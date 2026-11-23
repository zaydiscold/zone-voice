// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// One style, and the last choice wins (`TextStylePolicy`). A keyboard pick used to lapse after 15
/// minutes; on 2026-11-19 that made a casual pick in Teams come out formal. The tests that asserted
/// the lapse were changed with the behavior.
final class TextStylePolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testNoPickUsesTheSetting() {
        XCTAssertEqual(TextStylePolicy.effective(defaultStyle: .formal, override: nil, chosenAt: nil), .formal)
        // A style without a pick time is not a live pick.
        XCTAssertEqual(TextStylePolicy.effective(defaultStyle: .formal, override: .excited, chosenAt: nil), .formal)
    }

    func testAKeyboardPickStaysWithoutDictating() {
        // The Teams message: casual picked on the Z, the next dictation more than 15 minutes later.
        let store = InMemorySharedStore()
        store.chooseDefaultTextStyle(.formal)
        store.chooseTextStyle(.casual, now: t0)
        XCTAssertEqual(store.effectiveTextStyle(), .casual)
        XCTAssertEqual(TextStylePolicy.effective(defaultStyle: .formal, override: .casual, chosenAt: t0 - 30 * 86_400), .casual)
    }

    func testTheZCyclesFromTheStyleInEffect() {
        let store = InMemorySharedStore()
        store.chooseDefaultTextStyle(.formal)
        XCTAssertEqual(store.chooseNextTextStyle(now: t0), TextStyle.formal.next)
        XCTAssertEqual(store.effectiveTextStyle(), TextStyle.formal.next)
        XCTAssertEqual(store.chooseNextTextStyle(now: t0 + 60), TextStyle.formal.next.next)
    }

    func testSettingsReplacesAKeyboardPick() {
        let store = InMemorySharedStore()
        store.chooseDefaultTextStyle(.casual)
        store.chooseTextStyle(.excited, now: t0)
        store.chooseDefaultTextStyle(.formal)
        XCTAssertEqual(store.effectiveTextStyle(), .formal)
        XCTAssertNil(store.pendingKeyboardTextStyle)
        // Picking the same style in Settings as the setting already holds still wins over the Z.
        store.chooseTextStyle(.excited, now: t0 + 60)
        store.chooseDefaultTextStyle(.formal)
        XCTAssertEqual(store.effectiveTextStyle(), .formal)
    }

    func testTheAppFoldsAKeyboardPickIntoItsSetting() {
        let store = InMemorySharedStore()
        store.chooseDefaultTextStyle(.formal)
        store.chooseTextStyle(.veryCasual, now: t0)
        XCTAssertEqual(store.pendingKeyboardTextStyle, .veryCasual)
        // What AppSettings.adoptKeyboardStyle does when the app comes to the front.
        if let picked = store.pendingKeyboardTextStyle { store.chooseDefaultTextStyle(picked) }
        XCTAssertEqual(store.defaultTextStyle, .veryCasual)
        XCTAssertNil(store.pendingKeyboardTextStyle)
        XCTAssertEqual(store.effectiveTextStyle(), .veryCasual)
    }

    func testUserDefaultsStoreRoundTripsTheKeys() {
        let suite = "zone.tests.style.\(UUID().uuidString)"
        let store = UserDefaultsSharedStore(suiteName: suite)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        XCTAssertEqual(store.defaultTextStyle, .casual)
        XCTAssertNil(store.textStylePickedAt)
        store.defaultTextStyle = .excited
        store.textStylePickedAt = t0
        XCTAssertEqual(store.defaultTextStyle, .excited)
        XCTAssertEqual(store.textStylePickedAt, t0)
    }

    func testAPickSavedBeforePicksLastedDoesNotComeBack() {
        // Under the old rule this pick had lapsed for the user; reading it now would change their style.
        let suite = "zone.tests.style.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(TextStyle.formal.rawValue, forKey: "zone.defaultTextStyle")
        defaults.set(TextStyle.excited.rawValue, forKey: "zone.textStyle")
        defaults.set(t0, forKey: "zone.textStyleActiveAt")
        let store = UserDefaultsSharedStore(suiteName: suite)
        XCTAssertEqual(store.effectiveTextStyle(), .formal)
    }
}

final class SampleGateTests: XCTestCase {
    func testZeroesExactlyTheLeadingSamplesAcrossBuffers() {
        let gate = SampleGate(mutedSamples: 5)
        XCTAssertEqual(gate.pass([1, 1, 1]), [0, 0, 0])
        XCTAssertEqual(gate.pass([1, 1, 1]), [0, 0, 1])
        XCTAssertEqual(gate.pass([1, 1]), [1, 1])
    }

    func testZeroMuteIsAPassThrough() {
        let gate = SampleGate(mutedSamples: 0)
        XCTAssertEqual(gate.pass([0.5, -0.5]), [0.5, -0.5])
        XCTAssertEqual(SampleGate(mutedSamples: -3).pass([1]), [1])
        XCTAssertEqual(SampleGate(mutedSamples: 4).pass([]), [])
    }
}
