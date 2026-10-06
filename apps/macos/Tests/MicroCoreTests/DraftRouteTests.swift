import XCTest
import ApplicationServices
@testable import MicroCore
@testable import MicroDesktop

final class DraftRouteTests:XCTestCase {
    let a="01000000-0000-0000-0000-000000000001"
    func route(_ path:String,home:Bool=false,composer:Bool=true)->CurrentRoute {
        CurrentRoute.resolve(documents:["app://-"+path],selectedLinks:["/local/"+a],homeComposer:home,composerAvailable:composer)
    }
    func record(_ id:String,_ values:[String:Any]=[:]) {ReplayTrace.emit("DRAFT-ROUTE-TRACE",values.merging(["scenario":id]) {a,_ in a})}
    func testHotkeyDraftsRequireVisibleComposerAndRetireStaleSidebarID() {
        for path in ["/hotkey-window","/hotkey-window/new-thread"] {
            let actual=route(path);XCTAssertTrue(actual.draft);XCTAssertNil(actual.threadID);XCTAssertNil(actual.clientThreadID)
            XCTAssertEqual(actual.key,"draft:"+path)
            let empty=route(path,composer:false);XCTAssertFalse(empty.draft);XCTAssertTrue(empty.known)
        }
        XCTAssertNotEqual(route("/hotkey-window").key,route("/hotkey-window/new-thread").key)
        record("Z01 hotkey routes require composer")
    }
    func testProjectDraftRequiresHomeAndExactProjectScope() {
        XCTAssertFalse(route("/projects?projectId=project-a").draft)
        let first=route("/projects?projectId=project-a",home:true),second=route("/projects?projectId=project-b",home:true)
        XCTAssertTrue(first.draft);XCTAssertNil(first.threadID);XCTAssertNotEqual(first.key,second.key)
        XCTAssertEqual(first,route("/projects?hostId=local&projectId=project-a&view=review",home:true))
        XCTAssertEqual(route("/projects?projectId=project%2Fa",home:true).key,"draft:/projects?projectId=project%2Fa")
        record("Z02 project scope participates in draft identity")
    }
    func testInvalidOrForeignDraftPagesCannotUseComposerFallback() {
        var paths=["/projects","/projects?projectId=","/projects?projectId","/projects?projectId=a&projectId=b",
                   "/projects?projectId=a&projectId=a","/projects?projectId=%00","/projects?projectId="+String(repeating:"a",count:257),
                   "/hotkey-window/unknown","/hotkey-window/new-thread/child","/hotkey-window/new-thread/","/extension/panel/new",
                   "/dots/new","/o/new","/g/project/project","/agents/a/agent"]
        for path in ["/hotkey-window","/hotkey-window/new-thread","/projects?projectId=a"] {
            for query in ["hostId=remote","hostId=durable","hostId=","hostId=local&hostId=local"] {paths.append(path+(path.contains("?") ? "&":"?")+query)}
        }
        for path in paths {
            let value=route(path,home:true);XCTAssertFalse(value.draft,path);XCTAssertNil(value.threadID,path)
            XCTAssertFalse(value.allowsNativeComposer(selectedSidebarCount:1),path)
        }
        record("Z03 unsupported ambiguous and foreign draft pages",["cases":paths.count])
    }
    func testMultipleDocumentsRejectDifferentProjectOrDraftSurface() {
        for paths in [["/projects?projectId=a","/projects?projectId=b"],["/","/hotkey-window"],["/hotkey-window","/hotkey-window/new-thread"]] {
            let value=CurrentRoute.resolve(documents:paths.map {"app://-"+$0},selectedLinks:[],homeComposer:true,composerAvailable:true)
            XCTAssertEqual(value.key,"conflict");XCTAssertFalse(value.draft)
        }
        let same=CurrentRoute.resolve(documents:["app://-/projects?projectId=a","app://-/projects?view=review&projectId=a&hostId=local"],selectedLinks:[],homeComposer:true,composerAvailable:true)
        XCTAssertTrue(same.draft)
        record("Z04 multiple document scope agreement")
    }
    private func nodes(_ path:String,home:Bool=false,hidden:Bool=false)->[AXNode] {
        let elements=(0..<7).map {AXUIElementCreateApplication(Int32(600000+$0))}
        return [AXNode(element:elements[0],role:"AXWindow"),
                AXNode(element:elements[1],parent:0,role:"AXWebArea",frame:hidden ? .zero:CGRect(x:0,y:0,width:500,height:500),documentURLs:["app://-"+path]),
                AXNode(element:elements[2],parent:1,role:"AXGroup",classes:home ? ["[container-name:home-main-content]"]:[]),
                AXNode(element:elements[3],parent:2,role:"AXTextArea",text:"draft",classes:["ProseMirror"]),
                AXNode(element:elements[4],parent:2,role:"AXButton",name:"Select model"),
                AXNode(element:elements[5],parent:2,role:"AXButton",name:"Add files and more"),
                AXNode(element:elements[6],parent:1,role:"AXLink",classes:["sidebar-item"],url:"/local/"+a,current:true)]
    }
    func testProductionAXRouteProjectionUsesHotkeyComposerWithoutMainHomeClass() {
        for path in ["/hotkey-window","/hotkey-window/new-thread"] {
            let tree=nodes(path),value=MacUISnapshot.observeRoute(nodes:tree,composer:3,container:2)
            XCTAssertTrue(value.draft);XCTAssertNil(value.threadID)
            XCTAssertFalse(MacUISnapshot.observeRoute(nodes:tree,composer:nil,container:nil).draft)
            XCTAssertFalse(MacUISnapshot.observeRoute(nodes:tree,composer:3,container:nil).draft)
        }
        record("Z05 production AX route projection without main home class")
    }
    func testProductionAXProjectionKeepsProjectScopeAndIgnoresNestedDocuments() {
        let first=MacUISnapshot.observeRoute(nodes:nodes("/projects?projectId=a",home:true),composer:3,container:2)
        let second=MacUISnapshot.observeRoute(nodes:nodes("/projects?projectId=b",home:true),composer:3,container:2)
        XCTAssertTrue(first.draft);XCTAssertNotEqual(first.key,second.key)
        var nested=nodes("/local/"+a)
        nested.append(AXNode(element:AXUIElementCreateApplication(600007),parent:1,role:"AXWebArea",documentURLs:["app://-/hotkey-window"]))
        let actual=MacUISnapshot.observeRoute(nodes:nested,composer:3,container:2)
        XCTAssertEqual(actual.threadID,a);XCTAssertFalse(actual.draft)
        record("Z06 production AX project scope and nested document exclusion")
    }
}
