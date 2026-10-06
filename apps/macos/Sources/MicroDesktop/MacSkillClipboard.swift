import AppKit
import MicroCore

enum MacSkillClipboard {
    static func insert(name: String, path: String, snapshot: MacUISnapshot, context: UIRequestContext,
                       check: (_ preserveText: Bool) throws -> Void, markMutation: () -> Void) throws -> Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 256,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              path.hasPrefix("/"), !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              URL(fileURLWithPath: path).lastPathComponent == "SKILL.md", !path.localizedCaseInsensitiveContains("trash"),
              let editor = snapshot.editor, let originalText = editor.text else { throw CodexClientError.invalid("Invalid skill mention.") }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        _ = try MacLocalFile.read(url, maximum: 1024 * 1024)
        let lockURL = MacLocalFile.home.appendingPathComponent(".micro-clipboard.lock")
        guard !lockURL.path.localizedCaseInsensitiveContains("trash") else { throw CodexClientError.invalid("Invalid clipboard lock path.") }
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw CodexClientError.unavailable("Clipboard lock is unavailable.") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CodexClientError.unavailable("Another Micro operation owns the clipboard.") }
        defer { flock(fd, LOCK_UN) }
        try check(true)
        try MacAX.set(editor.element, "AXFocused", kCFBooleanTrue)
        let focusDeadline = ProcessInfo.processInfo.systemUptime + 0.6
        while MacAX.value(editor.element, "AXFocused") as? Bool != true && ProcessInfo.processInfo.systemUptime < focusDeadline {
            try context.check(); Thread.sleep(forTimeInterval: 0.02)
        }
        guard MacAX.value(editor.element, "AXFocused") as? Bool == true else { throw CodexClientError.staleTarget }
        let pasteboard = NSPasteboard.general, originalCount = pasteboard.changeCount
        var saved: [NSPasteboardItem] = [], total = 0
        for item in pasteboard.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type), data.count <= 16 * 1024 * 1024 - total else { throw CodexClientError.unavailable("The clipboard cannot be preserved safely.") }
                total += data.count; copy.setData(data, forType: type)
            }
            saved.append(copy)
        }
        try check(true)
        guard pasteboard.changeCount == originalCount else { throw CodexClientError.staleTarget }
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let content = NSPasteboardItem()
        content.setString("<html><body><span skill-mention-name=\"\(escape(name))\" skill-mention-path=\"\(escape(url.path))\">$\(escape(name))</span></body></html>", forType: .html)
        content.setString("$" + name, forType: .string)
        let marker = NSPasteboard.PasteboardType("com.gantrol.micro.clipboard-transaction"), nonce = UUID().uuidString
        content.setString(nonce, forType: marker)
        var ownedCount = pasteboard.clearContents()
        var staged = false, copiedByTarget = false
        defer {
            // A concurrent copy always wins, including copies from another app.
            if pasteboard.changeCount == ownedCount,
               copiedByTarget || (staged ? pasteboard.string(forType: marker) == nonce : (pasteboard.pasteboardItems ?? []).isEmpty) {
                pasteboard.clearContents(); if !saved.isEmpty { pasteboard.writeObjects(saved) }
            }
        }
        guard pasteboard.changeCount == ownedCount else { throw CodexClientError.staleTarget }
        guard pasteboard.writeObjects([content]) else { throw CodexClientError.unavailable("Could not stage the skill mention.") }
        ownedCount = pasteboard.changeCount; staged = true
        try check(true)
        guard pasteboard.changeCount == ownedCount else { throw CodexClientError.staleTarget }
        guard let paste = MacShortcut.parse("Command+V"), let copy = MacShortcut.parse("Command+C") else {
            throw CodexClientError.unavailable("Clipboard shortcuts are unavailable for the current keyboard layout.")
        }
        markMutation()
        try paste.send(to: snapshot.app.processIdentifier) {
            try context.check(); try check(true)
            guard pasteboard.changeCount == ownedCount, NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.app.processIdentifier else { throw CodexClientError.staleTarget }
        }
        // Keep the pasteboard alive until the target consumes the paste, then
        // copy the atom back and validate both custom attributes. Visible text
        // alone is not a successful Skill insertion.
        let end = ProcessInfo.processInfo.systemUptime + 1.5
        var inserted = false
        while ProcessInfo.processInfo.systemUptime < end {
            try context.check()
            if let text = MacAX.value(editor.element, "AXValue") as? String, text != originalText, text.contains("$" + name) {
                inserted = true; break
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        guard inserted else { throw CodexClientError.outcomeUnknown }
        try check(false)
        guard pasteboard.changeCount == ownedCount, MacAX.value(editor.element, "AXFocused") as? Bool == true else {
            throw CodexClientError.staleTarget
        }
        let selectPrevious = MacShortcut(key: 123, flags: .maskShift)
        try selectPrevious.send(to: snapshot.app.processIdentifier) {
            try context.check(); try check(false)
            guard pasteboard.changeCount == ownedCount, MacAX.value(editor.element, "AXFocused") as? Bool == true else {
                throw CodexClientError.staleTarget
            }
        }
        try copy.send(to: snapshot.app.processIdentifier) {
            try context.check(); try check(false)
            guard pasteboard.changeCount == ownedCount, MacAX.value(editor.element, "AXFocused") as? Bool == true else {
                throw CodexClientError.staleTarget
            }
        }
        let copyDeadline = ProcessInfo.processInfo.systemUptime + 0.8
        while pasteboard.changeCount == ownedCount && ProcessInfo.processInfo.systemUptime < copyDeadline {
            try context.check(); Thread.sleep(forTimeInterval: 0.02)
        }
        guard pasteboard.changeCount != ownedCount else { throw CodexClientError.outcomeUnknown }
        try check(false)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.app.processIdentifier,
              MacAX.value(editor.element, "AXFocused") as? Bool == true else { throw CodexClientError.staleTarget }
        let copiedCount = pasteboard.changeCount
        let copiedText = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let copiedHTML = pasteboard.string(forType: .html)
        guard pasteboard.changeCount == copiedCount else { throw CodexClientError.staleTarget }
        let exactMention = copiedHTML.map { containsMention($0, name: name, path: url.path) } == true
        if exactMention || copiedText == "$" + name {
            ownedCount = copiedCount; staged = false; copiedByTarget = true
        }
        let collapse = MacShortcut(key: 124, flags: [])
        try collapse.send(to: snapshot.app.processIdentifier) {
            try context.check(); try check(false)
            guard copiedByTarget, pasteboard.changeCount == ownedCount,
                  MacAX.value(editor.element, "AXFocused") as? Bool == true else { throw CodexClientError.staleTarget }
        }
        try check(false)
        guard pasteboard.changeCount == ownedCount else { throw CodexClientError.staleTarget }
        return exactMention
    }

    private static func containsMention(_ html: String, name: String, path: String) -> Bool {
        guard html.utf8.count <= 4 * 1024 * 1024,
              let spans = try? NSRegularExpression(pattern: #"<span\b[^>]*>"#, options: [.caseInsensitive]) else { return false }
        let source = html as NSString
        for match in spans.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            let tag = source.substring(with: match.range)
            if attribute("skill-mention-name", in: tag) == name,
               attribute("skill-mention-path", in: tag) == path { return true }
        }
        return false
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"(?:^|\s)"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*(?:\"([^\"]*)\"|'([^']*)')"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let source = tag as NSString, range = NSRange(location: 0, length: source.length)
        guard let match = expression.firstMatch(in: tag, range: range) else { return nil }
        let value = match.range(at: 1).location != NSNotFound ? source.substring(with: match.range(at: 1)) : source.substring(with: match.range(at: 2))
        return value.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
