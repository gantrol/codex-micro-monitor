import XCTest
@testable import MicroCore

final class ClientThreadBindingTests:XCTestCase {
    let a="01000000-0000-0000-0000-000000000001",b="01000000-0000-0000-0000-000000000002"
    var client:String {"client-new-thread:"+a}
    func read(_ atoms:[String:Any])throws->ClientThreadBinding.Evidence {try ClientThreadBinding.evidence(["electron-persisted-atom-state":atoms],client:client)}
    func reverse(_ id:String)->String {"thread-client-id-v1:local%3A"+id}
    func trace(_ id:String,_ values:[String:Any]=[:]) {ReplayTrace.emit("CLIENT-BINDING-TRACE",values.merging(["scenario":id]) {a,_ in a})}
    func testForwardAndReverseEvidenceAgree()throws {
        let evidence=try read(["client-thread-bindings-v1":[client:b],reverse(b):client])
        XCTAssertEqual(evidence.threadID,b);XCTAssertEqual(evidence.sources.count,2)
        trace("Y01 forward plus reverse",["threadId":b])
    }
    func testReverseFallbackAndMultipleClientAliasesForOneThread()throws {
        XCTAssertEqual(try read([reverse(b):client]).threadID,b)
        XCTAssertEqual(try read(["client-thread-bindings-v1":[client:b,"client-new-thread:"+b:b],reverse(b):"client-new-thread:"+b]).threadID,b)
        trace("Y02 reverse fallback and many clients to one thread")
    }
    func testConflictingServerIDsAndMalformedBindingsFail() {
        for atoms:[String:Any] in [["client-thread-bindings-v1":[client:a],reverse(b):client],
                                  [reverse(a):client,reverse(b):client],
                                  ["client-thread-bindings-v1":[client:"not-a-uuid"]],
                                  ["client-thread-bindings-v1":[client:NSNull()]],
                                  ["client-thread-bindings-v1":"bad"],
                                  [reverse("bad"):client]] {XCTAssertThrowsError(try read(atoms))}
        trace("Y03 conflicting and malformed binding",["rejected":6])
    }
    func testUnrelatedAndRemoteIdentitiesNeverResolveOrProveDraft()throws {
        for atoms:[String:Any] in [[:],["draft-thread-identities-v1":["new-conversation":client]],
                                  ["thread-client-id-v1:remote%3A"+b:client],
                                  ["client-thread-bindings-v1":["client-new-thread:"+b:a]],
                                  [reverse(a):"not-a-client"]] {XCTAssertNil(try read(atoms).threadID)}
        trace("Y04 unrelated home remote or missing binding",["resolved":false,"draftInferred":false])
    }
    func testEvidenceChangesEvenWhenNewSourcePointsToSameThread()throws {
        XCTAssertNotEqual(try read([reverse(a):client]),try read(["client-thread-bindings-v1":[client:a],reverse(a):client]))
        trace("Y05 evidence transition is observable")
    }
    func testInvalidClientAndOversizedMapReject() {
        XCTAssertThrowsError(try ClientThreadBinding.evidence([:],client:a))
        XCTAssertThrowsError(try read(["client-thread-bindings-v1":Dictionary(uniqueKeysWithValues:(0...1000).map {(String($0),a)})]))
        trace("Y06 invalid client and oversized catalog")
    }
}
