import Foundation

/// The serial worker keeps blocking socket/pipe I/O off the UI and prevents
/// reentrant actor calls from interleaving one operation with another.
public actor CodexClient {
    private let worker = ControlWorker()
    private let queue = DispatchQueue(label: "com.gantrol.micro.control", qos: .userInitiated)
    public init() {}

    public func execute(_ name: String, arguments: [String: Any]) async throws -> [String: Any] {
        let context = OperationContext()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [worker] in
                    do {
                        try context.check()
                        continuation.resume(returning: try worker.execute(name, arguments: arguments, context: context))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { context.cancel() })
    }

    public func close() async {
        await withCheckedContinuation { continuation in
            queue.async { [worker] in worker.catalog.close(); continuation.resume() }
        }
    }
}

private final class ControlWorker: @unchecked Sendable {
    let catalog = CodexCatalog()
    private func models(_ context: OperationContext) throws -> [String: Any] {
        try catalog.call("model/list", params: ["limit": 100], context: context)
    }

    func execute(_ name: String, arguments a: [String: Any], context: OperationContext) throws -> [String: Any] {
        guard MacPreviewCapabilities.operations.contains(name) else {
            throw CodexClientError.unsupported("This operation is unavailable in the macOS preview. Read get_keypad_capabilities for supported operations.")
        }
        switch name {
        case "get_keypad_capabilities": return MacPreviewCapabilities.description
        case "get_keypad_models": return try models(context)
        case "get_keypad_layout":
            let result = try catalog.call("config/read", params: ["includeLayers": false], context: context)
            guard let config = result["config"] as? [String: Any] else { throw CodexClientError.invalid("Missing Codex configuration.") }
            let desktop = config["desktop"] as? [String: Any] ?? [:]
            let layout = desktop["codex-micro-layout"] as? [String: Any] ?? [:]
            // Never return the rest of the user's configuration through this API.
            var analog = ["up": "composer.togglePlanMode", "down": "toggleSidebar", "left": "navigateBack", "right": "navigateForward"]
            if let configured = layout["analogActions"] {
                guard let bindings = configured as? [String: Any] else { throw CodexClientError.invalid("Invalid Micro joystick bindings.") }
                for (key, value) in bindings where analog[key] != nil { analog[key] = value as? String ?? "" }
            }
            return ["encoderMode": layout["encoderMode"] as? String ?? "composer-navigation", "analogActions": analog]
        case "get_keypad_usage": return try catalog.call("account/rateLimits/read", params: [:], context: context)
        case "list_keypad_threads":
            let result = try catalog.call("thread/list", params: ["limit": 100, "sortKey": "recency_at", "sortDirection": "desc", "useStateDbOnly": true], context: context)
            guard let rows = result["data"] as? [[String: Any]] else { throw CodexClientError.invalid("Missing Codex thread list.") }
            return ["threads": rows.map { row -> [String: Any] in
                ["id": row["id"] ?? JSON.null, "title": row["name"] ?? row["preview"] ?? "",
                 "cwd": row["cwd"] ?? "", "status": row["status"] ?? ["type": "unknown"]]
            }]
        case "new_keypad_thread":
            try context.check()
            try Self.open("codex://threads/new", context: context)
            return ["launch_requested": true]
        default: break
        }
        let thread = try JSON.required(a, "thread_id")
        guard UUID(uuidString: thread) != nil else { throw CodexClientError.invalid("Expected an exact local Codex thread UUID.") }
        if name == "open_keypad_thread" {
            try context.check()
            try Self.open("codex://threads/" + thread, context: context)
            return ["launch_requested": true, "threadId": thread]
        }
        if name == "fork_keypad_thread" {
            throw CodexClientError.unsupported("Fork is not enabled on macOS: the installed app-server schema does not expose deferred goal continuation. Fork in Codex instead.")
        }
        let supported = ["get_keypad_state", "set_keypad_model", "set_keypad_reasoning", "set_keypad_fast",
                         "send_keypad_message", "stop_keypad_turn", "reply_keypad_approval", "toggle_keypad_plan"]
        guard supported.contains(name) else { throw CodexClientError.unsupported("Unsupported keypad operation: \(name)") }
        let peer = try DesktopPeer(context: context)
        defer { peer.close() }
        let owner = try peer.owner(of: thread)
        let state = try peer.snapshot(thread, owner: owner)
        if name == "get_keypad_state" { return Self.project(thread, state) }

        func validateOwner() throws {
            try context.check()
            guard try peer.owner(of: thread) == owner else { throw CodexClientError.staleTarget }
        }
        if ["set_keypad_model", "set_keypad_reasoning", "set_keypad_fast", "toggle_keypad_plan"].contains(name) {
            let current = Self.project(thread, state)
            if let expected = a["expected_settings"] as? [String: Any],
               !expected.allSatisfy({ JSON.same(current[$0.key], $0.value) }) {
                throw CodexClientError.staleTarget
            }
            let model = current["model"] as? String
            let definitions = try models(context)["data"] as? [[String: Any]] ?? []
            var settings: [String: Any] = [:]
            if name == "toggle_keypad_plan" {
                let mode = (current["collaborationMode"] as? [String: Any])?["mode"] as? String
                guard ["plan", "default"].contains(mode ?? ""), let model, !model.isEmpty else {
                    throw CodexClientError.unsupported("The observed collaboration mode cannot be toggled.")
                }
                let next = mode == "plan" ? "default" : "plan"
                let modes = try catalog.call("collaborationMode/list", params: [:], context: context)["data"] as? [[String: Any]] ?? []
                guard modes.contains(where: { $0["mode"] as? String == next }) else {
                    throw CodexClientError.unsupported("The target collaboration mode is unavailable.")
                }
                // Match the desktop picker: null selects the new mode's default
                // instructions, rather than carrying Default instructions into Plan.
                settings["collaborationMode"] = ["mode": next, "settings": [
                    "model": model, "reasoning_effort": current["effort"] ?? JSON.null,
                    "developer_instructions": JSON.null] as [String: Any]]
            } else if name == "set_keypad_fast" {
                guard let enabled = a["enabled"] as? Bool else { throw CodexClientError.invalid("Missing Fast selection.") }
                if enabled {
                    guard let definition = definitions.first(where: { $0["model"] as? String == model }),
                          let tier = Self.fastTier(definition) else { throw CodexClientError.unsupported("Fast is unavailable for the selected model.") }
                    settings["serviceTier"] = tier
                } else { settings["serviceTier"] = JSON.null }
            } else {
                let requestedModel = name == "set_keypad_model" ? try JSON.required(a, "model") : model ?? ""
                guard let definition = definitions.first(where: { $0["model"] as? String == requestedModel }) else {
                    throw CodexClientError.invalid("The model is not in the current Codex catalog.")
                }
                let requestedEffort = name == "set_keypad_reasoning" ? try JSON.required(a, "effort")
                    : a["effort"] as? String ?? definition["defaultReasoningEffort"] as? String ?? ""
                let efforts = definition["supportedReasoningEfforts"] as? [[String: Any]] ?? []
                guard efforts.contains(where: { $0["reasoningEffort"] as? String == requestedEffort }) else {
                    throw CodexClientError.invalid("Unsupported reasoning effort for this model.")
                }
                if name == "set_keypad_model" {
                    settings["model"] = requestedModel
                    if ["fast", "priority"].contains(current["serviceTier"] as? String ?? "") {
                        settings["serviceTier"] = Self.fastTier(definition) ?? JSON.null as Any
                    }
                }
                settings["effort"] = requestedEffort
            }
            var condition: [String: Any] = [:]
            if let value = state["latestModel"] { condition["ifModelEquals"] = value }
            if let value = state["latestReasoningEffort"] { condition["ifEffortEquals"] = value }
            try validateOwner()
            // Catalog reads can take time. Revalidate all observed settings
            // before dispatch; the desktop's atomic condition covers model/effort.
            let beforeWrite = Self.project(thread, try peer.snapshot(thread, owner: owner))
            guard ["model", "effort", "serviceTier", "collaborationMode"].allSatisfy({ JSON.same(beforeWrite[$0], current[$0]) }) else {
                throw CodexClientError.staleTarget
            }
            if let deadline = a["input_deadline_uptime"] as? Double {
                guard deadline.isFinite, ProcessInfo.processInfo.systemUptime <= deadline else {
                    throw CodexClientError.invalid("The dial input expired before dispatch. Turn the dial again.")
                }
            }
            let response = try peer.request("thread-follower-update-thread-settings", version: 2,
                params: ["conversationId": thread, "threadSettings": settings, "condition": condition], target: owner, mutation: true)
            guard (response["result"] as? [String: Any])?["applied"] as? Bool == true else { throw CodexClientError.staleTarget }
            // A transport acknowledgement alone does not confirm the readback.
            do {
                try validateOwner()
                let observed = Self.project(thread, try peer.snapshot(thread, owner: owner))
                guard settings.allSatisfy({ JSON.same(observed[$0.key], $0.value) }) else { throw CodexClientError.outcomeUnknown }
                return ["applied": true, "verified": true, "threadId": thread, "settings": settings, "state": observed]
            } catch { throw CodexClientError.outcomeUnknown }
        }
        if name == "send_keypad_message" {
            let text = try JSON.required(a, "text")
            guard text.count <= 100_000 else { throw CodexClientError.invalid("Message exceeds 100,000 characters.") }
            let submissions = state["unconfirmedTurnSubmissions"] as? [[String: Any]] ?? []
            guard Self.activeTurn(state) == nil,
                  (state["threadRuntimeStatus"] as? [String: Any])?["type"] as? String == "idle",
                  submissions.allSatisfy({ $0["terminal"] as? Bool == true }) else {
                throw CodexClientError.invalid("The selected chat has an active or unconfirmed turn.")
            }
            try validateOwner()
            let result = try peer.request("thread-follower-start-turn", version: 2, params: [
                "conversationId": thread,
                "turnStart": ["request": ["threadId": thread, "input": [["type": "text", "text": text, "text_elements": []] as [String: Any]], "clientUserMessageId": UUID().uuidString],
                              "context": ["inheritThreadSettings": true]] as [String: Any]
            ], target: owner, mutation: true)
            guard let reply = result["result"] as? [String: Any], let outcome = reply["result"] else {
                throw CodexClientError.outcomeUnknown
            }
            return ["acknowledged": true, "verified": false, "threadId": thread, "result": outcome]
        }
        if name == "stop_keypad_turn" {
            let turn = try JSON.required(a, "turn_id")
            guard Self.activeTurn(state) == turn else { throw CodexClientError.staleTarget }
            try validateOwner()
            let result = try peer.request("thread-follower-interrupt-turn", version: 4,
                params: ["conversationId": thread, "mode": "user-stop", "expectedTurnId": turn], target: owner, mutation: true)
            guard let reply = result["result"] as? [String: Any], reply["ok"] as? Bool == true,
                  reply["interruptedTurnId"] as? String == turn else { throw CodexClientError.outcomeUnknown }
            do {
                try validateOwner()
                let observed = try peer.snapshot(thread, owner: owner)
                let idle = (observed["threadRuntimeStatus"] as? [String: Any])?["type"] as? String == "idle"
                guard Self.activeTurn(observed) != turn, idle || Self.terminalTurn(turn, in: observed) else {
                    throw CodexClientError.outcomeUnknown
                }
                var confirmed = reply
                confirmed["verified"] = true; confirmed["threadId"] = thread
                return confirmed
            } catch { throw CodexClientError.outcomeUnknown }
        }
        let request = try JSON.required(a, "request_id"), decision = try JSON.required(a, "decision")
        guard ["accept", "decline"].contains(decision) else { throw CodexClientError.invalid("Invalid approval decision.") }
        let pending = state["requests"] as? [[String: Any]] ?? []
        guard let item = pending.first(where: { Self.requestID($0) == request }), let rawID = item["id"] else { throw CodexClientError.staleTarget }
        if let expected = a["expected_request"] as? [String: Any] {
            guard JSON.same(expected["method"], item["method"]), JSON.same(expected["details"], item["params"] ?? [:]) else {
                throw CodexClientError.staleTarget
            }
        }
        let methods = ["item/commandExecution/requestApproval": "thread-follower-command-approval-decision",
                       "item/fileChange/requestApproval": "thread-follower-file-approval-decision"]
        guard let method = methods[item["method"] as? String ?? ""] else { throw CodexClientError.unsupported("Handle this request type in Codex.") }
        try validateOwner()
        let response = try peer.request(method, version: 1,
            params: ["conversationId": thread, "requestId": rawID, "decision": decision], target: owner, mutation: true)
        guard (response["result"] as? [String: Any])?["ok"] as? Bool == true else { throw CodexClientError.outcomeUnknown }
        do {
            try validateOwner()
            guard let remaining = try peer.snapshot(thread, owner: owner)["requests"] as? [[String: Any]] else {
                throw CodexClientError.outcomeUnknown
            }
            guard !remaining.contains(where: { Self.requestID($0) == request }) else { throw CodexClientError.outcomeUnknown }
            return ["acknowledged": true, "verified": true, "threadId": thread, "requestId": request]
        } catch { throw CodexClientError.outcomeUnknown }
    }

    private static func open(_ uri: String, context: OperationContext) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [uri]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try context.check()
        try process.run()
        let deadline = Date().addingTimeInterval(4)
        while process.isRunning {
            if Date() > deadline { process.terminate(); throw CodexClientError.outcomeUnknown }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard process.terminationStatus == 0 else { throw CodexClientError.unavailable("macOS could not open Codex. Install and open the Codex desktop app first.") }
    }

    private static func fastTier(_ definition: [String: Any]) -> String? {
        let tiers = definition["serviceTiers"] as? [[String: Any]] ?? []
        if let tier = tiers.first(where: { ["fast", "priority"].contains($0["id"] as? String ?? "") }) { return tier["id"] as? String }
        return (definition["additionalSpeedTiers"] as? [String] ?? []).contains("fast") ? "fast" : nil
    }
    private static func requestID(_ request: [String: Any]) -> String? {
        if let id = request["id"] as? String { return id }
        if let id = request["id"] as? NSNumber { return id.stringValue }
        return nil
    }
    private static func activeTurn(_ state: [String: Any]) -> String? {
        func find(_ node: Any?, depth: Int = 0) -> String? {
            guard depth < 30 else { return nil }
            if let object = node as? [String: Any] {
                if object["status"] as? String == "inProgress", let id = object["turnId"] as? String { return id }
                for child in object.values { if let found = find(child, depth: depth + 1) { return found } }
            } else if let array = node as? [Any] {
                for child in array.reversed() { if let found = find(child, depth: depth + 1) { return found } }
            }
            return nil
        }
        return find(state["turnHistory"]) ?? find(state["turns"])
    }
    private static func terminalTurn(_ id: String, in state: [String: Any]) -> Bool {
        func find(_ node: Any?, depth: Int = 0) -> Bool {
            guard depth < 30 else { return false }
            if let object = node as? [String: Any] {
                if object["turnId"] as? String == id {
                    return ["completed", "interrupted", "failed"].contains(object["status"] as? String ?? "")
                }
                return object.values.contains { find($0, depth: depth + 1) }
            }
            if let array = node as? [Any] { return array.contains { find($0, depth: depth + 1) } }
            return false
        }
        return find(state["turnHistory"]) || find(state["turns"])
    }
    private static func project(_ thread: String, _ state: [String: Any]) -> [String: Any] {
        let settings = state["latestThreadSettings"] as? [String: Any] ?? [:]
        let requests = state["requests"] as? [[String: Any]] ?? []
        return ["threadId": thread, "title": state["title"] ?? "",
            "model": settings["model"] ?? state["latestModel"] ?? JSON.null,
            "effort": settings["effort"] ?? state["latestReasoningEffort"] ?? JSON.null,
            "serviceTier": settings["serviceTier"] ?? JSON.null,
            "collaborationMode": settings["collaborationMode"] ?? state["latestCollaborationMode"] ?? JSON.null,
            "activeTurnId": activeTurn(state) ?? JSON.null as Any,
            "runtimeStatus": state["threadRuntimeStatus"] ?? JSON.null,
            "hasUnreadTurn": state["hasUnreadTurn"] ?? JSON.null,
            "hasPendingQuestion": requests.contains { $0["method"] as? String == "item/tool/requestUserInput" },
            "approvals": requests.filter { ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"].contains($0["method"] as? String ?? "") }
                .compactMap { item -> [String: Any]? in
                    guard let id = requestID(item) else { return nil }
                    return ["id": id, "method": item["method"] ?? "", "details": item["params"] ?? [:]]
                }]
    }
}
