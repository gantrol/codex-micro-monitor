import AppKit
import ApplicationServices
import Darwin
import MicroCore

// The renderer uses a memory router. Its WebArea can keep the bootstrap URL
// across chat changes; owner sync records the actual route, including home.
final class DesktopRouteObservation {
    struct Snapshot {
        let processID: Int32
        let window: AXUIElement
        let route: CurrentRoute
        func sameTarget(_ other: Self) -> Bool {
            processID == other.processID && MacAX.same(window, other.window) && route == other.route
        }
    }
    private struct Route {
        let window: Int
        let contents: Int
        let path: String
        let date: Date
    }
    private struct Cursor {
        var offset: UInt64
        var identity: UInt64
        var partial = Data()
        var sealed = false
    }
    private static let shared = DesktopRouteObservation()
    private let lock = NSLock()
    private var process: String?
    private var activeFD: Int32?
    private var activeInode: UInt64?
    private var activeFile: URL?
    private var trackedFiles: [URL] = []
    private var backfilled = false
    private var cursors: [URL: Cursor] = [:]
    private var routes: [Int: Route] = [:]
    private let timestamp: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return value
    }()

    static func document(app: NSRunningApplication, root: AXUIElement, window: AXUIElement) -> String? {
        // Electron window IDs are not macOS window numbers. Until an exact
        // mapping is available, accept only one native window and one log owner.
        guard let windows = MacAX.value(root, "AXWindows") as? [AXUIElement],
              windows.count == 1, MacAX.same(windows[0], window),
              MacAX.value(window, "AXMinimized") as? Bool != true,
              MacAX.value(window, "AXSubrole") as? String == "AXStandardWindow",
              (MacAX.value(window, "AXSheets") as? [AXUIElement])?.isEmpty != false,
              let launched = app.launchDate else { return nil }
        return shared.read(pid: app.processIdentifier, launched: launched)
    }

    static func observe(context: UIRequestContext) throws -> Snapshot? {
        try context.check()
        guard AXIsProcessTrusted() else { return nil }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
        guard apps.count == 1, let app = apps.first, !app.isTerminated else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = MacAX.element(MacAX.value(root, "AXFocusedWindow")) ?? MacAX.element(MacAX.value(root, "AXMainWindow")),
              let editor = MacAX.element(MacAX.value(root, "AXFocusedUIElement")),
              let editorWindow = MacAX.element(MacAX.value(editor, "AXWindow")), MacAX.same(editorWindow, window),
              let document = document(app: app, root: root, window: window) else { return nil }
        let node = AXNode(editor, parent: nil)
        guard node.enabled, node.rect.width > 0, node.rect.height > 0,
              ["AXTextArea", "AXTextField"].contains(node.role), node.classes.contains("ProseMirror") else { return nil }
        // A route log is supplementary evidence: settings and other pages may
        // stop emitting owner sync. Prove this window still contains the focused
        // Codex composer before using it after an incomplete tree observation.
        var parent = MacAX.element(MacAX.value(editor, "AXParent")), home = false, reachedWindow = false
        var ancestors: [NativeComposerScope.Ancestor] = []
        for _ in 0..<80 {
            try context.check()
            guard let element = parent else { break }
            if MacAX.same(element, window) { reachedWindow = true; break }
            guard let role = MacAX.value(element, "AXRole") as? String, !role.isEmpty else { return nil }
            ancestors.append(.init(role: role, identifier: MacAX.value(element, "AXDOMIdentifier") as? String ?? ""))
            let classes = MacAX.value(element, "AXDOMClassList") as? [String] ?? []
            home = home || classes.contains("[container-name:home-main-content]")
            parent = MacAX.element(MacAX.value(element, "AXParent"))
        }
        guard reachedWindow, NativeComposerScope.allows(ancestors) else { return nil }
        try context.check()
        let currentWindow = MacAX.element(MacAX.value(root, "AXFocusedWindow")) ?? MacAX.element(MacAX.value(root, "AXMainWindow"))
        guard MacAX.same(window, currentWindow), MacAX.same(editor, MacAX.element(MacAX.value(root, "AXFocusedUIElement"))),
              !app.isTerminated, MacAX.value(window, "AXMinimized") as? Bool != true else { return nil }
        let route = CurrentRoute.resolve(documents: [document], selectedLinks: [], homeComposer: home)
        return Snapshot(processID: app.processIdentifier, window: window, route: route)
    }

    private static func isMainThreadLog(name: String, pid: Int32) -> Bool {
        name.hasPrefix("codex-desktop-") && name.contains("-\(pid)-t0-") && name.hasSuffix(".log")
    }

    private func track(_ url: URL) {
        if !trackedFiles.contains(url) {
            trackedFiles.append(url)
            trackedFiles.sort { $0.path < $1.path }
        }
    }

    private func trackRotatedSiblings(of url: URL) {
        let name = url.lastPathComponent
        guard name.hasSuffix(".log") else { return }
        let stem = name.dropLast(4)
        guard let dash = stem.lastIndex(of: "-"),
              let part = Int(stem[stem.index(after: dash)...]), part > 0, part < 64 else { return }
        let prefix = String(stem[..<dash])
        let dir = url.deletingLastPathComponent()
        for index in 0..<part {
            let sibling = dir.appendingPathComponent("\(prefix)-\(index).log")
            if FileManager.default.fileExists(atPath: sibling.path) {
                track(sibling)
            }
        }
    }

    private func updateOpenLog(pid: Int32, rootPath: String) {
        let stride = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
        if let fd = activeFD, let inode = activeInode {
            var info = vnode_fdinfowithpath()
            if proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, &info, stride) == stride,
               UInt64(info.pvip.vip_vi.vi_stat.vst_ino) == inode {
                return
            }
            activeFD = nil; activeInode = nil; activeFile = nil
        }
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return }
        let count = Int(needed) / MemoryLayout<proc_fdinfo>.stride + 16
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let actual = fds.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard actual > 0 else { return }
        let total = Int(actual) / MemoryLayout<proc_fdinfo>.stride
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        for index in 0..<total where fds[index].proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            let fd = fds[index].proc_fd
            var info = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, &info, stride) == stride,
                  (info.pfi.fi_openflags & UInt32(FWRITE)) != 0 else { continue }
            let path = withUnsafePointer(to: &info.pvip.vip_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            guard path.hasPrefix(rootPrefix), !path.localizedCaseInsensitiveContains("trash") else { continue }
            let url = URL(fileURLWithPath: path)
            guard Self.isMainThreadLog(name: url.lastPathComponent, pid: pid) else { continue }
            activeFD = fd
            activeInode = UInt64(info.pvip.vip_vi.vi_stat.vst_ino)
            activeFile = url
            trackRotatedSiblings(of: url)
            track(url)
            return
        }
    }

    private func backfillFromDirectories(pid: Int32, launched: Date, now: Date, root: URL) {
        guard !backfilled else { return }
        backfilled = true
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy/MM/dd"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let startDay = calendar.startOfDay(for: max(launched, now.addingTimeInterval(-86400)))
        var days: [String] = []
        for candidate in [startDay, now] {
            let key = formatter.string(from: candidate)
            if !days.contains(key) { days.append(key) }
        }
        let token = "-\(pid)-t0-"
        for day in days {
            let dirURL = root.appendingPathComponent(day)
            guard let dir = Darwin.opendir(dirURL.path) else { continue }
            defer { Darwin.closedir(dir) }
            while let entry = Darwin.readdir(dir) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if name.hasPrefix("codex-desktop-"), name.contains(token), name.hasSuffix(".log") {
                    track(dirURL.appendingPathComponent(name))
                }
            }
        }
    }

    private func read(pid: Int32, launched: Date) -> String? {
        lock.lock(); defer { lock.unlock() }
        let identity = "\(pid):\(launched.timeIntervalSince1970)"
        if process != identity {
            process = identity
            activeFD = nil; activeInode = nil; activeFile = nil
            trackedFiles = []; backfilled = false
            cursors = [:]; routes = [:]
        }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/com.openai.codex")
        let now = Date()
        updateOpenLog(pid: pid, rootPath: root.path)
        if trackedFiles.isEmpty {
            backfillFromDirectories(pid: pid, launched: launched, now: now, root: root)
        }
        guard !trackedFiles.isEmpty, trackedFiles.count <= 64 else { return nil }
        if !( completeRead(launched: launched, now: now) ) { return nil }
        if routes.isEmpty, !backfilled {
            backfillFromDirectories(pid: pid, launched: launched, now: now, root: root)
            guard trackedFiles.count <= 64, completeRead(launched: launched, now: now) else { return nil }
        }
        guard routes.count == 1, let route = routes.values.first else { return nil }
        return "app://-" + route.path
    }

    private func completeRead(launched: Date, now: Date) -> Bool {
        // Every unread byte in the active files must be accounted for. Partial
        // records and an excessive backlog cannot authorize a cached old route.
        var complete = true
        for file in trackedFiles {
            if let existing = cursors[file], existing.sealed, file != activeFile { continue }
            guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let size = (attrs[.size] as? NSNumber)?.uint64Value,
                  let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value else { return false }
            var cursor = cursors[file] ?? Cursor(offset: 0, identity: inode)
            if cursor.identity != inode || cursor.offset > size { return false }
            if cursors[file] != nil, cursor.offset == size {
                if cursor.partial.isEmpty, file != activeFile { cursor.sealed = true; cursors[file] = cursor }
                complete = complete && cursor.partial.isEmpty
                continue
            }
            guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
            defer { try? handle.close() }
            if size - cursor.offset > 8 * 1024 * 1024 {
                // First observation may start at the tail; only complete lines
                // with timestamps from this process lifetime are accepted.
                guard cursor.offset == 0 else { return false }
                cursor.offset = size - 8 * 1024 * 1024
            }
            do {
                try handle.seek(toOffset: cursor.offset)
                let data = try handle.read(upToCount: Int(size - cursor.offset)) ?? Data()
                let skippedPrefix = cursors[file] == nil && cursor.offset > 0
                cursor.offset += UInt64(data.count)
                cursor.partial.append(data)
                if let end = cursor.partial.lastIndex(of: 10) {
                    var lines = String(decoding: cursor.partial[...end], as: UTF8.self).split(separator: "\n")
                    if skippedPrefix, !lines.isEmpty { lines.removeFirst() }
                    for line in lines { ingest(String(line), launched: launched, now: now) }
                    cursor.partial = Data(cursor.partial.suffix(from: cursor.partial.index(after: end)))
                }
                let atEnd = cursor.offset == size && cursor.partial.isEmpty
                if atEnd, file != activeFile { cursor.sealed = true }
                complete = complete && atEnd
                cursors[file] = cursor
            } catch { return false }
        }
        return complete
    }

    private func ingest(_ line: String, launched: Date, now: Date) {
        let marker = " info [electron-message-handler] IAB_LIFECYCLE received browser sidebar owner sync "
        guard let range = line.range(of: marker),
              let date = timestamp.date(from: String(line[..<range.lowerBound])), date >= launched,
              date <= now.addingTimeInterval(1) else { return }
        let fields = line[range.upperBound...].split(separator: " ").reduce(into: [String: String]()) { result, part in
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { result[String(pair[0])] = String(pair[1]) }
        }
        guard let rawWindow = fields["windowId"], let window = Int(rawWindow), window > 0,
              let rawContents = fields["originWebContentsId"], let contents = Int(rawContents), contents > 0 else { return }
        // A malformed or non-chat route is negative evidence, never permission
        // to retain the preceding conversation in this window.
        let path = fields["ownerRoutePath"] ?? "/unresolved"
        let document = "app://-" + path
        let valid = path.hasPrefix("/") && !path.hasPrefix("//") && path.utf8.count <= 2048 &&
            !path.contains("#") && CurrentRoute.documentPath(document) != nil
        let next = Route(window: window, contents: contents, path: valid ? path : "/unresolved", date: date)
        if let old = routes[window] {
            if date < old.date { return }
            if date == old.date && (old.path != next.path || old.contents != next.contents) {
                routes[window] = Route(window: window, contents: contents, path: "/unresolved", date: date)
                return
            }
        }
        routes[window] = next
    }
}
