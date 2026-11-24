// by zayd/cold @ zayd.wtf

import UIKit
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

    func testLockScreenHintUsesTheStartOfThisRecording() {
        var state = RecordingActivityAttributes.ContentState(phase: .recording, noteMode: true, startedAt: Date())
        XCTAssertEqual(state.recordingHint, "Tap Stop to finish")
        state.controlOwned = true
        state.startedByPress = false
        XCTAssertEqual(state.recordingHint, "Tap Stop to finish")
        state.startedByPress = true
        XCTAssertEqual(state.recordingHint, "Press again to stop")
        state.startedByPress = false
        state.controlOwned = false
        state.controls = false
        XCTAssertEqual(state.recordingHint, "Recording on this iPhone")
    }

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
            session.add(words: words, seconds: seconds, kept: words)
            let home = DictationStats.minutesSaved(words: words, secondsSpoken: Double(session.seconds))
            XCTAssertEqual(session.minutesSaved ?? 0, home, "\(words) words in \(seconds) s")
        }
        XCTAssertEqual(IslandSession.typingWordsPerMinute, DictationStats.typingWordsPerMinute)
    }

    func testSpeedIncludesPausesAndSavingsRequireDelivery() {
        var session = IslandSession(since: start)
        session.add(words: 12, seconds: 5)
        XCTAssertEqual(session.lockScreenLine, "1 dictation · 12 words")
        session.add(words: 300, seconds: 125)
        XCTAssertEqual(session.wordsPerMinute, DictationStats.wordsPerMinute(words: 312, recordingSeconds: 130))
        XCTAssertEqual(session.lockScreenLine, "312 words · 144 wpm")
        session.keptWords = 300
        XCTAssertEqual(session.lockScreenLine, "312 words · 144 wpm · 6 min saved")
        XCTAssertNil(IslandSession(since: start + 180).lockScreenLine)
    }

    @MainActor
    func testLockScreenStatsFitTheSmallPhoneAtDefaultCaptionSize() throws {
        var session = IslandSession(since: start)
        session.add(words: 312, seconds: 130, kept: 300)
        let line = try XCTUnwrap(session.lockScreenLine) as NSString
        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        let caption = UIFont.preferredFont(forTextStyle: .caption2, compatibleWith: traits)
        // Allow 32 points around the card, its two 14-point insets, the widest
        // 24-point figure (2.3x wide), three 10-point gaps and an 80-point end time.
        let available: CGFloat = 375 - 32 - 28 - 56 - 30 - 80
        XCTAssertLessThanOrEqual(ceil(line.size(withAttributes: [.font: caption]).width * 0.8), available)
    }

    func testFailedNoteCountsTowardPaceButOnlyMeasuredSecondsAffectSavings() {
        let session = IslandSession(since: start, dictations: 2, words: 140, seconds: 180,
                                    recordedSeconds: 180, measuredSeconds: 30, keptWords: 100)
        XCTAssertEqual(session.wordsPerMinute, DictationStats.wordsPerMinute(words: 140, recordingSeconds: 180))
        XCTAssertEqual(session.minutesSaved, DictationStats.minutesSaved(words: 100, secondsSpoken: 30))
    }

    func testOldIslandPayloadDoesNotAssumeDelivery() throws {
        var session = IslandSession(since: start)
        session.words = 500
        session.seconds = 200
        session.dictations = 2
        let decoded = try JSONDecoder().decode(IslandSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded.wordsPerMinute, 150)
        XCTAssertNil(decoded.minutesSaved)
    }

    /// The payload stays small: every update carries the session.
    func testTheSessionAddsLittleToEachUpdate() throws {
        var session = IslandSession(since: start)
        for _ in 0..<500 { session.add(words: 999, seconds: 300, kept: 900) }
        let bytes = try JSONEncoder().encode(session).count
        // 144 bytes with the speed fields filled; ActivityKit allows 4 KB per update.
        XCTAssertLessThan(bytes, 160)
    }

    /// Times (Settings > Dynamic Island) rides on every update. An older payload has no field
    /// and reads as clock times; Live survives the round trip ActivityKit makes.
    func testTimesDecodeFromOlderPayloadsAndSurviveTheTrip() throws {
        var state = RecordingActivityAttributes.ContentState(phase: .ready, noteMode: false, startedAt: Date(timeIntervalSince1970: 0))
        let older = try JSONEncoder().encode(state)
        XCTAssertNil(try JSONDecoder().decode(RecordingActivityAttributes.ContentState.self, from: older).times)
        state.times = .live
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(RecordingActivityAttributes.ContentState.self, from: data).times, .live)
        XCTAssertEqual(IslandTimes.allCases.map(\.title), ["Clock", "Live"])
    }
}
