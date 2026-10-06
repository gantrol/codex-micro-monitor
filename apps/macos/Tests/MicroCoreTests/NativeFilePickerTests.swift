import XCTest
import AppKit
import ApplicationServices
@testable import MicroDesktop
import MicroCore

private final class FilePickerRig:@unchecked Sendable {
    static let a="01000000-0000-0000-0000-000000000001",b="01000000-0000-0000-0000-000000000002"
    let elements=(0..<12).map {AXUIElementCreateApplication(Int32(710000+$0))}
    var thread:String?=a,draft=false,menu=false,picker=false,hasFiles=true,createPicker=true,duplicatePicker=false,oldPicker=false
    var language=0,events:[String]=[],afterOpen:(()->Void)?
    var photos=false,wrongPickerKind=false,extraPermission=false,oldOtherPicker=false
    var configured:MacShortcut?,beforeShortcut:(()->Void)?
    let addNames=["Add files and more","添加文件等内容","加入檔案及更多內容","新增檔案和更多內容"]
    let fileNames=["Files and folders","文件和文件夹","檔案及資料夾","檔案和資料夾"]
    let fileTitles=["Select files","选择文件","選取檔案","選取檔案"]
    let photoTitles=["Select photos","选择照片","選取相片","選取相片"]
    let photoNames=["Add photos","添加照片","加入相片","新增相片"]
    var titles:[String] {photos != wrongPickerKind ? photoTitles:fileTitles}
    func node(_ id:Int,_ parent:Int?,_ role:String,_ name:String="",expanded:Bool?=nil) -> AXNode {
        AXNode(element:elements[id],parent:parent,role:role,name:name,expanded:expanded)
    }
    func snapshot() -> MacUISnapshot {
        let nodes:[AXNode]
        if picker {nodes=[node(7,nil,"AXDialog",titles[language])]}
        else {
            var content=[node(0,nil,"AXWindow"),node(1,0,"AXGroup"),AXNode(element:elements[2],parent:1,role:"AXTextArea",text:"draft kept",classes:["ProseMirror"]),node(3,1,"AXButton",addNames[language],expanded:menu)]
            if menu {content.append(node(4,0,"AXList"));content.append(node(5,4,"AXRow",hasFiles ? fileNames[language]:photoNames[language]))}
            nodes=content
        }
        return MacUISnapshot(app:NSRunningApplication.current,root:elements[0],window:elements[picker ? 7:0],nodes:nodes,
            composer:picker ? nil:2,container:picker ? nil:1,thread:picker ? nil:thread,draft:!picker && draft,
            route:picker ? nil:draft ? "draft":thread.map{"thread:"+$0},selectionKnown:!picker,nativeFallback:false,selectedSidebar:nil,
            controls:picker ? []:[3],menuItems:[],blocked:picker,modelLabels:[])
    }
    var io:NativeUIAccess {
        var io=NativeUIAccess();io.observeActivation=false
        io.foreground={NSRunningApplication.current.processIdentifier};io.activate={_ in XCTFail("No activation expected");return false}
        io.capture={ [self] _,_ in snapshot() }
        io.windows={ [self] pid,_ in
            XCTAssertEqual(pid,NSRunningApplication.current.processIdentifier)
            var result=[node(0,nil,"AXWindow")]
            if picker || oldPicker {result.append(node(7,nil,"AXDialog",titles[language]))}
            if picker && duplicatePicker {result.append(node(8,nil,"AXDialog",titles[language]))}
            if picker && extraPermission {result.append(node(9,nil,"AXDialog","Permission request"))}
            if oldOtherPicker {result.append(node(10,nil,"AXDialog",photos ? fileTitles[language]:photoTitles[language]))}
            return result
        }
        io.press={ [self] element in
            if CFEqual(element,elements[3]) {events.append("open-add");menu=true;afterOpen?()}
            else if CFEqual(element,elements[5]) {events.append(hasFiles ? "choose-files":"choose-photos");menu=false;picker=createPicker}
            else {XCTFail("Unexpected press")}
        }
        io.shortcut={ [self] command in
            guard command == "composer.addPhotos",let configured else {throw CodexClientError.unavailable("No configured shortcut")}
            return configured
        }
        io.send={ [self] shortcut,_,check in
            if shortcut.key == 53 {try check();events.append("escape-owned-list");menu=false}
            else {beforeShortcut?();try check();XCTAssertEqual(shortcut,configured);events.append("shortcut:photos");picker=createPicker}
        }
        io.set={_,_,_ in XCTFail("Must not type or choose files")}
        return io
    }
    func open(_ controller:MacUIController) async throws -> [String:Any] {
        let before=try await controller.execute("get_keypad_ui_state",arguments:[:])
        XCTAssertEqual(before[photos ? "canOpenPhotos":"canOpenFiles"] as? Bool,true)
        return try await controller.execute(photos ? "open_keypad_photos":"open_keypad_files",arguments:["target_token":try XCTUnwrap(before["targetToken"] as? String)])
    }
    func record(_ scenario:String) {
        let data:[String:Any]=["scenario":scenario,"events":events,"pickerOpen":picker,"menuOpen":menu,"draft":draft,"photos":photos]
        ReplayTrace.emit("FILE-PICKER-TRACE",data)
    }
}

final class NativeFilePickerTests:XCTestCase {
    func testNativeFilesPickerHandoffInFourLocalesWithoutModelPickerOrFileSelection() async throws {
        for language in 0..<4 {
            let rig=FilePickerRig();rig.language=language
            let controller=MacUIController(io:rig.io)
            let result=try await rig.open(controller)
            XCTAssertEqual(result["verified"] as? Bool,true);XCTAssertEqual(result["pickerOpened"] as? Bool,true)
            XCTAssertEqual(result["awaitingSelection"] as? Bool,true);XCTAssertEqual(result["attachmentVerified"] as? Bool,false)
            XCTAssertEqual(rig.events,["open-add","choose-files"])
            let modal=try await controller.execute("get_keypad_ui_state",arguments:[:])
            XCTAssertEqual(modal["selectionKnown"] as? Bool,true);XCTAssertEqual(modal["available"] as? Bool,false)
            XCTAssertNil(modal["threadId"] as? String);XCTAssertNil(modal["targetToken"] as? String)
            rig.picker=false
            let returned=try await controller.execute("get_keypad_ui_state",arguments:[:])
            XCTAssertEqual(returned["threadId"] as? String,FilePickerRig.a)
            XCTAssertEqual(rig.snapshot().editor?.text,"draft kept")
            rig.record("F01 files picker and cancel locale \(language)")
        }
    }
    func testBlankDraftOpensFilesPickerWithoutInventingThreadID() async throws {
        let rig=FilePickerRig();rig.thread=nil;rig.draft=true
        let result=try await rig.open(MacUIController(io:rig.io))
        XCTAssertEqual(result["pickerOpened"] as? Bool,true);XCTAssertNil(result["threadId"])
        rig.record("F02 blank draft files")
    }
    func testMissingFilesItemClosesOnlyOwnedPopupAndNeverSelectsPhotos() async {
        let rig=FilePickerRig();rig.hasFiles=false
        do {_ = try await rig.open(MacUIController(io:rig.io));XCTFail("Missing Files and folders must fail")} catch {}
        XCTAssertEqual(rig.events,["open-add","escape-owned-list"]);XCTAssertFalse(rig.picker)
        rig.record("F03 missing files item")
    }
    func testChangedTargetDoesNotSelectOrDismissAnotherComposer() async {
        let rig=FilePickerRig();rig.afterOpen={rig.thread=FilePickerRig.b}
        do {_ = try await rig.open(MacUIController(io:rig.io));XCTFail("Changed composer must fail")} catch {}
        XCTAssertEqual(rig.events,["open-add"]);XCTAssertTrue(rig.menu)
        rig.record("F04 changed target")
    }
    func testMissingOrMultipleNewPickersStayUnknownAndDoNotReplay() async {
        for duplicate in [false,true] {
            let rig=FilePickerRig();rig.createPicker=duplicate;rig.duplicatePicker=duplicate
            do {_ = try await rig.open(MacUIController(io:rig.io));XCTFail("Must uniquely observe a new picker")} catch {}
            XCTAssertEqual(rig.events,["open-add","choose-files"])
            rig.record("F05 ambiguous picker \(duplicate)")
        }
    }
    func testAlreadyOpenPickerCannotAuthorizeNewAttachmentAction() async {
        let rig=FilePickerRig();rig.oldPicker=true
        do {_ = try await rig.open(MacUIController(io:rig.io));XCTFail("Existing picker must fail")} catch {}
        XCTAssertTrue(rig.events.isEmpty)
    }
    func testDedicatedPhotoPickerInFourLocalesPreservesDraftAndNeverChoosesFile() async throws {
        for language in 0..<4 {
            let rig=FilePickerRig();rig.photos=true;rig.hasFiles=false;rig.language=language
            let controller=MacUIController(io:rig.io)
            let result=try await rig.open(controller)
            XCTAssertEqual(result["pickerKind"] as? String,"photos")
            XCTAssertEqual(result["pickerEntryPoint"] as? String,"menu")
            XCTAssertEqual(result["imagesOnlyRequested"] as? Bool,true)
            XCTAssertEqual(result["awaitingSelection"] as? Bool,true)
            XCTAssertEqual(result["attachmentVerified"] as? Bool,false)
            XCTAssertEqual(rig.events,["open-add","choose-photos"])
            rig.picker=false
            let returned=try await controller.execute("get_keypad_ui_state",arguments:[:])
            XCTAssertEqual(returned["threadId"] as? String,FilePickerRig.a)
            XCTAssertEqual(rig.snapshot().editor?.text,"draft kept")
            rig.record("F06 photos picker and cancel locale \(language)")
        }
    }
    func testDraftPhotoPickerDoesNotInventConversationID() async throws {
        let rig=FilePickerRig();rig.photos=true;rig.hasFiles=false;rig.thread=nil;rig.draft=true
        let result=try await rig.open(MacUIController(io:rig.io))
        XCTAssertEqual(result["pickerKind"] as? String,"photos");XCTAssertNil(result["threadId"])
        rig.record("F07 draft photos")
    }
    func testMissingPhotoItemNeverSubstitutesGeneralFiles() async {
        let rig=FilePickerRig();rig.photos=true
        do {_ = try await rig.open(MacUIController(io:rig.io));XCTFail("Files cannot substitute photos")} catch {}
        XCTAssertEqual(rig.events,["open-add","escape-owned-list"]);XCTAssertFalse(rig.picker)
        rig.record("F08 missing photos item")
    }
    func testExplicitPhotoShortcutHasDedicatedPickerReadbackAndNoMenuFallback() async throws {
        let rig=FilePickerRig();rig.photos=true;rig.configured = .init(key:97,flags:.maskCommand)
        let result=try await rig.open(MacUIController(io:rig.io))
        XCTAssertEqual(result["pickerEntryPoint"] as? String,"configuredShortcut")
        XCTAssertEqual(result["pickerKind"] as? String,"photos")
        XCTAssertEqual(rig.events,["shortcut:photos"])
        rig.record("F09 explicit photo shortcut")
    }
    func testPhotoShortcutRechecksConfigurationAndExactComposerBeforeSending() async {
        for changedTarget in [false,true] {
            let rig=FilePickerRig();rig.photos=true;rig.configured = .init(key:97,flags:.maskCommand)
            rig.beforeShortcut={if changedTarget {rig.thread=FilePickerRig.b} else {rig.configured = .init(key:98,flags:.maskCommand)}}
            do {_ = try await rig.open(MacUIController(io:rig.io));XCTFail("Changed shortcut authority must fail")} catch {}
            XCTAssertTrue(rig.events.isEmpty);XCTAssertFalse(rig.picker)
            rig.record("F10 photo shortcut changed target \(changedTarget)")
        }
    }
    func testBareReturnIsNeverSentAsPhotoShortcutOrGeneralFileFallback() async {
        let rig=FilePickerRig();rig.photos=true;rig.configured = .init(key:36,flags:[])
        do {_ = try await rig.open(MacUIController(io:rig.io));XCTFail("Content key must not be sent")} catch {}
        XCTAssertEqual(rig.events,["open-add","escape-owned-list"]);XCTAssertFalse(rig.picker)
        rig.record("F11 unsafe content shortcut rejected")
    }
    func testPhotoPickerMissingWrongKindDuplicateOrPermissionOverlayStaysUnknown() async {
        for scenario in 0..<4 {
            let rig=FilePickerRig();rig.photos=true;rig.hasFiles=false
            rig.createPicker=scenario != 0;rig.wrongPickerKind=scenario == 1;rig.duplicatePicker=scenario == 2;rig.extraPermission=scenario == 3
            do {_ = try await rig.open(MacUIController(io:rig.io));XCTFail("Unknown photos handoff must fail")} catch {}
            XCTAssertEqual(rig.events,["open-add","choose-photos"])
            rig.record("F12 unknown photo picker \(scenario)")
        }
    }
    func testEitherExistingAttachmentPickerPreventsAnotherPhotoAction() async {
        for otherKind in [false,true] {
            let rig=FilePickerRig();rig.photos=true;rig.hasFiles=false;rig.oldPicker = !otherKind;rig.oldOtherPicker=otherKind
            do {_ = try await rig.open(MacUIController(io:rig.io));XCTFail("Existing attachment modal prevents action")} catch {}
            XCTAssertTrue(rig.events.isEmpty)
            rig.record("F13 existing picker other kind \(otherKind)")
        }
    }
    func testPhotoMenuTargetSwitchNeverChoosesOrDismissesAnotherComposer() async {
        let rig=FilePickerRig();rig.photos=true;rig.hasFiles=false;rig.afterOpen={rig.thread=FilePickerRig.b}
        do {_ = try await rig.open(MacUIController(io:rig.io));XCTFail("Changed photo target must fail")} catch {}
        XCTAssertEqual(rig.events,["open-add"]);XCTAssertTrue(rig.menu)
        rig.record("F14 changed photo menu target")
    }

    func testUnknownPhotoShortcutOutcomeNeverFallsBackToMenuOrResends() async {
        for wrongKind in [false,true] {
            let rig=FilePickerRig();rig.photos=true;rig.hasFiles=false;rig.configured = .init(key:97,flags:.maskCommand)
            rig.createPicker=wrongKind;rig.wrongPickerKind=wrongKind
            do {_ = try await rig.open(MacUIController(io:rig.io));XCTFail("Unknown shortcut outcome must stay unknown")} catch {}
            XCTAssertEqual(rig.events,["shortcut:photos"]);XCTAssertFalse(rig.menu)
            rig.record("F15 unknown shortcut outcome wrong kind \(wrongKind)")
        }
    }

}
