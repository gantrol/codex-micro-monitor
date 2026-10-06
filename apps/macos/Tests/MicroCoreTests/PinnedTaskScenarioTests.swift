import XCTest
@testable import MicroPanelModel

@MainActor final class PinnedTaskScenarioTests:XCTestCase {
    let old="01000000-0000-0000-0000-000000000003"
    var suite:String!,defaults:UserDefaults!,settings:Settings!,rig:PanelRig!,panel:MicroModel!
    override func setUp() async throws {
        suite="MicroPinnedTasks."+UUID().uuidString;defaults=UserDefaults(suiteName:suite)!
        settings=Settings(defaults:defaults);rig=PanelRig();panel=MicroModel(settings:settings,client:rig)
        rig.pinnedRows=[["id":old,"title":"Same title"],["id":PanelRig.b,"title":"Same title"]]
        await panel.refresh();await panel.refreshForeground()
    }
    override func tearDown() async throws {panel.stop();defaults.removePersistentDomain(forName:suite)}
    func settle() async {
        for _ in 0..<250 {await Task.yield();if !panel.refreshing && !panel.opening && !panel.controlling {return};try? await Task.sleep(for:.milliseconds(1))}
    }
    func source(_ value:String) async {
        var profile=settings.layout;profile.agentSource=value;settings.setLayout(profile);panel.preferencesChanged()
        await panel.refresh();await settle()
    }
    func record(_ scenario:String) {
        ReplayTrace.emit("PINNED-TASK-TRACE",["scenario":scenario,"source":settings.layout.agentSource,
            "available":panel.pinnedAvailable,"slots":panel.displayedThreads.map(\.id),"mutations":rig.mutations.map(\.0)])
    }
    func testPinnedSourceKeepsServerOrderAndOpensExactOlderID() async throws {
        await source("pinned")
        XCTAssertEqual(panel.displayedThreads.map(\.id),[old,PanelRig.b])
        XCTAssertTrue(rig.calls.contains {$0.0 == "list_keypad_threads" && $0.1["include_pinned"] as? Bool == true})
        let press=try XCTUnwrap(panel.prepareTask(0));press();await settle()
        XCTAssertEqual(rig.mutations.filter {$0.0 == "open_keypad_thread"}.first?.1["thread_id"] as? String,old)
        record("S01 server order and older exact ID")
    }
    func testEmptyOrUnsupportedPinsNeverFallBackToRecentChats() async {
        await source("pinned");rig.pinnedRows=[];await panel.refresh()
        XCTAssertTrue(panel.pinnedAvailable);XCTAssertTrue(panel.displayedThreads.isEmpty)
        rig.pinnedRows=[["id":old,"title":"Same title"]];rig.pinnedAvailable=false;await panel.refresh()
        XCTAssertTrue(panel.connected);XCTAssertFalse(panel.pinnedAvailable);XCTAssertNil(panel.prepareTask(0));XCTAssertTrue(panel.displayedThreads.isEmpty)
        XCTAssertTrue(rig.mutations.isEmpty);record("S02 empty and unsupported pins")
    }
    func testHeldPressAndNewPressAfterReorderCannotUseFrozenSlot() async throws {
        await source("pinned");panel.setInteraction("held",active:true)
        let press=try XCTUnwrap(panel.prepareTask(0));rig.pinnedRows.reverse();await panel.refresh();press()
        XCTAssertEqual(panel.taskRow(at:0)?.id,old);XCTAssertNil(panel.prepareTask(0));XCTAssertTrue(rig.mutations.isEmpty)
        panel.setInteraction("held",active:false);XCTAssertEqual(panel.taskRow(at:0)?.id,PanelRig.b)
        record("S03 reordered held slot")
    }
    func testUnpinDuringHoverCannotOpenAnOldRecentRow() async throws {
        await source("pinned");panel.setInteraction("hover",active:true)
        let press=try XCTUnwrap(panel.prepareTask(1));rig.pinnedRows.removeLast();await panel.refresh();press()
        XCTAssertTrue(panel.threads.contains {$0.id == PanelRig.b});XCTAssertNil(panel.prepareTask(1));XCTAssertTrue(rig.mutations.isEmpty)
        panel.setInteraction("hover",active:false);XCTAssertNil(panel.taskRow(at:1));record("S04 unpinned recent row")
    }
    func testAccountChangeAndUnknownIdentityRetirePinnedPress() async throws {
        await source("pinned");let press=try XCTUnwrap(panel.prepareTask(0))
        rig.rosterScope=String(repeating:"b",count:64);rig.pinnedRows=[];await panel.refresh();press()
        XCTAssertTrue(rig.mutations.isEmpty);XCTAssertTrue(panel.displayedThreads.isEmpty)
        rig.rosterScope=nil;rig.pinnedRows=[["id":old,"title":"Same title"]];await panel.refresh()
        XCTAssertFalse(panel.pinnedAvailable);XCTAssertNil(panel.prepareTask(0));record("S05 changed or unknown identity")
    }
    func testSwitchSourceDuringReadDoesNotInstallLatePins() async {
        await source("pinned");var changed=false
        rig.onCall={operation in
            if operation == "list_keypad_threads",!changed {
                changed=true;var profile=self.settings.layout;profile.agentSource="recent";self.settings.setLayout(profile);self.panel.preferencesChanged()
            }
        }
        await panel.refresh();await settle();await panel.refresh()
        XCTAssertEqual(panel.displayedThreads.map(\.id),[PanelRig.a,PanelRig.b]);XCTAssertTrue(panel.pinnedThreads.isEmpty)
        record("S06 late pin result after source change")
    }
    func testPinnedPreferenceRestoresAndQueriesFreshDataAfterRestart() async {
        await source("pinned");panel.stop()
        settings=Settings(defaults:defaults);panel=MicroModel(settings:settings,client:rig);rig.pinnedRows.reverse()
        await panel.refresh();XCTAssertEqual(settings.layout.agentSource,"pinned")
        XCTAssertEqual(panel.displayedThreads.map(\.id),[PanelRig.b,old]);XCTAssertTrue(rig.mutations.isEmpty)
        record("S07 restart with fresh order")
    }
    func testMalformedDuplicatePinsAndFailedCatalogClearControls() async {
        await source("pinned");rig.pinnedRows += rig.pinnedRows;await panel.refresh()
        XCTAssertFalse(panel.connected);XCTAssertNil(panel.prepareTask(0));XCTAssertTrue(panel.displayedThreads.isEmpty)
        rig.pinnedRows=[];rig.failure="list_keypad_threads";await panel.refresh()
        XCTAssertFalse(panel.pinnedAvailable);XCTAssertTrue(rig.mutations.isEmpty);record("S08 malformed or failed catalog")
    }
}
