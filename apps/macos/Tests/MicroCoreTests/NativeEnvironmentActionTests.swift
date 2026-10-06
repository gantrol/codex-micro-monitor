import XCTest
import AppKit
import ApplicationServices
@testable import MicroDesktop

private final class EnvironmentActionRig:@unchecked Sendable {
    static let a="01000000-0000-0000-0000-000000000001",b="01000000-0000-0000-0000-000000000002"
    let elements=(0..<100).map {AXUIElementCreateApplication(Int32(730000+$0))}
    var thread=a,locale=0,menu=false,terminal=false,terminalCopies=1,terminalSlot=1,terminalThread=a,terminalVisible=true
    var search:String?="",projectGroups=1,hasActions=true,firstEnabled=true,firstName="Build",terminalOnRun=true
    var menuReads=0,changeAfterMenuRead:(()->Void)?,afterOpen:(()->Void)?,afterRun:(()->Void)?
    var events:[String]=[],runs=0
    func node(_ id:Int,_ parent:Int?,_ role:String,_ name:String="",identifier:String="",classes:[String]=[],enabled:Bool=true,frame:CGRect=CGRect(x:0,y:0,width:100,height:100)) -> AXNode {
        AXNode(element:elements[id],parent:parent,role:role,name:name,identifier:identifier,enabled:enabled,classes:classes,frame:frame)
    }
    var prefix:String { ["Run: ","运行：","執行：","執行："][locale] }
    func snapshot() -> MacUISnapshot {
        var nodes=[node(0,nil,"AXWindow"),node(1,0,"AXGroup"),AXNode(element:elements[2],parent:1,role:"AXTextArea",text:"unsubmitted draft",classes:["ProseMirror"]),node(3,1,"AXButton",prefix+"Test")]
        if menu {
            nodes.append(node(4,0,"AXDialog",["Command menu","命令菜单","指令選單","指令功能表"][locale],classes:["global-command-menu-dialog"]))
            nodes.append(AXNode(element:elements[5],parent:4,role:locale % 2 == 0 ? "AXComboBox":"AXTextField",text:search))
            nodes.append(node(6,4,"AXList"))
            nodes.append(node(7,6,"AXGroup",projectGroups == 0 ? "Skills":["Project","项目","項目","專案"][locale]))
            if hasActions {
                nodes.append(node(8,7,"AXRow",prefix+firstName+" ⇧⌘D",enabled:firstEnabled))
                nodes.append(node(9,8,"AXStaticText",prefix+firstName))
                nodes.append(node(10,7,"AXRow",prefix+"Test"))
                nodes.append(node(11,10,"AXStaticText",prefix+"Test"))
            }
            // A matching chat result cannot become an environment command.
            let group=nodes.count;nodes.append(node(12,6,"AXGroup","Chats"));nodes.append(node(13,group,"AXRow",prefix+"Unrelated"))
            if projectGroups > 1 {nodes.append(node(14,6,"AXGroup",["Project","项目","項目","專案"][locale]))}
        }
        if terminal {
            for copy in 0..<terminalCopies {
                let base=40+copy*3,index=nodes.count
                nodes.append(node(base,0,"AXGroup","Build",identifier:"app-shell-tab-panel-action-\(copy)",frame:terminalVisible ? CGRect(x:0,y:0,width:200,height:100):.zero))
                nodes.append(node(base+1,index,"AXGroup",identifier:"terminal-panel-environment-action:\(terminalThread):workspace:environmentAction\(terminalSlot)"))
                nodes.append(node(base+2,index+1,"AXTextArea",classes:["xterm-helper-textarea"],frame:.zero))
            }
        }
        return MacUISnapshot(app:NSRunningApplication.current,root:elements[0],window:elements[0],nodes:nodes,
            composer:menu || terminal ? nil:2,container:menu || terminal ? nil:1,thread:thread,draft:false,route:"thread:"+thread,
            selectionKnown:true,nativeFallback:false,selectedSidebar:nil,controls:[],menuItems:[],blocked:menu,modelLabels:[])
    }
    var io:NativeUIAccess {
        var io=NativeUIAccess();io.observeActivation=false
        io.shortcut={_ in throw NSError(domain:"MicroReplay.NoConfiguredShortcut",code:1)}
        io.foreground={NSRunningApplication.current.processIdentifier};io.activate={_ in XCTFail("No activation expected");return false}
        io.capture={ [self] _,_ in
            let state=snapshot()
            if menu {menuReads += 1;if menuReads == 1 {changeAfterMenuRead?()}}
            return state
        }
        io.applicationCommand={ [self] _,names,_ in XCTAssertEqual(names,NativeCommandMenu.openMenu);return node(90,nil,"AXMenuItem","Open command menu") }
        io.press={ [self] element in
            if CFEqual(element,elements[90]) {events.append("open-command-menu");menu=true;menuReads=0;afterOpen?()}
            else if CFEqual(element,elements[8]),menu {events.append("run:"+firstName);runs += 1;menu=false;terminal=terminalOnRun;afterRun?()}
            else {XCTFail("Never choose the MRU toolbar button, another slot or a chat result")}
        }
        io.send={ [self] key,_,check in try check();XCTAssertEqual(key.key,53);XCTAssertTrue(menu);events.append("close-owned-menu");menu=false }
        io.set={_,_,_ in XCTFail("Never change search or type a shell command")}
        return io
    }
    func run(_ controller:MacUIController) async throws -> [String:Any] {
        let state=try await controller.execute("get_keypad_ui_state",arguments:[:])
        return try await controller.execute("run_keypad_environment_action",arguments:["thread_id":Self.a,"target_token":try XCTUnwrap(state["targetToken"] as? String)])
    }
    func record(_ scenario:String) {
        ReplayTrace.emit("ENVIRONMENT-ACTION-TRACE",["scenario":scenario,"events":events,"runs":runs,"menuOpen":menu,"terminalVisible":terminal && terminalVisible,"locale":locale])
    }
}

final class NativeEnvironmentActionTests:XCTestCase {
    func testFirstConfiguredActionIsNotMRUToolbarOrChatResultInFourLocales() async throws {
        for locale in 0..<4 {
            let rig=EnvironmentActionRig();rig.locale=locale
            let result=try await rig.run(MacUIController(io:rig.io))
            XCTAssertEqual(result["verified"] as? Bool,true);XCTAssertEqual(result["runRequested"] as? Bool,true)
            XCTAssertEqual(result["terminalVerified"] as? Bool,true);XCTAssertEqual(result["executionVerified"] as? Bool,false)
            XCTAssertEqual(rig.events,["open-command-menu","run:Build"])
            XCTAssertTrue((result["terminalIdentifier"] as? String)?.hasSuffix(":environmentAction1") == true)
            rig.record("E01 first configured action locale \(locale)")
        }
    }
    func testExplicitSecondPressReusesActionTerminalWithoutInventingCompletion() async throws {
        let rig=EnvironmentActionRig();rig.terminal=true
        let controller=MacUIController(io:rig.io)
        for _ in 0..<2 {
            let result=try await rig.run(controller)
            XCTAssertEqual(result["executionVerified"] as? Bool,false);XCTAssertEqual(result["terminalVerified"] as? Bool,true)
        }
        XCTAssertEqual(rig.runs,2);XCTAssertEqual(rig.events,["open-command-menu","run:Build","open-command-menu","run:Build"])
        rig.record("E02 explicit repeated action reuses terminal")
    }
    func testNonemptyOrUnreadableSearchNeverRunsFilteredFirstRow() async {
        for search:String? in ["Test",nil] {
            let rig=EnvironmentActionRig();rig.search=search
            do {_ = try await rig.run(MacUIController(io:rig.io));XCTFail("Filtered or unknown search must fail")} catch {}
            XCTAssertEqual(rig.events,["open-command-menu","close-owned-menu"]);XCTAssertEqual(rig.runs,0)
            rig.record("E03 search \(search == nil ? "unknown":"filtered")")
        }
    }
    func testMissingAmbiguousGroupsMissingActionsOrDisabledSlotNeverRunAnotherSlot() async {
        for scenario in 0..<4 {
            let rig=EnvironmentActionRig()
            switch scenario {case 0:rig.projectGroups=0;case 1:rig.projectGroups=2;case 2:rig.hasActions=false;default:rig.firstEnabled=false}
            do {_ = try await rig.run(MacUIController(io:rig.io));XCTFail("Unavailable first action must fail")} catch {}
            XCTAssertEqual(rig.runs,0);XCTAssertEqual(rig.events,["open-command-menu","close-owned-menu"])
            rig.record("E04 unavailable first slot \(scenario)")
        }
    }
    func testChangedConfigurationWithSameAXElementIsNotPressed() async {
        let rig=EnvironmentActionRig();rig.changeAfterMenuRead={rig.firstName="Different command"}
        do {_ = try await rig.run(MacUIController(io:rig.io));XCTFail("Changed command must fail")} catch {}
        XCTAssertEqual(rig.runs,0);XCTAssertEqual(rig.events,["open-command-menu","close-owned-menu"])
        rig.record("E05 changed command label with reused element")
    }
    func testWrongActionOtherChatHiddenDuplicateOrMissingTerminalStayUnknownWithoutReplay() async {
        for scenario in 0..<5 {
            let rig=EnvironmentActionRig()
            switch scenario {case 0:rig.terminalSlot=2;case 1:rig.terminalThread=EnvironmentActionRig.b;case 2:rig.terminalVisible=false;case 3:rig.terminalCopies=2;default:rig.terminalOnRun=false}
            do {_ = try await rig.run(MacUIController(io:rig.io));XCTFail("Wrong terminal must not confirm handoff")} catch {}
            XCTAssertEqual(rig.runs,1);XCTAssertEqual(rig.events,["open-command-menu","run:Build"])
            rig.record("E06 incorrect terminal \(scenario)")
        }
    }
    func testTargetChangeBeforeOrAfterRunNeverConfirmsAnotherChatOrReplays() async {
        for after in [false,true] {
            let rig=EnvironmentActionRig()
            if after {rig.afterRun={rig.thread=EnvironmentActionRig.b}} else {rig.afterOpen={rig.thread=EnvironmentActionRig.b}}
            do {_ = try await rig.run(MacUIController(io:rig.io));XCTFail("Changed target must fail")} catch {}
            XCTAssertEqual(rig.runs,after ? 1:0);XCTAssertFalse(rig.events.contains("close-owned-menu"))
            rig.record("E07 target changed after run \(after)")
        }
    }
}
