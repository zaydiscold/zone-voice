// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class DictationStatsTests: XCTestCase {
    func testMinutesSavedIsTypingLessSpeaking() {
        // 3,620 words take 100 minutes to type; 20 of them were spent speaking.
        XCTAssertEqual(DictationStats.minutesSaved(words: 3_620, secondsSpoken: 1_200), 80)
        // Slow speech never reports negative time.
        XCTAssertEqual(DictationStats.minutesSaved(words: 10, secondsSpoken: 600), 0)
        XCTAssertEqual(DictationStats.minutesSaved(words: -5, secondsSpoken: -1), 0)
    }

    func testTypingBaselineIsPalinEtAl() {
        XCTAssertEqual(DictationStats.typingWordsPerMinute, 36.2)
    }

    func testWordsPerMinuteUsesSpeakingTime() {
        XCTAssertEqual(DictationStats.wordsPerMinute(words: 250, speakingSeconds: 120), 125)
        // Under 10 s of speech says nothing.
        XCTAssertEqual(DictationStats.wordsPerMinute(words: 20, speakingSeconds: 9.9), 0)
        XCTAssertEqual(DictationStats.wordsPerMinute(words: 0, speakingSeconds: 60), 0)
    }

    func testTimeLabelThresholds() {
        XCTAssertEqual(DictationStats.timeLabel(minutes: 0), "0 min")
        XCTAssertEqual(DictationStats.timeLabel(minutes: 1), "1 min")
        XCTAssertEqual(DictationStats.timeLabel(minutes: 59), "59 min")
        XCTAssertEqual(DictationStats.timeLabel(minutes: 60), "1h")
        XCTAssertEqual(DictationStats.timeLabel(minutes: 125), "2h 5m")
        XCTAssertEqual(DictationStats.timeLabel(minutes: 1_439), "23h 59m")
        XCTAssertEqual(DictationStats.timeLabel(minutes: 1_440), "1d")
        XCTAssertEqual(DictationStats.timeLabel(minutes: 1_440 * 3 + 250), "3d 4h")
        XCTAssertEqual(DictationStats.timeLabel(minutes: -3), "0 min")
    }

    func testHelpedLineCountsPeople() {
        XCTAssertEqual(DictationStats.helpedLine(people: 1), "Shared Zone with 1 person")
        XCTAssertEqual(DictationStats.helpedLine(people: 2), "Shared Zone with 2 people")
    }

    // MARK: Longest dictation

    private let day = Date(timeIntervalSince1970: 1_790_000_000)

    func testTheFirstDictationWithWordsSetsTheRecord() {
        XCTAssertEqual(DictationStats.longest(nil, after: 537, words: 1_381, at: day),
                       LongestDictation(seconds: 537, words: 1_381, date: day))
    }

    func testOnlyAStrictlyLongerDictationTakesTheRecord() {
        let record = LongestDictation(seconds: 537, words: 1_381, date: day)
        let later = day.addingTimeInterval(3_600)
        XCTAssertEqual(DictationStats.longest(record, after: 538, words: 20, at: later),
                       LongestDictation(seconds: 538, words: 20, date: later))
        XCTAssertEqual(DictationStats.longest(record, after: 537, words: 2_000, at: later), record, "a tie keeps the first")
        XCTAssertEqual(DictationStats.longest(record, after: 12, words: 30, at: later), record)
    }

    func testADictationWithNoWordsOrNoRealLengthNeverCounts() {
        let record = LongestDictation(seconds: 60, words: 100, date: day)
        for current in [nil, record] {
            XCTAssertEqual(DictationStats.longest(current, after: 900, words: 0, at: day), current)
            XCTAssertEqual(DictationStats.longest(current, after: 900, words: -1, at: day), current)
            XCTAssertEqual(DictationStats.longest(current, after: .nan, words: 10, at: day), current)
            XCTAssertEqual(DictationStats.longest(current, after: .infinity, words: 10, at: day), current)
            XCTAssertEqual(DictationStats.longest(current, after: -900, words: 10, at: day), current)
            XCTAssertEqual(DictationStats.longest(current, after: 0, words: 10, at: day), current)
        }
    }

    func testHistoryBackfillFindsTheLongestFinishedDictation() {
        func record(_ seconds: Double, _ text: String, _ status: TranscriptStatus, minutesAgo: Double) -> TranscriptRecord {
            let created = day.addingTimeInterval(-minutesAgo * 60)
            return TranscriptRecord(id: UUID(), text: text, createdAt: created, updatedAt: created, audioSeconds: seconds,
                                    engine: "test", source: .keyboard, status: status)
        }
        let records = [
            record(4_000, "still going", .recording, minutesAgo: 1),
            record(3_000, "held by a call", .paused, minutesAgo: 2),
            record(2_000, "   ", .finished, minutesAgo: 3),          // no words
            record(.nan, "broken length", .finished, minutesAgo: 4),
            record(300, "one two three", .inserted, minutesAgo: 5),
            record(537, "the long one here", .cutOff, minutesAgo: 6),
            record(537, "a tie that came first", .note, minutesAgo: 7),
            record(-5, "negative", .finished, minutesAgo: 8),
        ]
        let tieFirst = LongestDictation(seconds: 537, words: 5, date: day.addingTimeInterval(-7 * 60))
        XCTAssertEqual(DictationStats.longest(in: records), tieFirst, "a tie goes to the earlier dictation")
        XCTAssertEqual(DictationStats.longest(in: records.reversed()), tieFirst, "in any order")
        XCTAssertNil(DictationStats.longest(in: []))
        XCTAssertNil(DictationStats.longest(in: Array(records.prefix(4))))
    }

    func testDurationLabel() {
        XCTAssertEqual(DictationStats.durationLabel(seconds: 0), "0:00")
        XCTAssertEqual(DictationStats.durationLabel(seconds: 4.9), "0:04", "rounded down")
        XCTAssertEqual(DictationStats.durationLabel(seconds: 60), "1:00")
        XCTAssertEqual(DictationStats.durationLabel(seconds: 537.99), "8:57")
        XCTAssertEqual(DictationStats.durationLabel(seconds: 3_599), "59:59")
        XCTAssertEqual(DictationStats.durationLabel(seconds: 3_599.999), "59:59")
        XCTAssertEqual(DictationStats.durationLabel(seconds: 3_600), "1:00:00")
        XCTAssertEqual(DictationStats.durationLabel(seconds: 3_727), "1:02:07")
        XCTAssertEqual(DictationStats.durationLabel(seconds: 36_000 + 61), "10:01:01")
        XCTAssertEqual(DictationStats.durationLabel(seconds: -3), "0:00")
        XCTAssertEqual(DictationStats.durationLabel(seconds: .nan), "0:00")
        XCTAssertEqual(DictationStats.durationLabel(seconds: -.infinity), "0:00")
        XCTAssertFalse(DictationStats.durationLabel(seconds: 1e300).isEmpty, "a corrupt value does not trap")
    }

    func testWaveIsStableForTheSameInputs() {
        XCTAssertEqual(ShareWave.bars(count: 48, words: 8_499, variation: 7),
                       ShareWave.bars(count: 48, words: 8_499, variation: 7))
    }

    func testWaveVariesASiblingWithoutLosingItsShape() {
        let first = ShareWave.bars(count: 48, words: 8_499, variation: 1)
        let second = ShareWave.bars(count: 48, words: 8_499, variation: 2)
        XCTAssertNotEqual(first, second)
        // Same voice: the two renders still move together.
        XCTAssertGreaterThan(correlation(first, second), 0.6)
        // A different total is a different voice.
        XCTAssertNotEqual(first, ShareWave.bars(count: 48, words: 120, variation: 1))
    }

    func testWaveStaysInRange() {
        for words in [0, 1, 37, 8_499, Int.max] {
            let bars = ShareWave.bars(count: 56, words: words, variation: UInt64(words & 0xFFFF))
            XCTAssertEqual(bars.count, 56)
            XCTAssertTrue(bars.allSatisfy { (0.08...1).contains($0) })
        }
        XCTAssertEqual(ShareWave.bars(count: 0, words: 5, variation: 0), [])
        XCTAssertEqual(ShareWave.bars(count: 1, words: 5, variation: 0).count, 1)
    }

    private func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let meanA = a.reduce(0, +) / Double(a.count), meanB = b.reduce(0, +) / Double(b.count)
        var cov = 0.0, varA = 0.0, varB = 0.0
        for (x, y) in zip(a, b) {
            cov += (x - meanA) * (y - meanB)
            varA += (x - meanA) * (x - meanA)
            varB += (y - meanB) * (y - meanB)
        }
        return cov / sqrt(varA * varB)
    }
}
