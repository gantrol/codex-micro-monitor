import XCTest
import AppKit
import ApplicationServices
@testable import MicroDesktop

final class NativeComposerScopeTests: XCTestCase {
    private let elements = (0..<20).map { AXUIElementCreateApplication(Int32(11000 + $0)) }
    private func node(_ id: Int, _ parent: Int?, _ role: String, name: String = "", identifier: String = "",
                      classes: [String] = [], height: CGFloat = 700, strings: [String] = []) -> AXNode {
        AXNode(element: elements[id], parent: parent, role: role, name: name, identifier: identifier,
               strings: strings, text: role == "AXTextArea" ? "fixture draft" : nil, classes: classes,
               frame: CGRect(x: 0, y: 0, width: 500, height: height))
    }
    private func nodes(picker: Bool = true) -> [AXNode] {
        var value = [node(0, nil, "AXWindow"), node(1, 0, "AXWebArea"), node(2, 1, "AXGroup"),
                     node(3, 2, "AXTextArea", classes: ["ProseMirror"]), node(4, 2, "AXGroup", height: 40),
                     node(5, 4, "AXButton", name: "Send", height: 30)]
        if picker { value.append(node(6, 2, "AXButton", name: "Custom", height: 30, strings: ["选择模型"])) }
        return value
    }
    func testTallComposerAndLocalizedHiddenLabelKeepTheirOwnControls() {
        for label in ["Select model", "选择模型", "選擇模型", "選取模型"] {
            var value = nodes()
            value[6] = node(6, 2, "AXButton", name: "Custom", height: 30, strings: [label])
            let scope = NativeComposerScope(nodes: value, tree: AXTreeIndex(value), modelLabels: [])
            XCTAssertEqual(scope.composer, 3)
            XCTAssertEqual(scope.container, 2)
            XCTAssertEqual(scope.controls, [5, 6])
        }
    }
    func testSideChatAndEmbeddedEditorsCannotCompeteForMainComposer() {
        var value = nodes()
        value += [node(7, 1, "AXGroup", identifier: "app-shell-tab-panel-side-chat"),
                  node(8, 7, "AXTextArea", classes: ["ProseMirror"]),
                  node(9, 7, "AXButton", name: "Select model"), node(10, 7, "AXButton", name: "Send"),
                  node(11, 1, "AXWebArea"), node(12, 11, "AXTextArea", classes: ["ProseMirror"])]
        let scope = NativeComposerScope(nodes: value, tree: AXTreeIndex(value), modelLabels: [])
        XCTAssertEqual(scope.candidateCount, 1)
        XCTAssertEqual(scope.composer, 3)
        XCTAssertEqual(scope.controls, [5, 6])
        XCTAssertFalse(NativeComposerScope.allows([.init(role: "AXGroup", identifier: "app-shell-tab-panel-side-chat")]))
        XCTAssertFalse(NativeComposerScope.allows([.init(role: "AXWebArea", identifier: ""), .init(role: "AXWebArea", identifier: "")]))
    }
    func testTwoMainEditorsAreAmbiguousInsteadOfChoosingTheFirst() {
        var value = nodes()
        value.append(node(7, 2, "AXTextArea", classes: ["ProseMirror"]))
        let scope = NativeComposerScope(nodes: value, tree: AXTreeIndex(value), modelLabels: [])
        XCTAssertEqual(scope.candidateCount, 2)
        XCTAssertNil(scope.composer)
        XCTAssertNil(scope.container)
        XCTAssertTrue(scope.controls.isEmpty)
    }
    func testMissingPickerDoesNotAbsorbHeaderButtonsOrDisableExactThreadSubmit() async throws {
        var value = nodes(picker: false)
        value.append(node(6, 1, "AXButton", name: "Select model"))
        let scope = NativeComposerScope(nodes: value, tree: AXTreeIndex(value), modelLabels: [])
        XCTAssertEqual(scope.container, 2)
        XCTAssertEqual(scope.controls, [5])
        let id = "01000000-0000-0000-0000-000000000001"
        let snapshot = MacUISnapshot(app: .current, root: elements[0], window: elements[0], nodes: value,
            composer: scope.composer, container: scope.container, thread: id, draft: false, route: "thread:" + id,
            selectionKnown: true, nativeFallback: false, selectedSidebar: nil, controls: scope.controls,
            menuItems: [], blocked: false, modelLabels: [])
        var io = NativeUIAccess()
        io.observeActivation = false
        io.foreground = { NSRunningApplication.current.processIdentifier }
        io.capture = { _, _ in snapshot }
        let state = try await MacUIController(io: io).execute("get_keypad_ui_state", arguments: [:])
        XCTAssertEqual(state["threadId"] as? String, id)
        XCTAssertEqual(state["canSubmit"] as? Bool, true)
        XCTAssertEqual(state["available"] as? Bool, true)
        XCTAssertEqual(state["failureCode"] as? String, "modelPickerUnavailable")
    }
}
