import XCTest
import MicroShared
@testable import MicroCore

final class ClientAliasTests:XCTestCase {
    let a="01000000-0000-0000-0000-000000000001",b="01000000-0000-0000-0000-000000000002"
    var client:String {"client-new-thread:"+a}
    func read(_ path:String,_ selection:[String],home:Bool=false)->CurrentRoute {
        CurrentRoute.resolve(documents:["app://-"+path],selectedLinks:selection,homeComposer:home,composerAvailable:true)
    }
    func record(_ id:String,_ values:[String:Any]=[:]) {ReplayTrace.emit("CLIENT-ALIAS-TRACE",values.merging(["scenario":id]) {a,_ in a})}
    func testClientDocumentAndServerSelectionOnlyExposeUnverifiedPair() {
        let route=read("/local/"+client,["/local/"+b])
        XCTAssertEqual(route.pendingBinding?.clientThreadID,client);XCTAssertEqual(route.pendingBinding?.threadID,b)
        XCTAssertEqual(route.pendingBinding?.documentIsClient,true)
        XCTAssertNil(route.threadID);XCTAssertNil(route.clientThreadID);XCTAssertFalse(route.draft)
        XCTAssertFalse(route.allowsNativeComposer(selectedSidebarCount:1))
        record("AA01 unverified client document and server selection")
    }
    func testServerDocumentAndClientSelectionHaveDistinctDirection() {
        let first=read("/local/"+client,["/local/"+b]),second=read("/local/"+b,["/hotkey-window/thread/"+client])
        XCTAssertEqual(second.pendingBinding?.threadID,b);XCTAssertEqual(second.pendingBinding?.documentIsClient,false)
        XCTAssertNotEqual(first.key,second.key);XCTAssertNil(second.threadID)
        record("AA02 document role participates in pair identity")
    }
    func testMultipleUnknownForeignAndHomeSelectionsCannotFormPair() {
        let cases:[(String,[String],Bool)]=[
            ("/local/"+client,["/local/"+b,"/local/"+b],false),
            ("/local/"+client,["/local/"+b,"/settings"],false),
            ("/local/"+client,["/local/"+b+"?hostId=remote"],false),
            ("/local/"+client+"?hostId=remote",["/local/"+b],false),
            ("/local/"+client,["/local/"+b],true),
            ("/local/"+b,["/local/"+client],true),
            ("/local/"+client,["/local/not-a-uuid"],false),
            ("/local/"+client,["/local/client-new-thread:"+b],false)]
        for (path,selected,home) in cases {
            let route=read(path,selected,home:home);XCTAssertNil(route.pendingBinding,path);XCTAssertNil(route.threadID,path)
        }
        record("AA03 ambiguous foreign or home pair",["cases":cases.count])
    }
    func testMultipleDocumentRoutesRemainConflictingEvenWhenTheyMightBeAliases() {
        let value=CurrentRoute.resolve(documents:["app://-/local/"+client,"app://-/local/"+b],selectedLinks:["/local/"+b],homeComposer:false)
        XCTAssertEqual(value.key,"conflict");XCTAssertNil(value.pendingBinding)
        record("AA04 no alias inferred between conflicting documents")
    }
    func testPairProjectionRejectsMalformedIdentifiersAndPreservesLocalHostEquivalence() {
        XCTAssertNil(ClientRoutePair(clientThreadID:a,threadID:b,documentIsClient:true))
        XCTAssertNil(ClientRoutePair(clientThreadID:client,threadID:"invalid",documentIsClient:true))
        XCTAssertNil(ClientRoutePair(["clientThreadId":client,"threadId":b]))
        let base=read("/local/"+client,["/local/"+b]),local=read("/local/"+client+"?hostId=local",["/local/"+b+"?hostId=local"])
        XCTAssertEqual(base,local);XCTAssertEqual(base.pendingBinding.flatMap {ClientRoutePair($0.dictionary)},base.pendingBinding)
        record("AA05 pair encoding and exact local scope")
    }
}
