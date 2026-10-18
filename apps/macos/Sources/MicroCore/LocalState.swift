import CryptoKit
import Darwin
import Foundation

struct CodexReadContext: Equatable {
    let identity: [String:String]
    let identityKey: String
    let executionHostKey: String
}

enum CodexStorage {
    private struct GlobalStateStamp: Equatable {
        let path: String
        let dev: dev_t
        let ino: ino_t
        let size: off_t
        let mtimeSec: Int
        let mtimeNsec: Int
        let ctimeSec: Int
        let ctimeNsec: Int
    }
    private static let globalStateLock = NSLock()
    private static var cachedGlobalState: (stamp: GlobalStateStamp, value: [String: Any])?

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

    static func globalState(root: URL = root, limit: Int = 16 * 1024 * 1024) throws -> [String: Any] {
        let url = root.appendingPathComponent(".codex-global-state.json")
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
        let stamp = GlobalStateStamp(
            path: url.path, dev: info.st_dev, ino: info.st_ino, size: info.st_size,
            mtimeSec: info.st_mtimespec.tv_sec, mtimeNsec: info.st_mtimespec.tv_nsec,
            ctimeSec: info.st_ctimespec.tv_sec, ctimeNsec: info.st_ctimespec.tv_nsec
        )
        globalStateLock.lock()
        if let cached = cachedGlobalState, cached.stamp == stamp {
            let value = cached.value
            globalStateLock.unlock()
            return value
        }
        globalStateLock.unlock()
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw CodexClientError.invalid("Codex local state exceeds the size limit.") }
        let parsed = try JSON.object(data)
        globalStateLock.lock()
        cachedGlobalState = (stamp, parsed)
        globalStateLock.unlock()
        return parsed
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
        guard let global = try? globalState() else { return nil }
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

    private static let composerContentBearingNodeTypes: Set<String> = [
        "atMention", "skillMention", "agentMention", "appMention", "pluginMention",
        "browserSkillMention", "browserTabMention", "richLink", "pageReferenceMention",
        "pageTaskMention", "resourceMention", "image", "horizontal_rule"
    ]

    static func composerDrafts(ids: Set<String>) -> Set<String>? {
        guard !ids.isEmpty else { return [] }
        guard let global = try? globalState(),
              let atoms = global["electron-persisted-atom-state"] as? [String: Any] else { return nil }
        // Prefer v2 as a whole dictionary. If v2 exists, do not fall back to v1
        // per-thread because v1 can retain stale entries after a draft is cleared.
        let v2Raw = atoms["composer-prompt-drafts-v2"]
        let prompts: [String: Any]?
        if let v2 = v2Raw as? [String: Any] {
            prompts = v2
        } else if v2Raw == nil || v2Raw is NSNull {
            prompts = atoms["composer-prompt-drafts-v1"] as? [String: Any]
        } else {
            prompts = nil
        }
        let pullRequests = atoms["composer-pull-request-attachment-drafts-v1"] as? [String: Any]
        let annotations = atoms["composer-response-annotation-drafts-v1"] as? [String: Any]
        let suggestions = atoms["composer-presentation-suggestion-drafts-v1"] as? [String: Any]
        guard prompts != nil || pullRequests != nil || annotations != nil || suggestions != nil else { return nil }

        func hasText(_ raw: String?) -> Bool {
            guard let raw else { return false }
            return raw.unicodeScalars.contains { scalar in
                !scalar.properties.isWhitespace && scalar.value != 0x200B && scalar.value != 0xFEFF
            }
        }
        func hasDocumentContent(_ node: [String: Any], depth: Int) -> Bool {
            guard depth <= 64 else { return false }
            let type = node["type"] as? String ?? ""
            if type == "text" { return hasText(node["text"] as? String) }
            if composerContentBearingNodeTypes.contains(type) { return true }
            if let content = node["content"] as? [[String: Any]] {
                return content.contains { hasDocumentContent($0, depth: depth + 1) }
            }
            return false
        }
        func hasPrompt(_ raw: Any?) -> Bool {
            if let text = raw as? String { return hasText(text) }
            guard let dict = raw as? [String: Any] else { return false }
            if hasPrompt(dict["draft"]) { return true }
            if let prompt = dict["prompt"] as? [String: Any],
               let document = prompt["document"] as? [String: Any] {
                return hasDocumentContent(document, depth: 0)
            }
            return false
        }

        var result = Set<String>()
        for id in ids where UUID(uuidString: id) != nil {
            let key = "local:" + id
            let present = hasPrompt(prompts?[key]) ||
                ((pullRequests?[key] as? [String: Any])?.isEmpty == false) ||
                ((annotations?[key] as? [Any])?.isEmpty == false) ||
                ((suggestions?[key] as? [String: Any])?["isAttached"] as? Bool == true)
            if present { result.insert(id) }
        }
        return result
    }
}

struct RolloutObservation {
    var status = "unknown"
    var pendingQuestion = false
    var errorCode: String? = nil
    var turnID: String? = nil
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
        var errorCode: String?
        var turn: String?
        var isTerminal = false
        var questions: Set<Question> = []
        var resolved: Set<Question> = []
        func clearQuestions() { questions.removeAll(); resolved.removeAll() }
        func resetTurn() { turn = nil; isTerminal = false; errorCode = nil; clearQuestions() }
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
            return .init(status: current.status, pendingQuestion: current.status == "active" && !current.questions.isEmpty,
                         errorCode: current.errorCode, turnID: current.turn)
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

    private static func readErrorCode(_ raw: Any?) -> String? {
        guard let dict = raw as? [String: Any] else { return nil }
        if let info = dict["codex_error_info"] as? String, !info.isEmpty { return info }
        if let code = dict["code"] as? String, !code.isEmpty { return code }
        return nil
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
            if let turn, turn == cursor.turn, cursor.isTerminal { return }
            if turn == nil || turn != cursor.turn { cursor.clearQuestions() }
            cursor.turn = turn
            cursor.isTerminal = false
            cursor.status = "active"
            cursor.errorCode = nil
        case "task_complete", "turn_aborted":
            let turn = payload["turn_id"] as? String
            if let turn, let active = cursor.turn, turn != active { return }
            // task_complete closes both successful and failed turns.
            // Capacity failures are reported here, without a separate error event.
            let error = payload["error"]
            let failed = error != nil && !(error is NSNull)
            cursor.status = failed ? "systemError" : "idle"
            cursor.errorCode = failed ? Self.readErrorCode(error) : nil
            cursor.clearQuestions()
            cursor.turn = turn ?? cursor.turn
            cursor.isTerminal = true
        case "error", "stream_error":
            let turn = payload["turn_id"] as? String
            if (cursor.isTerminal && turn != nil) || (turn != nil && cursor.turn != nil && turn != cursor.turn) { return }
            cursor.status = "systemError"
            cursor.errorCode = Self.readErrorCode(payload)
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
