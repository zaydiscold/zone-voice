// by zayd/cold @ zayd.wtf

import XCTest

/// The milestone note on Home and Send feedback: the note shows once and stays closed, its
/// button and the Settings row open the same screen, and Email only works with words in it.
final class FeedbackUITests: XCTestCase {
    private var settled: [String] {
        let version = Bundle(for: Self.self).infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.6"
        return ["-zone.settings.onboardingDone", "YES", "-zone.tour.seen", "YES", "-zoneWhatsNewAfter", version,
                "-zone.home.mode", "transcribe"]
    }

    override func setUp() {
        continueAfterFailure = false
    }

    private func keepScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = settled + extra
        app.launch()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 30), "Home")
        return app
    }

    private func messageField(_ app: XCUIApplication) -> XCUIElement {
        let field = app.textFields["Say it or type it"]
        return field.exists ? field : app.textViews["Say it or type it"]
    }

    func testTheNoteShowsOnceAndStaysClosed() {
        // The override starts every run from "nothing closed yet"; closing writes the real record.
        var app = launch(["-zoneMilestone", "10000", "-zone.milestone.acknowledged", "0"])
        XCTAssertTrue(app.staticTexts["10,000 words."].waitForExistence(timeout: 10), "the note")
        XCTAssertTrue(app.buttons["milestone.reply"].exists, "its button")
        keepScreenshot("milestone-note")
        app.buttons["milestone.close"].tap()
        XCTAssertTrue(app.staticTexts["10,000 words."].waitForNonExistence(timeout: 5), "closing puts it away")

        app.terminate()
        app = launch(["-zoneMilestone", "10000"])
        XCTAssertFalse(app.staticTexts["10,000 words."].waitForExistence(timeout: 3), "a closed note stays closed")
    }

    func testTheNoteOpensFeedbackAndEmailNeedsWords() {
        let app = launch(["-zoneMilestone", "50000", "-zone.milestone.acknowledged", "0"])
        XCTAssertTrue(app.staticTexts["50,000 words."].waitForExistence(timeout: 10), "the note")
        app.buttons["milestone.reply"].tap()
        XCTAssertTrue(app.navigationBars["Send feedback"].waitForExistence(timeout: 10), "the feedback screen")
        let email = app.buttons["feedback.email"]
        XCTAssertFalse(email.isEnabled, "Email waits for words")
        // iOS 26 gives the cancel slot an icon's width; the key must still show the whole word.
        XCTAssertGreaterThanOrEqual(app.buttons["Cancel"].frame.width, 60, "Cancel is cut short")
        keepScreenshot("feedback-empty")

        let field = messageField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the message field")
        field.tap()
        field.typeText("The mic key is great & fast. 100% better?")
        XCTAssertTrue(email.isEnabled, "Email works once there are words")
        keepScreenshot("feedback-written")

        // A simulator has no mail app, so the screen falls back to copying. On a phone with
        // one, Zone leaves for it instead.
        email.tap()
        let fallback = app.descendants(matching: .any)["feedback.fallback"].firstMatch
        if fallback.waitForExistence(timeout: 5) {
            // On screen, not hidden behind the composer and the keyboard.
            XCTAssertTrue(app.buttons["Copy my words"].waitForHittable(timeout: 5) && app.buttons["Copy address"].isHittable, "both copies")
            keepScreenshot("feedback-no-mail")
        } else {
            XCTAssertNotEqual(app.state, .runningForeground, "a mail app took the link")
            return
        }

        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 10), "back on Home")
        XCTAssertFalse(app.staticTexts["50,000 words."].exists, "answering the note puts it away")
    }

    func testSettingsHasSendFeedbackAndRate() {
        let app = launch([])
        app.buttons["home.settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "Settings")
        let about = app.buttons["settings.about"]
        for _ in 0..<10 where !about.isHittable { app.swipeUp() }
        about.tap()
        XCTAssertTrue(app.buttons["settings.rate"].isHittable)
        app.buttons["nav.back"].tap()
        app.buttons["settings.help"].tap()
        let feedback = app.buttons["settings.feedback"]
        XCTAssertTrue(feedback.isHittable)
        keepScreenshot("settings-feedback-rows")
        feedback.tap()
        XCTAssertTrue(app.navigationBars["Send feedback"].waitForExistence(timeout: 10), "the feedback screen")
        XCTAssertTrue(app.switches["feedback.details"].exists, "the details switch")
    }
}

private extension XCUIElement {
    func waitForHittable(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if exists && isHittable { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return exists && isHittable
    }
}
