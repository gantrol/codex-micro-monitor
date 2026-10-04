import CoreFoundation
import Foundation
import MicroCore

/// A headless JSON-RPC transport. Only protocol messages may be written to stdout.
struct MCPServer {
    private let client: CodexClient
    private static let maximumRequestBytes = 1_048_576
    private static let protocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]

    init(client: CodexClient = CodexClient()) {
        self.client = client
    }

    func run() async {
        await serve()
        await client.close()
    }

    private func serve() async {
        var buffer = Data()
        var discardingOversizedLine = false
        do {
            while true {
                let chunk = FileHandle.standardInput.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    if discardingOversizedLine || line.count > Self.maximumRequestBytes {
                        guard write(Self.failure(id: NSNull(), code: -32600, message: "Request exceeds 1 MiB.")) else { return }
                        discardingOversizedLine = false
                    } else if let response = await process(line) {
                        guard write(response) else { return }
                    }
                }
                if buffer.count > Self.maximumRequestBytes {
                    discardingOversizedLine = true
                    buffer.removeAll(keepingCapacity: false)
                } else if discardingOversizedLine {
                    buffer.removeAll(keepingCapacity: false)
                }
            }
            if discardingOversizedLine {
                _ = write(Self.failure(id: NSNull(), code: -32600, message: "Request exceeds 1 MiB."))
            } else if !buffer.isEmpty, let response = await process(buffer) {
                _ = write(response)
            }
        }
    }

    private func process(_ line: Data) async -> [String: Any]? {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed])
        } catch {
            return Self.failure(id: NSNull(), code: -32700, message: "Invalid JSON.")
        }
        guard let request = value as? [String: Any], request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String, !method.isEmpty else {
            return Self.failure(id: NSNull(), code: -32600, message: "Expected a JSON-RPC 2.0 request object.")
        }
        // Notifications, including initialized and cancelled, never receive responses.
        guard let id = request["id"] else { return nil }
        guard id is NSNull || id is String || (id is NSNumber && !Self.isBoolean(id)) else {
            return Self.failure(id: NSNull(), code: -32600, message: "Invalid request ID.")
        }
        do {
            let parameters: [String: Any]
            if let raw = request["params"] {
                guard let object = raw as? [String: Any] else { throw InvalidParameters("Expected named parameters.") }
                parameters = object
            } else {
                parameters = [:]
            }
            let result: [String: Any]
            switch method {
            case "initialize":
                guard let requestedVersion = parameters["protocolVersion"] as? String,
                      parameters["capabilities"] is [String: Any],
                      let info = parameters["clientInfo"] as? [String: Any],
                      info["name"] is String, info["version"] is String else {
                    throw InvalidParameters("initialize requires protocolVersion, capabilities and clientInfo.")
                }
                result = [
                    "protocolVersion": Self.protocolVersions.contains(requestedVersion) ? requestedVersion : Self.protocolVersions.last!,
                    "capabilities": ["tools": [:]] as [String: Any],
                    "serverInfo": ["name": "codex-micro-keypad", "version": Bundle.main.object(forInfoDictionaryKey: "CodexMicroReleaseVersion") as? String ?? "0.3.15-macos-preview.5"],
                    "instructions": "Resolve the exact target chat before controlling it. Read state before stopping or approving a specific request. Never retry a mutation with an unknown outcome. Read get_keypad_capabilities for macOS availability."
                ]
            case "ping":
                result = [:]
            case "tools/list":
                if parameters["cursor"] != nil { throw InvalidParameters("This server does not use pagination cursors.") }
                result = ["tools": Self.tools.map(\.json)]
            case "tools/call":
                result = try await call(parameters)
            default:
                return Self.failure(id: id, code: -32601, message: "Method not found.")
            }
            return ["jsonrpc": "2.0", "id": id, "result": result]
        } catch {
            return Self.failure(id: id, code: -32602, message: error.localizedDescription)
        }
    }

    private func call(_ parameters: [String: Any]) async throws -> [String: Any] {
        guard Set(parameters.keys).isSubset(of: ["name", "arguments", "_meta"]),
              let name = parameters["name"] as? String,
              let tool = Self.tools.first(where: { $0.name == name }) else {
            throw InvalidParameters("Unknown tool or invalid tool parameters.")
        }
        let arguments: [String: Any]
        if let raw = parameters["arguments"] {
            guard let object = raw as? [String: Any] else { throw InvalidParameters("arguments must be an object.") }
            arguments = object
        } else {
            arguments = [:]
        }
        for required in tool.required where arguments[required] == nil {
            throw InvalidParameters("Missing argument: \(required).")
        }
        for (key, value) in arguments {
            guard let field = tool.properties[key] else { throw InvalidParameters("Unknown argument: \(key).") }
            if field["type"] as? String == "boolean" {
                guard Self.isBoolean(value) else { throw InvalidParameters("Invalid boolean argument: \(key).") }
            } else {
                guard let string = value as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw InvalidParameters("Invalid string argument: \(key).")
                }
                if let allowed = field["enum"] as? [String], !allowed.contains(string) {
                    throw InvalidParameters("Invalid argument: \(key).")
                }
            }
        }
        do {
            let result: [String: Any]
            if name == "show_keypad" {
                result = try await showKeypad(threadID: arguments["thread_id"] as? String)
            } else {
                result = try await client.execute(name, arguments: arguments)
            }
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .fragmentsAllowed])
            return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]], "structuredContent": result, "isError": false]
        } catch {
            return ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
        }
    }

    private func showKeypad(threadID: String?) async throws -> [String: Any] {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app", FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Info.plist").path) else {
            throw InvalidParameters("show_keypad requires the packaged Codex Micro Monitor.app. Build it with scripts/package-macos.sh; swift run supports the other MCP tools.")
        }
        var components = URLComponents()
        components.scheme = "codex-micro-monitor"
        components.host = "show"
        if let threadID { components.queryItems = [URLQueryItem(name: "thread", value: threadID)] }
        guard let url = components.url else { throw InvalidParameters("Could not encode the selected thread.") }
        // Opening a URL delivers the target even when Launch Services reuses an existing instance.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", bundle.path, url.absoluteString]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in continuation.resume(returning: process.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        guard status == 0 else { throw InvalidParameters("macOS could not open Codex Micro Monitor (exit \(status)).") }
        var result: [String: Any] = ["launch_requested": true, "platform": "macOS"]
        if let threadID { result["thread_id"] = threadID }
        return result
    }

    private func write(_ response: [String: Any]) -> Bool {
        do {
            var data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
            data.append(0x0A)
            try FileHandle.standardOutput.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    private static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func failure(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private struct InvalidParameters: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private struct Tool {
        let name: String
        let description: String
        let readOnly: Bool
        var properties: [String: [String: Any]] = [:]
        var required: [String] = []

        var json: [String: Any] {
            [
                "name": name, "description": description,
                "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
                "annotations": [
                    "readOnlyHint": readOnly,
                    "destructiveHint": ["stop_keypad_turn", "reply_keypad_approval"].contains(name),
                    "idempotentHint": readOnly || ["show_keypad", "open_keypad_thread", "set_keypad_model", "set_keypad_reasoning", "set_keypad_fast"].contains(name),
                    "openWorldHint": ["send_keypad_message", "reply_keypad_approval"].contains(name)
                ]
            ]
        }
    }

    private static func stringField(_ description: String) -> [String: Any] {
        ["type": "string", "minLength": 1, "description": description]
    }
    private static let thread = stringField("Exact local Codex thread ID.")
    private static var tools: [Tool] {
        definitions.filter { $0.name == "show_keypad" || MacPreviewCapabilities.operations.contains($0.name) }
    }
    private static let definitions: [Tool] = [
        Tool(name: "toggle_keypad_plan", description: "Toggle the exact existing chat between Plan and Default for its next turn. Preserves model, effort and permissions; verifies readback. Never retry an unknown result.", readOnly: false, properties: ["thread_id": thread], required: ["thread_id"]),
        Tool(name: "get_keypad_layout", description: "Read Codex's Micro encoder mode and joystick bindings; does not expose other configuration values or local Mac overrides.", readOnly: true),
        Tool(name: "get_keypad_capabilities", description: "Read implemented macOS controls and unavailable features. This is not full device feature parity.", readOnly: true),
        Tool(name: "show_keypad", description: "Show the native macOS Codex Micro keypad. Optionally select an exact chat. Does not send input. Requires a packaged app.", readOnly: false, properties: ["thread_id": thread]),
        Tool(name: "list_keypad_threads", description: "List recent local Codex chats and their exact IDs.", readOnly: true),
        Tool(name: "get_keypad_models", description: "Read the live Codex model catalog and supported reasoning efforts.", readOnly: true),
        Tool(name: "get_keypad_usage", description: "Read Codex account usage limits. Unavailable values are not zero usage.", readOnly: true),
        Tool(name: "get_keypad_state", description: "Read an open chat's current model, active turn ID, and pending command/file approval requests from its desktop owner.", readOnly: true, properties: ["thread_id": thread], required: ["thread_id"]),
        Tool(name: "open_keypad_thread", description: "Navigate Codex to the requested existing chat using its native deep link.", readOnly: false, properties: ["thread_id": thread], required: ["thread_id"]),
        Tool(name: "new_keypad_thread", description: "Open a new Codex draft. Only when the user requests a new chat. Does not submit a message.", readOnly: false),
        Tool(name: "set_keypad_model", description: "Set the model for the selected chat's next turn, preserving permissions. Read get_keypad_models first.", readOnly: false, properties: ["thread_id": thread, "model": stringField("Catalog model ID."), "effort": stringField("Supported effort; defaults to the model default.")], required: ["thread_id", "model"]),
        Tool(name: "set_keypad_reasoning", description: "Set a supported reasoning effort for the selected chat's next turn.", readOnly: false, properties: ["thread_id": thread, "effort": stringField("Supported reasoning effort.")], required: ["thread_id", "effort"]),
        Tool(name: "set_keypad_fast", description: "Enable or disable Fast service for the selected chat's next turn. May affect usage/cost; only when requested.", readOnly: false, properties: ["thread_id": thread, "enabled": ["type": "boolean"]], required: ["thread_id", "enabled"]),
        Tool(name: "send_keypad_message", description: "Send the user's requested text to an idle selected chat through its existing desktop owner. Do not retry after a timeout.", readOnly: false, properties: ["thread_id": thread, "text": stringField("Exact text requested by the user.")], required: ["thread_id", "text"]),
        Tool(name: "stop_keypad_turn", description: "Stop only the exact active turn the user requested. Read its ID with get_keypad_state first.", readOnly: false, properties: ["thread_id": thread, "turn_id": stringField("Exact active turn ID from get_keypad_state.")], required: ["thread_id", "turn_id"]),
        Tool(name: "reply_keypad_approval", description: "Reply to one current command/file approval with the user's explicit decision. Read the request details with get_keypad_state first. No blanket or future approvals.", readOnly: false, properties: ["thread_id": thread, "request_id": stringField("Exact pending approval ID."), "decision": ["type": "string", "enum": ["accept", "decline"]]], required: ["thread_id", "request_id", "decision"])
    ]
}
