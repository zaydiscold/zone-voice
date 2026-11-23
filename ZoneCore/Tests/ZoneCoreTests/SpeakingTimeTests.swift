// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// Speaking time counts speech and the short gaps between words, never the start, a thinking
/// pause past half a second or the quiet before Stop.
final class SpeakingTimeTests: XCTestCase {
    private func quiet(_ seconds: Double, level: Float = 0.0005) -> [Float] {
        // Room noise: a faint alternating signal, so the noise floor is above zero.
        (0..<Int(seconds * 16_000)).map { $0.isMultiple(of: 2) ? level : -level }
    }
    private func voice(_ seconds: Double, level: Float = 0.2) -> [Float] {
        (0..<Int(seconds * 16_000)).map { level * sin(Float($0) * 2 * .pi * 180 / 16_000) }
    }
    private func seconds(_ audio: [[Float]], chunk: Int = 1_280) -> Double {
        var time = SpeakingTime()
        let samples = audio.flatMap { $0 }
        // Fed in capture-sized pieces that do not line up with the 100 ms frames.
        stride(from: 0, to: samples.count, by: chunk).forEach {
            time.add(Array(samples[$0..<min($0 + chunk, samples.count)]))
        }
        return time.seconds
    }

    func testSilenceIsNoSpeech() {
        XCTAssertEqual(seconds([quiet(5)]), 0)
        XCTAssertEqual(seconds([]), 0)
    }

    func testLeadingAndTrailingQuietDoNotCount() {
        XCTAssertEqual(seconds([quiet(1.5), voice(3), quiet(2)]), 3, accuracy: 0.11)
    }

    func testGapsBetweenWordsCountAndThinkingPausesStop() {
        // Two words 0.3 s apart: one stretch of talking.
        XCTAssertEqual(seconds([voice(1), quiet(0.3), voice(1)]), 2.3, accuracy: 0.11)
        // A 4 s pause to think counts only its first half second.
        XCTAssertEqual(seconds([voice(2), quiet(4), voice(2)]), 4.5, accuracy: 0.11)
    }

    func testSpeechFromTheFirstSampleCounts() {
        XCTAssertEqual(seconds([voice(2.5)]), 2.5, accuracy: 0.11)
    }

    func testQuietSpeakerStillCounts() {
        XCTAssertEqual(seconds([quiet(1), voice(2, level: 0.02), quiet(1)]), 2, accuracy: 0.11)
    }

    func testChunkSizeDoesNotChangeTheAnswer() {
        let audio = [quiet(0.7), voice(1.3), quiet(0.2), voice(0.9), quiet(3)]
        XCTAssertEqual(seconds(audio, chunk: 160), seconds(audio, chunk: 4_096))
    }

    func testClockMatchesTheValueType() {
        let clock = SpeakingClock()
        clock.add(quiet(1))
        clock.add(voice(2))
        XCTAssertEqual(clock.seconds, 2, accuracy: 0.11)
    }
}
