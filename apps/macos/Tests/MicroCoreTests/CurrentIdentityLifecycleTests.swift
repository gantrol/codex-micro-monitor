import XCTest
@testable import MicroPanelModel

@MainActor final class CurrentIdentityLifecycleTests:XCTestCase {
    var suite:String!,defaults:UserDefaults!,rig:PanelRig!,panel:MicroModel!
    var now:TimeInterval=100
    override func setUp() async throws {
        suite="CurrentIdentityLifecycle."+UUID().uuidString;defaults=UserDefaults(suiteName:suite)!
        rig=PanelRig();panel=MicroModel(settings:Settings(defaults:defaults),client:rig,observationUptime:{[unowned self] in self.now})
        await panel.refresh();await panel.refreshForeground();await panel.refreshActivity();await settle()
        XCTAssertEqual(panel.currentThreadID,PanelRig.a)
    }
    override func tearDown() async throws {panel.stop();defaults.removePersistentDomain(forName:suite)}
    func settle() async {
        for _ in 0..<200 {
            await Task.yield()
            if !panel.opening && !panel.controlling && (panel.selectedID == nil || panel.desktopConnected) {return}
            try? await Task.sleep(for:.milliseconds(1))
        }
        XCTFail("Panel did not settle")
    }
    var draft:[String:Any] {["available":true,"routeAvailable":true,"selectionKnown":true,"draft":true,"routeKey":"draft:/","targetToken":"new-draft","draftFastAvailable":true,"draftPlanAvailable":true,"draftReasoningAvailable":true,"settings":rig.thread]}
    func assertNoOldTarget(file:StaticString=#filePath,line:UInt=#line) {
        XCTAssertNil(panel.currentThreadID,file:file,line:line);XCTAssertNil(panel.displayedThreadID,file:file,line:line)
        XCTAssertNotEqual(panel.controlTarget?.threadID,PanelRig.a,file:file,line:line)
    }
    func record(_ id:String) {ReplayTrace.emit("CURRENT-IDENTITY-TRACE",["scenario":id,"currentID":panel.currentThreadID ?? NSNull() as Any,"source":panel.contextSource.rawValue,"draft":panel.isDraft,"mutations":rig.mutations.map(\.0)])}
    func testNewRequestFollowedByRepeatedOldNativeAndIPCCannotRestoreOldID() async {
        panel.newDraft();await settle()
        for _ in 0..<4 {await panel.refreshActivity();await panel.refreshForeground();await settle();assertNoOldTarget()}
        XCTAssertNil(panel.controlTarget);XCTAssertNotNil(panel.controlError)
        record("AB01 unverified new request with repeated old native and IPC")
    }
    func testNewRequestWithUnavailableNativeCannotRestoreOldIPC() async {
        panel.newDraft();await settle();rig.ui=["available":false]
        for _ in 0..<4 {now += 3;await panel.refreshForeground();await panel.refreshActivity();await settle();assertNoOldTarget()}
        XCTAssertNil(panel.controlTarget);record("AB02 new request and unavailable native")
    }
    func testConfirmedDraftResponseIsAdoptedBeforeAnotherPoll() async {
        rig.newDraftResult=["launch_requested":true,"navigation_verified":true,"foreground":draft]
        panel.newDraft();await settle()
        XCTAssertTrue(panel.isDraft);XCTAssertEqual(panel.controlTarget?.threadID,"draft");XCTAssertEqual(panel.nativeToken,"new-draft")
        assertNoOldTarget();XCTAssertNil(panel.controlError)
        record("AB03 verified navigation foreground adopted immediately")
    }
    func testExternallyObservedDraftThenReadFailureDoesNotRestoreOldIPC() async {
        rig.ui=draft;await panel.refreshForeground();XCTAssertTrue(panel.isDraft)
        rig.failure="get_keypad_ui_state";await panel.refreshForeground();await panel.refreshActivity();await settle()
        assertNoOldTarget();XCTAssertNil(panel.controlTarget)
        record("AB04 external new draft followed by native read failure")
    }
    func testExpiredDraftObservationCannotPromoteOldVisibility() async {
        rig.ui=draft;await panel.refreshForeground();now += 3
        await panel.refreshActivity();await settle();assertNoOldTarget();XCTAssertNil(panel.controlTarget)
        record("AB05 draft observation expires while IPC stays old")
    }
    func testLaterDraftThenFreshThreadCanRecoverAndReturnToOriginalThread() async {
        panel.newDraft();await settle();await panel.refreshActivity();await settle();assertNoOldTarget()
        rig.ui=draft;await panel.refreshForeground();await settle();XCTAssertTrue(panel.isDraft)
        rig.ui=["available":true,"routeAvailable":true,"selectionKnown":true,"threadId":PanelRig.b,"routeKey":"thread:"+PanelRig.b,"targetToken":"thread-b"]
        await panel.refreshForeground();await settle();XCTAssertEqual(panel.currentThreadID,PanelRig.b)
        rig.ui["threadId"]=PanelRig.a;rig.ui["routeKey"]="thread:"+PanelRig.a
        await panel.refreshForeground();await settle();XCTAssertEqual(panel.currentThreadID,PanelRig.a)
        record("AB06 delayed draft and explicit native route recovery")
    }
    func testExplicitSelectionRemainsASelectionAndDoesNotClaimCurrentID() async {
        panel.newDraft();await settle();panel.select(PanelRig.b);await settle()
        XCTAssertNil(panel.currentThreadID);XCTAssertEqual(panel.selectedID,PanelRig.b);XCTAssertEqual(panel.contextSource,.selected)
        record("AB07 manual selection is separate from observed current ID")
    }
    func testOldFailedNativeReadCannotClearConfirmedNewDraft() async throws {
        var suspended:CheckedContinuation<[String:Any]?,Error>?
        rig.intercept={ [unowned self] operation,_ in
            guard operation == "get_keypad_ui_state" else {return nil}
            self.rig.intercept=nil
            return try await withCheckedThrowingContinuation {suspended=$0}
        }
        let read=Task {await panel.refreshForeground()}
        for _ in 0..<200 where suspended == nil {await Task.yield()}
        let continuation=try XCTUnwrap(suspended)
        rig.newDraftResult=["navigation_verified":true,"foreground":draft]
        panel.newDraft();await settle()
        continuation.resume(throwing:NSError(domain:"OldNativeRead",code:1));await read.value
        XCTAssertTrue(panel.isDraft);XCTAssertEqual(panel.nativeToken,"new-draft");assertNoOldTarget()
        record("AB08 old native error cannot overwrite confirmed new draft")
    }
    func testOldActivityInvalidationCannotClearConfirmedNewDraft() async throws {
        var suspended:CheckedContinuation<[String:Any]?,Error>?
        rig.intercept={ [unowned self] operation,_ in
            guard operation == "get_keypad_activity" else {return nil}
            self.rig.intercept=nil
            return try await withCheckedThrowingContinuation {suspended=$0}
        }
        let read=Task {await panel.refreshActivity()}
        for _ in 0..<200 where suspended == nil {await Task.yield()}
        let continuation=try XCTUnwrap(suspended)
        rig.newDraftResult=["navigation_verified":true,"foreground":draft]
        panel.newDraft();await settle()
        continuation.resume(returning:["contextValid":false]);await read.value
        XCTAssertTrue(panel.isDraft);XCTAssertEqual(panel.nativeToken,"new-draft");assertNoOldTarget()
        record("AB09 old activity invalidation cannot overwrite confirmed new draft")
    }
    func testConfirmedNewDraftFastPlanAndMindUseOnlyNewNativeTarget() async throws {
        rig.ui=draft;rig.newDraftResult=["navigation_verified":true,"foreground":rig.ui]
        panel.newDraft();await settle();rig.calls=[]
        for command in ["composer.toggleFastMode","composer.togglePlanMode","composer.increaseReasoningEffort"] {
            try XCTUnwrap(panel.prepareBinding(["type":"command","commandId":command]))();await settle()
        }
        XCTAssertEqual(rig.mutations.map(\.0),["set_keypad_draft_fast","toggle_keypad_draft_plan","set_keypad_draft_reasoning"])
        XCTAssertTrue(rig.mutations.allSatisfy {$0.1["thread_id"] == nil})
        XCTAssertEqual(rig.mutations.first?.1["target_token"] as? String,"new-draft")
        XCTAssertTrue(panel.fast);XCTAssertEqual(panel.collaborationMode,"plan");XCTAssertEqual(panel.currentEffort,"high")
        assertNoOldTarget();record("AB10 confirmed new draft settings never target previous UUID")
    }
    func testLosingKnownThreadReadDoesNotPromoteItsCachedVisibility() async {
        rig.ui=["available":false];await panel.refreshForeground();await panel.refreshActivity();await settle()
        assertNoOldTarget();XCTAssertNil(panel.controlTarget)
        record("AB11 native authority does not fall back after a lost observation")
    }
    func testNonTargetTransitionCannotReleasePendingNewIdentity() async {
        let original=rig.ui
        for route in ["conflict","page:/settings","host:remote:/local/"+PanelRig.b,"binding:unverified"] {
            panel.newDraft();await settle()
            rig.ui=["available":false,"selectionKnown":true,"routeKey":route]
            await panel.refreshForeground();assertNoOldTarget()
            rig.ui=original;await panel.refreshForeground();await panel.refreshActivity();await settle()
            assertNoOldTarget();XCTAssertNil(panel.controlTarget)
        }
        record("AB12 ambiguous foreign and non-chat transitions keep new navigation pending")
    }
    func testLateDraftConfirmationClearsOnlyItsOwnNavigationError() async {
        panel.newDraft();await settle();XCTAssertNotNil(panel.controlError)
        rig.ui=draft;await panel.refreshForeground();await settle()
        XCTAssertTrue(panel.isDraft);XCTAssertNil(panel.controlError)
        record("AB13 delayed draft clears its unverified navigation error")
    }
    func testLateDraftConfirmationPreservesUnrelatedCapturedActionError() async throws {
        let captured=try XCTUnwrap(panel.controlTarget),model=try XCTUnwrap(panel.models.first)
        panel.newDraft();await settle();panel.setModel(model,target:captured);await settle()
        let actionError=try XCTUnwrap(panel.controlError)
        rig.ui=draft;await panel.refreshForeground();await settle()
        XCTAssertTrue(panel.isDraft);XCTAssertEqual(panel.controlError,actionError)
        record("AB14 delayed draft does not erase unrelated action error")
    }
}
