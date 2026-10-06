import XCTest
import AppKit
import ApplicationServices
@testable import MicroDesktop
@testable import MicroCore

final class AXRelationsAcceptanceTests: XCTestCase {
    private let elements = (0..<24).map { AXUIElementCreateApplication(Int32(800000 + $0)) }

    private func node(_ id: Int, _ parent: Int?, _ role: String, _ name: String = "",
                      expanded: Bool? = nil, title: Int? = nil, linked: [Int] = [],
                      popup: String? = nil, identifier: String = "",
                      frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 30)) -> AXNode {
        AXNode(element: elements[id], parent: parent, role: role, name: name, identifier: identifier,
               expanded: expanded, text: role == "AXTextArea" ? "fixture" : nil,
               classes: role == "AXTextArea" ? ["ProseMirror"] : [],
               frame: frame,
               titleElement: title.map { elements[$0] }, linkedElements: linked.map { elements[$0] }, popupValue: popup)
    }

    private func snapshot(_ nodes: [AXNode], route: String = "draft") -> MacUISnapshot {
        MacUISnapshot(app: .current, root: elements[0], window: elements[0], nodes: nodes,
                      composer: nil, container: nil, thread: nil, draft: true, route: route,
                      selectionKnown: true, nativeFallback: false, selectedSidebar: nil,
                      controls: [2], menuItems: [], blocked: false, modelLabels: [])
    }

    func testSiblingTitleReferenceRestoresPicker() {
        let raw = [node(0, nil, "AXWindow"), node(1, 0, "AXWebArea"), node(2, 1, "AXGroup"),
                   node(3, 2, "AXTextArea"), node(4, 2, "AXButton", "Send"),
                   node(5, 2, "AXButton", title: 6), node(6, 1, "AXStaticText", "Select model")]
        let tree = AXTreeIndex(raw)
        XCTAssertEqual(NativeComposerScope(nodes: raw, tree: tree, modelLabels: []).pickerCandidateCount, 0)
        let resolved = tree.resolvingRelationships(in: raw)
        let scope = NativeComposerScope(nodes: resolved, tree: tree, modelLabels: [])
        XCTAssertTrue(resolved[5].titleRelationshipResolved)
        XCTAssertEqual(scope.pickerCandidateCount, 1)
        XCTAssertEqual(scope.pickerSource, "composer-container")
    }

    func testCrossPanelAndEditableTitleReferencesAreRejected() {
        let raw = [node(0, nil, "AXWindow"), node(1, 0, "AXWebArea"),
                   node(2, 1, "AXButton", title: 4),
                   node(3, 1, "AXGroup", identifier: "app-shell-tab-panel-side"),
                   node(4, 3, "AXStaticText", "Select model"),
                   node(5, 1, "AXButton", title: 6), node(6, 1, "AXTextArea", "Select model")]
        let resolved = AXTreeIndex(raw).resolvingRelationships(in: raw)
        XCTAssertFalse(resolved[2].titleRelationshipResolved)
        XCTAssertFalse(resolved[5].titleRelationshipResolved)
    }

    func testPopupWithoutExpandedCanBeFoundBesideComposer() {
        let raw = [node(0, nil, "AXWindow"), node(1, 0, "AXWebArea"), node(2, 1, "AXGroup"),
                   node(3, 2, "AXTextArea"), node(4, 2, "AXButton", "Send"),
                   node(5, 1, "AXButton", "Select model", popup: "menu")]
        let scope = NativeComposerScope(nodes: raw, tree: AXTreeIndex(raw), modelLabels: [])
        XCTAssertEqual(scope.pickerCandidateCount, 1)
        XCTAssertEqual(scope.pickerSource, "composer-web-area")
        XCTAssertTrue(scope.controls.contains(5))
    }

    func testExpandedInferenceRequiresUniqueMenuAndPreservesFalse() {
        for (expanded, links, expected) in [(nil as Bool?, [3], true as Bool?), (false, [3], false),
                                          (nil, [3, 4], nil), (nil, [5], nil)] {
            let raw = [node(0, nil, "AXWindow"), node(1, 0, "AXWebArea"),
                       node(2, 1, "AXButton", "Select model", expanded: expanded, linked: links, popup: "menu"),
                       node(3, 1, "AXMenu"), node(4, 1, "AXMenu"), node(5, 1, "AXStaticText")]
            XCTAssertEqual(AXTreeIndex(raw).resolvingRelationships(in: raw)[2].expanded, expected)
        }
    }

    func testLinkedModelMenuDisambiguatesOtherVisibleMenu() {
        let raw = [node(0, nil, "AXWindow"), node(1, 0, "AXWebArea"),
                   node(2, 1, "AXButton", "Select model", linked: [3], popup: "menu"),
                   node(3, 1, "AXMenu"), node(4, 1, "AXMenu")]
        let resolved = AXTreeIndex(raw).resolvingRelationships(in: raw)
        XCTAssertEqual(snapshot(resolved).modelMenu, 3)
    }

    func testMenuAndNonMenuLinksAllowDuplicatesAndDisambiguate() {
        let raw = [node(0, nil, "AXWindow"), node(1, 0, "AXWebArea"),
                   node(2, 1, "AXButton", "Select model", linked: [3, 5, 3], popup: "menu"),
                   node(3, 1, "AXMenu"), node(4, 1, "AXMenu"), node(5, 1, "AXStaticText")]
        let resolved = AXTreeIndex(raw).resolvingRelationships(in: raw)
        XCTAssertEqual(resolved[2].expanded, true)
        XCTAssertEqual(snapshot(resolved).modelMenu, 3)
    }

    func testUnresolvedRelationshipsCannotAuthorizeAnotherMenu() {
        for expanded in [nil, true] as [Bool?] {
            for links in [[20], [3, 20], [4, 20]] {
                let raw = [node(0, nil, "AXWindow"), node(1, 0, "AXWebArea"),
                           node(2, 1, "AXButton", "Select model", expanded: expanded, linked: links, popup: "menu"),
                           node(3, 1, "AXMenu"), node(4, 1, "AXStaticText")]
                let resolved = AXTreeIndex(raw).resolvingRelationships(in: raw)
                XCTAssertEqual(resolved[2].expanded, expanded)
                XCTAssertNil(snapshot(resolved).modelMenu)
            }
        }
    }

    func testHiddenOrAmbiguousMenuRelationshipsCannotAuthorizeAnotherMenu() {
        for expanded in [nil, true] as [Bool?] {
            for links in [[4], [3, 4], [3, 5]] {
                let raw = [node(0, nil, "AXWindow"), node(1, 0, "AXWebArea"),
                           node(2, 1, "AXButton", "Select model", expanded: expanded, linked: links, popup: "menu"),
                           node(3, 1, "AXMenu"), node(4, 1, "AXMenu", frame: .zero), node(5, 1, "AXMenu")]
                let resolved = AXTreeIndex(raw).resolvingRelationships(in: raw)
                XCTAssertEqual(resolved[2].expanded, expanded)
                XCTAssertNil(snapshot(resolved).modelMenu)
            }
        }
    }

    func testNonMenuRelationshipDoesNotProveExpansionOrDisambiguateMenus() {
        for expanded in [nil, false, true] as [Bool?] {
            let raw = [node(0, nil, "AXWindow"), node(1, 0, "AXWebArea"),
                       node(2, 1, "AXButton", "Select model", expanded: expanded, linked: [5], popup: "menu"),
                       node(3, 1, "AXMenu"), node(4, 1, "AXMenu"), node(5, 1, "AXStaticText")]
            let resolved = AXTreeIndex(raw).resolvingRelationships(in: raw)
            XCTAssertEqual(resolved[2].expanded, expanded)
            XCTAssertNil(snapshot(resolved).modelMenu)
        }
    }

    func testUnrelatedFlowToDoesNotDisableExplicitlyExpandedUniqueModelMenu() {
        for links in [[], [4]] {
            let raw = [node(0, nil, "AXWindow"), node(1, 0, "AXWebArea"),
                       node(2, 1, "AXButton", "Select model", expanded: true, linked: links, popup: "menu"),
                       node(3, 1, "AXMenu"), node(4, 1, "AXStaticText", "next reading target")]
            let state = snapshot(AXTreeIndex(raw).resolvingRelationships(in: raw))
            XCTAssertEqual(state.picker?.expanded, true)
            XCTAssertEqual(state.modelMenu, 3, "A non-menu flow-to reference must not invalidate explicit expanded state and the existing unique-menu path")
        }
    }

    func testNavigationRetriesTransientReadWithoutReplayingClick() throws {
        for failure in [NativeObservationFailure.treeIncomplete, .windowUnavailable] {
            let raw = [node(0, nil, "AXWindow"), node(1, 0, "AXWebArea"), node(2, 0, "AXButton", "Back")]
            let before = snapshot(raw), after = snapshot(raw, route: "page:/settings")
            var reads = 0, presses = 0
            var io = NativeUIAccess()
            io.observeActivation = false
            io.foreground = { NSRunningApplication.current.processIdentifier }
            io.press = { _ in presses += 1 }
            io.capture = { _, _ in
                reads += 1
                if reads <= 2 { return before }
                if reads == 3 { throw failure }
                return after
            }
            let result = try NativeWindowNavigation.perform("back", before: before, io: io, models: [], context: UIRequestContext())
            XCTAssertEqual(result.route, "page:/settings")
            XCTAssertEqual(presses, 1)
            XCTAssertEqual(reads, 4)
        }
    }

    func testNavigationDoesNotRetryPermissionOrWindowIdentityFailure() {
        for failure in [NativeObservationFailure.accessibilityRequired, .windowChanged] {
            let raw = [node(0, nil, "AXWindow"), node(1, 0, "AXWebArea"), node(2, 0, "AXButton", "Back")]
            let before = snapshot(raw)
            var reads = 0, presses = 0
            var io = NativeUIAccess()
            io.observeActivation = false
            io.foreground = { NSRunningApplication.current.processIdentifier }
            io.press = { _ in presses += 1 }
            io.capture = { _, _ in
                reads += 1
                if reads <= 2 { return before }
                throw failure
            }
            XCTAssertThrowsError(try NativeWindowNavigation.perform("back", before: before, io: io, models: [], context: UIRequestContext()))
            XCTAssertEqual(presses, 1)
            XCTAssertEqual(reads, 3)
        }
    }
}
