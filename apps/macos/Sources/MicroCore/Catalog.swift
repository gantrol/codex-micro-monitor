import Foundation
import Darwin

// Existing-thread writes stay with the desktop owner. Fork has a separate,
// short-lived server and requires the installed schema's continuation guard.
final class CodexCatalog {
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = Data()
    private var requestID = 0
    private var executableStamp: String?
    private var authStamp: String?
    private var forkSchema: (stamp: String, supported: Bool)?
    private(set) var generation = UUID().uuidString
    private(set) var homeIdentity:String?

    deinit { close() }
    func close() {
        let old = process
        process = nil;homeIdentity=nil
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

    private static func stamp(_ url: URL) -> String {
        guard !url.path.localizedCaseInsensitiveContains("trash"),
              let info = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "missing" }
        let modified = (info[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.path):\(info[.systemFileNumber] ?? ""):\(info[.size] ?? ""):\(modified)"
    }

    func assertStorageCurrent() throws {
        guard authStamp == Self.stamp(CodexStorage.root.appendingPathComponent("auth.json")),
              let executable = Self.executable(), executableStamp == Self.stamp(executable) else {
            throw CodexClientError.staleTarget
        }
    }

    func supportsSafeFork(context: OperationContext) throws -> Bool {
        guard let executable = Self.executable() else { return false }
        let stamp = Self.stamp(executable)
        if let cached = forkSchema, cached.stamp == stamp { return cached.supported }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("micro-schema-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let task = Process()
        task.executableURL = executable
        task.arguments = ["app-server", "generate-json-schema", "--experimental", "--out", folder.path]
        task.standardInput = FileHandle.nullDevice; task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        try context.check()
        try task.run()
        defer { if task.isRunning { task.terminate(); if task.isRunning { kill(task.processIdentifier, SIGKILL) } } }
        let deadline = Date().addingTimeInterval(8)
        while task.isRunning {
            try context.check()
            guard Date() < deadline else { throw CodexClientError.timedOut }
            Thread.sleep(forTimeInterval: 0.02)
        }
        var supported = false
        if task.terminationStatus == 0,
           let data = try? CodexStorage.read(folder.appendingPathComponent("v2/ThreadForkParams.json"), limit: 256 * 1024),
           let schema = try? JSON.object(data), let properties = schema["properties"] as? [String: [String: Any]] {
            supported = properties["deferGoalContinuation"]?["type"] as? String == "boolean" &&
                properties["excludeTurns"]?["type"] as? String == "boolean" && properties["threadId"]?["type"] as? String == "string"
        }
        guard Self.stamp(executable) == stamp else { throw CodexClientError.staleTarget }
        forkSchema = (stamp, supported)
        return supported
    }

    func fork(_ thread: String, context: OperationContext) throws -> [String: Any] {
        guard try supportsSafeFork(context: context) else {
            throw CodexClientError.unsupported("This Codex CLI cannot fork without automatically continuing an existing goal. Update Codex or fork in Codex.")
        }
        let temporary = CodexCatalog()
        defer { temporary.close() }
        // Read without resuming the source; initialize this dedicated connection.
        let result = try temporary.call("thread/read", params: ["threadId": thread, "includeTurns": false], context: context)
        guard (result["thread"] as? [String: Any])?["id"] as? String == thread,
              let executable = Self.executable(), Self.stamp(executable) == forkSchema?.stamp,
              temporary.executableStamp == forkSchema?.stamp else { throw CodexClientError.staleTarget }
        try temporary.assertStorageCurrent()
        return try temporary.exchange("thread/fork", params: ["threadId": thread, "excludeTurns": true, "deferGoalContinuation": true], context: context, mutation: true)
    }

    func call(_ method: String, params: [String: Any], context: OperationContext) throws -> [String: Any] {
        guard ["thread/list", "thread/read", "threadSection/list", "project/list", "model/list", "account/rateLimits/read", "config/read", "configRequirements/read", "collaborationMode/list", "getAuthStatus"].contains(method) else {
            throw CodexClientError.unsupported("This operation is not available through the read-only catalog.")
        }
        do {
            guard let executable = Self.executable(), !CodexStorage.root.path.localizedCaseInsensitiveContains("trash") else {
                throw CodexClientError.unavailable("Codex CLI or local storage is unavailable.")
            }
            let currentExecutable = Self.stamp(executable), currentAuth = Self.stamp(CodexStorage.root.appendingPathComponent("auth.json"))
            if currentExecutable != executableStamp || currentAuth != authStamp { close() }
            if process?.isRunning != true {
                close()
                try context.check()
                let task = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe()
                task.executableURL = executable
                task.arguments = ["app-server", "--stdio"]
                task.standardInput = stdinPipe
                task.standardOutput = stdoutPipe
                task.standardError = FileHandle.nullDevice
                try task.run()
                process = task; input = stdinPipe; output = stdoutPipe
                executableStamp = currentExecutable; authStamp = currentAuth; generation = UUID().uuidString
                try DescriptorIO.nonblocking(stdinPipe.fileHandleForWriting.fileDescriptor)
                try DescriptorIO.nonblocking(stdoutPipe.fileHandleForReading.fileDescriptor)
                _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                let initialized = try exchange("initialize", params: [
                    "clientInfo": ["name": "codex-micro-mac", "title": "Codex Micro", "version": "1.0.0"],
                    "capabilities": ["experimentalApi": true]
                ], context: context)
                if let home = initialized["codexHome"] as? String,
                   URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath() != CodexStorage.root {
                    throw CodexClientError.unsupported("The catalog and desktop use different Codex storage roots.")
                }
                homeIdentity=initialized["codexHome"] as? String ?? CodexStorage.root.path
                try send(["method": "initialized", "params": [:]], context: context)
            }
            return try exchange(method, params: params, context: context)
        } catch let error as CodexClientError {
            // A complete JSON-RPC rejection (for example a deleted mapped
            // thread) does not invalidate a healthy catalog connection.
            if case .rejected = error {throw error}
            close();throw error
        } catch {close();throw error}
    }

    func batchWrite(edits: [[String: Any]], context: OperationContext) throws -> [String: Any] {
        _ = try call("config/read", params: ["includeLayers": false], context: context)
        do {
            return try exchange("config/batchWrite", params: [
                "edits": edits,
                "filePath": JSON.null,
                "expectedVersion": JSON.null,
                "reloadUserConfig": true
            ], context: context, mutation: true)
        } catch {
            close()
            throw error
        }
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
    private func exchange(_ method: String, params: [String: Any], context: OperationContext, mutation: Bool = false) throws -> [String: Any] {
        requestID += 1
        let id = requestID, deadline = Date().addingTimeInterval(20)
        try context.check()
        do { try send(["id": id, "method": method, "params": params], context: context) }
        catch { if mutation { throw CodexClientError.outcomeUnknown }; throw error }
        while true {
            let message: [String: Any]
            do { message = try JSON.object(line(until: deadline, context: context)) }
            catch { if mutation { throw CodexClientError.outcomeUnknown }; throw error }
            guard message["id"] as? Int == id else {
                // Reject unexpected server requests; do not approve or run tools.
                if let request = message["id"], message["method"] != nil {
                    do { try send(["id": request, "error": ["code": -32601, "message": "Catalog client does not execute tools"]], context: context) }
                    catch { if mutation { throw CodexClientError.outcomeUnknown }; throw error }
                }
                continue
            }
            if let error = message["error"] as? [String: Any] {
                if mutation { throw CodexClientError.outcomeUnknown }
                throw CodexClientError.rejected(error["message"] as? String ?? "Codex rejected the catalog request.")
            }
            guard let result = message["result"] as? [String: Any] else {
                if mutation { throw CodexClientError.outcomeUnknown }
                throw CodexClientError.invalid("Invalid Codex catalog response.")
            }
            return result
        }
    }
}
