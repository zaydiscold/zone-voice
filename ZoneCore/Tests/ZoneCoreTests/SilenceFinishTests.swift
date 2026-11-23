// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class SilenceFinishTests: XCTestCase {
    /// The meter level for a loudness, as the capture engine posts it.
    private func level(_ decibels: Float) -> Float {
        var scale = AdaptiveLevelScale()
        return scale.map(decibels: decibels, elapsed: 0.05)
    }

    /// Feeds `seconds` of one loudness at 20 samples a second and returns every reading.
    @discardableResult
    private func feed(_ detector: inout SilenceFinish, _ decibels: Float, seconds: Double,
                      from start: inout TimeInterval) -> [SilenceFinish.Reading] {
        var readings: [SilenceFinish.Reading] = []
        for _ in 0..<Int((seconds * 20).rounded()) {
            readings.append(detector.sample(level: level(decibels), at: start))
            start += 0.05
        }
        return readings
    }

    func testLevelConvertsBackToDecibels() {
        for decibels: Float in [-50, -43.6, -30, -12, -2] {
            XCTAssertEqual(SilenceFinish.decibels(forLevel: level(decibels)), decibels, accuracy: 0.01)
        }
    }

    func testQuietBeforeTheFirstWordNeverFinishes() {
        var detector = SilenceFinish(wait: 10), now: TimeInterval = 0
        let readings = feed(&detector, -60, seconds: 120, from: &now)
        XCTAssertTrue(readings.allSatisfy { $0 == .waitingForVoice })
    }

    func testFinishesOnceAfterTheWait() {
        var detector = SilenceFinish(wait: 10), now: TimeInterval = 0
        feed(&detector, -60, seconds: 2, from: &now)
        XCTAssertEqual(feed(&detector, -25, seconds: 3, from: &now).last, .hearing)
        let quiet = feed(&detector, -60, seconds: 9.9, from: &now)
        XCTAssertFalse(quiet.contains(.finish))
        guard case .quiet(let remaining)? = quiet.last else { return XCTFail("expected a countdown") }
        XCTAssertLessThan(remaining, 0.5)
        let after = feed(&detector, -60, seconds: 5, from: &now)
        XCTAssertEqual(after.filter { $0 == .finish }.count, 1, "reported once, then the wait starts over")
    }

    func testAnySoundStartsTheWaitOver() {
        var detector = SilenceFinish(wait: 10), now: TimeInterval = 0
        feed(&detector, -25, seconds: 3, from: &now)
        for _ in 0..<5 {
            XCTAssertFalse(feed(&detector, -60, seconds: 8, from: &now).contains(.finish))
            feed(&detector, -28, seconds: 0.5, from: &now)
        }
        // The last sound lingers a few samples past the voice, so allow a little over the wait.
        XCTAssertTrue(feed(&detector, -60, seconds: 10.5, from: &now).contains(.finish))
    }

    func testOneClickIsNotAVoice() {
        var detector = SilenceFinish(wait: 10), now: TimeInterval = 0
        feed(&detector, -25, seconds: 3, from: &now)
        feed(&detector, -60, seconds: 6, from: &now)
        feed(&detector, -10, seconds: 0.05, from: &now)   // a single loud sample
        XCTAssertTrue(feed(&detector, -60, seconds: 4.2, from: &now).contains(.finish))
    }

    func testHumOfALoudRoomReadsAsQuiet() {
        // An air conditioner at -38 dBFS is louder than the fixed bar; the voice is well above it.
        var detector = SilenceFinish(wait: 10), now: TimeInterval = 0
        feed(&detector, -38, seconds: 3, from: &now)
        feed(&detector, -20, seconds: 5, from: &now)
        XCTAssertTrue(feed(&detector, -38, seconds: 10.2, from: &now).contains(.finish))
    }

    func testVoiceBarelyOverTheNoiseIsNeverCutOff() {
        // Speech only 6 dB over steady noise: the two cannot be told apart safely, so nothing
        // reads as quiet and the dictation runs until it is stopped by hand.
        var detector = SilenceFinish(wait: 10), now: TimeInterval = 0
        var readings: [SilenceFinish.Reading] = []
        for _ in 0..<20 {
            readings += feed(&detector, -28, seconds: 2, from: &now)
            readings += feed(&detector, -34, seconds: 1, from: &now)
        }
        readings += feed(&detector, -34, seconds: 30, from: &now)
        XCTAssertFalse(readings.contains(.finish))
    }

    func testSoftContinuousSpeechIsNotQuiet() {
        // No pause for a minute: the quietest of the voice must not be taken for the room.
        var detector = SilenceFinish(wait: 10), now: TimeInterval = 0
        var readings: [SilenceFinish.Reading] = []
        for step in 0..<1_200 {
            let decibels: Float = -30 + 8 * Float(sin(Double(step) * 0.9))
            readings.append(detector.sample(level: level(decibels), at: now))
            now += 0.05
        }
        XCTAssertFalse(readings.contains(.finish))
        XCTAssertFalse(readings.dropFirst(10).contains { if case .quiet(let left) = $0 { return left < 9 } else { return false } })
    }

    func testAGapInSamplesIsNotJudged() {
        // The microphone was away for a call: the missing minute is not quiet.
        var detector = SilenceFinish(wait: 10), now: TimeInterval = 0
        feed(&detector, -25, seconds: 3, from: &now)
        feed(&detector, -60, seconds: 4, from: &now)
        now += 60
        let readings = feed(&detector, -60, seconds: 9.5, from: &now)
        XCTAssertFalse(readings.contains(.finish))
        XCTAssertTrue(feed(&detector, -60, seconds: 1, from: &now).contains(.finish))
    }

    func testRestartingTheWaitAfterAPause() {
        var detector = SilenceFinish(wait: 10), now: TimeInterval = 0
        feed(&detector, -25, seconds: 3, from: &now)
        feed(&detector, -60, seconds: 9, from: &now)
        detector.restartWait(at: now)
        XCTAssertFalse(feed(&detector, -60, seconds: 9.5, from: &now).contains(.finish))
    }

    func testLabelsAndChoices() {
        XCTAssertEqual(SilenceFinish.waitChoices.map(SilenceFinish.waitLabel),
                       ["10 seconds", "20 seconds", "30 seconds", "1 minute", "2 minutes"])
        XCTAssertTrue(SilenceFinish.waitChoices.contains(SilenceFinish.defaultWait))
    }

    /// Runs the detector over real dictations kept outside the repository. Skipped unless
    /// `ZONE_SILENCE_CORPUS` names a file of JSON lines with `levels` (the meter level every
    /// 50 ms) and `words` (start and end seconds of each recognized word).
    func testMeasureOnACorpus() throws {
        guard let corpus = ProcessInfo.processInfo.environment["ZONE_SILENCE_CORPUS"] else {
            throw XCTSkip("Set ZONE_SILENCE_CORPUS to measure on real dictations.")
        }
        var report = ""
        let lines = try String(contentsOfFile: corpus, encoding: .utf8).split(separator: "\n")
        for wait in SilenceFinish.waitChoices {
            var cutWhileTalking = 0, finished = 0, kept = 0
            for line in lines {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let levels = object["levels"] as? [Double], let words = object["words"] as? [[Double]] else { continue }
                var detector = SilenceFinish(wait: wait), fired: TimeInterval?
                for (index, level) in levels.enumerated() where fired == nil {
                    if detector.sample(level: Float(level), at: Double(index) * 0.05) == .finish { fired = Double(index) * 0.05 }
                }
                guard let fired else { kept += 1; continue }
                // Seconds since a word ended; nil before the first word, 0 inside one.
                let inside = words.contains { $0[0] <= fired && fired <= $0[1] }
                let lastEnd = words.map { $0[1] }.filter { $0 < fired }.max()
                let sinceWord = inside ? 0 : lastEnd.map { fired - $0 }
                if let sinceWord, sinceWord >= wait - 2 { finished += 1 } else { cutWhileTalking += 1 }
            }
            report += "wait \(Int(wait)) s: cut while talking \(cutWhileTalking), finished in a real pause \(finished), kept recording \(kept)\n"
        }
        print(report)
        if let out = ProcessInfo.processInfo.environment["ZONE_SILENCE_OUT"] {
            try report.write(toFile: out, atomically: true, encoding: .utf8)
        }
    }
}
