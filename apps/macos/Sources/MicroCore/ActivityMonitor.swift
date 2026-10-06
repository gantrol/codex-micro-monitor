import Darwin
import Foundation
import MicroShared

/// Independent from the command/catalog queue. File events and desktop patches
/// update a compact snapshot that the UIKit client can read without RPC latency.
final class ActivityMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.gantrol.micro.activity", qos: .userInitiated)
    private let streamQueue = DispatchQueue(label: "com.gantrol.micro.activity.ipc", qos: .userInitiated)
    private let rollouts = RolloutReader(maximumCursors:PriorityRoster.maximumRows)
    private var rows: [[String: Any]] = []
    private var identity: String?
    private var contextID = ""
    private var epoch = UUID()
    private var revision = 0
    private var signals: [String: String] = [:]
    private var attention:[String:String]=[:]
    private var priority=false
    private var localObservations:[String:RolloutObservation]=[:]
    private var rolloutOffset=0
    private var desktop: [String: [String: Any]] = [:]
    private var selectedThread: String?
    private var visibleContexts: [String] = []
    private var visibilityKnown = false
    private var files: [String: DispatchSourceFileSystemObject] = [:]
    private var timer: DispatchSourceTimer?
    private var debounce: DispatchWorkItem?
    private var streamContext: OperationContext?
    private var unreadStamp = ""
    private var unread: Set<String>?
    private var unreadState = UnreadStateStore()
    private var unreadEvidence: [String: [String: Any]] = [:]
    private var authStamp = ""
    private var contextValid = true
    private var streamConnected = false
    private var refreshedAt: TimeInterval = 0
    private var streamError = ""

    func configure(_ rows: [[String: Any]], identity: String?, contextID: String,priority:Bool=false) {
        queue.async {
            let compact: [[String: Any]] = Array(rows.prefix(priority ? PriorityRoster.maximumRows:14)).map { row in
                let path = (row["path"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
                return ["id": row["id"] ?? JSON.null, "path": path ?? JSON.null as Any,"status":row["status"] ?? [:],"recencyAt":TaskAttention.recency(row)]
            }
            let oldPaths = self.rows.map {[$0["id"] as? String ?? "",$0["path"] as? String ?? ""]}.sorted { $0[0] < $1[0] }
            let newPaths = compact.map {[$0["id"] as? String ?? "",$0["path"] as? String ?? ""]}.sorted { $0[0] < $1[0] }
            let changed = self.priority != priority || self.contextID != contextID || self.identity != identity || !self.contextValid || !JSON.same(oldPaths, newPaths)
            if self.contextID != contextID || self.identity != identity || !self.contextValid {
                self.rollouts.reset(); self.signals = [:]; self.attention=[:]; self.desktop = [:]
                self.unreadState.reset(); self.unreadEvidence = [:]; self.unreadStamp = ""; self.unread = nil
            }
            self.contextID = contextID; self.rows = compact;self.priority=priority
            self.authStamp = Self.fileStamp(CodexStorage.root.appendingPathComponent("auth.json")); self.contextValid = true
            if self.identity != identity { self.identity = identity; self.unreadStamp = ""; self.unread = nil }
            if changed { self.localObservations=[:];self.rolloutOffset=0;self.restartStream(); self.installWatches() }
            if self.timer == nil {
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(100))
                timer.setEventHandler { [weak self] in
                    guard let self else { return }
                    if let context = self.streamContext, (try? context.check()) == nil { self.restartStream() }
                    self.installWatches(); self.refresh()
                }
                self.timer = timer; timer.resume()
            }
            self.refresh()
        }
    }

    func close() {
        queue.async {
            self.epoch = UUID(); self.streamContext?.cancel(); self.streamContext = nil
            self.timer?.cancel(); self.timer = nil; self.debounce?.cancel(); self.debounce = nil
            self.files.values.forEach { $0.cancel() }; self.files = [:]
            self.unreadState.reset(); self.unreadEvidence = [:]
            self.rows = []; self.desktop = [:]; self.signals = [:];self.attention=[:]; self.localObservations=[:];self.rolloutOffset=0;self.rollouts.reset()
            self.selectedThread=nil; self.visibleContexts=[]; self.visibilityKnown=false
            self.streamConnected = false; self.refreshedAt = 0
            self.identity = nil; self.unread = nil; self.unreadStamp = ""; self.contextID = ""; self.revision += 1
        }
    }

    func read(thread: String?) async -> [String: Any] {
        await withCheckedContinuation { continuation in
            queue.async {
                self.selectedThread=thread.flatMap { UUID(uuidString:$0) != nil ? $0 : nil }
                let settings=self.desktop.mapValues { value -> [String:Any] in
                    let latest=value["latestThreadSettings"] as? [String:Any] ?? [:]
                    return ["model":latest["model"] as? String ?? value["latestModel"] ?? JSON.null,
                        "effort":latest["effort"] ?? value["latestReasoningEffort"] ?? JSON.null,
                        "serviceTier":latest["serviceTier"] ?? JSON.null,
                        "collaborationMode":latest["collaborationMode"] ?? value["latestCollaborationMode"] ?? JSON.null,
                        "title":value["title"] ?? ""]
                }
                continuation.resume(returning: ["contextID": self.contextID,
                "revision": self.revision, "unreadEvidence": self.unreadEvidence, "signals": self.signals,"attention":self.attention, "watching": self.timer != nil, "contextValid": self.contextValid,
                "visibleContexts":self.visibleContexts, "visibilityKnown":self.visibilityKnown,
                "settings":settings,
                "streamConnected": self.streamConnected, "streamError": self.streamError, "desktopThreads": self.desktop.count, "watchedFiles": self.files.count,
                "refreshAgeMs": self.refreshedAt > 0 ? max(0, Int((ProcessInfo.processInfo.systemUptime - self.refreshedAt) * 1000)) : -1])
            }
        }
    }

    /// Called only after exact account/storage-scoped persisted readback.
    /// Queue ordering makes the receipt a barrier for every earlier UI poll.
    func confirmUnread(_ thread: String, identity: String) -> [String: Any] {
        queue.sync {
            guard self.identity == identity, self.contextValid, self.timer != nil else { return [:] }
            self.unreadState.confirmUnread(thread, at: ProcessInfo.processInfo.systemUptime)
            self.revision += 1
            self.refresh()
            guard self.contextValid else { return [:] }
            return ["contextID": self.contextID, "activityRevision": self.revision]
        }
    }

    private func discardDesktop(_ id: String) {
        desktop[id] = nil
        unreadState.disconnect(id, at: ProcessInfo.processInfo.systemUptime)
    }

    private func discardAllDesktop() {
        for id in desktop.keys { unreadState.disconnect(id, at: ProcessInfo.processInfo.systemUptime) }
        desktop = [:]
    }

    private func scheduleRefresh() {
        guard debounce == nil else { return }
        let item = DispatchWorkItem { [weak self] in self?.debounce = nil; self?.refresh() }
        debounce = item; queue.asyncAfter(deadline: .now() + .milliseconds(40), execute: item)
    }

    private func installWatches() {
        let visible = priority ? rows.enumerated().sorted {
            let left=TaskAttention(rawValue:attention[$0.element["id"] as? String ?? ""] ?? "idle") ?? .idle
            let right=TaskAttention(rawValue:attention[$1.element["id"] as? String ?? ""] ?? "idle") ?? .idle
            if left.rank != right.rank {return left.rank < right.rank}
            let a=TaskAttention.recency($0.element),b=TaskAttention.recency($1.element)
            return a == b ? $0.offset < $1.offset:a > b
        }.prefix(14).map(\.element):Array(rows.prefix(14))
        var paths = Set(visible.compactMap { $0["path"] as? String })
        paths.insert(CodexStorage.root.appendingPathComponent(".codex-global-state.json").path)
        paths.insert(CodexStorage.root.appendingPathComponent("auth.json").path)
        for path in Array(files.keys) where !paths.contains(path) { files.removeValue(forKey: path)?.cancel() }
        rollouts.retain(Set(rows.compactMap { $0["path"] as? String }))
        for path in paths where files[path] == nil && !path.localizedCaseInsensitiveContains("trash") {
            let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(CodexStorage.root.path + "/"), !resolved.localizedCaseInsensitiveContains("trash") else { continue }
            let fd = Darwin.open(resolved, O_EVTONLY | O_NOFOLLOW)
            guard fd >= 0 else { continue }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { Darwin.close(fd); continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke], queue: queue)
            source.setEventHandler { [weak self] in
                guard let self, let source = self.files[path] else { return }
                if !source.data.intersection([.rename, .delete, .revoke]).isEmpty { self.files.removeValue(forKey: path)?.cancel() }
                self.scheduleRefresh()
            }
            source.setCancelHandler { Darwin.close(fd) }
            files[path] = source; source.resume()
        }
    }

    private func refresh() {
        guard timer != nil else { return }
        if Self.fileStamp(CodexStorage.root.appendingPathComponent("auth.json")) != authStamp {
            contextValid = false; identity = nil; unread = nil; desktop = [:]; unreadState.reset(); unreadEvidence = [:]; visibleContexts=[]; visibilityKnown=false
            if !signals.isEmpty || !attention.isEmpty { signals = [:];attention=[:]; revision += 1 }
            return
        }
        let global = CodexStorage.root.appendingPathComponent(".codex-global-state.json")
        let stamp = Self.fileStamp(global)
        if stamp != unreadStamp { unreadStamp = stamp; unread = CodexStorage.unread(identity: identity) }
        let tracked = Set(rows.compactMap { $0["id"] as? String }).union(selectedThread.map { [$0] } ?? []).union(desktop.keys)
        unreadState.retain(tracked)
        unreadState.observePersistent(unread, ids: tracked, at: ProcessInfo.processInfo.systemUptime)
        let context = OperationContext(timeout: 2)
        // Scan incrementally on the observation queue. A large catalog must
        // neither block control requests nor starve older rollout files.
        if !rows.isEmpty {
            let start=rolloutOffset % rows.count
            for step in 0..<rows.count {
                guard (try? context.check()) != nil else {break}
                let index=(start+step) % rows.count,row=rows[index]
                if let id=row["id"] as? String {
                    localObservations[id]=(try? rollouts.read(path:row["path"] as? String,thread:id,context:context)) ?? .init()
                }
                rolloutOffset=(index+1) % rows.count
            }
        }
        var next: [String: String] = [:],nextAttention:[String:String]=[:]
        for row in rows {
            guard let id = row["id"] as? String else { continue }
            let local=localObservations[id]
            let observed = desktop[id]
            let requests = observed?["requests"] as? [[String: Any]] ?? []
            let runtime = observed?["threadRuntimeStatus"] as? [String: Any] ?? row["status"] as? [String:Any] ?? [:]
            let flags = runtime["activeFlags"] as? [String] ?? []
            let rawType=runtime["type"] as? String ?? "unknown"
            let type = ["active","idle","systemError"].contains(rawType) ? rawType:local?.status ?? "unknown"
            let hasQuestion = requests.contains { $0["method"] as? String == "item/tool/requestUserInput" } ||
                flags.contains("waitingOnUserInput") || (type == "active" && local?.pendingQuestion == true)
            let hasApproval = flags.contains("waitingOnApproval") || requests.contains {
                ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"].contains($0["method"] as? String ?? "")
            }
            let hasUnread = unreadState.value(for: id) ?? false
            nextAttention[id]=TaskAttention.classify(status:["type":type],question:hasQuestion,approval:hasApproval,unread:hasUnread).rawValue
            next[id]=TaskLampSignal.classify(status:["type":type],question:hasQuestion,approval:hasApproval,unread:hasUnread).rawValue
        }
        let evidence = Dictionary(uniqueKeysWithValues: tracked.map { ($0, unreadState.evidence(for: $0)) })
        if signals != next || attention != nextAttention || !JSON.same(unreadEvidence, evidence) {
            signals = next; attention = nextAttention; unreadEvidence = evidence; revision += 1
        }
        refreshedAt = ProcessInfo.processInfo.systemUptime
    }

    private static func fileStamp(_ url: URL) -> String {
        guard !url.path.localizedCaseInsensitiveContains("trash") else { return "unavailable" }
        let info = try? FileManager.default.attributesOfItem(atPath: url.path)
        return "\(info?[.systemFileNumber] ?? ""):\(info?[.size] ?? ""):\((info?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
    }

    private func restartStream() {
        streamContext?.cancel(); discardAllDesktop(); streamConnected = false; visibleContexts=[]; visibilityKnown=false; revision += 1
        let context = OperationContext(timeout: 24 * 60 * 60), generation = UUID()
        epoch = generation; streamContext = context
        let rows = self.rows
        streamQueue.async { [weak self] in
            while (try? context.check()) != nil {
                do { try self?.stream(rows, context: context, generation: generation) }
                catch {
                    let detail = String(error.localizedDescription.prefix(160))
                    self?.queue.async { [weak self] in
                        guard let self, self.epoch == generation else { return }
                        self.discardAllDesktop(); self.visibleContexts=[]; self.visibilityKnown=false; self.revision += 1
                        self.streamConnected = false; self.streamError = detail; self.refresh()
                    }
                }
                for _ in 0..<10 { if (try? context.check()) == nil { return }; Thread.sleep(forTimeInterval: 0.1) }
            }
        }
    }

    static func discoveryBatch(ids:Set<String>,pending:Set<String>,last:[String:TimeInterval],selected:String?,now:TimeInterval = .infinity) -> [String] {
        Array(ids.subtracting(pending).filter {now-(last[$0] ?? -.infinity) >= 5}.sorted {
            if ($0 == selected) != ($1 == selected) {return $0 == selected}
            let a=last[$0] ?? -.infinity,b=last[$1] ?? -.infinity
            return a == b ? $0 < $1:a < b
        }.prefix(min(8,max(0,64-pending.count))))
    }

    private func stream(_ rows: [[String: Any]], context: OperationContext, generation: UUID) throws {
        let peer = try DesktopPeer(context: context)
        queue.async { [weak self] in guard let self, self.epoch == generation else { return }; self.streamConnected = true; self.streamError = "" }
        defer { peer.onResponse = nil; peer.onBroadcast = nil; peer.close() }
        let rosterIDs = Set(rows.compactMap { $0["id"] as? String })
        var owners: [String: String] = [:], revisions: [String: Int] = [:], state: [String: [String: Any]] = [:]
        var visibleByClient:[String:(thread:String,seen:TimeInterval)]=[:]
        var visibilityKnown=false
        var visibilityRefresh:(started:TimeInterval,deadline:TimeInterval,requested:Set<String>)?
        var snapshots: Set<String> = []
        var discoveries: [String: (thread: String, deadline: TimeInterval)] = [:]
        var lastDiscovery:[String:TimeInterval]=[:]
        var streamFailure: Error?
        let fields: Set<String> = ["threadRuntimeStatus", "requests", "hasUnreadTurn", "title",
            "latestModel", "latestReasoningEffort", "latestThreadSettings", "latestCollaborationMode"]
        func publishVisibility() {
            let ids=Array(Set(visibleByClient.values.map(\.thread))).sorted(), known=visibilityKnown
            queue.async { [weak self] in
                guard let self, self.epoch == generation else { return }
                if self.visibleContexts != ids || self.visibilityKnown != known {
                    self.visibleContexts=ids; self.visibilityKnown=known; self.revision += 1
                }
            }
        }
        func forget(_ id: String) {
            if let owner = owners[id] { try? peer.follow(id, owner: owner, following: false) }
            owners[id] = nil; revisions[id] = nil; state[id] = nil; snapshots.remove(id)
            queue.async { [weak self] in guard let self, self.epoch == generation else { return }; self.discardDesktop(id); self.revision += 1; self.scheduleRefresh() }
        }
        peer.onResponse = { response in
            guard let request = response["requestId"] as? String, let pending = discoveries.removeValue(forKey: request) else { return }
            let id = pending.thread
            guard response["resultType"] as? String == "success", response["method"] as? String == "thread-owner-discovery",
                  let owner = response["handledByClientId"] as? String, !owner.isEmpty else { forget(id); return }
            if owners[id] != owner {
                forget(id); owners[id] = owner
                do { try peer.follow(id, owner: owner, following: true) }
                catch { streamFailure = error }
            }
        }
        peer.onBroadcast = { [weak self] message in
            if message["method"] as? String == "client-status-changed", let parameters=message["params"] as? [String:Any],
               parameters["status"] as? String == "disconnected", let client=parameters["clientId"] as? String {
                visibleByClient[client]=nil; publishVisibility()
                for id in Array(owners.keys) where owners[id] == client { forget(id) }
                return
            }
            if message["method"] as? String == "thread-stream-following-changed", message["version"] as? Int == 1,
               let source=message["sourceClientId"] as? String, source != peer.identity,
               let parameters=message["params"] as? [String:Any], parameters["hostId"] as? String == "local",
               let id=parameters["conversationId"] as? String, id.count <= 256,
               UUID(uuidString:id) != nil || id.hasPrefix("client-new-thread:"), let following=parameters["following"] as? Bool {
                visibilityKnown=true
                if following, visibleByClient[source] != nil || visibleByClient.count < 32 {
                    visibleByClient[source]=(id,ProcessInfo.processInfo.systemUptime)
                } else if visibleByClient[source]?.thread == id { visibleByClient[source]=nil }
                publishVisibility(); return
            }
            guard message["method"] as? String == "thread-stream-state-changed",
                  let parameters = message["params"] as? [String: Any], parameters["hostId"] as? String == "local",
                  let id = parameters["conversationId"] as? String, let owner = owners[id], message["sourceClientId"] as? String == owner else { return }
            guard message["version"] as? Int == 11 else {
                revisions[id] = nil; state[id] = nil
                self?.queue.async { [weak self] in guard let self, self.epoch == generation else { return }; self.discardDesktop(id); self.revision += 1; self.scheduleRefresh() }
                return
            }
            guard
                  let change = parameters["change"] as? [String: Any], let revision = change["revision"] as? Int else { return }
            var unreadObserved = false
            if change["type"] as? String == "snapshot", let value = change["conversationState"] as? [String: Any] {
                guard revisions[id].map({ revision > $0 }) ?? true else { return }
                state[id] = value.filter { fields.contains($0.key) }; revisions[id] = revision
                unreadObserved = true
                // Parse accepted replies before dropping the large history.
                let path = rows.first { $0["id"] as? String == id }?["path"] as? String
                self?.queue.async { [weak self] in
                    guard let self, self.epoch == generation else { return }
                    _ = try? self.rollouts.read(path: path, thread: id, acceptedState: value, context: OperationContext(timeout: 1))
                }
            } else if change["type"] as? String == "patches" {
                guard let base = change["baseRevision"] as? Int, base == revisions[id], base < Int.max, revision == base + 1,
                      let patches = change["patches"] as? [[String: Any]], var value = state[id] else {
                    snapshots.insert(id); revisions[id] = nil; state[id] = nil
                    self?.queue.async { [weak self] in guard let self, self.epoch == generation else { return }; self.discardDesktop(id); self.revision += 1; self.scheduleRefresh() }
                    return
                }
                do {
                    for patch in patches {
                        let path = try ActivityPatch.path(patch["path"])
                        if path.isEmpty || path.first == "hasUnreadTurn" { unreadObserved = true }
                        if path.isEmpty || fields.contains(path[0]) { value = try ActivityPatch.apply(patch, path: path, to: value) }
                        // Only an accepted steering reply needs a fresh snapshot.
                        // Streaming token/content patches do not cause polling.
                        if path.last == "status", patch["value"] as? String == "accepted" { snapshots.insert(id) }
                        if let item = patch["value"] as? [String: Any], item["type"] as? String == "userMessage" { snapshots.insert(id) }
                    }
                    state[id] = value.filter { fields.contains($0.key) }; revisions[id] = revision
                } catch { snapshots.insert(id); revisions[id] = nil; state[id] = nil }
            }
            let observation = state[id]
            let hasUnreadObservation = unreadObserved
            self?.queue.async { [weak self] in
                guard let self, self.epoch == generation else { return }
                if let observation, hasUnreadObservation {
                    self.unreadState.observeStream(id, value: observation["hasUnreadTurn"] as? Bool,
                        stamp: .init(generation: generation, owner: owner, revision: revision),
                        at: ProcessInfo.processInfo.systemUptime)
                } else if observation == nil { self.discardDesktop(id) }
                if !JSON.same(self.desktop[id],observation) { self.desktop[id] = observation; self.revision += 1 }
                self.scheduleRefresh()
            }
        }
        var discovery = Date.distantPast,visibilityRequest = Date.distantPast
        while true {
            try context.check()
            if let streamFailure { throw streamFailure }
            let now = ProcessInfo.processInfo.systemUptime
            let selected=queue.sync { self.selectedThread }
            let ids=rosterIDs.union(selected.map { [$0] } ?? []).union(visibleByClient.values.map(\.thread).filter { UUID(uuidString:$0) != nil })
            for id in Array(owners.keys) where !ids.contains(id) { forget(id) }
            if let refresh=visibilityRefresh, now >= refresh.deadline {
                visibleByClient=visibleByClient.filter { !refresh.requested.contains($0.value.thread) || $0.value.seen >= refresh.started }
                visibilityRefresh=nil; publishVisibility()
            }
            for request in Array(discoveries.keys) {
                if let pending = discoveries[request], pending.deadline <= now { discoveries[request] = nil; forget(pending.thread) }
            }
            if Date().timeIntervalSince(discovery) >= 0.5 {
                // Discovery can take the broker's full 10-second budget for
                // unopened chats. Keep it asynchronous so those chats cannot
                // delay status patches or starve later roster entries.
                let pending = Set(discoveries.values.map(\.thread))
                let candidates=Self.discoveryBatch(ids:ids,pending:pending,last:lastDiscovery,selected:selected,now:now)
                for id in candidates {
                    let request = try peer.beginOwnerDiscovery(id)
                    discoveries[request] = (id, now + 12)
                    lastDiscovery[id]=now
                    try peer.pollBroadcast(waitMilliseconds:0)
                }
                discovery = Date()
                if Date().timeIntervalSince(visibilityRequest) >= 5 {
                    let requested=Set(candidates).union(visibleByClient.values.map(\.thread))
                    visibilityRefresh=(now,now+0.75,requested);visibilityRequest=Date()
                    for id in requested {try peer.requestFollowingStatus(id);try peer.pollBroadcast(waitMilliseconds:0)}
                }
            }
            // A newly selected or visible chat may be outside the 14 lamp slots.
            let pending=Set(discoveries.values.map(\.thread))
            for id in Self.discoveryBatch(ids:Set([selected].compactMap {$0}).union(visibleByClient.values.map(\.thread)),pending:pending,last:lastDiscovery,selected:selected,now:now) where owners[id] == nil && now-(lastDiscovery[id] ?? -.infinity) >= 5 {
                let request=try peer.beginOwnerDiscovery(id); discoveries[request]=(id,now+12)
                lastDiscovery[id]=now
                try peer.pollBroadcast(waitMilliseconds:0)
            }
            lastDiscovery=lastDiscovery.filter { ids.contains($0.key) }
            for id in snapshots {
                if let owner = owners[id] {
                    revisions[id] = nil
                    try peer.follow(id, owner: owner, following: false)
                    try peer.follow(id, owner: owner, following: true)
                }
            }
            snapshots.removeAll()
            try peer.pollBroadcast()
        }
    }
}

private enum ActivityPatch {
    static func path(_ raw: Any?) throws -> [String] {
        if let array = raw as? [Any] {
            return try array.map {
                if let part = $0 as? String { return part }
                if let part = $0 as? Int { return String(part) }
                throw CodexClientError.invalid("Invalid state patch path.")
            }
        }
        guard let pointer = raw as? String, pointer.isEmpty || pointer.hasPrefix("/") else { throw CodexClientError.invalid("Invalid state patch path.") }
        return pointer.isEmpty ? [] : pointer.dropFirst().components(separatedBy: "/").map { $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~") }
    }
    static func apply(_ patch: [String: Any], path: [String], to state: [String: Any]) throws -> [String: Any] {
        guard let operation = patch["op"] as? String, ["add", "replace", "remove"].contains(operation),
              operation == "remove" || patch["value"] != nil, path.count <= 32 else { throw CodexClientError.invalid("Invalid state patch.") }
        func edit(_ node: Any, _ offset: Int) throws -> Any {
            if offset == path.count { return patch["value"] ?? JSON.null }
            let key = path[offset], leaf = offset == path.count - 1
            if var object = node as? [String: Any] {
                if leaf { if operation == "remove" { object[key] = nil } else { object[key] = patch["value"] } }
                else { guard let child = object[key] else { throw CodexClientError.invalid("Missing patch parent.") }; object[key] = try edit(child, offset + 1) }
                return object
            }
            if var array = node as? [Any] {
                if leaf, key == "length", let count = patch["value"] as? Int, count >= 0, count <= array.count { return Array(array.prefix(count)) }
                let index = key == "-" ? array.count : Int(key) ?? -1
                guard index >= 0, index <= array.count else { throw CodexClientError.invalid("Invalid patch index.") }
                if leaf, operation == "add" { array.insert(patch["value"]!, at: index) }
                else {
                    guard index < array.count else { throw CodexClientError.invalid("Missing patch item.") }
                    if leaf, operation == "remove" { array.remove(at: index) }
                    else { array[index] = try edit(array[index], offset + 1) }
                }
                return array
            }
            throw CodexClientError.invalid("Invalid patch parent.")
        }
        guard let result = try edit(state, 0) as? [String: Any] else { throw CodexClientError.invalid("Missing state snapshot.") }
        return result
    }
}
