import XCTest
@testable import MicroPanelModel

@MainActor final class TaskCommandScenarioTests:XCTestCase {
    let scopeA=String(repeating:"a",count:64),scopeB=String(repeating:"b",count:64)
    var suite:String!,defaults:UserDefaults!,settings:Settings!,rig:PanelRig!,panel:MicroModel!
    override func setUp() async throws {
        suite="MicroTaskCommands."+UUID().uuidString;defaults=UserDefaults(suiteName:suite)!
        settings=Settings(defaults:defaults);await ready()
    }
    override func tearDown() async throws {panel.stop();defaults.removePersistentDomain(forName:suite)}
    func ready() async {
        rig=PanelRig();panel=MicroModel(settings:settings,client:rig)
        await panel.refresh();await panel.refreshForeground();await settle()
    }
    func settle() async {
        for _ in 0..<250 {
            await Task.yield()
            if !panel.refreshing && !panel.opening && !panel.controlling && (panel.selectedID == nil || panel.desktopConnected) {return}
            try? await Task.sleep(for:.milliseconds(1))
        }
    }
    func custom(_ commands:[String:String],threads:[String:String]=[:]) async {
        var profile=settings.layout;profile.agentSource="custom"
        profile.taskCommands=[scopeA:commands];profile.taskMappings=[scopeA:threads]
        settings.setLayout(profile);panel.preferencesChanged();await panel.refresh();await settle()
    }
    func record(_ scenario:String) {
        ReplayTrace.emit("TASK-COMMAND-TRACE",["scenario":scenario,"commands":panel.displayedTaskCommands.map {$0 ?? "empty"},
            "slots":panel.displayedTaskSlots.map {$0?.id ?? "empty"},"mutations":rig.mutations.map(\.0)])
    }
    func testMixedFixedRecentAndCommandsKeepTheirPositionsAndOnlyQueryIDs() async {
        await custom(["AG01":"recentThread1","AG02":"settings","AG13":"composer.togglePlanMode"],threads:["AG00":PanelRig.b])
        XCTAssertEqual(panel.displayedTaskSlots.count,14);XCTAssertEqual(panel.taskRow(at:0)?.id,PanelRig.b)
        XCTAssertEqual(panel.taskRow(at:1)?.id,PanelRig.a);XCTAssertNil(panel.taskRow(at:2))
        XCTAssertEqual(panel.taskCommand(at:13),"composer.togglePlanMode");XCTAssertNotNil(panel.prepareTask(13))
        XCTAssertEqual(rig.calls.last {$0.0 == "list_keypad_threads"}?.1["mapped_thread_ids"] as? [String],[PanelRig.b])
        XCTAssertNotEqual(panel.taskLabel(at:2),tr("emptySlot"));XCTAssertTrue(rig.mutations.isEmpty)
        record("U01 mixed assignments and exact-only catalog query")
    }
    func testRecentCommandFollowsOrderWhileFixedChatStaysFixed() async throws {
        await custom(["AG00":"recentThread1"],threads:["AG01":PanelRig.a])
        rig.rosterRows.reverse();await panel.refresh()
        XCTAssertEqual(panel.taskRow(at:0)?.id,PanelRig.b);XCTAssertEqual(panel.taskRow(at:1)?.id,PanelRig.a)
        try XCTUnwrap(panel.prepareTask(0))();await settle()
        XCTAssertEqual(rig.mutations.map(\.0),["open_keypad_thread"])
        XCTAssertEqual(rig.mutations.first?.1["thread_id"] as? String,PanelRig.b)
        record("U02 recent command versus fixed ID")
    }
    func testHoverAndHeldPressRetainExactDisplayedRecentChat() async throws {
        await custom(["AG00":"recentThread1"]);panel.setInteraction("hover",active:true)
        let press=try XCTUnwrap(panel.prepareTask(0));rig.rosterRows.reverse();await panel.refresh()
        XCTAssertEqual(panel.taskRow(at:0)?.id,PanelRig.a);press();await settle()
        XCTAssertEqual(rig.mutations.first?.1["thread_id"] as? String,PanelRig.a)
        panel.setInteraction("hover",active:false);XCTAssertEqual(panel.taskRow(at:0)?.id,PanelRig.b)
        record("U03 hovered recent identity")
    }
    func testCommandThreadReplacementClearAndFixedAssignmentMoveAreExclusive() async {
        await custom(["AG00":"settings"])
        panel.assignTask(0,thread:PanelRig.a);await settle()
        XCTAssertNil(settings.layout.taskCommandMap(scope:scopeA)["AG00"])
        panel.assignTask(4,thread:PanelRig.a);await settle()
        XCTAssertNil(settings.layout.taskMap(scope:scopeA)["AG00"]);XCTAssertEqual(panel.taskRow(at:4)?.id,PanelRig.a)
        panel.assignTaskCommand(4,command:"toggleTerminal");await settle()
        XCTAssertNil(settings.layout.taskMap(scope:scopeA)["AG04"])
        panel.assignTask(4,thread:nil);await settle()
        XCTAssertNil(panel.taskCommand(at:4));XCTAssertNil(panel.taskRow(at:4));XCTAssertNil(panel.prepareTask(4))
        XCTAssertTrue(rig.mutations.isEmpty);record("U04 exclusive replacement move and clear")
    }
    func testEverySupportedTaskCommandDispatchesItsExactOperation() async throws {
        var expected=["composer.submit":"submit_keypad_composer","composer.toggleFastMode":"set_keypad_fast","composer.togglePlanMode":"toggle_keypad_plan",
            "approval.approve":"reply_keypad_approval","approval.decline":"reply_keypad_approval","forkThread":"fork_keypad_thread","newTask":"new_keypad_thread","newThread":"new_keypad_thread",
            "toggleReviewTab":"open_keypad_review","openReviewTab":"open_keypad_review","review":"open_keypad_review","turn.cancel":"stop_keypad_turn",
            "dictation.pushToTalk":"toggle_keypad_dictation","composer.dictation":"toggle_keypad_dictation","composer.sketch":"open_keypad_sketch",
            "composer.increaseReasoningEffort":"set_keypad_reasoning","composer.decreaseReasoningEffort":"set_keypad_reasoning",
            "toggleSidebar":"navigate_keypad_ui","navigateBack":"navigate_keypad_ui","navigateForward":"navigate_keypad_ui",
            "developers.openai.com":"open_keypad_developer_site","openFolder":"open_keypad_folder","settings":"open_keypad_settings","openSkills":"open_keypad_skills",
            "toggleThreadPin":"toggle_keypad_pin","copyConversationMarkdown":"copy_keypad_markdown","archiveThread":"archive_keypad_thread","toggleTerminal":"toggle_keypad_terminal",
            "openBrowserTab":"open_keypad_browser","manageTasks":"open_keypad_tasks","feedback":"open_keypad_feedback","openSideChat":"open_keypad_side_chat",
            "composer.addFiles":"open_keypad_files","composer.addPhotos":"open_keypad_photos","git.mergePullRequest":"open_keypad_merge_pull_request","git.commit":"open_keypad_commit",
            "git.createBranch":"open_keypad_branch","git.createPullRequest":"open_keypad_pull_request","git.createDraftPullRequest":"open_keypad_draft_pull_request","environmentAction1":"run_keypad_environment_action"]
        for command in KeySlots.recentCommands {expected[command]="open_keypad_thread"}
        XCTAssertEqual(Set(expected.keys),KeySlots.supportedCommands)
        var dispatched:[[String:String]]=[]
        for command in expected.keys.sorted() {
            panel.stop();settings.resetLayout();await ready()
            rig.rosterRows=(1...6).map {["id":String(format:"01000000-0000-0000-0000-%012d",$0),"title":"Same title"]}
            rig.thread["approvals"]=[["id":"approval-a","method":"item/commandExecution/requestApproval"]]
            await custom(["AG13":command]);rig.calls=[]
            try XCTUnwrap(panel.prepareTask(13),command)();await settle()
            XCTAssertEqual(rig.mutations.map(\.0),[expected[command]!],command)
            let args=try XCTUnwrap(rig.mutations.first,command).1
            if let index=KeySlots.recentIndex(command) {XCTAssertEqual(args["thread_id"] as? String,rig.rosterRows[index]["id"] as? String)}
            else if let id=args["thread_id"] as? String {XCTAssertEqual(id,PanelRig.a,command)}
            if let token=args["target_token"] as? String {XCTAssertEqual(token,"native-a",command)}
            if command.hasPrefix("approval.") {XCTAssertEqual(args["request_id"] as? String,"approval-a")}
            dispatched.append(["command":command,"operation":expected[command]!])
        }
        ReplayTrace.emit("TASK-COMMAND-TRACE",["scenario":"U05 every supported command","dispatches":dispatched])
    }
    func testEditingHeldCommandRetiresOldActionAndKeepsFrozenDisplayDisabled() async throws {
        await custom(["AG00":"settings"]);panel.setInteraction("press",active:true)
        let press=try XCTUnwrap(panel.prepareTask(0));panel.assignTaskCommand(0,command:"openSkills");await settle();press()
        XCTAssertEqual(panel.taskCommand(at:0),"settings");XCTAssertNil(panel.prepareTask(0));XCTAssertTrue(rig.mutations.isEmpty)
        panel.setInteraction("press",active:false);XCTAssertEqual(panel.taskCommand(at:0),"openSkills")
        record("U06 command replacement during held press")
    }
    func testSameCommandInTwoAccountsCannotReuseOldHoveredState() async throws {
        await custom(["AG00":"settings","AG01":"recentThread1"])
        var profile=settings.layout;let commands=profile.taskCommandMap(scope:scopeA)
        profile.taskCommands?[scopeB]=commands;settings.setLayout(profile);panel.preferencesChanged();await settle()
        panel.setInteraction("hover",active:true);let old=try XCTUnwrap(panel.prepareTask(0))
        rig.rosterScope=scopeB;await panel.refresh();old()
        XCTAssertNil(panel.prepareTask(0));XCTAssertNil(panel.prepareTask(1));XCTAssertTrue(rig.mutations.isEmpty)
        panel.setInteraction("hover",active:false);XCTAssertNotNil(panel.prepareTask(0))
        rig.rosterScope=nil;await panel.refresh();panel.assignTaskCommand(0,command:"feedback")
        XCTAssertNil(panel.prepareTask(0));XCTAssertEqual(settings.layout.taskCommandMap(scope:scopeA)["AG00"],"settings")
        record("U07 same command account isolation and unknown account")
    }
    func testLateOldReadCannotReplaceEditedCommand() async {
        await custom(["AG00":"recentThread1"]);var changed=false
        rig.onCall={operation in
            if operation == "list_keypad_threads",!changed {changed=true;self.panel.assignTaskCommand(0,command:"settings")}
        }
        await panel.refresh();await settle()
        XCTAssertEqual(panel.taskCommand(at:0),"settings");XCTAssertNil(panel.taskRow(at:0));XCTAssertTrue(rig.mutations.isEmpty)
        record("U08 late mapping read after command edit")
    }
    func testRestartSourceSwitchAndRecentSnapshotPreserveIntent() async {
        await custom(["AG03":"settings","AG13":"recentThread2"]);panel.stop()
        settings=Settings(defaults:defaults);await ready()
        XCTAssertEqual(panel.taskCommand(at:3),"settings");XCTAssertEqual(panel.taskRow(at:13)?.id,PanelRig.b)
        var profile=settings.layout;profile.agentSource="recent";settings.setLayout(profile);panel.preferencesChanged();await settle()
        XCTAssertNil(panel.taskCommand(at:3));XCTAssertEqual(panel.taskRow(at:0)?.id,PanelRig.a)
        profile.agentSource="custom";settings.setLayout(profile);panel.preferencesChanged();await settle()
        XCTAssertEqual(panel.taskCommand(at:3),"settings")
        panel.captureRecentTaskLayout();await settle()
        XCTAssertTrue(settings.layout.taskCommandMap(scope:scopeA).isEmpty);XCTAssertEqual(panel.taskRow(at:0)?.id,PanelRig.a)
        XCTAssertTrue(rig.mutations.isEmpty);record("U09 restart source switch and explicit recent snapshot")
    }
    func testMalformedCommandsAndConflictingBindingsCannotChangeSavedLayout() throws {
        let before=settings.layout
        for map in [["AG14":"settings"],["AG00":"recentThread0"],["AG00":"recentThread7"],["AG00":"unknown"]] {
            var value=before;value.taskCommands=[scopeA:map];settings.setLayout(value);XCTAssertEqual(settings.layout,before)
        }
        var conflict=before;conflict.taskMappings=[scopeA:["AG00":PanelRig.a]];conflict.taskCommands=[scopeA:["AG00":"settings"]]
        settings.setLayout(conflict);XCTAssertEqual(settings.layout,before)
        defaults.set(try JSONEncoder().encode(conflict),forKey:"layoutProfile.v1")
        let loaded=Settings(defaults:defaults);XCTAssertNil(loaded.layout.taskCommands);XCTAssertEqual(loaded.layout.taskMap(scope:scopeA)["AG00"],PanelRig.a)
        XCTAssertTrue(rig.mutations.isEmpty);record("U10 invalid or conflicting saved commands")
    }
    func testTargetChangeBeforeCommandPressCannotWriteToOldChat() async throws {
        await custom(["AG00":"composer.toggleFastMode"]);let press=try XCTUnwrap(panel.prepareTask(0))
        rig.ui["threadId"]=PanelRig.b;rig.ui["routeKey"]="thread:"+PanelRig.b
        await panel.refreshForeground();await settle();press();await settle()
        XCTAssertTrue(rig.mutations.isEmpty);record("U11 changed command target before press")
    }
    func testMissingRecentPositionAndSelectOnlyDoNotRunAnotherAction() async throws {
        await custom(["AG00":"recentThread6","AG01":"settings","AG02":"recentThread2"])
        XCTAssertNil(panel.taskRow(at:0));XCTAssertNil(panel.prepareTask(0))
        XCTAssertNil(panel.prepareTask(1,open:false))
        try XCTUnwrap(panel.prepareTask(2,open:false))();await settle()
        XCTAssertEqual(panel.selectedID,PanelRig.b);XCTAssertTrue(rig.mutations.isEmpty)
        record("U12 missing recent and first selection tap")
    }
    func testNewDraftCommandRemainsCommandAndNeverGuessesNewThreadAssignment() async throws {
        await custom(["AG00":"newTask"]);try XCTUnwrap(panel.prepareTask(0))();await settle()
        XCTAssertNil(panel.selectedID);XCTAssertEqual(rig.mutations.map(\.0),["new_keypad_thread"])
        XCTAssertEqual(settings.layout.taskCommandMap(scope:scopeA)["AG00"],"newTask")
        XCTAssertTrue(settings.layout.taskMap(scope:scopeA).isEmpty)
        record("U13 new draft command preserves explicit assignment")
    }
    func testImportedRecentCommandCapturesExactIDAndRejectsAccountChange() async throws {
        settings.saveKey("CODEX",value:KeyOverride(icon:"CODEX",action:["type":"command","commandId":"recentThread2"]))
        let press=try XCTUnwrap(panel.prepareBinding(panel.binding(for:"CODEX")))
        rig.rosterRows.reverse();await panel.refresh();press();await settle()
        XCTAssertEqual(rig.mutations.first?.1["thread_id"] as? String,PanelRig.b)
        let previous=try XCTUnwrap(panel.prepareBinding(panel.binding(for:"CODEX")))
        rig.calls=[];rig.rosterScope=scopeB;await panel.refresh();previous();await settle()
        XCTAssertTrue(rig.mutations.isEmpty)
        XCTAssertNil(panel.prepareBinding(["type":"command","commandId":"recentThread7"]))
        record("U15 imported recent command exact target and account guard")
    }
}
