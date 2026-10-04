import Foundation
import Darwin

// This process is a catalog reader, never an alternate owner of desktop turns.
// Only the allowlisted reads can cross this transport.
final class CodexCatalog {
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = Data()
    private var requestID = 0

    deinit { close() }
    func close() {
        let old = process
        process = nil
        try? input?.fileHandleForWriting.close()
        try? input?.fileHandleForReading.close()
        try? output?.fileHandleForReading.close()
        try? output?.fileHandleForWriting.close()
        input = nil; output = nil; buffer.removeAll(keepingCapacity: false)
        if let old, old.isRunning {
            old.terminate()
            let deadline = Date().addingTimeInterval(0.2)
            while old.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if old.isRunning { kill(old.processIdentifier, SIGKILL) }
        }
    }
    static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            ProcessInfo.processInfo.environment["CODEX_MICRO_CLI"],
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "\(home)/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "\(home)/Applications/Codex.app/Contents/Resources/codex",
            "\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ].compactMap { $0 }
        for candidate in candidates {
            let url = URL(fileURLWithPath: candidate).resolvingSymlinksInPath()
            if !url.path.localizedCaseInsensitiveContains("trash"), FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
    func call(_ method: String, params: [String: Any], context: OperationContext) throws -> [String: Any] {
        guard ["thread/list", "thread/read", "model/list", "account/rateLimits/read", "config/read", "collaborationMode/list"].contains(method) else {
            throw CodexClientError.unsupported("This operation is not available through the read-only catalog.")
        }
        do {
            if process?.isRunning != true {
                close()
                guard let executable = Self.executable() else { throw CodexClientError.unavailable("Codex CLI was not found. Install Codex on this Mac.") }
                try context.check()
                let task = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe()
                task.executableURL = executable
                task.arguments = ["app-server", "--stdio"]
                task.standardInput = stdinPipe
                task.standardOutput = stdoutPipe
                task.standardError = FileHandle.nullDevice
                try task.run()
                process = task; input = stdinPipe; output = stdoutPipe
                try DescriptorIO.nonblocking(stdinPipe.fileHandleForWriting.fileDescriptor)
                try DescriptorIO.nonblocking(stdoutPipe.fileHandleForReading.fileDescriptor)
                _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                _ = try exchange("initialize", params: [
                    "clientInfo": ["name": "codex-micro-mac", "title": "Codex Micro", "version": "0.3.15"],
                    "capabilities": ["experimentalApi": true]
                ], context: context)
                try send(["method": "initialized", "params": [:]], context: context)
            }
            return try exchange(method, params: params, context: context)
        } catch { close(); throw error }
    }
    private func send(_ message: [String: Any], context: OperationContext) throws {
        guard let input else { throw CodexClientError.unavailable("Codex catalog is closed.") }
        var data = try JSON.encode(message); data.append(10)
        try DescriptorIO.write(data, fd: input.fileHandleForWriting.fileDescriptor, until: Date().addingTimeInterval(4), context: context)
    }
    private func line(until: Date, context: OperationContext) throws -> Data {
        guard let output else { throw CodexClientError.unavailable("Codex catalog is closed.") }
        while true {
            try context.check()
            if let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                return line
            }
            guard buffer.count < DescriptorIO.maxFrame else { throw CodexClientError.invalid("Codex catalog response exceeds the size limit.") }
            let fd = output.fileHandleForReading.fileDescriptor
            try DescriptorIO.wait(fd, events: Int16(POLLIN), until: until, context: context)
            var bytes = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(fd, &bytes, min(bytes.count, DescriptorIO.maxFrame - buffer.count))
            if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard count > 0 else { throw CodexClientError.unavailable("Codex catalog disconnected.") }
            buffer.append(contentsOf: bytes.prefix(count))
        }
    }
    private func exchange(_ method: String, params: [String: Any], context: OperationContext) throws -> [String: Any] {
        requestID += 1
        let id = requestID, deadline = Date().addingTimeInterval(20)
        try send(["id": id, "method": method, "params": params], context: context)
        while true {
            let message = try JSON.object(line(until: deadline, context: context))
            guard message["id"] as? Int == id else {
                // Reject unexpected server requests; do not approve or run tools.
                if let request = message["id"], message["method"] != nil {
                    try send(["id": request, "error": ["code": -32601, "message": "Read-only catalog client"]], context: context)
                }
                continue
            }
            if let error = message["error"] as? [String: Any] {
                throw CodexClientError.unavailable(error["message"] as? String ?? "Codex rejected the catalog request.")
            }
            guard let result = message["result"] as? [String: Any] else { throw CodexClientError.invalid("Invalid Codex catalog response.") }
            return result
        }
    }
}
