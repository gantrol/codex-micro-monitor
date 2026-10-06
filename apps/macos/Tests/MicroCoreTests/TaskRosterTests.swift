import XCTest
@testable import MicroCore

final class TaskRosterTests:XCTestCase {
    let a="01000000-0000-0000-0000-000000000001",b="01000000-0000-0000-0000-000000000002",c="01000000-0000-0000-0000-000000000003"
    let scope=String(repeating:"a",count:64)
    func testRosterScopeIsStableAndIsolatesAccountHostAndStorage() throws {
        let context=CodexReadContext(identity:[:],identityKey:"account-a",executionHostKey:"host-a")
        let first=try XCTUnwrap(TaskRoster.scope(context,root:URL(fileURLWithPath:"/fixture/one")))
        XCTAssertEqual(first,TaskRoster.scope(context,root:URL(fileURLWithPath:"/fixture/one")))
        XCTAssertNotEqual(first,TaskRoster.scope(context,root:URL(fileURLWithPath:"/fixture/two")))
        XCTAssertNotEqual(first,TaskRoster.scope(.init(identity:[:],identityKey:"account-b",executionHostKey:"host-a"),root:URL(fileURLWithPath:"/fixture/one")))
        XCTAssertNotEqual(first,TaskRoster.scope(.init(identity:[:],identityKey:"account-a",executionHostKey:"host-b"),root:URL(fileURLWithPath:"/fixture/one")))
        XCTAssertNil(TaskRoster.scope(nil,root:URL(fileURLWithPath:"/fixture/one")))
    }
    func testMappingRequestRejectsMalformedIDsScopeTypesAndOverflow() {
        for args:[String:Any] in [
            ["mapped_thread_ids":"invalid","roster_scope":scope],
            ["mapped_thread_ids":["not-an-id"],"roster_scope":scope],
            ["mapped_thread_ids":[a]],
            ["mapped_thread_ids":[a],"roster_scope":"unscoped"],
            ["mapped_thread_ids":Array(repeating:a,count:15),"roster_scope":scope]
        ] {XCTAssertThrowsError(try TaskRoster.request(args))}
    }
    func testDuplicateSlotTargetsNeedOnlyOneReadAndKeepRequestedOrder() throws {
        let request=try TaskRoster.request(["mapped_thread_ids":[c,a,c,b],"roster_scope":scope])
        var reads:[String]=[]
        let result=try TaskRoster.resolve(request,scope:scope,recent:[["id":a,"name":"Same title"]]) {id in
            reads.append(id);return ["thread":["id":id,"name":"Same title"]]
        }
        XCTAssertEqual(reads,[c,b]);XCTAssertEqual(result.rows.compactMap {$0["id"] as? String},[c,a,b])
        XCTAssertTrue(result.unavailable.isEmpty)
    }
    func testUnknownOrChangedScopeNeverReadsSavedIDs() throws {
        let request=try TaskRoster.request(["mapped_thread_ids":[c],"roster_scope":scope])
        for current in [nil,String(repeating:"b",count:64)] {
            let result=try TaskRoster.resolve(request,scope:current,recent:[["id":a]]) {_ in XCTFail("Must not query another account's saved ID");return [:]}
            XCTAssertTrue(result.rows.isEmpty);XCTAssertTrue(result.unavailable.isEmpty)
        }
    }
    func testDeletedMappedThreadDoesNotShiftToAnotherRecentChatOrHideOtherMappings() throws {
        let request=try TaskRoster.request(["mapped_thread_ids":[c,a,b],"roster_scope":scope])
        var reads:[String]=[]
        let result=try TaskRoster.resolve(request,scope:scope,recent:[["id":a]]) {id in
            reads.append(id)
            if id == self.c {throw CodexClientError.rejected("Fixture no longer exists")}
            return ["thread":["id":id]]
        }
        XCTAssertEqual(reads,[c,b]);XCTAssertEqual(result.unavailable,[c])
        XCTAssertEqual(result.rows.compactMap {$0["id"] as? String},[a,b])
    }
    func testWrongReadIDAndTransportFailureAreNotReportedAsMissingTasks() throws {
        let request=try TaskRoster.request(["mapped_thread_ids":[c],"roster_scope":scope])
        XCTAssertThrowsError(try TaskRoster.resolve(request,scope:scope,recent:[]) {_ in ["thread":["id":self.a]]})
        XCTAssertThrowsError(try TaskRoster.resolve(request,scope:scope,recent:[]) {_ in throw CodexClientError.timedOut})
    }
}
