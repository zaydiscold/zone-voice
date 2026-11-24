// by zayd/cold @ zayd.wtf

import XCTest

/// Settings > Dynamic Island: the switch that governs the island is the first row, turning it off
/// hides everything it governs, and the Color choice is there. Settings has no Experimental page:
/// its switches are on Dictation options, with no Beta or Experimental labels.
final class IslandSettingsUITests: XCTestCase {
    private var settled: [String] {
        let version = Bundle(for: Self.self).infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.6"
        return ["-zone.settings.onboardingDone", "YES", "-zone.tour.seen", "YES", "-zoneWhatsNewAfter", version,
                // A known start, whatever an earlier run left: Zone in the island, Halo, the accent.
                "-zone.settings.islandWhileReady", "YES", "-zone.settings.islandLook", "halo",
                "-zone.settings.islandPalette", "accent", "-zone.settings.autoArm", "NO"]
    }

    override func setUp() {
        continueAfterFailure = false
    }

    private func openSettings(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = settled + extra
        app.launch()
        let gear = app.buttons["home.settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 30), "Home")
        gear.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "Settings")
        return app
    }

    private func keepScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, swipes: Int = 6) {
        for _ in 0..<swipes where !(element.exists && element.isHittable) { app.swipeUp() }
        XCTAssertTrue(element.isHittable, "\(element.debugDescription.prefix(80)) on screen")
    }

    func testTheSwitchIsFirstAndHidesWhatItGoverns() {
        let app = openSettings()
        let row = app.descendants(matching: .any)["settings.island"].firstMatch
        reveal(row, in: app)
        XCTAssertTrue(row.label.contains("Halo"), "the row shows the switch: \(row.label)")
        row.tap()
        XCTAssertTrue(app.navigationBars["Dynamic Island"].waitForExistence(timeout: 10), "the Dynamic Island screen")

        let master = app.switches["island.master"]
        XCTAssertTrue(master.waitForExistence(timeout: 5), "the switch")
        XCTAssertEqual(master.value as? String, "1", "on out of the gate")
        let buttons = app.switches["Buttons"]
        XCTAssertTrue(buttons.exists)
        XCTAssertLessThan(master.frame.minY, buttons.frame.minY)
        XCTAssertTrue(app.buttons["island.gallery"].exists)
        XCTAssertTrue(app.buttons["Try it in the Dynamic Island"].exists)
        keepScreenshot("island-on")

        master.switches.firstMatch.tap()
        XCTAssertEqual(master.value as? String, "0", "off")
        XCTAssertFalse(app.staticTexts["Themes"].waitForExistence(timeout: 1), "no themes or looks while it is off")
        XCTAssertFalse(app.buttons["island.gallery"].exists)
        XCTAssertFalse(app.buttons["Blackout"].exists, "no colors")
        XCTAssertFalse(app.switches["Buttons"].exists, "no buttons switch")
        XCTAssertFalse(app.buttons["Try it in the Dynamic Island"].exists, "no demo")
        app.buttons["About Dynamic Island"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'orange mic pill'")).firstMatch.exists,
                      "the footer says what iOS shows instead")
        app.buttons["Done"].tap()
        keepScreenshot("island-off")

        app.buttons["nav.back"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "back to Settings")
        XCTAssertTrue(app.descendants(matching: .any)["settings.island"].firstMatch.label.contains("Off"), "the row says Off")

        // On again: the hidden choices come back as they were.
        app.descendants(matching: .any)["settings.island"].firstMatch.tap()
        XCTAssertTrue(master.waitForExistence(timeout: 10))
        master.switches.firstMatch.tap()
        XCTAssertTrue(buttons.exists)
        XCTAssertFalse(app.buttons["Blackout"].exists)
    }

    func testGalleryLetsYouChooseAPet() {
        let app = openSettings()
        let row = app.descendants(matching: .any)["settings.island"].firstMatch
        reveal(row, in: app)
        row.tap()
        let gallery = app.buttons["island.gallery"]
        reveal(gallery, in: app)
        gallery.tap()
        XCTAssertTrue(app.buttons["island.look.halo"].waitForExistence(timeout: 5))
        keepScreenshot("gallery")
        let pip = app.buttons["island.look.hare"]
        reveal(pip, in: app, swipes: 12)
        pip.tap()
        let status = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Pip ·'")).firstMatch
        reveal(status, in: app)
        keepScreenshot("companion")
        app.buttons["nav.back"].tap()
        app.buttons["nav.back"].tap()
        let summary = app.descendants(matching: .any)["settings.island"].firstMatch
        XCTAssertTrue(summary.label.contains("Pip"), summary.label)
    }

    func testChooseFlowerAndSynthFromTheOrdinaryPicker() {
        let app = openSettings()
        let settings = app.descendants(matching: .any)["settings.island"].firstMatch
        reveal(settings, in: app)
        settings.tap()
        let gallery = app.buttons["island.gallery"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 5))
        gallery.tap()
        XCTAssertTrue(app.navigationBars["Island looks"].waitForExistence(timeout: 8))
        reveal(app.buttons["island.look.ghost"], in: app)
        for name in ["rose", "synth"] {
            let row = app.buttons["island.look." + name]
            reveal(row, in: app, swipes: 12)
            row.tap()
            XCTAssertTrue(row.isSelected)
            keepScreenshot("island-" + name)
        }
        app.buttons["nav.back"].tap()
        XCTAssertTrue(gallery.label.contains("Synth"), gallery.label)
    }

    func testThereIsNoExperimentalPageAndDictationOptionsHasNoBetaLabels() {
        let app = openSettings()
        let options = app.descendants(matching: .any)["settings.dictationOptions"].firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 5), "Dictation options, under Dictation")
        keepScreenshot("settings-dictation")
        let experimental = NSPredicate(format: "label CONTAINS[c] 'experimental'")
        for _ in 0..<10 {
            XCTAssertFalse(app.descendants(matching: .any).matching(experimental).firstMatch.exists, "no Experimental in Settings")
            app.swipeUp()
        }
        app.swipeDown(); app.swipeDown(); app.swipeDown(); app.swipeDown(); app.swipeDown(); app.swipeDown()
        reveal(options, in: app)
        options.tap()
        XCTAssertTrue(app.navigationBars["Dictation options"].waitForExistence(timeout: 10), "the Dictation options page")
        for name in ["Scratch that and no wait", "Check unsure words", "Caps lock drops punctuation",
                     "Smiley face writes :)"] {
            let toggle = app.switches[name]
            for _ in 0..<4 where !toggle.exists { app.swipeUp() }
            XCTAssertTrue(toggle.exists, "the \(name) switch")
        }
        let beta = NSPredicate(format: "label CONTAINS[c] 'beta' OR label CONTAINS[c] 'experimental'")
        XCTAssertFalse(app.descendants(matching: .any).matching(beta).firstMatch.exists, "no Beta or Experimental label")
        keepScreenshot("dictation-options")
    }
}
