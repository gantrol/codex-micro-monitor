import XCTest
@testable import MicroPanelModel

@MainActor final class ObservationCoordinatorTests: XCTestCase {
    func testWakeBurstCoalescesBehindOnePendingRead() async throws {
        let coordinator = ObservationCoordinator()
        var calls = 0, active = 0, maximumActive = 0
        var pending: CheckedContinuation<Void, Never>?
        coordinator.start(native: {
            calls += 1; active += 1; maximumActive = max(maximumActive, active)
            if calls == 1 { await withCheckedContinuation { pending = $0 } }
            active -= 1
            if calls == 2 { coordinator.stop() }
        }, activity: {}, catalogue: {})
        for _ in 0..<100 where pending == nil { await Task.yield() }
        let first = try XCTUnwrap(pending)
        for _ in 0..<20 { coordinator.wake(.native) }
        XCTAssertEqual(calls, 1)
        first.resume()
        for _ in 0..<100 where coordinator.isRunning { await Task.yield() }
        coordinator.stop()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(maximumActive, 1)
    }

    func testStopDiscardsPendingWakeAfterTheReadReturns() async throws {
        let coordinator = ObservationCoordinator()
        var calls = 0
        var pending: CheckedContinuation<Void, Never>?
        coordinator.start(native: {
            calls += 1
            await withCheckedContinuation { pending = $0 }
        }, activity: {}, catalogue: {})
        for _ in 0..<100 where pending == nil { await Task.yield() }
        let first = try XCTUnwrap(pending)
        coordinator.wake(.native)
        coordinator.stop()
        first.resume()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertEqual(calls, 1)
    }
}
