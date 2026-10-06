import Foundation
import Combine
#if canImport(MicroShared)
import MicroShared
#endif

/// One complete presentation value per main-run-loop update. UIKit never
/// observes partially applied identity/activity transitions.
struct MicroViewState {
    struct TaskSlot {
        let row: ThreadRow?
        let command: String?
        let label: String
        let enabled: Bool
    }
    let connected: Bool
    let desktopConnected: Bool
    let refreshing: Bool
    let controlling: Bool
    let needsControlRefresh: Bool
    let layoutAvailable: Bool
    let separateMicrophoneKeys: Bool
    let isDraft: Bool
    let isNativeComposer: Bool
    let usesNativeSettings: Bool
    let fast: Bool
    let controlError: String?
    let encoderMode: String?
    let reasoningFeedback: String?
    let rosterScope: String?
    let selectedID: String?
    let displayedThreadID: String?
    let currentThreadID: String?
    let focusVerifiedCurrentID: String?
    let currentModel: String
    let currentModelTitle: String
    let currentEffort: String
    let selectedTitle: String
    let quota: String
    let collaborationMode: String?
    let contextSource: ConversationContextStore.Source
    let currentDefinition: ModelChoice?
    let controlTarget: ControlTarget?
    let models: [ModelChoice]
    let approvals: [ApprovalChoice]
    let threads: [ThreadRow]
    let knownThreads: [ThreadRow]
    let taskChoices: [ThreadRow]
    let usageWindows: [UsageWindow]
    let analogBindings: [String: [String: Any]]
    let encoderBindings: [String: [String: Any]]
    let slots: [String: [String: Any]]
    let tasks: [TaskSlot]
    let lamps: [String: TaskLampPresentation]
    let unreadActions: Set<String>
    let keycaps: [String: String]
    let bindings: [String: [String: Any]]

    @MainActor init(session: MicroSession) {
        connected = session.connected
        desktopConnected = session.desktopConnected
        refreshing = session.refreshing
        controlling = session.controlling
        needsControlRefresh = session.needsControlRefresh
        layoutAvailable = session.layoutAvailable
        separateMicrophoneKeys = session.separateMicrophoneKeys
        isDraft = session.isDraft
        isNativeComposer = session.isNativeComposer
        usesNativeSettings = session.usesNativeSettings
        fast = session.fast
        controlError = session.controlError
        encoderMode = session.encoderMode
        reasoningFeedback = session.reasoningFeedback
        rosterScope = session.rosterScope
        selectedID = session.selectedID
        displayedThreadID = session.displayedThreadID
        currentThreadID = session.currentThreadID
        focusVerifiedCurrentID = session.focusVerifiedCurrentID
        currentModel = session.currentModel
        currentModelTitle = session.currentModelTitle
        currentEffort = session.currentEffort
        selectedTitle = session.selectedTitle
        quota = session.quota
        collaborationMode = session.collaborationMode
        contextSource = session.contextSource
        currentDefinition = session.currentDefinition
        controlTarget = session.controlTarget
        models = session.models
        approvals = session.approvals
        threads = session.threads
        knownThreads = session.knownThreads
        taskChoices = session.taskChoices
        usageWindows = session.usageWindows
        analogBindings = session.analogBindings
        encoderBindings = session.encoderBindings
        slots = session.slots
        tasks = TaskSlots.ids.indices.map { index in
            TaskSlot(row: session.taskRow(at: index), command: session.taskCommand(at: index),
                     label: session.taskLabel(at: index), enabled: session.canUseTask(index))
        }
        // A priority roster may contain 10,000 rows. Project only the visible
        // keys; evaluating every row on every activity tick would block UIKit.
        let displayed = tasks.compactMap(\.row)
        lamps = Dictionary(displayed.map { ($0.id, session.lampPresentation(for: $0)) }, uniquingKeysWith: { first, _ in first })
        unreadActions = Set(displayed.filter(session.canMarkUnread).map(\.id))
        keycaps = Dictionary(uniqueKeysWithValues: KeySlots.defaults.keys.map { ($0, session.keycap(for: $0)) })
        bindings = Dictionary(uniqueKeysWithValues: KeySlots.defaults.keys.compactMap { key in
            session.binding(for: key).map { (key, $0) }
        })
    }
}

@MainActor final class MicroViewModel: ObservableObject {
    @Published private(set) var viewState: MicroViewState
    @Published var monitor = false
    let preferences: Settings
    private let session: MicroSession
    private var subscriptions = Set<AnyCancellable>()
    private var presentationScheduled = false
    private var lifecycleRevision = 0
    private var closingTransport: Task<Void, Never>?

    init(settings: Settings, session: MicroSession? = nil) {
        preferences = settings
        let session = session ?? MicroSession(settings: settings)
        self.session = session
        viewState = MicroViewState(session: session)
        session.objectWillChange.sink { [weak self] _ in self?.schedulePresentation() }.store(in: &subscriptions)
        settings.objectWillChange.sink { [weak self] _ in self?.schedulePresentation() }.store(in: &subscriptions)
    }

    private func schedulePresentation() {
        guard !presentationScheduled else { return }
        presentationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.presentationScheduled = false
            self.viewState = MicroViewState(session: self.session)
        }
    }

    var connected: Bool { viewState.connected }
    var desktopConnected: Bool { viewState.desktopConnected }
    var refreshing: Bool { viewState.refreshing }
    var controlling: Bool { viewState.controlling }
    var needsControlRefresh: Bool { viewState.needsControlRefresh }
    var layoutAvailable: Bool { viewState.layoutAvailable }
    var separateMicrophoneKeys: Bool { viewState.separateMicrophoneKeys }
    var isDraft: Bool { viewState.isDraft }
    var isNativeComposer: Bool { viewState.isNativeComposer }
    var usesNativeSettings: Bool { viewState.usesNativeSettings }
    var fast: Bool { viewState.fast }
    var controlError: String? { viewState.controlError }
    var encoderMode: String? { viewState.encoderMode }
    var reasoningFeedback: String? { viewState.reasoningFeedback }
    var rosterScope: String? { viewState.rosterScope }
    var selectedID: String? { viewState.selectedID }
    var displayedThreadID: String? { viewState.displayedThreadID }
    var currentThreadID: String? { viewState.currentThreadID }
    var focusVerifiedCurrentID: String? { viewState.focusVerifiedCurrentID }
    var currentModel: String { viewState.currentModel }
    var currentModelTitle: String { viewState.currentModelTitle }
    var currentEffort: String { viewState.currentEffort }
    var selectedTitle: String { viewState.selectedTitle }
    var quota: String { viewState.quota }
    var collaborationMode: String? { viewState.collaborationMode }
    var contextSource: ConversationContextStore.Source { viewState.contextSource }
    var currentDefinition: ModelChoice? { viewState.currentDefinition }
    var controlTarget: ControlTarget? { viewState.controlTarget }
    var models: [ModelChoice] { viewState.models }
    var approvals: [ApprovalChoice] { viewState.approvals }
    var threads: [ThreadRow] { viewState.threads }
    var knownThreads: [ThreadRow] { viewState.knownThreads }
    var taskChoices: [ThreadRow] { viewState.taskChoices }
    var usageWindows: [UsageWindow] { viewState.usageWindows }
    var analogBindings: [String: [String: Any]] { viewState.analogBindings }
    var encoderBindings: [String: [String: Any]] { viewState.encoderBindings }
    var slots: [String: [String: Any]] { viewState.slots }

    func taskRow(at index: Int) -> ThreadRow? { viewState.tasks.indices.contains(index) ? viewState.tasks[index].row : nil }
    func taskCommand(at index: Int) -> String? { viewState.tasks.indices.contains(index) ? viewState.tasks[index].command : nil }
    func taskLabel(at index: Int) -> String { viewState.tasks.indices.contains(index) ? viewState.tasks[index].label : tr("emptySlot") }
    func canUseTask(_ index: Int) -> Bool { viewState.tasks.indices.contains(index) && viewState.tasks[index].enabled }
    func canMarkUnread(_ row: ThreadRow) -> Bool { viewState.unreadActions.contains(row.id) }
    func displaySignal(for row: ThreadRow) -> TaskSignal { viewState.lamps[row.id]?.displayed ?? .unknown }

    // User intents pass through the coordinator, which revalidates captured
    // identities, generations and leases immediately before dispatch.
    func start() {
        lifecycleRevision += 1
        let revision = lifecycleRevision
        guard let closingTransport else { session.start(); return }
        Task { [weak self] in
            await closingTransport.value
            guard let self, self.lifecycleRevision == revision else { return }
            self.closingTransport = nil
            self.session.start()
        }
    }
    func stop() {
        lifecycleRevision += 1
        session.stop()
        guard closingTransport == nil else { return }
        let session = self.session
        closingTransport = Task { await session.closeTransport() }
    }
    func closeTransport() async { await closingTransport?.value }
    func refresh() async { await session.refresh() }
    func recoverObservation() { session.recoverObservation() }
    func refreshControls(clearError: Bool = true) { session.refreshControls(clearError: clearError) }
    func preferencesChanged() { session.preferencesChanged() }
    func setInteraction(_ token: String, active: Bool) { session.setInteraction(token, active: active) }
    func assignTask(_ slot: Int, thread: String?) { session.assignTask(slot, thread: thread) }
    func assignTaskCommand(_ slot: Int, command: String?) { session.assignTaskCommand(slot, command: command) }
    func captureRecentTaskLayout() { session.captureRecentTaskLayout() }
    func prepareTask(_ index: Int, open: Bool = true) -> (() -> Void)? {
        // A transport update can precede the next UI projection. Never capture
        // the new occupant of a key while the user still sees the old occupant.
        guard canUseTask(index), session.rosterScope == viewState.rosterScope,
              session.taskRow(at: index)?.id == taskRow(at: index)?.id,
              session.taskCommand(at: index) == taskCommand(at: index) else { return nil }
        return session.prepareTask(index, open: open)
    }
    func select(_ id: String, open: Bool = false) { session.select(id, open: open) }
    func markUnread(_ row: ThreadRow) { session.markUnread(row) }
    func binding(for key: String) -> [String: Any]? { viewState.bindings[KeySlots.id(key)] }
    func keycap(for key: String) -> String { viewState.keycaps[KeySlots.id(key)] ?? key }
    func approvalDecision(for key: String) -> String? {
        guard let action = binding(for: key), action["type"] as? String == "command" else { return nil }
        return ["approval.approve": "accept", "approval.decline": "decline"][action["commandId"] as? String ?? ""]
    }
    func prepareKey(_ key: String) -> (() -> Void)? {
        guard session.keycap(for: key) == keycap(for: key),
              session.binding(for: key) as NSDictionary? == binding(for: key) as NSDictionary? else { return nil }
        return session.prepareKey(key)
    }
    func prepareBinding(_ binding: [String: Any]?) -> (() -> Void)? { session.prepareBinding(binding) }
    func prepareDial(_ profile: DialProfile) -> DialActions? { session.prepareDial(profile) }
    func prepareNavigationDial(_ mode: String, profile: DialProfile) -> DialActions? { session.prepareNavigationDial(mode, profile: profile) }
    func prepareJoystick() -> ((String) -> Bool)? { session.prepareJoystick() }
    func cancelDialInput() { session.cancelDialInput() }
    func unavailableInput() { session.unavailableInput() }
    func openOfficialMicroSettings() { session.openOfficialMicroSettings() }
    func isCurrent(_ target: ControlTarget) -> Bool { session.isCurrent(target) }
    func reply(_ approval: ApprovalChoice, decision: String, target: ControlTarget) { session.reply(approval, decision: decision, target: target) }
}
