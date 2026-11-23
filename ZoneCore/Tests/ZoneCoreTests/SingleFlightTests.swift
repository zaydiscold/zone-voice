// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

@MainActor
final class SingleFlightTests: XCTestCase {
    /// Counts runs and lets the test decide when each one finishes.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var runs = 0
        private var open = false
        var count: Int { lock.withLock { runs } }
        func enter() { lock.withLock { runs += 1 } }
        func release() { lock.withLock { open = true } }
        var isOpen: Bool { lock.withLock { open } }
    }

    private func work(_ gate: Gate, ignoringCancellation: Bool = false) -> @Sendable () async throws -> Void {
        return {
            gate.enter()
            while !gate.isOpen {
                if !ignoringCancellation { try Task.checkCancellation() }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
    }

    func testStartingTwiceJoinsTheRunningWork() async throws {
        let flight = SingleFlight(), gate = Gate()
        XCTAssertTrue(flight.start(work(gate)))
        XCTAssertFalse(flight.start(work(gate)), "the toggle flipped twice must not start a second download")
        let waiter = Task { try await flight.join() }
        try await Task.sleep(nanoseconds: 50_000_000)
        gate.release()
        let outcome = try await waiter.value
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(gate.count, 1)
        XCTAssertFalse(flight.isRunning)
    }

    func testCancelReleasesWaitersAtOnceEvenIfTheWorkIgnoresIt() async throws {
        let flight = SingleFlight(), gate = Gate()
        flight.start(work(gate, ignoringCancellation: true))
        let waiter = Task { try await flight.join() }
        try await Task.sleep(nanoseconds: 30_000_000)
        flight.cancel()
        let outcome = try await waiter.value
        XCTAssertEqual(outcome, .cancelled, "a transcription waiting on a cancelled download moves on")
        gate.release()
    }

    func testCancelThenRestartWaitsForTheNewRun() async throws {
        let flight = SingleFlight(), first = Gate(), second = Gate()
        flight.start(work(first))
        let waiter = Task { try await flight.join() }
        try await Task.sleep(nanoseconds: 30_000_000)
        flight.cancel()              // toggle off
        flight.start(work(second))   // and on again
        try await Task.sleep(nanoseconds: 30_000_000)
        second.release()
        let outcome = try await waiter.value
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(second.count, 1)
    }

    func testFailuresReachWaitersAndTheFinishedHandler() async throws {
        struct Offline: Error {}
        let flight = SingleFlight()
        var reported: Result<Void, Error>?
        flight.start({ throw Offline() }, finished: { reported = $0 })
        do {
            _ = try await flight.join()
            XCTFail("should throw")
        } catch {
            XCTAssertTrue(error is Offline)
        }
        XCTAssertNotNil(reported)
        XCTAssertFalse(flight.isRunning, "a failed download can be started again")
        XCTAssertTrue(flight.start({}))
    }

    func testJoinWithNothingRunningReturnsAtOnce() async throws {
        let outcome = try await SingleFlight().join()
        XCTAssertEqual(outcome, .done)
    }

    func testACancelledRunNeverCallsFinished() async throws {
        let flight = SingleFlight(), gate = Gate()
        var called = false
        flight.start(work(gate), finished: { _ in called = true })
        try await Task.sleep(nanoseconds: 20_000_000)
        flight.cancel()
        gate.release()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(called)
    }
}
