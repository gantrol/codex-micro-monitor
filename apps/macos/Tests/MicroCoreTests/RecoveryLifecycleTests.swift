import XCTest
import MicroShared
@testable import MicroPanelModel

/// Component regressions for asynchronous recovery. Desktop/OS effects are
/// injected; these are not a second E2E implementation of the live journey.
@MainActor final class RecoveryLifecycleTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var rig: PanelRig!
    private var panel: MicroModel!
    private var now: TimeInterval = 100

    override func setUp() async throws {
        suite = "MicroRecovery." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        rig = PanelRig()
        panel = MicroModel(settings: Settings(defaults: defaults), client: rig,
                           observationUptime: { [unowned self] in self.now })
        await panel.refresh()
        await panel.refreshForeground()
        await idle()
    }
    override func tearDown() async throws {
        panel.stop()
        defaults.removePersistentDomain(forName: suite)
    }
    private func idle() async {
        for _ in 0..<300 {
            await Task.yield()
            if !panel.opening && !panel.controlling && !panel.activating && !panel.refreshing { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Recovery did not settle")
    }
    private func clientState() {
        let client = "client-new-thread:" + PanelRig.a
        rig.ui = ["available": false, "selectionKnown": true, "routeKey": "client:" + client,
                  "clientThreadId": client, "observationToken": "read-window-a", "targetToken": NSNull(),
                  "diagnostics": ["modelPickerAvailable": false, "composerAvailable": false]]
        rig.clientBinding = ["resolved": true, "clientThreadId": client, "threadId": PanelRig.b,
                             "rosterScope": rig.rosterScope!, "contextID": "account-a", "thread": ["id": PanelRig.b]]
    }

    func testMissingControlsRetainVerifiedReadIdentityWithoutWriteAuthority() async {
        clientState()
        await panel.refreshForeground()
        XCTAssertEqual(panel.currentThreadID, PanelRig.b)
        XCTAssertNil(panel.controlTarget)
        XCTAssertNil(panel.prepareBinding(KeySlots.defaultAction("FAST")))
        XCTAssertNil(panel.prepareBinding(KeySlots.defaultAction("CODEX")))
        XCTAssertTrue(rig.mutations.isEmpty)
        rig.ui["observationToken"] = NSNull()
        rig.ui["targetToken"] = "legacy-write-token"
        await panel.refreshForeground()
        XCTAssertNil(panel.currentThreadID, "Explicit null read authority cannot revive legacy write authority")
    }

    func testSlowNativeReadRecoversAfterOldObservationExpires() async {
        rig.onCall = { [unowned self] operation in
            guard operation == "get_keypad_ui_state" else { return }
            rig.onCall = nil
            now += 3
            await panel.refreshActivity()
            XCTAssertNil(panel.currentThreadID)
        }
        await panel.refreshForeground()
        XCTAssertEqual(panel.currentThreadID, PanelRig.a)
        XCTAssertTrue(rig.mutations.isEmpty)
    }

    func testSlowClientLookupRestoresOnlyAfterFreshNativeRead() async {
        clientState()
        rig.onCall = { [unowned self] operation in
            guard operation == "get_keypad_client_thread" else { return }
            rig.onCall = nil
            now += 3
            await panel.refreshActivity()
            XCTAssertNil(panel.currentThreadID)
        }
        await panel.refreshForeground()
        XCTAssertEqual(panel.currentThreadID, PanelRig.b)
        XCTAssertNil(panel.controlTarget)
        XCTAssertTrue(rig.mutations.isEmpty)
    }

    func testManualSelectionDuringNativeReadRejectsItsLateResult() async {
        rig.onCall = { [unowned self] operation in
            guard operation == "get_keypad_ui_state" else { return }
            rig.onCall = nil
            panel.select(PanelRig.b)
        }
        await panel.refreshForeground()
        await idle()
        XCTAssertEqual(panel.selectedID, PanelRig.b)
        XCTAssertEqual(panel.contextSource, .selected)
        XCTAssertTrue(rig.mutations.isEmpty)
    }

    func testRosterFailureDoesNotEraseNativeRouteAndSameAccountRecovers() async {
        rig.failure = "list_keypad_threads"
        await panel.refresh()
        XCTAssertFalse(panel.connected)
        XCTAssertEqual(panel.currentThreadID, PanelRig.a)
        XCTAssertNil(panel.controlTarget)
        rig.failure = nil
        await panel.refresh()
        XCTAssertEqual(panel.currentThreadID, PanelRig.a)
        XCTAssertTrue(panel.connected)
        XCTAssertTrue(rig.mutations.isEmpty)
    }

    func testUnreadReceiptSurvivesSameAccountNavigationAndOutage() async throws {
        let row = try XCTUnwrap(panel.threads.first { $0.id == PanelRig.b })
        rig.intercept = { operation, _ in
            operation == "mark_keypad_unread" ? ["verified": true, "contextID": "account-a", "activityRevision": 20] : nil
        }
        panel.markUnread(row)
        await idle()
        XCTAssertEqual(panel.signal(for: row), .unread)
        let draft: [String: Any] = ["available": true, "routeAvailable": true, "selectionKnown": true,
                                    "draft": true, "routeKey": "draft", "targetToken": "draft-next"]
        rig.newDraftResult = ["navigation_verified": true, "foreground": draft]
        panel.newDraft()
        await idle()
        await panel.refreshActivity()
        XCTAssertEqual(panel.signal(for: row), .unread)
        try XCTUnwrap(panel.prepareBinding(["type": "command", "commandId": "settings"]))()
        await idle()
        await panel.refreshActivity()
        XCTAssertEqual(panel.signal(for: row), .unread)
        rig.failure = "list_keypad_threads"
        await panel.refresh()
        rig.failure = nil
        await panel.refresh()
        await panel.refreshActivity()
        XCTAssertEqual(panel.signal(for: row), .unread)
        rig.rosterScope = String(repeating: "b", count: 64)
        await panel.refresh()
        XCTAssertNotEqual(panel.signal(for: row), .unread, "A confirmed new account must not inherit the old receipt")
    }

    func testRecoveryKeyWithoutLayoutOrIdentityActivatesOnceAndNeverSubmits() async throws {
        panel.stop()
        rig.failure = "list_keypad_threads"
        rig.ui = ["available": false, "accessibility": false]
        await panel.refresh()
        rig.calls = []
        rig.intercept = { [unowned self] operation, _ in
            guard operation == "activate_keypad_app" else { return nil }
            XCTAssertNil(panel.prepareKey("CODEX"), "A second press during recovery must not submit")
            return ["activated": true, "window_visible": true, "verified": true, "submitted": false]
        }
        try XCTUnwrap(panel.prepareKey("CODEX"))()
        await idle()
        XCTAssertEqual(rig.mutations.map(\.0), ["activate_keypad_app"])
        XCTAssertNil(panel.controlError)
    }

    func testQueuedSettingCannotDispatchAfterContextInvalidationDuringPreflight() async throws {
        let action = try XCTUnwrap(panel.prepareBinding(KeySlots.defaultAction("FAST")))
        rig.onCall = { [unowned self] operation in
            guard operation == "get_keypad_ui_state" else { return }
            rig.onCall = nil
            rig.activity["contextValid"] = false
            await panel.refreshActivity()
        }
        action()
        await idle()
        XCTAssertTrue(rig.mutations.isEmpty)
    }
}
