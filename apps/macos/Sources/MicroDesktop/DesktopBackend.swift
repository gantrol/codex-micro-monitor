import AppKit
import MicroCore
import MicroShared

protocol DesktopCoreAccess:Sendable {
    func execute(_ operation:String,arguments:[String:Any]) async throws -> [String:Any]
    func captureDraftConfiguration() async throws -> DraftConfigurationSnapshot?
    func readDraftConfiguration() async throws -> DraftConfigurationSnapshot?
    func writeDraftConfiguration(_ snapshot:DraftConfigurationSnapshot) async throws
    func invalidateUserSavedConfig() async throws -> Bool
    func close() async
}
extension DesktopCoreAccess {
    func captureDraftConfiguration() async throws -> DraftConfigurationSnapshot? { nil }
    func readDraftConfiguration() async throws -> DraftConfigurationSnapshot? { nil }
    func writeDraftConfiguration(_ snapshot:DraftConfigurationSnapshot) async throws {}
    func invalidateUserSavedConfig() async throws -> Bool { false }
}
extension CodexClient:DesktopCoreAccess {}

/// One dispatch contract for Catalyst and the plugin's native MCP process.
actor DesktopBackend {
    private let core:any DesktopCoreAccess
    private let ui:MacUIController
    private var models: [[String: Any]] = []
    private var mutating = false
    private var rosterIdentity:(scope:String,context:String)?
    private var rosterRevision=0
    init(core:any DesktopCoreAccess=CodexClient(),ui:MacUIController=MacUIController()) {
        self.core=core;self.ui=ui
    }

    static func acceptsNativeSettings(_ state: [String: Any], arguments: [String: Any]) -> Bool {
        guard state["available"] as? Bool == true, let token=state["targetToken"] as? String,
              token == arguments["target_token"] as? String else { return false }
        if arguments["native_composer"] as? Bool == true {
            return NativeComposerIdentity.settingsOnly(state)
        }
        return state["draft"] as? Bool == true
    }

    func close() async { ui.close(); models = [];rosterIdentity=nil;rosterRevision += 1; await core.close() }

    private func observeNative() async throws -> (state:[String:Any],verification:VerifiedClientRoute?) {
        var state=try await ui.execute("get_keypad_ui_state",arguments:[:],models:models)
        if state["draft"] as? Bool == true {
            var settings = state["settings"] as? [String: Any] ?? [:]
            if (settings["model"] == nil || settings["effort"] == nil),
               let config = try? await core.readDraftConfiguration() {
                if settings["model"] == nil, let model = config.model, !model.isEmpty {
                    settings["model"] = model
                }
                if settings["effort"] == nil, let effort = config.effort, !effort.isEmpty {
                    settings["effort"] = effort
                }
                state["settings"] = settings
            }
        }
        guard let raw=state["clientBindingCandidate"] as? [String:Any],let pair=ClientRoutePair(raw),
              let token=state["bindingObservationToken"] as? String else {return (state,nil)}
        guard let identity=rosterIdentity else {await ui.discardBinding(observationToken:token);return (state,nil)}
        let revision=rosterRevision
        do {
            let result=try await core.execute("get_keypad_client_thread",arguments:["client_thread_id":pair.clientThreadID,"roster_scope":identity.scope])
            try Task.checkCancellation()
            guard revision == rosterRevision,identity.scope == rosterIdentity?.scope,identity.context == rosterIdentity?.context,
                  result["resolved"] as? Bool == true,result["clientThreadId"] as? String == pair.clientThreadID,
                  result["threadId"] as? String == pair.threadID,(result["thread"] as? [String:Any])?["id"] as? String == pair.threadID,
                  result["rosterScope"] as? String == identity.scope,result["contextID"] as? String == identity.context else {throw CodexClientError.staleTarget}
            let verification=VerifiedClientRoute(pair:pair,scope:identity.scope,context:identity.context)
            let confirmed=try await ui.confirmBinding(verification,observationToken:token,models:models)
            guard revision == rosterRevision else {throw CodexClientError.staleTarget}
            return (confirmed,verification)
        } catch {
            await ui.discardBinding(observationToken:token)
            try Task.checkCancellation()
            return (state,nil)
        }
    }

    /// Blank new conversations (`draft == true`) on macOS bind their model and
    /// reasoning effort directly to `user-saved-config` (`config.toml`).
    /// Updating `config.toml` and broadcasting `query-cache-invalidate` for
    /// `["user-saved-config"]` directly updates the draft composer on screen
    /// without popping open or stepping the native UI Power picker control.
    private func directDraftConfigurationChange(
        _ operation:String,
        arguments:[String:Any],
        observed:[String:Any],
        verification:VerifiedClientRoute?
    ) async throws -> [String:Any]? {
        guard ["set_keypad_draft_model","set_keypad_draft_reasoning"].contains(operation),
              arguments["native_composer"] as? Bool != true,
              observed["draft"] as? Bool == true else {return nil}
        guard let previous = try await core.captureDraftConfiguration() else {return nil}
        guard let token = arguments["target_token"] as? String else {throw CodexClientError.staleTarget}
        let observedSettings = observed["settings"] as? [String:Any] ?? [:]
        if let expected = arguments["expected_settings"] as? [String:Any] {
            for (name, value) in expected where !(value is NSNull) {
                let candidate: Any? = observedSettings[name] ?? (name == "model" ? previous.model : name == "effort" ? previous.effort : nil)
                guard let actual = candidate as? NSObject, actual.isEqual(value) else {
                    throw CodexClientError.staleTarget
                }
            }
        }
        let candidateModel = (observedSettings["model"] as? String) ?? previous.model ??
            (models.first(where: { $0["hidden"] as? Bool != true })?["model"] as? String)
        guard let initialModel = candidateModel,
              let initialDefinition = models.first(where: { $0["model"] as? String == initialModel && $0["hidden"] as? Bool != true }) else {
            throw CodexClientError.unavailable("Draft model configuration is unavailable.")
        }
        let initialEfforts = (initialDefinition["supportedReasoningEfforts"] as? [[String:Any]] ?? [])
            .compactMap { $0["reasoningEffort"] as? String }
        let candidateEffort = (observedSettings["effort"] as? String) ?? previous.effort ??
            (initialDefinition["defaultReasoningEffort"] as? String) ?? initialEfforts.first
        guard let initialEffort = candidateEffort, !initialEffort.isEmpty else {
            throw CodexClientError.unavailable("Draft reasoning effort configuration is unavailable.")
        }

        var requestedModel = arguments["model"] as? String
        var requestedEffort = arguments["effort"] as? String
        if let quick = arguments["quick_models"] as? [[String:Any]] {
            guard quick.count == 2,
                  let first = quick[0]["model"] as? String,
                  let second = quick[1]["model"] as? String else {
                throw CodexClientError.invalid("Invalid Quick model profile.")
            }
            let useSecond = initialModel == first && (first != second || initialEffort == quick[0]["effort"] as? String)
            let preset = quick[useSecond ? 1 : 0]
            requestedModel = preset["model"] as? String
            requestedEffort = preset["effort"] as? String
        }
        let targetModel: String
        if operation == "set_keypad_draft_model" {
            guard let model = requestedModel else {throw CodexClientError.invalid("Missing model selection.")}
            targetModel = model
        } else {
            targetModel = initialModel
        }
        guard let targetDefinition = models.first(where: { $0["model"] as? String == targetModel && $0["hidden"] as? Bool != true }) else {
            throw CodexClientError.invalid("Model is not in the current catalog.")
        }
        let targetEfforts = (targetDefinition["supportedReasoningEfforts"] as? [[String:Any]] ?? [])
            .compactMap { $0["reasoningEffort"] as? String }
        guard !targetEfforts.isEmpty else {
            throw CodexClientError.unavailable("Native effort is unavailable.")
        }
        let targetEffort: String
        if let direction = arguments["direction"] as? Int {
            guard [-1, 1].contains(direction), let at = targetEfforts.firstIndex(of: initialEffort) else {
                throw CodexClientError.unavailable("Native effort is unavailable.")
            }
            targetEffort = targetEfforts[max(0, min(targetEfforts.count - 1, at + direction))]
        } else if let requestedEffort {
            guard targetEfforts.contains(requestedEffort) else {
                throw CodexClientError.invalid("Unsupported reasoning effort.")
            }
            targetEffort = requestedEffort
        } else if targetModel == initialModel, targetEfforts.contains(initialEffort) {
            targetEffort = initialEffort
        } else if let defaultEffort = targetDefinition["defaultReasoningEffort"] as? String,
                  targetEfforts.contains(defaultEffort) {
            targetEffort = defaultEffort
        } else {
            targetEffort = targetEfforts[0]
        }

        if let deadline = arguments["input_deadline_uptime"] as? Double {
            guard deadline.isFinite, ProcessInfo.processInfo.systemUptime <= deadline else {
                throw CodexClientError.staleTarget
            }
        }
        let confirmedSettings: [String: Any] = ["model": targetModel, "effort": targetEffort]
        if initialModel == targetModel && initialEffort == targetEffort &&
            previous.model == targetModel && previous.effort == targetEffort {
            let refreshed = try await ui.execute(
                "refresh_keypad_draft_target",
                arguments: ["target_token": token, "confirmed_settings": confirmedSettings],
                models: models,
                verification: verification
            )
            guard let state = refreshed["state"] as? [String: Any] else {
                throw CodexClientError.outcomeUnknown
            }
            var response: [String: Any] = ["applied": false, "verified": true, "state": state]
            if operation == "set_keypad_draft_reasoning", arguments["direction"] != nil {
                response["boundaryReached"] = true
            }
            return response
        }

        var refreshArgs: [String: Any] = ["target_token": token]
        if let deadline = arguments["input_deadline_uptime"] as? Double {
            refreshArgs["input_deadline_uptime"] = deadline
        }
        let precheck = try await ui.execute("refresh_keypad_draft_target", arguments: refreshArgs, models: models, verification: verification)
        guard let precheckState = precheck["state"] as? [String: Any],
              let activeToken = precheckState["targetToken"] as? String else {
            throw CodexClientError.staleTarget
        }

        let target = DraftConfigurationSnapshot(model: targetModel, effort: targetEffort, encoderMode: previous.encoderMode)
        try await core.writeDraftConfiguration(target)
        guard try await core.invalidateUserSavedConfig() else {
            throw CodexClientError.outcomeUnknown
        }
        let refreshed = try await ui.execute(
            "refresh_keypad_draft_target",
            arguments: ["target_token": activeToken, "confirmed_settings": confirmedSettings],
            models: models,
            verification: verification
        )
        guard let finalState = refreshed["state"] as? [String: Any] else {
            throw CodexClientError.outcomeUnknown
        }
        return [
            "applied": true,
            "verified": true,
            "rendererVerified": true,
            "verificationSource": "direct-draft-config",
            "state": finalState
        ]
    }

    func execute(_ operation: String, arguments: [String: Any]) async throws -> [String: Any] {
        // Recovery changes only application focus. It must remain reachable
        // while a service request is waiting; native writes still revalidate
        // their own exact window before every effect.
        if operation == "activate_keypad_app" { return try await CodexApplication.activate() }
        let isRead = operation.hasPrefix("get_") || operation.hasPrefix("list_")
        if !isRead {
            guard !mutating else { throw CodexClientError.unavailable("A control action is already in progress.") }
            mutating = true
        }
        defer { if !isRead { mutating = false } }
        if var page = ["open_keypad_settings":WorkspaceActions.CodexPage.settings,"open_keypad_skills":.skills,"open_keypad_tasks":.automations][operation] {
            if operation == "open_keypad_settings",let section=arguments["section"] {
                guard section as? String == "codex-micro" else { throw CodexClientError.invalid("Unsupported settings section.") }
                page = .microSettings
            }
            return try await WorkspaceActions.codexPage(page,open:{ url in
                try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
                    Task { @MainActor in
                        guard !Task.isCancelled else { continuation.resume(throwing:CancellationError());return }
                        guard let app=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.openai.codex") else {
                            continuation.resume(throwing:CodexClientError.unavailable("The Codex desktop app is unavailable."));return
                        }
                        let configuration=NSWorkspace.OpenConfiguration();configuration.activates=true
                        NSWorkspace.shared.open([url],withApplicationAt:app,configuration:configuration) { _,error in
                            if let error { continuation.resume(throwing:error) } else { continuation.resume() }
                        }
                    }
                }
            },observe:{ try await self.ui.execute("get_keypad_ui_state",arguments:[:],models:self.models) })
        }
        if operation == "open_keypad_developer_site" {
            try Task.checkCancellation()
            return try await MainActor.run {
                try Task.checkCancellation()
                return try WorkspaceActions.developerSite { NSWorkspace.shared.open($0) }
            }
        }
        if operation == "open_keypad_folder" {
            let folder = try await core.execute("get_keypad_folder",arguments:arguments)
            guard let cwd=folder["cwd"] as? String else { throw CodexClientError.staleTarget }
            try Task.checkCancellation()
            return try await MainActor.run {
                try Task.checkCancellation()
                return try WorkspaceActions.folder(cwd) { NSWorkspace.shared.selectFile(nil,inFileViewerRootedAtPath:$0.path) }
            }
        }
        if operation == "get_keypad_capabilities" {
            var result = try await core.execute(operation, arguments: arguments)
            result["accessibility"] = AXIsProcessTrusted()
            result["nativeUIOperations"] = Array(MacUIController.operations).sorted()
            return result
        }
        if operation == "get_keypad_ui_state" {return try await observeNative().state}
        if MacUIController.operations.contains(operation) {
            var nativeArguments = arguments
            var verification:VerifiedClientRoute?
            if operation == "navigate_keypad_ui" {
                let observation=try await observeNative()
                guard observation.state["targetToken"] as? String == arguments["target_token"] as? String else {throw CodexClientError.staleTarget}
                verification=observation.verification
            }
            if operation == "archive_keypad_thread" {
                guard let id=arguments["thread_id"] as? String else { throw CodexClientError.invalid("Missing exact chat ID.") }
                let state=try await core.execute("get_keypad_archive_state",arguments:["thread_id":id])
                guard state["archived"] as? Bool != true else { throw CodexClientError.staleTarget }
            }
            if operation.hasPrefix("set_keypad_draft_") || operation == "toggle_keypad_draft_plan" {
                do {
                    models = try await core.execute("get_keypad_models", arguments: [:])["data"] as? [[String: Any]] ?? []
                } catch {
                    models = []
                    throw error
                }
                let observation=try await observeNative(),observed=observation.state
                verification=observation.verification
                guard Self.acceptsNativeSettings(observed, arguments: arguments) else { throw CodexClientError.staleTarget }
                let settings = observed["settings"] as? [String: Any] ?? [:]
                let id = arguments["model"] as? String ?? settings["model"] as? String
                let model = models.first(where: { $0["model"] as? String == id && $0["hidden"] as? Bool != true })
                if arguments["model"] is String, model == nil { throw CodexClientError.invalid("Model is not in the current catalog.") }
                if let model, let effort = arguments["effort"] as? String {
                    guard (model["supportedReasoningEfforts"] as? [[String: Any]] ?? []).contains(where: { $0["reasoningEffort"] as? String == effort }) else { throw CodexClientError.invalid("Unsupported reasoning effort.") }
                }
                if let model, operation == "set_keypad_draft_fast", arguments["enabled"] as? Bool == true {
                    let tiers = model["serviceTiers"] as? [[String: Any]] ?? []
                    guard tiers.contains(where: { ["fast", "priority"].contains($0["id"] as? String ?? "") }) || (model["additionalSpeedTiers"] as? [String] ?? []).contains("fast") else { throw CodexClientError.invalid("Fast is unavailable for this model.") }
                }
                if let direct = try await directDraftConfigurationChange(operation, arguments: nativeArguments, observed: observed, verification: verification) {
                    return direct
                }
            }
            if operation == "submit_keypad_composer" {
                let state = try await ui.execute("get_keypad_ui_state", arguments: [:], models: models)
                guard state["targetToken"] as? String == arguments["target_token"] as? String else { throw CodexClientError.staleTarget }
                if state["foreground"] as? Bool == false {
                    // A background press only activates; composer readiness is
                    // checked on the later explicit foreground submission.
                    nativeArguments["activation_only"] = true
                } else if let id = state["threadId"] as? String {
                    let current = try await core.execute("get_keypad_state", arguments: ["thread_id": id])
                    guard current["canSubmit"] as? Bool == true else { throw CodexClientError.unavailable("The exact chat must be idle with no unconfirmed submission before submitting its composer.") }
                } else if state["draft"] as? Bool != true { throw CodexClientError.staleTarget }
            }
            let result=try await ui.execute(operation, arguments: nativeArguments, models: models,verification:verification)
            if operation == "archive_keypad_thread" {
                return try await NativeThreadMenu.confirmArchive(result,observe:{ id in try await self.core.execute("get_keypad_archive_state",arguments:["thread_id":id]) })
            }
            return result
        }
        var requestedRosterRevision:Int?
        if operation == "list_keypad_threads" {rosterIdentity=nil;rosterRevision += 1;requestedRosterRevision=rosterRevision}
        let resultRead: [String: Any]
        do {
            resultRead = try await core.execute(operation, arguments: arguments)
        } catch {
            if operation == "get_keypad_models" { models = [] }
            throw error
        }
        var result = resultRead
        if operation == "list_keypad_threads",requestedRosterRevision == rosterRevision,let scope=result["rosterScope"] as? String,scope.count == 64,
           scope.allSatisfy({"0123456789abcdef".contains($0)}),let context=result["contextID"] as? String,!context.isEmpty {
            rosterIdentity=(scope,context)
        }
        if operation == "get_keypad_models" { models = result["data"] as? [[String: Any]] ?? [] }
        if ["new_keypad_thread", "open_keypad_thread", "open_keypad_review", "fork_keypad_thread"].contains(operation), result["launch_requested"] as? Bool == true {
            // A deep link acknowledgment is distinct from observing its route.
            let id = result["threadId"] as? String
            do {
                for attempt in 0..<8 {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(attempt == 0 ? 60 : 80))
                    let state = try await ui.execute("get_keypad_ui_state", arguments: [:], models: models)
                    result["foreground"] = state
                    if operation == "new_keypad_thread" ? state["draft"] as? Bool == true : state["threadId"] as? String == id && id != nil {
                        result["navigation_verified"] = operation != "open_keypad_review" || state["reviewOpen"] as? Bool == true
                        result["foreground"] = state
                        if result["navigation_verified"] as? Bool == true { break }
                    }
                    result["followupError"] = state["reason"] as? String
                    // Permission denial is not a slow navigation. Preserve its
                    // cause and let the ordinary foreground observer recover later.
                    if state["accessibility"] as? Bool == false {break}
                }
            } catch { result["followupError"] = error.localizedDescription }
            if result["navigation_verified"] as? Bool == true {result["followupError"]=nil}
        }
        return result
    }
}
