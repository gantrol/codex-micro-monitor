import Foundation
import Darwin

public enum CodexClientError: LocalizedError {
    case unavailable(String)
    case unsupported(String)
    case invalid(String)
    case staleTarget
    case timedOut
    case outcomeUnknown

    public var errorDescription: String? {
        switch self {
        case .unavailable(let text), .unsupported(let text), .invalid(let text): return text
        case .staleTarget: return "The selected chat or its settings changed. Refresh and try again."
        case .timedOut: return "Codex did not respond before the deadline."
        case .outcomeUnknown: return "The action may have reached Codex. Its outcome is unknown; check the chat before trying again."
        }
    }
}

final class OperationContext: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    let deadline = Date().addingTimeInterval(45)
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
        if Date() >= deadline { throw CodexClientError.timedOut }
    }
}

enum JSON {
    static let null = NSNull()
    static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexClientError.invalid("Invalid Codex response.")
        }
        return value
    }
    static func encode(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    static func same(_ lhs: Any?, _ rhs: Any?) -> Bool {
        let a = lhs as? NSObject ?? null, b = rhs as? NSObject ?? null
        return a.isEqual(b)
    }
    static func required(_ dict: [String: Any], _ key: String) throws -> String {
        guard let value = dict[key] as? String, !value.isEmpty else {
            throw CodexClientError.invalid("Missing \(key).")
        }
        return value
    }
}

enum DescriptorIO {
    static let maxFrame = 16 * 1024 * 1024
    static func nonblocking(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw CodexClientError.unavailable("Cannot configure Codex transport.")
        }
    }
    static func wait(_ fd: Int32, events: Int16, until: Date, context: OperationContext) throws {
        while true {
            try context.check()
            guard Date() < until else { throw CodexClientError.timedOut }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, 100)
            if result < 0 {
                if errno == EINTR { continue }
                throw CodexClientError.unavailable("Codex transport failed.")
            }
            if descriptor.revents & events != 0 { return }
            if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                throw CodexClientError.unavailable("Codex disconnected.")
            }
        }
    }
    static func write(_ data: Data, fd: Int32, until: Date, context: OperationContext) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                try wait(fd, events: Int16(POLLOUT), until: until, context: context)
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { throw CodexClientError.unavailable("Codex disconnected while writing.") }
                offset += count
            }
        }
    }
    static func read(_ count: Int, fd: Int32, until: Date, context: OperationContext) throws -> Data {
        guard count > 0 && count <= maxFrame else { throw CodexClientError.invalid("Codex frame exceeds the size limit.") }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                try wait(fd, events: Int16(POLLIN), until: until, context: context)
                let read = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), count - offset)
                if read < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard read > 0 else { throw CodexClientError.unavailable("Codex disconnected.") }
                offset += read
            }
        }
        return data
    }
}

// Every operation owns its socket. Closing it drops the subscription and the entire
// response generation; no state, pending response, or mutation survives reconnect.
final class DesktopPeer {
    private var fd: Int32 = -1
    private var clientID = "initializing-client"
    private let context: OperationContext

    init(context: OperationContext) throws {
        self.context = context
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        let path = URL(fileURLWithPath: home).appendingPathComponent("ipc/ipc.sock").path
        var directory = stat(), endpoint = stat()
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard lstat(parent, &directory) == 0, lstat(path, &endpoint) == 0,
              directory.st_uid == getuid(), endpoint.st_uid == getuid(),
              (directory.st_mode & S_IFMT) == S_IFDIR,
              (endpoint.st_mode & S_IFMT) == S_IFSOCK,
              directory.st_mode & 0o022 == 0, endpoint.st_mode & 0o022 == 0 else {
            throw CodexClientError.unavailable("Codex desktop IPC is unavailable. Open Codex on this Mac.")
        }
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw CodexClientError.unavailable("Cannot open Codex desktop IPC.") }
        fd = socketFD
        do {
            try DescriptorIO.nonblocking(fd)
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(path.utf8) + [0]
            guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                throw CodexClientError.unavailable("Codex IPC path is too long.")
            }
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result != 0 {
                guard errno == EINPROGRESS else { throw CodexClientError.unavailable("Codex desktop is not accepting connections.") }
                try DescriptorIO.wait(fd, events: Int16(POLLOUT), until: Date().addingTimeInterval(4), context: context)
                var error: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                    throw CodexClientError.unavailable("Cannot connect to Codex desktop.")
                }
            }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
                throw CodexClientError.unavailable("Codex IPC belongs to a different user.")
            }
            let initialized = try request("initialize", version: 0, params: ["clientType": "codex-micro-mac"])
            guard let result = initialized["result"] as? [String: Any] else { throw CodexClientError.invalid("Invalid Codex initialization.") }
            clientID = try JSON.required(result, "clientId")
        } catch { close(); throw error }
    }
    deinit { close() }
    func close() { if fd >= 0 { Darwin.close(fd); fd = -1 } }
    private func write(_ object: [String: Any], until: Date) throws {
        let payload = try JSON.encode(object)
        guard payload.count <= DescriptorIO.maxFrame else { throw CodexClientError.invalid("Codex request is too large.") }
        var size = UInt32(payload.count).littleEndian
        var frame = withUnsafeBytes(of: &size) { Data($0) }
        frame.append(payload)
        try DescriptorIO.write(frame, fd: fd, until: until, context: context)
    }
    private func receive(until: Date) throws -> [String: Any] {
        let header = try DescriptorIO.read(4, fd: fd, until: until, context: context)
        let length = header.enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
        let message = try JSON.object(DescriptorIO.read(length, fd: fd, until: until, context: context))
        if message["type"] as? String == "client-discovery-request", let request = message["requestId"] {
            try write(["type": "client-discovery-response", "requestId": request, "response": ["canHandle": false]], until: until)
        }
        if message["method"] as? String == "ipc-connection-reset" {
            throw CodexClientError.unavailable("Codex restarted its desktop connection.")
        }
        return message
    }
    func request(_ method: String, version: Int, params: [String: Any], target: String? = nil, mutation: Bool = false) throws -> [String: Any] {
        let id = UUID().uuidString, until = Date().addingTimeInterval(12)
        var message: [String: Any] = ["type": "request", "requestId": id, "sourceClientId": clientID,
            "method": method, "version": version, "params": params, "timeoutMs": 10000]
        if let target { message["targetClientId"] = target }
        try context.check()
        var response: [String: Any]
        do {
            try write(message, until: until)
            while true {
                response = try receive(until: until)
                if response["type"] as? String == "response", response["requestId"] as? String == id { break }
            }
        } catch {
            if mutation { throw CodexClientError.outcomeUnknown }
            throw error
        }
        guard response["method"] as? String == method else {
            if mutation { throw CodexClientError.outcomeUnknown }
            throw CodexClientError.invalid("Codex response method mismatch.")
        }
        guard response["resultType"] as? String == "success" else {
            throw CodexClientError.unavailable(response["error"] as? String ?? "Codex rejected the request.")
        }
        return response
    }
    func owner(of thread: String) throws -> String {
        let result = try request("thread-owner-discovery", version: 1, params: ["hostId": "local", "conversationId": thread])
        return try JSON.required(result, "handledByClientId")
    }
    private func follow(_ thread: String, owner: String, following: Bool) throws {
        try write(["type": "broadcast", "method": "thread-stream-following-changed", "version": 1,
            "sourceClientId": clientID, "targetClientIds": [owner],
            "params": ["conversationId": thread, "hostId": "local", "following": following]], until: Date().addingTimeInterval(1))
    }
    func snapshot(_ thread: String, owner: String) throws -> [String: Any] {
        try follow(thread, owner: owner, following: false)
        try follow(thread, owner: owner, following: true)
        defer { try? follow(thread, owner: owner, following: false) }
        let until = Date().addingTimeInterval(6)
        while true {
            let message = try receive(until: until)
            guard message["type"] as? String == "broadcast",
                  message["method"] as? String == "thread-stream-state-changed",
                  message["sourceClientId"] as? String == owner,
                  let params = message["params"] as? [String: Any], params["conversationId"] as? String == thread else { continue }
            guard message["version"] as? Int == 11 else { throw CodexClientError.unsupported("Unsupported Codex desktop snapshot protocol.") }
            if let change = params["change"] as? [String: Any], change["type"] as? String == "snapshot",
               let state = change["conversationState"] as? [String: Any] { return state }
        }
    }
}
