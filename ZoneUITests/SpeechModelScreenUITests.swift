// by zayd/cold @ zayd.wtf

import XCTest

/// Settings > Speech model since 2026-11-18: one model explained, not a Light/Medium picker,
/// no publisher's benchmark, and the top-down card of every step from speaking to text.
final class SpeechModelScreenUITests: XCTestCase {
    private var settled: [String] {
        let version = Bundle(for: Self.self).infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.6"
        // The engine is pinned: a simulator keeps whatever an earlier Diagnostics run chose.
        return ["-zone.settings.onboardingDone", "YES", "-zone.tour.seen", "YES", "-zoneWhatsNewAfter", version,
                "-zone.diagnostics.engine", "fluidMiniCPU"]
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

    /// The speech model diagram must also be readable in light mode.
    func testFlowCardReadsInLightAppearance() {
        let app = open(appearance: "light")
        let last = app.descendants(matching: .any)["speechModel.step.insert"].firstMatch
        for _ in 0..<4 where !(last.exists && last.isHittable) { app.swipeUp() }
        XCTAssertTrue(last.exists, "the last step")
        keepScreenshot("speech-model-flow-light")
    }

    func testOneModelIsExplainedWithTheFlowCard() {
        let app = open(appearance: "dark")
        keepScreenshot("speech-model-top")
        checkScreen(app)
    }

    func testKeyboardRouteMapOpensGPUExplanationWithoutEnablingIt() {
        let app = open(appearance: "dark")
        let routes = app.buttons["What changes when I use the keyboard?"]
        for _ in 0..<8 where !routes.isHittable { app.swipeUp() }
        XCTAssertTrue(routes.isHittable)
        routes.tap()
        let choose = app.buttons["Choose keyboard recognition"]
        for _ in 0..<4 where !choose.isHittable { app.swipeUp() }
        choose.tap()
        let explanation = app.buttons["What is Zone Link GPU?"]
        XCTAssertTrue(explanation.waitForExistence(timeout: 6))
        let endpoint = app.textFields["HTTPS transcription endpoint"]
        // Establish that the field identifies the GPU route even on a reused simulator.
        // Picker changes stay local to this screen until Save is tapped.
        app.buttons["Use my computer’s GPU (beta)"].tap()
        XCTAssertTrue(endpoint.waitForExistence(timeout: 4))
        app.buttons["Zone default"].tap()
        XCTAssertTrue(endpoint.waitForNonExistence(timeout: 4))
        explanation.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'through Tailscale'")).firstMatch.exists)
        XCTAssertFalse(endpoint.exists)
        keepScreenshot("keyboard-route-beta")
    }

    private func open(appearance: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = settled + ["-zone.settings.appearance", appearance]
        app.launch()
        let gear = app.buttons["home.settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 30), "Home")
        // A tap while Home is still settling (dictation arming on open) can be dropped.
        for _ in 0..<3 where !app.navigationBars["Settings"].waitForExistence(timeout: 4) { gear.tap() }
        let row = app.descendants(matching: .any)["settings.speechModel"].firstMatch
        for _ in 0..<12 where !row.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(row.isHittable, "the Speech model row")
        XCTAssertTrue(row.label.contains("Fluid Mini"), "the row names the model, not a size: \(row.label)")
        row.tap()
        XCTAssertTrue(app.navigationBars["Speech model"].waitForExistence(timeout: 10), "the Speech model screen")
        XCTAssertTrue(app.staticTexts["Fluid Speech Mini"].firstMatch.exists, "the model's name")
        return app
    }

    private func checkScreen(_ app: XCUIApplication) {
        for gone in ["Light", "Medium", "For this iPhone", "Use"] {
            XCTAssertFalse(app.staticTexts[gone].exists || app.buttons[gone].exists, "no picker left: \(gone)")
        }
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'moonshine'")).firstMatch.exists,
                       "Moonshine is gone")

        let steps = ["speak", "model", "repair", "words", "style", "insert"]
            .map { app.descendants(matching: .any)["speechModel.step.\($0)"].firstMatch }
        for _ in 0..<4 where !(steps.last!.exists && steps.last!.isHittable) { app.swipeUp() }
        keepScreenshot("speech-model-flow")
        for (upper, lower) in zip(steps, steps.dropFirst()) {
            XCTAssertTrue(upper.exists && lower.exists, "every step is on the card")
            XCTAssertLessThan(upper.frame.minY, lower.frame.minY, "the card runs top to bottom")
        }
        XCTAssertTrue(steps[1].label.contains("FluidAudio"), "the model step names FluidAudio: \(steps[1].label)")

        let details = app.buttons["Details"].firstMatch
        for _ in 0..<4 where !(details.exists && details.isHittable) { app.swipeDown() }
        details.tap()
        let license = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'CC BY 4.0'")).firstMatch
        XCTAssertTrue(license.waitForExistence(timeout: 5), "the license")
        Thread.sleep(forTimeInterval: 1) // let the disclosure finish opening before the picture
        keepScreenshot("speech-model-details")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'publisher'")).firstMatch.exists,
                       "no publisher's test")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'CC BY 4.0'")).firstMatch.exists, "the license")
    }
}
