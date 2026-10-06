import XCTest
@testable import MicroPanelModel

@MainActor final class PriorityTaskScenarioTests:XCTestCase {
    var suite:String!,defaults:UserDefaults!,settings:Settings!,rig:PanelRig!,panel:MicroModel!
    func id(_ n:Int)->String {String(format:"01000000-0000-0000-0000-%012d",n)}
    func row(_ n:Int,_ type:String="idle",time:Double=0,unread:Bool=false,flags:[String]=[])->[String:Any] {
        ["id":id(n),"title":"Same title","status":["type":type,"activeFlags":flags],"recencyAt":time,"hasUnreadTurn":unread]
    }
    override func setUp() async throws {
        suite="MicroPriorityTasks."+UUID().uuidString;defaults=UserDefaults(suiteName:suite)!
        settings=Settings(defaults:defaults);rig=PanelRig();panel=MicroModel(settings:settings,client:rig)
    }
    override func tearDown() async throws {panel.stop();defaults.removePersistentDomain(forName:suite)}
    func ready(_ rows:[[String:Any]]) async {
        rig.rosterRows=rows;var profile=settings.layout;profile.agentSource="priority";settings.setLayout(profile)
        panel.preferencesChanged();await panel.refresh();await settle()
    }
    func settle() async {
        for _ in 0..<250 {await Task.yield();if !panel.refreshing && !panel.opening && !panel.controlling {return};try? await Task.sleep(for:.milliseconds(1))}
    }
    func record(_ scenario:String) {
        ReplayTrace.emit("PRIORITY-TASK-TRACE",["scenario":scenario,"complete":panel.priorityComplete,
            "slots":panel.displayedThreads.map(\.id),"mutations":rig.mutations.map(\.0)])
    }
    func testRanksAttentionBeforeRecencyWithoutChangingRunningUnreadLamp() async {
        await ready([row(1,"active",time:100),row(2,"active",time:20,unread:true),row(3,"active",time:10,flags:["waitingOnUserInput"]),row(4,"systemError",time:200),row(5,time:300)])
        XCTAssertEqual(panel.displayedThreads.map(\.id),[id(3),id(2),id(1),id(5),id(4)])
        let running=panel.threads.first {$0.id == id(2)}!;XCTAssertEqual(panel.signal(for:running),.running)
        XCTAssertEqual(panel.attention(for:running).rawValue,"unread");record("Q01 attention versus lamp")
    }
    func testCandidateAfterOneHundredCanEnterFirstKeyAndOpenExactID() async throws {
        var rows=(1...120).map {row($0,time:Double(200-$0))};rows[114]=row(115,"active",time:1,flags:["waitingOnApproval"])
        await ready(rows);XCTAssertEqual(panel.taskRow(at:0)?.id,id(115));XCTAssertEqual(panel.displayedThreads.count,14)
        XCTAssertTrue(rig.calls.contains {$0.0 == "list_keypad_threads" && $0.1["include_priority"] as? Bool == true})
        try XCTUnwrap(panel.prepareTask(0))();await settle()
        XCTAssertEqual(rig.mutations.filter {$0.0 == "open_keypad_thread"}.first?.1["thread_id"] as? String,id(115));record("Q02 candidate beyond first page")
    }
    func testApprovalAndQuestionShareWaitingRankAndTiesRetainCatalogOrder() async {
        await ready([row(1,"active",time:2,flags:["waitingOnUserInput"]),row(2,"active",time:5,flags:["waitingOnApproval"]),row(3,"active",time:5,flags:["waitingOnUserInput"]),row(4,"active",time:8,unread:true)])
        XCTAssertEqual(panel.displayedThreads.map(\.id),[id(2),id(3),id(1),id(4)]);record("Q03 waiting recency and stable ties")
    }
    func testLiveAttentionPromotesOlderRowAndStreamLossRestoresCatalogRank() async {
        await ready((1...20).map {row($0,time:Double(30-$0))})
        rig.activity["attention"]=[id(20):"waiting"];rig.activity["signals"]=[id(20):"question"]
        await panel.refreshActivity();XCTAssertEqual(panel.taskRow(at:0)?.id,id(20))
        rig.failure="get_keypad_activity";await panel.refreshActivity();XCTAssertEqual(panel.taskRow(at:0)?.id,id(1))
        record("Q04 live older attention and lost stream")
    }
    func testHoverFreezesExactTaskUntilReleaseDespiteNewPriority() async throws {
        await ready([row(1,time:2),row(2,time:1)]);panel.setInteraction("hover",active:true)
        let press=try XCTUnwrap(panel.prepareTask(0));rig.activity["attention"]=[id(2):"waiting"]
        await panel.refreshActivity();XCTAssertEqual(panel.taskRow(at:0)?.id,id(1));press();await settle()
        XCTAssertEqual(rig.mutations.filter {$0.0 == "open_keypad_thread"}.first?.1["thread_id"] as? String,id(1))
        panel.setInteraction("hover",active:false);XCTAssertEqual(panel.taskRow(at:0)?.id,id(2));record("Q05 stable hovered identity")
    }
    func testIncompleteCatalogAndAccountChangeRetireOldPriorityPress() async throws {
        await ready([row(1,"active")]);let press=try XCTUnwrap(panel.prepareTask(0))
        rig.priorityComplete=false;await panel.refresh();press()
        XCTAssertNil(panel.prepareTask(0));XCTAssertTrue(panel.displayedThreads.isEmpty);XCTAssertTrue(rig.mutations.isEmpty)
        rig.priorityComplete=true;rig.rosterScope=String(repeating:"b",count:64);await panel.refresh();press()
        XCTAssertTrue(rig.mutations.isEmpty);record("Q06 incomplete or changed account")
    }
    func testPriorityNeverUsesAnAttentionSnapshotFromAnotherContext() async {
        await ready([row(1,time:2),row(2,time:1)])
        rig.activity["attention"]=[id(2):"waiting"];await panel.refreshActivity();XCTAssertEqual(panel.taskRow(at:0)?.id,id(2))
        rig.activity["contextID"]="wrong-account";await panel.refreshActivity()
        XCTAssertEqual(panel.taskRow(at:0)?.id,id(1));record("Q07 wrong activity context")
    }
    func testSameConnectionAccountChangeClearsAttentionAndDiscardsLateOldRead() async {
        await ready([row(1,time:2),row(2,time:1)])
        rig.activity["attention"]=[id(2):"waiting"];await panel.refreshActivity();XCTAssertEqual(panel.taskRow(at:0)?.id,id(2))
        var changed=false
        rig.onCall={operation in
            if operation == "get_keypad_activity",!changed {
                changed=true;self.rig.rosterScope=String(repeating:"b",count:64);await self.panel.refresh()
            }
        }
        await panel.refreshActivity()
        XCTAssertEqual(panel.taskRow(at:0)?.id,id(1));XCTAssertTrue(rig.mutations.isEmpty)
        record("Q09 same connection account change and late activity")
    }
    func testReturningToRecentRestoresCatalogOrderAndStopsPriorityQuery() async {
        await ready([row(1,time:2),row(2,"active",time:1,flags:["waitingOnApproval"])])
        XCTAssertEqual(panel.taskRow(at:0)?.id,id(2))
        var profile=settings.layout;profile.agentSource="recent";settings.setLayout(profile);panel.preferencesChanged();await panel.refresh();await settle()
        XCTAssertEqual(panel.displayedThreads.map(\.id),[id(1),id(2)]);XCTAssertFalse(panel.priorityComplete)
        XCTAssertNil(rig.calls.last {$0.0 == "list_keypad_threads"}?.1["include_priority"]);record("Q08 return to recent")
    }
}
