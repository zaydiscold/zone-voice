// by zayd/cold @ zayd.wtf

import XCTest
import ZoneCore
@testable import Zone

/// The numbers the island says about a standby session, and how it says them.
final class IslandSessionTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    // Apple's time format puts a narrow no-break space (U+202F) before AM, so "8:31 AM" never
    // wraps between the two.
    private let us = Locale(identifier: "en_US")
    /// 08:31 UTC.
    private let start = Date(timeIntervalSince1970: 8 * 3600 + 31 * 60)

    func testNothingToTellBeforeTheFirstDictation() {
        let session = IslandSession(since: start)
        XCTAssertNil(session.tally)
        XCTAssertNil(session.lockScreenLine)
        XCTAssertEqual(session.islandLine(locale: us, timeZone: utc), "On since 8:31\u{202F}AM. Audio is not saved.")
    }

    func testCountsReadAsPlainEnglish() {
        var session = IslandSession(since: start)
        session.add(words: 1, seconds: 1)
        XCTAssertEqual(session.tally, "1 dictation · 1 word")
        session.add(words: 311, seconds: 120)
        session.add(words: 0, seconds: 30) // heard nothing: not a dictation
        XCTAssertEqual(session.dictations, 2)
        XCTAssertEqual(session.islandLine(locale: us, timeZone: utc), "2 dictations · 312 words since 8:31\u{202F}AM")
    }

    func testTimeSavedMatchesHome() {
        for (words, seconds) in [(0, 0.0), (20, 40.0), (312, 121.0), (1_240, 400.0), (5_000, 2_000.0)] {
            var session = IslandSession(since: start)
            session.add(words: words, seconds: seconds)
            let home = DictationStats.minutesSaved(words: words, secondsSpoken: Double(session.seconds))
            XCTAssertEqual(session.minutesSaved ?? 0, home, "\(words) words in \(seconds) s")
        }
        XCTAssertEqual(IslandSession.typingWordsPerMinute, DictationStats.typingWordsPerMinute)
    }

    func testSpeedMatchesHome() {
        var session = IslandSession(since: start)
        session.add(words: 40, seconds: 22, speakingSeconds: 18.4)
        session.add(words: 210, seconds: 110, speakingSeconds: 101.6)
        XCTAssertEqual(session.wordsPerMinute, DictationStats.wordsPerMinute(words: 250, speakingSeconds: 120))
        XCTAssertEqual(session.wordsPerMinute, 125)
    }

    func testLastDictationSpeedNeedsEnoughToMeasure() {
        var session = IslandSession(since: start)
        session.add(words: 42, seconds: 24, speakingSeconds: 19.7)
        XCTAssertEqual(session.lastWordsPerMinute, 128)
        XCTAssertEqual(session.keptLine(words: 42), "Kept 42 words · 128 wpm.")
        session.add(words: 2, seconds: 3, speakingSeconds: 0.9) // "ok thanks": too short to time
        XCTAssertNil(session.lastWordsPerMinute)
        XCTAssertEqual(session.keptLine(words: 2), "Kept 2 words.")
        session.add(words: 30, seconds: 14) // no speaking time measured
        XCTAssertNil(session.lastWordsPerMinute)
    }

    func testLockScreenLineLeadsWithSpeedOnceThereIsOne() {
        var session = IslandSession(since: start)
        session.add(words: 12, seconds: 20, speakingSeconds: 5) // 5 s of speech: no speed yet
        XCTAssertEqual(session.lockScreenLine, "1 dictation · 12 words")
        session.add(words: 300, seconds: 110, speakingSeconds: 140)
        XCTAssertEqual(session.lockScreenLine, "312 words · 129 wpm · 6 min saved")
    }

    func testLockScreenLineAddsTimeSavedOnlyOnceThereIsSome() {
        var session = IslandSession(since: start)
        session.add(words: 12, seconds: 20) // typing 12 words takes about 19 s: nothing saved
        XCTAssertEqual(session.lockScreenLine, "1 dictation · 12 words")
        session.add(words: 300, seconds: 110)
        XCTAssertEqual(session.lockScreenLine, "2 dictations · 312 words · 6 min saved")
    }

    /// The payload stays small: every update carries the session.
    func testTheSessionAddsLittleToEachUpdate() throws {
        var session = IslandSession(since: start)
        for _ in 0..<500 { session.add(words: 999, seconds: 300, speakingSeconds: 250) }
        let bytes = try JSONEncoder().encode(session).count
        // 144 bytes with the speed fields filled; ActivityKit allows 4 KB per update.
        XCTAssertLessThan(bytes, 160)
    }
}
