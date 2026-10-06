import XCTest
import AppKit
import ApplicationServices
import MicroShared
@testable import MicroCore
@testable import MicroDesktop

final class ReadOnlyRouteRecoveryTests: XCTestCase {
    func testIncompleteTreePreservesClientReadReceiptButCannotAuthorizeWrites() async throws {
        let client = "client-new-thread:01000000-0000-0000-0000-000000000001"
        let window = AXUIElementCreateApplication(12001)
        var route = CurrentRoute.resolve(documents: ["app://-/local/" + client], selectedLinks: [], homeComposer: false)
        var io = NativeUIAccess()
        io.observeActivation = false
        io.foreground = { 12001 }
        io.capture = { _, _ in throw NativeObservationFailure.treeIncomplete }
        io.observeRoute = { _ in .init(processID: 12001, window: window, route: route) }
        let controller = MacUIController(io: io)
        let first = try await controller.execute("get_keypad_ui_state", arguments: [:])
        let token = try XCTUnwrap(first["observationToken"] as? String)
        let second = try await controller.execute("get_keypad_ui_state", arguments: [:])
        XCTAssertEqual(second["observationToken"] as? String, token)
        XCTAssertEqual(NativeObservation(second).clientID, client)
        XCTAssertTrue(NativeObservation(second).readOnly)
        XCTAssertTrue(second["targetToken"] is NSNull)
        for operation in ["submit_keypad_composer", "set_keypad_draft_fast", "toggle_keypad_draft_plan"] {
            do {
                _ = try await controller.execute(operation, arguments: ["target_token": token, "native_composer": true])
                XCTFail("Read receipt must never authorize " + operation)
            } catch {
                guard case CodexClientError.staleTarget = error else { XCTFail("Unexpected error: \(error)"); continue }
            }
        }
        route = CurrentRoute.resolve(documents: ["app://-/settings"], selectedLinks: [], homeComposer: false)
        let page = try await controller.execute("get_keypad_ui_state", arguments: [:])
        XCTAssertTrue(page["observationToken"] is NSNull)
        XCTAssertNil(NativeObservation(page).clientID)
    }
}
