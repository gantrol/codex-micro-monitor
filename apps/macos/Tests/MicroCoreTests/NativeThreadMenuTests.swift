import XCTest
import AppKit
import ApplicationServices
@testable import MicroDesktop

private final class ThreadMenuRig: @unchecked Sendable {
    static let a="01000000-0000-0000-0000-000000000001",b="01000000-0000-0000-0000-000000000002"
    let elements=(0..<100).map { AXUIElementCreateApplication(Int32(700000+$0)) }
    var thread:String?=a,menu=false,copyMenu=false,pinned=false,toast=false,blocked=false,chinese=false
    var duplicateTrigger=false,ambiguousPin=false,confirmation=false,copyChanges=1,hiddenComposer=false
    var clipboard=NativeClipboardState(changeCount:5,text:"fixture user's clipboard")
    var events:[String]=[],afterOpen:(()->Void)?
    var terminalCount=0,terminalCommandAvailable=true,terminalHidden=false
    var browserCount=0,browserCommandAvailable=true,browserNoop=false,browserHidden=false,browserAddressOnly=false,hideComposerAfterPanel=false
    var commandLookup:(()->Void)?
    var afterPanelCommand:(()->Void)?
    var feedbackCommandAvailable=true,feedbackOpen=false,feedbackWrongDialog=false
    var sideChatAvailable=true,sideChatCount=0,sideChatNoop=false,sideChatReady=true
    var io:NativeUIAccess {
        var access=NativeUIAccess();access.observeActivation=false
        access.shortcut={_ in throw NSError(domain:"MicroReplay.NoConfiguredShortcut",code:1)}
        access.foreground={NSRunningApplication.current.processIdentifier}
        access.activate={_ in XCTFail("No app activation in replay");return false}
        access.capture={ [self] _,_ in snapshot() }
        access.applicationCommand={ [self] pid,names,_ in
            XCTAssertEqual(pid,NSRunningApplication.current.processIdentifier)
            commandLookup?()
            if names.contains("Send Feedback") {return feedbackCommandAvailable ? AXNode(element:elements[60],role:"AXMenuItem",name:chinese ? "反馈":"Send Feedback"):nil}
            if names.contains("Open Browser Tab") { return browserCommandAvailable ? AXNode(element:elements[30],role:"AXMenuItem",name:chinese ? "打开浏览器标签页":"Open Browser Tab"):nil }
            XCTAssertTrue(names.contains("Open Terminal"))
            return terminalCommandAvailable ? AXNode(element:elements[20],role:"AXMenuItem",name:"Open Terminal"):nil
        }
        access.clipboard={ [self] in clipboard }
        access.clipboardCount={ [self] in clipboard.changeCount }
        access.press={ [self] element in
            let id=elements.firstIndex(where:{CFEqual($0,element)})!;events.append("press:\(id)")
            switch id {
            case 6:menu=true;afterOpen?()
            case 8:pinned.toggle();menu=false
            case 9:menu=false;if confirmation {blocked=true} else {thread=nil}
            case 12:menu=false;copyMenu=false;toast=true;clipboard = .init(changeCount:clipboard.changeCount+copyChanges,text:"# User\nFixture prompt\n\n# Assistant\nFixture reply")
            case 20:terminalCount = terminalCount == 0 ? 1:terminalCount-1;hiddenComposer = hiddenComposer || hideComposerAfterPanel;afterPanelCommand?()
            case 30:if !browserNoop {browserCount += 1};hiddenComposer = hiddenComposer || hideComposerAfterPanel;afterPanelCommand?()
            case 60:feedbackOpen=true;blocked=true;afterPanelCommand?()
            case 17:menu=false;if !sideChatNoop {sideChatCount += 1};hiddenComposer=true;afterPanelCommand?()
            default:XCTFail("Unexpected native press: \(id)")
            }
        }
        access.expand={ [self] element in XCTAssertTrue(CFEqual(element,elements[10]));events.append("expand:copy");copyMenu=true }
        access.set={_,_,_ in XCTFail("Replay must not write native text, clipboard or consent")}
        access.send={ [self] shortcut,_,check in try check();XCTAssertEqual(shortcut.key,53);events.append("escape");menu=false;copyMenu=false }
        return access
    }
    func snapshot() -> MacUISnapshot {
        func node(_ id:Int,_ parent:Int?,_ role:String,_ name:String,expanded:Bool?=nil) -> AXNode {
            AXNode(element:elements[id],parent:parent,role:role,name:name,expanded:expanded)
        }
        var nodes=[node(0,nil,"AXWindow","fixture"),node(1,0,"AXGroup","composer"),
                   AXNode(element:elements[2],parent:1,role:"AXTextArea",text:"kept draft"),node(3,1,"AXButton","Select model"),
                   node(4,1,"AXButton","Add files and more"),node(5,1,"AXButton","Send"),
                   node(6,0,"AXButton",chinese ? "聊天操作":"Chat actions",expanded:menu)]
        var items:[Int]=[]
        if menu {
            nodes.append(node(7,nil,"AXMenu","native application menu"))
            nodes.append(node(8,7,"AXMenuItem",chinese ? (pinned ? "取消置顶":"置顶"):(pinned ? "Unpin":"Pin")))
            nodes.append(node(9,7,"AXMenuItem",chinese ? "归档":"Archive"))
            nodes.append(node(10,7,"AXMenuItem",chinese ? "复制":"Copy"));items += [8,9,10]
            if copyMenu {nodes.append(node(11,7,"AXMenu","copy submenu"));nodes.append(node(12,11,"AXMenuItem",chinese ? "复制为 Markdown":"Copy as Markdown"));items.append(12)}
            if sideChatAvailable {nodes.append(node(17,7,"AXMenuItem",chinese ? "新建侧边聊天":"New side chat"));items.append(nodes.count-1)}
            if ambiguousPin {nodes.append(node(15,7,"AXMenuItem","Unpin"));items.append(nodes.count-1)}
        }
        if toast {nodes.append(node(13,0,"AXStaticText",chinese ? "已将对话复制为 Markdown":"Copied conversation as Markdown"))}
        if duplicateTrigger {nodes.append(node(14,0,"AXButton","Chat actions"))}
        for i in 0..<terminalCount {
            let parent=nodes.count
            nodes.append(AXNode(element:elements[21+i*2],parent:0,role:"AXGroup",identifier:"app-shell-tab-panel-fixture-\(i)",frame:terminalHidden ? .zero:CGRect(x:0,y:0,width:300,height:200)))
            nodes.append(AXNode(element:elements[22+i*2],parent:parent,role:"AXTextArea",name:"Terminal input",classes:["xterm-helper-textarea"],frame:.zero))
        }
        for i in 0..<browserCount {
            let parent=nodes.count
            nodes.append(AXNode(element:elements[31+i*2],parent:0,role:"AXGroup",identifier:browserAddressOnly ? "unrelated-form":"app-shell-tab-panel-browser-\(i)",frame:browserHidden ? .zero:CGRect(x:0,y:0,width:300,height:200)))
            nodes.append(AXNode(element:elements[32+i*2],parent:parent,role:i.isMultiple(of:2) ? "AXComboBox":"AXTextField",name:chinese ? "搜索或输入网址":"Search or enter a URL"))
        }
        if feedbackOpen {
            let dialog=nodes.count
            nodes.append(node(61,0,"AXDialog",feedbackWrongDialog ? "Permission requested":chinese ? "提交反馈":"Share feedback"))
            nodes.append(node(62,dialog,"AXTextArea",chinese ? "填写详情（必填）":"Share details (required)"))
            nodes.append(node(63,dialog,"AXRadioGroup",chinese ? "反馈选项":"Feedback options"))
        }
        for i in 0..<sideChatCount {
            let panel=nodes.count
            nodes.append(AXNode(element:elements[70+i*2],parent:0,role:"AXGroup",name:(chinese ? "侧边聊天":"Side chat")+(i == 0 ? "":" \(i+1)"),identifier:"app-shell-tab-panel-side-fixture-\(i)"))
            if sideChatReady {nodes.append(AXNode(element:elements[71+i*2],parent:panel,role:"AXTextArea",text:"",classes:["ProseMirror"]))}
        }
        return MacUISnapshot(app:NSRunningApplication.current,root:elements[0],window:elements[0],nodes:nodes,composer:hiddenComposer ? nil:2,container:hiddenComposer ? nil:1,thread:thread,draft:false,
            route:thread.map{"thread:"+$0} ?? "page:/",selectionKnown:true,nativeFallback:false,selectedSidebar:nil,controls:hiddenComposer ? []:[3,4,5],menuItems:items,blocked:blocked,modelLabels:[])
    }
    func run(_ controller:MacUIController,_ operation:String) async throws -> [String:Any] {
        let state=try await controller.execute("get_keypad_ui_state",arguments:[:])
        return try await controller.execute(operation,arguments:["thread_id":Self.a,"target_token":try XCTUnwrap(state["targetToken"] as? String)])
    }
    func record(_ scenario:String) {
        let value:[String:Any]=["scenario":scenario,"events":events,"pinned":pinned,"menuOpen":menu,"pendingConfirmation":blocked,"clipboardChanges":clipboard.changeCount-5,"terminalPanels":snapshot().visibleTerminalCount,"browserPanels":snapshot().browserPanels.count,"sideChatPanels":snapshot().sideChatPanels.count,"feedbackDialog":snapshot().feedbackDialog != nil,"composerVisible":!hiddenComposer]
        ReplayTrace.emit("THREAD-MENU-TRACE",value)
    }
}

final class NativeThreadMenuTests:XCTestCase {
    func testFeedbackOpensSpecificDialogWithoutTypingSubmittingOrChangingConsent() async throws {
        for chinese in [false,true] {
            let rig=ThreadMenuRig();rig.chinese=chinese
            let result=try await rig.run(MacUIController(io:rig.io),"open_keypad_feedback")
            XCTAssertEqual(result["verified"] as? Bool,true);XCTAssertEqual(result["submitted"] as? Bool,false)
            XCTAssertEqual(rig.events,["press:60"]);XCTAssertEqual(rig.clipboard.changeCount,5)
            XCTAssertEqual(rig.snapshot().editor?.text,"kept draft")
            rig.record("T13 native feedback form "+(chinese ? "zh":"en"))
        }
    }
    func testFeedbackWorksOnKnownPageWithoutComposerOrModelPicker() async throws {
        let rig=ThreadMenuRig();rig.thread=nil;rig.hiddenComposer=true
        let controller=MacUIController(io:rig.io)
        let state=try await controller.execute("get_keypad_ui_state",arguments:[:])
        XCTAssertEqual(state["canOpenFeedback"] as? Bool,true);XCTAssertEqual(state["canSubmit"] as? Bool,false)
        let result=try await controller.execute("open_keypad_feedback",arguments:["target_token":try XCTUnwrap(state["targetToken"] as? String)])
        XCTAssertEqual(result["verified"] as? Bool,true);XCTAssertEqual(rig.events,["press:60"])
    }
    func testOtherDialogAndTargetChangeCannotConfirmFeedbackOrDismissDialog() async {
        for changed in [false,true] {
            let rig=ThreadMenuRig();rig.feedbackWrongDialog = !changed
            if changed {rig.afterPanelCommand={rig.thread=ThreadMenuRig.b}}
            do {_ = try await rig.run(MacUIController(io:rig.io),"open_keypad_feedback");XCTFail("Must not confirm other dialog or target")} catch {}
            XCTAssertEqual(rig.events,["press:60"]);XCTAssertTrue(rig.blocked)
            rig.record("T14 feedback refuses "+(changed ? "changed-target":"permission-dialog"))
        }
    }
    func testFeedbackMissingCommandAndChangedPageSendNothing() async {
        let missing=ThreadMenuRig();missing.feedbackCommandAvailable=false
        do {_ = try await missing.run(MacUIController(io:missing.io),"open_keypad_feedback");XCTFail("Missing command must fail")} catch {}
        XCTAssertTrue(missing.events.isEmpty)
        let changed=ThreadMenuRig();changed.commandLookup={changed.thread=nil}
        do {_ = try await changed.run(MacUIController(io:changed.io),"open_keypad_feedback");XCTFail("Changed page must fail")} catch {}
        XCTAssertTrue(changed.events.isEmpty)
    }
    func testSideChatCreatesNewPanelWithComposerForExactParent() async throws {
        for chinese in [false,true] {
            let rig=ThreadMenuRig();rig.chinese=chinese;rig.sideChatCount=1
            let result=try await rig.run(MacUIController(io:rig.io),"open_keypad_side_chat")
            XCTAssertEqual(result["verified"] as? Bool,true);XCTAssertEqual(result["parentThreadId"] as? String,ThreadMenuRig.a)
            XCTAssertEqual(result["sideChatPanel"] as? String,"app-shell-tab-panel-side-fixture-1")
            XCTAssertNil(result["threadId"]);XCTAssertEqual(rig.events,["press:6","press:17"])
            rig.record("T15 new side chat "+(chinese ? "zh":"en"))
        }
    }
    func testExistingOrLoadingSideChatDoesNotConfirmOrReplayCreation() async {
        for loading in [false,true] {
            let rig=ThreadMenuRig();rig.sideChatCount=1;rig.sideChatNoop = !loading;rig.sideChatReady = !loading
            do {_ = try await rig.run(MacUIController(io:rig.io),"open_keypad_side_chat");XCTFail("Must observe a new ready side chat")} catch {}
            XCTAssertEqual(rig.events,["press:6","press:17"])
            rig.record("T16 side chat "+(loading ? "loading":"existing"))
        }
    }
    func testSideChatUnavailableOrTargetChangesNeverCreatesAnotherChat() async {
        let missing=ThreadMenuRig();missing.sideChatAvailable=false
        do {_ = try await missing.run(MacUIController(io:missing.io),"open_keypad_side_chat");XCTFail("Missing item must fail")} catch {}
        XCTAssertEqual(missing.events,["press:6","escape"])
        let changed=ThreadMenuRig();changed.afterOpen={changed.thread=ThreadMenuRig.b}
        do {_ = try await changed.run(MacUIController(io:changed.io),"open_keypad_side_chat");XCTFail("Changed target must fail")} catch {}
        XCTAssertEqual(changed.events,["press:6"])
    }
    func testBrowserCommandCreatesANewVisiblePanelAndKeepsExactChat() async throws {
        for chinese in [false,true] {
            let rig=ThreadMenuRig();rig.browserCount=1;rig.chinese=chinese;rig.hideComposerAfterPanel=true
            let result=try await rig.run(MacUIController(io:rig.io),"open_keypad_browser")
            XCTAssertEqual(result["verified"] as? Bool,true);XCTAssertEqual(result["threadId"] as? String,ThreadMenuRig.a)
            XCTAssertEqual(result["browserPanel"] as? String,"app-shell-tab-panel-browser-1")
            XCTAssertTrue(rig.hiddenComposer);XCTAssertEqual(rig.events,["press:30"])
            rig.record("T10 new Codex browser panel "+(chinese ? "zh":"en"))
        }
    }
    func testBrowserExistingPanelOrAddressOutsidePanelCannotConfirmNewTab() async {
        for unrelated in [false,true] {
            let rig=ThreadMenuRig();rig.browserCount=1;rig.browserNoop = !unrelated;rig.browserAddressOnly=unrelated
            do {_ = try await rig.run(MacUIController(io:rig.io),"open_keypad_browser");XCTFail("Must observe a new browser panel")} catch {}
            XCTAssertEqual(rig.events,["press:30"])
            rig.record("T11 browser no new panel "+(unrelated ? "unrelated-field":"existing"))
        }
        let hidden=ThreadMenuRig();hidden.browserCount=1;hidden.browserHidden=true
        XCTAssertEqual(hidden.snapshot().browserPanels.count,1)
        XCTAssertTrue(hidden.snapshot().browserPanels.allSatisfy{$0.rect.isEmpty})
    }
    func testBrowserMissingCommandAndChangedTargetDoNotDispatch() async {
        let missing=ThreadMenuRig();missing.browserCommandAvailable=false
        do {_ = try await missing.run(MacUIController(io:missing.io),"open_keypad_browser");XCTFail("Must reject missing command")} catch {}
        XCTAssertTrue(missing.events.isEmpty)
        let changed=ThreadMenuRig();changed.commandLookup={changed.thread=ThreadMenuRig.b}
        do {_ = try await changed.run(MacUIController(io:changed.io),"open_keypad_browser");XCTFail("Must reject changed target")} catch {}
        XCTAssertTrue(changed.events.isEmpty)
    }
    func testTerminalReadbackAllowsComposerToHideWhileChatStaysExact() async throws {
        let rig=ThreadMenuRig();rig.hideComposerAfterPanel=true
        let result=try await rig.run(MacUIController(io:rig.io),"toggle_keypad_terminal")
        XCTAssertEqual(result["verified"] as? Bool,true);XCTAssertTrue(rig.hiddenComposer)
        XCTAssertEqual(rig.events,["press:20"])
    }
    func testPanelOnAnotherChatAfterCommandIsNeverConfirmedOrReplayed() async {
        for operation in ["toggle_keypad_terminal","open_keypad_browser"] {
            let rig=ThreadMenuRig();rig.afterPanelCommand={rig.thread=ThreadMenuRig.b}
            do {_ = try await rig.run(MacUIController(io:rig.io),operation);XCTFail("Must retain exact chat for readback")} catch {}
            XCTAssertEqual(rig.events.count,1)
            rig.record("T12 changed chat during "+operation)
        }
    }
    func testTerminalNativeMenuTogglePreservesComposerAndNeverTypesInput() async throws {
        let rig=ThreadMenuRig()
        let actual=MacUIController(io:rig.io)
        for expected in [true,false] {
            let result=try await rig.run(actual,"toggle_keypad_terminal")
            XCTAssertEqual(result["terminalVisible"] as? Bool,expected);XCTAssertEqual(result["verified"] as? Bool,true)
        }
        XCTAssertEqual(rig.events,["press:20","press:20"]);XCTAssertEqual(rig.snapshot().editor?.text,"kept draft")
        rig.record("T08 terminal native menu round trip")
    }
    func testTerminalWorksWithoutComposerAndClosingOneOfTwoPanelsIsVerified() async throws {
        let rig=ThreadMenuRig();rig.hiddenComposer=true;rig.terminalCount=2
        let result=try await rig.run(MacUIController(io:rig.io),"toggle_keypad_terminal")
        XCTAssertEqual(result["visibleTerminalCount"] as? Int,1);XCTAssertEqual(result["terminalVisible"] as? Bool,true)
        XCTAssertEqual(rig.events,["press:20"])
        rig.terminalHidden=true;XCTAssertEqual(rig.snapshot().visibleTerminalCount,0)
        rig.record("T09 terminal panel identity with hidden input")
    }
    func testUnavailableTerminalCommandAndPrepressTargetSwitchSendNothing() async {
        let unavailable=ThreadMenuRig();unavailable.terminalCommandAvailable=false
        do {_ = try await unavailable.run(MacUIController(io:unavailable.io),"toggle_keypad_terminal");XCTFail("Must reject missing native command")} catch {}
        XCTAssertTrue(unavailable.events.isEmpty)
        let changed=ThreadMenuRig();changed.commandLookup={changed.thread=ThreadMenuRig.b}
        do {_ = try await changed.run(MacUIController(io:changed.io),"toggle_keypad_terminal");XCTFail("Must reject changed target")} catch {}
        XCTAssertTrue(changed.events.isEmpty)
    }
    func testExactChatMenuDoesNotDependOnAVisibleComposerOrModelPicker() async throws {
        let rig=ThreadMenuRig();rig.hiddenComposer=true
        let controller=MacUIController(io:rig.io)
        let state=try await controller.execute("get_keypad_ui_state",arguments:[:])
        XCTAssertEqual(state["canOpenThreadMenu"] as? Bool,true);XCTAssertEqual(state["canSubmit"] as? Bool,false)
        let pin=try await rig.run(controller,"toggle_keypad_pin");XCTAssertEqual(pin["pinned"] as? Bool,true)
        let copy=try await rig.run(controller,"copy_keypad_markdown");XCTAssertEqual(copy["verified"] as? Bool,true)
        rig.record("T07 exact thread menu without composer")
    }
    func testPinAndUnpinReopenTheirMenuForReadback() async throws {
        for chinese in [false,true] {
            let rig=ThreadMenuRig();rig.chinese=chinese;let controller=MacUIController(io:rig.io)
            for expected in [true,false] {let result=try await rig.run(controller,"toggle_keypad_pin");XCTAssertEqual(result["pinned"] as? Bool,expected);XCTAssertEqual(result["verified"] as? Bool,true)}
            XCTAssertFalse(rig.menu);XCTAssertEqual(rig.events.filter{$0 == "press:8"}.count,2)
            XCTAssertEqual(rig.events.filter{$0 == "press:6"}.count,4)
            rig.record("T01 pin round trip "+(chinese ? "zh":"en"))
        }
    }
    func testCopyMarkdownUsesNativeSubmenuAndFreshToastWithoutLeakingText() async throws {
        let rig=ThreadMenuRig()
        let result=try await rig.run(MacUIController(io:rig.io),"copy_keypad_markdown")
        XCTAssertEqual(result["verified"] as? Bool,true);XCTAssertEqual(result["clipboard_updated"] as? Bool,true)
        XCTAssertEqual(rig.clipboard.text,"# User\nFixture prompt\n\n# Assistant\nFixture reply")
        XCTAssertEqual(rig.events,["press:6","expand:copy","press:12"])
        let encoded=String(decoding:try JSONSerialization.data(withJSONObject:result),as:UTF8.self)
        XCTAssertFalse(encoded.contains("Fixture reply"));XCTAssertEqual(rig.snapshot().editor?.text,"kept draft")
        rig.record("T02 copy native Markdown")
    }
    func testConcurrentClipboardWriteIsUnknownAndNeverReplayedOrRestored() async {
        let rig=ThreadMenuRig();rig.copyChanges=2
        do {_ = try await rig.run(MacUIController(io:rig.io),"copy_keypad_markdown");XCTFail("Must not confirm concurrent clipboard write")} catch {}
        XCTAssertEqual(rig.events.filter{$0 == "press:12"}.count,1);XCTAssertEqual(rig.clipboard.changeCount,7)
        rig.record("T03 clipboard concurrency rejects confirmation")
    }
    func testExistingCopyToastCannotConfirmANewCopy() async {
        let rig=ThreadMenuRig();rig.toast=true
        do {_ = try await rig.run(MacUIController(io:rig.io),"copy_keypad_markdown");XCTFail("Must reject stale toast")} catch {}
        XCTAssertTrue(rig.events.isEmpty);XCTAssertEqual(rig.clipboard.changeCount,5)
    }
    func testAmbiguousHeaderAndPinStateDoNotPerformActions() async {
        let header=ThreadMenuRig();header.duplicateTrigger=true
        do {_ = try await header.run(MacUIController(io:header.io),"toggle_keypad_pin");XCTFail("Must reject ambiguous header")} catch {}
        XCTAssertTrue(header.events.isEmpty)
        let pin=ThreadMenuRig();pin.ambiguousPin=true
        do {_ = try await pin.run(MacUIController(io:pin.io),"toggle_keypad_pin");XCTFail("Must reject ambiguous pin state")} catch {}
        XCTAssertEqual(pin.events,["press:6","escape"]);XCTAssertFalse(pin.pinned)
    }
    func testTargetChangesAfterOpeningCannotPinOrDismissTheNewChatMenu() async {
        let rig=ThreadMenuRig();rig.afterOpen={rig.thread=ThreadMenuRig.b}
        do {_ = try await rig.run(MacUIController(io:rig.io),"toggle_keypad_pin");XCTFail("Must reject changed target")} catch {}
        XCTAssertEqual(rig.events,["press:6"]);XCTAssertFalse(rig.pinned)
        rig.record("T04 target change before menu action")
    }
    func testArchiveLeavesConfirmationUntouchedAndSkipsReadback() async throws {
        let rig=ThreadMenuRig();rig.confirmation=true
        let requested=try await rig.run(MacUIController(io:rig.io),"archive_keypad_thread")
        var reads=0
        let result=try await NativeThreadMenu.confirmArchive(requested,observe:{_ in reads += 1;return [:]},pause:{})
        XCTAssertEqual(result["pending_confirmation"] as? Bool,true);XCTAssertEqual(result["verified"] as? Bool,false)
        XCTAssertEqual(reads,0);XCTAssertEqual(rig.events,["press:6","press:9"])
        rig.record("T05 native archive confirmation is preserved")
    }
    func testArchiveRequiresExactPersistedReadbackAfterNavigation() async throws {
        let rig=ThreadMenuRig()
        let requested=try await rig.run(MacUIController(io:rig.io),"archive_keypad_thread")
        XCTAssertNil(rig.thread);XCTAssertEqual(requested["verified"] as? Bool,false)
        var reads=0
        let result=try await NativeThreadMenu.confirmArchive(requested,observe:{id in reads += 1;XCTAssertEqual(id,ThreadMenuRig.a);return ["threadId":id,"archived":reads>1]},pause:{})
        XCTAssertEqual(reads,2);XCTAssertEqual(result["verified"] as? Bool,true)
        rig.record("T06 archive readback after route leaves chat")
    }
    func testArchiveMismatchAndMissingReadbackNeverClaimSuccess() async throws {
        let requested:[String:Any]=["threadId":ThreadMenuRig.a,"archive_requested":true,"verified":false]
        let mismatch=try await NativeThreadMenu.confirmArchive(requested,observe:{_ in ["threadId":ThreadMenuRig.b,"archived":true]},pause:{})
        XCTAssertEqual(mismatch["verified"] as? Bool,false)
        var reads=0
        let missing=try await NativeThreadMenu.confirmArchive(requested,observe:{id in reads += 1;return ["threadId":id,"archived":NSNull()]},pause:{})
        XCTAssertEqual(missing["verified"] as? Bool,false);XCTAssertEqual(reads,6)
    }
}
