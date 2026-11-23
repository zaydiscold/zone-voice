// by zayd/cold @ zayd.wtf

import XCTest
import ZoneCore
@testable import Zone

/// Home's words per minute: speaking time once enough is measured, the old whole-recording
/// figure until then, and time saved always against the whole recording.
@MainActor
final class SpeakingStatsTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites.removeAll()
        super.tearDown()
    }

    private func settings() -> AppSettings {
        let suite = "speaking-stats-test-" + UUID().uuidString
        suites.append(suite)
        return AppSettings(defaults: UserDefaults(suiteName: suite)!, store: UserDefaultsSharedStore(suiteName: suite),
                           vocabulary: nil, systemLexicon: nil)
    }

    func testOlderDictationsKeepTheOldSpeedUntilAMinuteIsMeasured() {
        let settings = settings()
        settings.record(words: 1_000, seconds: 600) // before 1.0.5: no speaking time
        XCTAssertEqual(settings.wordsPerMinute, 100)
        // 1,100 words over 660 s of recording is still 100 a minute; switching would read 133.
        settings.record(words: 100, seconds: 60, speakingSeconds: 45)
        XCTAssertEqual(settings.wordsPerMinute, 100, "45 s of measured speech is not enough to switch")
        settings.record(words: 50, seconds: 25, speakingSeconds: 20)
        XCTAssertEqual(settings.wordsPerMinute, 138, "150 words over 65 s of speech")
    }

    func testTimeSavedStillCountsTheWholeRecording() {
        let settings = settings()
        settings.record(words: 362, seconds: 300, speakingSeconds: 150)
        XCTAssertEqual(DictationStats.minutesSaved(words: settings.wordsDictated, secondsSpoken: settings.secondsDictated), 5)
    }

    func testResetClearsSpeakingTimeToo() {
        let settings = settings()
        settings.record(words: 300, seconds: 160, speakingSeconds: 140)
        settings.resetStats()
        XCTAssertEqual(settings.wordsTimed, 0)
        XCTAssertEqual(settings.speakingSeconds, 0)
        XCTAssertEqual(settings.wordsPerMinute, 0)
    }
    // MARK: Longest dictation

    func testRecordKeepsTheLongestAndAResetClearsIt() {
        let settings = settings()
        XCTAssertNil(settings.longestDictation)
        let first = Date(timeIntervalSince1970: 1_790_000_000)
        settings.record(words: 1_381, seconds: 537, speakingSeconds: 420, at: first)
        settings.record(words: 30, seconds: 12, at: first.addingTimeInterval(60))
        XCTAssertEqual(settings.longestDictation, LongestDictation(seconds: 537, words: 1_381, date: first))
        settings.resetStats()
        XCTAssertNil(settings.longestDictation)
        XCTAssertFalse(settings.needsLongestBackfill, "a reset never lets the history backfill bring it back")
        settings.backfillLongest(historyLongest: LongestDictation(seconds: 900, words: 2_000, date: first))
        XCTAssertNil(settings.longestDictation)
    }

    func testBackfillRunsOnceAndKeepsTheLonger() {
        let settings = settings()
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertTrue(settings.needsLongestBackfill)
        settings.record(words: 200, seconds: 90, at: day) // recorded before the backfill finished
        settings.backfillLongest(historyLongest: LongestDictation(seconds: 60, words: 150, date: day.addingTimeInterval(-86_400)))
        XCTAssertEqual(settings.longestDictation?.seconds, 90, "the shorter history record does not replace it")
        XCTAssertFalse(settings.needsLongestBackfill)
        settings.backfillLongest(historyLongest: LongestDictation(seconds: 900, words: 2_000, date: day))
        XCTAssertEqual(settings.longestDictation?.seconds, 90, "the backfill runs once ever")
    }

    func testTheRecordSurvivesARelaunch() {
        let suite = "speaking-stats-test-" + UUID().uuidString
        suites.append(suite)
        func open() -> AppSettings {
            AppSettings(defaults: UserDefaults(suiteName: suite)!, store: UserDefaultsSharedStore(suiteName: suite),
                        vocabulary: nil, systemLexicon: nil)
        }
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        open().record(words: 1_381, seconds: 537.1, at: day)
        let reopened = open()
        XCTAssertEqual(reopened.longestDictation, LongestDictation(seconds: 537.1, words: 1_381, date: day))
    }
}
