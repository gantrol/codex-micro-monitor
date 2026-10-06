import XCTest
@testable import MicroCore
@testable import MicroPanelModel

@MainActor final class PinnedProjectTaskScenarioTests:XCTestCase {
    func testMergedProjectReorderAndRemovalRetireHeldExactPresses() async throws {
        let suite="MicroPinnedProjectTasks."+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!,rig=PanelRig()
        let settings=Settings(defaults:defaults)
        let actual=MicroModel(settings:settings,client:rig)
        defer {actual.stop();defaults.removePersistentDomain(forName:suite)}
        let project="02000000-0000-0000-0000-000000000001",pin="01000000-0000-0000-0000-000000000003"
        var prefs=PinnedSidebarPreferences();prefs.projectIDs=[project];prefs.order=["codex:project:"+project]
        func merged(_ firstIsNewer:Bool)throws->[[String:Any]] {
            try PinnedSidebar.combine(pins:[["id":pin,"title":"Same title"]],preferences:prefs) {method,_ in
                if method == "project/list" {return ["data":[["id":project]]]}
                return ["data":[["id":PanelRig.a,"title":"Same title","projectId":project,"recencyAt":firstIsNewer ? 30:10],
                    ["id":PanelRig.b,"title":"Same title","projectId":project,"recencyAt":20]]]
            }.rows
        }
        func settle() async {
            for _ in 0..<250 {
                await Task.yield();if !actual.refreshing && !actual.opening && !actual.controlling && actual.desktopConnected {return}
                try? await Task.sleep(for:.milliseconds(1))
            }
        }
        var profile=settings.layout;profile.agentSource="pinned";settings.setLayout(profile)
        rig.pinnedRows=try merged(false);await actual.refresh();await actual.refreshForeground();await settle()
        XCTAssertEqual(actual.taskRow(at:0)?.id,PanelRig.b)
        actual.setInteraction("hover",active:true);let old=try XCTUnwrap(actual.prepareTask(0))
        rig.pinnedRows=try merged(true);await actual.refresh();old();await settle()
        XCTAssertTrue(rig.mutations.isEmpty);XCTAssertNil(actual.prepareTask(0))
        actual.setInteraction("hover",active:false);try XCTUnwrap(actual.prepareTask(0))();await settle()
        XCTAssertEqual(rig.mutations.first?.1["thread_id"] as? String,PanelRig.a)
        actual.setInteraction("hover",active:true);let removed=try XCTUnwrap(actual.prepareTask(1))
        prefs.projectIDs=[];rig.pinnedRows=try merged(true);await actual.refresh();removed();await settle()
        XCTAssertEqual(rig.mutations.map(\.0),["open_keypad_thread"])
        actual.setInteraction("hover",active:false);XCTAssertEqual(actual.taskRow(at:0)?.id,pin);XCTAssertNil(actual.taskRow(at:1))
        ReplayTrace.emit("PINNED-PROJECT-TRACE",["scenario":"V14 combined project roster to exact panel press","opened":rig.mutations.first?.1["thread_id"] ?? "none","remaining":actual.displayedThreads.map(\.id)])
    }
}
