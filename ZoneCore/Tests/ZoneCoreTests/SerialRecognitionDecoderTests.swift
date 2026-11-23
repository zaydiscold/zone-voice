// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class SerialRecognitionDecoderTests: XCTestCase {
    actor Concurrency {
        var active = 0
        var peak = 0
        func begin() { active += 1; peak = max(peak, active) }
        func end() { active -= 1 }
    }

    func testSharedLaneSerializesAcrossAwaitPoints() async throws {
        let lane = SerialRecognitionDecoder()
        let concurrency = Concurrency()
        let entered = expectation(description: "first decode running")
        let (gate, release) = AsyncStream<Void>.makeStream()
        let first = Task {
            try await lane.run {
                await concurrency.begin()
                entered.fulfill()
                for await _ in gate { break }
                await concurrency.end()
                return "first"
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        let second = Task {
            try await lane.run {
                await concurrency.begin()
                await concurrency.end()
                return "second"
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        release.yield(())
        release.finish()
        let a = try await first.value
        let b = try await second.value
        XCTAssertEqual([a, b], ["first", "second"])
        let peak = await concurrency.peak
        XCTAssertEqual(peak, 1)
    }

    func testCancelPropagatesToCooperativeNativeJob() async {
        let lane = SerialRecognitionDecoder()
        let entered = expectation(description: "entered")
        let cancelled = expectation(description: "cancel forwarded")
        let job = Task {
            try await lane.run {
                entered.fulfill()
                do { try await Task.sleep(for: .seconds(30)) }
                catch { cancelled.fulfill(); throw error }
                return "must not arrive"
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        job.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        do { _ = try await job.value; XCTFail("cancelled decoder must throw") } catch {}
        await lane.drain()
    }

    // MARK: Warm-up

    final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 1_000
        var now: TimeInterval { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    }

    actor Log {
        var entries: [String] = []
        func add(_ entry: String) { entries.append(entry) }
    }

    func testWarmUpRunsOnALaneThatHasNeverDecoded() async {
        let lane = SerialRecognitionDecoder()
        let ran = expectation(description: "warm-up ran")
        XCTAssertTrue(lane.warmUp(ifIdleFor: 5) { ran.fulfill() })
        await fulfillment(of: [ran], timeout: 2)
        await lane.drain()
        XCTAssertNotNil(lane.idleSeconds)
    }

    func testWarmUpWaitsForTheIdleThresholdAfterADecode() async throws {
        let clock = FakeClock()
        let lane = SerialRecognitionDecoder(clock: { clock.now })
        _ = try await lane.run { "text" }
        await lane.drain()
        clock.advance(4.9)
        XCTAssertFalse(lane.warmUp(ifIdleFor: 5) {}, "a model used 4.9 s ago is still warm")
        clock.advance(0.2)
        XCTAssertTrue(lane.warmUp(ifIdleFor: 5) {}, "5.1 s idle needs a warm-up")
        await lane.drain()
        XCTAssertFalse(lane.warmUp(ifIdleFor: 5) {}, "the warm-up itself counts as activity")
    }

    func testWarmUpIsSkippedWhileADecodeIsQueuedOrRunning() async throws {
        let lane = SerialRecognitionDecoder()
        let entered = expectation(description: "decode running")
        let (gate, release) = AsyncStream<Void>.makeStream()
        let job = Task {
            try await lane.run {
                entered.fulfill()
                for await _ in gate { break }
                return "busy"
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertFalse(lane.warmUp(ifIdleFor: 0) { XCTFail("a busy model is warm") })
        XCTAssertNil(lane.idleSeconds)
        release.yield(())
        release.finish()
        _ = try await job.value
        await lane.drain()
    }

    func testWarmUpRunsBeforeTheDecodeQueuedAfterIt() async throws {
        let lane = SerialRecognitionDecoder()
        let log = Log()
        let (gate, release) = AsyncStream<Void>.makeStream()
        // Queued synchronously, so the decode below cannot overtake it even though the
        // warm-up is still waiting when the decode is queued.
        XCTAssertTrue(lane.warmUp(ifIdleFor: 5) {
            for await _ in gate { break }
            await log.add("warm-up")
        })
        let decode = Task { try await lane.run { await log.add("decode"); return "text" } }
        try await Task.sleep(for: .milliseconds(30))
        let early = await log.entries
        XCTAssertEqual(early, [], "the decode waits for the warm-up")
        release.yield(())
        release.finish()
        let text = try await decode.value
        XCTAssertEqual(text, "text")
        let order = await log.entries
        XCTAssertEqual(order, ["warm-up", "decode"])
    }

    func testAFailedWarmUpDoesNotFailTheNextDecode() async throws {
        struct WarmUpFailure: Error {}
        let lane = SerialRecognitionDecoder()
        XCTAssertTrue(lane.warmUp(ifIdleFor: 5) { throw WarmUpFailure() })
        let text = try await lane.run { "after" }
        XCTAssertEqual(text, "after")
    }
}
