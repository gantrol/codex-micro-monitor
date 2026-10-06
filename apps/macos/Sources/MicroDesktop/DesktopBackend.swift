import AppKit
import MicroCore
import MicroShared

protocol DesktopCoreAccess:Sendable {
    func execute(_ operation:String,arguments:[String:Any]) async throws -> [String:Any]
    func captureDraftConfiguration() async throws -> DraftConfigurationSnapshot?
    func readDraftConfiguration() async throws -> DraftConfigurationSnapshot
    func writeDraftConfiguration(_ value:DraftConfigurationSnapshot) async throws -> Bool
    func invalidateUserSavedConfig() async throws -> Bool
    func close() async
}
extension DesktopCoreAccess {
    func captureDraftConfiguration() async throws -> DraftConfigurationSnapshot? { nil }
    func readDraftConfiguration() async throws -> DraftConfigurationSnapshot { throw CodexClientError.unsupported("Draft configuration observation is unavailable.") }
    func writeDraftConfiguration(_ value:DraftConfigurationSnapshot) async throws -> Bool { false }
    func invalidateUserSavedConfig() async throws -> Bool { false }
}
extension CodexClient:DesktopCoreAccess {}

/// One dispatch contract for Catalyst and the plugin's native MCP process.
actor DesktopBackend {
    private struct DraftSelection {
        let model:String
        let effort:String
        let position:Int
        let count:Int
    }

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

    private func draftSelection(_ result:[String:Any]) throws -> (DraftSelection,[String:Any]) {
        guard result["verified"] as? Bool == true,
              let raw=result["selection"] as? [String:Any],let model=raw["model"] as? String,
              let effort=raw["effort"] as? String,let position=raw["position"] as? Int,
              let count=raw["count"] as? Int,position > 0,count > 0,position <= count,
              let state=result["state"] as? [String:Any],state["targetToken"] as? String != nil else {
            throw CodexClientError.outcomeUnknown
        }
        return (.init(model:model,effort:effort,position:position,count:count),state)
    }

    private func inspectDraft(arguments:[String:Any],verification:VerifiedClientRoute?) async throws -> (DraftSelection,[String:Any]) {
        guard let token=arguments["target_token"] as? String else {throw CodexClientError.staleTarget}
        var input:[String:Any]=["target_token":token,"native_composer":arguments["native_composer"] as? Bool == true]
        if let expected=arguments["expected_settings"] {input["expected_settings"]=expected}
        if let deadline=arguments["input_deadline_uptime"] {input["input_deadline_uptime"]=deadline}
        return try draftSelection(await ui.execute("get_keypad_draft_selection",arguments:input,models:models,verification:verification))
    }

    private func refreshDraft(_ state:[String:Any],nativeComposer:Bool,verification:VerifiedClientRoute?) async throws -> [String:Any] {
        guard let token=state["targetToken"] as? String else {throw CodexClientError.staleTarget}
        let result=try await ui.execute("refresh_keypad_draft_target",arguments:["target_token":token,"native_composer":nativeComposer],models:models,verification:verification)
        guard result["verified"] as? Bool == true,let next=result["state"] as? [String:Any],next["targetToken"] as? String != nil else {
            throw CodexClientError.outcomeUnknown
        }
        return next
    }

    private func waitForDraftConfiguration(model:String,effort:String) async throws -> DraftConfigurationSnapshot {
        let end=ProcessInfo.processInfo.systemUptime+4
        var last:DraftConfigurationSnapshot?
        repeat {
            try Task.checkCancellation()
            last=try await core.readDraftConfiguration()
            if last?.model == model,last?.effort == effort {return last!}
            try await Task.sleep(for:.milliseconds(100))
        } while ProcessInfo.processInfo.systemUptime < end
        throw CodexClientError.outcomeUnknown
    }

    private func verifiedDraftConfigurationChange(_ operation:String,arguments:[String:Any],observed:[String:Any],verification:VerifiedClientRoute?) async throws -> [String:Any]? {
        // The App Server has no semantic owner for an unsent blank draft. Use
        // its official config writer as a seed, then require the foreground
        // renderer's own Power callback to persist an independently observed
        // transition before reporting success.
        guard ["set_keypad_draft_model","set_keypad_draft_reasoning"].contains(operation),
              arguments["native_composer"] as? Bool != true,observed["draft"] as? Bool == true else {return nil}

        guard let previous=try await core.captureDraftConfiguration() else {return nil}
        let (initial,inspectedState)=try await inspectDraft(arguments:arguments,verification:verification)

        var targetModel=initial.model
        var requestedEffort=arguments["effort"] as? String
        if operation == "set_keypad_draft_model" {
            if let quick=arguments["quick_models"] as? [[String:Any]] {
                guard quick.count == 2,let first=quick[0]["model"] as? String,let second=quick[1]["model"] as? String else {
                    throw CodexClientError.invalid("Invalid Quick model profile.")
                }
                let useSecond=initial.model == first && (first != second || initial.effort == quick[0]["effort"] as? String)
                let preset=quick[useSecond ? 1:0]
                guard let model=preset["model"] as? String else {throw CodexClientError.invalid("Invalid Quick model profile.")}
                targetModel=model;requestedEffort=preset["effort"] as? String
            } else {
                guard let model=arguments["model"] as? String else {throw CodexClientError.invalid("Missing model selection.")}
                targetModel=model
            }
        }
        guard let definition=models.first(where:{$0["model"] as? String == targetModel && $0["hidden"] as? Bool != true}) else {
            throw CodexClientError.invalid("Model is unavailable.")
        }
        let efforts=(definition["supportedReasoningEfforts"] as? [[String:Any]] ?? []).compactMap {$0["reasoningEffort"] as? String}
        guard Set(efforts).count == efforts.count,!efforts.isEmpty else {throw CodexClientError.unavailable("Native effort catalog is unavailable.")}
        if operation == "set_keypad_draft_reasoning",let direction=arguments["direction"] as? Int {
            guard [-1,1].contains(direction),targetModel == initial.model,let at=efforts.firstIndex(of:initial.effort) else {
                throw CodexClientError.staleTarget
            }
            requestedEffort=efforts[max(0,min(efforts.count-1,at+direction))]
        }
        let targetEffort=requestedEffort ?? (targetModel == initial.model && efforts.contains(initial.effort) ? initial.effort:definition["defaultReasoningEffort"] as? String)
        guard let targetEffort,let targetIndex=efforts.firstIndex(of:targetEffort) else {
            throw CodexClientError.invalid("Unsupported native effort.")
        }

        if initial.model == targetModel,initial.effort == targetEffort,
           previous.model == targetModel,previous.effort == targetEffort {
            var result:[String:Any]=["applied":false,"verified":true,"state":inspectedState]
            result["rendererVerified"]=true;result["verificationSource"]="native-menu-and-config-match"
            return result
        }
        guard efforts.count > 1 else {throw CodexClientError.unavailable("This model has no independent Power transition to verify.")}

        let seedEffort:String
        let probeEffort:String
        let nativeFinalEffort:String?
        if targetIndex == 0 {
            guard efforts[1] != "ultra" else {throw CodexClientError.unavailable("This Power range cannot be changed without a user confirmation.")}
            seedEffort=efforts[1];probeEffort=targetEffort;nativeFinalEffort=nil
        } else {
            seedEffort=targetEffort;probeEffort=efforts[targetIndex-1]
            nativeFinalEffort=["max","ultra"].contains(targetEffort) ? nil:targetEffort
        }

        // Unlike Windows HID, macOS can address the focused Power item
        // directly, so keep the user's encoder mode unchanged throughout.
        let seed=DraftConfigurationSnapshot(model:targetModel,effort:seedEffort,encoderMode:previous.encoderMode)
        var ownedConfiguration:DraftConfigurationSnapshot?
        var nativeMutationConfirmed=false
        var nativeInputAttempted=false
        do {
            ownedConfiguration=seed
            guard try await core.writeDraftConfiguration(seed) else {return nil}
            guard try await core.invalidateUserSavedConfig() else {throw CodexClientError.outcomeUnknown}
            var state=try await refreshDraft(inspectedState,nativeComposer:false,verification:verification)
            guard let token=state["targetToken"] as? String else {throw CodexClientError.staleTarget}
            nativeInputAttempted=true
            let probe=try await ui.execute("set_keypad_draft_reasoning",arguments:[
                "target_token":token,"native_composer":false,"model":targetModel,"effort":probeEffort,
                "seed_model":targetModel,"seed_effort":seedEffort
            ],models:models,verification:verification)
            guard probe["verified"] as? Bool == true,let probeState=probe["state"] as? [String:Any] else {throw CodexClientError.outcomeUnknown}
            let observedProbe=try await waitForDraftConfiguration(model:targetModel,effort:probeEffort)
            ownedConfiguration=observedProbe;nativeMutationConfirmed=true;state=probeState

            if let nativeFinalEffort {
                guard let finalToken=state["targetToken"] as? String else {throw CodexClientError.staleTarget}
                let final=try await ui.execute("set_keypad_draft_reasoning",arguments:[
                    "target_token":finalToken,"native_composer":false,"model":targetModel,"effort":nativeFinalEffort,
                    "seed_model":targetModel,"seed_effort":probeEffort
                ],models:models,verification:verification)
                guard final["verified"] as? Bool == true,let finalState=final["state"] as? [String:Any] else {throw CodexClientError.outcomeUnknown}
                ownedConfiguration=try await waitForDraftConfiguration(model:targetModel,effort:targetEffort)
                state=finalState
            }

            let target=DraftConfigurationSnapshot(model:targetModel,effort:targetEffort,encoderMode:previous.encoderMode)
            guard try await core.writeDraftConfiguration(target) else {throw CodexClientError.outcomeUnknown}
            ownedConfiguration=target
            guard try await core.invalidateUserSavedConfig() else {throw CodexClientError.outcomeUnknown}
            state=try await refreshDraft(state,nativeComposer:false,verification:verification)
            guard let inspectedToken=state["targetToken"] as? String else {throw CodexClientError.staleTarget}
            let (confirmed,finalState)=try await inspectDraft(arguments:["target_token":inspectedToken,"native_composer":false],verification:verification)
            guard confirmed.model == targetModel,confirmed.effort == targetEffort,
                  try await core.readDraftConfiguration() == target else {throw CodexClientError.outcomeUnknown}
            var result:[String:Any]=["applied":true,"verified":true,"state":finalState]
            result["rendererVerified"]=true;result["verificationSource"]="native-config-roundtrip"
            return result
        } catch {
            let current=try? await core.readDraftConfiguration()
            if !nativeInputAttempted,!nativeMutationConfirmed,current == ownedConfiguration {
                _=try? await core.writeDraftConfiguration(previous)
                _=try? await core.invalidateUserSavedConfig()
            }
            if nativeInputAttempted || nativeMutationConfirmed {throw CodexClientError.outcomeUnknown}
            throw error
        }
    }

    private func observeNative() async throws -> (state:[String:Any],verification:VerifiedClientRoute?) {
        let state=try await ui.execute("get_keypad_ui_state",arguments:[:],models:models)
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
                models = []
                models = try await core.execute("get_keypad_models", arguments: [:])["data"] as? [[String: Any]] ?? []
                let observation=try await observeNative(),observed=observation.state
                verification=observation.verification
                guard Self.acceptsNativeSettings(observed, arguments: arguments) else { throw CodexClientError.staleTarget }
                let settings = observed["settings"] as? [String: Any] ?? [:]
                let id = arguments["model"] as? String ?? settings["model"] as? String
                let model = models.first(where: { $0["model"] as? String == id && $0["hidden"] as? Bool != true })
                if arguments["model"] is String, model == nil { throw CodexClientError.invalid("Model is not in the current catalog.") }
                // Generic closed triggers expose no model. The native controller
                // resolves and validates the open menu before changing settings.
                if let model, let effort = arguments["effort"] as? String {
                    guard (model["supportedReasoningEfforts"] as? [[String: Any]] ?? []).contains(where: { $0["reasoningEffort"] as? String == effort }) else { throw CodexClientError.invalid("Unsupported reasoning effort.") }
                }
                if let model, operation == "set_keypad_draft_fast", arguments["enabled"] as? Bool == true {
                    let tiers = model["serviceTiers"] as? [[String: Any]] ?? []
                    guard tiers.contains(where: { ["fast", "priority"].contains($0["id"] as? String ?? "") }) || (model["additionalSpeedTiers"] as? [String] ?? []).contains("fast") else { throw CodexClientError.invalid("Fast is unavailable for this model.") }
                }
                if let result=try await verifiedDraftConfigurationChange(operation,arguments:arguments,observed:observed,verification:verification) {
                    return result
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
        if operation == "get_keypad_models" { models = [] }
        var requestedRosterRevision:Int?
        if operation == "list_keypad_threads" {rosterIdentity=nil;rosterRevision += 1;requestedRosterRevision=rosterRevision}
        var result = try await core.execute(operation, arguments: arguments)
        if operation == "list_keypad_threads",requestedRosterRevision == rosterRevision,let scope=result["rosterScope"] as? String,scope.count == 64,
           scope.allSatisfy({"0123456789abcdef".contains($0)}),let context=result["contextID"] as? String,!context.isEmpty {
            rosterIdentity=(scope,context)
        }
        if operation == "get_keypad_models" { models = result["data"] as? [[String: Any]] ?? [] }
        if ["new_keypad_thread", "open_keypad_thread", "open_keypad_review", "fork_keypad_thread"].contains(operation), result["launch_requested"] as? Bool == true {
            // A deep link acknowledgment is distinct from observing its route.
            let id = result["threadId"] as? String
            do {
                for _ in 0..<6 {
                    try Task.checkCancellation()
                    let state = try await ui.execute("get_keypad_ui_state", arguments: [:], models: models)
                    result["foreground"] = state
                    if operation == "new_keypad_thread" ? state["draft"] as? Bool == true : state["threadId"] as? String == id && id != nil {
                        result["navigation_verified"] = operation != "open_keypad_review" || state["reviewOpen"] as? Bool == true
                        result["foreground"] = state
                        if result["navigation_verified"] as? Bool == true { break }
                    }
                    if let reason=state["reason"] as? String {result["followupError"]=reason}
                    // Permission denial is not a slow navigation. Preserve its
                    // cause and let the ordinary foreground observer recover later.
                    if state["accessibility"] as? Bool == false {break}
                    try await Task.sleep(for: .milliseconds(150))
                }
            } catch { result["followupError"] = error.localizedDescription }
            if result["navigation_verified"] as? Bool == true {result["followupError"]=nil}
        }
        return result
    }
}
