import XCTest
@testable import MicroDesktop

@MainActor final class PermissionRecoveryTests: XCTestCase {
    func testOpeningSettingsDoesNotGrantTrustAndLaterGrantAndRevokeAreObserved() {
        var trusted = false, requests = 0, opened = 0
        var changes: [Bool] = []
        let model = PermissionSetupModel(applicationURL: URL(fileURLWithPath: "/fixture/Micro.app"),
            readTrust: { trusted }, requestTrust: { requests += 1 }, openSettings: { opened += 1; return true },
            revealApplication: { _ in XCTFail("A check must not reveal or select another application") })
        model.trustChanged = { changes.append($0) }
        model.requestAccess()
        model.checkAccess()
        XCTAssertEqual(model.status, .required)
        XCTAssertTrue(model.needsRepair)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(opened, 1)
        trusted = true
        model.checkAccess()
        XCTAssertEqual(model.status, .granted)
        XCTAssertFalse(model.needsRepair)
        model.refresh()
        trusted = false
        model.refresh()
        XCTAssertEqual(model.status, .required)
        XCTAssertEqual(changes, [false, true, false])
    }
}
