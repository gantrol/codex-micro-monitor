import XCTest
@testable import MicroPanelModel

@MainActor final class TaskMappingScenarioTests:XCTestCase {
    let scopeA=String(repeating:"a",count:64),scopeB=String(repeating:"b",count:64)
    let old="01000000-0000-0000-0000-000000000003",missing="01000000-0000-0000-0000-000000000004"
    var suite:String!,defaults:UserDefaults!,settings:Settings!,rig:PanelRig!,panel:MicroModel!
    override func setUp() async throws {
        suite="MicroTaskMappingTests."+UUID().uuidString;defaults=UserDefaults(suiteName:suite)!
        settings=Settings(defaults:defaults);rig=PanelRig();panel=MicroModel(settings:settings,client:rig)
        rig.mappedRows=[["id":old,"title":"Same title","status":["type":"idle"]]]
        await panel.refresh();await panel.refreshForeground();await settle()
    }
    override func tearDown() async throws {panel.stop();defaults.removePersistentDomain(forName:suite)}
    func settle() async {
        for _ in 0..<250 {
            await Task.yield()
            if !panel.refreshing && !panel.opening && !panel.controlling && panel.desktopConnected {return}
            try? await Task.sleep(for:.milliseconds(1))
        }
    }
    func custom(_ map:[String:String],scope:String?=nil) async {
        var profile=settings.layout;profile.agentSource="custom"
        var maps=profile.taskMappings ?? [:];maps[scope ?? scopeA]=map;profile.taskMappings=maps
        settings.setLayout(profile);panel.preferencesChanged();await panel.refresh();await settle()
    }
    func record(_ scenario:String) {
        ReplayTrace.emit("TASK-MAPPING-TRACE",["scenario":scenario,"source":settings.layout.agentSource,
            "slots":panel.displayedTaskSlots.map {$0?.id ?? "empty"},"mutations":rig.mutations.map(\.0)])
    }
    func testSparseMappingKeepsFourteenStableSlotsAndResolvesOldExactChat() async throws {
        await custom(["AG00":PanelRig.b,"AG03":old,"AG13":PanelRig.a])
        XCTAssertEqual(panel.displayedTaskSlots.count,14);XCTAssertEqual(panel.taskRow(at:0)?.id,PanelRig.b)
        XCTAssertNil(panel.taskRow(at:1));XCTAssertNil(panel.taskRow(at:2));XCTAssertEqual(panel.taskRow(at:3)?.id,old)
        XCTAssertEqual(panel.taskRow(at:13)?.id,PanelRig.a)
        rig.rosterRows.reverse();await panel.refresh()
        XCTAssertEqual(panel.taskRow(at:0)?.id,PanelRig.b);XCTAssertEqual(panel.taskRow(at:3)?.id,old)
        rig.calls=[];try XCTUnwrap(panel.prepareTask(3))();await settle()
        XCTAssertEqual(rig.mutations.map(\.0),["open_keypad_thread"]);XCTAssertEqual(rig.mutations[0].1["thread_id"] as? String,old)
        record("R01 sparse slots and older exact chat")
    }
    func testMissingTaskKeepsEmptyPositionAndItsSavedID() async {
        await custom(["AG00":missing,"AG01":old,"AG02":PanelRig.a])
        XCTAssertNil(panel.taskRow(at:0));XCTAssertNil(panel.prepareTask(0));XCTAssertEqual(panel.taskRow(at:1)?.id,old)
        XCTAssertEqual(settings.layout.taskMap(scope:scopeA)["AG00"],missing)
        record("R02 missing task keeps position")
    }
    func testSavedMappingsRestoreAfterModelRestartWithoutUsingOldProcessContext() async {
        await custom(["AG05":old]);panel.stop()
        settings=Settings(defaults:defaults);panel=MicroModel(settings:settings,client:rig);rig.calls=[]
        await panel.refresh();await panel.refreshForeground();await settle()
        XCTAssertEqual(panel.taskRow(at:5)?.id,old)
        let lists=rig.calls.filter {$0.0 == "list_keypad_threads"}
        XCTAssertEqual(lists.count,2);XCTAssertNil(lists[0].1["roster_scope"])
        XCTAssertEqual(lists[1].1["roster_scope"] as? String,scopeA)
        XCTAssertEqual(lists[1].1["mapped_thread_ids"] as? [String],[old])
        record("R03 restart resolves saved scope")
    }
    func testAccountChangeCannotReuseAnotherAccountsSlotsOrCapturedPress() async throws {
        await custom(["AG00":PanelRig.a])
        let action=try XCTUnwrap(panel.prepareTask(0))
        rig.rosterScope=scopeB;rig.calls=[];await panel.refresh();action();await settle()
        XCTAssertNil(panel.taskRow(at:0));XCTAssertTrue(rig.mutations.isEmpty)
        XCTAssertEqual(settings.layout.taskMap(scope:scopeA)["AG00"],PanelRig.a)
        await custom(["AG00":PanelRig.b],scope:scopeB)
        XCTAssertEqual(panel.taskRow(at:0)?.id,PanelRig.b)
        rig.rosterScope=scopeA;await panel.refresh();XCTAssertEqual(panel.taskRow(at:0)?.id,PanelRig.a)
        record("R04 account isolation and return")
    }
    func testEditingHeldKeyCancelsOldPressEvenIfBothChatsRemainAvailable() async throws {
        await custom(["AG00":PanelRig.a]);panel.setInteraction("fixture-press",active:true)
        let action=try XCTUnwrap(panel.prepareTask(0));rig.calls=[]
        panel.assignTask(0,thread:PanelRig.b);await settle();action();await settle()
        XCTAssertTrue(rig.mutations.isEmpty)
        XCTAssertNil(panel.prepareTask(0));XCTAssertFalse(panel.canUseTask(0))
        panel.setInteraction("fixture-press",active:false)
        XCTAssertEqual(panel.taskRow(at:0)?.id,PanelRig.b);record("R05 edit while held")
    }
    func testAccountChangeWhileHoveringCannotPrepareAnotherPressFromFrozenOldSlot() async throws {
        await custom(["AG00":PanelRig.a]);panel.setInteraction("fixture-hover",active:true)
        let previous=try XCTUnwrap(panel.prepareTask(0));rig.rosterScope=scopeB;rig.calls=[]
        await panel.refresh();previous()
        XCTAssertNil(panel.prepareTask(0));XCTAssertFalse(panel.canUseTask(0));XCTAssertTrue(rig.mutations.isEmpty)
        panel.setInteraction("fixture-hover",active:false);XCTAssertNil(panel.taskRow(at:0))
        record("R11 account change during hover")
    }
    func testLateOldMappingReadCannotOverwriteNewSelection() async {
        await custom(["AG00":old])
        var changed=false
        rig.onCall={operation in
            if operation == "list_keypad_threads",!changed {
                changed=true;self.settings.saveTask(0,thread:PanelRig.b,scope:self.scopeA);self.panel.preferencesChanged()
            }
        }
        await panel.refresh();await settle()
        XCTAssertEqual(panel.taskRow(at:0)?.id,PanelRig.b)
        XCTAssertEqual(settings.layout.taskMap(scope:scopeA)["AG00"],PanelRig.b)
        record("R06 late mapping read")
    }
    func testExplicitRecentSnapshotAndClearNeverDispatchOrFillEmptySlot() async {
        panel.captureRecentTaskLayout();await settle()
        XCTAssertEqual(settings.layout.agentSource,"custom")
        XCTAssertEqual(panel.taskRow(at:0)?.id,PanelRig.a);XCTAssertEqual(panel.taskRow(at:1)?.id,PanelRig.b)
        panel.assignTask(0,thread:nil);await settle()
        XCTAssertNil(panel.taskRow(at:0));XCTAssertEqual(panel.taskRow(at:1)?.id,PanelRig.b)
        XCTAssertTrue(rig.mutations.isEmpty);record("R07 capture and clear")
    }
    func testUnknownAccountCannotReadAssignOrRestoreMappings() async {
        await custom(["AG00":PanelRig.a]);rig.rosterScope=nil;await panel.refresh()
        panel.assignTask(0,thread:PanelRig.b);panel.captureRecentTaskLayout();await settle()
        XCTAssertNil(panel.taskRow(at:0));XCTAssertNil(panel.prepareTask(0))
        XCTAssertEqual(settings.layout.taskMap(scope:scopeA)["AG00"],PanelRig.a)
        record("R08 unknown account")
    }
    func testLocalMappingFailureDoesNotFallBackToRecentSlot() async {
        await custom(["AG00":old]);rig.failure="list_keypad_threads";await panel.refresh()
        XCTAssertNil(panel.taskRow(at:0));XCTAssertNil(panel.prepareTask(0));XCTAssertFalse(panel.connected)
        record("R09 failed observation")
    }
    func testLegacyLayoutDecodesWithoutLosingKeyOverridesAndRejectsInvalidNewMappings() throws {
        let legacy:[String:Any]=["agentSource":"priority","singleTapAgentKeys":false,"keys":["ACT06":["icon":"MIND+"]]]
        defaults.set(try JSONSerialization.data(withJSONObject:legacy),forKey:"layoutProfile.v1")
        let loaded=Settings(defaults:defaults)
        XCTAssertEqual(loaded.layout.agentSource,"priority");XCTAssertFalse(loaded.layout.singleTapAgentKeys)
        XCTAssertEqual(loaded.layout.keys["ACT06"]?.icon,"MIND+");XCTAssertNil(loaded.layout.taskMappings)
        let before=loaded.layout
        for map in [["AG14":PanelRig.a],["AG00":"invalid-id"]] {
            var invalid=before;invalid.taskMappings=[scopeA:map];loaded.setLayout(invalid);XCTAssertEqual(loaded.layout,before)
        }
        loaded.saveTask(-1,thread:PanelRig.a,scope:scopeA);loaded.saveTask(14,thread:PanelRig.a,scope:scopeA)
        loaded.saveTask(0,thread:PanelRig.a,scope:"wrong-account")
        XCTAssertEqual(loaded.layout,before);record("R10 legacy preferences and invalid mappings")
    }
}
