import XCTest
@testable import MicroPanelModel

@MainActor final class PanelRig: DesktopControlling {
    static let a="01000000-0000-0000-0000-000000000001"
    static let b="01000000-0000-0000-0000-000000000002"
    var calls:[(String,[String:Any])]=[]
    var rosterScope:String?=String(repeating:"a",count:64)
    var rosterRows:[[String:Any]]=[["id":a,"title":"Same title"],["id":b,"title":"Same title"]]
    var mappedRows:[[String:Any]]=[]
    var pinnedRows:[[String:Any]]=[]
    var pinnedAvailable=true
    var priorityComplete=true
    var ui:[String:Any]=["available":true,"routeAvailable":true,"selectionKnown":true,"threadId":a,"routeKey":"thread:"+a,"targetToken":"native-a","canSubmit":true,"canDictate":true,"canOpenThreadMenu":true,"canToggleTerminal":true,"canOpenBrowser":true,"canOpenFeedback":true,"canOpenFiles":true,"canOpenPhotos":true,"canOpenGitWorkflow":true,"canRunEnvironmentAction":true]
    var thread:[String:Any]=["model":"model-a","effort":"medium","serviceTier":NSNull(),"collaborationMode":["mode":"default"],"activeTurnId":"turn-a","canSubmit":true,"approvals":[]]
    var activity:[String:Any]=["watching":true,"contextValid":true,"contextID":"account-a","revision":1,"streamConnected":true,"visibilityKnown":true,"visibleContexts":[a],"settings":[:],"signals":[:]]
    var failure:String?
    var newDraftResult:[String:Any]=["launch_requested":true,"navigation_verified":false]
    var clientBinding:[String:Any]=["resolved":false]
    var onCall:((String) async -> Void)?
    var intercept:((String,[String:Any]) async throws -> [String:Any]?)?
    var mutations:[(String,[String:Any])] { calls.filter { !$0.0.hasPrefix("get_") && !$0.0.hasPrefix("list_") } }
    func execute(_ operation:String,arguments:[String:Any]) async throws -> [String:Any] {
        calls.append((operation,arguments)); await onCall?(operation)
        if let result=try await intercept?(operation,arguments) {return result}
        if failure == operation { throw NSError(domain:"Fixture",code:1) }
        switch operation {
        case "new_keypad_thread":return newDraftResult
        case "get_keypad_client_thread":return clientBinding
        case "list_keypad_threads":
            let ids=Set(arguments["mapped_thread_ids"] as? [String] ?? [])
            return ["contextID":"account-a","rosterScope":rosterScope ?? NSNull() as Any,"threads":rosterRows,"priorityComplete":priorityComplete,
                "pinnedThreads":arguments["include_pinned"] as? Bool == true ? pinnedRows:[],"pinnedAvailable":pinnedAvailable,
                "mappedThreads":arguments["roster_scope"] as? String == rosterScope ? mappedRows.filter {ids.contains($0["id"] as? String ?? "")}:[]]
        case "get_keypad_layout": return ["slots":[:],"encoderMode":"reasoning"]
        case "get_keypad_models": return ["data":[["model":"model-a","displayName":"Model A","defaultReasoningEffort":"medium","supportedReasoningEfforts":[["reasoningEffort":"low"],["reasoningEffort":"medium"],["reasoningEffort":"high"]],"serviceTiers":[["id":"fast"]]]]]
        case "get_keypad_usage": return [:]
        case "get_keypad_capabilities": return ["forkAvailable":true]
        case "get_keypad_ui_state": return ui
        case "get_keypad_activity": return activity
        case "get_keypad_state": return thread.merging(["threadId":arguments["thread_id"] ?? Self.a]) { _,new in new }
        case "open_keypad_developer_site", "open_keypad_folder": return ["launch_requested":true]
        case "open_keypad_settings", "open_keypad_skills", "open_keypad_tasks":
            ui=["available":false,"selectionKnown":true,"routeKey":["open_keypad_settings":"page:/settings/general","open_keypad_skills":"page:/skills","open_keypad_tasks":"page:/automations"][operation]!]
            return ["launch_requested":true,"navigation_verified":true,"foreground":ui]
        case "toggle_keypad_pin","copy_keypad_markdown","toggle_keypad_terminal","open_keypad_browser","open_keypad_side_chat","run_keypad_environment_action":return ["verified":true,"state":ui]
        case "insert_keypad_preset_text":
            ui["targetToken"]="native-preset-\(calls.count)"
            return ["verified":true,"inserted":true,"submitted":false,"clipboardModified":false,"state":ui]
        case "open_keypad_feedback":
            ui["available"]=false;ui["canOpenFeedback"]=false;ui["targetToken"]=NSNull()
            return ["verified":true,"submitted":false,"state":ui]
        case "open_keypad_files","open_keypad_photos":
            ui=["available":false,"selectionKnown":true,"routeKey":"modal:file-picker","threadId":NSNull(),"targetToken":NSNull()]
            return ["verified":true,"pickerOpened":true,"awaitingSelection":true,"attachmentVerified":false,"state":ui]
        case "open_keypad_merge_pull_request","open_keypad_commit","open_keypad_branch","open_keypad_pull_request","open_keypad_draft_pull_request":
            ui["available"]=false;ui["canOpenGitWorkflow"]=false;ui["targetToken"]=NSNull()
            return ["verified":true,"workflowOpened":true,"mutationCompleted":false,"state":ui]
        case "archive_keypad_thread":
            ui=["available":false,"selectionKnown":true,"routeKey":"page:/"]
            return ["verified":true,"archived":true,"state":ui]
        default:
            if operation == "set_keypad_fast" || operation == "set_keypad_draft_fast" { thread["serviceTier"] = (arguments["enabled"] as? Bool ?? !(thread["serviceTier"] is String)) ? "fast" : NSNull() as Any }
            if operation == "set_keypad_reasoning" || operation == "set_keypad_draft_reasoning" {
                if let direction=arguments["direction"] as? Int {
                    let choices=["low","medium","high"],at=choices.firstIndex(of:thread["effort"] as? String ?? "medium")!
                    thread["effort"]=choices[max(0,min(2,at+direction))]
                } else { thread["effort"] = arguments["effort"] }
            }
            if operation == "toggle_keypad_plan" || operation == "toggle_keypad_draft_plan" { thread["collaborationMode"] = ["mode":(thread["collaborationMode"] as? [String:String])?["mode"] == "plan" ? "default":"plan"] }
            if operation == "reply_keypad_approval" { thread["approvals"] = [] as [Any] }
            if operation == "stop_keypad_turn" { thread.removeValue(forKey:"activeTurnId") }
            if operation.contains("draft") { ui["settings"]=thread; ui["targetToken"]="native-draft-\(calls.count)" }
            return ["verified":true,"applied":true,"navigation_verified":true,"state":operation.contains("draft") || operation.contains("composer") || operation.contains("ui") || operation.contains("dictation") || operation.contains("sketch") || operation.contains("skill") ? ui : thread]
        }
    }
    func close() async {}
}

@MainActor final class PanelScenarioTests: XCTestCase {
    var suite:String!
    var defaults:UserDefaults!
    var settings:Settings!
    var rig:PanelRig!
    var panel:MicroModel!
    override func setUp() async throws {
        suite="MicroParityTests."+UUID().uuidString; defaults=UserDefaults(suiteName:suite)!
        settings=Settings(defaults:defaults); rig=PanelRig(); panel=MicroModel(settings:settings,client:rig)
        await panel.refresh(); await panel.refreshForeground(); await settle()
    }
    override func tearDown() async throws { panel.stop(); defaults.removePersistentDomain(forName:suite) }
    func settle() async {
        for _ in 0..<150 { await Task.yield(); if !panel.controlling && (panel.desktopConnected || panel.selectedID == nil) { return }; try? await Task.sleep(for:.milliseconds(1)) }
    }
    func press(_ command:String) async throws {
        let action=try XCTUnwrap(panel.prepareBinding(["type":"command","commandId":command]),command)
        action(); await settle()
    }
    func testStartupSelectsExactRouteDespiteDuplicateTitles() {
        XCTAssertEqual(panel.currentThreadID,PanelRig.a); XCTAssertEqual(panel.contextSource,.foreground)
        XCTAssertEqual(panel.currentModel,"model-a")
    }
    func testNonChatRouteClearsStaleIPCVisibility() async {
        await panel.refreshActivity()
        rig.ui=["available":false,"routeAvailable":false,"selectionKnown":true,"routeKey":"page:/settings"]
        await panel.refreshForeground(); await panel.refreshActivity()
        XCTAssertNil(panel.currentThreadID); XCTAssertNil(panel.controlTarget); XCTAssertEqual(panel.currentModel,"")
    }
    func testIPCVisibilityNeverEstablishesCurrentIdentityWithoutNativeEvidence() async {
        panel.stop();rig.ui=["available":false];await panel.refresh()
        await panel.refreshForeground(); await panel.refreshActivity(); await settle()
        XCTAssertNil(panel.currentThreadID); XCTAssertEqual(panel.contextSource,.none)
        XCTAssertNil(panel.selectedID); XCTAssertNil(panel.controlTarget)
        rig.activity["visibleContexts"]=[PanelRig.a,PanelRig.b]; await panel.refreshActivity()
        XCTAssertNil(panel.currentThreadID); XCTAssertNil(panel.controlTarget)
    }
    func testRouteSwitchBeforeWriteSendsNothingToOldThread() async throws {
        let action=try XCTUnwrap(panel.prepareBinding(["type":"command","commandId":"composer.toggleFastMode"]))
        rig.ui["threadId"]=PanelRig.b; rig.ui["routeKey"]="thread:"+PanelRig.b
        action(); await settle()
        XCTAssertTrue(rig.mutations.isEmpty); XCTAssertNotNil(panel.controlError)
    }
    func testNavigationToDraftDoesNotKeepOldThread() async {
        rig.ui=["available":true,"routeAvailable":true,"selectionKnown":true,"draft":true,"routeKey":"draft","targetToken":"draft-1","settings":rig.thread]
        await panel.refreshForeground()
        XCTAssertTrue(panel.isDraft); XCTAssertNil(panel.selectedID); XCTAssertNil(panel.currentThreadID)
        XCTAssertNil(panel.prepareBinding(["type":"command","commandId":"forkThread"]))
    }
    func testReplacingDraftInvalidatesCapturedAction() async throws {
        rig.ui=["available":true,"routeAvailable":true,"selectionKnown":true,"draft":true,"routeKey":"draft","targetToken":"draft-1","draftPlanAvailable":true,"settings":rig.thread]
        await panel.refreshForeground()
        let action=try XCTUnwrap(panel.prepareBinding(["type":"command","commandId":"composer.togglePlanMode"]))
        rig.ui["targetToken"]="draft-2"; await panel.refreshForeground(); action(); await settle()
        XCTAssertTrue(rig.mutations.isEmpty)
    }
    func testEverySupportedCommandDispatchesOneExactOperation() async throws {
        let cases:[(String,String)]=[("composer.toggleFastMode","set_keypad_fast"),("composer.togglePlanMode","toggle_keypad_plan"),("composer.increaseReasoningEffort","set_keypad_reasoning"),("composer.decreaseReasoningEffort","set_keypad_reasoning"),("forkThread","fork_keypad_thread"),("toggleReviewTab","open_keypad_review"),("turn.cancel","stop_keypad_turn"),("composer.submit","submit_keypad_composer"),("dictation.pushToTalk","toggle_keypad_dictation"),("composer.sketch","open_keypad_sketch"),("toggleSidebar","navigate_keypad_ui"),("navigateBack","navigate_keypad_ui"),("navigateForward","navigate_keypad_ui")]
        for (command,operation) in cases {
            rig.calls=[]; try await press(command)
            XCTAssertEqual(rig.mutations.map(\.0),[operation],command)
            if operation.hasPrefix("set_keypad_") || ["fork_keypad_thread","open_keypad_review","stop_keypad_turn","toggle_keypad_plan"].contains(operation) { XCTAssertEqual(rig.mutations.first?.1["thread_id"] as? String,PanelRig.a,command) }
            else { XCTAssertEqual(rig.mutations.first?.1["target_token"] as? String,"native-a",command) }
            await panel.refreshForeground(); await settle()
        }
    }
    func testApprovalRequiresUniqueRequestAndPreservesItsIdentity() async throws {
        for command in ["approval.approve","approval.decline"] {
            rig.thread["approvals"]=[["id":"request-a","method":"item/commandExecution/requestApproval","details":["command":"fixture"]]]
            await panel.refresh(); rig.calls=[]; try await press(command)
            XCTAssertEqual(rig.mutations.map(\.0),["reply_keypad_approval"])
            XCTAssertEqual(rig.mutations.first?.1["request_id"] as? String,"request-a")
            XCTAssertEqual(rig.mutations.first?.1["decision"] as? String,command == "approval.approve" ? "accept":"decline")
        }
        rig.thread["approvals"]=[["id":"a","method":"x"],["id":"b","method":"x"]]; await panel.refresh()
        XCTAssertNil(panel.prepareBinding(["type":"command","commandId":"approval.approve"]))
    }
    func testNewButtonRetiresOldIdentity() async throws {
        try await press("newTask")
        XCTAssertEqual(rig.mutations.map(\.0),["new_keypad_thread"]); XCTAssertNil(panel.selectedID)
    }
    func testSkillOverrideUsesExactPathWithoutSending() async throws {
        let binding:[String:Any]=["type":"skill","skillName":"fixture","skillPath":"/fixture/SKILL.md"]
        let action=try XCTUnwrap(panel.prepareBinding(binding)); action(); await settle()
        XCTAssertEqual(rig.mutations.map(\.0),["insert_keypad_skill"])
        XCTAssertEqual(rig.mutations.first?.1["path"] as? String,"/fixture/SKILL.md")
    }
    func testChangeKeycapThenSaveReloadDispatchesNewDefault() async throws {
        for key in KeySlots.defaults.keys.sorted() {
            rig.thread["effort"]="medium"
            var edit=KeyOverride(icon:"CODEX",action:KeySlots.defaultAction("CODEX")); edit.selectIcon("MIND+")
            settings.saveKey(key,value:edit)
            let reload=Settings(defaults:defaults), model=MicroModel(settings:reload,client:rig)
            await model.refresh(); await model.refreshForeground()
            for _ in 0..<100 where !model.desktopConnected { await Task.yield() }
            XCTAssertEqual(model.binding(for:key)?["commandId"] as? String,"composer.increaseReasoningEffort",key)
            rig.calls=[]; let action=try XCTUnwrap(model.prepareBinding(model.binding(for:key)),key); action()
            for _ in 0..<100 where model.controlling { await Task.yield() }
            XCTAssertEqual(rig.mutations.map(\.0),["set_keypad_reasoning"],key); model.stop()
        }
    }
    func testEveryAlternativeKeycapResetsPriorSendAndPersists() {
        // Independent expected catalog, including unsupported defaults. They must
        // remain unavailable instead of silently retaining the previous Send.
        let expected:[String:String]=["FAST":"composer.toggleFastMode","APPR":"approval.approve","REJ":"approval.decline","SPLIT":"forkThread","MIC":"dictation.pushToTalk","MIC1":"dictation.pushToTalk","CODEX":"composer.submit","NEW":"newTask","DIFF":"toggleReviewTab","SKETCH":"composer.sketch","MIND+":"composer.increaseReasoningEffort","MIND-":"composer.decreaseReasoningEffort","BUG":"feedback","OAI":"developers.openai.com","TERM":"toggleTerminal","DWN":"copyConversationMarkdown","DEL":"archiveThread","NAV":"openBrowserTab","MAGIC":"toggleThreadPin","PLAY":"environmentAction1","GIT":"git.commit","BRCH":"git.createDraftPullRequest","BRANCH":"git.createBranch","MRG":"git.mergePullRequest","PR":"git.createPullRequest","PAINT":"composer.addPhotos","LAB":"settings","SETUP":"settings","PARTY":"openSideChat","TIME":"manageTasks","FOLD":"openFolder","UPL":"composer.addFiles","APPS":"openSkills"]
        for (icon,command) in expected {
            var draft=KeyOverride(icon:"OLD",action:KeySlots.defaultAction("CODEX")); draft.selectIcon(icon)
            settings.saveKey("FAST",value:draft)
            let reloaded=Settings(defaults:defaults).layout.keys["ACT06"]
            XCTAssertEqual(reloaded?.icon,icon); XCTAssertEqual(reloaded?.action?["commandId"] as? String,command,icon)
        }
        for icon in ["EMPT1","EMPT2","EMPT3","EMPT4","EMPT5"] {
            var draft=KeyOverride(icon:"CODEX",action:KeySlots.defaultAction("CODEX")); draft.selectIcon(icon)
            XCTAssertNil(draft.action,icon)
        }
        for (icon,text) in [("YOLO",":yolo:"),("YEET",":yeet:")] {
            var draft=KeyOverride(icon:"CODEX",action:KeySlots.defaultAction("CODEX"));draft.selectIcon(icon)
            settings.saveKey("FAST",value:draft)
            let saved=Settings(defaults:defaults).layout.keys["ACT06"]
            XCTAssertEqual(saved?.action?["type"] as? String,"composer-text")
            XCTAssertEqual(saved?.action?["text"] as? String,text);XCTAssertNil(saved?.action?["commandId"])
        }
        XCTAssertEqual(Set(KeySlots.iconIDs),Set(expected.keys).union(["EMPT1","EMPT2","EMPT3","EMPT4","EMPT5","YOLO","YEET"]))
        XCTAssertEqual(KeySlots.iconIDs.count,40)
    }
    func testPresetKeycapsSaveReloadAndDispatchOnlyFixedTextWithFreshNativeToken() async throws {
        rig.ui["canInsertPresetText"]=true;await panel.refreshForeground()
        for icon in ["YOLO","YEET"] {
            let token=try XCTUnwrap(rig.ui["targetToken"] as? String)
            var cap=KeyOverride(icon:"CODEX",action:KeySlots.defaultAction("CODEX"));cap.selectIcon(icon)
            settings.saveKey("CODEX",value:cap)
            let reload=Settings(defaults:defaults),model=MicroModel(settings:reload,client:rig)
            await model.refresh();await model.refreshForeground();rig.calls=[]
            try XCTUnwrap(model.prepareBinding(model.binding(for:"CODEX")))()
            for _ in 0..<150 where model.controlling {await Task.yield()}
            XCTAssertEqual(rig.mutations.map(\.0),["insert_keypad_preset_text"])
            XCTAssertEqual(rig.mutations.first?.1["preset"] as? String,icon)
            XCTAssertEqual(rig.mutations.first?.1["target_token"] as? String,token)
            XCTAssertNil(rig.mutations.first?.1["text"]);XCTAssertNil(model.controlError)
            model.stop()
        }
    }
    func testPresetDraftAllowedButIDlessFallbackAndUnavailableSelectionRejected() async throws {
        rig.ui=["available":true,"routeAvailable":true,"selectionKnown":true,"draft":true,"routeKey":"draft","targetToken":"draft-preset","canInsertPresetText":true,"settings":rig.thread]
        await panel.refreshForeground()
        try XCTUnwrap(panel.prepareBinding(KeySlots.defaultAction("YEET")))();await settle()
        XCTAssertEqual(rig.mutations.map(\.0),["insert_keypad_preset_text"])
        XCTAssertNil(rig.mutations[0].1["thread_id"])
        rig.calls=[];rig.ui["canInsertPresetText"]=false;await panel.refreshForeground()
        XCTAssertNil(panel.prepareBinding(KeySlots.defaultAction("YOLO")))
        rig.ui=["available":true,"nativeComposer":true,"targetToken":"native-no-id","canInsertPresetText":true,"settings":rig.thread]
        await panel.refreshForeground()
        XCTAssertNil(panel.prepareBinding(KeySlots.defaultAction("YEET")))
        XCTAssertTrue(rig.mutations.isEmpty)
    }
    func testUnknownComposerTextAndFailedPresetCannotSendOrRetry() async throws {
        rig.ui["canInsertPresetText"]=true;await panel.refreshForeground()
        for text in ["Hello",":YOLO:",":yolo:\n",""] {
            XCTAssertNil(panel.prepareBinding(["type":"composer-text","text":text,"commandId":"composer.submit"]))
        }
        rig.failure="insert_keypad_preset_text"
        let press=try XCTUnwrap(panel.prepareBinding(KeySlots.defaultAction("YOLO")))
        for _ in 0..<6 {press()};await settle()
        XCTAssertEqual(rig.mutations.map(\.0),["insert_keypad_preset_text"])
        XCTAssertNotNil(panel.controlError);XCTAssertNil(panel.prepareBinding(KeySlots.defaultAction("YOLO")))
    }
    func testEveryEmptyAlternativePersistsAndNeverKeepsPreviousSend() {
        for icon in ["EMPT1","EMPT2","EMPT3","EMPT4","EMPT5"] {
            var cap=KeyOverride(icon:"CODEX",action:KeySlots.defaultAction("CODEX"));cap.selectIcon(icon)
            settings.saveKey("CODEX",value:cap)
            let reload=Settings(defaults:defaults),model=MicroModel(settings:reload,client:rig)
            XCTAssertEqual(model.keycap(for:"CODEX"),icon)
            XCTAssertNil(model.binding(for:"CODEX"));XCTAssertNil(model.prepareBinding(model.binding(for:"CODEX")))
            model.stop()
        }
        XCTAssertTrue(rig.mutations.isEmpty)
    }
    func testExplicitActionSurvivesReopeningButNextKeycapResetsIt() {
        let skill:[String:Any]=["type":"skill","skillName":"fixture","skillPath":"/fixture/SKILL.md"]
        var draft=KeyOverride(icon:"APPR",action:skill); draft.selectIcon("APPR")
        XCTAssertEqual(draft.action?["type"] as? String,"skill")
        draft.selectIcon("NEW"); XCTAssertEqual(draft.action?["commandId"] as? String,"newTask")
    }
    func testUnknownAlternativeNeverRetainsPreviousSend() {
        for icon in ["UNKNOWN-KEYCAP"] {
            var draft=KeyOverride(icon:"CODEX",action:KeySlots.defaultAction("CODEX")); draft.selectIcon(icon)
            XCTAssertNil(draft.action,icon); XCTAssertNil(panel.prepareBinding(draft.action),icon)
        }
        XCTAssertTrue(rig.mutations.isEmpty)
    }
    func testPinCopyArchiveKeycapsRouteOnlyToObservedExactThread() async throws {
        for (icon,operation) in [("PARTY","open_keypad_side_chat"),("NAV","open_keypad_browser"),("TERM","toggle_keypad_terminal"),("MAGIC","toggle_keypad_pin"),("DWN","copy_keypad_markdown"),("DEL","archive_keypad_thread")] {
            var cap=KeyOverride(icon:"CODEX",action:KeySlots.defaultAction("CODEX"));cap.selectIcon(icon)
            settings.saveKey("CODEX",value:cap);rig.calls=[]
            try XCTUnwrap(panel.prepareBinding(panel.binding(for:"CODEX")))();await settle()
            XCTAssertEqual(rig.mutations.map(\.0),[operation],icon)
            XCTAssertEqual(rig.mutations[0].1["thread_id"] as? String,PanelRig.a)
            XCTAssertEqual(rig.mutations[0].1["target_token"] as? String,"native-a")
            XCTAssertNil(panel.controlError)
        }
        XCTAssertNil(panel.currentThreadID);XCTAssertFalse(panel.threads.contains {$0.id == PanelRig.a})
    }
    func testThreadMenuKeycapsRejectUnknownIDAndUnavailableMenu() async throws {
        rig.ui["canOpenThreadMenu"]=false;await panel.refreshForeground()
        for icon in ["MAGIC","DWN","DEL","PARTY"] {XCTAssertNil(panel.prepareBinding(KeySlots.defaultAction(icon)))}
        await observeNativeComposer()
        rig.ui["canOpenThreadMenu"]=true;await panel.refreshForeground()
        for icon in ["MAGIC","DWN","DEL","PARTY"] {XCTAssertNil(panel.prepareBinding(KeySlots.defaultAction(icon)))}
        XCTAssertTrue(rig.mutations.isEmpty)
    }
    func testEachSettingsAndSkillsKeycapDefaultsRoutesAndClearsPreviousChat() async throws {
        for (icon,operation) in [("LAB","open_keypad_settings"),("SETUP","open_keypad_settings"),("APPS","open_keypad_skills"),("TIME","open_keypad_tasks")] {
            var cap=KeyOverride(icon:"CODEX",action:KeySlots.defaultAction("CODEX"));cap.selectIcon(icon)
            settings.saveKey("CODEX",value:cap);rig.calls=[]
            try XCTUnwrap(panel.prepareBinding(panel.binding(for:"CODEX")))();await settle()
            XCTAssertEqual(rig.mutations.map(\.0),[operation],icon);XCTAssertTrue(rig.mutations[0].1.isEmpty)
            XCTAssertNil(panel.currentThreadID);XCTAssertNil(panel.controlError)
        }
    }
    func testFeedbackKeycapSavesRoutesAndWorksAfterLeavingChatWithoutRetainingOldID() async throws {
        var cap=KeyOverride(icon:"CODEX",action:KeySlots.defaultAction("CODEX"));cap.selectIcon("BUG")
        settings.saveKey("CODEX",value:cap)
        rig.ui=["available":true,"selectionKnown":true,"routeKey":"page:/settings","targetToken":"native-settings","canOpenFeedback":true]
        await panel.refreshForeground();rig.calls=[]
        try XCTUnwrap(panel.prepareBinding(panel.binding(for:"CODEX")))();await settle()
        XCTAssertEqual(rig.mutations.map(\.0),["open_keypad_feedback"])
        XCTAssertEqual(rig.mutations[0].1["target_token"] as? String,"native-settings")
        XCTAssertNil(rig.mutations[0].1["thread_id"]);XCTAssertNil(panel.currentThreadID)
        XCTAssertNil(panel.controlError);XCTAssertNil(panel.prepareBinding(panel.binding(for:"CODEX")))
    }
    func testFilesKeycapSavesRoutesAndModalVetoesOldVisibleConversation() async throws {
        var cap=KeyOverride(icon:"CODEX",action:KeySlots.defaultAction("CODEX"));cap.selectIcon("UPL")
        settings.saveKey("CODEX",value:cap);rig.calls=[]
        try XCTUnwrap(panel.prepareBinding(panel.binding(for:"CODEX")))();await settle()
        XCTAssertEqual(rig.mutations.map(\.0),["open_keypad_files"])
        XCTAssertEqual(rig.mutations[0].1["target_token"] as? String,"native-a")
        XCTAssertNil(rig.mutations[0].1["thread_id"]);XCTAssertNil(panel.currentThreadID)
        XCTAssertNil(panel.controlError);XCTAssertNil(panel.prepareBinding(panel.binding(for:"CODEX")))
        // Later polling may identify only the native modal, without a route.
        // Old desktop visibility must still not restore the previous chat.
        rig.ui=["available":false,"selectionKnown":true,"routeKey":NSNull(),"threadId":NSNull(),"targetToken":NSNull()]
        await panel.refreshForeground();await panel.refreshActivity();await settle()
        XCTAssertNil(panel.currentThreadID);XCTAssertNil(panel.controlTarget)
        XCTAssertNil(panel.prepareBinding(KeySlots.defaultAction("CODEX")))
    }

    func testPhotosKeycapSavesDedicatedActionAndRetiresTargetAtNativeModal() async throws {
        var cap=KeyOverride(icon:"CODEX",action:KeySlots.defaultAction("CODEX"));cap.selectIcon("PAINT")
        settings.saveKey("CODEX",value:cap);rig.calls=[]
        try XCTUnwrap(panel.prepareBinding(panel.binding(for:"CODEX")))();await settle()
        XCTAssertEqual(rig.mutations.map(\.0),["open_keypad_photos"])
        XCTAssertEqual(rig.mutations[0].1["target_token"] as? String,"native-a")
        XCTAssertNil(rig.mutations[0].1["thread_id"]);XCTAssertNil(panel.currentThreadID)
        XCTAssertNil(panel.controlError);XCTAssertNil(panel.prepareBinding(panel.binding(for:"CODEX")))
    }
    func testPhotosKeycapRequiresAvailableNativePathAndKnownComposer() async throws {
        rig.ui["canOpenPhotos"]=false;await panel.refreshForeground()
        XCTAssertNil(panel.prepareBinding(KeySlots.defaultAction("PAINT")))
        await observeNativeComposer();rig.ui["canOpenPhotos"]=true;await panel.refreshForeground()
        XCTAssertNil(panel.prepareBinding(KeySlots.defaultAction("PAINT")))
        XCTAssertTrue(rig.mutations.isEmpty)
    }
    func testFilesKeycapRequiresObservedAddControlAndKnownComposerTarget() async throws {
        rig.ui["canOpenFiles"]=false;await panel.refreshForeground()
        XCTAssertNil(panel.prepareBinding(KeySlots.defaultAction("UPL")))
        await observeNativeComposer()
        rig.ui["canOpenFiles"]=true;await panel.refreshForeground()
        XCTAssertNil(panel.prepareBinding(KeySlots.defaultAction("UPL")))
        XCTAssertTrue(rig.mutations.isEmpty)
    }
    func testEachGitWorkflowKeycapSavesAndDispatchesExactNativeCommandOnce() async throws {
        let original=rig.ui
        for (icon,operation) in [("MRG","open_keypad_merge_pull_request"),("GIT","open_keypad_commit"),("BRANCH","open_keypad_branch"),("PR","open_keypad_pull_request"),("BRCH","open_keypad_draft_pull_request")] {
            rig.ui=original;await panel.refreshForeground();await settle()
            var cap=KeyOverride(icon:"CODEX",action:KeySlots.defaultAction("CODEX"));cap.selectIcon(icon)
            settings.saveKey("CODEX",value:cap);rig.calls=[]
            try XCTUnwrap(panel.prepareBinding(panel.binding(for:"CODEX")))();await settle()
            XCTAssertEqual(rig.mutations.map(\.0),[operation],icon)
            XCTAssertEqual(rig.mutations[0].1["thread_id"] as? String,PanelRig.a)
            XCTAssertEqual(rig.mutations[0].1["target_token"] as? String,"native-a")
            XCTAssertNil(panel.controlError);XCTAssertNil(panel.prepareBinding(panel.binding(for:"CODEX")))
        }
    }
    func testGitWorkflowKeycapsRejectUnavailableOrIDLessContext() async throws {
        rig.ui["canOpenGitWorkflow"]=false;await panel.refreshForeground()
        for cap in ["MRG","GIT","BRANCH","PR","BRCH"] {XCTAssertNil(panel.prepareBinding(KeySlots.defaultAction(cap)))}
        await observeNativeComposer();rig.ui["canOpenGitWorkflow"]=true;await panel.refreshForeground()
        for cap in ["MRG","GIT","BRANCH","PR","BRCH"] {XCTAssertNil(panel.prepareBinding(KeySlots.defaultAction(cap)))}
        XCTAssertTrue(rig.mutations.isEmpty)
    }
    func testPlayKeycapSavesAndTargetsFirstEnvironmentActionWithExactIDAndToken() async throws {
        var cap=KeyOverride(icon:"CODEX",action:KeySlots.defaultAction("CODEX"));cap.selectIcon("PLAY")
        settings.saveKey("CODEX",value:cap);rig.calls=[]
        try XCTUnwrap(panel.prepareBinding(panel.binding(for:"CODEX")))();await settle()
        XCTAssertEqual(rig.mutations.map(\.0),["run_keypad_environment_action"])
        XCTAssertEqual(rig.mutations[0].1["thread_id"] as? String,PanelRig.a)
        XCTAssertEqual(rig.mutations[0].1["target_token"] as? String,"native-a")
        XCTAssertNil(rig.mutations[0].1["command"]);XCTAssertNil(panel.controlError)
    }
    func testPlayRejectsUnavailableAndIDLessTargetsAndDoesNotReplayFailures() async throws {
        rig.failure="run_keypad_environment_action"
        try await press("environmentAction1")
        XCTAssertEqual(rig.mutations.map(\.0),["run_keypad_environment_action"])
        XCTAssertNotNil(panel.controlError)
        rig.ui["canRunEnvironmentAction"]=false;await panel.refreshForeground()
        XCTAssertNil(panel.prepareBinding(KeySlots.defaultAction("PLAY")))
        await observeNativeComposer();rig.ui["canRunEnvironmentAction"]=true;await panel.refreshForeground()
        XCTAssertNil(panel.prepareBinding(KeySlots.defaultAction("PLAY")))
    }
    func testDeveloperSiteKeycapWorksWithoutAChatOrCodexConnection() async throws {
        panel.stop(); rig.calls=[]
        var cap=KeyOverride(icon:"CODEX",action:KeySlots.defaultAction("CODEX")); cap.selectIcon("OAI")
        settings.saveKey("CODEX",value:cap)
        try XCTUnwrap(panel.prepareBinding(panel.binding(for:"CODEX")))()
        await settle()
        XCTAssertEqual(rig.mutations.map(\.0),["open_keypad_developer_site"])
        XCTAssertTrue(rig.mutations[0].1.isEmpty); XCTAssertNil(panel.controlError)
    }
    func testFolderKeycapUsesExactTargetAndRejectsPrewriteSwitch() async throws {
        var cap=KeyOverride(icon:"CODEX",action:KeySlots.defaultAction("CODEX")); cap.selectIcon("FOLD")
        settings.saveKey("CODEX",value:cap)
        try XCTUnwrap(panel.prepareBinding(panel.binding(for:"CODEX")))(); await settle()
        XCTAssertEqual(rig.mutations.map(\.0),["open_keypad_folder"])
        XCTAssertEqual(rig.mutations[0].1["thread_id"] as? String,PanelRig.a)
        let again=try XCTUnwrap(panel.prepareBinding(panel.binding(for:"CODEX")))
        rig.calls=[]; rig.ui["threadId"]=PanelRig.b; again(); await settle()
        XCTAssertTrue(rig.mutations.isEmpty)
    }
    func testFolderIsUnavailableWithoutExactIDAndLaunchFailureIsNotReplayed() async throws {
        rig.failure="open_keypad_developer_site"
        try await press("developers.openai.com")
        XCTAssertEqual(rig.mutations.count,1); XCTAssertNotNil(panel.controlError)
        await observeNativeComposer()
        XCTAssertNil(panel.prepareBinding(KeySlots.defaultAction("FOLD")))
        rig.ui["draft"]=true; rig.ui["nativeComposer"]=false; rig.ui["routeAvailable"]=true; rig.ui["selectionKnown"]=true; rig.ui["routeKey"]="draft"
        await panel.refreshForeground(); await settle()
        XCTAssertNil(panel.prepareBinding(KeySlots.defaultAction("FOLD")))
    }
    func testCancelAndSplitMergeKeepAllStoredBindings() {
        for (key,icon) in [("ACT10","NEW"),("ACT11","SKETCH"),("ACT10_ACT11","MIC")] { settings.saveKey(key,value:KeyOverride(icon:icon,action:KeySlots.defaultAction(icon))) }
        var cancelled=KeyOverride(icon:"NEW",action:KeySlots.defaultAction("NEW")); cancelled.selectIcon("CODEX")
        var layout=settings.layout; layout.separateMicrophoneKeys=true; settings.setLayout(layout); layout.separateMicrophoneKeys=false; settings.setLayout(layout)
        let reloaded=Settings(defaults:defaults)
        XCTAssertEqual(reloaded.layout.keys["ACT10"]?.icon,"NEW"); XCTAssertEqual(reloaded.layout.keys["ACT11"]?.icon,"SKETCH"); XCTAssertEqual(reloaded.layout.keys["ACT10_ACT11"]?.icon,"MIC")
    }
    func testSixRapidFastClicksAreSerializedAndRestoreOriginalTier() async throws {
        for _ in 0..<6 {
            let action=try XCTUnwrap(panel.prepareBinding(["type":"command","commandId":"composer.toggleFastMode"]))
            action()
        }
        await settle()
        XCTAssertEqual(rig.mutations.map(\.0),Array(repeating:"set_keypad_fast",count:6))
        XCTAssertEqual(rig.mutations.compactMap { $0.1["enabled"] as? Bool },[true,false,true,false,true,false])
        XCTAssertFalse(panel.fast); XCTAssertEqual(panel.currentModel,"model-a"); XCTAssertEqual(panel.currentEffort,"medium")
    }
    func testFastQueueStopsAtTargetChangeWithoutReplayingRemainingClicks() async throws {
        rig.onCall={ [weak rig] operation in if operation == "set_keypad_fast" { rig?.ui["threadId"]=PanelRig.b } }
        for _ in 0..<6 { try XCTUnwrap(panel.prepareBinding(["type":"command","commandId":"composer.toggleFastMode"]))() }
        await settle(); XCTAssertEqual(rig.mutations.count,1); XCTAssertNotNil(panel.controlError)
    }
    func testSixFastClicksSurviveSlowNativeReadbacks() async throws {
        var now=ProcessInfo.processInfo.systemUptime
        panel.stop(); panel=MicroModel(settings:settings,client:rig,uptime:{ now })
        await panel.refresh(); await panel.refreshForeground(); await settle()
        rig.onCall={ operation in if operation == "set_keypad_fast" { now += 10 } }
        for _ in 0..<6 { try XCTUnwrap(panel.prepareBinding(["type":"command","commandId":"composer.toggleFastMode"]))() }
        await settle()
        XCTAssertEqual(rig.mutations.compactMap { $0.1["enabled"] as? Bool },[true,false,true,false,true,false])
        XCTAssertFalse(panel.fast); XCTAssertNil(panel.controlError)
    }
    func testMixedSettingsClicksSerializeAndUseEachReadback() async throws {
        for command in ["composer.toggleFastMode","composer.togglePlanMode","composer.increaseReasoningEffort","composer.increaseReasoningEffort","composer.decreaseReasoningEffort","composer.toggleFastMode","composer.togglePlanMode"] {
            try XCTUnwrap(panel.prepareBinding(["type":"command","commandId":command]),command)()
        }
        await settle()
        XCTAssertEqual(rig.mutations.map(\.0),["set_keypad_fast","toggle_keypad_plan","set_keypad_reasoning","set_keypad_reasoning","set_keypad_fast","toggle_keypad_plan"])
        XCTAssertEqual(rig.mutations.filter { $0.0 == "set_keypad_reasoning" }.compactMap { $0.1["effort"] as? String },["high","medium"])
        XCTAssertFalse(panel.fast); XCTAssertEqual(panel.currentEffort,"medium"); XCTAssertEqual(panel.collaborationMode,"default")
        XCTAssertNil(panel.controlError)
    }
    func testMixedSettingsQueueStopsOnTargetChange() async throws {
        rig.onCall={ [weak rig] operation in if operation == "toggle_keypad_plan" { rig?.ui["threadId"]=PanelRig.b } }
        for command in ["composer.togglePlanMode","composer.increaseReasoningEffort","composer.toggleFastMode"] {
            try XCTUnwrap(panel.prepareBinding(["type":"command","commandId":command]))()
        }
        await settle(); XCTAssertEqual(rig.mutations.map(\.0),["toggle_keypad_plan"]); XCTAssertNotNil(panel.controlError)
    }
    func testDraftMixedSettingsQueueUsesRenewedNativeTokens() async throws {
        rig.ui=["available":true,"routeAvailable":true,"selectionKnown":true,"draft":true,"routeKey":"draft","targetToken":"native-draft",
                "draftFastAvailable":true,"draftPlanAvailable":true,"draftReasoningAvailable":true,"settings":rig.thread]
        await panel.refreshForeground(); await settle()
        for command in ["composer.toggleFastMode","composer.togglePlanMode","composer.increaseReasoningEffort"] {
            try XCTUnwrap(panel.prepareBinding(["type":"command","commandId":command]),command)()
        }
        await settle()
        XCTAssertEqual(rig.mutations.map(\.0),["set_keypad_draft_fast","toggle_keypad_draft_plan","set_keypad_draft_reasoning"])
        let tokens=rig.mutations.compactMap { $0.1["target_token"] as? String }
        XCTAssertEqual(tokens.count,3); XCTAssertEqual(Set(tokens).count,3)
        XCTAssertTrue(rig.mutations.allSatisfy { $0.1["thread_id"] == nil })
        XCTAssertTrue(panel.fast); XCTAssertEqual(panel.currentEffort,"high"); XCTAssertEqual(panel.collaborationMode,"plan")
    }
    func observeNativeComposer() async {
        rig.ui=["available":true,"routeAvailable":false,"selectionKnown":false,"draft":false,"nativeComposer":true,"targetToken":"native-only",
                "canSubmit":true,"canDictate":true,"draftFastAvailable":true,"draftPlanAvailable":true,"draftReasoningAvailable":true,"settings":rig.thread]
        await panel.refreshForeground(); await settle(); rig.calls=[]
    }
    func testNativeOnlySettingsUseNativeChannelsWithoutThreadID() async throws {
        await observeNativeComposer()
        for command in ["composer.toggleFastMode","composer.togglePlanMode","composer.increaseReasoningEffort"] {
            try XCTUnwrap(panel.prepareBinding(["type":"command","commandId":command]),command)()
        }
        await settle()
        XCTAssertEqual(rig.mutations.map(\.0),["set_keypad_draft_fast","toggle_keypad_draft_plan","set_keypad_draft_reasoning"])
        XCTAssertTrue(rig.mutations.allSatisfy { $0.1["thread_id"] == nil && $0.1["native_composer"] as? Bool == true })
        XCTAssertTrue(panel.isNativeComposer); XCTAssertFalse(panel.isDraft); XCTAssertNil(panel.currentThreadID); XCTAssertNil(panel.selectedID)
        XCTAssertTrue(panel.fast); XCTAssertEqual(panel.collaborationMode,"plan"); XCTAssertEqual(panel.currentEffort,"high")
    }
    func testNativeComposerPreventsStaleVisibleIPCFromBecomingTarget() async {
        await observeNativeComposer(); await panel.refreshActivity(); await settle()
        XCTAssertTrue(panel.isNativeComposer); XCTAssertNil(panel.selectedID); XCTAssertEqual(panel.contextSource,.foreground)
        XCTAssertFalse(rig.calls.contains { $0.0 == "get_keypad_state" })
    }
    func testNativeComposerCannotSendApproveStopForkOrReview() async {
        rig.thread["approvals"]=[["id":"fixture-request","method":"commandExecution","details":[:]]]
        await observeNativeComposer()
        for command in ["composer.submit","approval.approve","approval.decline","turn.cancel","forkThread","toggleReviewTab","composer.sketch","dictation.pushToTalk","toggleSidebar"] {
            XCTAssertNil(panel.prepareBinding(["type":"command","commandId":command]),command)
        }
        XCTAssertNil(panel.prepareBinding(["type":"skill","skillName":"fixture","skillPath":"/fixture/SKILL.md"]))
        XCTAssertNil(panel.prepareNavigationDial("conversation-scroll",profile:DialProfile()))
        XCTAssertTrue(rig.mutations.isEmpty)
    }
    func testNativeComposerReplacementInvalidatesCapturedSettings() async throws {
        await observeNativeComposer()
        let action=try XCTUnwrap(panel.prepareBinding(["type":"command","commandId":"composer.toggleFastMode"]))
        rig.ui["targetToken"]="native-replacement"; await panel.refreshForeground(); action(); await settle()
        XCTAssertTrue(rig.mutations.isEmpty)
    }
    func testNativeComposerBecomesExactThreadAndRestoresIPC() async throws {
        await observeNativeComposer()
        rig.ui=["available":true,"routeAvailable":true,"selectionKnown":true,"threadId":PanelRig.b,"routeKey":"thread:"+PanelRig.b,"targetToken":"thread-b"]
        await panel.refreshForeground(); await settle(); rig.calls=[]
        XCTAssertFalse(panel.isNativeComposer); XCTAssertEqual(panel.currentThreadID,PanelRig.b)
        try await press("composer.toggleFastMode")
        XCTAssertEqual(rig.mutations.map(\.0),["set_keypad_fast"])
        XCTAssertEqual(rig.mutations.first?.1["thread_id"] as? String,PanelRig.b)
    }
    func testKnownNonChatRouteRetiresNativeComposer() async {
        await observeNativeComposer()
        rig.ui=["available":false,"routeAvailable":false,"selectionKnown":true,"routeKey":"page:/settings"]
        await panel.refreshForeground(); await panel.refreshActivity(); await settle()
        XCTAssertFalse(panel.isNativeComposer); XCTAssertNil(panel.controlTarget); XCTAssertNil(panel.currentThreadID); XCTAssertEqual(panel.currentModel,"")
    }
    func testNativeComposerWithoutConfiguredShortcutsDoesNotFallBackToIPC() async {
        await observeNativeComposer()
        for key in ["draftFastAvailable","draftPlanAvailable","draftReasoningAvailable"] { rig.ui[key]=false }
        await panel.refreshForeground(); await settle()
        for command in ["composer.toggleFastMode","composer.togglePlanMode","composer.increaseReasoningEffort","composer.decreaseReasoningEffort"] {
            XCTAssertNil(panel.prepareBinding(["type":"command","commandId":command]),command)
        }
        XCTAssertTrue(rig.mutations.isEmpty)
    }
    func testNativeComposerBecomingDraftInvalidatesOldActionWithoutInventingID() async throws {
        await observeNativeComposer()
        let action=try XCTUnwrap(panel.prepareBinding(["type":"command","commandId":"composer.togglePlanMode"]))
        rig.ui["nativeComposer"]=false; rig.ui["draft"]=true; rig.ui["selectionKnown"]=true; rig.ui["routeAvailable"]=true; rig.ui["routeKey"]="draft"
        await panel.refreshForeground(); action(); await settle()
        XCTAssertTrue(panel.isDraft); XCTAssertFalse(panel.isNativeComposer); XCTAssertNil(panel.currentThreadID)
        XCTAssertTrue(rig.mutations.isEmpty)
    }
    func testFastQueueExpiresWithoutReplayingRemainingClicks() async throws {
        var now=ProcessInfo.processInfo.systemUptime
        panel.stop(); panel=MicroModel(settings:settings,client:rig,uptime:{ now })
        await panel.refresh(); await panel.refreshForeground(); await settle()
        rig.onCall={ operation in if operation == "set_keypad_fast" { now += 61 } }
        for _ in 0..<6 { try XCTUnwrap(panel.prepareBinding(["type":"command","commandId":"composer.toggleFastMode"]))() }
        await settle()
        XCTAssertEqual(rig.mutations.count,1); XCTAssertNotNil(panel.controlError)
    }
    func testScrollDialPressGoesToBottomWithoutChangingModel() async throws {
        let dial=try XCTUnwrap(panel.prepareNavigationDial("conversation-scroll",profile:DialProfile()))
        dial.tap(); await settle()
        XCTAssertEqual(rig.mutations.map(\.0),["navigate_keypad_ui"])
        XCTAssertEqual(rig.mutations.first?.1["action"] as? String,"scroll-bottom")
    }
    func testScrollBurstAccumulatesStepsAndDoesNotClickOrChangeModel() async throws {
        let dial=try XCTUnwrap(panel.prepareNavigationDial("conversation-scroll",profile:DialProfile()))
        dial.step(1);dial.step(2);dial.step(3);dial.end(false)
        await settle()
        XCTAssertEqual(rig.mutations.map(\.0),["navigate_keypad_ui"])
        XCTAssertEqual(rig.mutations.first?.1["action"] as? String,"scroll-down")
        XCTAssertEqual(rig.mutations.first?.1["steps"] as? Int,6)
    }
    func testScrollingWhileAwaitingReadbackKeepsOrderAndRenewsTargetToken() async throws {
        let dial=try XCTUnwrap(panel.prepareNavigationDial("conversation-scroll",profile:DialProfile()))
        var first=true
        rig.onCall={ [weak rig] operation in
            if operation == "navigate_keypad_ui",first {
                first=false;dial.step(-2);rig?.ui["targetToken"]="after-scroll"
            }
        }
        dial.step(1);dial.end(false);await settle()
        XCTAssertEqual(rig.mutations.compactMap{$0.1["action"] as? String},["scroll-down","scroll-up"])
        XCTAssertEqual(rig.mutations.compactMap{$0.1["target_token"] as? String},["native-a","after-scroll"])
    }
    func testScrollingTargetChangeStopsPendingSteps() async throws {
        let dial=try XCTUnwrap(panel.prepareNavigationDial("conversation-scroll",profile:DialProfile()))
        rig.onCall={ [weak rig] operation in
            if operation == "navigate_keypad_ui" { dial.step(-1);rig?.ui["routeKey"]="thread:"+PanelRig.b }
        }
        dial.step(1);dial.end(false);await settle()
        XCTAssertEqual(rig.mutations.count,1);XCTAssertNotNil(panel.controlError)
    }
    func testBackgroundSubmitCanActivateEmptyComposerButForegroundCannotSend() async throws {
        rig.ui["canSubmit"]=false; rig.ui["foreground"]=false
        await panel.refreshForeground(); await settle()
        try await press("composer.submit")
        XCTAssertEqual(rig.mutations.map(\.0),["submit_keypad_composer"])
        rig.ui["foreground"]=true
        await panel.refreshForeground(); await settle()
        XCTAssertNil(panel.prepareBinding(["type":"command","commandId":"composer.submit"]))
    }
    func testThreadABAInvalidatesCapturedControl() async throws {
        let action=try XCTUnwrap(panel.prepareBinding(["type":"command","commandId":"composer.togglePlanMode"]))
        rig.ui["threadId"]=PanelRig.b; rig.ui["routeKey"]="thread:"+PanelRig.b
        await panel.refreshForeground(); await settle()
        rig.ui["threadId"]=PanelRig.a; rig.ui["routeKey"]="thread:"+PanelRig.a
        await panel.refreshForeground(); await settle(); action(); await settle()
        XCTAssertTrue(rig.mutations.isEmpty)
    }
    func testFailedFastWriteDoesNotRunQueuedClicks() async throws {
        rig.failure="set_keypad_fast"
        for _ in 0..<6 { try XCTUnwrap(panel.prepareBinding(["type":"command","commandId":"composer.toggleFastMode"]))() }
        await settle(); XCTAssertEqual(rig.mutations.count,1); XCTAssertNotNil(panel.controlError)
    }
    func testInvalidBindingTypeCannotDispatchEmbeddedCommand() {
        XCTAssertNil(panel.prepareBinding(["type":"invalid","commandId":"composer.submit"]))
        XCTAssertTrue(rig.mutations.isEmpty)
    }
    func testMarkUnreadUsesClickedTaskWithoutSwitchingCurrentConversation() async throws {
        let row=try XCTUnwrap(panel.threads.first { $0.id == PanelRig.b })
        panel.markUnread(row); await settle()
        XCTAssertEqual(rig.mutations.map(\.0),["mark_keypad_unread"])
        XCTAssertEqual(rig.mutations.first?.1["thread_id"] as? String,PanelRig.b)
        XCTAssertEqual(panel.currentThreadID,PanelRig.a); XCTAssertEqual(panel.signal(for:row),.unread)
        XCTAssertFalse(panel.canMarkUnread(row))
    }
}
