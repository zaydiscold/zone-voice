// by zayd/cold @ zayd.wtf

import XCTest

/// Settings > Text style: the four styles, each with the same sentence written its way, and a
/// tap chooses one. Casual's example follows Auto-Capitalization.
final class TextStyleScreenUITests: XCTestCase {
    private var settled: [String] {
        let version = Bundle(for: Self.self).infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.6"
        return ["-zone.settings.onboardingDone", "YES", "-zone.tour.seen", "YES", "-zoneWhatsNewAfter", version]
    }

    override func setUp() {
        continueAfterFailure = false
    }

    /// The switch is read as a Boolean object, so it is passed as a property list value: a bare
    /// "NO" arrives as a string and reads as unset.
    private func openTextStyle(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = settled + extra
        app.launch()
        let gear = app.buttons["home.settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 30), "Home")
        gear.tap()
        let row = app.descendants(matching: .any)["settings.textStyle"].firstMatch
        for _ in 0..<12 where !row.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(row.isHittable, "the Text style row")
        row.tap()
        XCTAssertTrue(app.navigationBars["Text style"].waitForExistence(timeout: 10), "the Text style screen")
        return app
    }

    private func keepScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func checkExample(_ app: XCUIApplication, style: String, expected: String) {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", style, expected)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Rendered example for \(style)")
    }

    func testEachStyleShowsTheSentenceItsWayAndATapChoosesIt() {
        let app = openTextStyle(["-zone.settings.defaultStyle", "casual", "-zone.settings.autoCapitalization", "<true/>"])
        keepScreenshot("text-style")
        checkExample(app, style: "Casual", expected: "Hey sorry does later tonight work? I'm gonna be free around 7 maybe 8")
        checkExample(app, style: "Very casual", expected: "hey sorry does later tonight work? i'm gonna be free around 7 maybe 8")
        checkExample(app, style: "Formal.", expected: "Hey, sorry, does later tonight work? I'm going to be free around seven, maybe eight.")
        checkExample(app, style: "Excited!", expected: "Hey, sorry, does later tonight work? I'm gonna be free around seven, maybe eight!")

        let veryCasual = app.buttons["textStyle.veryCasual"]
        XCTAssertFalse(veryCasual.isSelected, "Casual is chosen at first")
        for id in ["formal", "excited", "casual", "veryCasual"] {
            let style = app.buttons["textStyle." + id]
            style.tap()
            XCTAssertTrue(style.isSelected, "The tapped style is chosen")
        }
        app.buttons["nav.back"].tap()
        let row = app.buttons["settings.textStyle"]
        for _ in 0..<12 where !row.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(row.isHittable, "back on Settings")
        XCTAssertTrue(row.label.contains("Very casual"), "Settings shows the chosen style: \(row.label)")
        row.tap()
        XCTAssertTrue(veryCasual.isSelected, "The selection survives reopening the page")
    }

    func testCasualsExampleStartsLowercaseWithAutoCapitalizationOff() {
        let app = openTextStyle(["-zone.settings.defaultStyle", "casual", "-zone.settings.autoCapitalization", "<false/>"])
        keepScreenshot("text-style-auto-capitalization-off")
        checkExample(app, style: "Casual", expected: "hey sorry does later tonight work? i'm gonna be free around 7 maybe 8")
        checkExample(app, style: "Formal.", expected: "Hey, sorry, does later tonight work? I'm going to be free around seven, maybe eight.")
    }
}
