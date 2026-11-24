// by zayd/cold @ zayd.wtf

import XCTest
import ZoneCore
@testable import Zone

@MainActor
final class QuickSettingTests: XCTestCase {
    private let suite = "quick-settings-\(UUID())"
    private let store = InMemorySharedStore()
    private var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
    private var inbox: QuickSettingInbox {
        QuickSettingInbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent(suite))
    }

    private func launch() -> AppSettings {
        store.quickSettingInbox = inbox
        return AppSettings(defaults: defaults, store: store, vocabulary: nil, systemLexicon: nil)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        if FileManager.default.fileExists(atPath: inbox.directory.path) {
            try FileManager.default.removeItem(at: inbox.directory)
        }
    }

    func testActivationAppliesRequestWhenDarwinPostIsNeverDelivered() throws {
        let settings = launch()
        let coordinator = DictationCoordinator(settings: settings, store: store, engine: TestSpeechEngine())
        defer { coordinator.setForeground(false) }
        try inbox.submit(.init(.sounds(false))) // Deliberately never post a Darwin notification.
        XCTAssertTrue(settings.soundsEnabled)
        XCTAssertFalse(inbox.overlay(on: store.keyboardPreferences).soundsEnabled)
        coordinator.scenePhaseChanged(.active)
        XCTAssertFalse(settings.soundsEnabled)
        settings.hideHomeButton = true
        XCTAssertFalse(store.keyboardPreferences.soundsEnabled)
        XCTAssertFalse(launch().soundsEnabled)
    }

    func testAppChangeAfterRequestWinsAndOtherKeysStillApply() throws {
        let settings = launch()
        try inbox.submit(.init(.sounds(false)))
        try inbox.submit(.init(.hold(.talk)))
        settings.soundsEnabled = true
        XCTAssertTrue(settings.soundsEnabled)
        XCTAssertEqual(settings.spaceHold, .talk)
        XCTAssertTrue(inbox.overlay(on: store.keyboardPreferences).soundsEnabled)
        XCTAssertTrue(launch().soundsEnabled)
    }

    func testTwoRequestsBetweenActivationsAreAppliedInOrderAndPruned() throws {
        let settings = launch()
        let coordinator = DictationCoordinator(settings: settings, store: store, engine: TestSpeechEngine())
        defer { coordinator.setForeground(false) }
        coordinator.scenePhaseChanged(.active)
        coordinator.scenePhaseChanged(.background)
        let first = QuickSettingRequest(.graphic(.bars), at: Date(timeIntervalSince1970: 100.1))
        let second = QuickSettingRequest(.graphic(.ink), at: Date(timeIntervalSince1970: 100.2))
        try inbox.submit(first)
        XCTAssertEqual(inbox.overlay(on: store.keyboardPreferences).meterStyle, .bars)
        try inbox.submit(second)
        try inbox.submit(first)
        XCTAssertEqual(inbox.overlay(on: store.keyboardPreferences).meterStyle, .ink)
        XCTAssertEqual(try inbox.read(), [first, second])
        XCTAssertEqual(settings.meterStyle, .wave)
        coordinator.scenePhaseChanged(.active)
        XCTAssertEqual(settings.quickSettingLedger.appliedIDs, [first.stamp.id, second.stamp.id])
        XCTAssertEqual(settings.meterStyle, .ink)
        XCTAssertEqual(try inbox.read(), [])
        // Crash after the private commit, before its new snapshot or file removals survive.
        store.keyboardPreferences = KeyboardPreferences()
        defaults.set(MeterStyle.wave.rawValue, forKey: "zone.settings.meterStyle")
        try inbox.submit(second)
        try inbox.submit(first)
        let relaunched = launch()
        XCTAssertEqual(relaunched.quickSettingLedger.appliedIDs, [first.stamp.id, second.stamp.id])
        XCTAssertEqual(relaunched.meterStyle, .ink)
        XCTAssertEqual(store.keyboardPreferences.meterStyle, .ink)
        XCTAssertEqual(try inbox.read(), [])
    }

    func testPruneKeepsRequestWrittenAfterDirectoryScan() throws {
        let settings = launch()
        let first = QuickSettingRequest(.sounds(false))
        try inbox.submit(first)
        let second = QuickSettingRequest(.sounds(true), after: first.stamp)
        let scanned = try inbox.read()
        try inbox.submit(second)
        settings.publishKeyboardPreferences(pending: scanned)
        XCTAssertFalse(settings.soundsEnabled)
        XCTAssertEqual(try inbox.read(), [second])
        settings.publishKeyboardPreferences()
        XCTAssertTrue(settings.soundsEnabled)
    }

    func testBackgroundKeyboardRequestDrainsBeforeRecording() async throws {
        let settings = launch()
        settings.startsSessionOnOpen = false
        let engine = TestSpeechEngine()
        let coordinator = DictationCoordinator(settings: settings, store: store, engine: engine, requestSessionPermission: { true })
        defer { coordinator.endSession(reason: .user) }
        await coordinator.prepareModelAndWait()
        try await coordinator.armSession()
        coordinator.setForeground(false)
        try inbox.submit(.init(.sounds(false)))
        try inbox.submit(.init(.quiet(enabled: true, wait: 5)))
        let request = DictationRequest(id: UUID(), generation: 1, createdAt: Date(), inputSession: "field", contextBefore: nil)
        store.request = request
        store.status = DictationStatus(requestID: request.id, generation: 1, phase: .requested, updatedAt: Date(), message: nil)
        DarwinNotifier.post(.requestChanged)
        for _ in 0..<100 where store.status?.phase != .recording {
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(store.status?.phase, .recording)
        XCTAssertEqual(engine.utterances, 1)
        XCTAssertFalse(settings.soundsEnabled)
        XCTAssertTrue(settings.finishWhenQuiet)
        XCTAssertEqual(settings.finishWhenQuietWait, 5)
        XCTAssertEqual(try inbox.read(), [])
    }

    func testFutureKeyboardStampCannotOverrideLaterAppEditOrReset() throws {
        let settings = launch()
        let future = QuickSettingRequest(.sounds(false), at: Date().addingTimeInterval(86400))
        try inbox.submit(future)
        settings.soundsEnabled = true
        let published = store.keyboardPreferences
        XCTAssertGreaterThan(try XCTUnwrap(published.quickSettingStamps["sounds"]).time, future.stamp.time)
        XCTAssertTrue(published.soundsEnabled)
        settings.soundsEnabled = false
        let cache = LastKeyboardPreferences(defaults: UserDefaults(suiteName: suite + "-keyboard")!)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite + "-keyboard") }
        let before = cache.resolve(stored: store.keyboardPreferences)
        defaults.removePersistentDomain(forName: suite)
        _ = launch()
        let reset = cache.resolve(stored: store.keyboardPreferences)
        XCTAssertTrue(reset.soundsEnabled)
        XCTAssertGreaterThan(try XCTUnwrap(reset.quickSettingGeneration), try XCTUnwrap(before.quickSettingGeneration))
        XCTAssertGreaterThan(try XCTUnwrap(reset.quickSettingStamps["sounds"]), try XCTUnwrap(before.quickSettingStamps["sounds"]))
        _ = cache.resolve(stored: before)
        defaults.removePersistentDomain(forName: suite)
        store.keyboardPreferences = KeyboardPreferences()
        _ = launch()
        XCTAssertTrue(cache.resolve(stored: store.keyboardPreferences).soundsEnabled)
    }

    func testLaunchArgumentWinsOverUnpublishedLedgerWinner() throws {
        let settings = launch()
        let request = QuickSettingRequest(.quiet(enabled: true, wait: 5))
        try inbox.submit(request)
        settings.publishKeyboardPreferences()
        store.keyboardPreferences = KeyboardPreferences()
        try inbox.submit(request)
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        defaults.setVolatileDomain(previous.merging(["zone.settings.finishWhenQuietWait": "30"]) { _, value in value },
                                   forName: UserDefaults.argumentDomain)
        XCTAssertEqual(launch().finishWhenQuietWait, 30)
    }

    func testColdLaunchAfterADayAndResetToDefaults() throws {
        let yesterday = Date().addingTimeInterval(-86400)
        for value: QuickSetting in [.quiet(enabled: true, wait: 30), .sounds(false), .hold(.talk), .graphic(.stars)] {
            try inbox.submit(.init(value, at: yesterday))
        }
        let settings = launch()
        XCTAssertTrue(settings.finishWhenQuiet)
        XCTAssertEqual(settings.finishWhenQuietWait, 30)
        XCTAssertFalse(settings.soundsEnabled)
        XCTAssertEqual(settings.spaceHold, .talk)
        XCTAssertEqual(settings.meterStyle, .stars)
        defaults.removePersistentDomain(forName: suite)
        let reset = launch()
        XCTAssertFalse(reset.finishWhenQuiet)
        XCTAssertEqual(reset.finishWhenQuietWait, SilenceFinish.defaultWait)
        XCTAssertTrue(reset.soundsEnabled)
        XCTAssertEqual(reset.spaceHold, .moveCursor)
        XCTAssertEqual(reset.meterStyle, .wave)
        XCTAssertEqual(inbox.overlay(on: store.keyboardPreferences), store.keyboardPreferences)
    }

    func testDarwinNoticeAppliesWhileAppIsRunning() async throws {
        let settings = launch()
        try inbox.submit(.init(.sounds(false)))
        DarwinNotifier.post(.quickSettingChanged)
        for _ in 0..<50 where settings.soundsEnabled {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(settings.soundsEnabled)
    }
}
