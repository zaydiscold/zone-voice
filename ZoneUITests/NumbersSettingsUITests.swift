// by zayd/cold @ zayd.wtf

import XCTest

final class NumbersSettingsUITests: XCTestCase {
    func testLight() { checkNumbers("light") }
    func testDark() { checkNumbers("dark") }

    private func checkNumbers(_ appearance: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        let version = Bundle(for: Self.self).infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.6"
        app.launchArguments = ["-zone.settings.onboardingDone", "YES", "-zone.tour.seen", "YES", "-zoneWhatsNewAfter", version,
                               "-zone.settings.appearance", appearance, "-zone.settings.defaultStyle", "casual"]
        app.launch()
        let gear = app.buttons["home.settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 30))
        gear.tap()
        let row = app.buttons["settings.numbers"]
        for _ in 0..<12 where !row.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(row.isHittable)
        row.tap()
        let picker = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Number format")).firstMatch
        for _ in 0..<12 where !picker.isHittable { app.swipeUp() }
        let choices = ["Follow text style", "Always digits", "Words under ten"]
        guard let originalChoice = choices.first(where: { picker.label.contains($0) || picker.value as? String == $0 }) else {
            return XCTFail("The picker must show its current number format")
        }
        defer {
            for _ in 0..<4 where !picker.isHittable { app.swipeDown() }
            picker.tap()
            app.buttons[originalChoice].tap()
        }
        for (choice, example) in [("Always digits", "7"), ("Words under ten", "seven")] {
            picker.tap()
            app.buttons[choice].tap()
            XCTAssertTrue(app.staticTexts["numbers.example"].label.lowercased().hasPrefix(example))
        }
        let toggle = app.switches["numbers.veryCasual"]
        for _ in 0..<3 where !toggle.isHittable { app.swipeUp() }
        let initial = toggle.value as? String
        let changed = initial == "1" ? "0" : "1"
        func setSwitch(to desired: String?) {
            if toggle.value as? String != desired {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
                let settled = NSPredicate(format: "value == %@", desired ?? "")
                expectation(for: settled, evaluatedWith: toggle)
                waitForExpectations(timeout: 5)
            }
        }
        defer { setSwitch(to: initial) }
        setSwitch(to: changed)
        XCTAssertEqual(toggle.value as? String, changed)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "numbers-" + appearance
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
