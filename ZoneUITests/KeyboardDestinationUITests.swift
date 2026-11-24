// by zayd/cold @ zayd.wtf

import XCTest

final class KeyboardDestinationUITests: XCTestCase {
    func testSetupDropsIncomingKeyboardDestination() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-zone.settings.onboardingDone", "NO", "-zone.tour.seen", "YES",
                               "-zoneWhatsNewAfter", "1.0.6"]
        app.launch()
        app.open(try XCTUnwrap(URL(string: "zone://settings")))
        let later = app.buttons["Not now"], finish = app.buttons["Start using Zone"]
        let setup = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in later.exists || finish.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [setup], timeout: 15), .completed)
        (later.exists ? later : finish).tap()
        XCTAssertTrue(app.buttons["History"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars["Settings"].exists)
    }

    func testKeyboardURLsReplaceTheOpenScreen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-zone.settings.onboardingDone", "YES", "-zone.tour.seen", "YES",
                               "-zoneWhatsNewAfter", "1.0.6"]
        app.launch()
        for name in ["Settings", "Notes", "Home", "Settings"] {
            app.open(try XCTUnwrap(URL(string: "zone://\(name.lowercased())")))
            if name == "Home" {
                XCTAssertTrue(app.buttons["History"].waitForExistence(timeout: 10))
                XCTAssertFalse(app.navigationBars["Notes"].exists)
            } else {
                XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 10), name)
            }
        }
    }
}
