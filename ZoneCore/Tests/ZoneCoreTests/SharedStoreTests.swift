// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class SharedStoreTests: XCTestCase {
    private var suite: String!
    private var store: UserDefaultsSharedStore!

    override func setUp() {
        super.setUp()
        suite = "test.zone.\(UUID().uuidString)"
        store = UserDefaultsSharedStore(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testEveryFieldRoundTripsThroughDefaults() {
        let id = UUID()
        let request = DictationRequest(id: id, generation: 1, createdAt: Date(timeIntervalSince1970: 10), inputSession: "S", contextBefore: "ctx")
        let status = DictationStatus(requestID: id, generation: 1, phase: .transcribing, updatedAt: Date(timeIntervalSince1970: 11), message: "m")
        let result = DictationResult(requestID: id, generation: 1, text: "words", audioSeconds: 1, createdAt: Date(timeIntervalSince1970: 12), inputSession: "S")
        let control = DictationControl(requestID: id, generation: 1, action: .stop, issuedAt: Date(timeIntervalSince1970: 13))
        let session = SessionState(isArmed: true, armedUntil: Date(timeIntervalSince1970: 400), modelReady: true, heartbeat: Date(timeIntervalSince1970: 14))
        var ledger = InsertionLedger()
        ledger.claimedResultID = id
        ledger.droppedGeneration = 4

        store.request = request
        store.status = status
        store.result = result
        store.control = control
        store.session = session
        store.ledger = ledger
        let presence = KeyboardPresence(lastSeen: Date(timeIntervalSince1970: 15), hasFullAccess: true)
        store.keyboardPresence = presence
        store.level = 0.42

        // A second instance over the same suite must see the same values: that is the
        // keyboard process reading what the app wrote.
        let reader = UserDefaultsSharedStore(suiteName: suite)
        XCTAssertEqual(reader.request, request)
        XCTAssertEqual(reader.status, status)
        XCTAssertEqual(reader.result, result)
        XCTAssertEqual(reader.control, control)
        XCTAssertEqual(reader.session, session)
        XCTAssertEqual(reader.ledger, ledger)
        XCTAssertEqual(reader.keyboardPresence, presence)
        XCTAssertEqual(reader.level, 0.42, accuracy: 0.001)
    }

    func testKeyboardCueChoiceAndSwitchSurviveASecondReader() throws {
        store.keyboardPreferences = KeyboardPreferences(soundsEnabled: false, soundSet: "kalimba")
        let other = UserDefaultsSharedStore(suiteName: suite).keyboardPreferences
        XCTAssertFalse(other.soundsEnabled)
        XCTAssertEqual(other.soundSet, "kalimba")
        let old = try JSONDecoder().decode(KeyboardPreferences.self, from: Data("{}".utf8))
        XCTAssertTrue(old.soundsEnabled)
        XCTAssertEqual(old.soundSet, "wood")
    }

    func testMissingValuesReadAsNilAndEmptyLedger() {
        XCTAssertNil(store.request)
        XCTAssertNil(store.status)
        XCTAssertNil(store.result)
        XCTAssertNil(store.control)
        XCTAssertNil(store.session)
        XCTAssertEqual(store.ledger, InsertionLedger())
        XCTAssertNil(store.keyboardPresence)
    }

    func testSettingNilClears() {
        store.result = DictationResult(requestID: UUID(), generation: 1, text: "x", audioSeconds: 0, createdAt: Date(), inputSession: nil)
        store.result = nil
        XCTAssertNil(UserDefaultsSharedStore(suiteName: suite).result)
    }

    func testInMemoryStoreBehavesTheSame() {
        let memory = InMemorySharedStore()
        XCTAssertEqual(memory.ledger, InsertionLedger())
        memory.ledger.droppedGeneration = 2
        XCTAssertEqual(memory.ledger.droppedGeneration, 2)
        let status = DictationStatus(requestID: UUID(), generation: 2, phase: .ready, updatedAt: Date(), message: nil)
        memory.status = status
        XCTAssertEqual(memory.status, status)
    }
}

final class KeyboardPreferencesStoreTests: XCTestCase {
    func testHomeButtonDefaultsVisibleAndOptOutPersistsWithoutResettingOtherPreferences() throws {
        XCTAssertFalse(KeyboardPreferences().hideHomeButton)
        for record in [#"{"autocorrectEnabled":false}"#, #"{"autocorrectEnabled":false,"hideHomeButton":"yes"}"#] {
            let decoded = try JSONDecoder().decode(KeyboardPreferences.self, from: Data(record.utf8))
            XCTAssertFalse(decoded.hideHomeButton)
            XCTAssertFalse(decoded.autocorrectEnabled)
        }
        let suite = "zone.tests.home.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = UserDefaultsSharedStore(suiteName: suite)
        store.keyboardPreferences = KeyboardPreferences(showSuggestions: true, hideHomeButton: true)
        let reloaded = UserDefaultsSharedStore(suiteName: suite).keyboardPreferences
        XCTAssertTrue(reloaded.hideHomeButton)
        XCTAssertTrue(reloaded.showSuggestions)
        store.keyboardPreferences.hideHomeButton = false
        XCTAssertFalse(UserDefaultsSharedStore(suiteName: suite).keyboardPreferences.hideHomeButton)
    }

    /// Suggestions are on unless the person turned them off (the default changed on November 18,
    /// with the next-word row): a record that never said keeps its other choices and shows the
    /// row, and an explicit off survives.
    func testLegacyPreferencesPreserveCorrectionChoiceAndShowSuggestions() throws {
        let legacy = Data(#"{"autocorrectEnabled":true,"hapticsEnabled":false}"#.utf8)
        let decoded = try JSONDecoder().decode(KeyboardPreferences.self, from: legacy)
        XCTAssertTrue(decoded.autocorrectEnabled)
        XCTAssertFalse(decoded.hapticsEnabled)
        XCTAssertTrue(decoded.showSuggestions)
        for choice in [true, false] {
            let explicit = KeyboardPreferences(autocorrectEnabled: true, hapticsEnabled: false, showSuggestions: choice)
            let decoded = try JSONDecoder().decode(KeyboardPreferences.self, from: JSONEncoder().encode(explicit))
            XCTAssertEqual(decoded, explicit)
            XCTAssertEqual(decoded.showSuggestions, choice)
        }
    }

    func testDictationFollowsShiftDefaultsOnForOldRecordsAndOptOutRoundTrips() throws {
        let legacy = Data(#"{"autocorrectEnabled":true,"hapticsEnabled":true,"showsPasteKey":true}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(KeyboardPreferences.self, from: legacy).dictationFollowsShift)
        let off = KeyboardPreferences(dictationFollowsShift: false)
        XCTAssertFalse(try JSONDecoder().decode(KeyboardPreferences.self, from: JSONEncoder().encode(off)).dictationFollowsShift)
        // A wrong type falls back alone, not the whole record.
        let wrong = Data(#"{"autocorrectEnabled":false,"dictationFollowsShift":"yes"}"#.utf8)
        let decoded = try JSONDecoder().decode(KeyboardPreferences.self, from: wrong)
        XCTAssertFalse(decoded.autocorrectEnabled)
        XCTAssertTrue(decoded.dictationFollowsShift)
    }

    func testQuietAutocorrectDefaultsOnAndExplicitOptOutRoundTrips() {
        let suite = "zone.tests.prefs.\(UUID().uuidString)"
        let store = UserDefaultsSharedStore(suiteName: suite)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        XCTAssertEqual(store.keyboardPreferences, KeyboardPreferences())
        XCTAssertTrue(store.keyboardPreferences.autocorrectEnabled)
        XCTAssertTrue(store.keyboardPreferences.showSuggestions)
        store.keyboardPreferences = KeyboardPreferences(autocorrectEnabled: false, hapticsEnabled: true)
        XCTAssertFalse(store.keyboardPreferences.autocorrectEnabled)
        XCTAssertFalse(UserDefaultsSharedStore(suiteName: suite).keyboardPreferences.autocorrectEnabled)
        XCTAssertTrue(store.keyboardPreferences.hapticsEnabled)
        let memory = InMemorySharedStore()
        XCTAssertEqual(memory.keyboardPreferences, KeyboardPreferences())
    }
}

final class KeyboardModeTests: XCTestCase {
    func testModeDefaultsToTypeAndRoundTrips() {
        let suite = "test.zone.mode.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = UserDefaultsSharedStore(suiteName: suite)
        XCTAssertEqual(store.keyboardMode, .type)
        store.keyboardMode = .dictate
        XCTAssertEqual(UserDefaultsSharedStore(suiteName: suite).keyboardMode, .dictate)
        XCTAssertEqual(KeyboardMode.dictate.toggled, .type)
        XCTAssertEqual(KeyboardMode.type.toggled, .dictate)
    }

    func testUnknownStoredValueReadsAsType() {
        let suite = "test.zone.mode.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        UserDefaults(suiteName: suite)?.set("sideways", forKey: "zone.keyboardMode")
        XCTAssertEqual(UserDefaultsSharedStore(suiteName: suite).keyboardMode, .type)
    }
}

final class DictationControlStoreTests: XCTestCase {
    private var suite: String!
    private var store: UserDefaultsSharedStore!

    override func setUp() {
        super.setUp()
        suite = "test.zone.control.\(UUID().uuidString)"
        store = UserDefaultsSharedStore(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// The store keeps dates to the whole second. A Pause and a Stop pressed within one second
    /// must still read back as two different controls, or the app drops the Stop.
    func testTwoControlsInOneSecondStayDistinctThroughTheStore() {
        let id = UUID()
        let second = Date(timeIntervalSince1970: 1_000)
        store.control = DictationControl(requestID: id, generation: 1, action: .pause, issuedAt: second.addingTimeInterval(0.2))
        let pause = store.control
        store.control = DictationControl(requestID: id, generation: 1, action: .pause, issuedAt: second.addingTimeInterval(0.8))
        let secondPause = store.control
        XCTAssertEqual(pause?.issuedAt, secondPause?.issuedAt, "the store truncates to the second")
        XCTAssertNotEqual(pause, secondPause, "but each press keeps its own identity")
        XCTAssertEqual(UserDefaultsSharedStore(suiteName: suite).control, secondPause)
    }

    func testAControlWrittenByAnOlderBuildStillDecodes() throws {
        let id = UUID()
        let json = #"{"requestID":"\#(id.uuidString)","generation":2,"action":"stop","issuedAt":"2026-11-03T07:55:38Z"}"#
        UserDefaults(suiteName: suite)?.set(Data(json.utf8), forKey: "zone.control")
        let control = try XCTUnwrap(UserDefaultsSharedStore(suiteName: suite).control)
        XCTAssertEqual(control.requestID, id)
        XCTAssertEqual(control.action, ControlAction.stop)
        XCTAssertEqual(control.id, UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
    }
}
