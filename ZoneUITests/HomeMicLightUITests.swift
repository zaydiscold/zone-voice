// by zayd/cold @ zayd.wtf

import XCTest

final class HomeMicLightUITests: XCTestCase {
    func testFullScreenListeningKeepsControlsInClearEdgeMode() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let id = UUID().uuidString
        app.launchArguments = ["-zone.settings.onboardingDone", "YES", "-zone.tour.seen", "YES",
                               "-zone.settings.appearance", "light", "-zone.settings.micLightStyle", "clear",
                               "-zoneSeedKeyboardRequest", id, "-zoneFakeSpeech", "Full screen microphone check"]
        app.launchEnvironment["ZONE_SIM_CLIP"] = "1"
        app.open(try XCTUnwrap(URL(string: "zone://dictate?request=\(id)")))
        let hide = app.buttons["Hide. Recording continues"]
        XCTAssertTrue(hide.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Listening"].exists)
        let cancel = app.buttons["dictation.cancel"]
        XCTAssertTrue(cancel.wait(for: \.isHittable, toEqual: true, timeout: 5), app.debugDescription)
        keepScreenshot("listening-clear-edge-light")
        hide.tap()
        let reopen = app.buttons["recordingStrip.open"]
        XCTAssertTrue(reopen.waitForExistence(timeout: 8))
        reopen.tap()
        let finish = app.buttons["dictation.stop"]
        XCTAssertTrue(finish.waitForExistence(timeout: 8))
        finish.tap()
        XCTAssertTrue(app.staticTexts["Done"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["dictation.close"].isHittable)
    }

    func testStandbyAndMicTestControlsWithBorderLight() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let version = Bundle(for: Self.self).infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.6"
        app.launchArguments = [
            "-zone.settings.onboardingDone", "YES", "-zone.tour.seen", "YES",
            "-zoneWhatsNewAfter", version, "-zone.settings.autoArm", "<false/>",
            "-zoneHomeMode", "transcribe", "-zone.settings.micLightStyle", "glow", "-zoneFakeSpeech", "Testing the microphone"
        ]
        // Feed the real level meter a bundled speech clip on the simulator.
        app.launchEnvironment["ZONE_SIM_CLIP"] = "1"
        app.launch()

        let headline = app.descendants(matching: .any)["home.standbyTitle"].firstMatch
        let turnOn = app.buttons["Turn on"]
        XCTAssertTrue(turnOn.waitForExistence(timeout: 20))
        XCTAssertEqual(headline.label, "Standby off")
        waitUntilEnabled(turnOn)
        turnOn.tap()

        let turnOff = app.buttons["Turn off"]
        XCTAssertTrue(turnOff.waitForExistence(timeout: 15))
        XCTAssertEqual(headline.label, "Standby on")
        keepScreenshot("standby")
        turnOff.tap()
        XCTAssertTrue(turnOn.waitForExistence(timeout: 10))
        XCTAssertEqual(headline.label, "Standby off")
        keepScreenshot("standby-off")

        let dictate = app.buttons["Dictate"]
        XCTAssertTrue(dictate.isHittable)
        dictate.tap()
        let pause = app.buttons["Pause recording"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        XCTAssertEqual(headline.label, "Listening")
        keepScreenshot("listening")
        pause.tap()
        let resume = app.buttons["Resume recording"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        XCTAssertEqual(headline.label, "Paused")
        resume.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 5))

        app.buttons["Stop and keep the words"].tap()
        let words = NSPredicate(format: "value CONTAINS[c] %@", "testing the microphone")
        let field = app.descendants(matching: .any)
            .matching(NSPredicate(format: "elementType == %d OR elementType == %d",
                                  XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue))
            .matching(words).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))

    }

    private func waitUntilEnabled(_ element: XCUIElement) {
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: element)
        waitForExpectations(timeout: 15)
    }

    private func keepScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
