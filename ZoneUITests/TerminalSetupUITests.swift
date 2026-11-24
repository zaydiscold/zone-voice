// by zayd/cold @ zayd.wtf

import XCTest

/// The terminal-style setup (`-zoneSetupTerminal`, Debug), start to finish on a simulator: a
/// scripted download (`-zoneFakeModelDownload`), the scripted speech model (`-zoneFakeSpeech`)
/// and `-zoneKeyboardStandIn` writing what the Zone keyboard writes, since a UI test cannot type
/// through the real extension. Every line is the app's own reading of that state.
///
/// Answers iOS's microphone prompt if asked. `TEST_RUNNER_ZONE_SETUP_SHOTS=1`
/// keeps a screenshot of every step in the result bundle, and `TEST_RUNNER_ZONE_SETUP_APPEARANCE`
/// picks light or dark.
final class TerminalSetupUITests: XCTestCase {
    private let sentence = "Running late order me the usual please"

    private var settledVersion: [String] {
        let version = Bundle(for: Self.self).infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.6"
        return ["-zoneWhatsNewAfter", version]
    }

    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    func testActionButtonGuide() { checkGuide(appearance: "light") }

    func testActionButtonGuideDark() { checkGuide(appearance: "dark") }

    func testActionButtonGuideLargest() {
        checkGuide(appearance: "light", size: "UICTContentSizeCategoryAccessibilityXXXL")
    }

    private func checkGuide(appearance: String, size: String? = nil) {
        let app = XCUIApplication()
        app.launchArguments = settledVersion + ["-zone.settings.onboardingDone", "NO",
            "-zone.settings.appearance", appearance]
        if let size {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", size]
        }
        app.launch()
        let guide = app.buttons["Action Button guide"]
        XCTAssertTrue(guide.waitForExistence(timeout: 10))
        for _ in 0..<4 where !guide.isHittable { app.swipeUp() }
        guide.tap()
        let first = app.staticTexts["Settings > Action Button > Controls > Zone > Voice note"]
        if first.exists {
            XCTAssertFalse(app.buttons["guide.openSettings"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["guide.sketch"].firstMatch.exists)
        } else {
            XCTAssertTrue(app.staticTexts["Back Tap"].exists)
            XCTAssertFalse(app.buttons["guide.openSettings"].exists)
        }
        // Let the sheet finish sliding into place before capturing its first screen.
        Thread.sleep(forTimeInterval: 0.6)
        let picture = XCTAttachment(screenshot: app.screenshot())
        picture.name = size == nil ? "guide-\(appearance)" : "guide-largest"
        picture.lifetime = .keepAlways
        add(picture)
        let siri = app.buttons["Siri and Shortcuts"]
        for _ in 0..<6 where !siri.isHittable { app.swipeUp() }
        for _ in 0..<6 where !siri.isHittable { app.swipeDown() }
        siri.tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Action Button guide"].exists)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        let arguments = settledVersion + [
            "-zone.settings.onboardingDone", "NO", "-zoneKeyboardStandIn",
            "-zoneFakeSpeech", sentence, "-zoneFakeModelDownload", "12",
            "-zone.settings.appearance", environment["ZONE_SETUP_APPEARANCE"] ?? "dark",
        ]
        app.launchArguments = arguments
        app.launch()
        let openLog = app.buttons["setup.openLog"]
        XCTAssertTrue(openLog.waitForExistence(timeout: 15), "Quick setup is reachable from the ordinary first-run screen")
        openLog.tap()
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        guard environment["ZONE_SETUP_SHOTS"] == "1" else { return }
        // Past the keyboard's and the lines' animations, so the picture is the settled screen.
        Thread.sleep(forTimeInterval: 0.6)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func line(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "setup.line.\(id)").firstMatch
    }

    private func count(_ app: XCUIApplication, _ id: String) -> Int {
        app.descendants(matching: .any).matching(identifier: "setup.line.\(id)").count
    }

    func testSetupRunsStartToFinishOnRealChecksWithTheDownloadRunningAlongside() {
        let app = launch()
        let began = Date()

        let download = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Download'")).firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 15), "setup asks for the model first")
        shot(app, "01-download-asked")
        download.tap()

        XCTAssertTrue(line(app, "live.download").waitForExistence(timeout: 5), "the download shows as a live line")
        // A simulator whose permission was reset asks; the pool's granted one is said, not asked.
        let continueKey = app.buttons["Continue"]
        if continueKey.waitForExistence(timeout: 2) {
            shot(app, "02a-microphone-asked")
            continueKey.tap()
            let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
            if allow.waitForExistence(timeout: 5) { allow.tap() }
        }
        XCTAssertTrue(line(app, "microphone.done").waitForExistence(timeout: 5))
        // The download runs while the keyboard is set up. A simulator whose keyboard list
        // already has Zone goes straight to the practice box; otherwise Settings first.
        let practice = app.descendants(matching: .any).matching(identifier: "setup.practice").firstMatch
        let asked = NSPredicate { _, _ in practice.exists || self.line(app, "keyboard.fullAccess").exists }
        expectation(for: asked, evaluatedWith: nil)
        waitForExpectations(timeout: 8)
        shot(app, "02-downloading-keyboard-asked")
        let openSettings = app.buttons["Open Settings"]
        if openSettings.exists {
            openSettings.tap()
            XCTAssertTrue(XCUIApplication(bundleIdentifier: "com.apple.Preferences").wait(for: .runningForeground, timeout: 10))
            app.activate()
            XCTAssertTrue(practice.waitForExistence(timeout: 5))
            practice.tap()
        }
        XCTAssertTrue(line(app, "keyboard.fullAccess").waitForExistence(timeout: 8), "the keyboard's presence is read back")
        XCTAssertTrue(line(app, "keyboard.added").exists)
        XCTAssertFalse(line(app, "model.done").exists, "the keyboard is confirmed while the model is still on its way")
        shot(app, "03-keyboard-found")

        XCTAssertTrue(line(app, "model.done").waitForExistence(timeout: 20))
        XCTAssertTrue(line(app, "live.listening").waitForExistence(timeout: 15), "the dictation shows while it is heard")
        let hearing = line(app, "live.listening")
        let partial = NSPredicate(format: "label CONTAINS[c] 'running'")
        expectation(for: partial, evaluatedWith: hearing)
        waitForExpectations(timeout: 10)
        shot(app, "04-listening")

        XCTAssertTrue(line(app, "said").waitForExistence(timeout: 30), "the first dictation lands")
        // The text style may capitalize or punctuate; the words are the script's.
        XCTAssertTrue(line(app, "said").label.lowercased().contains("order me the usual"), line(app, "said").label)
        XCTAssertTrue(line(app, "dictation.done").label.contains("7 words"), line(app, "dictation.done").label)
        shot(app, "05-dictated")

        let skipButton = app.buttons["Skip for now"]
        XCTAssertTrue(skipButton.waitForExistence(timeout: 5), "the Action Button is offered and can wait")
        shot(app, "06-action-button")
        skipButton.tap()

        let start = app.buttons["Start using Zone"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(line(app, "finished").exists)
        shot(app, "07-ready")

        for id in ["microphone.done", "keyboard.added", "keyboard.fullAccess", "model.done", "said", "dictation.done", "finished"] {
            XCTAssertEqual(count(app, id), 1, "\(id) is printed once")
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 90, "the whole setup, download included, in a minute and a half")

        start.tap()
        let prompt = app.descendants(matching: .any).matching(identifier: "setup.prompt").firstMatch
        XCTAssertTrue(prompt.waitForNonExistence(timeout: 5), "Start using Zone leaves setup")
    }
}
