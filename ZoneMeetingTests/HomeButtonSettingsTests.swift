// by zayd/cold @ zayd.wtf

import XCTest
import ZoneCore
@testable import Zone

@MainActor
final class HomeButtonSettingsTests: XCTestCase {
    func testHideHomeButtonPersistsAndPublishesOnChangeAndRelaunch() throws {
        let suite = "zone.tests.home-settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = InMemorySharedStore()
        let settings = AppSettings(defaults: defaults, store: store, vocabulary: nil)
        XCTAssertFalse(settings.hideHomeButton)
        XCTAssertFalse(store.keyboardPreferences.hideHomeButton)
        settings.hideHomeButton = true
        XCTAssertTrue(store.keyboardPreferences.hideHomeButton)
        settings.showSuggestions = true
        XCTAssertTrue(store.keyboardPreferences.hideHomeButton, "Publishing another preference must preserve hiding")
        let reloadedStore = InMemorySharedStore()
        let reloaded = AppSettings(defaults: defaults, store: reloadedStore, vocabulary: nil)
        XCTAssertTrue(reloaded.hideHomeButton)
        XCTAssertTrue(reloadedStore.keyboardPreferences.hideHomeButton)
        reloaded.hideHomeButton = false
        XCTAssertFalse(reloadedStore.keyboardPreferences.hideHomeButton)
        XCTAssertFalse(AppSettings(defaults: defaults, store: InMemorySharedStore(), vocabulary: nil).hideHomeButton)
    }
}
