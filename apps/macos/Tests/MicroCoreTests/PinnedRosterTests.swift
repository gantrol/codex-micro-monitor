import XCTest
@testable import MicroCore

final class PinnedRosterTests:XCTestCase {
    let a="01000000-0000-0000-0000-000000000001",b="01000000-0000-0000-0000-000000000002"
    func row(_ id:String,section:String=PinnedRoster.sectionID)->[String:Any] {
        ["id":id,"section":["id":section],"name":"Same title"]
    }
    var section:[String:Any] {["data":[["id":PinnedRoster.sectionID,"name":"Renamed pin section"]]]}
    func testSectionIdentityAndNativeOrderAcrossPages() throws {
        var calls:[(String,[String:Any])]=[]
        let result=try PinnedRoster.read(scope:"observed") {method,params in
            calls.append((method,params))
            if method == "threadSection/list" {
                return params["cursor"] == nil ? ["data":[["id":self.a,"name":"Pinned"]],"nextCursor":"sections-2"]:self.section
            }
            XCTAssertEqual(params["sortKey"] as? String,"section_position");XCTAssertNil(params["sortDirection"])
            XCTAssertEqual(params["sectionId"] as? String,PinnedRoster.sectionID)
            XCTAssertEqual(params["archived"] as? Bool,false);XCTAssertEqual(params["useStateDbOnly"] as? Bool,true)
            XCTAssertEqual((params["modelProviders"] as? [String])?.count,0)
            return params["cursor"] == nil ? ["data":[self.row(self.b)],"nextCursor":"pins-2"]:["data":[self.row(self.a)],"nextCursor":NSNull()]
        }
        XCTAssertTrue(result.available);XCTAssertEqual(result.rows.compactMap {$0["id"] as? String},[b,a])
        XCTAssertEqual(calls.map(\.0),["threadSection/list","threadSection/list","thread/list","thread/list"])
    }
    func testFourteenSlotsDoNotScanRemainingPins() throws {
        var count=0
        let rows=(1...20).map {row(String(format:"01000000-0000-0000-0000-%012d",$0))}
        let result=try PinnedRoster.read(scope:"observed") {method,_ in
            count += 1;return method == "threadSection/list" ? self.section:["data":rows,"nextCursor":"more"]
        }
        XCTAssertEqual(count,2);XCTAssertTrue(result.available);XCTAssertEqual(result.rows.count,14)
        XCTAssertEqual(result.rows.last?["id"] as? String,"01000000-0000-0000-0000-000000000014")
    }
    func testEmptyModernPinsAreKnownButUnknownIdentityOrLegacySourceIsNot() throws {
        let empty=try PinnedRoster.read(scope:"observed") {method,_ in method == "threadSection/list" ? self.section:["data":[]]}
        XCTAssertTrue(empty.available);XCTAssertTrue(empty.rows.isEmpty)
        let unknown=try PinnedRoster.read(scope:nil) {_,_ in XCTFail("Unknown identity must not enumerate pins");return [:]}
        XCTAssertFalse(unknown.available)
        let legacy=try PinnedRoster.read(scope:"observed") {_,_ in ["data":[["id":self.a,"name":"Pinned"]]]}
        XCTAssertFalse(legacy.available);XCTAssertTrue(legacy.rows.isEmpty)
    }
    func testUnsupportedSectionsOrSortStayUnavailableWithoutFallback() throws {
        for failingMethod in ["threadSection/list","thread/list"] {
            var calls:[String]=[]
            let result=try PinnedRoster.read(scope:"observed") {method,_ in
                calls.append(method)
                if method == failingMethod {throw CodexClientError.rejected("Unsupported")}
                return self.section
            }
            XCTAssertFalse(result.available);XCTAssertTrue(result.rows.isEmpty)
            XCTAssertEqual(calls.last,failingMethod)
        }
    }
    func testWrongSectionMalformedIDOrDuplicateRowNeverBecomesAnOpenablePin() {
        for rows in [[row(a,section:b)],[row("invalid")],[row(a),row(a)],[ ["id":a] ]] {
            XCTAssertThrowsError(try PinnedRoster.read(scope:"observed") {method,_ in
                method == "threadSection/list" ? self.section:["data":rows]
            })
        }
        XCTAssertThrowsError(try PinnedRoster.read(scope:"observed") {_,_ in ["data":[["id":PinnedRoster.sectionID],["id":PinnedRoster.sectionID]]]})
    }
    func testMalformedRepeatedAndExcessivePaginationCannotReturnPartialPins() throws {
        for cursor:Any in ["",17,"stuck"] {
            XCTAssertThrowsError(try PinnedRoster.read(scope:"observed") {method,_ in
                method == "threadSection/list" ? self.section:["data":[],"nextCursor":cursor]
            })
        }
        var page=0
        let result=try PinnedRoster.read(scope:"observed") {method,_ in
            if method == "threadSection/list" {return self.section}
            page += 1;return ["data":page == 1 ? [self.row(self.a)]:[],"nextCursor":"page-\(page)"]
        }
        XCTAssertEqual(page,10);XCTAssertFalse(result.available);XCTAssertTrue(result.rows.isEmpty)
    }
    func testTransportFailureIsNotReportedAsAnEmptyPinList() {
        XCTAssertThrowsError(try PinnedRoster.read(scope:"observed") {_,_ in throw CodexClientError.staleTarget})
    }
}
