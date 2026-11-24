// by zayd/cold @ zayd.wtf

import XCTest

/// Settings > About > Version opens the version history, and the What's New sheet shows once after an
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
        let about = app.buttons["settings.about"]
        for _ in 0..<8 where !about.isHittable { app.swipeUp() }
        about.tap()
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

        // A version opens to its notes: the number, then every change as one line under its group.
        rows[1].tap()
        let number = element(app, "releaseNotes.version")
        XCTAssertTrue(number.waitForExistence(timeout: 10))
        XCTAssertEqual(number.label, "Version 1.0.3")
        XCTAssertFalse(element(app, "releaseNotes.build").exists, "the build number belongs to the installed version")
        let groups = app.descendants(matching: .any).matching(identifier: "releaseNotes.group")
        XCTAssertEqual(groups.allElementsBoundByIndex.map(\.label), ["New, 5 changes", "Fixes and polish, 8 changes"])
        let items = app.descendants(matching: .any).matching(identifier: "releaseNotes.item")
        XCTAssertEqual(items.count, 13, "a short version shows every change, none folded away")
        XCTAssertTrue(items.firstMatch.label.hasPrefix("Toggle Zone"), items.firstMatch.label)

        // And back, to the installed version, which shows its build number at the end.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(rows[0].waitForExistence(timeout: 10))
        rows[0].tap()
        XCTAssertTrue(number.waitForExistence(timeout: 10))
        XCTAssertEqual(number.label, "Version 1.0.4")
        XCTAssertFalse(continueButton(app).exists, "opening a version by hand is not the What's New sheet")
    }

    func testSubmittedVersionAndNextVersionShowTheirOwnDictationChanges() {
        let app = launch(["-zoneVersion", "1.0.6", "-zoneWhatsNewAfter", "1.0.6"])
        openVersionHistory(app)
        let current = element(app, "versionHistory.row.1.0.6")
        let submitted = element(app, "versionHistory.row.1.0.5")
        XCTAssertTrue(current.label.contains("installed on this iPhone"))
        XCTAssertLessThan(current.frame.minY, submitted.frame.minY)
        for (row, included, excluded) in [(current, "Restyle what you said", "Learns your fixes"),
                                         (submitted, "Learns your fixes", "Restyle what you said")] {
            row.tap()
            let dictation = element(app, "releaseNotes.group")
            XCTAssertTrue(dictation.waitForExistence(timeout: 10))
            let changes = dictation.value as? String ?? ""
            XCTAssertTrue(changes.contains(included), changes)
            XCTAssertFalse(changes.contains(excluded), changes)
            app.navigationBars.buttons.firstMatch.tap()
        }
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
        // A short list: only the starred changes, each with its name and one sentence.
        let lines = app.descendants(matching: .any).matching(identifier: "whatsNew.line")
        XCTAssertEqual(lines.count, 4, "the starred 1.0.4 changes")
        XCTAssertTrue(lines.firstMatch.label.contains("Your words on your own computer"), lines.firstMatch.label)
        XCTAssertTrue(lines.firstMatch.label.contains("Send your dictations, notes and meetings to a computer you pair."),
                      lines.firstMatch.label)
        XCTAssertFalse(element(app, "releaseNotes.group").exists, "the groups wait for the full notes")
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
        let full = element(app, "whatsNew.fullNotes")
        let changes = app.scrollViews.containing(.button, identifier: "whatsNew.fullNotes").firstMatch
        let footer = continueButton(app)
        // The pinned footer can cover the link even while XCTest reports it as hittable.
        for _ in 0..<6 {
            if full.isHittable && full.frame.maxY < footer.frame.minY - 14 { break }
            changes.swipeUp()
        }
        XCTAssertTrue(full.isHittable)
        XCTAssertLessThan(full.frame.maxY, footer.frame.minY - 14, "All changes is above the pinned footer")
        XCTAssertTrue(full.label.contains("All 39 changes"), full.label)
        XCTAssertTrue(full.label.contains("New, Fixes and polish"), full.label)
        full.tap()

        // The same page as Settings > About > Version. A long version opens folded: each group names its
        // changes, and a tap shows them one line each.
        XCTAssertTrue(app.navigationBars["Version 1.0.4"].waitForExistence(timeout: 10))
        let groups = app.descendants(matching: .any).matching(identifier: "releaseNotes.group")
        let items = app.descendants(matching: .any).matching(identifier: "releaseNotes.item")
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(items.count, 0, "folded until a group is tapped")
        XCTAssertTrue(element(app, "releaseNotes.build").exists, "the installed version shows its build")
        let first = groups.firstMatch
        XCTAssertEqual(first.label, "New, 16 changes")
        XCTAssertTrue((first.value as? String ?? "").hasPrefix("Your words on your own computer, "), "\(String(describing: first.value))")
        first.tap()
        XCTAssertEqual(items.count, 16, "the group's changes, one line each")
        XCTAssertEqual(first.value as? String, "Open")
        first.tap()
        XCTAssertEqual(items.count, 0, "and folded again")

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
        // The walkthrough opens on the first step the simulator has not done. On one that already has
        // the model, the microphone, the keyboard and a dictation (a pool simulator other tests have
        // used) that is the last step, which has Start using Zone and no Not now: batch
        // 20261120-0612 failed here on the one simulator in that state. Either way out is checked.
        let later = app.buttons["Not now"], start = app.buttons["Start using Zone"]
        let walkthrough = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in later.exists || start.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [walkthrough], timeout: 30), .completed, "the setup walkthrough")
        XCTAssertFalse(continueButton(app).waitForExistence(timeout: pastTheWindow), "never during setup")
        if later.exists {
            // "Not now" shows Home with setup unfinished: still nothing.
            later.tap()
            XCTAssertTrue(home(app).waitForExistence(timeout: 10), "Home")
            XCTAssertFalse(continueButton(app).waitForExistence(timeout: pastTheWindow), "never before setup is finished")
        } else {
            // Setup finished in this very launch: the version they just installed is not news either.
            start.tap()
            XCTAssertTrue(home(app).waitForExistence(timeout: 10), "Home")
            XCTAssertFalse(continueButton(app).waitForExistence(timeout: pastTheWindow), "never right after finishing setup")
        }

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
        let id = UUID()
        // Keep this request waiting for setup so the app becomes idle within the
        // eight-second update window, regardless of models installed by other tests.
        app.launchArguments = settledIn + ["-zoneVersion", "1.0.4", "-zoneWhatsNewAfter", "1.0.3",
                                            "-zoneSeedKeyboardRequest", id.uuidString, "-zoneFakeSpeech", "Test words",
                                            "-zoneFakeModelDownload", "30"]
        let opened = Date()
        app.open(try XCTUnwrap(URL(string: "zone://dictate?request=\(id.uuidString)")))
        let close = app.buttons["dictation.close"]
        XCTAssertTrue(close.isHittable || close.waitForExistence(timeout: 5), "keyboard request screen")
        close.tap()
        XCTAssertTrue(home(app).isHittable || home(app).waitForExistence(timeout: 5))
        XCTAssertLessThan(Date().timeIntervalSince(opened), 7)
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

        // A refused press survives relaunch and correctly postpones What's New. End this
        // test's own press before checking what an idle visit is owed.
        if app.staticTexts["Note failed"].exists {
            let dismiss = app.buttons["Dismiss"].firstMatch
            XCTAssertTrue(dismiss.isHittable)
            dismiss.tap()
            XCTAssertTrue(app.staticTexts["Note failed"].waitForNonExistence(timeout: 5))
        } else if app.buttons["Discard note"].exists {
            app.buttons["Discard note"].tap()
            let discard = app.alerts["Discard this recording?"].buttons["Discard"]
            XCTAssertTrue(discard.waitForExistence(timeout: 5))
            discard.tap()
            XCTAssertTrue(app.buttons["noteCard.save"].waitForNonExistence(timeout: 5))
        }

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
            let app = launch(["-zoneVersion", "1.0.6", "-zoneWhatsNewAfter", "1.0.5", "-zone.settings.appearance", look])
            XCTAssertTrue(continueButton(app).waitForExistence(timeout: 30))
            try shot("whats-new-\(look)")
            app.swipeUp()
            try shot("whats-new-scrolled-\(look)")
            element(app, "whatsNew.fullNotes").tap()
            XCTAssertTrue(app.navigationBars["Version 1.0.6"].waitForExistence(timeout: 10))
            try shot("whats-new-all-changes-\(look)")
            app.navigationBars.buttons.firstMatch.tap()
            continueButton(app).tap()
            XCTAssertTrue(continueButton(app).waitForNonExistence(timeout: 10))

            openVersionHistory(app)
            try shot("history-\(look)")
            element(app, "versionHistory.row.1.0.6").tap()
            XCTAssertTrue(element(app, "releaseNotes.version").waitForExistence(timeout: 10))
            try shot("notes-1.0.6-\(look)")
            app.swipeUp()
            try shot("notes-1.0.6-second-\(look)")
            app.swipeDown()
            app.descendants(matching: .any).matching(identifier: "releaseNotes.group").firstMatch.tap()
            try shot("notes-1.0.6-dictation-open-\(look)")
            app.swipeUp()
            try shot("notes-1.0.6-dictation-open-second-\(look)")
            app.navigationBars.buttons.firstMatch.tap()
            element(app, "versionHistory.row.1.0.1").tap()
            XCTAssertTrue(element(app, "releaseNotes.version").waitForExistence(timeout: 10))
            try shot("notes-1.0.1-\(look)")
            app.terminate()
        }
    }
}
