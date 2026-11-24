// by zayd/cold @ zayd.wtf

import AVFAudio
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

    func testNewSteadyFloorAfterSpeechAndResumedSentence() {
        var detector = SilenceFinish(wait: 5), now: TimeInterval = 0
        feed(&detector, -50, seconds: 4, from: &now)
        feed(&detector, -18, seconds: 0.65, from: &now)
        XCTAssertFalse(feed(&detector, -32, seconds: 4, from: &now).contains(.finish))
        // The speaker continues before the five seconds are up.
        for _ in 0..<5 {
            XCTAssertFalse(feed(&detector, -23, seconds: 0.15, from: &now).contains(.finish))
            XCTAssertFalse(feed(&detector, -35, seconds: 0.15, from: &now).contains(.finish))
        }
        var result: [SilenceFinish.Reading] = []
        for step in 0..<115 {
            let db: Float = -32 + Float(sin(Double(step))) * 0.7
            result.append(detector.sample(level: level(db), at: now))
            now += 0.05
        }
        XCTAssertFalse(result.prefix(98).contains(.finish))
        XCTAssertEqual(result.filter { $0 == .finish }.count, 1)
    }

    func testBundledSpeechFollowedByANewFanFloor() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let file = try AVAudioFile(forReading: root.appendingPathComponent("Zone/Resources/test-clip.wav"))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 800))
        var detector = SilenceFinish(wait: 5), now: TimeInterval = 0
        feed(&detector, -50, seconds: 4, from: &now)
        var heard = false
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: 800)
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            let samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
            let energy = samples.reduce(Float.zero) { $0 + $1 * $1 } / Float(samples.count)
            let reading = detector.sample(level: level(10 * log10(max(energy, 1e-10))), at: now)
            XCTAssertNotEqual(reading, .finish)
            if reading == .hearing { heard = true }
            now += 0.05
        }
        XCTAssertTrue(heard)
        let fan = feed(&detector, -32, seconds: 5.6, from: &now)
        XCTAssertTrue(fan.contains(.finish))
    }

    func testRecordedSpeechTracesWithNewFloorsAndMissingReadings() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "quiet-meter-traces", withExtension: "txt"))
        let rows = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").filter { !$0.hasPrefix("#") }
        XCTAssertEqual(rows.count, 2)
        for (index, row) in rows.enumerated() {
            let fields = row.split(separator: " ")
            var detector = SilenceFinish(wait: 5), now: TimeInterval = 0
            feed(&detector, -52, seconds: 3, from: &now)
            for sample in fields.dropFirst() {
                let db = try XCTUnwrap(Float(sample))
                XCTAssertNotEqual(detector.sample(level: level(db), at: now), .finish, String(fields[0]))
                now += 0.05
            }
            let floor: Float = index == 0 ? -32 : -28
            XCTAssertFalse(feed(&detector, floor, seconds: 3, from: &now).contains(.finish))
            now += 4
            let resumed = feed(&detector, floor, seconds: 2.4, from: &now)
            XCTAssertFalse(resumed.prefix(36).contains(.finish), "Do not count time without input")
            XCTAssertEqual(resumed.filter { $0 == .finish }.count, 1, "Do not restart the observed wait")
        }
    }

    func testLevelConvertsBackToDecibels() {
        for decibels: Float in [-50, -43.6, -30, -12, -2] {
            XCTAssertEqual(SilenceFinish.decibels(forLevel: level(decibels)), decibels, accuracy: 0.01)
        }
    }

    /// The recording log says what a quiet finish was judged against, so a recording that
    /// ended on someone still talking can be told from one that ended on silence.
    func testTheLogSaysWhatTheWaitWasJudgedAgainst() {
        var detector = SilenceFinish(wait: 5), now: TimeInterval = 0
        feed(&detector, -40, seconds: 4, from: &now)
        feed(&detector, -22, seconds: 4, from: &now)
        feed(&detector, -40, seconds: 2, from: &now)
        let fields = detector.journalFields
        XCTAssertEqual(fields["roomDB"], "-40")
        XCTAssertEqual(fields["voiceDB"], "-22")
        XCTAssertEqual(fields["samples"], "200")
        XCTAssertEqual(fields["loudShare"], "0.40")
        let bar = Int(fields["barDB"] ?? "") ?? 0
        XCTAssertTrue((-39 ... -23).contains(bar), "the bar sits between the room and the voice: \(bar)")
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

    func testShortAnswerOverSteadyNoiseFinishesAfterFiveSeconds() {
        var detector = SilenceFinish(wait: 5), now: TimeInterval = 0
        XCTAssertTrue(feed(&detector, -38, seconds: 40, from: &now).allSatisfy { $0 == .waitingForVoice })
        feed(&detector, -20, seconds: 0.5, from: &now)
        let quiet = feed(&detector, -38, seconds: 15, from: &now)
        XCTAssertTrue(quiet.prefix(98).allSatisfy { $0 != .finish })
        XCTAssertTrue(quiet.prefix(110).contains(.finish))
    }

    func testQuietVoiceOverFanResetsWaitUntilOnlyFanRemains() {
        // With speech only 6 dB over the fan, listen through the quieter intervals between words.
        var detector = SilenceFinish(wait: 10), now: TimeInterval = 0
        var readings: [SilenceFinish.Reading] = []
        for _ in 0..<20 {
            readings += feed(&detector, -28, seconds: 2, from: &now)
            readings += feed(&detector, -34, seconds: 1, from: &now)
        }
        XCTAssertFalse(readings.contains(.finish))
        XCTAssertTrue(feed(&detector, -34, seconds: 10.5, from: &now).contains(.finish))
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

    func testInputStallsFreezeTheCountdownWithoutErasingObservedQuiet() {
        // The microphone was away for a call: the missing minute is not quiet.
        var detector = SilenceFinish(wait: 5), now: TimeInterval = 0
        feed(&detector, -25, seconds: 3, from: &now)
        feed(&detector, -60, seconds: 4, from: &now)
        now += 2
        let readings = feed(&detector, -60, seconds: 0.75, from: &now)
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
                       ["2 seconds", "3 seconds", "5 seconds", "6 seconds", "7 seconds", "10 seconds", "30 seconds"])
        XCTAssertEqual(SilenceFinish.defaultWait, 5)
        XCTAssertEqual(SilenceFinish.waitChoices.first, 2, "2 s is offered to try; under it a breath ends every dictation")
        XCTAssertEqual(SilenceFinish.waitLabel(60), "1 minute")
        XCTAssertEqual(SilenceFinish.waitLabel(120), "2 minutes")
    }

    func testCustomWaitSurvivesKeyboardRoundTrip() throws {
        for wait in 1...60 {
            let seconds = Double(wait)
            var prefs = KeyboardPreferences(finishWhenQuietWait: seconds)
            QuickSetting.quiet(enabled: false, wait: seconds).apply(to: &prefs)
            let stored = try JSONEncoder().encode(prefs)
            var decoded = try JSONDecoder().decode(KeyboardPreferences.self, from: stored)
            XCTAssertEqual(decoded.quietWait, seconds)
            XCTAssertNil(decoded.finishWhenQuietWait)
            XCTAssertEqual(SilenceFinish.waitChoices(including: decoded.quietWait).filter { $0 == seconds }, [seconds])
            QuickSetting.quiet(enabled: true, wait: decoded.quietWait).apply(to: &decoded)
            XCTAssertEqual(decoded.finishWhenQuietWait, seconds)
        }
        XCTAssertEqual(SilenceFinish.nearestChoice(8.5), 9)
        XCTAssertEqual(SilenceFinish.nearestChoice(120), 60)
        XCTAssertEqual(SilenceFinish.nearestChoice(0), SilenceFinish.defaultWait)
        XCTAssertEqual(SilenceFinish.nearestChoice(.nan), SilenceFinish.defaultWait)
        XCTAssertEqual(SilenceFinish.waitLabel(1), "1 second")
    }

    /// Runs the detector over real dictations kept outside the repository. Skipped unless
    /// `ZONE_SILENCE_CORPUS` names a file of JSON lines with `levels` (the meter level every
    /// 50 ms) and `words` (start and end seconds of each recognized word). `ZONE_SILENCE_WAITS`
    /// ("3,5,7") measures waits other than the Settings choices.
    ///
    /// Two ways a finish can be wrong. "Misheard" fires while a word is still sounding or right
    /// after one, so the detector took speech for quiet. "Ended early" fires in a real pause but
    /// the speaker had more to say: some word starts after the finish, and those words would be
    /// lost from the dictation (they start a new one by hand instead).
    func testMeasureOnACorpus() throws {
        guard let corpus = ProcessInfo.processInfo.environment["ZONE_SILENCE_CORPUS"] else {
            throw XCTSkip("Set ZONE_SILENCE_CORPUS to measure on real dictations.")
        }
        let waits = ProcessInfo.processInfo.environment["ZONE_SILENCE_WAITS"]?
            .split(separator: ",").compactMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            ?? SilenceFinish.waitChoices
        var report = ""
        let lines = try String(contentsOfFile: corpus, encoding: .utf8).split(separator: "\n")
        for wait in waits {
            var misheard = 0, endedEarly = 0, wordsLost = 0, wordsTotal = 0, clean = 0, kept = 0
            var afterLastWord: [Double] = []
            for line in lines {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let levels = object["levels"] as? [Double], let words = object["words"] as? [[Double]] else { continue }
                wordsTotal += words.count
                var detector = SilenceFinish(wait: wait), fired: TimeInterval?
                for (index, level) in levels.enumerated() where fired == nil {
                    if detector.sample(level: Float(level), at: Double(index) * 0.05) == .finish { fired = Double(index) * 0.05 }
                }
                guard let fired else { kept += 1; continue }
                let still = words.filter { $0[0] > fired }.count
                if stoppedNearSpeech(at: fired, words: words, wait: wait) {
                    misheard += 1
                } else if still > 0 {
                    endedEarly += 1
                    wordsLost += still
                } else {
                    clean += 1
                    if let last = words.map({ $0[1] }).max() { afterLastWord.append(fired - last) }
                }
            }
            afterLastWord.sort()
            let median = afterLastWord.isEmpty ? 0 : afterLastWord[afterLastWord.count / 2]
            report += "wait \(wait) s: misheard \(misheard), ended early \(endedEarly) (\(wordsLost) of \(wordsTotal) words lost), "
                + "finished after the last word \(clean) (median \(String(format: "%.1f", median)) s after it), kept recording \(kept)\n"
        }
        print(report)
        if let out = ProcessInfo.processInfo.environment["ZONE_SILENCE_OUT"] {
            try report.write(toFile: out, atomically: true, encoding: .utf8)
        }
    }

    private func stoppedNearSpeech(at fired: Double, words: [[Double]], wait: Double) -> Bool {
        if words.contains(where: { $0[0] <= fired && fired <= $0[1] }) { return true }
        guard let lastEnd = words.map({ $0[1] }).filter({ $0 < fired }).max() else { return true }
        return fired - lastEnd < wait - 2
    }

    func testCorpusCountsAStopInsideAWordEvenAtTheShortestWait() {
        for wait in [1.0, 2.0, 5.0] {
            XCTAssertTrue(stoppedNearSpeech(at: 2.5, words: [[2, 3]], wait: wait))
            XCTAssertTrue(stoppedNearSpeech(at: 1, words: [[2, 3]], wait: wait))
            XCTAssertFalse(stoppedNearSpeech(at: 9, words: [[2, 3], [12, 13]], wait: wait))
        }
    }

    func testQuietIsSaidAfterTwoSecondsOrHalfAShortWait() {
        XCTAssertEqual(SilenceFinish.noticeDelay(wait: 10), 2)
        XCTAssertEqual(SilenceFinish.noticeDelay(wait: 30), 2)
        XCTAssertEqual(SilenceFinish.noticeDelay(wait: 3), 1.5)
        XCTAssertFalse(SilenceFinish.saysQuiet(remaining: 8.5, wait: 10), "1.5 s of quiet is a breath")
        XCTAssertTrue(SilenceFinish.saysQuiet(remaining: 8, wait: 10))
        XCTAssertTrue(SilenceFinish.saysQuiet(remaining: 0.2, wait: 10))
        XCTAssertTrue(SilenceFinish.saysQuiet(remaining: 1.5, wait: 3))
        XCTAssertFalse(SilenceFinish.saysQuiet(remaining: 2, wait: 3))
    }

    /// The keyboard's "Finishing in N" and the app's countdown start when the island and the note
    /// card say "Quiet", never on a breath, and show only the last five seconds of a long wait.
    func testCountdownStartsWithQuietAndShowsTheLastFiveSeconds() {
        // 5 s, the default: a breath between sentences shows nothing; from 2 s of quiet, 3 2 1.
        XCTAssertNil(SilenceFinish.countdown(remaining: 4.95, wait: 5), "the first quiet sample is a breath")
        XCTAssertNil(SilenceFinish.countdown(remaining: 3.5, wait: 5))
        XCTAssertEqual(SilenceFinish.countdown(remaining: 3, wait: 5), 3)
        XCTAssertEqual(SilenceFinish.countdown(remaining: 0.05, wait: 5), 1)
        // 3 s: from 1.5 s of quiet, 2 1.
        XCTAssertNil(SilenceFinish.countdown(remaining: 2, wait: 3))
        XCTAssertEqual(SilenceFinish.countdown(remaining: 1.5, wait: 3), 2)
        XCTAssertEqual(SilenceFinish.countdown(remaining: 0.4, wait: 3), 1)
        // 10 and 30 s: "Quiet" is said long before; the number shows for the last five.
        XCTAssertNil(SilenceFinish.countdown(remaining: 7, wait: 10))
        XCTAssertEqual(SilenceFinish.countdown(remaining: 5, wait: 10), 5)
        XCTAssertNil(SilenceFinish.countdown(remaining: 5.2, wait: 30))
        XCTAssertEqual(SilenceFinish.countdown(remaining: 4.2, wait: 30), 5)
        // Every second of the countdown is a shown number: it never says "Finishing in 0".
        for wait in SilenceFinish.waitChoices {
            for tenth in 1...Int(wait * 10) {
                let remaining = TimeInterval(tenth) / 10
                guard let n = SilenceFinish.countdown(remaining: remaining, wait: wait) else {
                    XCTAssertFalse(SilenceFinish.saysQuiet(remaining: remaining, wait: wait) && remaining <= 5,
                                   "\(wait) s wait, \(remaining) s left: Quiet is said, so the number shows")
                    continue
                }
                XCTAssertTrue((1...5).contains(n), "\(wait) s wait, \(remaining) s left gave \(n)")
                XCTAssertTrue(SilenceFinish.saysQuiet(remaining: remaining, wait: wait))
            }
        }
    }
}
