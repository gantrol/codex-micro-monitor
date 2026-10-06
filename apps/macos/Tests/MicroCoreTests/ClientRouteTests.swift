import XCTest
@testable import MicroCore

final class ClientRouteTests:XCTestCase {
    let a="01000000-0000-0000-0000-000000000001",b="01000000-0000-0000-0000-000000000002"
    var client:String {"client-new-thread:"+a}
    func record(_ id:String,_ values:[String:Any]=[:]) {ReplayTrace.emit("CLIENT-ROUTE-TRACE",values.merging(["scenario":id]) {a,_ in a})}
    func testClientRouteHasExactIdentityButIsNeitherServerThreadNorUnsentDraft() {
        let paths=["/local/\(client)","/local/client-new-thread%3A\(a)","/hotkey-window/thread/\(client)"]
        for path in paths {
            let route=CurrentRoute.resolve(documents:["app://-"+path],selectedLinks:[],homeComposer:false)
            XCTAssertEqual(route.clientThreadID,client);XCTAssertEqual(route.key,"client:"+client)
            XCTAssertTrue(route.known);XCTAssertFalse(route.draft);XCTAssertNil(route.threadID)
            XCTAssertNil(CurrentRoute.sidebarThread(path))
        }
        record("W01 exact client route",["paths":paths,"clientThreadId":client,"serverUUID":false,"unsentDraft":false])
    }
    func testHotkeyLocalRoutesAndExplicitLocalHostResolveCanonicalUUIDs() {
        let id="01A10CC9-DFE9-70C3-A1AB-1DE3A9D80797"
        for path in ["/local/\(id)?hostId=local&view=review","/hotkey-window/thread/\(id)","/hotkey-window/thread/\(id)?hostId=local"] {
            let route=CurrentRoute.resolve(documents:["app://-"+path],selectedLinks:[],homeComposer:false)
            XCTAssertEqual(route.threadID,id.lowercased());XCTAssertEqual(CurrentRoute.sidebarThread(path),id.lowercased())
        }
        record("W02 hotkey and explicit local host",["id":id.lowercased()])
    }
    func testForeignOrAmbiguousHostCannotFallBackToLocalSidebarOrHome() {
        let queries=["hostId=remote-workstation","hostId=durable","hostId=","hostId","hostId=LOCAL","hostId=local&hostId=remote","hostId=local&hostId=local","%68ostId=remote"]
        for query in queries {
            for path in ["/local/\(a)","/local/\(client)","/hotkey-window/thread/\(a)","/"] {
                let route=CurrentRoute.resolve(documents:["app://-\(path)?\(query)"],selectedLinks:["/local/\(a)"],homeComposer:true)
                XCTAssertNil(route.threadID);XCTAssertNil(route.clientThreadID);XCTAssertFalse(route.draft);XCTAssertTrue(route.known)
                XCTAssertFalse(route.allowsNativeComposer(selectedSidebarCount:1))
                XCTAssertNil(CurrentRoute.sidebarThread(path+"?"+query))
            }
        }
        record("W03 nonlocal and ambiguous hosts",["queries":queries,"combinations":queries.count*4])
    }
    func testSelectedRemoteIdentityConflictsWithLocalDocumentEvenForSameUUID() {
        for selection in ["/local/\(a)?hostId=remote","codex://threads/\(a)?hostId=remote"] {
            let known=CurrentRoute.resolve(documents:["app://-/local/\(a)"],selectedLinks:[selection],homeComposer:false)
            XCTAssertEqual(known.key,"conflict");XCTAssertNil(known.threadID)
            let bootstrap=CurrentRoute.resolve(documents:["app://-/index.html?initialRoute=/local/\(a)"],selectedLinks:[selection],homeComposer:false)
            XCTAssertTrue(bootstrap.known);XCTAssertNil(bootstrap.threadID);XCTAssertFalse(bootstrap.allowsNativeComposer(selectedSidebarCount:1))
        }
        record("W04 selected host conflicts",["sameUUID":a,"fallback":false])
    }
    func testMalformedClientIdentitiesAndForeignWebsitesNeverAcquireIdentity() {
        for path in ["/local/client-new-thread:","/local/client-new-thread:not-a-uuid","/local/\(client)/child","/local/\(client)%2Fchild","/local/client-new-thread:\(a):suffix","/unrelated/\(client)"] {
            let route=CurrentRoute.resolve(documents:["app://-"+path],selectedLinks:[],homeComposer:false)
            XCTAssertNil(route.clientThreadID);XCTAssertFalse(route.draft);XCTAssertFalse(route.allowsNativeComposer(selectedSidebarCount:1))
        }
        for url in ["https://example.com/local/\(client)","app://other/local/\(client)","codex://threads/\(client)"] {
            let route=CurrentRoute.resolve(documents:[url],selectedLinks:[url],homeComposer:false)
            XCTAssertNil(route.clientThreadID);XCTAssertNil(route.threadID)
        }
        record("W05 malformed client identity",["accepted":0])
    }
    func testClientDocumentRejectsConflictingSelectionAndClientChanges() {
        for selection in ["/local/client-new-thread:\(b)","/local/\(client)?hostId=remote"] {
            XCTAssertEqual(CurrentRoute.resolve(documents:["app://-/local/\(client)"],selectedLinks:[selection],homeComposer:false).key,"conflict")
        }
        let pending=CurrentRoute.resolve(documents:["app://-/local/\(client)"],selectedLinks:["/local/\(a)"],homeComposer:false)
        XCTAssertNotNil(pending.pendingBinding);XCTAssertNil(pending.threadID);XCTAssertNil(pending.clientThreadID)
        let route=CurrentRoute.resolve(documents:["app://-/local/\(client)"],selectedLinks:["/local/\(client)"],homeComposer:true)
        XCTAssertEqual(route.clientThreadID,client);XCTAssertFalse(route.draft)
        let changed=CurrentRoute.resolve(documents:["app://-/local/\(client)","app://-/local/client-new-thread:\(b)"],selectedLinks:[],homeComposer:false)
        XCTAssertEqual(changed.key,"conflict")
        record("W06 client document conflicts",["clientThreadId":client])
    }
    func testEquivalentLocalDocumentsKeepIdentityButHostChangeIsAConflict() {
        let documents=["app://-/local/\(a)","app://-/local/\(a)?hostId=local&view=review"]
        XCTAssertEqual(CurrentRoute.resolve(documents:documents,selectedLinks:[],homeComposer:false).threadID,a)
        let foreign=CurrentRoute.resolve(documents:documents+["app://-/local/\(a)?hostId=remote"],selectedLinks:[],homeComposer:false)
        XCTAssertEqual(foreign.key,"conflict");XCTAssertNil(foreign.threadID)
        record("W07 query scope participates in identity",["sameLocalID":a,"foreignConflict":true])
    }
}
