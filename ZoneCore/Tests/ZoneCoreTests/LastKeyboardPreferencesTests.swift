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
