// by zayd/cold @ zayd.wtf

import XCTest
import ZoneCore
@testable import Zone

@MainActor
final class SpeakingStatsTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites.removeAll()
        super.tearDown()
    }

    func testKeyboardReceiptRefreshesCoordinatorSettingsThroughStatsChanged() async throws {
        let suite = "speaking-stats-notification-" + UUID().uuidString
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = InMemorySharedStore()
        let settings = AppSettings(defaults: defaults, store: store, vocabulary: nil, systemLexicon: nil)
        let history = try XCTUnwrap(TranscriptHistory.shared)
        let before = try XCTUnwrap(history.stats(legacyWords: 0, legacySeconds: 0, since: nil)).0
        let coordinator = DictationCoordinator(settings: settings, store: store)
        let id = UUID()
        defer {
            history.cancel(id: id)
            withExtendedLifetime(coordinator) {}
        }
        let keyboard = TranscriptHistory(directory: history.directory, keepsDecodedFile: false)
        keyboard.finish(id: id, text: "from the keyboard", audioSeconds: 12, source: .keyboard, statsStartedAt: Date())
        let deadline = ContinuousClock.now + .seconds(5)
        while settings.wordsDictated != before.words + 3 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(settings.wordsDictated, before.words + 3)
        // The ledger can sum earlier durations in a different order after adding this receipt.
        XCTAssertEqual(settings.secondsDictated, before.seconds + 12, accuracy: 0.5 / 16_000)
    }

    func testTransferFromReceiptTestBuildIgnoresItsLiveCounters() throws {
        let suite = "speaking-stats-preview-" + UUID().uuidString
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(120, forKey: "zone.stats.words")
        defaults.set(30, forKey: "zone.stats.seconds")
        defaults.set(2, forKey: "zone.stats.minutesSaved")
        let settings = AppSettings(defaults: defaults, store: InMemorySharedStore(), vocabulary: nil, systemLexicon: nil)
        XCTAssertEqual(settings.wordsDictated, 120)
        XCTAssertEqual(settings.legacyWords, 0)
        XCTAssertEqual(settings.legacySeconds, 0)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = TranscriptHistory(directory: directory)
        func refresh() throws {
            let snapshot = try XCTUnwrap(destination.stats(legacyWords: settings.legacyWords, legacySeconds: settings.legacySeconds,
                                                           since: nil, transferred: settings.transferTotals))
            settings.applyStats(snapshot.0)
        }
        try refresh()
        XCTAssertEqual(settings.wordsDictated, 120)
        XCTAssertEqual(settings.secondsDictated, 30)
        XCTAssertEqual(settings.estimatedMinutesSaved, 2)
        let backup = TranscriptHistory(directory: directory.appendingPathComponent("old-phone"))
        let id = UUID()
        XCTAssertTrue(backup.finish(id: id, text: Array(repeating: "word", count: 120).joined(separator: " "),
                                    audioSeconds: 30, statsStartedAt: Date()))
        backup.confirmKept(id: id, words: 90)
        try destination.importBackupData(backup.backupData())
        try refresh()
        XCTAssertEqual(settings.wordsDictated, 120)
        XCTAssertEqual(settings.estimatedMinutesSaved, 2)
        XCTAssertEqual(settings.transferTotals?.legacySavedMinutes, 0)
    }

    func testHomeUsesFreshSnapshotsAndPreservesTotalsWhileLoading() throws {
        let suite = "speaking-stats-test-" + UUID().uuidString
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(100, forKey: "zone.stats.words")
        defaults.set(50.0, forKey: "zone.stats.seconds")
        let settings = AppSettings(defaults: defaults, store: UserDefaultsSharedStore(suiteName: suite), vocabulary: nil, systemLexicon: nil)
        XCTAssertEqual(settings.wordsDictated, 100)
        XCTAssertEqual(settings.wordsPerMinute, 120)
        XCTAssertEqual(settings.estimatedMinutesSaved, 0)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = TranscriptHistory(directory: directory), id = UUID()
        func reload() throws {
            let snapshot = try XCTUnwrap(history.stats(legacyWords: settings.legacyWords, legacySeconds: settings.legacySeconds, since: nil))
            settings.applyStats(snapshot.0)
        }
        try reload()
        history.finish(id: id, text: Array(repeating: "word", count: 100).joined(separator: " "), audioSeconds: 30, statsStartedAt: Date())
        try reload()
        XCTAssertEqual(settings.wordsPerMinute, 150)
        XCTAssertEqual(settings.estimatedMinutesSaved, 0)
        history.confirmKept(id: id, words: 100)
        try reload()
        XCTAssertEqual(settings.estimatedMinutesSaved, 2)
        XCTAssertEqual(settings.longestDictation?.words, 100)
        let newSuite = suite + "-transferred"
        suites.append(newSuite)
        let copied = try XCTUnwrap(UserDefaults(suiteName: newSuite))
        copied.setPersistentDomain(try XCTUnwrap(defaults.persistentDomain(forName: suite)), forName: newSuite)
        let reopened = AppSettings(defaults: copied, store: UserDefaultsSharedStore(suiteName: newSuite), vocabulary: nil, systemLexicon: nil)
        XCTAssertEqual(reopened.longestDictation, settings.longestDictation)
        XCTAssertEqual(reopened.estimatedMinutesSaved, 2)
        XCTAssertEqual(reopened.wordsDictated, 200)
        XCTAssertEqual(reopened.secondsDictated, 80)
        XCTAssertEqual(defaults.integer(forKey: "zone.stats.words"), 100)
        XCTAssertEqual(defaults.double(forKey: "zone.stats.seconds"), 50)
        // Quick Start copied defaults. The new phone launches before importing its archive.
        let destination = TranscriptHistory(directory: directory.appendingPathComponent("new-phone"))
        func refreshDestination() throws {
            let snapshot = try XCTUnwrap(destination.stats(legacyWords: reopened.legacyWords,
                                                           legacySeconds: reopened.legacySeconds, since: nil,
                                                           transferred: reopened.transferTotals))
            reopened.applyStats(snapshot.0)
        }
        try refreshDestination()
        XCTAssertEqual(reopened.wordsDictated, 200)
        XCTAssertEqual(reopened.secondsDictated, 80)
        XCTAssertEqual(reopened.estimatedMinutesSaved, 2)
        XCTAssertEqual(reopened.longestDictation, settings.longestDictation)
        let backup = try history.backupData()
        for _ in 0..<2 {
            _ = try destination.importBackupData(backup)
            try refreshDestination()
            XCTAssertEqual(reopened.wordsDictated, 200)
            XCTAssertEqual(reopened.secondsDictated, 80)
            XCTAssertEqual(reopened.estimatedMinutesSaved, 2)
            XCTAssertEqual(reopened.transferTotals, settings.transferTotals)
        }
        XCTAssertTrue(history.delete(id: id))
        try reload()
        XCTAssertEqual(settings.longestDictation?.words, 100)
        XCTAssertEqual(settings.wordsDictated, 200)
        XCTAssertTrue(history.resetStats())
        settings.didResetStats()
        try reload()
        XCTAssertEqual(settings.wordsDictated, 0)
        let resetTransfer = TranscriptHistory(directory: directory.appendingPathComponent("after-reset"))
        XCTAssertEqual(resetTransfer.stats(legacyWords: settings.legacyWords, legacySeconds: settings.legacySeconds,
                                           since: nil, transferred: settings.transferTotals)?.0, DictationTotals())
        XCTAssertEqual(settings.wordsPerMinute, 0)
        XCTAssertEqual(settings.estimatedMinutesSaved, 0)
    }
}
