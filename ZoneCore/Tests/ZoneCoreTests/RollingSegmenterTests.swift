// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class RollingSegmenterTests: XCTestCase {
    private func speech(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * 16_000)).map { Float(sin(Double($0) * 0.07)) * 0.3 }
    }

    private func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * 16_000)) }

    func testShortBufferIsNotCut() {
        XCTAssertNil(RollingSegmenter().cut(speech(23.9)))
    }

    func testCutLandsInsideThePauseBetweenWords() {
        // Speech, a 400 ms pause starting at 20.0 s, more speech up to 24.5 s.
        let audio = speech(20) + silence(0.4) + speech(4.1)
        let cut = try! XCTUnwrap(RollingSegmenter().cut(audio))
        XCTAssertGreaterThanOrEqual(cut, 20 * 16_000)
        XCTAssertLessThanOrEqual(cut, Int(20.4 * 16_000))
    }

    func testUnbrokenSpeechIsStillCutSoTheBufferStaysBounded() {
        let cut = try! XCTUnwrap(RollingSegmenter().cut(speech(25)))
        XCTAssertGreaterThan(cut, 18 * 16_000)
        XCTAssertLessThan(cut, 25 * 16_000)
    }

    func testTenMinutesSplitIntoBoundedSegments() {
        var buffer: [Float] = []
        var segments: [Int] = []
        let piece = speech(2.8) + silence(0.3)
        for _ in 0..<(600 / 3) {
            buffer += piece
            while let cut = RollingSegmenter().cut(buffer) {
                segments.append(cut)
                buffer.removeFirst(cut)
            }
        }
        // Each cut lands in the last 6 s of a 24 s window: segments run 18 to 24 s.
        XCTAssertTrue((600 / 24)...(600 / 18) ~= segments.count, "\(segments.count) segments")
        XCTAssertTrue(segments.allSatisfy { $0 <= 25 * 16_000 })
        XCTAssertLessThan(buffer.count, 24 * 16_000)
    }
}
