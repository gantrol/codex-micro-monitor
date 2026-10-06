import AppKit
import ApplicationServices
import MicroCore
import MicroShared
import OSLog

// Clicking the controller itself temporarily takes foreground from Codex.
// Retain only the most recent external process, never a title or chat identity.
final class SubmissionFocus: @unchecked Sendable {
    private let controller: Int32
    private let lock = NSLock()
    private var lastExternal: Int32?
    init(controller: Int32) { self.controller = controller }
    func activated(_ process: Int32?) {
        lock.lock(); defer { lock.unlock() }
        if process != controller { lastExternal = process }
    }
    func isForeground(_ process: Int32?, target: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if process != controller { lastExternal = process }
        return process == target || (process == controller && lastExternal == target)
    }
}

/// Shared by the panel and MCP. A token is an expiring native target lease,
/// never a chat title or a caller-supplied window coordinate.
final class MacUIController: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.gantrol.codex-micro-monitor", category: "native-control")
    private static let observationLogger = Logger(subsystem: "com.gantrol.codex-micro-monitor", category: "native-observation")
    static let operations: Set<String> = ["get_keypad_ui_state", "submit_keypad_composer", "navigate_keypad_ui",
        "insert_keypad_skill", "insert_keypad_preset_text", "open_keypad_sketch", "set_keypad_draft_model", "set_keypad_draft_reasoning",
        "set_keypad_draft_fast", "toggle_keypad_draft_plan", "toggle_keypad_dictation",
        "toggle_keypad_pin", "copy_keypad_markdown", "archive_keypad_thread", "toggle_keypad_terminal", "open_keypad_browser", "open_keypad_side_chat", "open_keypad_feedback", "open_keypad_files", "open_keypad_photos", "open_keypad_branch", "open_keypad_pull_request", "open_keypad_draft_pull_request", "open_keypad_commit", "open_keypad_merge_pull_request", "run_keypad_environment_action"]
    private static let draftTransactionOperations:Set<String>=["get_keypad_draft_selection","refresh_keypad_draft_target"]
    private static let threadMenuOperations:Set<String>=["toggle_keypad_pin","copy_keypad_markdown","archive_keypad_thread","open_keypad_side_chat"]
    private static let gitOperations:[String:NativeGitWorkflow.Action]=["open_keypad_merge_pull_request":.mergePullRequest,"open_keypad_commit":.commit,"open_keypad_branch":.branch,"open_keypad_pull_request":.pullRequest,"open_keypad_draft_pull_request":.draftPullRequest]
    private static let panelOperations:Set<String>=["toggle_keypad_terminal","open_keypad_browser"]
    private static let dialNavigationActions:Set<String>=["composer-next","composer-previous","composer-activate","scroll-up","scroll-down","scroll-bottom"]
    private static func canNavigateDial(_ state:MacUISnapshot) -> Bool {
        guard !state.blocked,state.editor?.text != nil else {return false}
        if state.thread != nil || state.draft {return true}
        // A verified client route is sufficient for native focus/scroll actions.
        // The unidentified composer fallback remains settings-only.
        return state.nativeComposer && state.selectionKnown &&
            state.clientThreadID.flatMap(ClientThreadIdentity.canonical) != nil &&
            (state.clientBinding == nil || state.bindingVerified)
    }
    private let queue = DispatchQueue(label: "com.gantrol.micro.native-ui", qos: .userInitiated)
    private var lease: (token: String, snapshot: MacUISnapshot, expires: Double, settings:[String:Any], settingsAt:Double, binding:VerifiedClientRoute?)?
    private var observation: (token: String, snapshot: MacUISnapshot, expires: Double)?
    private var readOnlyObservation: (token: String, snapshot: DesktopRouteObservation.Snapshot, expires: Double)?
    private var lastObservationSummary:String?
    private var lastSlowObservation: TimeInterval = -.infinity
    private let submissionFocus:SubmissionFocus
    private var activationObserver: NSObjectProtocol?
    private let io: NativeUIAccess

    init(io: NativeUIAccess = .live,controllerPID:Int32=getpid()) {
        self.io=io;self.submissionFocus=SubmissionFocus(controller:controllerPID)
        if io.observeActivation { activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self?.submissionFocus.activated(app?.processIdentifier)
            } }
        submissionFocus.activated(io.foreground())
    }
    deinit {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }
    private func targetWasForeground(_ app: NSRunningApplication) -> Bool {
        submissionFocus.isForeground(io.foreground(), target: app.processIdentifier)
    }

    func execute(_ operation: String, arguments: [String: Any], models: [[String: Any]] = [], verification:VerifiedClientRoute?=nil) async throws -> [String: Any] {
        let context = UIRequestContext()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do { continuation.resume(returning: try self.perform(operation, arguments: arguments, models: models, context: context,verification:verification)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { context.cancel() }
    }
    func close() { queue.async { self.lease = nil;self.observation=nil;self.readOnlyObservation=nil;self.lastObservationSummary=nil } }

    private func recordObservation(_ state:[String:Any])->[String:Any] {
        let available=state["available"] as? Bool == true,accessibility=state["accessibility"] as? Bool == true
        let kind: String
        switch NativeObservation(state).identity {
        case .thread: kind = "thread"
        case .draft: kind = "draft"
        case .client: kind = "client"
        case .unidentifiedComposer: kind = "composer"
        case .unknown: kind = "unresolved"
        }
        let diagnostics=state["diagnostics"] as? [String:Any] ?? [:]
        let flags=["composerAvailable","composerContainerAvailable","modelPickerAvailable","blocked"].map {"\($0)=\(diagnostics[$0] as? Bool == true)"}.joined(separator:" ")
        let picker="pickerSource=\(diagnostics["pickerSource"] as? String ?? "none") pickerCandidates=\(diagnostics["pickerCandidates"] as? Int ?? 0)"
        let relationships="adapter=\(diagnostics["adapterRevision"] as? String ?? "unknown") titleRefs=\(diagnostics["titleRelationshipCount"] as? Int ?? 0) resolvedTitleRefs=\(diagnostics["resolvedTitleRelationshipCount"] as? Int ?? 0) pickerLinkedMenu=\(diagnostics["pickerExpandedFromLinkedMenu"] as? Bool == true) modelLabels=\(diagnostics["modelLabelCount"] as? Int ?? 0)"
        let home=diagnostics["homeComposerEvidence"] as? String ?? "none"
        let reason=state["reason"] as? String ?? ""
        let route=state["routeAvailable"] as? Bool == true,known=state["selectionKnown"] as? Bool == true,focused=state["appFocused"] as? Bool == true
        let code=state["failureCode"] as? String ?? "none",source=state["routeSource"] as? String ?? "none"
        let summary="available=\(available) accessibility=\(accessibility) kind=\(kind) routeAvailable=\(route) selectionKnown=\(known) appFocused=\(focused) \(flags) \(picker) \(relationships) home=\(home) source=\(source) failure=\(code)"
        let identity=summary+" "+reason
        if identity != lastObservationSummary {
            lastObservationSummary=identity
            let milliseconds=(diagnostics["captureMilliseconds"] as? Double ?? 0).rounded()
            if available {Self.observationLogger.info("Native state: \(summary,privacy:.public) captureMs=\(milliseconds,privacy:.public)")}
            else {Self.observationLogger.warning("Native state: \(summary,privacy:.public); reason: \(reason,privacy:.private)")}
        }
        let duration=diagnostics["captureMilliseconds"] as? Double ?? 0,now=ProcessInfo.processInfo.systemUptime
        if duration >= 1000,now-lastSlowObservation >= 30 {
            lastSlowObservation=now
            Self.observationLogger.warning("Slow native observation: captureMs=\(duration,privacy:.public) nodes=\(diagnostics["nodeCount"] as? Int ?? 0,privacy:.public)")
        }
        return state
    }

    func discardBinding(observationToken:String) async {
        await withCheckedContinuation { (continuation:CheckedContinuation<Void,Never>) in queue.async {
            if self.observation?.token == observationToken,self.observation?.snapshot.clientBinding != nil {
                self.observation=nil;self.lease=nil
            }
            continuation.resume()
        } }
    }
    func confirmBinding(_ verification:VerifiedClientRoute,observationToken:String,models:[[String:Any]]) async throws->[String:Any] {
        let context=UIRequestContext()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in queue.async {
                do {
                    try context.check()
                    guard verification.fresh,let old=self.observation,old.token == observationToken,
                          old.expires >= ProcessInfo.processInfo.systemUptime,
                          old.snapshot.clientBinding == verification.pair else {throw CodexClientError.staleTarget}
                    var state=try (self.io.observe ?? self.io.capture)(context,models.flatMap(Self.modelLabels))
                    guard verification.fresh,state.clientBinding == verification.pair,old.snapshot.sameObservedTarget(state) else {throw CodexClientError.staleTarget}
                    state.bindingVerified=true
                    continuation.resume(returning:self.recordObservation(self.project(state,models:models,verification:verification)))
                } catch {continuation.resume(throwing:error)}
            } }
        } onCancel:{context.cancel()}
    }

    private func project(_ state: MacUISnapshot, models: [[String: Any]], confirmed:[String:Any]? = nil,verification:VerifiedClientRoute?=nil) -> [String: Any] {
        readOnlyObservation = nil
        let now=ProcessInfo.processInfo.systemUptime
        if (state.route != nil && state.route != "conflict") || state.nativeComposer {
            let token = observation.flatMap { old in
                old.expires >= now && old.snapshot.sameObservedTarget(state) ? old.token : nil
            } ?? UUID().uuidString
            observation = (token,state,now+5)
        } else { observation = nil }
        var settings=Self.settings(state,models:models),settingsAt=now
        var source="native-observation"
        if let confirmed { settings=confirmed.merging(settings) { _,observed in observed };source="native-menu-readback" }
        else if let old=lease,now-old.settingsAt <= 15,old.snapshot.sameTarget(state,text:true),old.snapshot.settings as NSDictionary == state.settings as NSDictionary,
                let id=old.settings["model"] as? String,models.contains(where:{$0["model"] as? String == id}),settings["model"] == nil || settings["effort"] == nil {
            settings=old.settings.merging(settings) { _,observed in observed };settingsAt=old.settingsAt;source="recent-native-readback"
        }
        let pending=state.clientBinding != nil && !state.bindingVerified
        let composerUsable = !pending && (state.thread != nil || state.draft || state.nativeComposer) && state.editor?.text != nil && !state.blocked
        let usable = composerUsable && state.picker != nil
        let threadMenuUsable = state.thread != nil && state.threadMenuTrigger != nil && !state.blocked
        let exactWindowUsable = state.thread != nil && !state.blocked
        let knownPageUsable = state.clientBinding == nil && state.selectionKnown && state.route != nil && state.route != "conflict" && !state.blocked
        let binding=verification ?? (state.clientBinding != nil ? lease?.binding:nil)
        // A re-observed alias is temporarily pending while Core verifies it.
        // Keep an existing matching lease internally across that read roundtrip;
        // targetToken remains null until verification succeeds. Dropping it here
        // would rotate every control token before the command can validate it.
        let recheckingLease = pending && lease != nil && observation != nil
        if composerUsable || exactWindowUsable || knownPageUsable || recheckingLease {
            if let old = lease, old.expires >= ProcessInfo.processInfo.systemUptime,
               old.snapshot.sameTarget(state, text: true), old.snapshot.settings as NSDictionary == state.settings as NSDictionary,
               verification == nil || old.binding == nil || verification!.sameIdentity(old.binding) {
                lease = (old.token,state,now+15,settings,settingsAt,binding)
            } else { lease = (UUID().uuidString,state,now+15,settings,settingsAt,state.bindingVerified ? binding:verification) }
        } else { lease = nil }
        var result: [String: Any] = ["accessibility": true, "available": composerUsable || exactWindowUsable || knownPageUsable, "draft": state.draft, "nativeComposer": state.nativeComposer,
            "foreground": targetWasForeground(state.app),"appFocused":io.foreground() == state.app.processIdentifier,
            "routeAvailable":state.thread != nil || state.draft, "selectionKnown":state.selectionKnown || state.blocked,
            "routeKey": state.bindingVerified ? "client:"+(state.clientThreadID ?? "") : state.route ?? NSNull() as Any,
            "clientThreadId":state.clientThreadID ?? NSNull() as Any,
            "threadId": state.thread ?? NSNull() as Any, "targetToken": pending ? NSNull() : lease?.token ?? NSNull() as Any,
            "observationToken": observation?.token ?? NSNull() as Any,
            "canSubmit": composerUsable && (state.thread != nil || state.draft) && state.send != nil && !(state.editor?.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
            "plan": state.plan, "picker": state.picker?.name ?? "", "sketchOpen": state.sketchOpen, "reviewOpen": state.reviewOpen]
        result["canDictate"] = composerUsable && (state.thread != nil || state.draft) && state.controls.contains { state.nodes[$0].enabled && state.nodes[$0].named(MacUISnapshot.voiceNames + MacUISnapshot.voiceStopNames) }
        result["canOpenThreadMenu"] = threadMenuUsable && state.topLevelMenus.isEmpty
        result["canToggleTerminal"] = exactWindowUsable && state.topLevelMenus.isEmpty
        result["canOpenBrowser"] = exactWindowUsable && state.topLevelMenus.isEmpty
        result["canRunEnvironmentAction"] = exactWindowUsable && state.topLevelMenus.isEmpty && state.composerMenuItems.isEmpty
        result["canOpenGitWorkflow"] = exactWindowUsable && state.topLevelMenus.isEmpty && state.composerMenuItems.isEmpty
        result["canOpenFeedback"] = knownPageUsable && state.topLevelMenus.isEmpty
        result["windowNavigationActions"] = pending ? [] : NativeWindowNavigation.actions.filter { NativeWindowNavigation.button($0,in:state) != nil }
        result["dialNavigationAvailable"] = !pending && Self.canNavigateDial(state)
        let attachmentTarget=(state.thread != nil || state.draft) && state.editor?.text != nil && !state.blocked && state.topLevelMenus.isEmpty && state.composerMenuItems.isEmpty
        let attachmentMenu=state.controls.contains {state.nodes[$0].enabled && state.nodes[$0].named(MacUISnapshot.addNames)}
        result["canInsertPresetText"] = attachmentTarget && state.menuItems.isEmpty
        result["canOpenFiles"] = attachmentTarget && attachmentMenu
        result["canOpenPhotos"] = attachmentTarget && (attachmentMenu || NativeFilePicker.photosShortcut(io) != nil)
        result["draftPlanAvailable"] = composerUsable && (state.draft || state.nativeComposer) &&
            ((try? io.shortcut("composer.togglePlanMode")) != nil || state.plan || state.controls.contains { state.nodes[$0].named(MacUISnapshot.addNames) })
        result["draftFastAvailable"] = usable && (state.draft || state.nativeComposer)
        result["draftReasoningAvailable"] = usable && (state.draft || state.nativeComposer)
        result["settings"] = settings
        result["settingsSource"] = source
        result["diagnostics"]=["nodeCount":state.nodes.count,"composerAvailable":state.editor?.text != nil,
            "composerContainerAvailable":state.container != nil,"modelPickerAvailable":state.picker != nil,"blocked":state.blocked,
            "composerCandidates":state.composerCandidates,"pickerCandidates":state.pickerCandidates,"pickerSource":state.pickerSource,
            "adapterRevision":"ax-relations-r2",
            "titleRelationshipCount":state.nodes.filter { $0.titleElement != nil }.count,
            "resolvedTitleRelationshipCount":state.nodes.filter { $0.titleRelationshipResolved }.count,
            "pickerExpandedFromLinkedMenu":state.picker?.expandedFromLinkedMenu ?? false,
            "modelLabelCount":state.modelLabels.count,
            "captureMilliseconds":state.captureDuration*1000,
            "processID":state.app.processIdentifier,"windowFingerprint":String(CFHash(state.window)),
            "homeComposerEvidence":MacUISnapshot.homeComposerEvidence(nodes:state.nodes,composer:state.composer,container:state.container,controls:state.controls,modelLabels:state.modelLabels) ?? "none"]
        result["observedAtUptime"]=state.observedAtUptime
        result["routeSource"]=state.routeEvidence
        if !usable {
            if state.route == "conflict" {result["failureCode"]="routeConflict";result["reason"]="Native route and selection evidence conflict."}
            else if state.blocked {result["failureCode"]="dialogBlocked";result["reason"]="A Codex dialog is blocking the native target."}
            else if pending {result["failureCode"]="bindingUnverified";result["reason"]="The client/server conversation binding has not been verified."}
            else if state.editor?.text == nil {result["failureCode"]="composerUnavailable";result["reason"]="A unique native Codex composer was not found."}
            else if state.picker == nil {result["failureCode"]="modelPickerUnavailable";result["reason"]="The native composer model picker was not found."}
            else {result["failureCode"]="routeUnavailable";result["reason"]="The native route does not identify a supported local composer."}
        }
        if pending,let pair=state.clientBinding {
            result["clientBindingCandidate"]=pair.dictionary
            result["bindingObservationToken"]=observation?.token ?? NSNull() as Any
        }
        if state.bindingVerified {result["clientBindingVerified"]=true}
        return result
    }

    private func projectReadOnly(_ snapshot: DesktopRouteObservation.Snapshot) -> [String: Any] {
        let route = snapshot.route, now = ProcessInfo.processInfo.systemUptime
        if route.threadID != nil || route.clientThreadID != nil {
            let token = readOnlyObservation.flatMap { old in
                old.expires >= now && old.snapshot.sameTarget(snapshot) ? old.token : nil
            } ?? UUID().uuidString
            readOnlyObservation = (token, snapshot, now + 5)
        } else { readOnlyObservation = nil }
        return ["available": false, "accessibility": true, "routeReadOnly": true,
                "routeAvailable": route.threadID != nil, "selectionKnown": route.known,
                "routeKey": route.key ?? NSNull() as Any, "threadId": route.threadID ?? NSNull() as Any,
                "clientThreadId": route.clientThreadID ?? NSNull() as Any,
                "observationToken": readOnlyObservation?.token ?? NSNull() as Any, "targetToken": NSNull(),
                "draft": false, "nativeComposer": false, "routeSource": "desktop-window-log",
                "appFocused": io.foreground() == snapshot.processID, "observedAtUptime": now]
    }

    private func perform(_ operation: String, arguments a: [String: Any], models: [[String: Any]], context: UIRequestContext,verification:VerifiedClientRoute?) throws -> [String: Any] {
        try context.check()
        if operation == "get_keypad_ui_state" {
            do { return recordObservation(project(try (io.observe ?? io.capture)(context,models.flatMap(Self.modelLabels)), models: models)) }
            catch {
                lease = nil; observation = nil
                if let snapshot = try? io.observeRoute?(context) {
                    var route = projectReadOnly(snapshot)
                    route["reason"] = error.localizedDescription
                    route["failureCode"] = (error as? NativeObservationFailure)?.rawValue ?? "observationFailed"
                    return recordObservation(route)
                }
                readOnlyObservation = nil
                return recordObservation(["available": false, "accessibility": AXIsProcessTrusted(), "reason": error.localizedDescription,
                                          "failureCode": (error as? NativeObservationFailure)?.rawValue ?? "observationFailed"])
            }
        }
        if operation == "insert_keypad_preset_text",ComposerTextPreset(rawValue:a["preset"] as? String ?? "") == nil {throw CodexClientError.invalid("Unknown composer preset.")}
        guard let token = a["target_token"] as? String, let captured = lease, captured.token == token,
              captured.expires >= ProcessInfo.processInfo.systemUptime else { throw CodexClientError.staleTarget }
        let before = captured.snapshot
        if before.clientBinding != nil {
            guard before.bindingVerified,let verification,verification.fresh,captured.binding == verification,
                  before.clientBinding == verification.pair else {throw CodexClientError.staleTarget}
        }
        if operation == "navigate_keypad_ui",let action=a["action"] as? String,NativeWindowNavigation.actions.contains(action) {
            do {
                let after=try NativeWindowNavigation.perform(action,before:before,io:io,models:models,context:context)
                lease=nil
                return ["verified":true,"state":project(after,models:models)]
            } catch {
                lease=nil
                throw error
            }
        }
        var io=self.io
        if let verification {
            let capture=io.capture
            io.capture={ context,labels in
                var state=try capture(context,labels)
                guard state.clientBinding == verification.pair else {throw CodexClientError.staleTarget}
                state.bindingVerified=true
                return state
            }
        }
        if before.nativeComposer || before.clientThreadID != nil, !operation.hasPrefix("set_keypad_draft_"), operation != "toggle_keypad_draft_plan",
           !Self.draftTransactionOperations.contains(operation),
           !(operation == "navigate_keypad_ui" && Self.dialNavigationActions.contains(a["action"] as? String ?? "") && Self.canNavigateDial(before)) {
            throw CodexClientError.unavailable("This native composer has no exact chat ID; only settings controls are available.")
        }
        if let thread = a["thread_id"] as? String, before.thread != thread { throw CodexClientError.staleTarget }
        if let deadline = a["input_deadline_uptime"] as? Double, !deadline.isFinite || ProcessInfo.processInfo.systemUptime > deadline { throw CodexClientError.staleTarget }
        var mutated = false
        func fresh(preserveText: Bool = true, requireComposer: Bool = true) throws -> MacUISnapshot {
            try context.check()
            if let deadline = a["input_deadline_uptime"] as? Double, !deadline.isFinite || ProcessInfo.processInfo.systemUptime > deadline { throw CodexClientError.staleTarget }
            let current = try io.capture(context,models.flatMap(Self.modelLabels))
            guard MacAX.same(before.window, current.window), before.app.processIdentifier == current.app.processIdentifier,
                  !requireComposer || (!current.blocked && before.sameTarget(current, text: preserveText)) else { throw CodexClientError.staleTarget }
            return current
        }
        func front() throws {
            _ = try fresh()
            if io.foreground() != before.app.processIdentifier {
                guard io.activate(before.app) else { throw CodexClientError.unavailable("Codex could not become the active application.") }
                let end = ProcessInfo.processInfo.systemUptime + 1
                while io.foreground() != before.app.processIdentifier && ProcessInfo.processInfo.systemUptime < end { try context.check(); Thread.sleep(forTimeInterval: 0.02) }
            }
            guard io.foreground() == before.app.processIdentifier else { throw CodexClientError.staleTarget }
            _ = try fresh()
        }
        func press(_ node: AXNode, preserveText: Bool = true) throws {
            _ = try fresh(preserveText: preserveText)
            guard node.enabled else { throw CodexClientError.unavailable("The control is disabled.") }
            mutated = true; try io.press(node.element)
        }
        func wait(_ predicate: (MacUISnapshot) -> Bool, preserveTarget: Bool = true) throws -> MacUISnapshot {
            let end = ProcessInfo.processInfo.systemUptime + 2.5
            repeat {
                let current = try fresh(preserveText: preserveTarget, requireComposer: preserveTarget)
                if predicate(current) { return current }
                Thread.sleep(forTimeInterval: 0.04)
            } while ProcessInfo.processInfo.systemUptime < end
            throw CodexClientError.outcomeUnknown
        }
        func key(_ shortcut: MacShortcut, preserveText: Bool = true) throws {
            _ = try fresh(preserveText: preserveText)
            mutated = true
            try io.send(shortcut,before.app.processIdentifier) {
                let current=try fresh(preserveText:preserveText)
                guard io.foreground() == before.app.processIdentifier,
                      MacAX.same(before.window,current.window) else { throw CodexClientError.staleTarget }
            }
        }
        do {
            guard !before.blocked, before.editor != nil || (Self.threadMenuOperations.contains(operation) && before.threadMenuTrigger != nil) || ((Self.panelOperations.contains(operation) || Self.gitOperations[operation] != nil || operation == "run_keypad_environment_action") && before.thread != nil) || (operation == "open_keypad_feedback" && before.selectionKnown && before.route != nil && before.route != "conflict") else { throw CodexClientError.staleTarget }
            if operation == "submit_keypad_composer", a["activation_only"] as? Bool == true || !targetWasForeground(before.app) {
                // Restoring focus consumes this press; a later foreground press sends.
                try front(); lease = nil
                return ["activated":true,"submitted":false,"verified":true,"state":project(try fresh(),models:models)]
            }
            try front()
            if operation == "refresh_keypad_draft_target" {
                let current=try fresh()
                let matchingKind=a["native_composer"] as? Bool == true ? current.nativeComposer:current.draft
                guard matchingKind,current.menuItems.isEmpty else {throw CodexClientError.staleTarget}
                return ["verified":true,"state":project(current,models:models,verification:verification)]
            }
            guard before.settings as NSDictionary == (try fresh()).settings as NSDictionary else { throw CodexClientError.staleTarget }
            var after: MacUISnapshot
            switch operation {
            case "insert_keypad_preset_text":
                let preset=ComposerTextPreset(rawValue:a["preset"] as? String ?? "")!
                after=try NativePresetText.insert(preset,before:before,io:io,context:context,capture:{try fresh(preserveText:$0)},mutation:{mutated=true})
                lease=nil
                return ["verified":true,"inserted":true,"preset":preset.rawValue,"submitted":false,"clipboardModified":false,"state":project(after,models:models)]
            case "run_keypad_environment_action":
                guard before.thread != nil,a["thread_id"] as? String == before.thread else {throw CodexClientError.staleTarget}
                after=try NativeEnvironmentAction.run(before:before,io:io,context:context,capture:{try fresh(preserveText:false,requireComposer:false)},mutation:{mutated=true})
                // The action terminal may be reused; its identity confirms the
                // native handoff, not the shell command's completion or exit code.
                return ["verified":true,"runRequested":true,"terminalVerified":true,"executionVerified":false,
                    "threadId":before.thread!,"terminalIdentifier":NativeEnvironmentAction.terminals(after)[0].identifier,"state":project(after,models:models)]
            case "open_keypad_branch", "open_keypad_pull_request", "open_keypad_draft_pull_request", "open_keypad_commit", "open_keypad_merge_pull_request":
                guard let action=Self.gitOperations[operation],before.thread != nil,a["thread_id"] as? String == before.thread else {throw CodexClientError.staleTarget}
                after=try NativeGitWorkflow.open(action,before:before,io:io,context:context,capture:{try fresh(preserveText:false,requireComposer:false)},mutation:{mutated=true})
                guard let stage=NativeGitWorkflow.stage(after,action:action) else {throw CodexClientError.outcomeUnknown}
                lease=nil
                var result:[String:Any] = ["verified":true,"threadId":before.thread!,"workflowOpened":true,"workflow":action.rawValue,
                    "workflowStage":stage.rawValue,"prDefaultVerified":stage == .pullRequestForm,
                    "mutationCompleted":false,"state":project(after,models:models)]
                if action == .mergePullRequest {
                    result["mergeMethod"]=NativeGitWorkflow.mergeMethod(after)
                    result["mergeCompleted"]=false
                    // The native confirmation does not expose a PR number.
                    // Its surrounding app-shell ID is an opaque UI instance ID.
                    result["pullRequestIdentityVerified"]=false
                }
                return result
            case "open_keypad_files", "open_keypad_photos":
                guard before.thread != nil || before.draft,before.editor?.text != nil else {throw CodexClientError.staleTarget}
                let kind:NativeFilePicker.Kind=operation == "open_keypad_photos" ? .photos:.files
                let entry=try NativeFilePicker.open(kind,before:before,io:io,context:context,capture:{try fresh()},mutation:{mutated=true})
                lease=nil
                return ["verified":true,"pickerOpened":true,"pickerKind":kind.rawValue,"pickerEntryPoint":entry,
                    "imagesOnlyRequested":kind == .photos,"awaitingSelection":true,"attachmentVerified":false,
                    "state":["available":false,"selectionKnown":true,"routeKey":"modal:file-picker","threadId":NSNull(),"targetToken":NSNull()]]
            case "open_keypad_feedback":
                guard before.selectionKnown,before.route != nil,before.route != "conflict",before.topLevelMenus.isEmpty,
                      let command=try io.applicationCommand(before.app.processIdentifier,MacUISnapshot.feedbackCommands,context) else { throw CodexClientError.unavailable("The native feedback command is unavailable.") }
                guard (try fresh()).topLevelMenus.isEmpty,
                      let checked=try io.applicationCommand(before.app.processIdentifier,MacUISnapshot.feedbackCommands,context),MacAX.same(command.element,checked.element) else { throw CodexClientError.staleTarget }
                try press(checked)
                after=try wait({ $0.route == before.route && $0.feedbackDialog != nil },preserveTarget:false)
                lease=nil
                return ["verified":true,"feedbackOpened":true,"submitted":false,"state":project(after,models:models)]
            case "toggle_keypad_terminal", "open_keypad_browser":
                guard before.thread != nil,a["thread_id"] as? String == before.thread,before.topLevelMenus.isEmpty else { throw CodexClientError.staleTarget }
                let terminal=operation == "toggle_keypad_terminal"
                let names=terminal ? ["Open Terminal","打开终端","開啟終端機"]:["Open Browser Tab","打开浏览器标签页","開啟瀏覽器分頁"]
                guard let command=try io.applicationCommand(before.app.processIdentifier,names,context) else { throw CodexClientError.unavailable("The native panel command is unavailable.") }
                let current=try fresh()
                guard current.topLevelMenus.isEmpty else { throw CodexClientError.staleTarget }
                guard let rechecked=try io.applicationCommand(before.app.processIdentifier,names,context),MacAX.same(command.element,rechecked.element) else { throw CodexClientError.staleTarget }
                let previousPanels=Set(current.browserPanels.map(\.identifier))
                try press(rechecked)
                if terminal {
                    after=try wait({ $0.thread == before.thread && !$0.blocked && $0.visibleTerminalCount != current.visibleTerminalCount },preserveTarget:false)
                    return ["verified":true,"threadId":before.thread!,"terminalVisible":after.visibleTerminalCount > 0,"visibleTerminalCount":after.visibleTerminalCount,"state":project(after,models:models)]
                }
                func created(_ state:MacUISnapshot) -> [AXNode] {
                    state.browserPanels.filter { $0.rect.width > 0 && $0.rect.height > 0 && !previousPanels.contains($0.identifier) }
                }
                after=try wait({ $0.thread == before.thread && !$0.blocked && created($0).count == 1 },preserveTarget:false)
                return ["verified":true,"threadId":before.thread!,"browserOpened":true,"browserPanel":created(after)[0].identifier,"state":project(after,models:models)]
            case "toggle_keypad_pin", "copy_keypad_markdown", "archive_keypad_thread", "open_keypad_side_chat":
                guard a["thread_id"] as? String == before.thread,before.thread != nil else { throw CodexClientError.staleTarget }
                let actions:[String:NativeThreadMenu.Action]=["toggle_keypad_pin":.pin,"copy_keypad_markdown":.copyMarkdown,"archive_keypad_thread":.archive,"open_keypad_side_chat":.sideChat]
                let action=actions[operation]!
                let result=try NativeThreadMenu.perform(action,before:before,io:io,context:context,
                    capture:{try fresh()},captureAfterNavigation:{try fresh(requireComposer:false)},mutation:{mutated=true})
                lease=nil
                return result.fields.merging(["state":project(result.state,models:models)]) { _,new in new }
            case "submit_keypad_composer":
                let current = try fresh()
                guard current.menuItems.isEmpty, let send = current.send,
                      !(current.editor?.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
                      !current.controls.contains(where: { current.nodes[$0].named(MacUISnapshot.stopNames) }) else { throw CodexClientError.unavailable("The current composer is not ready to send.") }
                try press(send)
                after = try wait({ state in
                    let began = state.controls.contains { state.nodes[$0].named(MacUISnapshot.stopNames) }
                    return began && (state.thread == before.thread || (before.draft && state.thread != nil)) && state.editor?.text?.isEmpty == true
                }, preserveTarget: false)
            case "navigate_keypad_ui":
                let action = a["action"] as? String ?? ""
                let steps = min(64, max(1, a["steps"] as? Int ?? 1))
                let current = try fresh()
                switch action {
                case "composer-next", "composer-previous", "composer-activate":
                    let choices = current.menuItems.isEmpty ? current.controls.filter { current.nodes[$0].enabled } : current.menuItems
                    guard !choices.isEmpty else { throw CodexClientError.unavailable("No composer controls are available.") }
                    let selected = choices.firstIndex { current.nodes[$0].focused }
                    if action == "composer-activate" {
                        guard let selected else { throw CodexClientError.unavailable("Select a composer control first.") }
                        let node = current.nodes[choices[selected]]
                        // Sending, dictation and purchases are separate explicit operations.
                        let isModel = models.contains { model in
                            [model["model"] as? String, model["displayName"] as? String].compactMap { $0 }.contains { Self.prefix(node.name, $0) }
                        }
                        guard MacAX.same(node.element, current.picker?.element) || node.named(MacUISnapshot.addNames + MacUISnapshot.sketchNames) || isModel else {
                            throw CodexClientError.unavailable("Use the dedicated command or Codex menu for this action.")
                        }
                        try press(node)
                        after = try wait { $0.menuItems.count != current.menuItems.count || $0.picker?.name != current.picker?.name }
                    } else {
                        let delta = (action == "composer-next" ? 1 : -1) * (steps % choices.count)
                        let next = selected.map { ($0 + delta + choices.count) % choices.count } ?? (action == "composer-next" ? 0 : choices.count - 1)
                        let node = current.nodes[choices[next]]
                        mutated = true; try io.set(node.element, "AXFocused", kCFBooleanTrue)
                        after = try wait { snapshot in snapshot.nodes.contains { MacAX.same($0.element, node.element) && $0.focused } }
                    }
                case "scroll-up", "scroll-down", "scroll-bottom":
                    guard let editor = current.editor else { throw CodexClientError.staleTarget }
                    let scrollers = current.nodes.filter { $0.role == "AXScrollArea" && $0.rect.width >= editor.rect.width * 0.6 && $0.rect.minY < editor.rect.minY && $0.rect.maxY <= editor.rect.maxY + 40 && $0.rect.height >= 140 }
                    guard scrollers.count == 1, let scroller = scrollers.first,
                          let bar = MacAX.element(MacAX.value(scroller.element, "AXVerticalScrollBar")),
                          let value = MacAX.value(bar, "AXValue") as? Double else { throw CodexClientError.unavailable("Conversation scroll position is unavailable.") }
                    let next = action == "scroll-bottom" ? 1 : min(1, max(0, value + (action == "scroll-up" ? -0.12 : 0.12) * Double(steps)))
                    if next != value { mutated = true; try io.set(bar, "AXValue", NSNumber(value: next)) }
                    after = try wait { _ in (MacAX.value(bar, "AXValue") as? Double).map { abs($0 - next) < 0.015 } ?? false }
                default: throw CodexClientError.invalid("Unsupported native navigation action.")
                }
            case "open_keypad_sketch":
                var current = try fresh()
                if !current.sketchOpen {
                    guard current.menuItems.isEmpty, let button = current.unique(current.controls, matching: { $0.enabled && $0.named(MacUISnapshot.addNames) }) else { throw CodexClientError.unavailable("The composer add menu is unavailable.") }
                    try press(button)
                    current = try wait { !$0.menuItems.isEmpty }
                    guard let sketch = current.unique(current.menuItems, matching: { $0.named(MacUISnapshot.sketchNames) }) else { throw CodexClientError.unavailable("Sketch is unavailable in this composer.") }
                    try press(sketch)
                }
                after = try wait({ $0.sketchOpen }, preserveTarget: false)
            case "insert_keypad_skill":
                let verified = try MacSkillClipboard.insert(name: a["name"] as? String ?? "", path: a["path"] as? String ?? "", snapshot: before, context: context,
                    check: { preserveText in _ = try fresh(preserveText: preserveText) }, markMutation: { mutated = true })
                after = try fresh(preserveText: false)
                guard verified else { throw CodexClientError.outcomeUnknown }
                lease = nil
                return ["applied": true, "verified": true, "textObserved": after.editor?.text?.contains("$" + (a["name"] as? String ?? "")) ?? false,
                        "structuralVerification": "clipboard-roundtrip", "targetChanged": false]
            case "toggle_keypad_dictation":
                let current = try fresh()
                let wasRecording = current.controls.contains { current.nodes[$0].named(MacUISnapshot.voiceStopNames) }
                let labels = wasRecording ? MacUISnapshot.voiceStopNames : MacUISnapshot.voiceNames
                guard let button = current.unique(current.controls, matching: { $0.enabled && $0.named(labels) }) else { throw CodexClientError.unavailable("Native dictation is unavailable.") }
                try press(button)
                after = try wait({ state in state.controls.contains { state.nodes[$0].named(MacUISnapshot.voiceStopNames) } != wasRecording }, preserveTarget: false)
            case "get_keypad_draft_selection", "set_keypad_draft_model", "set_keypad_draft_reasoning", "set_keypad_draft_fast", "toggle_keypad_draft_plan":
                let matchingKind = a["native_composer"] as? Bool == true ? before.nativeComposer : before.draft
                guard matchingKind, before.menuItems.isEmpty else { throw CodexClientError.staleTarget }
                var current=try fresh()
                var openedPicker=false,openedAdd=false
                defer {
                    if let state=try? fresh(), (openedPicker && state.picker?.expanded == true) || (openedAdd && state.controls.contains { state.nodes[$0].named(MacUISnapshot.addNames) && state.nodes[$0].expanded == true }) {
                        try? key(.init(key:53,flags:[]))
                    }
                }
                func openPicker() throws -> MacUISnapshot {
                    let state=try fresh()
                    if state.picker?.expanded == true, state.modelMenu != nil { return state }
                    guard state.menuItems.isEmpty,let picker=state.picker else { throw CodexClientError.staleTarget }
                    openedPicker=true; try press(picker)
                    return try wait { $0.picker?.expanded == true && $0.modelMenu != nil }
                }
                func closePicker() throws -> MacUISnapshot {
                    if (try fresh()).picker?.expanded == true {
                        try key(.init(key:53,flags:[]))
                        return try wait { $0.picker?.expanded != true && $0.menuItems.isEmpty }
                    }
                    return try fresh()
                }
                func focusedKey(_ shortcut:MacShortcut, element:AXUIElement) throws {
                    _ = try fresh()
                    try io.set(element,"AXFocused",kCFBooleanTrue)
                    _ = try wait { state in state.nodes.contains { MacAX.same($0.element,element) && $0.focused } }
                    try io.send(shortcut,before.app.processIdentifier) {
                        let state=try fresh()
                        if MacAX.same(element,state.editor?.element) {
                            guard state.menuItems.isEmpty && state.picker?.expanded != true else { throw CodexClientError.staleTarget }
                        } else {
                            guard state.modelMenu != nil else { throw CodexClientError.staleTarget }
                        }
                        guard io.foreground() == before.app.processIdentifier,
                              state.nodes.contains(where:{MacAX.same($0.element,element) && $0.focused}) else { throw CodexClientError.staleTarget }
                        mutated=true
                    }
                }
                func verifyExpected(_ state:MacUISnapshot) throws {
                    let actual=Self.settings(state,models:models)
                    if let expected=a["expected_settings"] as? [String:Any] {
                        for (name,value) in expected where !(value is NSNull) {
                            guard let observed=actual[name] as? NSObject,observed.isEqual(value) else { throw CodexClientError.staleTarget }
                        }
                    }
                }
                if operation == "get_keypad_draft_selection" {
                    current=try openPicker()
                    try verifyExpected(current)
                    guard let selected=Self.selection(current,models:models),let effort=selected.effort,
                          let position=selected.position,let count=selected.count else {
                        throw CodexClientError.unavailable("Native model and Power selection are unavailable.")
                    }
                    let confirmed=Self.settings(current,models:models)
                    after=try closePicker()
                    return ["verified":true,"selection":["model":selected.model,"effort":effort,"position":position,"count":count],
                            "state":project(after,models:models,confirmed:confirmed,verification:verification)]
                } else if operation == "toggle_keypad_draft_plan" {
                    // Plan does not require a resolved model or a Power value.
                    if let expected=(a["expected_settings"] as? [String:Any])?["collaborationMode"] as? NSDictionary,
                       expected != Self.settings(current,models:models)["collaborationMode"] as? NSDictionary { throw CodexClientError.staleTarget }
                    if let shortcut=try? io.shortcut("composer.togglePlanMode"),let editor=current.editor {
                        try focusedKey(shortcut,element:editor.element)
                    } else if current.plan,let button=current.unique(current.controls,matching:{$0.named(MacUISnapshot.planNames)}) {
                        try press(button)
                    } else {
                        guard let add=current.unique(current.controls,matching:{$0.enabled && $0.named(MacUISnapshot.addNames)}) else { throw CodexClientError.unavailable("Plan control is unavailable.") }
                        openedAdd=true; try press(add); current=try wait { !$0.composerMenuItems.isEmpty }
                        guard let plan=current.unique(current.composerMenuItems,matching:{ node in
                            current.strings(under:node.element).contains { text in MacUISnapshot.planMenuNames.contains { $0.caseInsensitiveCompare(text.trimmingCharacters(in:.whitespacesAndNewlines)) == .orderedSame } }
                        }) else { throw CodexClientError.unavailable("Plan is unavailable in the composer menu.") }
                        try press(plan)
                    }
                    after=try wait { $0.plan != before.plan && $0.menuItems.isEmpty && $0.composerMenuItems.isEmpty }
                } else if operation == "set_keypad_draft_fast" {
                    if Self.speed(current) == nil { current=try openPicker() }
                    guard let initial=Self.speed(current) else { throw CodexClientError.unavailable("Native speed is unavailable.") }
                    let toggle=a["toggle"] as? Bool == true
                    guard toggle || a["enabled"] is Bool else { throw CodexClientError.invalid("Missing Fast selection.") }
                    let desired=a["enabled"] as? Bool == true
                    if toggle || (initial != .standard) != desired {
                        if let shortcut=try? io.shortcut("composer.toggleFastMode") {
                            var previous=initial
                            for _ in 0..<3 {
                                if current.picker?.expanded == true { try key(shortcut) }
                                else if let editor=current.editor { try focusedKey(shortcut,element:editor.element) }
                                else { throw CodexClientError.staleTarget }
                                current=try wait { state in
                                    state.picker?.expanded != true || Self.speed(state).map { $0 != previous } == true
                                }
                                if Self.speed(current) == nil { current=try openPicker() }
                                current=try wait { Self.speed($0).map { $0 != previous } == true }
                                guard let value=Self.speed(current) else { throw CodexClientError.outcomeUnknown }
                                if toggle || (value != .standard) == desired { break }
                                guard value != initial else { throw CodexClientError.outcomeUnknown }
                                previous=value
                            }
                        } else {
                            current=try openPicker()
                            guard let speed=current.unique(current.menuItems+current.controls,matching: { node in
                                node.named(["Speed","速度"]) || ["Speed ","速度 "].contains(where:{node.name.hasPrefix($0)})
                            }) else { throw CodexClientError.unavailable("Native Speed menu is unavailable.") }
                            try press(speed); current=try wait { Self.speedChoices($0).count >= 2 }
                            let choices=Self.speedChoices(current)
                            guard let at=choices.firstIndex(where:{$0.1 == initial}) else { throw CodexClientError.staleTarget }
                            let next=toggle ? choices[(at+1)%choices.count] : choices.first(where: { ($0.1 != .standard) == desired })
                            guard let next else { throw CodexClientError.unavailable("Requested speed is unavailable.") }
                            try press(next.0)
                            current=try wait { $0.picker?.expanded != true || Self.speed($0) == next.1 }
                            if Self.speed(current) == nil { current=try openPicker() }
                        }
                        current=try wait { state in
                            guard let value=Self.speed(state) else { return false }
                            return toggle ? value != initial : (value != .standard) == desired
                        }
                    }
                    let confirmed=Self.settings(current,models:models)
                    after=try closePicker()
                    let actual=Self.settings(after,models:models)
                    guard actual.allSatisfy({ key,value in confirmed[key].map { (value as? NSObject)?.isEqual($0) == true } ?? true }) else { throw CodexClientError.outcomeUnknown }
                    return ["applied":true,"verified":true,"state":project(after,models:models,confirmed:confirmed,verification:verification)]
                } else {
                    // Match Windows: resolve the actual selection inside Power,
                    // including when the closed trigger exposes no model/effort.
                    current=try openPicker()
                    try verifyExpected(current)
                    var selected=Self.selection(current,models:models)
                    if let seedModel=a["seed_model"] as? String,let seedEffort=a["seed_effort"] as? String {
                        guard selected?.model == seedModel,selected?.effort == seedEffort else {throw CodexClientError.staleTarget}
                    }
                    var requestedModel=a["model"] as? String
                    var requestedEffort=a["effort"] as? String
                    if let quick=a["quick_models"] as? [[String:Any]] {
                        guard quick.count == 2,let initial=selected,let first=quick[0]["model"] as? String,let second=quick[1]["model"] as? String else { throw CodexClientError.invalid("Invalid Quick model profile.") }
                        let useSecond=initial.model == first && (first != second || initial.effort == quick[0]["effort"] as? String)
                        let preset=quick[useSecond ? 1:0]
                        requestedModel=preset["model"] as? String; requestedEffort=preset["effort"] as? String
                    }
                    if operation == "set_keypad_draft_model",let model=requestedModel {
                        guard let definition=models.first(where:{$0["model"] as? String == model && $0["hidden"] as? Bool != true}) else { throw CodexClientError.invalid("Model is unavailable.") }
                        if let requestedEffort {
                            guard (definition["supportedReasoningEfforts"] as? [[String:Any]] ?? []).contains(where:{$0["reasoningEffort"] as? String == requestedEffort}) else { throw CodexClientError.invalid("Unsupported native effort.") }
                        }
                        if selected?.model != model {
                            func modelRow(_ state:MacUISnapshot) -> AXNode? {
                                state.unique(state.menuItems) { node in
                                    NativeComposerSelection.parse(state.strings(under:node.element),models:models)?.model == model && !node.named(NativeComposerSelection.powerNames)
                                }
                            }
                            if modelRow(current) == nil {
                                guard let submenu=current.modelSubmenu else { throw CodexClientError.unavailable("The native model submenu is unavailable.") }
                                try press(submenu);current=try wait { modelRow($0) != nil }
                            }
                            guard let item=modelRow(current),!current.strings(under:item.element).contains(where: { text in
                                ["locked","opens access options","已锁定","已鎖定"].contains { text.localizedCaseInsensitiveContains($0) }
                            }) else { throw CodexClientError.unavailable("The requested model is unavailable or locked.") }
                            try press(item)
                            current=try wait { $0.picker?.expanded != true || Self.selection($0,models:models)?.model == model }
                            if current.picker?.expanded != true { current=try openPicker() }
                            current=try wait { Self.selection($0,models:models)?.model == model }
                            selected=Self.selection(current,models:models)
                        }
                    }
                    guard let initial=selected,let definition=models.first(where:{$0["model"] as? String == initial.model}) else { throw CodexClientError.unavailable("Native model selection is unavailable.") }
                    let efforts=(definition["supportedReasoningEfforts"] as? [[String:Any]] ?? []).compactMap {$0["reasoningEffort"] as? String}
                    var requested=requestedEffort
                    if let direction=a["direction"] as? Int {
                        guard [-1,1].contains(direction),let effort=initial.effort,let at=efforts.firstIndex(of:effort),!efforts.isEmpty else { throw CodexClientError.unavailable("Native effort is unavailable.") }
                        requested=efforts[max(0,min(efforts.count-1,at+direction))]
                    }
                    if let requested,initial.effort != requested {
                        guard efforts.contains(requested) else { throw CodexClientError.invalid("Unsupported native effort.") }
                        if a["seed_model"] == nil,let slider=current.powerSlider,slider.valueSettable,
                           let value=NativeComposerSelection.sliderValue(selection:initial,effort:requested,models:models,minimum:slider.minimum,maximum:slider.maximum) {
                            _=try fresh();mutated=true;try io.set(slider.element,"AXValue",NSNumber(value:value))
                            current=try wait {Self.selection($0,models:models)?.effort == requested}
                        } else {
                            // The verified blank-draft transaction never trusts
                            // AXValue: it can move the accessibility proxy without
                            // invoking the renderer's setting callback.
                            for _ in 0..<efforts.count {
                                guard let value=Self.selection(current,models:models),value.model == initial.model,
                                      let effort=value.effort,let at=efforts.firstIndex(of:effort),let to=efforts.firstIndex(of:requested) else { throw CodexClientError.staleTarget }
                                if at == to { break }
                                guard value.position == at+1,value.count == efforts.count,
                                      let power=current.unique(current.menuItems,matching:{$0.named(NativeComposerSelection.powerNames)}) else { throw CodexClientError.unavailable("Native Power control is unavailable.") }
                                try focusedKey(.init(key:at < to ? 124:123,flags:[]),element:power.element)
                                current=try wait { Self.selection($0,models:models)?.effort == efforts[at+(at < to ? 1:-1)] }
                            }
                        }
                        guard let value=Self.selection(current,models:models),value.model == initial.model,value.effort == requested else { throw CodexClientError.outcomeUnknown }
                    }
                    let confirmed=Self.settings(current,models:models)
                    after=try closePicker()
                    // Keep the menu's verified result when the closed trigger
                    // omits it; a subsequent action opens and rechecks Power.
                    let actual=Self.settings(after,models:models)
                    guard actual.allSatisfy({ key,value in confirmed[key].map { (value as? NSObject)?.isEqual($0) == true } ?? true }) else { throw CodexClientError.outcomeUnknown }
                    return ["applied":true,"verified":true,"state":project(after,models:models,confirmed:confirmed,verification:verification)]
                }
            default: throw CodexClientError.unsupported("Unsupported native operation.")
            }
            return ["applied": true, "verified": true, "state": project(after, models: models,verification:verification)]
        } catch {
            lease = nil
            Self.logger.error("Native operation \(operation, privacy: .public), input attempted \(mutated, privacy: .public): \(error.localizedDescription, privacy: .private)")
            if mutated { throw CodexClientError.outcomeUnknown }
            throw error
        }
    }

    static func prefix(_ title: String, _ model: String) -> Bool {
        let title=title.lowercased(), model=model.lowercased()
        return title == model || title.hasPrefix(model + " ") || title.hasPrefix(model + " ·") || title.hasPrefix(model + "\n")
    }
    static func modelLabels(_ model: [String:Any]) -> [String] { NativeComposerSelection.labels(model) }
    static func selection(_ snapshot:MacUISnapshot, models:[[String:Any]]) -> NativeComposerSelection.Selection? {
        // While Power is open its live announcement owns model/effort state.
        // Do not fall back to the stale trigger when Power is ambiguous.
        if !snapshot.powerTexts.isEmpty { return NativeComposerSelection.power(snapshot.powerTexts,models:models) }
        guard let picker=snapshot.picker else { return nil }
        if let menu=snapshot.modelMenu {
            let selected=snapshot.nodes.indices.filter { snapshot.nodes[$0].selected && MacUISnapshot.within($0,ancestor:menu,nodes:snapshot.nodes) }
            let values=selected.compactMap { NativeComposerSelection.parse(snapshot.strings(under:snapshot.nodes[$0].element),models:models) }
            if let first=values.first { return values.allSatisfy({$0 == first}) ? first : nil }
        }
        return NativeComposerSelection.parse(snapshot.strings(under:picker.element),models:models)
    }
    static func settings(_ snapshot: MacUISnapshot, models: [[String: Any]]) -> [String: Any] {
        var result:[String:Any]=["collaborationMode":["mode":snapshot.plan ? "plan":"default"]]
        if let value=selection(snapshot,models:models) {
            result["model"]=value.model
            if let effort=value.effort { result["effort"]=effort }
        }
        if let speed=speed(snapshot) { result["serviceTier"]=speed == .standard ? NSNull() as Any : "fast"; result["nativeSpeed"]=speed.rawValue }
        return result
    }
    static func speed(_ snapshot:MacUISnapshot) -> NativeComposerSelection.Speed? {
        let nodes=(snapshot.controls+snapshot.menuItems).map { snapshot.nodes[$0] }
        let toggles=nodes.filter { $0.named(["Enable standard mode","启用标准模式","啟用標準模式","Enable fast mode","启用快速模式","啟用快速模式"]) }
        let titles=nodes.filter { node in
            let first=node.name.components(separatedBy:.whitespacesAndNewlines.union(CharacterSet(charactersIn:"·:："))).first?.lowercased()
            return first == "speed" || first == "速度" || MacAX.same(node.element,snapshot.picker?.element)
        }.flatMap { snapshot.strings(under:$0.element) }
        let selected=speedChoices(snapshot).filter { $0.0.selected }
        if selected.count > 1 { return nil }
        if selected.count == 1 { return selected[0].1 }
        if let explicit=NativeComposerSelection.speed(titles) { return explicit }
        guard toggles.count == 1, let toggle=toggles.first else { return nil }
        return toggle.named(["Enable fast mode","启用快速模式","啟用快速模式"]) ? .standard : .fast
    }
    static func speedChoices(_ snapshot:MacUISnapshot) -> [(AXNode,NativeComposerSelection.Speed)] {
        snapshot.menuItems.compactMap { index in
            let node=snapshot.nodes[index]
            guard ["AXRadioButton","AXMenuItem","AXCheckBox"].contains(node.role) else { return nil }
            let names=["standard","fast","ultrafast","标准","標準","快速","超快","极速","極速"]
            // Speed's trigger contains its current value as a descendant. It
            // is not a selectable speed row and must not enter the cycle.
            guard node.named(names) || ["AXRadioButton","AXCheckBox"].contains(node.role) else { return nil }
            let labels=snapshot.strings(under:node.element).filter { names.contains($0.lowercased()) }
            return NativeComposerSelection.speed(labels).map { (node,$0) }
        }
    }
    static func fastValue(_ snapshot:MacUISnapshot) -> Bool? { speed(snapshot).map { $0 != .standard } }
    static func speedValue(_ title:String) -> Bool? { NativeComposerSelection.speed([title]).map { $0 != .standard } }
}
