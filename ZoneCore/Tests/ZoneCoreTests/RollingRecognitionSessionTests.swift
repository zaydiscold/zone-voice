// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class RollingRecognitionSessionTests: XCTestCase {
    private let segmenter = RollingSegmenter(segmentSeconds: 1, searchSeconds: 0.2)
    private var second: [Float] { Array(repeating: 0.1, count: 16_000) }

    actor Counter {
        var count = 0
        func next() -> Int { count += 1; return count }
    }

    func testFailedMiddleSegmentPreservesPrefixAndDoesNotClaimComplete() async {
        let counter = Counter()
        let session = RollingRecognitionSession(segmenter: segmenter) { _ in
            let n = await counter.next()
            if n == 2 { throw RecognitionFailure.recognizer("injected decoder failure") }
            return "part\(n)"
        }
        for _ in 0..<3 { session.feed(second) }
        do { _ = try await session.finish(); XCTFail("A missing segment must not look successful") }
        catch { XCTAssertNotNil(session.failure) }
        XCTAssertEqual(session.textSoFar, "part1")
        XCTAssertEqual(session.pendingSamples, 0)
        let calls = await counter.count
        XCTAssertEqual(calls, 2, "Later segments must not conceal a gap")
    }

    func testBacklogOverloadIsBoundedAndExplicit() async {
        let session = RollingRecognitionSession(segmenter: segmenter, maxQueuedSeconds: 2) { _ in "text" }
        session.feed(Array(repeating: 0.1, count: 3 * 16_000))
        XCTAssertEqual(session.failure, .overloaded)
        XCTAssertEqual(session.pendingSamples, 0, "Rejected audio must not be retained")
        do { _ = try await session.finish(); XCTFail("Overload must not report success") }
        catch { XCTAssertEqual(error as? RecognitionFailure, .overloaded) }
    }

    func testBatchedFeedDecodesTheSameWindowsAsStreaming() async throws {
        // The first quiet gap falls inside the first 24 seconds. A burst also contains
        // a later gap, which belongs to the next window.
        let rate = RollingSegmenter.sampleRate
        var audio = [Float](repeating: 0.25, count: 47 * rate)
        for start in [20, 43] {
            audio.replaceSubrange(start * rate..<(start + 1) * rate,
                                  with: repeatElement(Float.zero, count: rate))
        }
        let burst = RollingRecognitionSession { String($0.count) }
        let live = RollingRecognitionSession { String($0.count) }
        burst.feed(audio)
        for offset in stride(from: 0, to: audio.count, by: rate) {
            live.feed(Array(audio[offset..<(offset + rate)]))
        }
        let burstText = try await burst.finish()
        let liveText = try await live.finish()
        let sizes = burstText.split(separator: " ").compactMap { Int($0) }
        XCTAssertEqual(burstText, liveText)
        XCTAssertEqual(sizes.reduce(0, +), audio.count)
        XCTAssertTrue(sizes.allSatisfy { $0 <= 24 * rate })
    }

    func testRecordingCanExceedTwoMinutesWithoutDurationCutoff() async throws {
        let session = RollingRecognitionSession(segmenter: segmenter, maxQueuedSeconds: 140) { _ in "word" }
        for _ in 0..<130 { session.feed(second) }
        let text = try await session.finish()
        XCTAssertEqual(text.split(separator: " ").count, 130)
        XCTAssertEqual(session.audioSeconds, 130)
        XCTAssertEqual(session.pendingSamples, 0)
    }

    func testCancellationDuringDecodeDiscardsLateResultAndQueuedWork() async {
        let entered = expectation(description: "decoder entered")
        let (gate, release) = AsyncStream<Void>.makeStream()
        let counter = Counter()
        let session = RollingRecognitionSession(segmenter: segmenter) { _ in
            _ = await counter.next()
            entered.fulfill()
            for await _ in gate { break }
            return "late result"
        }
        session.feed(second)
        session.feed(second)
        await fulfillment(of: [entered], timeout: 2)
        session.cancel()
        release.yield(())
        release.finish()
        for _ in 0..<10_000 where session.pendingSamples > 0 { await Task.yield() }
        XCTAssertEqual(session.pendingSamples, 0)
        XCTAssertEqual(session.textSoFar, "")
        let calls = await counter.count
        XCTAssertEqual(calls, 1)
        do { _ = try await session.finish(); XCTFail("Cancelled session must not finish") }
        catch { XCTAssertEqual(error as? RecognitionFailure, .cancelled) }
    }

    func testBacklogFailureIsStickyAndReleasedAudioAllowsLongRunningUse() {
        let backlog = RecognitionBacklog(maxSamples: 10)
        for _ in 0..<1_000 { XCTAssertTrue(backlog.admit(10)); backlog.release(10) }
        XCTAssertTrue(backlog.admit(8))
        XCTAssertFalse(backlog.admit(3))
        backlog.release(8)
        XCTAssertFalse(backlog.admit(1), "After losing audio, never resume as if complete")
        XCTAssertEqual(backlog.failure, .overloaded)
    }
}
