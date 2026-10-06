import XCTest
@testable import MicroCore
import MicroShared

final class PriorityRosterTests:XCTestCase {
    func id(_ n:Int)->String {String(format:"01000000-0000-0000-0000-%012d",n)}
    func testCompleteCatalogIncludesCandidatesAfterFirstPage() throws {
        let first:[String:Any]=["data":(1...100).map {["id":id($0)]},"nextCursor":"older"]
        var calls=0
        let rows=try PriorityRoster.read(first:first) {params in
            calls += 1;XCTAssertEqual(params["cursor"] as? String,"older")
            XCTAssertEqual(params["sortKey"] as? String,"recency_at");XCTAssertEqual(params["sortDirection"] as? String,"desc")
            XCTAssertEqual(params["useStateDbOnly"] as? Bool,true)
            return ["data":[["id":self.id(101)]],"nextCursor":NSNull()]
        }
        XCTAssertEqual(calls,1);XCTAssertEqual(rows.count,101);XCTAssertEqual(rows.last?["id"] as? String,id(101))
    }
    func testEmptyIntermediatePageDoesNotHideOlderCandidates() throws {
        let rows=try PriorityRoster.read(first:["data":[],"nextCursor":"older"]) {_ in ["data":[["id":self.id(101)]]]}
        XCTAssertEqual(rows.count,1)
    }
    func testMalformedDuplicatesOrWrongIDsRejectWholeRanking() {
        for first:[String:Any] in [["data":"invalid"],["data":[["id":"bad"]]],["data":[["id":id(1)],["id":id(1)]]],["data":Array(repeating:["id":id(1)],count:101)]] {
            XCTAssertThrowsError(try PriorityRoster.read(first:first) {_ in XCTFail("Malformed first page must not continue");return [:]})
        }
        XCTAssertThrowsError(try PriorityRoster.read(first:["data":[["id":id(1)]],"nextCursor":"next"]) {_ in ["data":[["id":self.id(1)]]]})
    }
    func testInvalidLoopingOrExcessiveCursorsNeverReturnPartialCatalog() {
        for cursor:Any in ["",false,17,"same"] {
            XCTAssertThrowsError(try PriorityRoster.read(first:["data":[],"nextCursor":cursor]) {_ in ["data":[],"nextCursor":cursor]})
        }
        var pages=0
        XCTAssertThrowsError(try PriorityRoster.read(first:["data":[["id":id(1)]],"nextCursor":"0"]) {_ in
            pages += 1;return ["data":[],"nextCursor":String(pages)]
        });XCTAssertEqual(pages,100)
    }
    func testServerOrIdentityFailureDoesNotReturnSuccessfulPrefix() {
        XCTAssertThrowsError(try PriorityRoster.read(first:["data":[["id":id(1)]],"nextCursor":"next"]) {_ in throw CodexClientError.staleTarget})
    }
    func testAttentionIsIndependentOfLampStatus() {
        XCTAssertEqual(TaskAttention.classify(status:["type":"active"],unread:true),.unread)
        XCTAssertEqual(TaskAttention.classify(status:["type":"active","activeFlags":["waitingOnApproval"]],unread:true),.waiting)
        XCTAssertEqual(TaskAttention.classify(status:["type":"active"],question:true,unread:true),.waiting)
        XCTAssertEqual(TaskAttention.classify(status:["type":"systemError"]),.idle)
        XCTAssertEqual(TaskAttention.classify(status:["type":"systemError"],unread:true),.unread)
        XCTAssertEqual(TaskAttention.allCases.map(\.rawValue),["waiting","unread","active","idle"])
    }
    func testRecencyUsesFiniteNativeFallbackAndDoesNotConvertBoolOrStringToTimestamp() {
        XCTAssertEqual(TaskAttention.recency(["recencyAt":10,"updatedAt":20,"createdAt":30]),10)
        XCTAssertEqual(TaskAttention.recency(["recencyAt":NSNull(),"updatedAt":20]),20)
        XCTAssertEqual(TaskAttention.recency(["recencyAt":Double.nan,"updatedAt":Double.infinity,"createdAt":30]),30)
        XCTAssertEqual(TaskAttention.recency(["recencyAt":true,"updatedAt":"999","createdAt":30]),30)
        XCTAssertEqual(TaskAttention.recency([:]),0)
    }
    func testBoundedOwnerDiscoveryRotatesBeyondFirstFourteenAndSixtyFour() {
        let ids=Set((1...150).map(id));var last:[String:TimeInterval]=[:],seen:Set<String>=[]
        for step in 1...22 {
            let batch=ActivityMonitor.discoveryBatch(ids:ids,pending:[],last:last,selected:id(1))
            XCTAssertEqual(batch.count,8);XCTAssertEqual(batch.first,id(1))
            for id in batch {last[id]=Double(step);seen.insert(id)}
        }
        XCTAssertEqual(seen,ids)
    }
    func testPendingOwnerRequestsRespectConcurrencyAndRetireFromCandidates() {
        let ids=Set((1...100).map(id)),pending=Set((1...60).map(id))
        let batch=ActivityMonitor.discoveryBatch(ids:ids,pending:pending,last:[:],selected:id(100))
        XCTAssertEqual(batch.count,4);XCTAssertEqual(batch.first,id(100));XCTAssertTrue(Set(batch).isDisjoint(with:pending))
        XCTAssertTrue(ActivityMonitor.discoveryBatch(ids:ids,pending:ids,last:[:],selected:nil).isEmpty)
    }
    func testRecentlyQueriedOwnersDoNotMonopolizeEverySmallBatch() {
        let batch=ActivityMonitor.discoveryBatch(ids:Set((1...20).map(id)),pending:[],last:[id(1):19,id(2):10],selected:id(1),now:20)
        XCTAssertEqual(batch.count,8);XCTAssertFalse(batch.contains(id(1)))
    }

}
