// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// The keyboard's fallback when the App Group gives no record back (2026-11-08: friends saw swipe,
/// Paste and suggestions off after a relaunch while the app showed them on).
final class LastKeyboardPreferencesTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "test.zone.lastPreferences.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private var turnedOn: KeyboardPreferences {
        KeyboardPreferences(showSuggestions: true, showsPasteKey: true, swipeTypingEnabled: true)
    }

    func testAMissingRecordKeepsWhatTheAppLastSaid() {
        let last = LastKeyboardPreferences(defaults: defaults)
        XCTAssertEqual(last.resolve(stored: turnedOn), turnedOn)
        let afterRelaunch = LastKeyboardPreferences(defaults: defaults).resolve(stored: nil)
        XCTAssertTrue(afterRelaunch.swipeTypingEnabled)
        XCTAssertTrue(afterRelaunch.showsPasteKey)
        XCTAssertTrue(afterRelaunch.showSuggestions)
    }

    func testKeyboardKeepsItsDisplayedValueWhenGroupAccessDrops() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inbox = QuickSettingInbox(directory: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let stale = KeyboardPreferences()
        let cache = LastKeyboardPreferences(defaults: defaults)
        let yesterday = Date().addingTimeInterval(-86400)
        try inbox.submit(.init(.sounds(false), at: yesterday))
        XCTAssertFalse(cache.resolve(stored: stale, inbox: inbox).soundsEnabled)
        XCTAssertFalse(cache.resolve(stored: stale).soundsEnabled)
        XCTAssertFalse(cache.resolve(stored: nil).soundsEnabled)
        var newer = stale
        newer.quickSettingStamps["sounds"] = .init()
        XCTAssertTrue(cache.resolve(stored: newer, inbox: inbox).soundsEnabled)
    }

    func testMigrationAndConcurrentWritersRetainTheirOwnIDs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("old.json")
        let directory = root.appendingPathComponent("requests")
        let inbox = QuickSettingInbox(directory: directory, legacyFile: legacy)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let old = QuickSettingRequest(.sounds(false))
        try JSONEncoder().encode([old]).write(to: legacy)
        let taps = (0..<16).map { QuickSettingRequest(.sounds($0.isMultiple(of: 2))) }
        DispatchQueue.concurrentPerform(iterations: taps.count) { i in
            do { try inbox.submit(taps[i]) } catch { XCTFail("Submitting tap: \(error)") }
        }
        let pending = try inbox.read()
        XCTAssertEqual(pending, ([old] + taps).sorted { $0.stamp < $1.stamp })
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        inbox.prune(pending)
        XCTAssertEqual(try inbox.read(), [])
    }

    func testFutureStampAndEqualClockTapsCompactPerKey() throws {
        let inbox = QuickSettingInbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent(suite))
        defer { try? FileManager.default.removeItem(at: inbox.directory) }
        let now = Date()
        var snapshot = KeyboardPreferences()
        let future = QuickSettingRequest.Stamp(at: now.addingTimeInterval(86400))
        snapshot.quickSettingStamps["sounds"] = future
        let first = try inbox.submit(.sounds(false), known: snapshot, at: now)
        let second = try inbox.submit(.sounds(true), known: snapshot, at: now)
        let hold = try inbox.submit(.hold(.talk), known: snapshot, at: now)
        XCTAssertGreaterThan(first.stamp.time, future.time)
        XCTAssertGreaterThan(second.stamp.time, first.stamp.time)
        XCTAssertEqual(Set(try inbox.read().map(\.stamp.id)), [second.stamp.id, hold.stamp.id])
        XCTAssertTrue(inbox.overlay(on: snapshot).soundsEnabled)
    }

    func testMalformedInboxAndLegacyRecordsLeaveTheHotPath() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appendingPathComponent("legacy")
        let bad = dir.appendingPathComponent(UUID().uuidString + ".json")
        for url in [old, bad] { try Data("broken".utf8).write(to: url) }
        let inbox = QuickSettingInbox(directory: dir, legacyFile: old)
        XCTAssertEqual(try inbox.read(), [])
        XCTAssertEqual(try inbox.read(), [])
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.allSatisfy { $0.hasSuffix(".invalid") })
    }

    @MainActor
    func testDefaultsStorePublishesValueOnlyEditAndReset() async throws {
        let store = UserDefaultsSharedStore(suiteName: suite, installID: nil, publishesSettings: true)
        var changed = KeyboardPreferences()
        changed.soundsEnabled = false
        for prefs in [changed, KeyboardPreferences()] {
            let published = expectation(description: "quick settings published")
            let notice = DarwinNotifier.observe(.quickSettingsPublished) {
                if store.confirmKeyboardPreferences(prefs) { published.fulfill() }
            }
            store.keyboardPreferences = prefs
            await fulfillment(of: [published], timeout: 2)
            notice.cancel()
        }
    }

    func testTheAppsRecordAlwaysWins() {
        let last = LastKeyboardPreferences(defaults: defaults)
        _ = last.resolve(stored: turnedOn)
        let turnedOff = KeyboardPreferences()
        XCTAssertEqual(last.resolve(stored: turnedOff), turnedOff)
        XCTAssertEqual(last.resolve(stored: nil), turnedOff, "the newer record replaces the remembered one")
    }

    func testAKeyboardThatNeverReadARecordUsesTheDefaults() {
        XCTAssertEqual(LastKeyboardPreferences(defaults: defaults).resolve(stored: nil), KeyboardPreferences())
    }

    func testTheStoreTellsAMissingRecordFromADefaultOne() {
        let storeSuite = "test.zone.store.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: storeSuite) }
        let store = UserDefaultsSharedStore(suiteName: storeSuite)
        XCTAssertNil(store.storedKeyboardPreferences)
        XCTAssertEqual(store.keyboardPreferences, KeyboardPreferences())
        store.keyboardPreferences = turnedOn
        XCTAssertEqual(store.storedKeyboardPreferences, turnedOn)
    }
}

/// The same fallback for the two other values the keyboard read once from the App Group.
final class KeyboardLocalStateTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "test.zone.keyboardLocal.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testAMissingAccentKeepsTheLastOneRead() {
        XCTAssertEqual(LastAccentChoice(defaults: defaults).resolve(stored: nil), .violet, "never read: the default")
        XCTAssertEqual(LastAccentChoice(defaults: defaults).resolve(stored: .ember), .ember)
        XCTAssertEqual(LastAccentChoice(defaults: defaults).resolve(stored: nil), .ember, "an empty read is not violet")
        XCTAssertEqual(LastAccentChoice(defaults: defaults).resolve(stored: .violet), .violet, "the app's choice wins")
        XCTAssertEqual(LastAccentChoice(defaults: defaults).resolve(stored: nil), .violet)
    }

    func testTheFaceSurvivesAnUnreadableAppGroup() {
        let store = InMemorySharedStore()
        LocalKeyboardMode(store: store, defaults: defaults).mode = .dictate
        XCTAssertEqual(store.keyboardMode, .dictate, "the App Group copy is still written")
        // A fresh process whose App Group read comes back empty (its default is .type).
        XCTAssertEqual(LocalKeyboardMode(store: InMemorySharedStore(), defaults: defaults).mode, .dictate)
    }

    func testAKeyboardWithNoLocalFaceTakesTheAppGroupOne() {
        let store = InMemorySharedStore()
        store.keyboardMode = .dictate
        XCTAssertEqual(LocalKeyboardMode(store: store, defaults: defaults).mode, .dictate)
    }
}
