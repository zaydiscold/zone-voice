// by zayd/cold @ zayd.wtf

import XCTest
import ZoneCore
@testable import Zone

@MainActor
final class FinishWhenQuietSettingTests: XCTestCase {
    private func settings(storing value: Any?) throws -> AppSettings {
        let suite = "zone.tests.quiet-wait.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        if let value { defaults.set(value, forKey: "zone.settings.finishWhenQuietWait") }
        return AppSettings(defaults: defaults, store: InMemorySharedStore(), vocabulary: nil)
    }

    func testNothingSavedIsTheDefault() throws {
        XCTAssertEqual(try settings(storing: nil).finishWhenQuietWait, SilenceFinish.defaultWait)
    }

    func testASavedChoiceIsKept() throws {
        for wait in SilenceFinish.waitChoices {
            XCTAssertEqual(try settings(storing: wait).finishWhenQuietWait, wait)
        }
    }

    /// A launch argument (`-zone.settings.finishWhenQuietWait 30`, how UI tests and simulator
    /// checks pin the wait) arrives as a string. Read as a Double only, it fell back to the 5 s
    /// default, and a test written for 30 s ran at 5 without saying so.
    func testAWaitGivenAsTextIsRead() throws {
        XCTAssertEqual(try settings(storing: "30").finishWhenQuietWait, 30)
        XCTAssertEqual(try settings(storing: "10").finishWhenQuietWait, 10)
    }

    func testSavedQuietWaitMatchesTheKeyboardAndTheNextLaunch() throws {
        let suite = "zone.tests.quiet-persistence." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = InMemorySharedStore()
        let settings = AppSettings(defaults: defaults, store: store, vocabulary: nil)
        let key = "zone.settings.finishWhenQuietWait"
        for (value, expected) in [(8.0, 8.0), (0.25, 1), (120, 60), (-2, SilenceFinish.defaultWait)] {
            settings.finishWhenQuietWait = value
            XCTAssertEqual(settings.finishWhenQuietWait, expected)
            XCTAssertEqual(store.keyboardPreferences.quietWait, expected)
            XCTAssertEqual(defaults.persistentDomain(forName: suite)?[key] as? Double, expected)
            XCTAssertEqual(AppSettings(defaults: defaults, store: store, vocabulary: nil).finishWhenQuietWait, expected)
        }
    }

    func testCustomAndUnreadableWaitsOnLaunch() throws {
        XCTAssertEqual(try settings(storing: 7.0).finishWhenQuietWait, 7)
        XCTAssertEqual(try settings(storing: 20.0).finishWhenQuietWait, 20)
        XCTAssertEqual(try settings(storing: 0.25).finishWhenQuietWait, 1)
        XCTAssertEqual(try settings(storing: -2.0).finishWhenQuietWait, SilenceFinish.defaultWait)
        XCTAssertEqual(try settings(storing: 60.0).finishWhenQuietWait, 60)
        XCTAssertEqual(try settings(storing: 120.0).finishWhenQuietWait, 60)
        XCTAssertEqual(try settings(storing: "soon").finishWhenQuietWait, SilenceFinish.defaultWait)
    }
}
