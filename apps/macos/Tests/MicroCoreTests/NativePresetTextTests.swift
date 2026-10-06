import XCTest
import AppKit
import ApplicationServices
import MicroCore
import MicroShared
@testable import MicroDesktop

private final class PresetTextRig:@unchecked Sendable {
    static let a="01000000-0000-0000-0000-000000000001",b="01000000-0000-0000-0000-000000000002"
    let elements=(0..<7).map {AXUIElementCreateApplication(Int32(740000+$0))}
    var text:String?="",selection:NSRange?=NSRange(location:0,length:0)
    var thread:String?=a,draft=false,nativeFallback=false,focused=true,acceptFocus=true,menu=false,blocked=false
    var foreground=true,replacedEditor=false,model="Fixture A",events:[String]=[]
    var beforeTyping:(()->Void)?,afterTyping:(()->Void)?,onCapture:(()->Void)?
    var outcome="success"
    func snapshot() -> MacUISnapshot {
        var nodes=[AXNode(element:elements[0],role:"AXWindow"),AXNode(element:elements[1],parent:0,role:"AXGroup"),
            AXNode(element:elements[replacedEditor ? 5:2],parent:1,role:"AXTextArea",focused:focused,text:text,selectedTextRange:selection,classes:["ProseMirror"]),
            AXNode(element:elements[3],parent:1,name:"Select model",strings:[model])]
        if menu {nodes.append(AXNode(element:elements[4],parent:0,role:"AXMenuItem",name:"Fixture menu"))}
        return MacUISnapshot(app:NSRunningApplication.current,root:elements[0],window:elements[0],nodes:nodes,composer:2,container:1,
            thread:thread,draft:draft,route:draft ? "draft":thread.map {"thread:"+$0},selectionKnown:thread != nil || draft,
            nativeFallback:nativeFallback,selectedSidebar:nativeFallback ? elements[6]:nil,controls:[3],menuItems:menu ? [4]:[],blocked:blocked,modelLabels:["Fixture A","Fixture B"])
    }
    var io:NativeUIAccess {
        var io=NativeUIAccess();io.observeActivation=false
        io.capture={ [self] _,_ in onCapture?();return snapshot() }
        io.foreground={ [self] in foreground ? NSRunningApplication.current.processIdentifier:nil }
        io.activate={_ in XCTFail("Unexpected activation");return false}
        io.set={ [self] element,key,_ in
            XCTAssertTrue(CFEqual(element,elements[2]));XCTAssertEqual(key,"AXFocused")
            events.append("focus-composer");focused=acceptFocus
        }
        io.typePreset={ [self] preset,pid,check in
            XCTAssertEqual(pid,NSRunningApplication.current.processIdentifier)
            beforeTyping?();try check();events.append("unicode:"+preset.rawValue)
            if outcome == "throw" {throw CodexClientError.outcomeUnknown}
            if outcome != "unchanged",let text,let selection {
                // Model the OS edit only after production validates the range.
                self.text=(text as NSString).replacingCharacters(in:selection,with:preset.text)
                self.selection=NSRange(location:selection.location+preset.text.utf16.count,length:0)
            }
            if outcome == "wrong-text" {text="fixture mismatch"}
            if outcome == "wrong-caret" {selection=NSRange(location:0,length:0)}
            if outcome == "lost-focus" {focused=false}
            afterTyping?()
        }
        io.press={_ in XCTFail("Preset must never press Send or another control")}
        io.send={_,_,_ in XCTFail("Preset must never send Return or a shortcut")}
        io.expand={_ in XCTFail("Preset must never open a menu")}
        io.applicationCommand={_,_,_ in XCTFail("Preset must never select an application command");return nil}
        io.windows={_,_ in XCTFail("Preset must never enumerate OS windows");return []}
        io.shortcut={_ in throw CodexClientError.unavailable("Fixture has no configured shortcut")}
        io.clipboardCount={XCTFail("Preset must not inspect the clipboard");return 0}
        io.clipboard={XCTFail("Preset must not read the clipboard");return .init(changeCount:0,text:nil)}
        return io
    }
    func token(_ controller:MacUIController) async throws -> String {
        let state=try await controller.execute("get_keypad_ui_state",arguments:[:])
        return try XCTUnwrap(state["targetToken"] as? String)
    }
    func insert(_ controller:MacUIController,_ preset:String="YOLO") async throws -> [String:Any] {
        try await controller.execute("insert_keypad_preset_text",arguments:["preset":preset,"target_token":token(controller)])
    }
    func record(_ scenario:String) {
        ReplayTrace.emit("PRESET-TEXT-TRACE",["scenario":scenario,"events":events,"draft":draft,
            "utf16Length":text?.utf16.count ?? -1,"caret":selection?.location ?? -1,"selectionLength":selection?.length ?? -1])
    }
}

final class NativePresetTextTests:XCTestCase {
    func testBothPresetsInsertAtCaretOrReplaceSelectionWithExactReadback() async throws {
        for (preset,literal) in [("YOLO",":yolo:"),("YEET",":yeet:")] {
            for (index,value,range,prefix,suffix) in [
                (0,"",NSRange(location:0,length:0),"",""),
                (1,"abc",NSRange(location:1,length:0),"a","bc"),
                (2,"abc",NSRange(location:1,length:1),"a","c")
            ] {
                let rig=PresetTextRig();rig.text=value;rig.selection=range
                let result=try await rig.insert(MacUIController(io:rig.io),preset)
                XCTAssertEqual(rig.text,prefix+literal+suffix)
                XCTAssertEqual(rig.selection,NSRange(location:range.location+6,length:0))
                XCTAssertEqual(result["verified"] as? Bool,true);XCTAssertEqual(result["inserted"] as? Bool,true)
                XCTAssertEqual(result["submitted"] as? Bool,false);XCTAssertEqual(result["clipboardModified"] as? Bool,false)
                XCTAssertEqual(rig.events,["unicode:"+preset]);rig.record("C01 \(preset) selection \(index)")
            }
        }
    }
    func testUnicodeSelectionUsesUTF16AndPreservesSurroundingMultilineText() async throws {
        for (index,value,range,expected) in [
            (0,"A🚀B",NSRange(location:1,length:2),"A:yolo:B"),
            (1,"A🚀B",NSRange(location:3,length:0),"A🚀:yolo:B"),
            (2,"e\u{301}X",NSRange(location:0,length:2),":yolo:X"),
            (3,"中\r\n文",NSRange(location:3,length:0),"中\r\n:yolo:文")
        ] {
            let rig=PresetTextRig();rig.text=value;rig.selection=range
            _ = try await rig.insert(MacUIController(io:rig.io))
            XCTAssertEqual(rig.text,expected);XCTAssertEqual(rig.events,["unicode:YOLO"])
            rig.record("C02 Unicode \(index)")
        }
    }
    func testConfirmedEmptyDraftDoesNotInventConversationID() async throws {
        let rig=PresetTextRig();rig.thread=nil;rig.draft=true
        let result=try await rig.insert(MacUIController(io:rig.io),"YEET")
        let state=try XCTUnwrap(result["state"] as? [String:Any])
        XCTAssertTrue(state["threadId"] is NSNull);XCTAssertEqual(state["draft"] as? Bool,true)
        XCTAssertEqual(rig.text,":yeet:");rig.record("C03 confirmed draft")
    }
    func testFocusingComposerPreservesSelectionAndNeverReplacesWholeDraft() async throws {
        let rig=PresetTextRig();rig.focused=false;rig.text="keep this";rig.selection=NSRange(location:5,length:4)
        _ = try await rig.insert(MacUIController(io:rig.io))
        XCTAssertEqual(rig.events,["focus-composer","unicode:YOLO"]);XCTAssertEqual(rig.text,"keep :yolo:")
        rig.record("C04 focus preserves selection")
    }
    func testMissingInvalidOutOfBoundsOrSplitSurrogateSelectionNeverTypes() async {
        let invalid:[NSRange?]=[nil,NSRange(location:-1,length:0),NSRange(location:0,length:-1),NSRange(location:5,length:0),NSRange(location:1,length:Int.max),NSRange(location:NSNotFound,length:0),NSRange(location:2,length:0),NSRange(location:1,length:1)]
        for (index,selection) in invalid.enumerated() {
            let rig=PresetTextRig();rig.text="A🚀B";rig.selection=selection
            do {_ = try await rig.insert(MacUIController(io:rig.io));XCTFail("Invalid selection must fail")} catch {}
            XCTAssertTrue(rig.events.isEmpty);XCTAssertEqual(rig.text,"A🚀B")
            rig.record("C05 invalid selection \(index)")
        }
    }
    func testFailedFocusNeverTypes() async {
        let rig=PresetTextRig();rig.focused=false;rig.acceptFocus=false
        do {_ = try await rig.insert(MacUIController(io:rig.io));XCTFail("Unfocused composer must fail")} catch {}
        XCTAssertEqual(rig.events,["focus-composer"]);rig.record("C06 rejected focus")
    }
    func testLastMomentTextCaretThreadEditorFocusMenuAndForegroundChangesCancelInput() async {
        for scenario in 0..<9 {
            let rig=PresetTextRig();rig.text="abc";rig.selection=NSRange(location:1,length:0)
            rig.beforeTyping={
                switch scenario {
                case 0:rig.text="user changed text"
                case 1:rig.selection=NSRange(location:2,length:0)
                case 2:rig.thread=PresetTextRig.b
                case 3:rig.replacedEditor=true
                case 4:rig.focused=false
                case 5:rig.menu=true
                case 6:rig.foreground=false
                case 7:rig.blocked=true
                default:rig.model="Fixture B"
                }
            }
            do {_ = try await rig.insert(MacUIController(io:rig.io));XCTFail("Changed authority must fail")} catch {}
            XCTAssertTrue(rig.events.isEmpty);rig.record("C07 changed authority \(scenario)")
        }
    }
    func testUnknownInputResultNeverReplaysAndRetiresOldToken() async throws {
        for outcome in ["throw","unchanged","wrong-text","wrong-caret","lost-focus"] {
            let rig=PresetTextRig();rig.outcome=outcome
            let controller=MacUIController(io:rig.io),token=try await rig.token(controller)
            for _ in 0..<2 {
                do {_ = try await controller.execute("insert_keypad_preset_text",arguments:["preset":"YOLO","target_token":token]);XCTFail("Unverified or stale input must fail")} catch {}
            }
            XCTAssertEqual(rig.events,["unicode:YOLO"]);rig.record("C08 unknown outcome \(outcome)")
        }
    }
    func testChangedThreadAfterInputStaysUnknownWithoutSecondInsertion() async {
        let rig=PresetTextRig();rig.afterTyping={rig.thread=PresetTextRig.b}
        do {_ = try await rig.insert(MacUIController(io:rig.io));XCTFail("Different thread cannot confirm insertion")} catch {}
        XCTAssertEqual(rig.events,["unicode:YOLO"]);rig.record("C09 changed thread after input")
    }
    func testNewPressUsesNewTokenAndCurrentCaret() async throws {
        let rig=PresetTextRig(),controller:MacUIController
        controller=MacUIController(io:rig.io)
        let old=try await rig.token(controller)
        let first=try await controller.execute("insert_keypad_preset_text",arguments:["preset":"YOLO","target_token":old])
        let next=try XCTUnwrap((first["state"] as? [String:Any])?["targetToken"] as? String)
        XCTAssertNotEqual(old,next)
        do {_ = try await controller.execute("insert_keypad_preset_text",arguments:["preset":"YOLO","target_token":old]);XCTFail("Old lease cannot repeat input")} catch {}
        _ = try await rig.insert(controller,"YEET")
        XCTAssertEqual(rig.text,":yolo::yeet:");XCTAssertEqual(rig.events,["unicode:YOLO","unicode:YEET"])
        rig.record("C10 distinct presses")
    }
    func testUnknownPresetRejectsBeforeActivationAndNeverFallsBackToSend() async throws {
        let rig=PresetTextRig(),controller:MacUIController
        controller=MacUIController(io:rig.io)
        let token=try await rig.token(controller);rig.foreground=false
        for preset in ["YOLO\n",":yolo:","DELETE",""] {
            do {_ = try await controller.execute("insert_keypad_preset_text",arguments:["preset":preset,"target_token":token]);XCTFail("Unknown preset must fail")} catch {}
        }
        XCTAssertTrue(rig.events.isEmpty);rig.record("C11 invalid preset")
    }
    func testIDlessFallbackAndExistingPopupCannotAuthorizeTyping() async {
        for fallback in [false,true] {
            let rig=PresetTextRig()
            if fallback {rig.thread=nil;rig.nativeFallback=true} else {rig.menu=true}
            let controller=MacUIController(io:rig.io)
            let state=try? await controller.execute("get_keypad_ui_state",arguments:[:])
            XCTAssertEqual(state?["canInsertPresetText"] as? Bool,false)
            do {_ = try await controller.execute("insert_keypad_preset_text",arguments:["preset":"YOLO","target_token":state?["targetToken"] as? String ?? "unavailable"]);XCTFail("Unknown target or menu cannot authorize input")} catch {}
            XCTAssertTrue(rig.events.isEmpty);rig.record("C12 unavailable target fallback \(fallback)")
        }
    }
}
