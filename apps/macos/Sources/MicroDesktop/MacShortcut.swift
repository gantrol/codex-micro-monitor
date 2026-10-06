import AppKit
import Carbon
import MicroCore

struct MacShortcut: Equatable {
    let key: CGKeyCode
    let flags: CGEventFlags

    static func configured(_ command: String) throws -> MacShortcut {
        let url = MacLocalFile.home.appendingPathComponent("keybindings.json")
        guard let entries = try JSONSerialization.jsonObject(with: MacLocalFile.read(url, maximum: 256 * 1024)) as? [[String: Any]],
              entries.allSatisfy({ $0["command"] is String && ($0["key"] is String || $0["key"] is NSNull) }) else {
            throw CodexClientError.invalid("Invalid Codex keyboard shortcuts.")
        }
        let assigned = entries.filter { $0["command"] as? String == command }
        guard !assigned.isEmpty, !assigned.contains(where: { $0["key"] is NSNull }) else {
            throw CodexClientError.unavailable("Assign a native Codex shortcut for \(command) first.")
        }
        for binding in assigned {
            guard let text = binding["key"] as? String, let shortcut = parse(text) else { continue }
            let conflicts = entries.contains { entry in
                guard entry["command"] as? String != command, let text = entry["key"] as? String,
                      let first = text.split(whereSeparator: \.isWhitespace).first else { return false }
                return parse(String(first)) == shortcut
            }
            if !conflicts { return shortcut }
        }
        throw CodexClientError.unavailable("The configured shortcut is ambiguous or unsupported.")
    }

    static func parse(_ text: String) -> MacShortcut? {
        guard !text.contains(where: \.isWhitespace) else { return nil }
        let parts = text.lowercased().split(separator: "+").map(String.init)
        guard let last = parts.last else { return nil }
        var flags: CGEventFlags = []
        for part in parts.dropLast() {
            let flag: CGEventFlags
            switch part {
            case "cmd", "command", "meta", "cmdorctrl", "commandorcontrol": flag = .maskCommand
            case "ctrl", "control": flag = .maskControl
            case "alt", "option": flag = .maskAlternate
            case "shift": flag = .maskShift
            default: return nil
            }
            guard !flags.contains(flag) else { return nil }; flags.insert(flag)
        }
        let fixed: [String: CGKeyCode] = ["f1":122,"f2":120,"f3":99,"f4":118,"f5":96,"f6":97,"f7":98,"f8":100,"f9":101,"f10":109,"f11":103,"f12":111,
            "f13":105,"f14":107,"f15":113,"f16":106,"f17":64,"f18":79,"f19":80,"f20":90,
            "left":123,"right":124,"down":125,"up":126,"return":36,"enter":36,"tab":48,"space":49,"escape":53]
        if let key = fixed[last] { return .init(key: key, flags: flags) }
        guard !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty, last.count == 1,
              let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        for code in 0..<128 {
            var dead: UInt32 = 0, count = 0
            var characters = [UniChar](repeating: 0, count: 8)
            // Some layouts (Dvorak–QWERTY Command) use a different mapping
            // while Command is held. Resolve the shortcut in that mapping.
            let modifiers = flags.contains(.maskCommand) ? UInt32(cmdKey) >> 8 : 0
            let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &dead, 8, &count, &characters)
            if status == noErr, String(utf16CodeUnits: characters, count: count).lowercased() == last { return .init(key: CGKeyCode(code), flags: flags) }
        }
        return nil
    }

    func send(to pid: pid_t, check: () throws -> Void) throws {
        try check()
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { throw CodexClientError.unavailable("Cannot create native keyboard input.") }
        down.flags = flags; up.flags = flags
        // Posting to the exact PID avoids redirecting input on a focus race.
        // Release always pairs with its key-down, including cancellation.
        down.postToPid(pid); up.postToPid(pid)
    }
}

enum MacLocalFile {
    static var home: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path).standardizedFileURL.resolvingSymlinksInPath() }
    static func read(_ url: URL, maximum: Int) throws -> Data {
        guard !url.path.localizedCaseInsensitiveContains("trash") else { throw CodexClientError.invalid("Unsupported file path.") }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw CodexClientError.unavailable("The requested local file is unavailable.") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size <= maximum else { throw CodexClientError.invalid("Invalid local file.") }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw CodexClientError.invalid("Local file exceeds the size limit.") }
        return data
    }
}
