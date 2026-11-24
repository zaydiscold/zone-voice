// by zayd/cold @ zayd.wtf

import XCTest
import ZoneCore
@testable import Zone

@MainActor
final class FasterDictationSettingTests: XCTestCase {
    func testOffOnUpgradeAndChoiceSurvivesRelaunch() throws {
        let suite = "zone.tests.faster.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func launch() -> AppSettings {
            AppSettings(defaults: defaults, store: InMemorySharedStore(), vocabulary: nil, systemLexicon: nil)
        }
        let settings = launch()
        XCTAssertFalse(settings.fasterDictation)
        settings.fasterDictation = true
        XCTAssertTrue(launch().fasterDictation)
        settings.fasterDictation = false
        XCTAssertFalse(launch().fasterDictation)
    }
}
