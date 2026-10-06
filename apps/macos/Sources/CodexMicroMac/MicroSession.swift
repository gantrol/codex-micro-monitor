import Foundation
#if canImport(MicroShared)
import MicroShared
#endif
import Combine
import OSLog

/// Application coordinator. Owns transport, polling and command lifetimes;
/// identity and activity are reduced by their independent stores.
@MainActor final class MicroSession: ObservableObject {
    typealias ContextSource = ConversationContextStore.Source
    @Published private var conversation = ConversationContextStore()
    @Published private var activity = ActivityStore()
    @Published private var connection = ServiceConnectionState()
    @Published private(set) var threads: [ThreadRow] = []
    @Published private(set) var displayedTaskSlots: [ThreadRow?] = []
    @Published private(set) var displayedTaskCommands:[String?]=[]
    @Published private(set) var mappedThreads: [ThreadRow] = []
    @Published private(set) var pinnedThreads:[ThreadRow]=[]
    @Published private(set) var pinnedAvailable=false
    @Published private(set) var priorityComplete=false
    var rosterScope: String? { connection.active?.scope }
    private var contextID: String? { connection.active?.id }
    var displayedThreads:[ThreadRow] {displayedTaskSlots.compactMap {$0}}
    var knownThreads:[ThreadRow] {
        var seen:Set<String>=[]
        return (pinnedThreads+threads+mappedThreads).filter {seen.insert($0.id).inserted}
    }
    var selectedID: String? { conversation.selectedID }
    var explicitTargetID: String? { conversation.explicitTargetID }
    var contextSource: ContextSource { conversation.source }
    var observedDraft: Bool { conversation.isDraft }
    var isNativeComposer: Bool { conversation.isNativeComposer }
    private var clientBindingRevision = 0
    @Published private(set) var state: [String: Any] = [:]
    @Published private(set) var usage: [String: Any] = [:]
    var connected: Bool { connection.isConnected }
    @Published private(set) var desktopConnected = false
    @Published private(set) var refreshing = false
    @Published private(set) var opening = false {
        didSet { if opening && !oldValue { foregroundRequestRevision += 1 } }
    }
    @Published private(set) var controlling = false {
        didSet { if controlling && !oldValue { foregroundRequestRevision += 1 } }
    }
    @Published private(set) var activating = false
    @Published private(set) var models: [ModelChoice] = []
    @Published private(set) var controlError: String? {
        didSet {
            if let controlError, controlError != oldValue { Self.logger.warning("Control action: \(controlError, privacy: .private)") }
        }
    }
    @Published private(set) var needsControlRefresh = false
    @Published private(set) var lastRefreshed: Date?
    @Published private(set) var lastUsageRefresh: Date?
    @Published private(set) var error: String?
    @Published private(set) var encoderMode: String?
    @Published private(set) var analogActions: [String: String] = [:]
    @Published private(set) var reasoningFeedback: String?
    @Published private(set) var forkAvailable = false
    var foreground: [String: Any] {
        get { conversation.foreground }
        set { conversation.observe(newValue, at: observationUptime()) }
    }
    @Published private(set) var slots: [String: [String: Any]] = [:]
    @Published private(set) var analogBindings: [String: [String: Any]] = [:]
    @Published private(set) var encoderBindings: [String: [String: Any]] = [:]
    @Published private(set) var layoutAvailable = false
    @Published var monitor = false
    let preferences: Settings
    init(settings: Settings, client: DesktopControlling? = nil,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         observationUptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        let client = client ?? DesktopClient()
        preferences = settings; self.client = client; self.commands = CommandExecutor(client: client)
        self.uptime = uptime;self.observationUptime=observationUptime
    }
    @Published private(set) var configuredSeparateMicrophoneKeys = false
    var separateMicrophoneKeys: Bool { preferences.layout.separateMicrophoneKeys ?? configuredSeparateMicrophoneKeys }
    private var taskMappingVersion=0
    private var lastTaskSource="recent"
    private var lastTaskMappings:[String:[String:String]]?
    private var lastTaskCommands:[String:[String:String]]?
    private var displayedTaskScope:String?
    private var displayedTaskContext:String?
    private var displayedTaskSource="recent"
    private var rosterRefreshPending=false
    private func scheduleRosterRefresh() {
        let generation=lifecycle
        Task { [weak self] in guard let self,self.lifecycle == generation else {return};await self.refresh() }
    }
    func preferencesChanged() {
        cancelDialInput()
        if lastTaskSource != preferences.layout.agentSource || lastTaskMappings != preferences.layout.taskMappings || lastTaskCommands != preferences.layout.taskCommands {
            lastTaskSource=preferences.layout.agentSource;lastTaskMappings=preferences.layout.taskMappings;lastTaskCommands=preferences.layout.taskCommands
            taskMappingVersion += 1;mappedThreads=[];pinnedThreads=[];pinnedAvailable=false;priorityComplete=false;rosterRefreshPending=true
            scheduleRosterRefresh()
        }
        reconcileRoster()
    }
    func taskRow(at index:Int) -> ThreadRow? {displayedTaskSlots.indices.contains(index) ? displayedTaskSlots[index]:nil}
    func taskCommand(at index:Int)->String? {displayedTaskCommands.indices.contains(index) ? displayedTaskCommands[index]:nil}
    func taskLabel(at index:Int)->String {
        taskRow(at:index)?.label ?? taskCommand(at:index).map {KeySlots.actionLabel(["type":"command","commandId":$0])} ?? tr("emptySlot")
    }
    var taskChoices:[ThreadRow] {
        var rows=knownThreads
        if let row=verifiedClientRow,!rows.contains(where:{$0.id == row.id}) {rows.insert(row,at:0)}
        if let id=selectedID,desktopConnected,!usesNativeSettings,!rows.contains(where:{$0.id == id}),
           let current=ThreadRow(["id":id,"title":selectedTitle,"status":state["runtimeStatus"] ?? [:]]) {rows.insert(current,at:0)}
        return rows
    }
    func assignTask(_ slot:Int,thread:String?) {
        guard connected,let scope=rosterScope,thread == nil || taskChoices.contains(where:{$0.id == thread}) else {return}
        preferences.saveTask(slot,thread:thread,scope:scope);preferencesChanged()
    }
    func assignTaskCommand(_ slot:Int,command:String?) {
        guard connected,let scope=rosterScope else {return}
        preferences.saveTaskCommand(slot,command:command,scope:scope);preferencesChanged()
    }
    func captureRecentTaskLayout() {
        guard connected,let scope=rosterScope else {return}
        var profile=preferences.layout,maps=profile.taskMappings ?? [:]
        maps[scope]=Dictionary(uniqueKeysWithValues:threads.prefix(TaskSlots.count).enumerated().map {(TaskSlots.ids[$0.offset],$0.element.id)})
        profile.taskMappings=maps;profile.agentSource="custom"
        profile.taskCommands?[scope]=nil
        preferences.setLayout(profile);preferencesChanged()
    }
    func prepareTask(_ index:Int,open:Bool=true) -> (() -> Void)? {
        guard canUseTask(index) else {return nil}
        let generation=lifecycle,context=contextID,scope=rosterScope,version=taskMappingVersion
        if let command=taskCommand(at:index),KeySlots.recentIndex(command) == nil {
            guard open,let action=prepareBinding(["type":"command","commandId":command]) else {return nil}
            return { [weak self] in
                guard let self,self.lifecycle == generation,self.contextID == context,self.rosterScope == scope,self.taskMappingVersion == version,
                      self.taskCommand(at:index) == command,self.canUseTask(index) else {return}
                action()
            }
        }
        guard let row=taskRow(at:index) else {return nil}
        return { [weak self] in
            guard let self,self.lifecycle == generation,self.contextID == context,self.rosterScope == scope,self.taskMappingVersion == version,
                  self.taskRow(at:index)?.id == row.id,self.canUseTask(index) else {return}
            self.select(row.id,open:open)
        }
    }
    func canUseTask(_ index:Int) -> Bool {
        guard connected,TaskSlots.ids.indices.contains(index),displayedTaskScope == rosterScope,
              displayedTaskContext == contextID,displayedTaskSource == preferences.layout.agentSource else {return false}
        if let command=taskCommand(at:index) {
            guard preferences.layout.agentSource == "custom",rosterScope != nil,
                  preferences.layout.taskCommandMap(scope:rosterScope)[TaskSlots.ids[index]] == command else {return false}
            if KeySlots.recentIndex(command) != nil {return taskRow(at:index).map(canOpen) ?? false}
            return prepareBinding(["type":"command","commandId":command]) != nil
        }
        guard let row=taskRow(at:index),canOpen(row) else {return false}
        if preferences.layout.agentSource == "custom" {
            return preferences.layout.taskMap(scope:rosterScope)[TaskSlots.ids[index]] == row.id
        }
        if preferences.layout.agentSource == "pinned" {
            return pinnedAvailable && rosterScope != nil && pinnedThreads.indices.contains(index) && pinnedThreads[index].id == row.id
        }
        if preferences.layout.agentSource == "priority" {return priorityComplete}
        return true
    }
    private let client: DesktopControlling
    private let commands: CommandExecutor
    private let uptime: () -> TimeInterval
    private let observationUptime:()->TimeInterval
    private let observations = ObservationCoordinator()
    private var liveSettings: [String: [String: Any]] { activity.liveSettings }
    private var streamConnected: Bool { activity.streamConnected }
    private var pendingNewError: String?
    private var observationEpoch = 0
    private var activityRequestRevision = 0
    private var foregroundRequestRevision = 0
    private var selectionRequestRevision = 0
    private var selectionTask: Task<Void, Never>?
    private var controlTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?
    private var lifecycle = 0
    private var selectionVersion = 0
    private var interactions: Set<String> = []
    private var modelNames: [String: String] = [:]
    private var lastCatalog = Date.distantPast
    private var catalogueError: String?
    private var selectionError: String?
    private var openError: String?
    private var reasoningInput: ReasoningInput?
    private enum SettingAction {
        case fast, plan, reasoning(Int)
        init?(_ command: String) {
            switch command {
            case "composer.toggleFastMode": self = .fast
            case "composer.togglePlanMode": self = .plan
            case "composer.increaseReasoningEffort": self = .reasoning(1)
            case "composer.decreaseReasoningEffort": self = .reasoning(-1)
            default: return nil
            }
        }
    }
    private final class SettingsInput {
        let target: ControlTarget
        var pending: [(SettingAction, TimeInterval)] = []
        init(_ target: ControlTarget) { self.target = target }
    }
    private var settingsInput: SettingsInput?
    private final class NavigationInput {
        let originToken:String
        var token:String
        var pending:[(String,Int,TimeInterval)]=[]
        init(_ token:String) { originToken=token;self.token=token }
    }
    private var navigationInput:NavigationInput?
    // Match Windows' bounded queue wait. Six native operations can each take
    // up to ten seconds; a five-second queue deadline drops later clicks.
    private static let settingsQueueWait: TimeInterval = 60
    private var feedbackTask: Task<Void, Never>?
    private var refreshingControls = false
    private var canAutomaticallyRefreshControls = false
    private static let logger = Logger(subsystem: "com.gantrol.codex-micro-monitor", category: "control")

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
    var currentEffort: String {
        if let effort = state["effort"] as? String { return effort }
        // An existing chat's null effort selects the catalog default. Drafts
        // still need their actual composer setting to be observed.
        return usesNativeSettings ? "" : currentDefinition?.defaultEffort ?? ""
    }
    var collaborationMode: String? { (state["collaborationMode"] as? [String: Any])?["mode"] as? String }
    var canTogglePlan: Bool { controlTarget != nil && ["plan", "default"].contains(collaborationMode ?? "") && (!usesNativeSettings || foreground["draftPlanAvailable"] as? Bool == true) }
    var fast: Bool { ["fast", "priority"].contains(state["serviceTier"] as? String ?? "") }
    var currentDefinition: ModelChoice? { models.first { $0.id == currentModel } }
    var approvals: [ApprovalChoice] { (state["approvals"] as? [[String: Any]] ?? []).compactMap(ApprovalChoice.init) }
    var nativeToken: String? {
        guard !opening, !controlling, !activating, !needsControlRefresh else { return nil }
        return conversation.nativeLease(at: observationUptime())?.token
    }
    var isDraft: Bool { observedDraft }
    var usesNativeSettings: Bool { isDraft || isNativeComposer }
    var observedCurrentIdentity: ConversationContextStore.ObservedIdentity? {
        guard !opening else { return nil }
        return conversation.observedIdentity(scope: rosterScope, context: contextID, at: observationUptime())
    }
    var currentThreadID: String? {
        guard contextSource == .foreground, let observed = observedCurrentIdentity,
              case .thread(let id) = observed.identity else { return nil }
        return id
    }
    var displayedThreadID: String? { explicitTargetID ?? currentThreadID }
    private var verifiedClientRow: ThreadRow? {
        guard connected, !opening else { return nil }
        return conversation.verifiedClientRow(scope: rosterScope, context: contextID, at: observationUptime())
    }
    var focusVerifiedCurrentID: String? {
        guard connected, !opening else { return nil }
        return conversation.focusVerifiedID(scope: rosterScope, context: contextID, at: observationUptime())
    }
    private var targetID: String? { isDraft ? "draft" : isNativeComposer ? "native-composer" : selectedID }
    var controlTarget: ControlTarget? {
        guard let id = targetID, connected, desktopConnected, !opening, !controlling, !activating, reasoningInput == nil, !needsControlRefresh else { return nil }
        guard contextSource != .foreground || foregroundFresh && foreground["routeReadOnly"] as? Bool != true else { return nil }
        guard !usesNativeSettings || nativeToken != nil else { return nil }
        guard !isNativeComposer || NativeComposerIdentity.settingsOnly(foreground) else { return nil }
        return ControlTarget(threadID: id, title: selectedTitle, version: selectionVersion, lifecycle: lifecycle,
            settings: ["model": state["model"] ?? NSNull(), "effort": state["effort"] ?? NSNull(), "serviceTier": state["serviceTier"] ?? NSNull(), "collaborationMode": state["collaborationMode"] ?? NSNull()],
            turnID: state["activeTurnId"] as? String, uiToken: usesNativeSettings ? nativeToken : nil, contextSource: contextSource.rawValue)
    }
    var canSetFast: Bool { controlTarget != nil && (usesNativeSettings ? foreground["draftFastAvailable"] as? Bool == true : fast || currentDefinition?.supportsFast == true) }
    var canSetReasoning: Bool { controlTarget != nil && (usesNativeSettings ? foreground["draftReasoningAvailable"] as? Bool == true : currentDefinition?.efforts.contains(currentEffort) == true) }
    var canFork: Bool { forkAvailable && controlTarget != nil && !usesNativeSettings }
    var canNavigate: Bool { connected && !opening && !controlling && !activating && reasoningInput == nil }
    var selectedTitle: String {
        if isDraft { return tr("newDraft") }
        if isNativeComposer { return verifiedClientRow?.label ?? tr("currentComposer") }
        if let title=state["title"] as? String, !title.isEmpty { return title }
        return knownThreads.first { $0.id == selectedID }?.label ?? selectedID ?? tr("selectChat")
    }
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
        guard connected, knownThreads.contains(where: { $0.id == row.id }) else { return .unknown }
        var fallback = row.signal
        if row.id == selectedID, desktopConnected {
            let approvals = state["approvals"] as? [[String: Any]] ?? []
            if let runtime = state["runtimeStatus"] as? [String: Any] {
                fallback = TaskSignal.classify(status: runtime, question: state["hasPendingQuestion"] as? Bool ?? false,
                    approval: !approvals.isEmpty, unread: state["hasUnreadTurn"] as? Bool ?? row.hasUnreadTurn)
            } else if !approvals.isEmpty { fallback = .waiting }
            else if state["hasPendingQuestion"] as? Bool == true { fallback = .question }
        }
        return activity.signal(for: row.id, fallback: fallback)
    }
    private var foregroundFresh: Bool { conversation.isFresh(at: observationUptime()) }

    func lampPresentation(for row: ThreadRow) -> TaskLampPresentation {
        let raw = signal(for: row)
        let masked = raw == .unread && row.id == focusVerifiedCurrentID
        let evidence = activity.unreadEvidence[row.id] ?? [:]
        return TaskLampPresentation(raw: raw, displayed: masked ? .idle : raw,
            unreadSource: evidence["source"] as? String ?? "catalog",
            unreadRevision: evidence["revision"] as? Int, activityRevision: activity.revision,
            maskReason: raw != .unread ? .notUnread : masked ? .focusVerified : .focusUnverified)
    }
    func displaySignal(for row: ThreadRow) -> TaskSignal { lampPresentation(for: row).displayed }

    func setInteraction(_ token: String, active: Bool) {
        if active { interactions.insert(token) } else { interactions.remove(token) }
        reconcileRoster()
    }

    func attention(for row: ThreadRow) -> TaskAttention {
        var fallback = row.attention
        if row.id == selectedID, desktopConnected, let runtime = state["runtimeStatus"] as? [String: Any] {
            fallback = TaskAttention.classify(status: runtime, question: state["hasPendingQuestion"] as? Bool ?? false,
                approval: !(state["approvals"] as? [[String: Any]] ?? []).isEmpty,
                unread: state["hasUnreadTurn"] as? Bool ?? row.hasUnreadTurn)
        }
        return activity.attention(for: row.id, fallback: fallback)
    }
    private func reconcileRoster() {
        guard !opening, !controlling, interactions.isEmpty else {
            let fresh = Dictionary(knownThreads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            displayedTaskSlots = displayedTaskSlots.map {row in row.map {fresh[$0.id] ?? $0}}
            return
        }
        displayedTaskScope=rosterScope;displayedTaskContext=contextID;displayedTaskSource=preferences.layout.agentSource
        if preferences.layout.agentSource == "custom" {
            let map=preferences.layout.taskMap(scope:rosterScope)
            let commands=preferences.layout.taskCommandMap(scope:rosterScope)
            let rows=Dictionary(knownThreads.map {($0.id,$0)},uniquingKeysWith:{first,_ in first})
            displayedTaskCommands=TaskSlots.ids.map {commands[$0]}
            displayedTaskSlots=TaskSlots.ids.map {slot in
                if let command=commands[slot] {
                    guard let index=KeySlots.recentIndex(command),threads.indices.contains(index) else {return nil}
                    return threads[index]
                }
                return map[slot].flatMap {rows[$0]}
            }
            return
        }
        displayedTaskCommands=[]
        if preferences.layout.agentSource == "pinned" {
            displayedTaskSlots=pinnedAvailable ? pinnedThreads.map {Optional($0)}:[]
            return
        }
        if preferences.layout.agentSource == "priority" {
            guard priorityComplete else {displayedTaskSlots=[];return}
            displayedTaskSlots=threads.enumerated().sorted {
                let left=attention(for:$0.element).rank,right=attention(for:$1.element).rank
                if left != right {return left < right}
                let a=$0.element.recencyAt,b=$1.element.recencyAt
                return a == b ? $0.offset < $1.offset:a > b
            }.prefix(14).map {Optional($0.element)}
        } else { displayedTaskSlots = threads.prefix(14).map {Optional($0)} }
    }

    func canOpen(_ row: ThreadRow) -> Bool {
        connected && !opening && !controlling && knownThreads.contains { $0.id == row.id }
    }
    func canMarkUnread(_ row: ThreadRow) -> Bool {
        canOpen(row) && reasoningInput == nil && [.idle,.unknown].contains(signal(for:row)) && !needsControlRefresh
    }
    func markUnread(_ row: ThreadRow) {
        guard canMarkUnread(row) else { return }
        controlling=true; controlError=nil
        let generation=lifecycle, scope=rosterScope, context=contextID
        controlTask=Task { [weak self] in
            guard let self else { return }
            defer { if generation == lifecycle { controlling=false; controlTask=nil; reconcileRoster() } }
            do {
                let result=try await client.execute("mark_keypad_unread",arguments:["thread_id":row.id])
                guard !Task.isCancelled, generation == lifecycle, scope == rosterScope, context == contextID else { return }
                guard result["verified"] as? Bool == true,
                      result["threadId"] == nil || result["threadId"] as? String == row.id else { throw NSError(domain:"MicroBridge",code:2,userInfo:[NSLocalizedDescriptionKey:tr("unverifiedControl")]) }
                activity.confirmUnread(row.id, receipt: result, context: contextID)
            } catch {
                guard generation == lifecycle, !(error is CancellationError) else { return }
                controlError=error.localizedDescription
                if (error as NSError).domain == "MicroBridge", (error as NSError).code == 2 { needsControlRefresh=true }
            }
        }
    }

    func start() {
        guard !observations.isRunning else { return }
        lifecycle += 1
        observations.start(native: { [weak self] in await self?.refreshForeground() },
                           activity: { [weak self] in await self?.refreshActivity() },
                           catalogue: { [weak self] in await self?.refresh() })
    }

    func recoverObservation() {
        guard observations.isRunning else { return }
        observations.wake(.native)
        if !connected { observations.wake(.catalogue) }
    }

    func stop() {
        conversation.bind(nil);clientBindingRevision += 1
        cancelDialInput()
        feedbackTask?.cancel(); reasoningFeedback = nil
        lifecycle += 1
        selectionVersion += 1
        observationEpoch += 1; conversation.reset(); pendingNewError=nil
        observations.stop(); activity.reset(); foreground = [:]
        selectionTask?.cancel(); selectionTask = nil
        controlTask?.cancel(); controlTask = nil
        activationTask?.cancel(); activationTask = nil; activating = false
        settingsInput = nil; navigationInput=nil; reasoningInput=nil
        controlling = false; opening = false; refreshing = false; refreshingControls = false
        interactions.removeAll()
        connection.reset()
        desktopConnected = false
        state = [:]
        encoderMode = nil
        analogActions = [:]
        analogBindings = [:]; slots = [:]; encoderBindings = [:]; layoutAvailable = false
        models = []; modelNames = [:]
        usage = [:]
        lastCatalog = .distantPast
        forkAvailable = false;mappedThreads=[];pinnedThreads=[];pinnedAvailable=false;priorityComplete=false;displayedTaskSlots=[];displayedTaskCommands=[];rosterRefreshPending=false
    }

    func closeTransport() async { await client.close() }

    func refreshActivity() async {
        activityRequestRevision += 1
        let requestRevision = activityRequestRevision
        let generation = lifecycle,observedScope=rosterScope,observedContext=contextID,epoch=observationEpoch
        let connectionRevision = connection.revision
        do {
            let snapshot = try await client.execute("get_keypad_activity", arguments: selectedID.map { ["thread_id":$0] } ?? [:])
            guard !Task.isCancelled, generation == lifecycle,epoch == observationEpoch,requestRevision == activityRequestRevision,
                  connectionRevision == connection.revision,observedScope == rosterScope,observedContext == contextID else { return }
            if snapshot["contextValid"] as? Bool == false {
                clearObservedContext()
                selectionVersion += 1; state = [:]; desktopConnected = false
                activity.reset()
                await refresh(); return
            }
            guard connected, snapshot["watching"] as? Bool == true, snapshot["contextID"] as? String == contextID else {
                activity.disconnect()
                reconcileCurrentContext(); reconcileRoster(); return
            }
            let changed = activity.apply(snapshot)
            reconcileCurrentContext()
            applyLiveSettings()
            if changed, preferences.layout.agentSource == "priority" { reconcileRoster() }
        } catch {
            guard !Task.isCancelled, generation == lifecycle, epoch == observationEpoch, requestRevision == activityRequestRevision,
                  connectionRevision == connection.revision, observedScope == rosterScope, observedContext == contextID else { return }
            activity.disconnect()
            reconcileCurrentContext(); reconcileRoster()
        }
    }

    func refreshForeground() async {
        guard !controlling, !opening, !activating, reasoningInput == nil else { return }
        foregroundRequestRevision += 1
        let requestRevision = foregroundRequestRevision
        let generation = lifecycle, epoch = observationEpoch
        do {
            let result = try await client.execute("get_keypad_ui_state", arguments: [:])
            guard !Task.isCancelled, generation == lifecycle, epoch == observationEpoch, requestRevision == foregroundRequestRevision, !controlling, !opening, !activating else { return }
            if usesNativeSettings, foreground["targetToken"] as? String != result["targetToken"] as? String { selectionVersion += 1 }
            foreground = result
            reconcileCurrentContext(); applyLiveSettings()
            await refreshClientBinding()
        } catch {
            guard generation == lifecycle, epoch == observationEpoch, requestRevision == foregroundRequestRevision, !opening, !controlling, !activating, !Task.isCancelled else { return }
            foreground = [:]
            reconcileCurrentContext()
        }
    }

    private func refreshClientBinding() async {
        clientBindingRevision += 1
        let revision=clientBindingRevision,generation=lifecycle,epoch=observationEpoch,requestRevision=foregroundRequestRevision
        guard connected,contextSource == .foreground,isNativeComposer,foregroundFresh,
              let client=NativeObservation(foreground).clientID,
              let token=NativeObservation(foreground).token,let scope=rosterScope,let context=contextID else {conversation.bind(nil);return}
        func stillCurrent()->Bool {
            !Task.isCancelled && revision == clientBindingRevision && generation == lifecycle && epoch == observationEpoch &&
            requestRevision == foregroundRequestRevision && scope == rosterScope && context == contextID && connected &&
            !opening && !controlling && !activating &&
            NativeObservation(foreground).token == token && NativeObservation(foreground).clientID == client
        }
        do {
            let result=try await self.client.execute("get_keypad_client_thread",arguments:["client_thread_id":client,"roster_scope":scope])
            guard stillCurrent() else {return}
            guard result["resolved"] as? Bool == true,result["clientThreadId"] as? String == client,
                  result["rosterScope"] as? String == scope,result["contextID"] as? String == context,
                  let raw=result["thread"] as? [String:Any],let row=ThreadRow(raw),row.id == result["threadId"] as? String else {conversation.bind(nil);return}
            // Reobserve the actual window after the asynchronous storage/server read.
            let observed=try await self.client.execute("get_keypad_ui_state",arguments:[:])
            guard stillCurrent() else {return}
            guard NativeObservation(observed).clientID == client,
                  NativeObservation(observed).token == token else {conversation.bind(nil);return}
            foreground=observed
            // Expiry may have cleared the presentation during the lookup. Only
            // this fresh native read restores it; the server UUID cannot do so.
            reconcileCurrentContext()
            conversation.bind(.init(client:client,token:token,scope:scope,context:context,row:row,observedAt:observationUptime()))
        } catch {if stillCurrent() {conversation.bind(nil)}}
    }

    private func reconcileCurrentContext() {
        guard !opening, !controlling, reasoningInput == nil else { return }
        let wasPending = conversation.retiredRoutes != nil
        let resolution = conversation.resolve(at: observationUptime())
        if wasPending, conversation.retiredRoutes == nil {
            if let pendingNewError, controlError == pendingNewError { controlError = nil }
            pendingNewError = nil
        }
        switch resolution {
        case .retain: break
        case .thread(let id):
            if selectedID != id || usesNativeSettings { select(id, source: .foreground) }
            else if contextSource != .foreground { conversation.selectThread(id, source: .foreground, at: observationUptime()) }
        case .draft, .nativeComposer:
            let nativeOnly: Bool
            if case .nativeComposer = resolution { nativeOnly = true } else { nativeOnly = false }
            if !usesNativeSettings || isNativeComposer != nativeOnly || selectedID != nil {
                selectionVersion += 1; selectionTask?.cancel()
            }
            conversation.selectComposer(nativeOnly: nativeOnly)
            let settings = foreground["settings"] as? [String: Any] ?? [:]
            if state as NSDictionary != settings as NSDictionary { state = settings }
            desktopConnected = foreground["available"] as? Bool == true && foreground["targetToken"] is String
            selectionError = nil
        case .clear:
            if selectedID != nil || usesNativeSettings { selectionVersion += 1; selectionTask?.cancel() }
            conversation.clearTarget()
            if !state.isEmpty { state = [:] }
            desktopConnected = false
        }
    }

    private func clearObservedContext() {
        observationEpoch += 1; pendingNewError = nil; clientBindingRevision += 1
        selectionVersion += 1; selectionTask?.cancel()
        conversation.reset(); activity.disconnect()
    }

    private func acceptNativeSettings(_ observed: [String: Any]) {
        foreground = observed
        state = observed["settings"] as? [String: Any] ?? [:]
    }

    private func applyLiveSettings() {
        guard !opening, !controlling, reasoningInput == nil, !usesNativeSettings,
              streamConnected, let id=selectedID, let settings=liveSettings[id] else { return }
        var next=state; next.merge(settings) { _, current in current }; next["threadId"]=id
        if state as NSDictionary != next as NSDictionary { state=next }
        // A stream supplies current settings; exact control readiness still
        // comes from get_keypad_state and its complete owner snapshot.
    }

    func refresh() async {
        guard !refreshing, !controlling, reasoningInput == nil else { return }
        let generation = lifecycle
        refreshing = true
        rosterRefreshPending=false
        let mappingVersion=taskMappingVersion,profile=preferences.layout
        defer {
            if generation == lifecycle {
                refreshing = false
                if rosterRefreshPending {rosterRefreshPending=false;scheduleRosterRefresh()}
            }
        }
        do {
            func parameters(_ scope:String?) -> [String:Any] {
                if profile.agentSource == "pinned" {return ["include_pinned":true]}
                if profile.agentSource == "priority" {return ["include_priority":true]}
                guard profile.agentSource == "custom",let scope else {return [:]}
                let map=profile.taskMap(scope:scope)
                return ["roster_scope":scope,"mapped_thread_ids":TaskSlots.ids.compactMap {map[$0]}]
            }
            var requestedScope=rosterScope
            var result = try await client.execute("list_keypad_threads", arguments:parameters(requestedScope))
            if let observed=result["rosterScope"] as? String,TaskSlots.validScope(observed),observed != requestedScope,
               profile.agentSource == "custom",!profile.taskMap(scope:observed).isEmpty {
                requestedScope=observed
                result=try await client.execute("list_keypad_threads",arguments:parameters(observed))
                guard result["rosterScope"] as? String == observed else {throw NSError(domain:"MicroRoster",code:1)}
            }
            guard !Task.isCancelled, generation == lifecycle else { return }
            guard mappingVersion == taskMappingVersion else {rosterRefreshPending=true;return}
            let nextScope=(result["rosterScope"] as? String).flatMap {TaskSlots.validScope($0) ? $0:nil}
            let nextContext = result["contextID"] as? String
            let pinnedRows=(result["pinnedThreads"] as? [[String:Any]] ?? []).compactMap(ThreadRow.init)
            guard pinnedRows.count <= 14,Set(pinnedRows.map(\.id)).count == pinnedRows.count else {throw NSError(domain:"MicroRoster",code:2)}
            if connection.connect(id: nextContext, scope: nextScope) {
                clearObservedContext()
                activity.reset()
                selectionVersion += 1; state = [:]; desktopConnected = false
                models = []; modelNames = [:]; usage = [:]; forkAvailable = false; lastCatalog = .distantPast
            }
            var seen: Set<String> = []
            threads = (result["threads"] as? [[String: Any]] ?? []).compactMap(ThreadRow.init).filter { seen.insert($0.id).inserted }
            let allowed=Set(profile.taskMap(scope:rosterScope).values)
            var mappedSeen:Set<String>=[]
            mappedThreads=rosterScope == requestedScope ? (result["mappedThreads"] as? [[String:Any]] ?? []).compactMap(ThreadRow.init).filter {allowed.contains($0.id) && mappedSeen.insert($0.id).inserted}:[]
            priorityComplete=profile.agentSource == "priority" && result["priorityComplete"] as? Bool == true
            pinnedAvailable=profile.agentSource == "pinned" && rosterScope != nil && result["pinnedAvailable"] as? Bool == true
            pinnedThreads=pinnedAvailable ? pinnedRows:[]
            reconcileRoster()
            lastRefreshed = Date()
            catalogueError = nil
            // An active older chat need not be in the recent-list page.
            // Its exact owner snapshot, not roster membership, validates it.
        } catch {
            guard !Task.isCancelled, generation == lifecycle else { return }
            connection.disconnect(); desktopConnected = false
            mappedThreads=[];pinnedThreads=[];pinnedAvailable=false;priorityComplete=false;reconcileRoster()
            // A roster failure revokes service-derived authority, not an
            // independently observed native route. New account evidence still
            // resets the complete context in the successful response above.
            clientBindingRevision += 1; conversation.bind(nil); activity.disconnect()
            selectionVersion += 1; selectionTask?.cancel()
            state = [:]; usage = [:]; lastCatalog = .distantPast
            models = []; modelNames = [:]; forkAvailable = false
            encoderMode = nil; analogActions = [:]; analogBindings = [:]; slots = [:]; encoderBindings = [:]; layoutAvailable = false
            catalogueError = error.localizedDescription
            updateError()
            return
        }
        do {
            let layout = try await client.execute("get_keypad_layout", arguments: [:])
            guard !Task.isCancelled, generation == lifecycle else { return }
            configuredSeparateMicrophoneKeys = layout["separateMicrophoneKeys"] as? Bool ?? false
            encoderMode = layout["encoderMode"] as? String
            analogActions = layout["analogActions"] as? [String: String] ?? [:]
            analogBindings = (layout["analogBindings"] as? [String: Any] ?? [:]).compactMapValues { $0 as? [String: Any] }
            slots = layout["slots"] as? [String: [String: Any]] ?? [:]
            encoderBindings = layout["encoderBindings"] as? [String: [String: Any]] ?? [:]
            layoutAvailable = true
        } catch {
            guard !Task.isCancelled, generation == lifecycle else { return }
            encoderMode = nil
            analogActions = [:]
            analogBindings = [:]; slots = [:]; encoderBindings = [:]; layoutAvailable = false
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
            } catch {
                guard !Task.isCancelled, generation == lifecycle else { return }
                models = []; modelNames = [:]
                catalogueError = error.localizedDescription
            }
            do {
                let limits = try await client.execute("get_keypad_usage", arguments: [:])
                guard !Task.isCancelled, generation == lifecycle else { return }
                usage = limits
                lastUsageRefresh = Date()
            } catch {
                guard !Task.isCancelled, generation == lifecycle else { return }
                usage = [:]
                catalogueError = error.localizedDescription
            }
            do {
                let capabilities = try await client.execute("get_keypad_capabilities", arguments: [:])
                guard !Task.isCancelled, generation == lifecycle else { return }
                forkAvailable = capabilities["forkAvailable"] as? Bool == true
            } catch {
                guard !Task.isCancelled, generation == lifecycle else { return }
                forkAvailable = false
                catalogueError = error.localizedDescription
            }
            if catalogueError == nil { lastCatalog = Date() }
        }
        await refreshSelection()
        if needsControlRefresh, canAutomaticallyRefreshControls { refreshControls(clearError:false) }
        updateError()
    }

    // Selection here is an explicit read target; it does not claim to observe Codex's foreground chat.
    func select(_ id: String, open: Bool = false, source:ContextSource = .selected) {
        guard !opening, !controlling, UUID(uuidString: id) != nil else { return }
        if source == .selected { pendingNewError=nil; foregroundRequestRevision += 1 }
        cancelDialInput()
        feedbackTask?.cancel(); reasoningFeedback = nil
        selectionTask?.cancel()
        selectionVersion += 1
        conversation.selectThread(id, source: source, at: observationUptime())
        state = [:]; desktopConnected = false
        selectionError = nil; openError = nil; updateError()
        let generation = lifecycle
        let version = selectionVersion
        selectionTask = Task { [weak self] in
            guard let self else { return }
            if open {
                opening = true
                defer { if generation == lifecycle { opening = false; reconcileRoster() } }
                do {
                    let result = try await client.execute("open_keypad_thread", arguments: ["thread_id": id])
                    if generation == lifecycle, version == selectionVersion, result["navigation_verified"] as? Bool != true {
                        openError = result["followupError"] as? String ?? tr("unverifiedControl"); controlError = openError; needsControlRefresh = true
                        canAutomaticallyRefreshControls = true
                    }
                }
                catch {
                    if generation == lifecycle, version == selectionVersion {
                        openError = error.localizedDescription; controlError = openError
                        if (error as NSError).domain == "MicroBridge", (error as NSError).code == 2 {
                            needsControlRefresh = true; canAutomaticallyRefreshControls = true
                        }
                    }
                }
            }
            guard !Task.isCancelled, generation == lifecycle, version == selectionVersion else { return }
            await refreshSelection()
            if needsControlRefresh, canAutomaticallyRefreshControls { refreshControls(clearError:false) }
            updateError()
        }
    }

    private func refreshSelection() async {
        if usesNativeSettings { await refreshForeground(); return }
        guard let id = selectedID else { return }
        selectionRequestRevision += 1
        let requestRevision = selectionRequestRevision
        let version = selectionVersion, generation = lifecycle
        let previousLive=liveSettings[id] as NSDictionary?
        do {
            let result = try await client.execute("get_keypad_state", arguments: ["thread_id": id])
            guard !Task.isCancelled, version == selectionVersion, generation == lifecycle, requestRevision == selectionRequestRevision else { return }
            guard result["threadId"] as? String == id else {
                throw NSError(domain: "MicroBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: tr("targetChanged")])
            }
            state = result; desktopConnected = true; selectionError = nil
            if previousLive != liveSettings[id] as NSDictionary? { applyLiveSettings() }
        } catch {
            guard !Task.isCancelled, version == selectionVersion, generation == lifecycle, requestRevision == selectionRequestRevision else { return }
            state = [:]; desktopConnected = false
            selectionError = error.localizedDescription
        }
    }

    func isCurrent(_ target: ControlTarget) -> Bool {
        target.threadID == targetID && target.version == selectionVersion && target.lifecycle == lifecycle
            && (!target.usesNativeSettings || target.uiToken == foreground["targetToken"] as? String)
            && desktopConnected && connected && !controlling && !activating && !needsControlRefresh
    }

    func setModel(_ choice: ModelChoice, target: ControlTarget) {
        let oldEffort = target.settings["effort"] as? String ?? ""
        let effort = choice.efforts.contains(oldEffort) ? oldEffort : choice.defaultEffort
        var arguments: [String: Any] = ["model": choice.id, "expected_settings": target.settings]
        if !target.usesNativeSettings || foreground["draftReasoningAvailable"] as? Bool == true { arguments["effort"] = effort }
        perform("set_keypad_model", target: target, arguments: arguments)
    }

    func setReasoning(_ effort: String, target: ControlTarget) {
        guard canSetReasoning else { return }
        guard isCurrent(target) else { controlError = tr("targetChanged"); return }
        if effort == currentEffort { showReasoningFeedback(effort); return }
        perform("set_keypad_reasoning", target: target, arguments: ["effort": effort, "expected_settings": target.settings])
    }

    private func showReasoningFeedback(_ effort: String) {
        feedbackTask?.cancel(); reasoningFeedback = effort
        feedbackTask = Task { [weak self] in
            do { try await Task.sleep(for:.milliseconds(900)) } catch { return }
            self?.reasoningFeedback = nil
        }
    }

    func toggleFast(target: ControlTarget) {
        enqueueSetting(.fast, target: target)
    }

    private func canQueueSetting(_ action: SettingAction) -> Bool {
        switch action {
        case .fast: return usesNativeSettings ? foreground["draftFastAvailable"] as? Bool == true : fast || currentDefinition?.supportsFast == true
        case .plan: return ["plan", "default"].contains(collaborationMode ?? "") && (!usesNativeSettings || foreground["draftPlanAvailable"] as? Bool == true)
        case .reasoning: return usesNativeSettings ? foreground["draftReasoningAvailable"] as? Bool == true : currentDefinition?.efforts.contains(currentEffort) == true
        }
    }

    private func enqueueSetting(_ action: SettingAction, target: ControlTarget) {
        guard canQueueSetting(action) else { return }
        if let input = settingsInput {
            guard input.target.threadID == target.threadID, input.target.version == target.version,
                  input.target.lifecycle == lifecycle, input.pending.count < 64 else { return }
            input.pending.append((action, uptime() + Self.settingsQueueWait)); return
        }
        guard isCurrent(target), reasoningInput == nil else { return }
        let input = SettingsInput(target); input.pending = [(action, uptime() + Self.settingsQueueWait)]
        settingsInput = input; controlling = true; controlError = nil
        selectionVersion += 1; selectionTask?.cancel()
        let version = selectionVersion
        controlTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if target.lifecycle == lifecycle {
                    if settingsInput === input { settingsInput = nil }
                    controlling = false; controlTask = nil; reconcileRoster()
                    if needsControlRefresh, canAutomaticallyRefreshControls { refreshControls(clearError:false) }
                }
            }
            var settings = target.settings, token = target.uiToken
            do {
                while !input.pending.isEmpty {
                    let (action, deadline) = input.pending.removeFirst()
                    try Task.checkCancellation()
                    guard settingsInput === input, target.lifecycle == lifecycle, version == selectionVersion,
                          target.threadID == targetID, uptime() <= deadline else {
                        throw NSError(domain:"MicroBridge",code:1,userInfo:[NSLocalizedDescriptionKey:tr("targetChanged")])
                    }
                    var args:[String:Any] = ["expected_settings":settings,"input_deadline_uptime":deadline]
                    let operation: String
                    switch action {
                    case .fast:
                        operation = "set_keypad_fast"
                        if target.usesNativeSettings { args["toggle"] = true }
                        else { args["enabled"] = !["fast","priority"].contains(settings["serviceTier"] as? String ?? "") }
                    case .plan:
                        operation = "toggle_keypad_plan"
                    case .reasoning(let delta):
                        operation = "set_keypad_reasoning"
                        if target.usesNativeSettings {
                            // Resolve the real initial Power value in the native
                            // menu; a closed trigger may omit effort entirely.
                            args["direction"] = delta
                        } else {
                            guard let definition=models.first(where: { $0.id == settings["model"] as? String }),
                                  let at=definition.efforts.firstIndex(of:settings["effort"] as? String ?? definition.defaultEffort) else {
                                throw NSError(domain:"MicroBridge",code:1,userInfo:[NSLocalizedDescriptionKey:tr("targetChanged")])
                            }
                            let next=max(0,min(definition.efforts.count-1,at+delta))
                            if next == at { showReasoningFeedback(definition.efforts[at]); continue }
                            args["effort"] = definition.efforts[next]
                        }
                    }
                    var currentTarget = target; currentTarget.uiToken = token
                    let command = try PreparedControlCommand(operation, target: currentTarget, arguments: args)
                    let result = try await commands.execute(command) {
                        self.settingsInput === input && target.lifecycle == self.lifecycle && version == self.selectionVersion &&
                        target.threadID == self.targetID && self.connected && !self.activating
                    }
                    guard !Task.isCancelled, target.lifecycle == lifecycle, version == selectionVersion else { return }
                    guard result["verified"] as? Bool == true, let observed = result["state"] as? [String:Any] else {
                        throw NSError(domain:"MicroBridge",code:2,userInfo:[NSLocalizedDescriptionKey:tr("unverifiedControl")])
                    }
                    if target.usesNativeSettings { acceptNativeSettings(observed); token = observed["targetToken"] as? String }
                    else { state = observed }
                    settings = ["model":state["model"] ?? NSNull(),"effort":state["effort"] ?? NSNull(),"serviceTier":state["serviceTier"] ?? NSNull(),"collaborationMode":state["collaborationMode"] ?? NSNull()]
                    if case .reasoning = action { showReasoningFeedback(currentEffort) }
                }
            } catch {
                if target.lifecycle == lifecycle, !(error is CancellationError) {
                    controlError = error.localizedDescription
                    if (error as NSError).domain == "MicroBridge", (error as NSError).code == 2 { needsControlRefresh = true; canAutomaticallyRefreshControls = true }
                }
            }
        }
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
        enqueueSetting(.plan, target: target)
    }

    func fork(target: ControlTarget) {
        guard canFork else { return }
        perform("fork_keypad_thread", target: target, arguments: [:])
    }

    func openReview(target: ControlTarget) {
        perform("open_keypad_review", target: target, arguments: [:])
    }

    func newDraft() {
        guard canNavigate else { return }
        opening = true
        controlError = nil
        var additionalRetired = Set<String>()
        if activity.streamConnected, activity.visibilityKnown, activity.visibleCandidates.count == 1,
           let id = activity.visibleCandidates.first {
            additionalRetired.insert((UUID(uuidString: id) == nil ? "client:" : "thread:") + id)
        }
        cancelDialInput()
        observationEpoch += 1; clientBindingRevision += 1
        selectionVersion += 1; selectionTask?.cancel(); pendingNewError = nil
        conversation.beginNavigation(additionalRetiredRoutes: additionalRetired)
        activity.disconnect()
        state = [:]; desktopConnected = false
        let generation = lifecycle
        selectionTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == lifecycle {opening = false; reconcileCurrentContext(); reconcileRoster()} }
            do {
                let result = try await client.execute("new_keypad_thread", arguments: [:])
                guard !Task.isCancelled, generation == lifecycle else { return }
                // A new draft has no exact thread ID. Do not retain the previous
                // conversation's write controls while Codex handles the link.
                state = [:]; desktopConnected = false
                selectionError = nil; openError = nil; updateError()
                if result["navigation_verified"] as? Bool == true,let observed=result["foreground"] as? [String:Any],
                   observed["routeAvailable"] as? Bool == true,observed["draft"] as? Bool == true {
                    foreground=observed
                } else {
                    if let observed=result["foreground"] as? [String:Any] {foreground=observed}
                    pendingNewError=result["followupError"] as? String ?? foreground["reason"] as? String ?? tr("unverifiedControl")
                    controlError=pendingNewError
                }
            } catch {
                guard !Task.isCancelled, generation == lifecycle else { return }
                pendingNewError=error.localizedDescription;controlError=pendingNewError
            }
        }
    }

    func toggleQuickModel(_ profile: DialProfile, target: ControlTarget) {
        guard isCurrent(target) else { controlError = tr("targetChanged"); return }
        if target.usesNativeSettings {
            var presets:[[String:Any]]=[]
            for preset in [profile.a,profile.b] {
                guard let choice=models.first(where:{$0.id == preset.model}),choice.efforts.contains(preset.effort ?? choice.defaultEffort) else { controlError=tr("presetUnavailable"); return }
                presets.append(["model":choice.id,"effort":preset.effort ?? choice.defaultEffort])
            }
            perform("set_keypad_model",target:target,arguments:["quick_models":presets,"expected_settings":target.settings])
            return
        }
        let sameModel = profile.a.model == profile.b.model
        let effortA = profile.a.effort ?? models.first(where: { $0.id == profile.a.model })?.defaultEffort
        let selectB = target.settings["model"] as? String == profile.a.model &&
            (!sameModel || currentEffort == effortA)
        let preset = selectB ? profile.b : profile.a
        guard let choice = models.first(where: { $0.id == preset.model }),
              choice.efforts.contains(preset.effort ?? choice.defaultEffort) else {
            controlError = tr("presetUnavailable"); return
        }
        var arguments: [String: Any] = ["model": choice.id, "expected_settings": target.settings]
        if !target.usesNativeSettings || foreground["draftReasoningAvailable"] as? Bool == true {
            arguments["effort"] = preset.effort ?? choice.defaultEffort
        } else if preset.effort != nil { controlError = tr("effortUnavailable"); return }
        perform("set_keypad_model", target: target, arguments: arguments)
    }

    func prepareDial(_ profile: DialProfile) -> DialActions? {
        if usesNativeSettings, currentEffort.isEmpty,canSetReasoning,let target=controlTarget {
            var cancelled=false
            return DialActions(step:{ [weak self] physical in
                guard !cancelled,let self else { return }
                let direction=DialMapping.reasoning(physical,inverted:profile.invertDirection).signum()
                for _ in 0..<abs(max(-64,min(64,physical))) { self.enqueueSetting(.reasoning(direction),target:target) }
            },end:{ cancelled=$0 },tap:{ [weak self] in if !cancelled { self?.toggleQuickModel(profile,target:target) } })
        }
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
            let efforts = canSetReasoning ? currentDefinition?.efforts ?? [] : []
            let index = efforts.firstIndex(of: currentEffort) ?? -1
            input = ReasoningInput(target: target, efforts: efforts, index: index)
            reasoningInput = input; canTap = true
        }
        setInteraction("dial", active: true)
        return DialActions(step: { [weak self, weak input] physical in
            guard let self, let input else { return }
            self.stepDial(input, steps: DialMapping.reasoning(physical,inverted:profile.invertDirection))
        }, end: { [weak self, weak input] cancelled in
            guard let self, let input, self.reasoningInput === input else { return }
            input.ended = true
            if cancelled { input.cancelled = true }
            if !self.controlling { self.releaseDial(input) }
        }, tap: { [weak self] in if canTap { self?.toggleQuickModel(profile, target: input.target) } })
    }

    private func stepDial(_ input: ReasoningInput, steps: Int) {
        guard reasoningInput === input, !input.cancelled, !input.ended,
              input.target.threadID == targetID, input.target.lifecycle == lifecycle,
              input.version == selectionVersion, connected, desktopConnected, !needsControlRefresh else { return }
        guard input.desired >= 0, !input.efforts.isEmpty else { return }
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
                if input.target.lifecycle == lifecycle {
                    controlling = false; controlTask = nil
                    if input.ended || input.cancelled { releaseDial(input) }
                    reconcileRoster()
                }
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
                    let arguments: [String: Any] = [
                        "effort": input.efforts[destination],
                        "expected_settings": input.observed, "input_deadline_uptime": input.lastInput + 5]
                    var currentTarget = input.target
                    if currentTarget.usesNativeSettings { currentTarget.uiToken = foreground["targetToken"] as? String }
                    let command = try PreparedControlCommand("set_keypad_reasoning", target: currentTarget, arguments: arguments)
                    let result = try await commands.execute(command) {
                        self.reasoningInput === input && !input.cancelled && input.version == self.selectionVersion &&
                        input.target.lifecycle == self.lifecycle && self.connected && !self.activating
                    }
                    guard !Task.isCancelled, input.version == selectionVersion, input.target.lifecycle == lifecycle else { return }
                    guard result["verified"] as? Bool == true, let observed = result["state"] as? [String: Any] else {
                        throw NSError(domain: "MicroBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: tr("unverifiedControl")])
                    }
                    if input.target.usesNativeSettings { acceptNativeSettings(observed) }
                    else { state = observed }
                    input.observed = ["model": state["model"] ?? NSNull(), "effort": state["effort"] ?? NSNull(), "serviceTier": state["serviceTier"] ?? NSNull(), "collaborationMode": state["collaborationMode"] ?? NSNull()]
                    input.acknowledged = destination
                }
            } catch {
                input.cancelled = true
                if (error as NSError).domain == "MicroBridge", (error as NSError).code == 2 {
                    needsControlRefresh = true; canAutomaticallyRefreshControls = true
                }
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
        if needsControlRefresh, canAutomaticallyRefreshControls { refreshControls(clearError:false) }
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

    func openOfficialMicroSettings() {
        openGlobalPage("open_keypad_settings",arguments:["section":"codex-micro"])
    }
    func unavailableInput() { controlError=foreground["reason"] as? String ?? tr("controlNotReady") }
    private func activateCodex() {
        guard !activating else { return }
        activating = true; controlError = nil; foregroundRequestRevision += 1
        let generation = lifecycle
        activationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == lifecycle {
                    activating = false; activationTask = nil
                    reconcileCurrentContext(); reconcileRoster()
                    refreshControls(clearError: false)
                }
            }
            do {
                let result = try await client.execute("activate_keypad_app", arguments: [:])
                guard !Task.isCancelled, generation == lifecycle else { return }
                guard result["activated"] as? Bool == true, result["window_visible"] as? Bool == true, result["verified"] as? Bool == true,
                      result["submitted"] as? Bool == false else {
                    throw NSError(domain: "MicroBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: tr("unverifiedControl")])
                }
            } catch {
                if !Task.isCancelled, generation == lifecycle { controlError = error.localizedDescription }
            }
        }
    }
    private func openGlobalPage(_ operation:String,arguments:[String:Any] = [:]) {
        guard !controlling, !opening else { return }
        controlling=true; controlError=nil
        let generation=lifecycle
        controlTask=Task { [weak self] in
            guard let self else { return }
            defer { if generation == lifecycle { controlling=false; controlTask=nil; reconcileRoster() } }
            do {
                try Task.checkCancellation()
                let result=try await client.execute(operation,arguments:arguments)
                guard result["launch_requested"] as? Bool == true else {
                    throw NSError(domain:"MicroBridge",code:1,userInfo:[NSLocalizedDescriptionKey:tr("unverifiedControl")])
                }
                if operation != "open_keypad_developer_site",generation == lifecycle {
                    clearObservedContext();selectionVersion += 1;selectionTask?.cancel()
                    state=[:];desktopConnected=false
                    if let observed=result["foreground"] as? [String:Any] { foreground=observed }
                    if result["navigation_verified"] as? Bool != true {
                        needsControlRefresh=true;canAutomaticallyRefreshControls=true
                        controlError=tr("unverifiedControl")
                    }
                }
            } catch {
                if generation == lifecycle, !(error is CancellationError) { controlError=error.localizedDescription }
            }
        }
    }

    private func perform(_ operation: String, target: ControlTarget, arguments: [String: Any]) {
        guard reasoningInput == nil, isCurrent(target) else { controlError = tr("targetChanged"); return }
        let command: PreparedControlCommand
        do { command = try PreparedControlCommand(operation, target: target, arguments: arguments) }
        catch { controlError = error.localizedDescription; return }
        let operation = command.operation
        controlling = true
        controlError = nil
        // Invalidate any in-flight observation. It must not overwrite readback
        // with a snapshot taken before the operation.
        selectionVersion += 1
        selectionTask?.cancel()
        let version = selectionVersion
        controlTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if target.lifecycle == lifecycle {
                    controlling = false; controlTask = nil; reconcileRoster()
                    if needsControlRefresh, canAutomaticallyRefreshControls { refreshControls(clearError:false) }
                }
            }
            do {
                let result = try await commands.execute(command) {
                    target.lifecycle == self.lifecycle && version == self.selectionVersion && self.connected && !self.activating
                }
                guard !Task.isCancelled, target.lifecycle == lifecycle, version == selectionVersion else { return }
                if operation == "open_keypad_folder", result["launch_requested"] as? Bool != true {
                    throw NSError(domain:"MicroBridge",code:1,userInfo:[NSLocalizedDescriptionKey:tr("unverifiedControl")])
                }
                if !target.usesNativeSettings, let observed = result["state"] as? [String:Any],
                   target.lifecycle == lifecycle, version == selectionVersion { state = observed }
                if target.usesNativeSettings, let observed = result["state"] as? [String: Any], target.lifecycle == lifecycle {
                    acceptNativeSettings(observed)
                }
                if ["set_keypad_reasoning", "set_keypad_draft_reasoning"].contains(operation), result["verified"] as? Bool == true,
                   target.lifecycle == lifecycle, version == selectionVersion { showReasoningFeedback(currentEffort) }
                if operation == "fork_keypad_thread", let created = result["threadId"] as? String {
                    // Record the created ID before observing the new target. A
                    // failed launch must never lead to a second fork attempt.
                    if let warning = result["followupError"] as? String { controlError = "\(created)\n\(warning)" }
                    if !Task.isCancelled, target.lifecycle == lifecycle, version == selectionVersion {
                        conversation.selectThread(created, source: .selected, at: observationUptime()); state = [:]; desktopConnected = false
                    }
                }
                if let warning = result["goalPauseError"] as? String { controlError = warning }
                if ["fork_keypad_thread", "open_keypad_review"].contains(operation), result["navigation_verified"] as? Bool != true {
                    controlError = controlError ?? result["followupError"] as? String ?? tr("unverifiedControl")
                    if operation == "fork_keypad_thread" { needsControlRefresh = true }
                }
            } catch {
                // Keep uncertainty across hide/show. No mutation is replayed.
                if (error as NSError).domain == "MicroBridge", (error as NSError).code == 2 {
                    needsControlRefresh = true
                    // Fork, submission and approval keep explicit reconciliation.
                    canAutomaticallyRefreshControls = ["set_keypad_model", "set_keypad_reasoning", "set_keypad_fast", "toggle_keypad_plan",
                        "set_keypad_draft_model", "set_keypad_draft_reasoning", "set_keypad_draft_fast", "toggle_keypad_draft_plan"].contains(operation)
                }
                if target.lifecycle == lifecycle, !(error is CancellationError) { controlError = error.localizedDescription }
            }
            guard !Task.isCancelled, target.lifecycle == lifecycle, version == selectionVersion else { return }
            await refreshSelection()
            updateError()
        }
    }

    func native(_ operation: String, token: String, arguments: [String: Any] = [:]) {
        guard !controlling else { return }
        guard nativeToken == token, reasoningInput == nil else { controlError = tr("targetChanged"); return }
        controlling = true; controlError = nil; selectionVersion += 1
        let generation = lifecycle
        controlTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == lifecycle {
                    controlling = false; controlTask = nil; reconcileCurrentContext(); reconcileRoster()
                    if needsControlRefresh, canAutomaticallyRefreshControls { refreshControls(clearError:false) }
                }
            }
            do {
                var params = arguments; params["target_token"] = token
                let result = try await client.execute(operation, arguments: params)
                guard !Task.isCancelled, lifecycle == generation else { return }
                if let observed = result["state"] as? [String: Any] { foreground = observed }
                else { foreground = [:] }
                if operation == "archive_keypad_thread",result["archived"] as? Bool == true,let id=arguments["thread_id"] as? String {
                    activity.remove(id)
                    threads.removeAll {$0.id == id}
                    if selectedID == id { conversation.clearTarget(); state=[:]; desktopConnected=false }
                }
                if result["verified"] as? Bool != true {
                    needsControlRefresh = true
                    canAutomaticallyRefreshControls = operation == "navigate_keypad_ui"
                    controlError = tr("unverifiedControl")
                }
            } catch {
                if (error as NSError).domain == "MicroBridge", (error as NSError).code == 2 {
                    needsControlRefresh = true
                    canAutomaticallyRefreshControls = operation == "navigate_keypad_ui"
                }
                if !Task.isCancelled, lifecycle == generation {
                    controlError = error.localizedDescription
                    foreground = [:]
                }
            }
        }
    }

    func binding(for key: String) -> [String: Any]? {
        let slotID = KeySlots.id(key)
        if let local = preferences.layout.keys[slotID] { return local.action }
        guard layoutAvailable else { return nil }
        let slot = slots[slotID] ?? [:]
        if let action = slot["action"] as? [String: Any] { return action }
        if slot["action"] is NSNull { return nil }
        return KeySlots.defaultAction(keycap(for:key))
    }

    func keycap(for key: String) -> String {
        let slotID = KeySlots.id(key)
        return preferences.layout.keys[slotID]?.icon ?? slots[slotID]?["keycapId"] as? String ?? KeySlots.defaults[slotID] ?? key
    }

    func approvalDecision(for key: String) -> String? {
        guard let action = binding(for:key), action["type"] as? String == "command" else { return nil }
        return ["approval.approve":"accept", "approval.decline":"decline"][action["commandId"] as? String ?? ""]
    }

    func prepareKey(_ key: String) -> (() -> Void)? {
        let binding = binding(for: key), slotID = KeySlots.id(key)
        // Keep the default recovery key usable before the remote layout loads.
        // An explicitly cleared or remapped slot must retain its chosen action.
        let wakeBinding = binding ?? (!layoutAvailable && preferences.layout.keys[slotID] == nil && slots[slotID] == nil
            ? KeySlots.defaultAction(keycap(for: key)) : nil)
        guard keycap(for: key) == "CODEX", wakeBinding?["type"] as? String == "command",
              wakeBinding?["commandId"] as? String == "composer.submit" else { return prepareBinding(binding) }
        guard !activating else { return nil }
        if foreground["foreground"] as? Bool == true, let submit = prepareBinding(binding) { return submit }
        let generation = lifecycle
        return { [weak self] in
            guard let self, self.lifecycle == generation else { return }
            self.activateCodex()
        }
    }

    func prepareBinding(_ binding: [String: Any]?) -> (() -> Void)? {
        guard let binding else { return nil }
        if binding["type"] as? String == "command", let command=binding["commandId"] as? String,
           let action=SettingAction(command), let input = settingsInput {
            guard canQueueSetting(action), input.pending.count < 64 else { return nil }
            return { [weak self] in self?.enqueueSetting(action,target:input.target) }
        }
        let target = controlTarget, token = isNativeComposer ? nil : nativeToken
        if binding["type"] as? String == "composer-text" {
            guard let token,foreground["canInsertPresetText"] as? Bool == true,
                  let preset=ComposerTextPreset.matching(binding["text"] as? String) else {return nil}
            return { [weak self] in self?.native("insert_keypad_preset_text",token:token,arguments:["preset":preset.rawValue]) }
        }
        if binding["type"] as? String == "skill", let token, let name = binding["skillName"] as? String, let path = binding["skillPath"] as? String {
            return { [weak self] in self?.native("insert_keypad_skill", token: token, arguments: ["name":name,"path":path]) }
        }
        guard binding["type"] as? String == "command", let command = binding["commandId"] as? String else { return nil }
        if let index=KeySlots.recentIndex(command) {
            guard threads.indices.contains(index),canOpen(threads[index]) else {return nil}
            let row=threads[index],generation=lifecycle,context=contextID,scope=rosterScope
            return { [weak self] in
                guard let self,self.lifecycle == generation,self.contextID == context,self.rosterScope == scope,self.canOpen(row) else {return}
                self.select(row.id,open:true)
            }
        }
        switch command {
        case "developers.openai.com", "settings", "openSkills", "manageTasks":
            guard !controlling, !opening else { return nil }
            let operation = ["developers.openai.com":"open_keypad_developer_site","settings":"open_keypad_settings","openSkills":"open_keypad_skills","manageTasks":"open_keypad_tasks"][command]!
            return { [weak self] in self?.openGlobalPage(operation) }
        case "openFolder":
            guard let target, !target.usesNativeSettings else { return nil }
            return { [weak self] in self?.perform("open_keypad_folder",target:target,arguments:[:]) }
        case "feedback":
            guard let token=nativeToken,foreground["canOpenFeedback"] as? Bool == true else {return nil}
            return { [weak self] in self?.native("open_keypad_feedback",token:token) }
        case "composer.addFiles", "composer.addPhotos":
            let photos=command == "composer.addPhotos"
            guard let token=nativeToken,!isNativeComposer,foreground[photos ? "canOpenPhotos":"canOpenFiles"] as? Bool == true else {return nil}
            return { [weak self] in self?.native(photos ? "open_keypad_photos":"open_keypad_files",token:token) }
        case "environmentAction1":
            guard let target,!target.usesNativeSettings,let token=nativeToken,
                  foreground["threadId"] as? String == target.threadID,foreground["canRunEnvironmentAction"] as? Bool == true else {return nil}
            return { [weak self] in self?.native("run_keypad_environment_action",token:token,arguments:["thread_id":target.threadID]) }
        case "git.mergePullRequest", "git.commit", "git.createBranch", "git.createPullRequest", "git.createDraftPullRequest":
            guard let target,!target.usesNativeSettings,let token=nativeToken,
                  foreground["threadId"] as? String == target.threadID,foreground["canOpenGitWorkflow"] as? Bool == true else {return nil}
            let operation=["git.mergePullRequest":"open_keypad_merge_pull_request","git.commit":"open_keypad_commit","git.createBranch":"open_keypad_branch","git.createPullRequest":"open_keypad_pull_request","git.createDraftPullRequest":"open_keypad_draft_pull_request"][command]!
            return { [weak self] in self?.native(operation,token:token,arguments:["thread_id":target.threadID]) }
        case "toggleThreadPin", "copyConversationMarkdown", "archiveThread", "openSideChat":
            guard let target,!target.usesNativeSettings,let token=nativeToken,
                  foreground["threadId"] as? String == target.threadID,foreground["canOpenThreadMenu"] as? Bool == true else { return nil }
            let operation=["toggleThreadPin":"toggle_keypad_pin","copyConversationMarkdown":"copy_keypad_markdown","archiveThread":"archive_keypad_thread","openSideChat":"open_keypad_side_chat"][command]!
            return { [weak self] in self?.native(operation,token:token,arguments:["thread_id":target.threadID]) }
        case "toggleTerminal", "openBrowserTab":
            let terminal=command == "toggleTerminal"
            guard let target,!target.usesNativeSettings,let token=nativeToken,
                  foreground["threadId"] as? String == target.threadID,foreground[terminal ? "canToggleTerminal":"canOpenBrowser"] as? Bool == true else { return nil }
            return { [weak self] in self?.native(terminal ? "toggle_keypad_terminal":"open_keypad_browser",token:token,arguments:["thread_id":target.threadID]) }
        case "composer.toggleFastMode": guard canSetFast, let target else { return nil }; return { [weak self] in self?.toggleFast(target: target) }
        case "composer.togglePlanMode": guard canTogglePlan, let target else { return nil }; return { [weak self] in self?.togglePlan(target: target) }
        case "composer.increaseReasoningEffort", "composer.decreaseReasoningEffort":
            guard canSetReasoning, let target else { return nil }
            let delta = command == "composer.increaseReasoningEffort" ? 1 : -1
            return { [weak self] in self?.enqueueSetting(.reasoning(delta),target:target) }
        case "forkThread": guard canFork, let target else { return nil }; return { [weak self] in self?.fork(target: target) }
        case "newTask", "newThread": guard canNavigate else { return nil }; return { [weak self] in self?.newDraft() }
        case "toggleReviewTab", "openReviewTab", "review": guard let target, !target.usesNativeSettings else { return nil }; return { [weak self] in self?.openReview(target: target) }
        case "turn.cancel": guard let target, !target.usesNativeSettings, target.turnID != nil else { return nil }; return { [weak self] in self?.stopTurn(target:target) }
        case "approval.approve", "approval.decline":
            guard let target, !target.usesNativeSettings, approvals.count == 1, let approval=approvals.first else { return nil }
            let decision = command == "approval.approve" ? "accept" : "decline"
            return { [weak self] in self?.reply(approval,decision:decision,target:target) }
        case "composer.submit":
            guard let token, foreground["foreground"] as? Bool == false || foreground["canSubmit"] as? Bool == true else { return nil }
            return { [weak self] in self?.native("submit_keypad_composer", token: token) }
        case "composer.dictation", "dictation.pushToTalk", "composer.sketch":
            let dictation = command != "composer.sketch"
            guard let token, !dictation || foreground["canDictate"] as? Bool == true else { return nil }
            return { [weak self] in self?.native(dictation ? "toggle_keypad_dictation" : "open_keypad_sketch", token: token) }
        case "toggleSidebar", "navigateBack", "navigateForward":
            guard let token=nativeToken, let action = ["toggleSidebar":"sidebar", "navigateBack":"back", "navigateForward":"forward"][command] else { return nil }
            if let actions=foreground["windowNavigationActions"] as? [String] {
                guard actions.contains(action) else { return nil }
            } else if isNativeComposer { return nil }
            return { [weak self] in self?.native("navigate_keypad_ui", token: token, arguments: ["action":action]) }
        default: return nil
        }
    }

    private var canNavigateDial:Bool {
        !isNativeComposer || (foreground["dialNavigationAvailable"] as? Bool == true &&
            foreground["selectionKnown"] as? Bool == true &&
            ClientThreadIdentity.fromRoute(foreground["routeKey"] as? String) != nil)
    }
    private func enqueueNavigation(_ action:String,steps:Int=1,token:String) {
        let amount=max(1,min(64,steps)),deadline=uptime()+5
        if let input=navigationInput {
            guard input.originToken == token,input.pending.count < 64 else { return }
            if let last=input.pending.last,last.0 == action,last.1+amount <= 64 {
                input.pending[input.pending.count-1]=(action,last.1+amount,min(last.2,deadline))
            } else { input.pending.append((action,amount,deadline)) }
            return
        }
        guard !controlling,nativeToken == token,reasoningInput == nil,canNavigateDial else { return }
        let identity=foreground["routeKey"] as? String ?? foreground["threadId"] as? String
        guard let identity else { return }
        let input=NavigationInput(token);input.pending=[(action,amount,deadline)];navigationInput=input
        controlling=true;controlError=nil;selectionVersion += 1
        let generation=lifecycle,version=selectionVersion
        controlTask=Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == lifecycle {
                    if navigationInput === input {navigationInput=nil}
                    controlling=false;controlTask=nil;reconcileRoster()
                    if needsControlRefresh,canAutomaticallyRefreshControls {refreshControls(clearError:false)}
                }
            }
            do {
                while navigationInput === input,!input.pending.isEmpty {
                    try Task.checkCancellation()
                    let next=input.pending.removeFirst()
                    guard lifecycle == generation,selectionVersion == version,uptime() <= next.2 else { throw NSError(domain:"MicroBridge",code:1,userInfo:[NSLocalizedDescriptionKey:tr("targetChanged")]) }
                    let result=try await client.execute("navigate_keypad_ui",arguments:["target_token":input.token,"action":next.0,"steps":next.1,"input_deadline_uptime":next.2])
                    guard !Task.isCancelled,lifecycle == generation,selectionVersion == version else { return }
                    guard result["verified"] as? Bool == true,let observed=result["state"] as? [String:Any],
                          (observed["routeKey"] as? String ?? observed["threadId"] as? String) == identity,
                          let renewed=observed["targetToken"] as? String else { throw NSError(domain:"MicroBridge",code:2,userInfo:[NSLocalizedDescriptionKey:tr("unverifiedControl")]) }
                    foreground=observed;input.token=renewed
                }
            } catch {
                if !Task.isCancelled,lifecycle == generation {
                    controlError=error.localizedDescription
                    if (error as NSError).domain == "MicroBridge",(error as NSError).code == 2 {
                        needsControlRefresh=true;canAutomaticallyRefreshControls=true
                    }
                }
            }
        }
    }

    func prepareJoystick() -> ((String) -> Bool)? {
        guard analogBindings.values.contains(where:{prepareBinding($0) != nil}) else {return nil}
        let generation=lifecycle,scope=rosterScope,context=contextID,bindings=analogBindings
        var version=selectionVersion
        return { [weak self] direction in
            guard let self,self.lifecycle == generation,self.rosterScope == scope,self.contextID == context,
                  self.selectionVersion == version,
                  self.analogBindings as NSDictionary == bindings as NSDictionary,
                  let action=self.prepareBinding(bindings[direction]) else {return false}
            action()
            // Own actions advance the control version. External target changes
            // invalidate the held gesture instead of retargeting its next move.
            version=self.selectionVersion
            return true
        }
    }
    func prepareNavigationDial(_ mode: String, profile: DialProfile) -> DialActions? {
        if mode == "custom" {
            let actions=encoderBindings.compactMapValues { prepareBinding($0) }
            guard !actions.isEmpty else { return nil }
            return DialActions(step: { steps in
                guard steps != 0 else { return }
                let direction=DialMapping.forward(steps,inverted:profile.invertDirection) ? "right" : "left"
                actions[direction]?()
            }, end: { _ in }, tap: { actions["click"]?() })
        }
        guard ["composer-navigation", "conversation-scroll"].contains(mode) else { return nil }
        guard canNavigateDial, let token = navigationInput?.originToken ?? nativeToken else { return nil }
        return DialActions(step: { [weak self] steps in
            guard steps != 0 else { return }
            let forward = DialMapping.forward(steps,inverted:profile.invertDirection)
            let action = mode == "conversation-scroll" ? (forward ? "scroll-down" : "scroll-up") : (forward ? "composer-next" : "composer-previous")
            self?.enqueueNavigation(action,steps:abs(max(-64,min(64,steps))),token:token)
        }, end: { _ in }, tap: { [weak self] in
            if mode == "composer-navigation" { self?.enqueueNavigation("composer-activate",token:token) }
            else { self?.enqueueNavigation("scroll-bottom",token:token) }
        })
    }

    func refreshControls(clearError: Bool = true) {
        guard !refreshingControls, !controlling, !opening, reasoningInput == nil else { return }
        refreshingControls = true
        let generation = lifecycle
        Task { [weak self] in
            guard let self, generation == self.lifecycle else { return }
            defer { if generation == lifecycle { refreshingControls = false } }
            let recoveringError = canAutomaticallyRefreshControls ? controlError : nil
            await refreshForeground()
            guard generation == lifecycle, !controlling else { return }
            let version = selectionVersion
            // The foreground read already refreshed a native composer and its
            // token. Reading it twice can invalidate this recovery's version.
            if !usesNativeSettings { await refreshSelection() }
            guard version == selectionVersion, generation == lifecycle, !controlling, !opening else { return }
            if desktopConnected || foreground["available"] as? Bool == true {
                needsControlRefresh = false
                canAutomaticallyRefreshControls = false
                // The log retains the failed action. A successful observation
                // clears only the error being recovered, without replaying it.
                if clearError || recoveringError != nil && controlError == recoveringError { controlError = nil }
            }
            updateError()
        }
    }

    private func updateError() { error = openError ?? catalogueError ?? selectionError }
}
