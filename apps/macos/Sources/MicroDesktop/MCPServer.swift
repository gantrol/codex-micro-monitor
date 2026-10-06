import CoreFoundation
import Foundation
import MicroCore
import MicroShared

/// A headless JSON-RPC transport. Only protocol messages may be written to stdout.
struct MCPServer {
    private let client: DesktopBackend
    private static let maximumRequestBytes = 1_048_576
    private static let protocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]

    init(client: DesktopBackend = DesktopBackend()) {
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
                    "serverInfo": ["name": "codex-micro-keypad", "version": Bundle.main.object(forInfoDictionaryKey: "CodexMicroReleaseVersion") as? String ?? "1.0.0-macos-preview.33"],
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
            } else if field["type"] as? String == "array" {
                guard (field["items"] as? [String:Any])?["type"] as? String == "string",
                      let values=value as? [String],let maximum=field["maxItems"] as? Int,values.count <= maximum,
                      values.allSatisfy({!$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}) else {
                    throw InvalidParameters("Invalid string-array argument: \(key).")
                }
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
                    "destructiveHint": ["stop_keypad_turn", "reply_keypad_approval", "archive_keypad_thread"].contains(name),
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
    private static let targetToken = stringField("Fresh targetToken from get_keypad_ui_state in this MCP process. Expires after 15 seconds; never reuse after the target changes.")
    private static var tools: [Tool] {
        definitions.filter { $0.name == "show_keypad" || MacPreviewCapabilities.operations.contains($0.name) || MacUIController.operations.contains($0.name) }
    }
    private static let nativeComposer: [String: Any] = ["type":"boolean", "description":"Set true only when get_keypad_ui_state returned nativeComposer=true: the exact native composer has either a matching clientThreadId and client route or an unambiguous ID-less sidebar selection. This identity supports native settings only and is not a server UUID or proof of an unsent draft. The fresh target token and identity are checked again at dispatch. Defaults to false for confirmed blank drafts."]
    private static let definitions: [Tool] = [
        Tool(name: "get_keypad_activity", description: "Read compact live activity and its revision after list_keypad_threads starts observation. No chat content is returned.", readOnly: true),
        Tool(name: "get_keypad_client_thread", description: "Resolve an exact local client route identity to a stored chat UUID using persisted renderer bindings and an exact local thread read. Requires the previously observed rosterScope. Rechecks account, storage and binding after lookup. Unresolved does not imply an unsent draft. This read does not grant native control or send messages.", readOnly: true,
             properties:["client_thread_id":stringField("Exact client-new-thread:UUID from the current local route."),"roster_scope":stringField("Previously observed rosterScope.")],required:["client_thread_id","roster_scope"]),
        Tool(name: "get_keypad_ui_state", description: "Observe the current native Codex window and exact composer identity, including while another application is foreground. Requires macOS Accessibility permission. Returns an expiring target token, never composer contents. Mutations separately recheck focus and the exact target. Read get_keypad_models first for draft settings and list_keypad_threads for account-scoped client/server alias verification. An unresolved clientBindingCandidate and bindingObservationToken are not control authorization. A verified alias remains native settings only.", readOnly: true),
        Tool(name: "submit_keypad_composer", description: "Submit the user's current native draft only when explicitly requested. Rechecks composer identity and idle chat state. Never retry an unknown result.", readOnly: false, properties: ["target_token": targetToken], required: ["target_token"]),
        Tool(name: "navigate_keypad_ui", description: "Operate an explicitly observed native composer/window and read back the result. Uses the exact target token; does not guess coordinates.", readOnly: false, properties: ["target_token": targetToken, "action": ["type":"string", "enum":["sidebar","back","forward","composer-next","composer-previous","composer-activate","scroll-up","scroll-down","scroll-bottom"]]], required: ["target_token","action"]),
        Tool(name: "insert_keypad_skill", description: "Insert a requested skill mention into the current composer through guarded HTML clipboard paste. Preserves a concurrent user copy. Visible text alone does not confirm mention structure; never auto-retry.", readOnly: false, properties: ["target_token": targetToken, "name": stringField("Exact skill name."), "path": stringField("Absolute path to its existing SKILL.md.")], required: ["target_token","name","path"]),
        Tool(name: "open_keypad_sketch", description: "Open Sketch from the exact composer's add menu; success requires observing the sketch editor.", readOnly: false, properties: ["target_token": targetToken], required: ["target_token"]),
        Tool(name: "set_keypad_draft_model", description: "Choose a catalog model in an observed blank draft or confirmed ID-less composer's native picker. Optional effort uses observed native Power controls and verified readback. Preserves draft text and permissions.", readOnly: false, properties: ["native_composer":nativeComposer,"target_token": targetToken,"model": stringField("Current catalog model ID."),"effort": stringField("Supported effort.")], required: ["target_token","model"]),
        Tool(name: "set_keypad_draft_reasoning", description: "Set supported effort in the blank draft or explicitly confirmed ID-less composer through validated native Power controls, with readback.", readOnly: false, properties: ["native_composer":nativeComposer,"target_token": targetToken,"effort": stringField("Supported effort.")], required: ["target_token","effort"]),
        Tool(name: "set_keypad_draft_fast", description: "Set Fast in the blank draft or explicitly confirmed ID-less composer only when requested. Uses the observed native Speed menu or a configured speed shortcut. May affect usage/cost.", readOnly: false, properties: ["native_composer":nativeComposer,"target_token": targetToken,"enabled": ["type":"boolean"]], required: ["target_token","enabled"]),
        Tool(name: "toggle_keypad_draft_plan", description: "Toggle Plan for the blank draft or explicitly confirmed ID-less composer using its observed native Plan control or a configured shortcut, and verify the mode.", readOnly: false, properties: ["native_composer":nativeComposer,"target_token": targetToken], required: ["target_token"]),
        Tool(name: "toggle_keypad_dictation", description: "Start or stop native Codex dictation only when explicitly requested. Requires an observed native dictation control and the app's microphone permission.", readOnly: false, properties: ["target_token": targetToken], required: ["target_token"]),
        Tool(name: "toggle_keypad_plan", description: "Toggle the exact existing chat between Plan and Default for its next turn. Preserves model, effort and permissions; verifies readback. Never retry an unknown result.", readOnly: false, properties: ["thread_id": thread], required: ["thread_id"]),
        Tool(name: "get_keypad_layout", description: "Read Codex's Micro encoder mode and joystick bindings; does not expose other configuration values or local Mac overrides.", readOnly: true),
        Tool(name: "get_keypad_capabilities", description: "Read implemented macOS controls and unavailable features. This is not full device feature parity.", readOnly: true),
        Tool(name: "show_keypad", description: "Show the native macOS Codex Micro keypad. Optionally select an exact chat. Does not send input. Requires a packaged app.", readOnly: false, properties: ["thread_id": thread]),
        Tool(name: "list_keypad_threads", description: "List recent local Codex chats and their exact IDs. Returns a stable account/host/storage rosterScope. Optionally resolve up to 14 mapped exact IDs using that same scope, including older stored chats outside the recent page. Missing mapped chats stay unavailable. include_pinned returns up to 14 local modern pinned chats and pinned-project members, using exact server project membership and saved sidebar placement. Manual and recency order, project-ID migration aliases and duplicate exclusion are supported. Unsupported or incomplete required catalogs stay unavailable; no legacy pin migration or writes occur. include_priority reads the complete local interactive catalog across pages for attention ranking (waiting, unread, active, idle then recency); incomplete catalogs fail instead of returning a partial ranking. No navigation or messages are sent.", readOnly: true,
             properties:["include_priority":["type":"boolean"],"include_pinned":["type":"boolean"],"roster_scope":stringField("The previously observed rosterScope; mappings are ignored if the account or storage changed."),
                         "mapped_thread_ids":["type":"array","maxItems":14,"items":["type":"string"]]]),
        Tool(name: "get_keypad_models", description: "Read the live Codex model catalog and supported reasoning efforts.", readOnly: true),
        Tool(name: "get_keypad_usage", description: "Read Codex account usage limits. Unavailable values are not zero usage.", readOnly: true),
        Tool(name: "get_keypad_state", description: "Read an open chat's current model, active turn ID, and pending command/file approval requests from its desktop owner.", readOnly: true, properties: ["thread_id": thread], required: ["thread_id"]),
        Tool(name: "mark_keypad_unread", description: "Mark an exact local chat unread, scoped to the current account and host. Success requires persisted readback. Never retry an unknown outcome.", readOnly: false, properties: ["thread_id":thread], required: ["thread_id"]),
        Tool(name: "open_keypad_thread", description: "Navigate Codex to the requested existing chat using its native deep link.", readOnly: false, properties: ["thread_id": thread], required: ["thread_id"]),
        Tool(name: "open_keypad_review", description: "Request the Review panel for an exact existing local chat. Validates the stored target; reports a launch request, not verified foreground navigation.", readOnly: false, properties: ["thread_id": thread], required: ["thread_id"]),
        Tool(name: "get_keypad_folder", description: "Read the project folder from an exact stored local thread record. Does not open Finder.", readOnly: true, properties: ["thread_id": thread], required: ["thread_id"]),
        Tool(name: "open_keypad_folder", description: "Open the exact chat's existing local project folder in Finder. Reports macOS launch acceptance, not a claim about folder contents.", readOnly: false, properties: ["thread_id": thread], required: ["thread_id"]),
        Tool(name: "open_keypad_developer_site", description: "Open the fixed OpenAI developer website in the default browser. Requires no chat ID; reports macOS launch acceptance.", readOnly: false),
        Tool(name: "open_keypad_settings", description: "Open Codex settings or the Micro settings section using a fixed native deep link. Separately reports launch acceptance and observed page navigation. Does not change any settings.", readOnly: false, properties:["section":["type":"string","enum":["codex-micro"]]]),
        Tool(name: "open_keypad_skills", description: "Open Codex's Skills page using its fixed native deep link. Separately reports launch acceptance and observed page navigation. Does not install or remove skills.", readOnly: false),
        Tool(name: "open_keypad_tasks", description: "Open Codex's scheduled tasks management page using its native deep link. Separately reports launch acceptance and exact page readback. Does not create, run or change tasks.", readOnly: false),
        Tool(name: "open_keypad_browser", description: "Open a new browser tab inside the exact foreground Codex chat using its native application menu. Requires a new visible browser panel and preserves the chat target. Does not launch an external browser or navigate to a URL.", readOnly: false, properties:["thread_id":thread,"target_token":targetToken],required:["thread_id","target_token"]),
        Tool(name: "run_keypad_environment_action", description: "Run the exact foreground chat's first platform-applicable configured environment action only when requested. Uses the unfiltered native Project command group, not the most-recently-used Run button. Verifies the matching environmentAction1 terminal handoff; executionVerified=false means no shell exit status or successful script completion is claimed. Never retries or types shell commands.", readOnly: false, properties:["thread_id":thread,"target_token":targetToken],required:["thread_id","target_token"]),
        Tool(name: "open_keypad_merge_pull_request", description: "Open the exact foreground chat's native Merge PR confirmation through the unique Project command group. Verifies the specific merge confirmation and its displayed method. Never changes the method or presses the final merge button. workflowStage=mergeConfirmation; mergeCompleted=false; pullRequestIdentityVerified=false because the form exposes no verified PR number. Do not infer a PR ID from the opaque panel ID.", readOnly: false, properties:["thread_id":thread,"target_token":targetToken],required:["thread_id","target_token"]),
        Tool(name: "open_keypad_commit", description: "Open the exact foreground chat's native Commit or push workflow through its command menu. Verifies either the three-choice commit/push form or the prerequisite Work here branch form and returns workflowStage. Never selects commit, push, branch creation, form options or submits. mutationCompleted=false.", readOnly: false, properties:["thread_id":thread,"target_token":targetToken],required:["thread_id","target_token"]),
        Tool(name: "open_keypad_branch", description: "Open Codex's native branch creation form for the exact foreground chat via its command menu. Verifies the specific form; does not enter values, create a branch or PR, commit, push, or submit the form. Workflow opening and repository mutation are separate.", readOnly: false, properties:["thread_id":thread,"target_token":targetToken],required:["thread_id","target_token"]),
        Tool(name: "open_keypad_pull_request", description: "Open Codex's native regular PR workflow for the exact foreground chat via its command menu. Returns workflowStage=branchSetup and prDefaultVerified=false if Codex first requires a branch; otherwise verifies the regular PR default. Does not enter values, create a branch or PR, commit, push, or submit.", readOnly: false, properties:["thread_id":thread,"target_token":targetToken],required:["thread_id","target_token"]),
        Tool(name: "open_keypad_draft_pull_request", description: "Open Codex's native draft PR workflow for the exact foreground chat via its command menu. Returns workflowStage=branchSetup and prDefaultVerified=false if Codex first requires a branch; otherwise verifies the draft PR default. Does not enter values, create a branch or PR, commit, push, or submit.", readOnly: false, properties:["thread_id":thread,"target_token":targetToken],required:["thread_id","target_token"]),
        Tool(name: "open_keypad_feedback", description: "Open Codex's native feedback form for the observed window. Requires a current UI token and verifies the specific dialog. Does not select feedback categories, change consent options, type details or submit feedback.", readOnly: false, properties:["target_token":targetToken],required:["target_token"]),
        Tool(name: "insert_keypad_preset_text", description: "Write the requested YOLO or YEET preset (:yolo: or :yeet:) into the exact native composer at its observed caret or selection. Does not send a message, change permissions or use the clipboard. Requires exact UTF-16 selection and text/caret readback. Unknown input outcomes are never replayed.", readOnly: false, properties:["preset":["type":"string","enum":ComposerTextPreset.allCases.map(\.rawValue)],"target_token":targetToken],required:["preset","target_token"]),
        Tool(name: "open_keypad_photos", description: "Open the exact composer's dedicated Select photos picker. Uses its observed Add photos menu item or an explicitly configured native composer.addPhotos command shortcut, rechecked before input. No guessed shortcut and no general-files fallback. Requires a new unique native photos dialog. Reports imagesOnlyRequested=true, awaitingSelection=true, attachmentVerified=false; never selects a file or submits a message.", readOnly: false, properties:["target_token":targetToken],required:["target_token"]),
        Tool(name: "open_keypad_files", description: "Open Codex's native Files and folders picker for the observed chat or blank draft. Verifies a newly opened Select files dialog in the same application. Reports awaitingSelection, not attachment completion. Does not choose, read, attach or submit files automatically.", readOnly: false, properties:["target_token":targetToken],required:["target_token"]),
        Tool(name: "open_keypad_side_chat", description: "Create a side chat from the exact foreground local chat only when requested, through its native Chat actions menu. Requires a new visible side-chat panel with a ready composer; does not send a message or infer the child thread ID.", readOnly: false, properties:["thread_id":thread,"target_token":targetToken],required:["thread_id","target_token"]),
        Tool(name: "toggle_keypad_pin", description: "Toggle pin for the exact foreground local chat through its native Chat actions menu. Reopens the menu to verify the opposite action. Requires a current UI target token.", readOnly: false, properties:["thread_id":thread,"target_token":targetToken],required:["thread_id","target_token"]),
        Tool(name: "copy_keypad_markdown", description: "Copy the exact foreground chat as Markdown using Codex's own menu. Requires its fresh success notification and a single clipboard update. Returns only confirmation and character count, never clipboard contents.", readOnly: false, properties:["thread_id":thread,"target_token":targetToken],required:["thread_id","target_token"]),
        Tool(name: "get_keypad_archive_state", description: "Read archive status for an exact stored local chat. A bounded archived-list search reports unknown when incomplete.", readOnly: true, properties:["thread_id":thread],required:["thread_id"]),
        Tool(name: "toggle_keypad_terminal", description: "Toggle Codex's terminal panel for the exact foreground local chat via its native application menu. Verifies the terminal view changed; never launches a different terminal app or types a command.", readOnly: false, properties:["thread_id":thread,"target_token":targetToken],required:["thread_id","target_token"]),
        Tool(name: "archive_keypad_thread", description: "Request archive of the exact foreground local chat through Codex's native menu. Leaves any confirmation to the user; success requires exact archived-list readback. Never retry an unknown result.", readOnly: false, properties:["thread_id":thread,"target_token":targetToken],required:["thread_id","target_token"]),
        Tool(name: "fork_keypad_thread", description: "Fork the exact local chat only when the user requests it. Requires a CLI schema that defers goal continuation. Returns the new ID even if opening fails; never repeat a fork after an unknown outcome.", readOnly: false, properties: ["thread_id": thread], required: ["thread_id"]),
        Tool(name: "new_keypad_thread", description: "Open a new Codex draft. Only when the user requests a new chat. Does not submit a message. launch_requested is not navigation confirmation. Only navigation_verified with a confirmed draft foreground authorizes the new draft context. Retire the previous thread ID immediately; do not restore it from stale IPC visibility while waiting.", readOnly: false),
        Tool(name: "set_keypad_model", description: "Set the model for the selected chat's next turn, preserving permissions. Read get_keypad_models first.", readOnly: false, properties: ["thread_id": thread, "model": stringField("Catalog model ID."), "effort": stringField("Supported effort; defaults to the model default.")], required: ["thread_id", "model"]),
        Tool(name: "set_keypad_reasoning", description: "Set a supported reasoning effort for the selected chat's next turn.", readOnly: false, properties: ["thread_id": thread, "effort": stringField("Supported reasoning effort.")], required: ["thread_id", "effort"]),
        Tool(name: "set_keypad_fast", description: "Enable or disable Fast service for the selected chat's next turn. May affect usage/cost; only when requested.", readOnly: false, properties: ["thread_id": thread, "enabled": ["type": "boolean"]], required: ["thread_id", "enabled"]),
        Tool(name: "send_keypad_message", description: "Send the user's requested text to an idle selected chat through its existing desktop owner. Do not retry after a timeout.", readOnly: false, properties: ["thread_id": thread, "text": stringField("Exact text requested by the user.")], required: ["thread_id", "text"]),
        Tool(name: "stop_keypad_turn", description: "Stop only the exact active turn the user requested. Read its ID with get_keypad_state first.", readOnly: false, properties: ["thread_id": thread, "turn_id": stringField("Exact active turn ID from get_keypad_state.")], required: ["thread_id", "turn_id"]),
        Tool(name: "reply_keypad_approval", description: "Reply to one current command/file approval with the user's explicit decision. Read the request details with get_keypad_state first. No blanket or future approvals.", readOnly: false, properties: ["thread_id": thread, "request_id": stringField("Exact pending approval ID."), "decision": ["type": "string", "enum": ["accept", "decline"]]], required: ["thread_id", "request_id", "decision"])
    ]
}
