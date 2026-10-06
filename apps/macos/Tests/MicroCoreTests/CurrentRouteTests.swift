import XCTest
@testable import MicroCore

final class CurrentRouteTests: XCTestCase {
    func testNativeFallbackRequiresUniqueSidebarAndNoAuthoritativeRoute() {
        let unknown=CurrentRoute.resolve(documents:[],selectedLinks:[],homeComposer:false)
        XCTAssertTrue(unknown.allowsNativeComposer(selectedSidebarCount:1))
        XCTAssertFalse(unknown.allowsNativeComposer(selectedSidebarCount:0))
        XCTAssertFalse(unknown.allowsNativeComposer(selectedSidebarCount:2))
        for documents in [["app://-/"],["app://-/settings"],["app://-/local/01000000-0000-0000-0000-000000000001"],["app://-/local/not-a-uuid"],["app://-/settings","app://-/"]] {
            let known=CurrentRoute.resolve(documents:documents,selectedLinks:[],homeComposer:false)
            XCTAssertFalse(known.allowsNativeComposer(selectedSidebarCount:1),"\(documents)")
        }
        XCTAssertFalse(CurrentRoute.resolve(documents:[],selectedLinks:[],homeComposer:true).allowsNativeComposer(selectedSidebarCount:1))
    }
    let a = "01000000-0000-0000-0000-000000000001"
    let b = "01000000-0000-0000-0000-000000000002"

    func testLiveDocumentWorksWithoutSidebarOrUniqueTitle() {
        let result = CurrentRoute.resolve(documents:["app://-/local/\(a)"],selectedLinks:[],homeComposer:false)
        XCTAssertEqual(result.threadID,a); XCTAssertTrue(result.known)
    }
    func testHomeAndSettingsVetoStaleSidebarSelection() {
        for path in ["/", "/settings", "/automations", "/remote/\(a)"] {
            let result = CurrentRoute.resolve(documents:["app://-\(path)"],selectedLinks:["app://-/local/\(a)"],homeComposer:false)
            XCTAssertNil(result.threadID,path); XCTAssertTrue(result.known,path); XCTAssertFalse(result.draft,path)
        }
    }
    func testHomeNeedsComposerBeforeBecomingDraft() {
        for home in [false,true] {
            let result = CurrentRoute.resolve(documents:["app://-/"],selectedLinks:["app://-/local/\(a)"],homeComposer:home)
            XCTAssertEqual(result.draft,home); XCTAssertNil(result.threadID)
        }
    }
    func testBootstrapInitialRouteCannotResurrectOldChat() {
        for page in ["index.html","detached-window.html"] {
            let document="app://-/\(page)?initialRoute=%2Flocal%2F\(a)"
            XCTAssertNil(CurrentRoute.resolve(documents:[document],selectedLinks:[],homeComposer:false).threadID)
            XCTAssertEqual(CurrentRoute.resolve(documents:[document],selectedLinks:["app://-/local/\(b)"],homeComposer:false).threadID,b)
            XCTAssertTrue(CurrentRoute.resolve(documents:[document],selectedLinks:[],homeComposer:true).draft)
        }
    }
    func testLiveRouteConflictsAreUnavailable() {
        for documents in [["app://-/local/\(a)","app://-/local/\(b)"], ["app://-/", "app://-/local/\(a)"]] {
            let result=CurrentRoute.resolve(documents:documents,selectedLinks:[],homeComposer:false)
            XCTAssertTrue(result.known); XCTAssertNil(result.threadID); XCTAssertEqual(result.key,"conflict")
        }
        XCTAssertNil(CurrentRoute.resolve(documents:["app://-/local/\(a)"],selectedLinks:["/local/\(b)"],homeComposer:false).threadID)
        XCTAssertNil(CurrentRoute.resolve(documents:["app://-/local/\(a)"],selectedLinks:[],homeComposer:true).threadID)
    }
    func testForeignURLsAndLoosePathMatchesNeverBecomeTargets() {
        for value in ["https://example.com/local/\(a)","file:///local/\(a)","app://evil/local/\(a)","app://-/foo/local/\(a)","app://-/local/\(a)/other","app://-/threads/\(a)","//evil/local/\(a)","app://user@-/local/\(a)"] {
            XCTAssertNil(CurrentRoute.sidebarThread(value),value)
            XCTAssertNil(CurrentRoute.resolve(documents:[value],selectedLinks:[],homeComposer:false).threadID,value)
        }
    }
    func testCanonicalLinksAndUppercaseUUIDs() {
        let id="01A10CC9-DFE9-70C3-A1AB-1DE3A9D80797"
        for link in ["/local/\(id)","app://-/local/\(id)?view=review","codex://threads/\(id)"] {
            XCTAssertEqual(CurrentRoute.sidebarThread(link),id.lowercased(),link)
        }
    }
    func testLiveValueOverridesEmptyOrBootstrapURLAttribute() {
        for old in ["", "app://-/index.html?initialRoute=%2Flocal%2F\(a)"] {
            let result=CurrentRoute.resolve(documents:[old,"app://-/local/\(b)"],selectedLinks:[],homeComposer:false)
            XCTAssertEqual(result.threadID,b)
        }
    }
}
