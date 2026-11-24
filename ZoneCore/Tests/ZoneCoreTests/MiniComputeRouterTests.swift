// by zayd/cold @ zayd.wtf

import Foundation
import XCTest
@testable import ZoneCore

final class MiniComputeRouterTests: XCTestCase {
    private let cpu: MiniComputeRouter.Decode = { _ in RecognizedSegment(text: "CPU") }
    private let fast: MiniComputeRouter.Decode = { _ in RecognizedSegment(text: "fast") }
    private let router = MiniComputeRouter()

    private func next() -> MiniComputeRouter.Decode {
        router.session(cpu: cpu, report: { _, _ in }, onFailure: { _ in })
    }

    func testPreparationOnlyPromotesTheNextForegroundRecording() async throws {
        let early = next()
        let slow = expectation(description: "preparation began")
        let release = AsyncStream<Void>.makeStream()
        router.configure(enabled: true, foreground: true, prepare: { [fast] in
            slow.fulfill()
            for await _ in release.stream { break }
            return fast
        }, onFailure: { _ in XCTFail() })
        await fulfillment(of: [slow], timeout: 5)
        let during = next()
        let whileLoading = try await during([]).text
        XCTAssertEqual(whileLoading, "CPU")
        release.continuation.finish()
        await router.waitForPreparation()
        for session in [early, during] {
            let result = try await session([]).text
            XCTAssertEqual(result, "CPU")
        }
        let fixedCPU = router.session(cpu: cpu, allowAcceleration: false, report: { _, _ in }, onFailure: { _ in })
        let benchmark = try await fixedCPU([]).text
        XCTAssertEqual(benchmark, "CPU")
        let active = next()
        let result = try await active([]).text
        XCTAssertEqual(result, "fast")
        router.configure(enabled: true, foreground: false, prepare: { fatalError() }, onFailure: { _ in })
        let background = try await active([]).text
        XCTAssertEqual(background, "CPU")
        router.configure(enabled: true, foreground: true, prepare: { fatalError() }, onFailure: { _ in })
        let pinned = try await active([]).text
        XCTAssertEqual(pinned, "CPU")
    }

    func testFailedPredictionPublishesOneCPUResultAndDisablesAcceleration() async throws {
        struct Failure: Error {}
        router.configure(enabled: true, foreground: true, prepare: { { _ in throw Failure() } }, onFailure: { _ in })
        await router.waitForPreparation()
        let attempts = expectation(description: "one retry")
        let decode = router.session(cpu: { samples in
            XCTAssertEqual(samples, [1, 2, 3])
            return RecognizedSegment(text: "one two three")
        }, report: { route, _ in XCTAssertEqual(route, "cpuOnly") }, onFailure: { _ in attempts.fulfill() })
        let recording = RollingRecognitionSession(decodeSegment: decode)
        recording.feed([1, 2, 3])
        let text = try await recording.finish()
        XCTAssertEqual(text, "one two three")
        XCTAssertEqual(recording.textSoFar, text)
        await fulfillment(of: [attempts], timeout: 2)
        let nextResult = try await next()([]).text
        XCTAssertEqual(nextResult, "CPU")
    }

    func testOnlyTheFailedRollingSegmentIsReplayed() async throws {
        struct Failure: Error {}
        let retry = expectation(description: "one retry after a published prefix")
        router.configure(enabled: true, foreground: true, prepare: {
            { samples in
                if samples.first == 1 { return RecognizedSegment(text: "first") }
                XCTAssertEqual(samples.first, 2)
                throw Failure()
            }
        }, onFailure: { _ in XCTFail() })
        await router.waitForPreparation()
        let decode = router.session(cpu: { samples in
            XCTAssertEqual(samples.count, 160)
            return RecognizedSegment(text: samples.first == 2 ? "second" : "third")
        }, report: { _, _ in }, onFailure: { _ in retry.fulfill() })
        let recording = RollingRecognitionSession(segmenter: RollingSegmenter(segmentSeconds: 0.01, searchSeconds: 0),
                                                  decodeSegment: decode)
        for marker in [Float(1), 2, 3] {
            recording.feed([Float](repeating: marker, count: 160))
        }
        let result = try await recording.finish()
        XCTAssertEqual(result, "first second third")
        await fulfillment(of: [retry], timeout: 2)
    }

    func testOffAndFailedPreparationLeaveCPUAvailable() async throws {
        struct Failure: Error {}
        router.configure(enabled: false, foreground: true, prepare: { XCTFail(); throw Failure() }, onFailure: { _ in })
        router.configure(enabled: true, foreground: false, prepare: { XCTFail(); throw Failure() }, onFailure: { _ in })
        router.configure(enabled: true, foreground: true, prepare: { throw Failure() }, onFailure: { _ in })
        await router.waitForPreparation()
        let result = try await next()([]).text
        XCTAssertEqual(result, "CPU")
    }
}
