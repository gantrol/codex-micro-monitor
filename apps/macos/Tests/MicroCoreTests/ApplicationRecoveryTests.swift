import XCTest
import AppKit
@testable import MicroDesktop

/// Launch Services boundary only; no application is opened or activated.
@MainActor final class ApplicationRecoveryTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/fixture/Codex.app")

    func testAbsentCallbackTimesOutAndLateDuplicateCompletionIsIgnored() async {
        var callback: (@Sendable (NSRunningApplication?, Error?) -> Void)?
        let request = CodexApplication.OpenRequest(timeout: .milliseconds(10)) { _, completion in callback = completion }
        do { _ = try await request.open(url); XCTFail("Missing callback must time out") }
        catch { XCTAssertFalse(error is CancellationError) }
        callback?(NSRunningApplication.current, nil)
        callback?(nil, NSError(domain: "LateCallback", code: 1))
        await Task.yield()
        do { _ = try await request.open(url); XCTFail("A late success must not replace the timeout") }
        catch { XCTAssertTrue(error.localizedDescription.contains("in time")) }
    }

    func testCancellationReleasesRequestWithoutWaitingForCallbackOrTimeout() async throws {
        var callback: (@Sendable (NSRunningApplication?, Error?) -> Void)?
        let request = CodexApplication.OpenRequest(timeout: .seconds(30)) { _, completion in callback = completion }
        let operation = Task { try await request.open(url) }
        for _ in 0..<100 where callback == nil { await Task.yield() }
        XCTAssertNotNil(callback)
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Cancelled request must finish") }
        catch { XCTAssertTrue(error is CancellationError) }
        callback?(NSRunningApplication.current, nil)
        await Task.yield()
    }

    func testSynchronousDuplicateCallbacksCompleteExactlyOnce() async throws {
        let app = NSRunningApplication.current
        let request = CodexApplication.OpenRequest { _, completion in
            completion(app, nil)
            completion(nil, NSError(domain: "DuplicateCallback", code: 1))
        }
        let actual = try await request.open(url)
        XCTAssertEqual(actual.processIdentifier, app.processIdentifier)
    }
}
