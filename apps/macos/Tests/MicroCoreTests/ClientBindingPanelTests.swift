import XCTest
@testable import MicroPanelModel

@MainActor final class ClientBindingPanelTests:XCTestCase {
    var panel:MicroModel!,rig:PanelRig!,defaults:UserDefaults!,suite:String!
    var now:TimeInterval=10
    let server="01000000-0000-0000-0000-000000000003"
    var client:String {"client-new-thread:"+PanelRig.a}
    override func setUp() async throws {
        suite="MicroClientBinding."+UUID().uuidString;defaults=UserDefaults(suiteName:suite);rig=PanelRig()
        panel=MicroModel(settings:Settings(defaults:defaults),client:rig,observationUptime:{self.now})
        await panel.refresh()
        rig.ui=["available":true,"nativeComposer":true,"selectionKnown":true,"draft":false,"routeKey":"client:"+client,
                "clientThreadId":client,"targetToken":"composer-a","settings":rig.thread,"draftPlanAvailable":true]
        rig.clientBinding=["resolved":true,"clientThreadId":client,"threadId":server,"rosterScope":rig.rosterScope!,"contextID":"account-a","thread":["id":server,"title":"Same title"]]
    }
    override func tearDown() async throws {panel.stop();defaults.removePersistentDomain(forName:suite)}
    func trace(_ id:String,_ values:[String:Any]=[:]) {ReplayTrace.emit("CLIENT-BINDING-TRACE",values.merging(["scenario":id]) {a,_ in a})}
    func testVerifiedBindingExposesIDAndChoiceWithoutServerControlLease() async throws {
        await panel.refreshForeground()
        XCTAssertEqual(panel.currentThreadID,server);XCTAssertEqual(panel.displayedThreadID,server)
        XCTAssertNil(panel.selectedID);XCTAssertTrue(panel.isNativeComposer);XCTAssertFalse(panel.isDraft)
        XCTAssertEqual(panel.controlTarget?.threadID,"native-composer");XCTAssertFalse(panel.canFork)
        XCTAssertEqual(panel.taskChoices.first?.id,server);XCTAssertTrue(rig.mutations.isEmpty)
        panel.assignTask(2,thread:server)
        XCTAssertEqual(panel.preferences.layout.taskMap(scope:rig.rosterScope)[TaskSlots.ids[2]],server)
        trace("Y07 bound current identity remains settings-only",["currentID":panel.currentThreadID ?? "none","controlID":panel.controlTarget?.threadID ?? "none"])
    }
    func testFailedOrUnresolvedLookupClearsPriorBinding() async {
        await panel.refreshForeground();XCTAssertEqual(panel.currentThreadID,server)
        rig.clientBinding=["resolved":false];await panel.refreshForeground();XCTAssertNil(panel.currentThreadID)
        rig.failure="get_keypad_client_thread";await panel.refreshForeground();XCTAssertNil(panel.displayedThreadID)
        XCTAssertFalse(panel.isDraft);XCTAssertTrue(panel.isNativeComposer);XCTAssertTrue(rig.mutations.isEmpty)
        trace("Y08 unresolved and failed lookup discard binding")
    }
    func testRouteChangesWhileLookupRunsRejectLateResult() async {
        rig.onCall={ [weak self] operation in
            guard let self,operation == "get_keypad_client_thread" else {return}
            self.rig.ui["targetToken"]="composer-b";self.rig.ui["clientThreadId"]="client-new-thread:"+PanelRig.b
            self.rig.ui["routeKey"]="client:client-new-thread:"+PanelRig.b
        }
        await panel.refreshForeground();XCTAssertNil(panel.currentThreadID);XCTAssertTrue(rig.mutations.isEmpty)
        trace("Y09 native window changes during lookup")
    }
    func testWrongScopeContextClientAndReadbackNeverExposeID() async {
        let good=rig.clientBinding
        for (key,value) in [("rosterScope","wrong"),("contextID","old"),("clientThreadId","client-new-thread:"+PanelRig.b),("threadId",PanelRig.b)] {
            rig.clientBinding=good;rig.clientBinding[key]=value
            await panel.refreshForeground();XCTAssertNil(panel.currentThreadID)
        }
        trace("Y10 mismatched lookup envelope",["rejected":4])
    }
    func testBindingExpiresAndStopDiscardsPendingResult() async {
        await panel.refreshForeground();XCTAssertEqual(panel.currentThreadID,server)
        now += 2;XCTAssertNil(panel.currentThreadID);XCTAssertFalse(panel.taskChoices.contains {$0.id == server})
        rig.onCall={ [weak self] operation in if operation == "get_keypad_client_thread" {self?.panel.stop()} }
        await panel.refreshForeground();XCTAssertNil(panel.currentThreadID);XCTAssertNil(panel.controlTarget)
        trace("Y11 stale observation and stopped lifecycle")
    }
    func testHomeDraftNeverLooksUpPersistedGlobalIdentity() async {
        rig.ui=["available":true,"draft":true,"routeAvailable":true,"selectionKnown":true,"routeKey":"draft","targetToken":"home","settings":rig.thread]
        await panel.refreshForeground();XCTAssertTrue(panel.isDraft);XCTAssertNil(panel.currentThreadID)
        XCTAssertFalse(rig.calls.contains {$0.0 == "get_keypad_client_thread"})
        trace("Y12 home draft does not infer client identity")
    }
}
