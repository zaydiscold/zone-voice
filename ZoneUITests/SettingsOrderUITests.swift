// by zayd/cold @ zayd.wtf

import XCTest

/// The order of the top-level Settings screen: Computers sits in Setup, Your data holds only
/// Dictation history, Backup and export and Delete data, just above About, and Privacy is in
/// About. Computers still opens from its row.
final class SettingsOrderUITests: XCTestCase {
    private var settled: [String] {
        let version = Bundle(for: Self.self).infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.4"
        return ["-zone.settings.onboardingDone", "YES", "-zone.tour.seen", "YES", "-zoneWhatsNewAfter", version]
    }

    override func setUp() {
        continueAfterFailure = false
    }

    private func openSettings() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = settled
        app.launch()
        let gear = app.buttons["home.settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 30), "Home")
        gear.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "Settings")
        return app
    }

    /// Kept in the result bundle, so a run shows the screen it checked.
    private func keepScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func above(_ upper: XCUIElement, _ lower: XCUIElement, _ message: String) {
        XCTAssertTrue(upper.exists && lower.exists, message)
        XCTAssertLessThan(upper.frame.minY, lower.frame.minY, message)
    }

    func testComputersIsInSetupAndOpens() {
        let app = openSettings()
        keepScreenshot("settings-top")
        let computers = app.descendants(matching: .any)["settings.computers"].firstMatch
        for _ in 0..<4 where !(computers.exists && computers.isHittable) { app.swipeUp() }
        XCTAssertTrue(computers.isHittable, "the Computers row")
        above(app.buttons["Action Button and Shortcuts"], computers, "Computers follows Action Button and Shortcuts")
        above(computers, app.staticTexts["Personalize"], "Computers is in Setup, above Personalize")
        computers.tap()
        XCTAssertTrue(app.navigationBars["Computers"].waitForExistence(timeout: 10), "the Computers screen")
    }

    func testYourDataSitsAboveAboutAndPrivacyIsInAbout() {
        let app = openSettings()
        let acknowledgments = app.buttons["Acknowledgments"]
        for _ in 0..<10 where !(acknowledgments.exists && acknowledgments.isHittable) { app.swipeUp() }
        XCTAssertTrue(acknowledgments.isHittable, "the bottom of Settings")
        keepScreenshot("settings-bottom")

        let order = [app.buttons["Share Zone with a friend"], app.staticTexts["Your data"],
                     app.buttons["Dictation history"], app.buttons["Backup and export"], app.buttons["Delete data"],
                     app.staticTexts["About"], app.buttons["A note from Zayd"],
                     app.descendants(matching: .any)["settings.version"].firstMatch,
                     app.buttons["Privacy"], acknowledgments]
        for (upper, lower) in zip(order, order.dropFirst()) {
            above(upper, lower, "\(upper.debugDescription.prefix(80)) above \(lower.debugDescription.prefix(80))")
        }
        XCTAssertTrue(app.staticTexts["Stored on this iPhone. Back up to Files, or pair a computer in Setup."].exists
                      || app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Stored on this iPhone and sent to'")).firstMatch.exists,
                      "the Your data footer")
        XCTAssertTrue(app.staticTexts["Swipe typing powered by FUTO Swipe."].exists, "the FUTO line")
        XCTAssertFalse(app.descendants(matching: .any)["settings.computers"].firstMatch.isHittable,
                       "Computers is not down with Your data")
    }
}
