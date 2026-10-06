import Foundation
import MicroShared

public struct DraftConfigurationSnapshot: Equatable, Sendable {
    public let model: String?
    public let effort: String?
    public let encoderMode: String?

    public init(model: String?, effort: String?, encoderMode: String?) {
        self.model = model
        self.effort = effort
        self.encoderMode = encoderMode
    }
}

/// The serial worker keeps blocking socket/pipe I/O off the UI and prevents
/// reentrant actor calls from interleaving one operation with another.
public actor CodexClient {
    private let worker: ControlWorker
    private let activity: ActivityMonitor
    private let queue = DispatchQueue(label: "com.gantrol.micro.control", qos: .userInitiated)
    public init() { let activity = ActivityMonitor(); self.activity = activity; worker = ControlWorker(activity: activity) }

    public func execute(_ name: String, arguments: [String: Any]) async throws -> [String: Any] {
        if name == "get_keypad_activity" {
            try Task.checkCancellation()
            return await activity.read(thread:arguments["thread_id"] as? String)
        }
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
        activity.close()
        await withCheckedContinuation { continuation in
            queue.async { [worker] in worker.close(); continuation.resume() }
        }
    }

    public func captureDraftConfiguration() async throws -> DraftConfigurationSnapshot? {
        let context = OperationContext()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [worker] in
                    do {
                        try context.check()
                        continuation.resume(returning: try worker.captureDraftConfiguration(context: context))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { context.cancel() })
    }

    public func readDraftConfiguration() async throws -> DraftConfigurationSnapshot {
        let context = OperationContext()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [worker] in
                    do {
                        try context.check()
                        continuation.resume(returning: try worker.readDraftConfiguration(context: context))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { context.cancel() })
    }

    public func writeDraftConfiguration(_ value: DraftConfigurationSnapshot) async throws -> Bool {
        let context = OperationContext()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [worker] in
                    do {
                        try context.check()
                        continuation.resume(returning: try worker.writeDraftConfiguration(value, context: context))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { context.cancel() })
    }

    public func invalidateUserSavedConfig() async throws -> Bool {
        let context = OperationContext()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [worker] in
                    do {
                        try context.check()
                        continuation.resume(returning: try worker.invalidateUserSavedConfig(context: context))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { context.cancel() })
    }
}

private final class ControlWorker: @unchecked Sendable {
    private let activity: ActivityMonitor
    init(activity: ActivityMonitor) { self.activity = activity }
    let catalog = CodexCatalog()
    private let rollouts = RolloutReader()
    private var paths: [String: String] = [:]
    private var observationGeneration: String?
    private var pinnedScope:String?,pinnedContext:String?
    private var pinnedProjectOrders:[String:[String]]=[:]
    func close() { catalog.close(); activity.close(); rollouts.reset(); paths.removeAll(); observationGeneration = nil;pinnedScope=nil;pinnedContext=nil;pinnedProjectOrders=[:] }
    private func models(_ context: OperationContext) throws -> [String: Any] {
        var data: [[String: Any]] = [], cursor: String?, seen: Set<String> = []
        var generation: String?
        for _ in 0..<10 {
            var params: [String: Any] = ["limit": 100]
            if let cursor { params["cursor"] = cursor }
            let page = try catalog.call("model/list", params: params, context: context)
            if let generation, generation != catalog.generation { throw CodexClientError.staleTarget }
            generation = catalog.generation
            guard let rows = page["data"] as? [[String: Any]] else { throw CodexClientError.invalid("Missing Codex model catalog.") }
            data += rows.filter { $0["hidden"] as? Bool != true }
            guard let next = page["nextCursor"] as? String, !next.isEmpty else {
                try catalog.assertStorageCurrent()
                return ["data": data, "nextCursor": JSON.null]
            }
            guard seen.insert(next).inserted else { throw CodexClientError.invalid("Repeated Codex model catalog cursor.") }
            cursor = next
        }
        throw CodexClientError.invalid("Codex model catalog exceeds the page limit.")
    }

    func readDraftConfiguration(context: OperationContext) throws -> DraftConfigurationSnapshot {
        let result = try catalog.call("config/read", params: ["includeLayers": false], context: context)
        guard let config = result["config"] as? [String: Any] else {
            throw CodexClientError.invalid("Missing Codex configuration.")
        }
        let desktop = config["desktop"] as? [String: Any]
        let layout = desktop?["codex-micro-layout"] as? [String: Any]
        return .init(
            model: config["model"] as? String,
            effort: config["model_reasoning_effort"] as? String,
            encoderMode: layout?["encoderMode"] as? String)
    }

    func captureDraftConfiguration(context: OperationContext) throws -> DraftConfigurationSnapshot {
        let requirements = try catalog.call("configRequirements/read", params: [:], context: context)
        guard let rawRequirements = requirements["requirements"] else {
            throw CodexClientError.invalid("Missing Codex configuration requirements.")
        }
        if !(rawRequirements is NSNull) {
            guard let object = rawRequirements as? [String: Any] else {
                throw CodexClientError.invalid("Invalid Codex configuration requirements.")
            }
            if let rawModels = object["models"], !(rawModels is NSNull) {
                guard let managedModels = rawModels as? [String: Any] else {
                    throw CodexClientError.invalid("Invalid managed model requirements.")
                }
                if let newThread = managedModels["newThread"], !(newThread is NSNull) {
                    throw CodexClientError.unsupported("Managed new-chat model settings cannot be changed by Micro.")
                }
            }
        }
        let auth = try catalog.call("getAuthStatus", params: ["includeToken": false, "refreshToken": false], context: context)
        guard let method = auth["authMethod"] as? String else {
            throw CodexClientError.invalid("Codex authentication status is unavailable.")
        }
        guard method.caseInsensitiveCompare("copilot") != .orderedSame else {
            throw CodexClientError.unsupported("Copilot-managed new-chat settings cannot be changed by Micro.")
        }
        return try readDraftConfiguration(context: context)
    }

    func writeDraftConfiguration(_ value: DraftConfigurationSnapshot, context: OperationContext) throws -> Bool {
        func edit(_ key: String, _ raw: String?) -> [String: Any] {
            ["keyPath": key, "value": raw.map { $0 as Any } ?? JSON.null, "mergeStrategy": raw == nil ? "replace" : "upsert"]
        }
        let result = try catalog.batchWrite(edits: [
            edit("model", value.model),
            edit("model_reasoning_effort", value.effort),
            edit("desktop.codex-micro-layout.encoderMode", value.encoderMode)
        ], context: context)
        guard result["status"] as? String == "ok" else {
            throw CodexClientError.rejected("Codex did not accept the draft configuration write.")
        }
        guard try readDraftConfiguration(context: context) == value else { throw CodexClientError.outcomeUnknown }
        return true
    }

    func invalidateUserSavedConfig(context: OperationContext) throws -> Bool {
        let peer = try DesktopPeer(context: context)
        defer { peer.close() }
        try peer.invalidateUserSavedConfig()
        return true
    }

    func execute(_ name: String, arguments a: [String: Any], context: OperationContext) throws -> [String: Any] {
        guard MacPreviewCapabilities.operations.contains(name) else {
            throw CodexClientError.unsupported("This operation is unavailable in the macOS preview. Read get_keypad_capabilities for supported operations.")
        }
        switch name {
        case "get_keypad_capabilities":
            var capabilities = MacPreviewCapabilities.description
            do { capabilities["forkAvailable"] = try catalog.supportsSafeFork(context: context) }
            catch { try context.check(); capabilities["forkAvailable"] = false }
            return capabilities
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
            var analogBindings: [String: Any] = analog.mapValues { ["type": "command", "commandId": $0] }
            if let modern = layout["analogStick"] as? [String: Any] {
                for direction in ["up", "down", "left", "right"] {
                    guard let raw = modern[direction] else { continue }
                    let binding = Self.binding(raw)
                    analogBindings[direction] = binding ?? JSON.null as Any
                    analog[direction] = binding?["commandId"] as? String ?? ""
                }
            }
            let slotDefaults = ["ACT06": "FAST", "ACT07": "APPR", "ACT08": "REJ", "ACT09": "SPLIT", "ACT10_ACT11": "MIC", "ACT10": "MIC1", "ACT11": "EMPT1", "ACT12": "CODEX"]
            let rawSlots = layout["slots"] as? [String: [String: Any]] ?? [:]
            let slots = slotDefaults.mapValues { ["keycapId": $0] as [String: Any] }.merging(rawSlots.mapValues { raw in
                var slot: [String: Any] = ["keycapId": raw["keycapId"] as? String ?? "EMPT1"]
                if let action = Self.binding(raw["action"]) { slot["action"] = action }
                else if let command = raw["commandId"] as? String, command.count <= 256 { slot["action"] = ["type": "command", "commandId": command] }
                // Windows null/missing action means the keycap's default.
                // An invalid explicit binding must still remain unavailable.
                else if let action = raw["action"], !(action is NSNull) { slot["action"] = JSON.null }
                return slot
            }, uniquingKeysWith: { _, configured in configured })
            return ["separateMicrophoneKeys": layout["separateMicrophoneKeys"] as? Bool ?? false, "encoderMode": layout["encoderMode"] as? String ?? "composer-navigation", "analogActions": analog,
                    "analogBindings": analogBindings, "slots": slots, "encoderBindings": (layout["encoder"] as? [String: Any] ?? [:]).compactMapValues(Self.binding)]
        case "get_keypad_usage": return try catalog.call("account/rateLimits/read", params: [:], context: context)
        case "get_keypad_client_thread":
            guard let raw=a["client_thread_id"] as? String,let client=ClientThreadIdentity.canonical(raw),
                  let requested=a["roster_scope"] as? String,requested.count == 64,
                  requested.allSatisfy({"0123456789abcdef".contains($0)}) else {
                throw CodexClientError.invalid("Client identity lookup requires the observed roster scope.")
            }
            func currentScope()throws->String? {
                let auth=try catalog.call("getAuthStatus",params:["includeToken":true,"refreshToken":false],context:context)
                try context.check();try catalog.assertStorageCurrent()
                return TaskRoster.scope(CodexStorage.readContext(auth),root:CodexStorage.root)
            }
            guard try currentScope() == requested else {throw CodexClientError.staleTarget}
            let generation=catalog.generation,root=CodexStorage.root
            let evidence=try ClientThreadBinding.load(root:root,client:client)
            var row:[String:Any]?
            if let id=evidence.threadID {
                do {
                    let result=try catalog.call("thread/read",params:["threadId":id,"includeTurns":false],context:context)
                    guard let exact=result["thread"] as? [String:Any],exact["id"] as? String == id else {throw CodexClientError.staleTarget}
                    row=["id":id,"title":String((exact["name"] as? String ?? "").prefix(160))]
                } catch CodexClientError.rejected {row=nil}
            }
            guard try currentScope() == requested,generation == catalog.generation,root == CodexStorage.root,
                  try evidence == ClientThreadBinding.load(root:root,client:client) else {throw CodexClientError.staleTarget}
            return ["clientThreadId":client,"threadId":row?["id"] ?? JSON.null,"thread":row ?? JSON.null as Any,
                    "resolved":row != nil,"rosterScope":requested,"contextID":generation]
        case "list_keypad_threads":
            let mapping=try TaskRoster.request(a)
            let result = try catalog.call("thread/list", params: ["limit": 100, "sortKey": "recency_at", "sortDirection": "desc", "useStateDbOnly": true], context: context)
            let generation = catalog.generation
            let priority = a["include_priority"] as? Bool == true
            let rows:[[String:Any]]
            if priority {
                rows=try PriorityRoster.read(first:result) {params in
                    try context.check();try catalog.assertStorageCurrent()
                    let page=try catalog.call("thread/list",params:params,context:context)
                    guard generation == catalog.generation else {throw CodexClientError.staleTarget}
                    return page
                }
            } else {
                guard let data=result["data"] as? [[String:Any]] else {throw CodexClientError.invalid("Missing Codex thread list.")}
                rows=data
            }
            if observationGeneration != generation { rollouts.reset(); paths.removeAll(); observationGeneration = generation }
            var seen: Set<String> = []
            let valid = rows.filter { row in
                guard let id = row["id"] as? String, UUID(uuidString: id) != nil else { return false }
                return seen.insert(id).inserted
            }
            let auth = try? catalog.call("getAuthStatus", params: ["includeToken": true, "refreshToken": false], context: context)
            let readContext=auth.flatMap(CodexStorage.readContext)
            let identity=readContext?.identityKey,scope=TaskRoster.scope(readContext,root:CodexStorage.root)
            let includePinned=a["include_pinned"] as? Bool == true
            let pinPreferences=includePinned && scope != nil ? try PinnedSidebarPreferences.load(root:CodexStorage.root,migrationRoot:catalog.homeIdentity):PinnedSidebarPreferences()
            let previousOrders=pinnedScope == scope && pinnedContext == generation ? pinnedProjectOrders:[:]
            let pinned = includePinned ? try PinnedRoster.read(scope:scope,preferences:pinPreferences,previousOrders:previousOrders) {method,params in
                try context.check();try catalog.assertStorageCurrent()
                return try catalog.call(method,params:params,context:context)
            } : PinnedRoster.Snapshot()
            let mapped=try TaskRoster.resolve(mapping,scope:scope,recent:valid) {id in
                try context.check();try catalog.assertStorageCurrent()
                return try catalog.call("thread/read",params:["threadId":id,"includeTurns":false],context:context)
            }
            var observedIDs:Set<String>=[]
            let observed=(pinned.rows+mapped.rows+valid).filter {row in
                guard let id=row["id"] as? String else {return false};return observedIDs.insert(id).inserted
            }
            paths = Dictionary(observed.compactMap { row -> (String, String)? in
                guard let id = row["id"] as? String, let path = row["path"] as? String else { return nil }
                return (id, path)
            }, uniquingKeysWith: { first, _ in first })
            rollouts.retain(Set(observed.prefix(14).compactMap { row in
                (row["path"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
            }))
            let unread = CodexStorage.unread(identity: identity)
            var projected: [[String: Any]] = []
            for (index, row) in observed.enumerated() {
                try context.check()
                let id = row["id"] as! String
                let local = index < 14 ? (try? rollouts.read(path: paths[id], thread: id, context: context)) : nil
                let catalogStatus = row["status"] as? [String: Any] ?? [:]
                let status = Self.status(catalogStatus, fallback: local?.status)
                let title=(row["name"] as? String).flatMap {$0.isEmpty ? nil:$0} ?? row["preview"] as? String ?? ""
                projected.append(["id": id, "title":title,"cwd": row["cwd"] ?? "",
                    "status": status, "hasPendingQuestion": local?.pendingQuestion ?? false,
                    "attention":TaskAttention.classify(status:status,question:local?.pendingQuestion ?? false,unread:unread?.contains(id) ?? false).rawValue,
                    "recencyAt":TaskAttention.recency(row),
                    "hasUnreadTurn": unread.map { $0.contains(id) } ?? JSON.null as Any,
                    "statusSource": ["active", "idle", "systemError"].contains(catalogStatus["type"] as? String ?? "") ? "app-server" : local?.status != "unknown" && local != nil ? "rollout" : "unavailable"])
            }
            try context.check()
            try catalog.assertStorageCurrent()
            guard generation == catalog.generation else { throw CodexClientError.staleTarget }
            if includePinned,scope != nil {
                guard try pinPreferences == PinnedSidebarPreferences.load(root:CodexStorage.root,migrationRoot:catalog.homeIdentity) else {throw CodexClientError.staleTarget}
                pinnedScope=scope;pinnedContext=generation;pinnedProjectOrders=pinned.available ? pinned.projectOrders:[:]
            }
            activity.configure(observed, identity: identity, contextID: generation,priority:priority)
            let byID=Dictionary(projected.map {($0["id"] as! String,$0)},uniquingKeysWith:{first,_ in first})
            return ["threads":valid.compactMap {($0["id"] as? String).flatMap {byID[$0]}},
                    "pinnedThreads":pinned.rows.compactMap {($0["id"] as? String).flatMap {byID[$0]}},
                    "pinnedAvailable":pinned.available,"priorityComplete":priority,
                    "mappedThreads":mapped.rows.compactMap {($0["id"] as? String).flatMap {byID[$0]}},
                    "unavailableMappedThreadIds":mapped.unavailable,"rosterScope":scope ?? JSON.null as Any,
                    "contextID":generation,"unreadAvailable":unread != nil]
        case "new_keypad_thread":
            try context.check()
            try Self.open("codex://threads/new", context: context)
            return ["launch_requested": true, "navigation_verified": false, "target": "new-draft"]
        default: break
        }
        let thread = try JSON.required(a, "thread_id")
        guard UUID(uuidString: thread) != nil else { throw CodexClientError.invalid("Expected an exact local Codex thread UUID.") }
        if name == "get_keypad_archive_state" {
            let stored=try catalog.call("thread/read",params:["threadId":thread,"includeTurns":false],context:context)
            guard (stored["thread"] as? [String:Any])?["id"] as? String == thread else { throw CodexClientError.staleTarget }
            var cursor:String?,seen=Set<String>()
            for _ in 0..<10 {
                var params:[String:Any]=["archived":true,"limit":100,"sortKey":"updated_at","sortDirection":"desc","useStateDbOnly":true,"modelProviders":[],
                    "sourceKinds":["cli","vscode","exec","appServer","subAgent","subAgentReview","subAgentCompact","subAgentThreadSpawn","subAgentOther","unknown"]]
                if let cursor { params["cursor"]=cursor }
                let result=try catalog.call("thread/list",params:params,context:context)
                guard let rows=result["data"] as? [[String:Any]],rows.allSatisfy({$0["id"] is String}) else { throw CodexClientError.invalid("Invalid archived chat list.") }
                try context.check();try catalog.assertStorageCurrent()
                if rows.contains(where:{$0["id"] as? String == thread}) { return ["threadId":thread,"archived":true,"complete":true] }
                guard result["nextCursor"] == nil || result["nextCursor"] is NSNull || result["nextCursor"] is String else { throw CodexClientError.invalid("Invalid archived chat cursor.") }
                guard let next=result["nextCursor"] as? String,!next.isEmpty else { return ["threadId":thread,"archived":false,"complete":true] }
                guard seen.insert(next).inserted else { throw CodexClientError.invalid("Archived chat pagination did not advance.") }
                cursor=next
            }
            return ["threadId":thread,"archived":NSNull(),"complete":false]
        }
        if name == "get_keypad_folder" {
            let stored = try catalog.call("thread/read", params:["threadId":thread,"includeTurns":false],context:context)
            guard let value=stored["thread"] as? [String:Any], value["id"] as? String == thread else { throw CodexClientError.staleTarget }
            guard let cwd=value["cwd"] as? String, cwd.hasPrefix("/"), !cwd.contains("\0") else {
                throw CodexClientError.unavailable("The exact chat has no local project folder.")
            }
            try context.check(); try catalog.assertStorageCurrent()
            return ["threadId":thread,"cwd":cwd]
        }
        if name == "mark_keypad_unread" {
            let stored = try catalog.call("thread/read", params:["threadId":thread,"includeTurns":false],context:context)
            guard (stored["thread"] as? [String:Any])?["id"] as? String == thread else { throw CodexClientError.staleTarget }
            let auth = try catalog.call("getAuthStatus",params:["includeToken":true,"refreshToken":false],context:context)
            guard let readContext=CodexStorage.readContext(auth), let before=CodexStorage.unread(identity:readContext.identityKey) else {
                throw CodexClientError.unavailable("Codex read state is unavailable.")
            }
            func confirmedUnread() throws -> [String: Any] {
                // Storage-root checks alone do not detect a switched account.
                let latestAuth = try catalog.call("getAuthStatus", params: ["includeToken": true, "refreshToken": false], context: context)
                guard CodexStorage.readContext(latestAuth) == readContext else { throw CodexClientError.staleTarget }
                try catalog.assertStorageCurrent()
                guard CodexStorage.unread(identity: readContext.identityKey)?.contains(thread) == true else {
                    throw CodexClientError.outcomeUnknown
                }
                var result: [String: Any] = ["verified": true, "threadId": thread, "hasUnreadTurn": true]
                result.merge(activity.confirmUnread(thread, identity: readContext.identityKey)) { _, new in new }
                return result
            }
            if before.contains(thread) { return try confirmedUnread() }
            let peer = try DesktopPeer(context:context)
            defer { peer.close() }
            try catalog.assertStorageCurrent()
            try peer.markUnread(thread,context:readContext)
            do {
                let deadline=Date().addingTimeInterval(3)
                repeat {
                    try context.check(); try catalog.assertStorageCurrent()
                    if CodexStorage.unread(identity:readContext.identityKey)?.contains(thread) == true {
                        return try confirmedUnread()
                    }
                    Thread.sleep(forTimeInterval:0.05)
                } while Date() < deadline
            } catch { throw CodexClientError.outcomeUnknown }
            throw CodexClientError.outcomeUnknown
        }
        if name == "open_keypad_thread" || name == "open_keypad_review" {
            let stored = try catalog.call("thread/read", params: ["threadId": thread, "includeTurns": false], context: context)
            guard (stored["thread"] as? [String: Any])?["id"] as? String == thread else { throw CodexClientError.staleTarget }
            try context.check()
            try Self.open("codex://threads/" + thread + (name == "open_keypad_review" ? "?view=review" : ""), context: context)
            return ["launch_requested": true, "navigation_verified": false, "threadId": thread]
        }
        if name == "fork_keypad_thread" {
            let fork = try catalog.fork(thread, context: context)
            guard let created = (fork["thread"] as? [String: Any])?["id"] as? String,
                  UUID(uuidString: created) != nil, created != thread else { throw CodexClientError.outcomeUnknown }
            // Once creation is acknowledged, preserve its ID even if readback,
            // cancellation or Launch Services fails. Never repeat the fork.
            var response: [String: Any] = ["threadId": created, "forkedFrom": thread, "created": true,
                "verified": false, "launch_requested": false, "navigation_verified": false]
            do {
                let readback = try catalog.call("thread/read", params: ["threadId": created, "includeTurns": false], context: context)
                guard let stored = readback["thread"] as? [String: Any], stored["id"] as? String == created,
                      stored["forkedFromId"] as? String == thread else { throw CodexClientError.outcomeUnknown }
                response["verified"] = true
                try Self.open("codex://threads/" + created, context: context)
                response["launch_requested"] = true
            } catch { response["followupError"] = error.localizedDescription }
            return response
        }
        let supported = ["get_keypad_state", "set_keypad_model", "set_keypad_reasoning", "set_keypad_fast",
                         "send_keypad_message", "stop_keypad_turn", "reply_keypad_approval", "toggle_keypad_plan"]
        guard supported.contains(name) else { throw CodexClientError.unsupported("Unsupported keypad operation: \(name)") }
        if name == "get_keypad_state", paths[thread] == nil {
            let stored = try? catalog.call("thread/read", params: ["threadId": thread, "includeTurns": false], context: context)
            if let metadata = stored?["thread"] as? [String: Any], metadata["id"] as? String == thread {
                paths[thread] = metadata["path"] as? String
                if paths.count > 128, let obsolete = paths.keys.filter({ $0 != thread }).sorted().first { paths[obsolete] = nil }
            }
            try context.check()
        }
        let peer = try DesktopPeer(context: context)
        defer { peer.close() }
        let owner = try peer.owner(of: thread)
        let state = try peer.snapshot(thread, owner: owner)
        if name == "get_keypad_state" {
            var projected = Self.project(thread, state)
            let local = try? rollouts.read(path: paths[thread], thread: thread, acceptedState: state, context: context)
            if local?.pendingQuestion == true,
               !["idle", "systemError"].contains((state["threadRuntimeStatus"] as? [String: Any])?["type"] as? String ?? "") {
                projected["hasPendingQuestion"] = true
            }
            try context.check()
            return projected
        }

        func validateOwner() throws {
            try context.check()
            guard try peer.owner(of: thread) == owner else { throw CodexClientError.staleTarget }
        }
        func confirm(_ matches: ([String: Any]) -> Bool) throws -> [String: Any] {
            // Acknowledgement can precede the observable state transition.
            // Retry only observation, never the operation that caused it.
            let deadline = Date().addingTimeInterval(3)
            do {
                repeat {
                    try context.check()
                    guard try peer.owner(of: thread, timeout: max(0.1, deadline.timeIntervalSinceNow)) == owner else { throw CodexClientError.staleTarget }
                    let observed = try peer.snapshot(thread, owner: owner, timeout: max(0.1, deadline.timeIntervalSinceNow))
                    if matches(observed) { return observed }
                    if Date() >= deadline { break }
                    Thread.sleep(forTimeInterval: 0.1)
                } while Date() < deadline
            } catch { throw CodexClientError.outcomeUnknown }
            throw CodexClientError.outcomeUnknown
        }
        if ["set_keypad_model", "set_keypad_reasoning", "set_keypad_fast", "toggle_keypad_plan"].contains(name) {
            let current = Self.project(thread, state)
            if let expected = a["expected_settings"] as? [String: Any],
               !expected.allSatisfy({ JSON.same(current[$0.key], $0.value) }) {
                throw CodexClientError.staleTarget
            }
            let model = current["model"] as? String
            let definitions = try models(context)["data"] as? [[String: Any]] ?? []
            if name != "set_keypad_model" {
                guard definitions.contains(where: { $0["model"] as? String == model }) else { throw CodexClientError.invalid("The current model is not in the Codex catalog.") }
            }
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
            try catalog.assertStorageCurrent()
            if let deadline = a["input_deadline_uptime"] as? Double {
                guard deadline.isFinite, ProcessInfo.processInfo.systemUptime <= deadline else {
                    throw CodexClientError.invalid("The dial input expired before dispatch. Turn the dial again.")
                }
            }
            let response = try peer.request("thread-follower-update-thread-settings", version: 2,
                params: ["conversationId": thread, "threadSettings": settings, "condition": condition], target: owner, mutation: true)
            guard (response["result"] as? [String: Any])?["applied"] as? Bool == true else { throw CodexClientError.staleTarget }
            // A transport acknowledgement alone does not confirm the readback.
            let observed = Self.project(thread, try confirm { state in
                let projected = Self.project(thread, state)
                return settings.allSatisfy { JSON.same(projected[$0.key], $0.value) }
            })
            return ["applied": true, "verified": true, "threadId": thread, "settings": settings, "state": observed]
        }
        if name == "send_keypad_message" {
            let text = try JSON.required(a, "text")
            guard text.count <= 100_000 else { throw CodexClientError.invalid("Message exceeds 100,000 characters.") }
            guard Self.canSubmit(state) else {
                throw CodexClientError.invalid("The selected chat has an active or unconfirmed turn.")
            }
            try validateOwner()
            guard Self.canSubmit(try peer.snapshot(thread, owner: owner)) else { throw CodexClientError.staleTarget }
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
            _ = try confirm { observed in
                let idle = (observed["threadRuntimeStatus"] as? [String: Any])?["type"] as? String == "idle"
                return Self.activeTurn(observed) != turn && (idle || Self.terminalTurn(turn, in: observed))
            }
            var confirmed = reply
            confirmed["verified"] = true; confirmed["threadId"] = thread
            return confirmed
        }
        let request = try JSON.required(a, "request_id"), decision = try JSON.required(a, "decision")
        guard ["accept", "decline"].contains(decision) else { throw CodexClientError.invalid("Invalid approval decision.") }
        let pending = state["requests"] as? [[String: Any]] ?? []
        let matching = pending.filter { Self.requestID($0) == request }
        guard matching.count == 1, let item = matching.first, let rawID = item["id"] else { throw CodexClientError.staleTarget }
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
        _ = try confirm { observed in
            guard let remaining = observed["requests"] as? [[String: Any]] else { return false }
            return !remaining.contains { Self.requestID($0) == request }
        }
        return ["acknowledged": true, "verified": true, "threadId": thread, "requestId": request]
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
            do { try context.check() }
            catch { process.terminate(); throw CodexClientError.outcomeUnknown }
            if Date() > deadline { process.terminate(); throw CodexClientError.outcomeUnknown }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard process.terminationStatus == 0 else { throw CodexClientError.unavailable("macOS could not open Codex. Install and open the Codex desktop app first.") }
    }

    private static func status(_ observed: [String: Any], fallback: String?) -> [String: Any] {
        if ["active", "idle", "systemError"].contains(observed["type"] as? String ?? "") { return observed }
        return ["type": fallback ?? "unknown"]
    }

    private static func binding(_ value: Any?) -> [String: Any]? {
        guard let raw = value as? [String: Any], let type = raw["type"] as? String else { return nil }
        if type == "command", let id = raw["commandId"] as? String, !id.isEmpty, id.count <= 256 { return ["type": type, "commandId": id] }
        if type == "skill", let name = raw["skillName"] as? String, !name.isEmpty, name.count <= 256,
           let path = raw["skillPath"] as? String, path.hasPrefix("/"), path.count <= 4096, !path.localizedCaseInsensitiveContains("trash") {
            return ["type": type, "skillName": name, "skillPath": path]
        }
        return nil
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
            "model": settings["model"] as? String ?? state["latestModel"] ?? JSON.null,
            "effort": settings["effort"] ?? state["latestReasoningEffort"] ?? JSON.null,
            "serviceTier": settings["serviceTier"] ?? JSON.null,
            "collaborationMode": settings["collaborationMode"] ?? state["latestCollaborationMode"] ?? JSON.null,
            "activeTurnId": activeTurn(state) ?? JSON.null as Any,
            "canSubmit": canSubmit(state),
            "runtimeStatus": state["threadRuntimeStatus"] ?? JSON.null,
            "hasUnreadTurn": state["hasUnreadTurn"] ?? JSON.null,
            "hasPendingQuestion": requests.contains { $0["method"] as? String == "item/tool/requestUserInput" },
            "approvals": requests.filter { ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"].contains($0["method"] as? String ?? "") }
                .compactMap { item -> [String: Any]? in
                    guard let id = requestID(item) else { return nil }
                    return ["id": id, "method": item["method"] ?? "", "details": item["params"] ?? [:]]
                }]
    }

    private static func canSubmit(_ state: [String: Any]) -> Bool {
        let submissions = state["unconfirmedTurnSubmissions"] as? [[String: Any]] ?? []
        return activeTurn(state) == nil &&
            (state["threadRuntimeStatus"] as? [String: Any])?["type"] as? String == "idle" &&
            (state["requests"] as? [[String: Any]] ?? []).isEmpty &&
            submissions.allSatisfy { $0["terminal"] as? Bool == true }
    }
}
