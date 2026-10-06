import XCTest
@testable import MicroPanelModel

@MainActor final class TaskLampScenarioTests:XCTestCase {
    var suite:String!,defaults:UserDefaults!,rig:PanelRig!,panel:MicroModel!
    var now:TimeInterval=100
    override func setUp() async throws {
        suite="MicroTaskLamps."+UUID().uuidString;defaults=UserDefaults(suiteName:suite)!
        rig=PanelRig();rig.rosterRows=[PanelRig.a,PanelRig.b].map {
            ["id":$0,"title":"Same title","status":["type":"idle"],"hasUnreadTurn":true]
        }
        rig.thread["runtimeStatus"]=["type":"idle"];rig.thread["hasUnreadTurn"]=true
        rig.ui["appFocused"]=true;rig.ui["foreground"]=true
        panel=MicroModel(settings:Settings(defaults:defaults),client:rig,observationUptime:{[unowned self] in self.now})
        await panel.refresh();await panel.refreshForeground();await settle()
    }
    override func tearDown() async throws {panel.stop();defaults.removePersistentDomain(forName:suite)}
    func settle() async {
        for _ in 0..<250 {await Task.yield();if !panel.refreshing && panel.desktopConnected {return};try? await Task.sleep(for:.milliseconds(1))}
    }
    var a:ThreadRow {panel.threads.first {$0.id == PanelRig.a}!}
    func record(_ scenario:String) {
        XCTAssertTrue(rig.mutations.isEmpty)
        ReplayTrace.emit("LAMP-TRACE",["scenario":scenario,"raw":panel.signal(for:a).rawValue,
            "display":panel.displaySignal(for:a).rawValue,"attention":panel.attention(for:a).rawValue,"mutations":rig.mutations.map(\.0)])
    }
    func testFocusedExactChatHidesOnlyUnreadPresentationWithoutAcknowledging() {
        XCTAssertEqual(panel.contextSource,.foreground);XCTAssertEqual(panel.selectedID,PanelRig.a)
        XCTAssertEqual(panel.signal(for:a),.unread);XCTAssertEqual(panel.displaySignal(for:a),.idle)
        XCTAssertEqual(panel.attention(for:a).rawValue,"unread")
        XCTAssertEqual(panel.displaySignal(for:panel.threads.first {$0.id == PanelRig.b}!),.unread)
        record("L01 focused exact unread preserves truth and other chat")
    }
    func testRememberedSubmissionFocusAndOldBridgeCannotHideUnread() async {
        for focused:Bool? in [false,nil] {
            rig.ui["appFocused"]=focused;await panel.refreshForeground()
            XCTAssertEqual(panel.foreground["foreground"] as? Bool,true)
            XCTAssertEqual(panel.displaySignal(for:a),.unread)
        }
        record("L02 remembered focus and absent physical focus")
    }
    func testWrongMissingOrUnknownRouteCannotHideUnread() async {
        let original=rig.ui
        for changed:[String:Any] in [
            ["routeKey":"thread:"+PanelRig.b],["routeKey":NSNull()],
            ["routeAvailable":false],["selectionKnown":false],["available":false]] {
            rig.ui=original.merging(changed) {_,new in new};await panel.refreshForeground()
            XCTAssertEqual(panel.displaySignal(for:a),.unread,"\(changed)")
        }
        record("L03 contradictory or unavailable route")
    }
    func testDraftModalVisibleAndManualSelectionDoNotHideUnread() async {
        for route:[String:Any] in [
            ["available":true,"selectionKnown":true,"routeAvailable":true,"draft":true,"routeKey":"draft","appFocused":true],
            ["available":false,"selectionKnown":true,"routeKey":"modal:file-picker","appFocused":true],
            ["available":false,"appFocused":true]] {
            rig.ui=route;await panel.refreshForeground();await panel.refreshActivity();await settle()
            XCTAssertEqual(panel.displaySignal(for:a),.unread)
        }
        panel.select(PanelRig.a,source:.selected);await settle()
        XCTAssertEqual(panel.displaySignal(for:a),.unread)
        record("L04 draft modal visible and manual contexts")
    }
    func testObservationExpiresAtTwoSecondsAndRejectsClockRegression() async {
        now=101.999;XCTAssertEqual(panel.displaySignal(for:a),.idle)
        now=102;XCTAssertEqual(panel.displaySignal(for:a),.unread)
        now=99;XCTAssertEqual(panel.displaySignal(for:a),.unread)
        now=103;await panel.refreshForeground();XCTAssertEqual(panel.displaySignal(for:a),.idle)
        record("L05 observation age and refreshed focus")
    }
    func testSharedCatalogAndSelectedStateHonorErrorApprovalQuestionPrecedence() async {
        let cases:[(String,Bool,Bool,Bool,TaskSignal)]=[
            ("systemError",true,true,true,.error),("active",true,true,true,.waiting),
            ("active",true,false,true,.question),("active",false,false,true,.running),
            ("idle",false,false,true,.unread),("idle",false,false,false,.idle),
            ("notLoaded",false,false,false,.unknown)]
        rig.ui["appFocused"]=false;await panel.refreshForeground()
        for (type,question,approval,unread,expected) in cases {
            let flags=(question ? ["waitingOnUserInput"]:[])+(approval ? ["waitingOnApproval"]:[])
            rig.rosterRows[1]["status"]=["type":type,"activeFlags":flags];rig.rosterRows[1]["hasUnreadTurn"]=unread
            rig.thread["runtimeStatus"]=["type":type];rig.thread["hasPendingQuestion"]=question
            rig.thread["approvals"]=approval ? [["id":"approval"]]:[];rig.thread["hasUnreadTurn"]=unread
            await panel.refresh();await settle()
            XCTAssertEqual(panel.signal(for:a),expected)
            XCTAssertEqual(panel.signal(for:panel.threads.first {$0.id == PanelRig.b}!),expected)
            XCTAssertEqual(panel.displaySignal(for:a),expected)
        }
        record("L06 catalog and selected state precedence")
    }
    func testFocusedChatStillShowsLiveErrorApprovalQuestionAndRunning() async {
        for signal in [TaskSignal.error,.waiting,.question,.running] {
            rig.activity["signals"]=[PanelRig.a:signal.rawValue]
            rig.activity["revision"]=(rig.activity["revision"] as? Int ?? 0)+1;await panel.refreshActivity()
            XCTAssertEqual(panel.displaySignal(for:a),signal)
        }
        record("L07 foreground never masks actionable or running lamps")
    }
    func testRemovedAndDisconnectedRowsDoNotReuseCachedActivityLamp() async {
        let old=a;rig.activity["signals"]=[PanelRig.a:"error"];await panel.refreshActivity()
        XCTAssertEqual(panel.signal(for:old),.error)
        rig.rosterRows.removeAll {$0["id"] as? String == PanelRig.a};await panel.refresh()
        XCTAssertEqual(panel.signal(for:old),.unknown)
        rig.rosterRows.append(["id":PanelRig.a,"title":"Same title"]);await panel.refresh()
        rig.failure="list_keypad_threads";await panel.refresh()
        XCTAssertEqual(panel.signal(for:old),.unknown)
        XCTAssertTrue(rig.mutations.isEmpty)
        ReplayTrace.emit("LAMP-TRACE",["scenario":"L08 removed or disconnected row retires lamp","display":panel.displaySignal(for:old).rawValue,"mutations":[]])
    }
}
