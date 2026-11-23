// by zayd/cold @ zayd.wtf

import XCTest

/// Settings > Version opens the version history, and the What's New sheet shows once after an
/// update: only to someone who opened Zone themselves, never on a fresh install, and never
/// when the keyboard's link, a Live Activity link or a Shortcut opened Zone.
///
/// The launch arguments are in `Zone/Versions/WhatsNewGate.swift` (`WhatsNewDebug`).
/// `-zoneVersion` makes Zone act as a version, so these tests do not depend on the version in
/// `project.yml`, and `-zoneWhatsNewAfter` writes the record an earlier version would have left.
final class VersionHistoryUITests: XCTestCase {
    /// Setup finished and the tour seen, as on a phone that has used Zone for a while.
    private let settledIn = ["-zone.settings.onboardingDone", "YES", "-zone.tour.seen", "YES"]
    /// Longer than the window in which the sheet may open (`WhatsNewPolicy.window`, 8 seconds).
    private let pastTheWindow: TimeInterval = 12

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String], settled: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = (settled ? settledIn : ["-zone.settings.onboardingDone", "NO"]) + arguments
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func continueButton(_ app: XCUIApplication) -> XCUIElement { app.buttons["whatsNew.continue"] }

    /// Home's gear: on screen and hittable only while Home is in front with nothing over it.
    private func home(_ app: XCUIApplication) -> XCUIElement { app.buttons["home.settings"] }

    private func openVersionHistory(_ app: XCUIApplication) {
        XCTAssertTrue(home(app).waitForExistence(timeout: 30), "Home")
        home(app).tap()
        let row = element(app, "settings.version")
        for _ in 0..<8 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.isHittable, "the Version row in Settings")
        row.tap()
        XCTAssertTrue(app.staticTexts["Version history"].waitForExistence(timeout: 10))
    }

    // MARK: Version history

    func testVersionRowOpensHistoryNewestFirstWithTheInstalledOneMarked() {
        let app = launch(["-zoneVersion", "1.0.4", "-zoneWhatsNewAfter", "1.0.4"])
        openVersionHistory(app)

        let versions = ["1.0.4", "1.0.3", "1.0.2", "1.0.1", "1.0"]
        let rows = versions.map { element(app, "versionHistory.row.\($0)") }
        for (version, row) in zip(versions, rows) { XCTAssertTrue(row.exists, version) }
        for (above, below) in zip(rows, rows.dropFirst()) {
            XCTAssertLessThan(above.frame.minY, below.frame.minY, "newest first")
        }
        XCTAssertTrue(rows[0].label.contains("installed on this iPhone"), rows[0].label)
        XCTAssertFalse(rows[1].label.contains("installed"), rows[1].label)
        XCTAssertTrue(rows[1].label.hasPrefix("Version 1.0.3, November 14, 2026."), rows[1].label)
        XCTAssertTrue(element(app, "versionHistory.build").label.hasPrefix("Zone 1.0.4, build "))

        // A version opens to its notes: the number, cards, then the smaller changes, folded.
        rows[1].tap()
        let number = element(app, "releaseNotes.version")
        XCTAssertTrue(number.waitForExistence(timeout: 10))
        XCTAssertEqual(number.label, "Version 1.0.3")
        XCTAssertTrue(app.staticTexts["Toggle Zone"].exists, "the lead card")
        XCTAssertFalse(element(app, "releaseNotes.build").exists, "the build number belongs to the installed version")
        let showAll = app.buttons["releaseNotes.showAll"]
        for _ in 0..<8 where !(showAll.exists && showAll.isHittable) { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Also in this version"].exists)
        XCTAssertEqual(showAll.label, "Show all 8")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "releaseNotes.fix").count, 5)
        showAll.tap()
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "releaseNotes.fix").count, 8)
        XCTAssertEqual(showAll.label, "Show fewer")

        // And back, to the installed version, which shows its build number at the end.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(rows[0].waitForExistence(timeout: 10))
        rows[0].tap()
        XCTAssertTrue(number.waitForExistence(timeout: 10))
        XCTAssertEqual(number.label, "Version 1.0.4")
        XCTAssertFalse(continueButton(app).exists, "opening a version by hand is not the What's New sheet")
    }

    func testHistoryStopsAtTheInstalledVersion() {
        // Notes written ahead of a release stay out of sight until the app is that version.
        let app = launch(["-zoneVersion", "1.0.2", "-zoneWhatsNewAfter", "1.0.2"])
        openVersionHistory(app)
        XCTAssertTrue(element(app, "versionHistory.row.1.0.2").label.contains("installed on this iPhone"))
        XCTAssertTrue(element(app, "versionHistory.row.1.0").exists)
        XCTAssertFalse(element(app, "versionHistory.row.1.0.3").exists)
        XCTAssertFalse(element(app, "versionHistory.row.1.0.4").exists)
    }

    func testAVersionWithoutNotesStillHasItsHistoryAndNoSheet() {
        let app = launch(["-zoneVersion", "9.9", "-zoneWhatsNewAfter", "1.0.3"])
        XCTAssertTrue(home(app).waitForExistence(timeout: 30), "Home")
        XCTAssertFalse(continueButton(app).waitForExistence(timeout: pastTheWindow), "no notes, no sheet")
        openVersionHistory(app)
        let unwritten = element(app, "versionHistory.unwritten")
        XCTAssertTrue(unwritten.exists)
        XCTAssertTrue(unwritten.label.contains("Version 9.9, installed on this iPhone"), unwritten.label)
        XCTAssertTrue(element(app, "versionHistory.row.1.0.4").exists)
        XCTAssertTrue(element(app, "versionHistory.row.1.0").exists)
    }

    // MARK: What's New

    func testWhatsNewAppearsOnceAfterAnUpdate() {
        var app = launch(["-zoneVersion", "1.0.4", "-zoneWhatsNewAfter", "1.0.3"])
        XCTAssertTrue(continueButton(app).waitForExistence(timeout: 30), "the sheet, on the first open after the update")
        XCTAssertEqual(element(app, "releaseNotes.version").label, "Version 1.0.4")
        XCTAssertTrue(app.staticTexts["What's new in Zone"].exists)
        XCTAssertTrue(app.staticTexts["Your words on your own computer"].exists)
        // A short list: one line per feature, each with its brief, not the full cards.
        XCTAssertTrue(app.staticTexts["Send your dictations, notes and meetings to a computer you pair."].exists)
        XCTAssertFalse(app.staticTexts["Also in this version"].exists, "the smaller changes wait for the full notes")
        XCTAssertTrue(app.buttons["whatsNew.allVersions"].exists)
        continueButton(app).tap()
        XCTAssertTrue(continueButton(app).waitForNonExistence(timeout: 10))
        XCTAssertTrue(home(app).isHittable, "Continue leaves the person on Home")

        // The same version again, as after quitting Zone or installing a newer build of it.
        app.terminate()
        app = launch(["-zoneVersion", "1.0.4"])
        XCTAssertTrue(home(app).waitForExistence(timeout: 30), "Home")
        XCTAssertFalse(continueButton(app).waitForExistence(timeout: pastTheWindow), "shown once per version")
    }

    func testReadTheFullNotesOpensTheDetailedPageInsideTheSheet() {
        let app = launch(["-zoneVersion", "1.0.4", "-zoneWhatsNewAfter", "1.0.3"])
        XCTAssertTrue(continueButton(app).waitForExistence(timeout: 30))
        let lines = app.descendants(matching: .any).matching(identifier: "whatsNew.line")
        XCTAssertEqual(lines.count, 16, "a line for every 1.0.4 feature")
        let full = element(app, "whatsNew.fullNotes")
        for _ in 0..<12 where !(full.exists && full.isHittable) { app.swipeUp() }
        XCTAssertTrue(full.isHittable)
        XCTAssertTrue(full.label.contains("smaller fixes and improvements"), full.label)
        full.tap()

        // The same detailed page as Settings > Version: full cards, then the smaller changes.
        XCTAssertTrue(app.navigationBars["Version 1.0.4"].waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "releaseNotes.feature").exists)
        let showAll = app.buttons["releaseNotes.showAll"]
        for _ in 0..<30 where !(showAll.exists && showAll.isHittable) { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Also in this version"].exists)
        XCTAssertTrue(element(app, "releaseNotes.build").exists, "the installed version shows its build")

        // Back to the list, and Continue still closes the sheet.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(continueButton(app).waitForExistence(timeout: 10))
        continueButton(app).tap()
        XCTAssertTrue(continueButton(app).waitForNonExistence(timeout: 10))
        XCTAssertTrue(home(app).isHittable)
    }

    func testSeeAllVersionsOpensTheHistoryInsideTheSheet() {
        let app = launch(["-zoneVersion", "1.0.4", "-zoneWhatsNewAfter", "1.0.3"])
        XCTAssertTrue(app.buttons["whatsNew.allVersions"].waitForExistence(timeout: 30))
        app.buttons["whatsNew.allVersions"].tap()
        XCTAssertTrue(element(app, "versionHistory.row.1.0.3").waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        XCTAssertTrue(element(app, "versionHistory.row.1.0.3").waitForNonExistence(timeout: 10))
        XCTAssertTrue(home(app).isHittable, "Done closes the sheet")
    }

    func testNoWhatsNewOnAFreshInstallEvenAfterSetup() {
        // First launch ever: no record, setup not started.
        var app = launch(["-zoneVersion", "1.0.4", "-zoneWhatsNewForget"], settled: false)
        XCTAssertTrue(app.buttons["Not now"].waitForExistence(timeout: 30), "the setup walkthrough")
        XCTAssertFalse(continueButton(app).waitForExistence(timeout: pastTheWindow), "never during setup")
        // "Not now" shows Home with setup unfinished: still nothing.
        app.buttons["Not now"].tap()
        XCTAssertTrue(home(app).waitForExistence(timeout: 10), "Home")
        XCTAssertFalse(continueButton(app).waitForExistence(timeout: pastTheWindow), "never before setup is finished")

        // Setup finished, same version: the version they installed is not news to them.
        app.terminate()
        app = launch(["-zoneVersion", "1.0.4"])
        XCTAssertTrue(home(app).waitForExistence(timeout: 30), "Home")
        XCTAssertFalse(continueButton(app).waitForExistence(timeout: pastTheWindow), "never for the version of a fresh install")
    }

    // MARK: Launches the person did not make

    /// The keyboard opens Zone with a dictate link to start the microphone, many times a day.
    /// The notes are owed, and they must wait.
    func testNoWhatsNewWhenTheKeyboardOpensZoneAndItWaitsForThePerson() throws {
        var app = XCUIApplication()
        app.launchArguments = settledIn + ["-zoneVersion", "1.0.4", "-zoneWhatsNewAfter", "1.0.3"]
        let opened = Date()
        app.open(try XCTUnwrap(URL(string: "zone://dictate?request=\(UUID().uuidString)")))
        // The cold path's own screen, which is what the keyboard's tap is for.
        let close = app.buttons["dictation.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 30), "the dictation screen the link opens")
        XCTAssertFalse(continueButton(app).exists, "no sheet over a keyboard dictation")
        // Close it at once. Home is now idle and the visit is seconds old, inside the window in
        // which the sheet may open (8 seconds), so only one thing holds it back: this visit was
        // the keyboard's. A run too slow to get here inside the window proves nothing, and says so.
        close.tap()
        XCTAssertTrue(home(app).waitForExistence(timeout: 10), "Home")
        XCTAssertLessThan(Date().timeIntervalSince(opened), 7, "too slow to test the visit rule on an idle Home; run it again")
        XCTAssertFalse(continueButton(app).waitForExistence(timeout: pastTheWindow), "not on an idle Home in the keyboard's visit")

        // The next time the person opens Zone themselves, the notes are still owed and appear.
        app.terminate()
        app = launch(["-zoneVersion", "1.0.4"])
        XCTAssertTrue(continueButton(app).waitForExistence(timeout: 30), "still owed after the keyboard's visit")
    }

    /// A Live Activity tap, with Zone already running in the background.
    func testNoWhatsNewWhenALinkBringsZoneForwardThenThePersonComesBack() throws {
        let app = XCUIApplication()
        app.launchArguments = settledIn + ["-zoneVersion", "1.0.4", "-zoneWhatsNewAfter", "1.0.3"]
        let link = try XCTUnwrap(URL(string: "zone://recording"))
        // Started by the link (`open` launches the app with it), then sent to the background.
        app.open(link)
        XCTAssertTrue(home(app).waitForExistence(timeout: 30), "Home")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        // The link again, through iOS this time, which brings the running app forward.
        XCUIDevice.shared.system.open(link)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(home(app).waitForExistence(timeout: 10), "an idle Home")
        XCTAssertFalse(continueButton(app).waitForExistence(timeout: pastTheWindow), "no sheet on a visit a link began")

        // Back out, wait past the link's shadow (15 seconds), and open Zone by hand.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        Thread.sleep(forTimeInterval: 17)
        app.activate()
        XCTAssertTrue(continueButton(app).waitForExistence(timeout: 15), "the person's own visit shows it")
    }

    /// The Action Button, a Shortcut, a control or a widget: all run a Zone intent.
    func testNoWhatsNewWhenAShortcutRuns() {
        var app = launch(["-zoneVersion", "1.0.4", "-zoneWhatsNewAfter", "1.0.3", "-zoneWhatsNewIntent"])
        XCTAssertFalse(continueButton(app).waitForExistence(timeout: pastTheWindow), "no sheet on a visit a Shortcut drove")

        app.terminate()
        app = launch(["-zoneVersion", "1.0.4"])
        XCTAssertTrue(continueButton(app).waitForExistence(timeout: 30), "still owed after the Shortcut's visit")
    }

    /// Send to Computer runs in the background from the Action Button or Back Tap: never a visit.
    func testNoWhatsNewWhenSendToComputerRuns() {
        var app = launch(["-zoneVersion", "1.0.4", "-zoneWhatsNewAfter", "1.0.3", "-zoneWhatsNewClipIntent"])
        XCTAssertFalse(continueButton(app).waitForExistence(timeout: pastTheWindow), "no sheet on a visit the Send to Computer shortcut drove")

        app.terminate()
        app = launch(["-zoneVersion", "1.0.4"])
        XCTAssertTrue(continueButton(app).waitForExistence(timeout: 30), "still owed after the shortcut's visit")
    }

    // MARK: Media

    /// Not a test: writes screenshots of the three screens, light and dark, for a review.
    /// `TEST_RUNNER_ZONE_MEDIA_OUT=/tmp/zone-media/ios-versions xcodebuild test ...
    /// -only-testing:ZoneUITests/VersionHistoryUITests/testCaptureMedia`.
    /// `TEST_RUNNER_ZONE_MEDIA_LOOKS=dark` walks through one appearance only, for a screen recording.
    func testCaptureMedia() throws {
        guard let out = ProcessInfo.processInfo.environment["ZONE_MEDIA_OUT"], !out.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_ZONE_MEDIA_OUT to a folder to write screenshots")
        }
        let folder = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func shot(_ name: String) throws {
            Thread.sleep(forTimeInterval: 0.8)
            try XCUIScreen.main.screenshot().pngRepresentation.write(to: folder.appendingPathComponent("\(name).png"))
        }

        let looks = ProcessInfo.processInfo.environment["ZONE_MEDIA_LOOKS"]?.split(separator: ",").map(String.init) ?? ["light", "dark"]
        for look in looks {
            let app = launch(["-zoneVersion", "1.0.4", "-zoneWhatsNewAfter", "1.0.3", "-zone.settings.appearance", look])
            XCTAssertTrue(continueButton(app).waitForExistence(timeout: 30))
            try shot("whats-new-\(look)")
            app.swipeUp()
            try shot("whats-new-scrolled-\(look)")
            continueButton(app).tap()
            XCTAssertTrue(continueButton(app).waitForNonExistence(timeout: 10))

            openVersionHistory(app)
            try shot("history-\(look)")
            element(app, "versionHistory.row.1.0.4").tap()
            XCTAssertTrue(element(app, "releaseNotes.version").waitForExistence(timeout: 10))
            try shot("notes-1.0.4-\(look)")
            app.swipeUp()
            try shot("notes-1.0.4-cards-\(look)")
            for _ in 0..<12 where !app.buttons["releaseNotes.showAll"].isHittable { app.swipeUp() }
            try shot("notes-1.0.4-also-\(look)")
            app.navigationBars.buttons.firstMatch.tap()
            element(app, "versionHistory.row.1.0.1").tap()
            XCTAssertTrue(element(app, "releaseNotes.version").waitForExistence(timeout: 10))
            try shot("notes-1.0.1-\(look)")
            app.terminate()
        }
    }
}
