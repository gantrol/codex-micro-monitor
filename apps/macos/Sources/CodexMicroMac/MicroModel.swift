import Foundation
import Combine

// Only explicit observations produce colored activity. Completion is not unread.
enum TaskSignal: String {
    case unknown, idle, running, waiting, question, unread, error
    init(status: [String: Any]) {
        switch status["type"] as? String {
        case "idle": self = .idle
        case "systemError": self = .error
        case "active":
            let flags = status["activeFlags"] as? [String] ?? []
            self = flags.contains("waitingOnApproval") || flags.contains("waitingOnUserInput") ? .waiting : .running
        default: self = .unknown
        }
    }
}

struct ThreadRow: Identifiable {
    let id: String
    let title: String
    let signal: TaskSignal
    let project: String
    init?(_ raw: [String: Any]) {
        guard let id = raw["id"] as? String, UUID(uuidString: id) != nil else { return nil }
        self.id = id
        let title = raw["title"] as? String ?? ""
        self.title = title.isEmpty ? tr("untitled") : String(title.prefix(160))
        signal = TaskSignal(status: raw["status"] as? [String: Any] ?? [:])
        let cwd = raw["cwd"] as? String ?? ""
        project = cwd.isEmpty ? "" : URL(fileURLWithPath: cwd).lastPathComponent
    }
    var label: String { project.isEmpty ? title : "\(project) › \(title)" }
}

struct UsageWindow: Identifiable {
    let id: String
    let label: String
    let available: Bool
    let remaining: Double?
    let reset: Date?
    var text: String { remaining.map { "\(Int($0.rounded()))%" } ?? "—" }
}

@MainActor final class MicroModel: ObservableObject {
    @Published private(set) var threads: [ThreadRow] = []
    @Published private(set) var displayedThreads: [ThreadRow] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var state: [String: Any] = [:]
    @Published private(set) var usage: [String: Any] = [:]
    @Published private(set) var connected = false
    @Published private(set) var desktopConnected = false
    @Published private(set) var refreshing = false
    @Published private(set) var opening = false
    @Published private(set) var controlling = false
    @Published private(set) var models: [ModelChoice] = []
    @Published private(set) var controlError: String?
    @Published private(set) var needsControlRefresh = false
    @Published private(set) var lastRefreshed: Date?
    @Published private(set) var lastUsageRefresh: Date?
    @Published private(set) var error: String?
    @Published private(set) var encoderMode: String?
    @Published private(set) var analogActions: [String: String] = [:]
    @Published private(set) var reasoningFeedback: String?
    @Published var monitor = false
    private let client = DesktopClient()
    private var polling: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var controlTask: Task<Void, Never>?
    private var lifecycle = 0
    private var selectionVersion = 0
    private var interactions: Set<String> = []
    private var modelNames: [String: String] = [:]
    private var lastCatalog = Date.distantPast
    private var catalogueError: String?
    private var selectionError: String?
    private var openError: String?
    private var reasoningInput: ReasoningInput?
    private var feedbackTask: Task<Void, Never>?

    private final class ReasoningInput {
        let target: ControlTarget
        let efforts: [String]
        var observed: [String: Any]
        var desired: Int
        var acknowledged: Int
        var version: Int
        var lastInput = ProcessInfo.processInfo.systemUptime
        var ended = false
        var cancelled = false
        init(target: ControlTarget, efforts: [String], index: Int) {
            self.target = target; self.efforts = efforts; observed = target.settings
            desired = index; acknowledged = index; version = target.version
        }
    }

    var currentModel: String { state["model"] as? String ?? "" }
    var currentModelTitle: String { modelNames[currentModel] ?? currentModel }
    var currentEffort: String { state["effort"] as? String ?? "" }
    var collaborationMode: String? { (state["collaborationMode"] as? [String: Any])?["mode"] as? String }
    var canTogglePlan: Bool { controlTarget != nil && ["plan", "default"].contains(collaborationMode ?? "") }
    var fast: Bool { ["fast", "priority"].contains(state["serviceTier"] as? String ?? "") }
    var currentDefinition: ModelChoice? { models.first { $0.id == currentModel } }
    var approvals: [ApprovalChoice] { (state["approvals"] as? [[String: Any]] ?? []).compactMap(ApprovalChoice.init) }
    var controlTarget: ControlTarget? {
        guard let id = selectedID, connected, desktopConnected, !opening, !controlling, reasoningInput == nil, !needsControlRefresh else { return nil }
        return ControlTarget(threadID: id, title: selectedTitle, version: selectionVersion, lifecycle: lifecycle,
            settings: ["model": state["model"] ?? NSNull(), "effort": state["effort"] ?? NSNull(), "serviceTier": state["serviceTier"] ?? NSNull(), "collaborationMode": state["collaborationMode"] ?? NSNull()],
            turnID: state["activeTurnId"] as? String)
    }
    var canSetFast: Bool { controlTarget != nil && (fast || currentDefinition?.supportsFast == true) }
    var selectedTitle: String { threads.first { $0.id == selectedID }?.label ?? tr("selectChat") }
    var usageWindows: [UsageWindow] {
        let buckets = usage["rateLimitsByLimitId"] as? [String: [String: Any]] ?? [:]
        let limits = buckets["codex"] ?? usage["rateLimits"] as? [String: Any] ?? [:]
        return ["primary", "secondary"].map { key in
            let window = limits[key] as? [String: Any] ?? [:]
            let used = (window["usedPercent"] as? NSNumber)?.doubleValue
            let remaining = used.flatMap { $0.isFinite ? max(0, min(100, 100 - $0)) : nil }
            let minutes = (window["windowDurationMins"] as? NSNumber)?.intValue
            let label: String
            if let minutes, minutes > 0 {
                if minutes % 1440 == 0 { label = String(format: tr("days"), minutes / 1440) }
                else if minutes % 60 == 0 { label = String(format: tr("hours"), minutes / 60) }
                else { label = String(format: tr("minutes"), minutes) }
            } else { label = tr(key + "Usage") }
            let reset = (window["resetsAt"] as? NSNumber)?.doubleValue
            return UsageWindow(id: key, label: label, available: !window.isEmpty, remaining: remaining,
                               reset: reset.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil })
        }
    }
    var quota: String { usageWindows.first(where: { $0.remaining != nil })?.text ?? "—" }

    func signal(for row: ThreadRow) -> TaskSignal {
        guard connected, threads.contains(where: { $0.id == row.id }) else { return .unknown }
        if row.id == selectedID, desktopConnected {
            if state["hasPendingQuestion"] as? Bool == true { return .question }
            let approvals = state["approvals"] as? [[String: Any]] ?? []
            if !approvals.isEmpty { return .waiting }
            if let runtime = state["runtimeStatus"] as? [String: Any] {
                let signal = TaskSignal(status: runtime)
                return signal == .idle && state["hasUnreadTurn"] as? Bool == true ? .unread : signal
            }
        }
        return row.signal
    }

    func setInteraction(_ token: String, active: Bool) {
        if active { interactions.insert(token) } else { interactions.remove(token) }
        reconcileRoster()
    }

    private func reconcileRoster() {
        guard !opening, !controlling, interactions.isEmpty else {
            let fresh = Dictionary(threads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            displayedThreads = displayedThreads.map { fresh[$0.id] ?? $0 }
            return
        }
        displayedThreads = Array(threads.prefix(14))
    }

    func canOpen(_ row: ThreadRow) -> Bool {
        connected && !opening && !controlling && threads.contains { $0.id == row.id }
    }

    func start() {
        guard polling == nil else { return }
        lifecycle += 1
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
            }
        }
    }

    func stop() {
        cancelDialInput()
        feedbackTask?.cancel(); reasoningFeedback = nil
        lifecycle += 1
        selectionVersion += 1
        polling?.cancel(); polling = nil
        selectionTask?.cancel(); selectionTask = nil
        controlTask?.cancel()
        interactions.removeAll()
        connected = false
        desktopConnected = false
        state = [:]
        encoderMode = nil
        analogActions = [:]
        usage = [:]
        lastCatalog = .distantPast
    }

    func closeTransport() async { await client.close() }

    func refresh() async {
        guard !refreshing, !controlling, reasoningInput == nil else { return }
        let generation = lifecycle
        refreshing = true
        defer { refreshing = false }
        do {
            let result = try await client.execute("list_keypad_threads", arguments: [:])
            guard !Task.isCancelled, generation == lifecycle else { return }
            var seen: Set<String> = []
            threads = (result["threads"] as? [[String: Any]] ?? []).compactMap(ThreadRow.init).filter { seen.insert($0.id).inserted }
            reconcileRoster()
            connected = true
            lastRefreshed = Date()
            catalogueError = nil
            if let selectedID, !threads.contains(where: { $0.id == selectedID }) {
                selectionVersion += 1
                self.selectedID = nil
                state = [:]; desktopConnected = false
            }
        } catch {
            guard !Task.isCancelled, generation == lifecycle else { return }
            connected = false; desktopConnected = false
            state = [:]; usage = [:]; lastCatalog = .distantPast
            catalogueError = error.localizedDescription
            updateError()
            return
        }
        do {
            let layout = try await client.execute("get_keypad_layout", arguments: [:])
            guard !Task.isCancelled, generation == lifecycle else { return }
            encoderMode = layout["encoderMode"] as? String
            analogActions = layout["analogActions"] as? [String: String] ?? [:]
        } catch {
            guard !Task.isCancelled, generation == lifecycle else { return }
            encoderMode = nil
            analogActions = [:]
        }
        if Date().timeIntervalSince(lastCatalog) > 60 {
            do {
                let catalog = try await client.execute("get_keypad_models", arguments: [:])
                guard !Task.isCancelled, generation == lifecycle else { return }
                modelNames = Dictionary((catalog["data"] as? [[String: Any]] ?? []).compactMap { row in
                    guard let id = row["model"] as? String else { return nil }
                    return (id, row["displayName"] as? String ?? id)
                }, uniquingKeysWith: { first, _ in first })
                var seen: Set<String> = []
                models = (catalog["data"] as? [[String: Any]] ?? []).compactMap(ModelChoice.init).filter { seen.insert($0.id).inserted }
                let limits = try await client.execute("get_keypad_usage", arguments: [:])
                guard !Task.isCancelled, generation == lifecycle else { return }
                usage = limits
                lastUsageRefresh = Date(); lastCatalog = Date()
            } catch {
                guard !Task.isCancelled, generation == lifecycle else { return }
                usage = [:]
                catalogueError = error.localizedDescription
            }
        }
        await refreshSelection()
        updateError()
    }

    // Selection here is an explicit read target; it does not claim to observe Codex's foreground chat.
    func select(_ id: String, open: Bool = false) {
        guard !opening, !controlling, UUID(uuidString: id) != nil else { return }
        cancelDialInput()
        feedbackTask?.cancel(); reasoningFeedback = nil
        selectionTask?.cancel()
        selectionVersion += 1
        selectedID = id
        state = [:]; desktopConnected = false
        selectionError = nil; openError = nil; updateError()
        let generation = lifecycle
        let version = selectionVersion
        selectionTask = Task { [weak self] in
            guard let self else { return }
            if open {
                opening = true
                defer { opening = false; reconcileRoster() }
                do { _ = try await client.execute("open_keypad_thread", arguments: ["thread_id": id]) }
                catch {
                    if generation == lifecycle, version == selectionVersion { openError = error.localizedDescription }
                }
            }
            guard !Task.isCancelled, generation == lifecycle, version == selectionVersion else { return }
            await refreshSelection()
            updateError()
        }
    }

    private func refreshSelection() async {
        guard let id = selectedID else { return }
        let version = selectionVersion, generation = lifecycle
        do {
            let result = try await client.execute("get_keypad_state", arguments: ["thread_id": id])
            guard !Task.isCancelled, version == selectionVersion, generation == lifecycle else { return }
            state = result; desktopConnected = true; selectionError = nil
        } catch {
            guard !Task.isCancelled, version == selectionVersion, generation == lifecycle else { return }
            state = [:]; desktopConnected = false
            selectionError = error.localizedDescription
        }
    }

    func isCurrent(_ target: ControlTarget) -> Bool {
        target.threadID == selectedID && target.version == selectionVersion && target.lifecycle == lifecycle
            && desktopConnected && connected && !controlling && !needsControlRefresh
    }

    func setModel(_ choice: ModelChoice, target: ControlTarget) {
        let oldEffort = target.settings["effort"] as? String ?? ""
        let effort = choice.efforts.contains(oldEffort) ? oldEffort : choice.defaultEffort
        perform("set_keypad_model", target: target, arguments: ["model": choice.id, "effort": effort, "expected_settings": target.settings])
    }

    func setReasoning(_ effort: String, target: ControlTarget) {
        perform("set_keypad_reasoning", target: target, arguments: ["effort": effort, "expected_settings": target.settings])
    }

    func toggleFast(target: ControlTarget) {
        perform("set_keypad_fast", target: target, arguments: ["enabled": !target.fast, "expected_settings": target.settings])
    }

    func reply(_ approval: ApprovalChoice, decision: String, target: ControlTarget) {
        perform("reply_keypad_approval", target: target, arguments: ["request_id": approval.id, "decision": decision,
            "expected_request": ["method": approval.method, "details": approval.details]])
    }

    func stopTurn(target: ControlTarget) {
        guard let turn = target.turnID else { return }
        perform("stop_keypad_turn", target: target, arguments: ["turn_id": turn])
    }

    func togglePlan(target: ControlTarget) {
        perform("toggle_keypad_plan", target: target, arguments: ["expected_settings": target.settings])
    }

    func toggleQuickModel(_ profile: DialProfile, target: ControlTarget) {
        guard isCurrent(target) else { controlError = tr("targetChanged"); return }
        let sameModel = profile.a.model == profile.b.model
        let effortA = profile.a.effort ?? models.first(where: { $0.id == profile.a.model })?.defaultEffort
        let selectB = target.settings["model"] as? String == profile.a.model &&
            (!sameModel || target.settings["effort"] as? String == effortA)
        let preset = selectB ? profile.b : profile.a
        guard let choice = models.first(where: { $0.id == preset.model }),
              choice.efforts.contains(preset.effort ?? choice.defaultEffort) else {
            controlError = tr("presetUnavailable"); return
        }
        perform("set_keypad_model", target: target, arguments: ["model": choice.id,
            "effort": preset.effort ?? choice.defaultEffort, "expected_settings": target.settings])
    }

    func prepareDial(_ profile: DialProfile) -> DialActions? {
        let input: ReasoningInput
        let canTap: Bool
        if let existing = reasoningInput {
            // A new wheel burst can update the destination while the preceding
            // burst is being acknowledged. It never starts a second writer.
            guard existing.ended, !existing.cancelled, existing.target.lifecycle == lifecycle,
                  existing.version == selectionVersion else { return nil }
            existing.ended = false; input = existing; canTap = false
        } else {
            guard let target = controlTarget else { return nil }
            let efforts = currentDefinition?.efforts ?? []
            let index = efforts.firstIndex(of: currentEffort) ?? -1
            input = ReasoningInput(target: target, efforts: efforts, index: index)
            reasoningInput = input; canTap = true
        }
        setInteraction("dial", active: true)
        return DialActions(step: { [weak self, weak input] physical in
            guard let self, let input else { return }
            self.stepDial(input, steps: profile.invertDirection ? physical : -physical)
        }, end: { [weak self, weak input] cancelled in
            guard let self, let input, self.reasoningInput === input else { return }
            input.ended = true
            if cancelled { input.cancelled = true }
            if !self.controlling { self.releaseDial(input) }
        }, tap: { [weak self] in if canTap { self?.toggleQuickModel(profile, target: input.target) } })
    }

    private func stepDial(_ input: ReasoningInput, steps: Int) {
        guard reasoningInput === input, !input.cancelled, !input.ended,
              input.target.threadID == selectedID, input.target.lifecycle == lifecycle,
              input.version == selectionVersion, connected, desktopConnected, !needsControlRefresh else { return }
        guard input.desired >= 0, !input.efforts.isEmpty else { controlError = tr("effortUnavailable"); return }
        let next = max(0, min(input.efforts.count - 1, input.desired + max(-64, min(64, steps))))
        guard next != input.desired else { return }
        input.desired = next; input.lastInput = ProcessInfo.processInfo.systemUptime
        feedbackTask?.cancel(); reasoningFeedback = input.efforts[next]
        guard !controlling else { return }
        controlling = true; controlError = nil
        selectionVersion += 1; input.version = selectionVersion
        selectionTask?.cancel()
        controlTask = Task { [weak self] in
            guard let self else { return }
            defer {
                controlling = false; controlTask = nil
                if input.ended || input.cancelled { releaseDial(input) }
                reconcileRoster()
            }
            do {
                // Coalesce a burst before the first write. Later steps update
                // one absolute destination while the preceding write is read back.
                try await Task.sleep(for: .milliseconds(80))
                while reasoningInput === input, !input.cancelled,
                      input.version == selectionVersion, input.target.lifecycle == lifecycle, connected, desktopConnected,
                      input.desired != input.acknowledged {
                    guard ProcessInfo.processInfo.systemUptime - input.lastInput <= 5 else {
                        input.cancelled = true; break
                    }
                    let destination = input.desired
                    let result = try await client.execute("set_keypad_reasoning", arguments: [
                        "thread_id": input.target.threadID, "effort": input.efforts[destination],
                        "expected_settings": input.observed, "input_deadline_uptime": input.lastInput + 5])
                    guard !Task.isCancelled, input.version == selectionVersion, input.target.lifecycle == lifecycle else { return }
                    guard result["verified"] as? Bool == true, let observed = result["state"] as? [String: Any] else {
                        throw NSError(domain: "MicroBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: tr("unverifiedControl")])
                    }
                    state = observed
                    input.observed = ["model": observed["model"] ?? NSNull(), "effort": observed["effort"] ?? NSNull(), "serviceTier": observed["serviceTier"] ?? NSNull(), "collaborationMode": observed["collaborationMode"] ?? NSNull()]
                    input.acknowledged = destination
                }
            } catch {
                input.cancelled = true
                if (error as NSError).domain == "MicroBridge", (error as NSError).code == 2 { needsControlRefresh = true }
                if !Task.isCancelled, input.target.lifecycle == lifecycle {
                    if !(error is CancellationError) { controlError = error.localizedDescription }
                    await refreshSelection()
                }
            }
        }
    }

    func cancelDialInput() {
        guard let input = reasoningInput else { return }
        input.cancelled = true; input.ended = true
        reasoningFeedback = nil
        if !controlling { releaseDial(input) }
    }

    private func releaseDial(_ input: ReasoningInput) {
        guard reasoningInput === input else { return }
        reasoningInput = nil
        setInteraction("dial", active: false)
        if input.cancelled { reasoningFeedback = nil; return }
        // Feedback shows the last observation once the gesture has drained.
        if reasoningFeedback != nil {
            reasoningFeedback = currentEffort
            feedbackTask?.cancel()
            feedbackTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(1200)) } catch { return }
                self?.reasoningFeedback = nil
            }
        }
    }

    private func perform(_ operation: String, target: ControlTarget, arguments: [String: Any]) {
        guard reasoningInput == nil, isCurrent(target) else { controlError = tr("targetChanged"); return }
        controlling = true
        controlError = nil
        // Invalidate any in-flight observation. It must not overwrite readback
        // with a snapshot taken before the operation.
        selectionVersion += 1
        selectionTask?.cancel()
        let version = selectionVersion
        var parameters = arguments
        parameters["thread_id"] = target.threadID
        controlTask = Task { [weak self] in
            guard let self else { return }
            defer { controlling = false; controlTask = nil; reconcileRoster() }
            do {
                let result = try await client.execute(operation, arguments: parameters)
                if let warning = result["goalPauseError"] as? String { controlError = warning }
            } catch {
                // Keep uncertainty across hide/show. No mutation is replayed.
                if (error as NSError).domain == "MicroBridge", (error as NSError).code == 2 { needsControlRefresh = true }
                if !(error is CancellationError) { controlError = error.localizedDescription }
            }
            guard !Task.isCancelled, target.lifecycle == lifecycle, version == selectionVersion else { return }
            await refreshSelection()
            updateError()
        }
    }

    func dismissControlError() { controlError = nil }

    func refreshControls() {
        guard !controlling, reasoningInput == nil else { return }
        Task {
            let version = selectionVersion, generation = lifecycle
            await refreshSelection()
            guard version == selectionVersion, generation == lifecycle else { return }
            if desktopConnected { needsControlRefresh = false }
            updateError()
        }
    }

    private func updateError() { error = openError ?? catalogueError ?? selectionError }
}
