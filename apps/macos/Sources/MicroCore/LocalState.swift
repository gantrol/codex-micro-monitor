import CryptoKit
import Darwin
import Foundation

struct CodexReadContext: Equatable {
    let identity: [String:String]
    let identityKey: String
    let executionHostKey: String
}

enum CodexStorage {
    static var root: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path,
            isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    }

    static func read(_ url: URL, limit: Int) throws -> Data {
        guard !url.path.localizedCaseInsensitiveContains("trash") else {
            throw CodexClientError.invalid("Unsupported Codex storage path.")
        }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw CodexClientError.unavailable("Codex local state is unavailable.") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_size <= limit else {
            throw CodexClientError.invalid("Unsupported Codex local state file.")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw CodexClientError.invalid("Codex local state exceeds the size limit.") }
        return data
    }

    static func hash(_ parts: [Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: parts, options: [.withoutEscapingSlashes]) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // Only the derived bucket key leaves this method. Never return or persist tokens.
    static func identityKey(_ auth: [String: Any]) -> String? {
        readContext(auth)?.identityKey
    }

    static func readContext(_ auth: [String:Any]) -> CodexReadContext? {
        let method = auth["authMethod"] as? String
        guard let host = hash(["local", "local", NSNull()]) else { return nil }
        if method == "chatgpt" || method == "chatgptAuthTokens" {
            guard let token = auth["authToken"] as? String else { return nil }
            let parts = token.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[1].count < 64 * 1024 else { return nil }
            var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
            guard let bytes = Data(base64Encoded: payload), let value = try? JSON.object(bytes),
                  let claims = value["https://api.openai.com/auth"] as? [String: Any],
                  let account = (claims["chatgpt_account_id"] ?? claims["account_id"]) as? String, !account.isEmpty,
                  let user = (claims["user_id"] ?? claims["chatgpt_user_id"]) as? String, !user.isEmpty else { return nil }
            guard let key=hash(["chatgpt", account, user]) else { return nil }
            return .init(identity:["kind":"chatgpt","accountId":account,"userId":user],identityKey:key,executionHostKey:"local:"+host)
        }
        guard method != nil || auth["requiresOpenaiAuth"] as? Bool == false else { return nil }
        guard let key=hash(["execution-storage", method ?? "none"]) else { return nil }
        return .init(identity:["kind":"execution-storage","authMode":method ?? "none"],identityKey:key,executionHostKey:"local:"+host)
    }

    static func unread(identity: String?) -> Set<String>? {
        guard let bytes = try? read(root.appendingPathComponent(".codex-global-state.json"), limit: 16 * 1024 * 1024),
              let global = try? JSON.object(bytes) else { return nil }
        if let raw = global["electron-thread-read-state-v1"] {
            guard let state = raw as? [String: Any], state["version"] as? Int == 1,
                  let identity, let identities = state["unreadByIdentity"] as? [String: Any],
                  let host = hash(["local", "local", NSNull()]) else { return nil }
            guard let rawHosts=identities[identity] else { return [] }
            guard let hosts=rawHosts as? [String:Any] else { return nil }
            guard let rawIDs=hosts["local:"+host] else { return [] }
            guard let ids = rawIDs as? [String],
                  ids.allSatisfy({ UUID(uuidString: $0) != nil }) else { return nil }
            return Set(ids)
        }
        // Legacy state has no account binding. It is deliberately not merged
        // into a modern identity or treated as proof that a chat is unread.
        return nil
    }
}

struct RolloutObservation {
    var status = "unknown"
    var pendingQuestion = false
}

/// Bounded, incremental JSONL observation. Only lifecycle and question IDs are
/// cached beyond the partial-line buffer; message contents are never returned.
final class RolloutReader {
    private struct Question: Hashable { let item: String; let index: Int }
    private final class Cursor {
        var file: UInt64 = 0
        var device: Int32 = 0
        var offset: UInt64 = 0
        var modified = timespec()
        var partial = Data()
        var dropping = false
        var status = "unknown"
        var turn: String?
        var questions: Set<Question> = []
        var resolved: Set<Question> = []
        func resetTurn() { turn = nil; questions.removeAll(); resolved.removeAll() }
    }
    private var cursors: [String: Cursor] = [:]
    private let maximumLine = 256 * 1024
    private let maximumRead = 2 * 1024 * 1024
    private let maximumCursors:Int
    init(maximumCursors:Int=24) {self.maximumCursors=max(24,maximumCursors)}

    func retain(_ paths: Set<String>) { cursors = cursors.filter { paths.contains($0.key) } }
    func reset() { cursors.removeAll() }

    func read(path: String?, thread: String, acceptedState: [String: Any]? = nil, context: OperationContext) throws -> RolloutObservation {
        try context.check()
        guard let path, path.hasPrefix("/"), !path.localizedCaseInsensitiveContains("trash") else { return .init() }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let sessions = CodexStorage.root.appendingPathComponent("sessions").path + "/"
        guard url.path.hasPrefix(sessions), !url.path.localizedCaseInsensitiveContains("trash") else { return .init() }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { cursors[url.path] = nil; return .init() }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { return .init() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let length = UInt64(info.st_size)
        var cursor = cursors[url.path]
        if let existing = cursor, existing.file != info.st_ino || existing.device != info.st_dev || length < existing.offset ||
            (length == existing.offset && (info.st_mtimespec.tv_sec != existing.modified.tv_sec || info.st_mtimespec.tv_nsec != existing.modified.tv_nsec)) {
            cursor = nil
        }
        if cursor == nil {
            let header = try handle.read(upToCount: maximumLine) ?? Data()
            guard let end = header.firstIndex(of: 10), let record = try? JSON.object(Data(header[..<end])),
                  record["type"] as? String == "session_meta",
                  (record["payload"] as? [String: Any])?["id"] as? String == thread else { cursors[url.path] = nil; return .init() }
            let created = Cursor(); created.file = info.st_ino; created.device = info.st_dev
            // Seed from a bounded tail. Until a lifecycle event is present,
            // status stays unknown; an arbitrary message is never an idle signal.
            created.offset = length > maximumRead ? length - UInt64(maximumRead) : 0
            created.dropping = created.offset > 0
            cursor = created; cursors[url.path] = created
        }
        let current = cursor!
        // MCP callers can inspect many exact IDs without fetching a roster.
        // Bound that cache too; losing a cursor only requires another tail read.
        if cursors.count > maximumCursors, let oldest = cursors.keys.filter({ $0 != url.path }).sorted().first { cursors[oldest] = nil }
        do {
            try handle.seek(toOffset: current.offset)
            let end = min(length, current.offset + UInt64(maximumRead))
            while current.offset < end {
                try context.check()
                let bytes = try handle.read(upToCount: Int(min(32 * 1024, end - current.offset))) ?? Data()
                guard !bytes.isEmpty else { break }
                current.offset += UInt64(bytes.count)
                consume(bytes, cursor: current)
            }
            current.modified = info.st_mtimespec
            if let acceptedState { accept(acceptedState, cursor: current) }
            guard current.offset == length else { return .init() }
            return .init(status: current.status, pendingQuestion: current.status == "active" && !current.questions.isEmpty)
        } catch {
            cursors[url.path] = nil
            throw error
        }
    }

    private func consume(_ bytes: Data, cursor: Cursor) {
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let end = bytes[start...].firstIndex(of: 10) ?? bytes.endIndex
            let segment = bytes[start..<end]
            if !cursor.dropping {
                if cursor.partial.count + segment.count <= maximumLine { cursor.partial.append(contentsOf: segment) }
                else { cursor.partial.removeAll(keepingCapacity: false); cursor.dropping = true; cursor.status = "unknown"; cursor.resetTurn() }
            }
            if end == bytes.endIndex { break }
            if !cursor.dropping { record(cursor.partial, cursor: cursor) }
            cursor.partial.removeAll(keepingCapacity: true); cursor.dropping = false
            start = bytes.index(after: end)
        }
    }

    private func record(_ bytes: Data, cursor: Cursor) {
        guard let value = try? JSON.object(bytes), let payload = value["payload"] as? [String: Any] else { return }
        if value["type"] as? String == "response_item", payload["type"] as? String == "message", payload["role"] as? String == "user" {
            answer(payload["content"], cursor: cursor); return
        }
        guard value["type"] as? String == "event_msg", let type = payload["type"] as? String else { return }
        switch type {
        case "task_started":
            let turn = payload["turn_id"] as? String
            if turn == nil || turn != cursor.turn { cursor.resetTurn() }
            cursor.turn = turn; cursor.status = "active"
        case "task_complete", "turn_aborted":
            if let turn = payload["turn_id"] as? String, let active = cursor.turn, turn != active { return }
            cursor.status = "idle"; cursor.resetTurn()
        case "error", "stream_error": cursor.status = "systemError"
        case "item_completed":
            guard let item = payload["item"] as? [String: Any] else { return }
            if ["UserMessage", "userMessage"].contains(item["type"] as? String ?? "") { answer(item["content"], cursor: cursor); return }
            guard cursor.status == "active", ["AgentMessage", "agentMessage"].contains(item["type"] as? String ?? ""),
                  item["delivery"] as? String == "async", let id = item["id"] as? String,
                  cursor.turn == nil || payload["turn_id"] as? String == cursor.turn,
                  let questions = item["questions"] as? [[String: Any]], questions.count <= 100 else { return }
            for (index, question) in questions.enumerated() where !(question["title"] as? String ?? "").isEmpty {
                let key = Question(item: id, index: index)
                if !cursor.resolved.contains(key), cursor.questions.count < 256 { cursor.questions.insert(key) }
            }
        default: break
        }
    }

    private func accept(_ state: [String: Any], cursor: Cursor) {
        var turns = state["turns"] as? [[String: Any]] ?? []
        if let history = state["turnHistory"] as? [String: Any], let data = history["history"] as? [String: Any],
           let entities = data["entitiesByKey"] as? [String: [String: Any]] { turns += entities.values }
        for turn in turns {
            for item in turn["items"] as? [[String: Any]] ?? [] {
                if item["type"] as? String == "userMessage" { answer(item["content"], cursor: cursor) }
                if item["type"] as? String == "steeringUserMessage", item["status"] as? String == "accepted" { answer(item["input"], cursor: cursor) }
            }
        }
    }

    private func answer(_ raw: Any?, cursor: Cursor) {
        let start = "<send_user_message_question_reply>", end = "</send_user_message_question_reply>"
        guard let content = raw as? [[String: Any]], content.count == 1,
              let text = content[0]["text"] as? String, text.utf8.count <= maximumLine else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(start), trimmed.hasSuffix(end),
              let json = String(trimmed.dropFirst(start.count).dropLast(end.count)).data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: json) else { return }
        let replies = value as? [[String: Any]] ?? (value as? [String: Any]).map { [$0] } ?? []
        for reply in replies {
            guard reply["answer"] is String, let id = reply["questionItemId"] as? String,
                  let bytes = id.data(using: .utf8), let parts = try? JSONSerialization.jsonObject(with: bytes) as? [Any],
                  parts.count == 3, parts[0] as? String == "request_user_input_async", let item = parts[1] as? String,
                  let index = parts[2] as? Int, index >= 0 else { continue }
            let key = Question(item: item, index: index)
            cursor.questions.remove(key)
            if cursor.resolved.count < 1024 { cursor.resolved.insert(key) }
        }
    }
}
