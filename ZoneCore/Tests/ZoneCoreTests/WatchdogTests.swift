// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class WatchdogTests: XCTestCase {
    func testWorkThatFinishesReturnsItsValue() async throws {
        let value = try await Watchdog.run(what: "work", limit: 1) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testWorkThatNeverReturnsFailsVisiblyInsteadOfHanging() async {
        let started = Date()
        do {
            _ = try await Watchdog.run(what: "The speech model", limit: 0.3, checkEvery: 0.05) { () async throws -> Int in
                // Ignores cancellation on purpose (for 3 s, so it does not hold a test thread
                // forever): the caller must still get its answer at the limit.
                for _ in 0..<300 { usleep(10_000) }
                return 0
            }
            XCTFail("should have stalled")
        } catch let stalled as Watchdog.Stalled {
            XCTAssertEqual(stalled.what, "The speech model")
            XCTAssertEqual(stalled.errorDescription, "The speech model did not respond for 0 seconds")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testBeatsKeepSlowButMovingWorkAlive() async throws {
        let pulse = Watchdog.Pulse()
        let value = try await Watchdog.run(what: "work", limit: 0.3, pulse: pulse, checkEvery: 0.05) {
            for _ in 0..<10 {
                try await Task.sleep(nanoseconds: 100_000_000)
                pulse.beat()
            }
            return "done"
        }
        XCTAssertEqual(value, "done", "a full second of work under a 0.3 s limit, kept alive by beats")
    }

    func testWorkThatStopsBeatingIsCancelled() async {
        let pulse = Watchdog.Pulse()
        let cancelled = expectation(description: "work cancelled")
        do {
            _ = try await Watchdog.run(what: "work", limit: 0.2, pulse: pulse, checkEvery: 0.05) { () async throws -> Int in
                pulse.beat()
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { cancelled.fulfill(); throw error }
                return 1
            }
            XCTFail("should have stalled")
        } catch {
            XCTAssertTrue(error is Watchdog.Stalled)
        }
        await fulfillment(of: [cancelled], timeout: 2)
    }

    func testErrorsFromTheWorkPassThrough() async {
        struct Boom: Error {}
        do {
            _ = try await Watchdog.run(what: "work", limit: 1) { () async throws -> Int in throw Boom() }
            XCTFail("should throw")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }

    func testCancellingTheCallerCancelsTheWork() async {
        let caller = Task {
            try await Watchdog.run(what: "work", limit: 10) { () async throws -> Int in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return 1
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        caller.cancel()
        let result = await caller.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
    }
}
