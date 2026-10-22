import Foundation

@MainActor
final class MicroStore {
    private(set) var snapshot: MicroSnapshot?
    private(set) var connection: MicroConnection = .disconnected
    private(set) var selectedID: String?
    private(set) var isDemo = true
    private(set) var lease: MicroSessionLease?
    private(set) var pending: [UUID: MicroCommand] = [:]
    private(set) var uncertain: Set<UUID> = []
    private(set) var lastReceipt: MicroReceipt?
    private(set) var threadDetails: [String: MicroThreadDetail] = [:]
    private(set) var latestThreadsPage: MicroThreadsPage?
    private(set) var savedHosts: [SavedHost] = []
    private(set) var activeHost: SavedHost?

    var onChange: (() -> Void)?
    var onError: ((String) -> Void)?
    var onThreadDetail: ((MicroThreadDetail) -> Void)?
    var onThreadsPage: ((MicroThreadsPage) -> Void)?

    var page = UserDefaults.standard.integer(forKey: "micro.page") {
        didSet {
            UserDefaults.standard.set(page, forKey: "micro.page")
            onChange?()
        }
    }

    private var transport: MicroTransport = DemoTransport()
    private var generation = UUID()
    private var active = false
    private var demoTransport: MicroTransport?
    private var isTouchFrozen = false
    private var deferredSnapshot: MicroSnapshot?

    init() {
        reloadSavedHosts()
        if let initialHost = HostKeychain.activeHost() {
            self.activeHost = initialHost
            self.isDemo = false
            self.transport = WebSocketTransport(credentials: initialHost)
        }
    }

    var selected: MicroThread? {
        snapshot?.threads.first { $0.id == selectedID }
    }

    var isReadOnlyLease: Bool {
        !isDemo && connection == .ready && lease?.role == .readOnly
    }

    var isBusy: Bool {
        guard let selectedID else { return false }
        return isThreadBusy(selectedID)
    }

    var canControl: Bool {
        guard active, connection.allowsCommands else { return false }
        if !isDemo && lease?.role != .readWrite { return false }
        if let selectedID, isThreadLocked(selectedID) { return false }
        return true
    }

    var models: [MicroModel] {
        snapshot?.models ?? []
    }

    func isThreadBusy(_ threadID: String) -> Bool {
        let hostID = snapshot?.hostID ?? activeHost?.id ?? "demo"
        return pending.values.contains { $0.hostID == hostID && $0.threadID == threadID }
    }

    func hasUncertainCommand(forThread threadID: String) -> Bool {
        let hostID = snapshot?.hostID ?? activeHost?.id ?? "demo"
        return uncertain.contains { reqID in
            guard let cmd = pending[reqID] else { return false }
            return cmd.hostID == hostID && cmd.threadID == threadID
        }
    }

    func isThreadLocked(_ threadID: String) -> Bool {
        isThreadBusy(threadID) || hasUncertainCommand(forThread: threadID)
    }

    func setTouchFrozen(_ frozen: Bool) {
        guard isTouchFrozen != frozen else { return }
        isTouchFrozen = frozen
        if !frozen, let deferred = deferredSnapshot {
            deferredSnapshot = nil
            applySnapshot(deferred)
            onChange?()
        }
    }

    func reloadSavedHosts() {
        savedHosts = HostKeychain.loadHosts()
        activeHost = HostKeychain.activeHost()
    }

    func select(_ threadID: String) {
        selectedID = threadID
        onChange?()
        if connection.allowsCommands {
            execute(.select, threadID: threadID)
        }
    }

    func supports(_ kind: MicroCommandKind) -> Bool {
        guard active, connection.allowsCommands else { return false }
        if !isDemo && lease?.role != .readWrite { return false }
        guard let selected else { return false }
        if isThreadLocked(selected.id) { return false }
        guard selected.capabilities.contains(kind) else { return false }

        switch kind {
        case .approve, .decline:
            return selected.pendingApprovalCount > 0 || selected.approval != nil
        case .stop:
            return selected.turnID != nil || selected.status == .running
        case .fast:
            return selected.fast != nil
        case .plan:
            return selected.plan != nil
        default:
            return true
        }
    }

    func resume() {
        guard !active else { return }
        active = true
        connect()
    }

    func suspend() {
        guard active else { return }
        active = false
        generation = UUID()
        transport.disconnect()
        lease = nil
        uncertain.formUnion(pending.keys)
        connection = .suspended
        onChange?()
    }

    func useDemo() {
        HostKeychain.setActiveHostID(nil)
        activeHost = nil
        replace(with: demoTransport ?? DemoTransport(), demo: true)
    }

    func useHost(_ credentials: SavedHost) {
        if isDemo { demoTransport = transport }
        try? HostKeychain.upsertHost(credentials)
        reloadSavedHosts()
        activeHost = credentials
        replace(with: WebSocketTransport(credentials: credentials), demo: false)
    }

    func removeHost(id: String) {
        try? HostKeychain.removeHost(id: id)
        reloadSavedHosts()
        if activeHost?.id == id || savedHosts.isEmpty {
            if let next = savedHosts.first {
                useHost(next)
            } else {
                useDemo()
            }
        } else {
            onChange?()
        }
    }

    private func replace(with next: MicroTransport, demo: Bool) {
        generation = UUID()
        transport.disconnect()
        transport = next
        isDemo = demo
        snapshot = nil
        deferredSnapshot = nil
        selectedID = nil
        lease = nil
        threadDetails.removeAll()
        latestThreadsPage = nil
        lastReceipt = nil
        if active {
            connect()
        } else {
            onChange?()
        }
    }

    private func connect() {
        let token = UUID()
        generation = token
        lease = nil
        connection = .connecting
        onChange?()
        transport.connect { [weak self] event in
            guard let self, self.active, self.generation == token else { return }
            self.receive(event)
        }
    }

    private func receive(_ event: MicroEvent) {
        switch event {
        case .connection(let state):
            connection = state
            if !state.allowsCommands {
                uncertain.formUnion(pending.keys)
            }
            if state == .ready || state == .demo {
                let ids = Array(uncertain)
                if !ids.isEmpty {
                    Task { [weak self] in try? await self?.transport.query(ids) }
                }
            }

        case .lease(let newLease):
            lease = newLease

        case .hostCredentialsUpdated(let updatedHost):
            activeHost = updatedHost
            reloadSavedHosts()

        case .snapshot(let next):
            if isTouchFrozen && snapshot != nil {
                deferredSnapshot = next
                return
            }
            applySnapshot(next)

        case .threadDetail(let detail):
            threadDetails[detail.threadID] = detail
            onThreadDetail?(detail)

        case .threadsPage(let pageResult):
            latestThreadsPage = pageResult
            onThreadsPage?(pageResult)

        case .receipt(let receipt):
            guard pending[receipt.requestID] != nil else { return }
            lastReceipt = receipt
            switch receipt.status {
            case .accepted:
                break
            case .unknown:
                uncertain.insert(receipt.requestID)
            case .applied, .rejected, .notSent:
                pending.removeValue(forKey: receipt.requestID)
                uncertain.remove(receipt.requestID)
                if !isDemo {
                    saveJournal(loadJournal().filter { $0.requestID != receipt.requestID })
                }
            }
            if receipt.status == .rejected, let reason = receipt.reason {
                onError?(reason)
            }
        }
        onChange?()
    }

    private func applySnapshot(_ next: MicroSnapshot) {
        if let current = snapshot, current.hostID != next.hostID {
            selectedID = nil
            threadDetails.removeAll()
        }
        if !isDemo, snapshot == nil {
            for command in loadJournal() where command.hostID == next.hostID {
                pending[command.requestID] = command
                uncertain.insert(command.requestID)
            }
        }
        snapshot = next
        if let selectedID, next.threads.contains(where: { $0.id == selectedID }) {
            // Keep current selection
        } else if let hostSelected = next.selectedThreadID,
                  next.threads.contains(where: { $0.id == hostSelected }) {
            selectedID = hostSelected
        } else {
            selectedID = next.threads.first?.id
        }
    }

    func execute(
        _ kind: MicroCommandKind,
        value: String? = nil,
        secondaryValue: String? = nil,
        threadID: String? = nil,
        approvalItem: MicroApprovalItem? = nil
    ) {
        guard active, connection.allowsCommands, let snapshot else { return }
        if !isDemo && lease?.role != .readWrite {
            onError?("当前处于只读观察模式，请先接管控制权")
            return
        }
        let resolvedThreadID = threadID ?? selectedID ?? snapshot.threads.first?.id
        guard let targetID = resolvedThreadID else { return }
        if kind != .select && isThreadLocked(targetID) {
            onError?("当前会话存在待确认操作，请刷新状态或解锁后再试")
            return
        }

        let thread = snapshot.threads.first { $0.id == targetID }
        if kind == .stop && thread?.turnID == nil { return }

        let targetApproval = approvalItem ?? thread?.approval
        if (kind == .approve || kind == .decline) && targetApproval == nil { return }

        let command = MicroCommand(
            requestID: UUID(),
            hostID: snapshot.hostID,
            hostEpoch: snapshot.hostEpoch,
            controlLeaseID: lease?.leaseID ?? "lease",
            threadID: targetID,
            kind: kind,
            expectedRevision: snapshot.revision,
            value: value,
            secondaryValue: secondaryValue,
            turnID: thread?.turnID,
            approvalID: targetApproval?.id,
            approvalContentHash: targetApproval?.approvalContentHash
        )

        if kind != .select {
            pending[command.requestID] = command
            if !isDemo {
                saveJournal(loadJournal() + [command])
            }
        }
        lastReceipt = nil
        onChange?()

        let sender = transport
        Task { [weak self] in
            do {
                try await sender.send(command)
            } catch {
                guard let self, self.pending[command.requestID] != nil else { return }
                self.receive(.receipt(MicroReceipt(
                    requestID: command.requestID,
                    status: .unknown,
                    reason: error.localizedDescription,
                    threadID: targetID
                )))
            }
        }

        if kind != .select {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, self.pending[command.requestID] != nil else { return }
                self.receive(.receipt(MicroReceipt(
                    requestID: command.requestID,
                    status: .unknown,
                    reason: "等待 Host 确认结果",
                    threadID: targetID
                )))
            }
        }
    }

    func stepEffort(_ steps: Int) {
        guard let thread = selected else { return }
        if let modelID = thread.modelID,
           let model = models.first(where: { $0.id == modelID }),
           let currentEffort = thread.effort,
           let index = model.efforts.firstIndex(of: currentEffort) {
            let next = min(max(index + steps, 0), model.efforts.count - 1)
            if next != index {
                execute(.effort, value: model.efforts[next])
            }
        } else {
            execute(.stepEffort, value: String(steps >= 0 ? 1 : -1))
        }
    }

    func toggleModel() {
        guard let selected, models.count > 1 else { return }
        let index = models.firstIndex(where: { $0.id == selected.modelID }) ?? 0
        let nextModel = models[(index + 1) % models.count]
        execute(.model, value: nextModel.id)
    }

    func fetchThreadDetail(_ threadID: String) {
        Task { [weak self] in
            guard let self else { return }
            try? await self.transport.requestThreadDetail(threadID)
        }
    }

    func fetchThreadsList(query: String? = nil, cursor: String? = nil, limit: Int = 30) {
        Task { [weak self] in
            guard let self else { return }
            try? await self.transport.requestThreadsList(query: query, cursor: cursor, limit: limit)
        }
    }

    func requestTakeover() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.transport.requestTakeover()
            } catch {
                self.onError?(error.localizedDescription)
            }
        }
    }

    func queryPending() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.transport.query(Array(self.pending.keys))
            } catch {
                self.onError?(error.localizedDescription)
            }
        }
    }

    func clearUncertainCommands(forThread threadID: String? = nil) {
        let hostID = snapshot?.hostID ?? activeHost?.id ?? "demo"
        let toRemove = pending.filter { reqID, cmd in
            guard uncertain.contains(reqID), cmd.hostID == hostID else { return false }
            if let threadID { return cmd.threadID == threadID }
            return true
        }.map(\.key)

        for id in toRemove {
            pending.removeValue(forKey: id)
            uncertain.remove(id)
        }
        if !isDemo {
            let removedSet = Set(toRemove)
            saveJournal(loadJournal().filter { !removedSet.contains($0.requestID) })
        }
        onChange?()
    }

    // MARK: - File-Protected Unresolved Command Journal

    private static var journalFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = dir.appendingPathComponent("CodexMicro", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("unresolved_commands_v2.json")
    }

    private func loadJournal() -> [MicroCommand] {
        guard let data = try? Data(contentsOf: Self.journalFileURL),
              let decoded = try? JSONDecoder().decode([MicroCommand].self, from: data) else {
            return []
        }
        return decoded
    }

    private func saveJournal(_ commands: [MicroCommand]) {
        guard let data = try? JSONEncoder().encode(commands) else { return }
        try? data.write(to: Self.journalFileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
