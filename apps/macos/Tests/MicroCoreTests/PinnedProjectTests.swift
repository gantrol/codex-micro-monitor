import XCTest
@testable import MicroCore

final class PinnedProjectTests:XCTestCase {
    let root=URL(fileURLWithPath:"/fixture/home")
    let project="02000000-0000-0000-0000-000000000001"
    func id(_ n:Int)->String {String(format:"01000000-0000-0000-0000-%012d",n)}
    func row(_ n:Int,time:Int=0)->[String:Any] {["id":id(n),"name":"Same title","recencyAt":time,"section":["id":PinnedRoster.sectionID]]}
    func member(_ n:Int,time:Int=0)->[String:Any] {row(n,time:time).merging(["projectId":project]) {_,new in new}}
    func preferences(order:[String]=[],manual:Bool=false)throws->PinnedSidebarPreferences {
        try .init(global:["pinned-project-ids":["legacy"],"app-server-project-id-by-legacy-project-id-by-host":["local:"+root.path:["legacy":project]],
            "electron-persisted-atom-state":["unified-sidebar-pinned-order-v1":order,"flat-project-sidebar-preferences-v1":["projectSortMode":manual ? "manual":"updated_at","manualSortVersion":1]]],root:root)
    }
    func read(_ prefs:PinnedSidebarPreferences,pins:[[String:Any]]?=nil,members:[[String:Any]]?=nil,previous:[String:[String]]=[:])throws->PinnedRoster.Snapshot {
        try PinnedRoster.read(scope:"current",preferences:prefs,previousOrders:previous) {method,params in
            switch method {
            case "threadSection/list":return ["data":[["id":PinnedRoster.sectionID]]]
            case "project/list":return ["data":[["id":self.project,"name":"Same title","roots":[["path":"/fixture/project"]]]]]
            default:
                if let project=params["projectId"] as? String {
                    XCTAssertEqual(project,self.project);XCTAssertEqual(params["sortKey"] as? String,"recency_at")
                    XCTAssertEqual(params["sortDirection"] as? String,"desc");XCTAssertEqual(params["archived"] as? Bool,false)
                    XCTAssertEqual(params["useStateDbOnly"] as? Bool,true);XCTAssertEqual(params["modelProviders"] as? [String],[])
                    return ["data":members ?? [self.member(1),self.member(4,time:2),self.member(3,time:8)]]
                }
                return ["data":pins ?? [self.row(1),self.row(2)]]
            }
        }
    }
    func record(_ scenario:String,_ result:PinnedRoster.Snapshot) {
        ReplayTrace.emit("PINNED-PROJECT-TRACE",["scenario":scenario,"available":result.available,"slots":result.rows.compactMap {$0["id"] as? String},"projectOrders":result.projectOrders])
    }
    func testManualInterleavingPreservesServerPinOrderAndRemovesDuplicateMembers()throws {
        let prefs=try preferences(order:["codex:thread:local:"+id(2),"codex:project:legacy","codex:thread:local:"+id(1)])
        let result=try read(prefs)
        XCTAssertEqual(result.rows.compactMap {$0["id"] as? String},[id(1),id(3),id(4),id(2)])
        record("V01 project interleaving server pins and duplicate removal",result)
    }
    func testUpdatedPinSortReadsBeyondFourteenBeforeTruncating()throws {
        var prefs=PinnedSidebarPreferences();prefs.manualPins=false;var pages=0
        let result=try PinnedRoster.read(scope:"current",preferences:prefs) {method,params in
            if method == "threadSection/list" {return ["data":[["id":PinnedRoster.sectionID]]]}
            pages += 1
            return params["cursor"] == nil ? ["data":(1...14).map {self.row($0,time:$0)},"nextCursor":"next"]:["data":[self.row(15,time:500)]]
        }
        XCTAssertEqual(pages,2);XCTAssertEqual(result.rows.count,14);XCTAssertEqual(result.rows.first?["id"] as? String,id(15))
        record("V02 recency pin after first fourteen",result)
    }
    func testExplicitProjectOrderAndPreviousManualOrderKeepNewMembersAtEnd()throws {
        var prefs=try preferences(manual:true);prefs.projectOrders=["legacy":[id(4),id(3),id(99)]]
        let first=try read(prefs);XCTAssertEqual(first.projectOrders["legacy"],[id(4),id(3)])
        prefs.projectOrders=[:]
        let second=try read(prefs,members:[member(3,time:10),member(5,time:20),member(4,time:1)],previous:first.projectOrders)
        XCTAssertEqual(second.projectOrders["legacy"],[id(4),id(3),id(5)])
        record("V03 explicit and prior manual project order",second)
    }
    func testLegacySortModeAndInvalidManualVersionUseRecency()throws {
        for version:Any in [0,true,1.5] {
            let prefs=try PinnedSidebarPreferences(global:["electron-persisted-atom-state":["flat-project-sidebar-preferences-v1":["projectSortMode":"manual","manualSortVersion":version]]],root:root)
            XCTAssertFalse(prefs.manualProjects)
        }
        let prefs=try PinnedSidebarPreferences(global:["electron-persisted-atom-state":["codex-sidebar-sort-mode-v1":"manual","flat-project-sidebar-preferences-v1":["projectSortMode":"manual","manualSortVersion":1]]],root:root)
        XCTAssertFalse(prefs.manualProjects);record("V04 legacy preferences normalize to recency",try read(prefs))
    }
    func testMigrationAliasesBelongToExactLocalStorageRoot()throws {
        let global:[String:Any]=["pinned-project-ids":["legacy"],"app-server-project-id-by-legacy-project-id-by-host":["local:/other/home":["legacy":project]]]
        let prefs=try PinnedSidebarPreferences(global:global,root:root)
        XCTAssertTrue(prefs.aliases.isEmpty);let result=try read(prefs)
        XCTAssertEqual(result.rows.compactMap {$0["id"] as? String},[id(1),id(2)])
        let exact=try PinnedSidebarPreferences(global:global,root:root,migrationRoot:"/other/home")
        XCTAssertEqual(exact.aliases["legacy"],project)
        record("V05 foreign storage alias ignored",result)
    }
    func testWrongProjectMembershipNeverBecomesAnOpenableTask()throws {
        let prefs=try preferences()
        XCTAssertThrowsError(try read(prefs,members:[row(3)]))
        XCTAssertThrowsError(try read(prefs,members:[member(3),member(3)]))
        var wrong=member(3);wrong["projectId"]=id(99)
        XCTAssertThrowsError(try read(prefs,members:[wrong]))
        record("V06 canonical membership mismatch rejected",.init())
    }
    func testAllPinsAreReadBeforeFilteringProjectMembership()throws {
        let prefs=try preferences(order:["codex:project:legacy"]);var pinPages=0
        let result=try PinnedRoster.read(scope:"current",preferences:prefs) {method,params in
            if method == "threadSection/list" {return ["data":[["id":PinnedRoster.sectionID]]]}
            if method == "project/list" {return ["data":[["id":self.project]]]}
            if params["projectId"] != nil {return ["data":[self.member(15,time:100),self.member(16,time:1)]]}
            pinPages += 1
            return params["cursor"] == nil ? ["data":(1...14).map {self.row($0)},"nextCursor":"next"]:["data":[self.row(15)]]
        }
        XCTAssertEqual(pinPages,2);XCTAssertEqual(result.rows.first?["id"] as? String,id(16));XCTAssertEqual(result.rows.count,14)
        record("V07 pin beyond fourteen excluded from project",result)
    }
    func testUnsupportedProjectProtocolDoesNotReturnPartialPins()throws {
        let result=try PinnedRoster.read(scope:"current",preferences:preferences()) {method,_ in
            if method == "threadSection/list" {return ["data":[["id":PinnedRoster.sectionID]]]}
            if method == "project/list" {throw CodexClientError.rejected("Unsupported")}
            return ["data":[self.row(1)]]
        }
        XCTAssertFalse(result.available);XCTAssertTrue(result.rows.isEmpty);record("V08 unsupported project protocol",result)
    }
    func testMalformedAndLoopingProjectPagesRejectPartialResult()throws {
        for mode in ["wrong-id","duplicate","loop"] {
            XCTAssertThrowsError(try PinnedRoster.read(scope:"current",preferences:preferences()) {method,_ in
                if method == "threadSection/list" {return ["data":[["id":PinnedRoster.sectionID]]]}
                if method == "project/list" {
                    if mode == "wrong-id" {return ["data":[["id":"invalid"]]]}
                    if mode == "duplicate" {return ["data":[["id":self.project],["id":self.project]]]}
                    return ["data":[],"nextCursor":"same"]
                }
                return ["data":[self.row(1)]]
            })
        }
        record("V09 malformed duplicate and looping projects",.init())
    }
    func testMissingAndChatGPTMirrorProjectsDoNotInferMembersFromDirectoryNames()throws {
        var prefs=try preferences();prefs.projectIDs.append("deleted")
        let result=try PinnedRoster.read(scope:"current",preferences:prefs) {method,params in
            if method == "threadSection/list" {return ["data":[["id":PinnedRoster.sectionID]]]}
            if method == "project/list" {return ["data":[["id":self.project,"roots":[["path":"/fixture/.chatgpt-projects/mirror"]]]]]}
            XCTAssertNil(params["projectId"]);return ["data":[self.row(1)]]
        }
        XCTAssertEqual(result.rows.count,1);record("V10 missing projects and native mirrors",result)
    }
    func testInvalidPreferenceTypesAndAmbiguousMigrationFail() {
        for global:[String:Any] in [["pinned-project-ids":17],["electron-persisted-atom-state":[]],
            ["app-server-project-id-by-legacy-project-id-by-host":["local:"+root.path:["a":project,"b":project]]],
            ["electron-persisted-atom-state":["unified-sidebar-pinned-order-v1":[17]]]] {
            XCTAssertThrowsError(try PinnedSidebarPreferences(global:global,root:root))
        }
        record("V11 malformed preferences and ambiguous aliases",.init())
    }
    func testUnknownAccountSkipsProjectEnumerationAndEqualRecencyKeepsOrder()throws {
        let unknown=try PinnedRoster.read(scope:nil,preferences:preferences()) {_,_ in XCTFail("No account");return [:]}
        XCTAssertFalse(unknown.available)
        let result=try read(preferences(),members:[member(4,time:10),member(3,time:10)])
        XCTAssertEqual(result.projectOrders["legacy"],[id(4),id(3)])
        record("V12 unknown account and stable equal recency",result)
    }
    func testProjectsRemainAvailableWithoutAnIndividualPinnedSection()throws {
        let result=try PinnedRoster.read(scope:"current",preferences:preferences()) {method,params in
            if method == "threadSection/list" {return ["data":[["id":self.id(99),"name":"Pinned"]]]}
            if method == "project/list" {return ["data":[["id":self.project]]]}
            XCTAssertEqual(params["projectId"] as? String,self.project);XCTAssertNil(params["sectionId"])
            return ["data":[self.member(3),self.member(4)]]
        }
        XCTAssertTrue(result.available);XCTAssertEqual(result.rows.compactMap {$0["id"] as? String},[id(3),id(4)])
        record("V13 project-only pins without built-in section",result)
    }
}
