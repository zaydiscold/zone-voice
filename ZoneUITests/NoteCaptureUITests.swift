// by zayd/cold @ zayd.wtf

import XCTest

/// The note card and the Note saved page in the app itself, with `-zoneFakeSpeech` standing in
/// for the speech model (one script line per note) and the real microphone engine underneath.
/// The pool grants microphone permission when it leases a simulator
/// (`xcrun simctl privacy <udid> grant microphone wtf.zayd.zone`); if a simulator was never granted
/// it, `waitForCard` answers iOS's prompt itself.
final class NoteCaptureUITests: XCTestCase {
    private var settled: [String] {
        let version = Bundle(for: Self.self).infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.6"
        // `TEST_RUNNER_ZONE_APPEARANCE=light xcodebuild test ...` takes the screenshots in light.
        let appearance = ProcessInfo.processInfo.environment["ZONE_APPEARANCE"].map { ["-zone.settings.appearance", $0] } ?? []
        return ["-zone.settings.onboardingDone", "YES", "-zone.tour.seen", "YES", "-zoneWhatsNewAfter", version,
                "-zone.home.notesCollapsed", "NO", "-zone.home.mode", "transcribe",
                // The pool simulators are shared: another session's text style (very casual
                // lowercases) must not change the words these tests look for.
                "-zone.settings.defaultStyle", "casual"] + appearance
    }

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ script: [String], extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = settled + ["-zoneFakeSpeech", script.joined(separator: "|")] + extraArguments
        addUIInterruptionMonitor(withDescription: "Microphone") { alert in
            for label in ["Allow", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Home's Dictate a note, scrolled into reach, once the scripted engine is ready.
    private func dictateNote(_ app: XCUIApplication) {
        let button = app.buttons["home.dictateNote"]
        XCTAssertTrue(button.waitForExistence(timeout: 30), "Home's Dictate a note")
        for _ in 0..<6 where !button.isHittable { app.swipeUp() }
        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: button)
        waitForExpectations(timeout: 20)
        // Home is still laying out when the button first exists: the recovery card arrives a
        // moment after launch and moves everything under it, and a tap aimed before that lands
        // on the card instead (seen on a pool simulator that held recordings to recover).
        waitUntilStill(button)
        button.tap()
    }

    /// Waits until an element has stopped moving. XCUITest aims a tap at the frame it read; on a
    /// page still sliding in, or a list still laying out, that tap lands on something else.
    private func waitUntilStill(_ element: XCUIElement, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        var last = element.frame
        var stillFor = 0
        while stillFor < 3, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.12)
            let now = element.frame
            stillFor = now == last ? stillFor + 1 : 0
            last = now
        }
    }

    private func waitForCard(_ app: XCUIApplication, _ file: StaticString = #filePath, _ line: UInt = #line) -> XCUIElement {
        let save = app.buttons["noteCard.save"]
        let deadline = Date().addingTimeInterval(15)
        while !save.waitForExistence(timeout: 0.5), Date() < deadline {
            allowMicrophoneIfAsked()
        }
        XCTAssertTrue(save.exists, "the note card's save button", file: file, line: line)
        return save
    }

    /// iOS's microphone prompt, on a simulator that was never granted the microphone. The
    /// interruption monitor in `launch` runs only on the test's next interaction with the app, and
    /// waiting for an element is not one: on 2026-11-20 the prompt sat over Home for the whole
    /// 15 s wait on a freshly made pool iPhone 17 Pro Max, and the first note test failed there.
    /// SpringBoard draws the prompt, so it is answered there.
    private func allowMicrophoneIfAsked() {
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.exists { allow.tap() }
    }

    private func waitForPage(_ app: XCUIApplication, _ file: StaticString = #filePath, _ line: UInt = #line) {
        XCTAssertTrue(app.staticTexts["Note saved"].waitForExistence(timeout: 15), "the Note saved page", file: file, line: line)
        // The page slides up; its buttons are not where they will be until it lands.
        waitUntilStill(app.buttons["notePage.done"])
    }

    private func waitForGone(_ element: XCUIElement, timeout: TimeInterval = 8, _ what: String) {
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: element)
        waitForExpectations(timeout: timeout)
        XCTAssertFalse(element.exists, what)
    }

    private func keepScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testDeleteEverythingDuringANoteKeepsItsRecording() {
        let app = launch(["Keep this recording through deletion"])
        dictateNote(app)
        let save = waitForCard(app)
        app.buttons["home.settings"].tap()
        let data = app.buttons["settings.yourData"]
        for _ in 0..<14 where !data.isHittable { app.swipeUp() }
        data.tap()
        let row = app.buttons["Delete data"]
        for _ in 0..<14 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.isHittable)
        row.tap()
        let wipe = app.buttons["Delete everything"]
        for _ in 0..<4 where !wipe.isHittable { app.swipeUp() }
        wipe.tap()
        app.alerts.buttons["Delete everything"].tap()
        let refusal = app.staticTexts["Finish the recording before deleting library items. Nothing was deleted."]
        // Form realizes the result row when it scrolls into view. The floating
        // recording card stays available while the settings form moves underneath.
        XCTAssertTrue(app.alerts.firstMatch.waitForNonExistence(timeout: 5))
        for _ in 0..<4 where !refusal.isHittable {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(refusal.isHittable, "The refusal must be visible while the note is still recording")
        keepScreenshot("delete-during-recording")
        save.tap()
        waitForPage(app)
        XCTAssertTrue(app.staticTexts["Keep this recording through deletion"].exists)
        keepScreenshot("recording-survived-delete")
    }

    // MARK: Tests

    func testHomeDictationWritesAnUnsavedFirstNameAsAHandle() {
        let app = launch(["At Kevin, nice work."], extraArguments: ["-zone.settings.handleRecognition", "<true/>"])
        let mic = app.buttons["Dictate"].firstMatch
        XCTAssertTrue(mic.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: mic)
        waitForExpectations(timeout: 20)
        mic.tap()
        let stop = app.buttons["Stop and keep the words"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        stop.tap()
        let result = app.descendants(matching: .any).matching(
            NSPredicate(format: "value == %@", "@kevin nice work")
        ).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 20))
        keepScreenshot("home-spoken-handle")
    }

    func testHomeDictateFinishesWhileTheFanIsStillPlaying() {
        let app = XCUIApplication()
        app.launchEnvironment["ZONE_SIM_CLIP"] = "speech-then-fan"
        app.launchArguments = settled + ["-zoneFakeSpeech", "Finished over the fan", "-zone.settings.finishWhenQuiet", "YES", "-zone.settings.finishWhenQuietWait", "5"]
        app.launch()
        let mic = app.buttons["Dictate"].firstMatch
        XCTAssertTrue(mic.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: mic)
        waitForExpectations(timeout: 20)
        mic.tap()
        let stop = app.buttons["Stop and keep the words"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(stop.waitForNonExistence(timeout: 19), "The WAV still has fan sound; no one tapped Stop")
        XCTAssertGreaterThan(ProcessInfo.processInfo.systemUptime - start, 7, "Do not finish during the spoken clip")
        let result = app.descendants(matching: .any).matching(NSPredicate(format: "value CONTAINS[c] 'finished over the fan'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        keepScreenshot("home-quiet-finished-over-fan")
    }

    /// Recording is a card over Home, not a screen in front of it; the saved page edits in place
    /// and Added to Notes lands on the note.
    func testCardThenPageThenEditInPlaceThenAddedToNotes() {
        let words = uniqueNotes("Oat", endings: ["milk"])[0]
        let edited = words + " and bread"
        let app = launch([words])
        dictateNote(app)
        let save = waitForCard(app)
        XCTAssertTrue(app.buttons["Discard note"].exists, "X sits on the card")
        // Home is still there under the card, and usable.
        XCTAssertTrue(app.staticTexts["History"].exists, "Home stays on screen while a note records")
        sleep(2)
        keepScreenshot("note-card-recording")
        save.tap()
        waitForPage(app)
        XCTAssertTrue(app.staticTexts[words].exists, "the saved words on the page")
        XCTAssertTrue(app.buttons["notePage.edit"].exists && app.buttons["notePage.copy"].exists
                      && app.buttons["notePage.delete"].exists, "Edit, Copy and Delete on the page")
        XCTAssertTrue(app.buttons["notePage.openNotes"].exists, "Added to Notes is a button")
        XCTAssertFalse(app.buttons["Clean up"].exists, "Cleanup was taken out in 1.0.6")
        keepScreenshot("note-saved-page")

        app.buttons["notePage.edit"].tap()
        let editor = app.textViews["notePage.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "the editor, in place")
        editor.tap()
        app.typeText(" and bread")
        keepScreenshot("note-saved-page-editing")
        app.buttons["notePage.saveEdit"].tap()
        XCTAssertTrue(app.staticTexts[edited].waitForExistence(timeout: 5), "the edit is saved on the page")

        app.buttons["notePage.openNotes"].tap()
        waitForGone(app.staticTexts["Note saved"], "Added to Notes closes the page")
        let onHome = app.buttons.matching(identifier: "note.row")
            .matching(NSPredicate(format: "label CONTAINS %@", edited)).firstMatch
        XCTAssertTrue(onHome.waitForExistence(timeout: 5), "the edited note is in Notes on Home")
        // The section scrolls after the saved page dismisses. The test never scrolls it into view.
        let reachable = onHome.wait(for: \.isHittable, toEqual: true, timeout: 5)
        if !reachable { keepScreenshot("notes-on-home-missing-reveal") }
        XCTAssertTrue(reachable, "Notes scrolled the newly edited row into view at \(onHome.frame)")
        keepScreenshot("notes-on-home-revealed")
    }

    /// The same simulator may have prior notes and any saved number format.
    private func uniqueNotes(_ prefix: String, endings: [String]) -> [String] {
        let letters = (0..<10).map { _ in Character(UnicodeScalar(UInt8.random(in: 97...122))) }
        let marker = "run" + String(letters)
        return endings.map { "\(prefix) \(marker) \($0)" }
    }

    /// Five notes as fast as the page allows: record, save, the page's mic, again. Each press
    /// takes the last page away and every note lands.
    func testFiveNotesInARowFromThePagesMic() {
        let script = uniqueNotes("Rapid", endings: ["cedar", "oak", "pine", "birch", "elm"])
        let app = launch(script)
        dictateNote(app)
        for round in 1...5 {
            waitForCard(app).tap()
            waitForPage(app)
            XCTAssertTrue(app.staticTexts[script[round - 1]].exists, "note \(round) on its page")
            if round < 5 {
                app.buttons["notePage.newNote"].tap()
                waitForGone(app.staticTexts["Note saved"], "the mic closes the page (round \(round))")
            }
        }
        app.buttons["notePage.done"].tap()
        waitForGone(app.staticTexts["Note saved"], "Done closes the page")
        // Home shows the newest three; all five are on the Notes page behind See all.
        let seeAll = app.buttons["home.seeAllNotes"]
        for _ in 0..<8 where !(seeAll.exists && seeAll.isHittable) { app.swipeUp() }
        XCTAssertTrue(seeAll.isHittable, "See all, beside Notes on Home")
        waitUntilStill(seeAll)
        seeAll.tap()
        XCTAssertTrue(app.navigationBars["Notes"].waitForExistence(timeout: 10), "See all opens the Notes page")
        for (round, line) in script.enumerated() {
            let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", line)).firstMatch
            for _ in 0..<3 where !row.exists { app.swipeUp() }
            XCTAssertTrue(row.exists, "note \(round + 1) of 5 is in Notes")
        }
    }

    /// Three notes saved in a row with nobody looking (`-zoneNotesSavedAway` stands in for an
    /// Action Button pressed away from Zone): the page says three, steps between them, copies
    /// them all, and deleting one leaves the other two.
    func testNotesSavedInARowShareOnePage() {
        let script = uniqueNotes("Row", endings: ["cedar", "oak", "pine"])
        let app = XCUIApplication()
        app.launchArguments = settled + ["-zoneFakeSpeech", script.joined(separator: "|"), "-zoneNotesSavedAway"]
        app.launch()
        dictateNote(app)
        waitForCard(app).tap()
        XCTAssertTrue(app.staticTexts["Note saved"].waitForExistence(timeout: 15), "one note: the page as it always was")
        XCTAssertFalse(app.buttons["notePage.copyAll"].exists, "One note has nothing to step between")
        app.buttons["notePage.newNote"].tap()
        waitForCard(app).tap()
        XCTAssertTrue(app.staticTexts["2 notes saved"].waitForExistence(timeout: 15))
        app.buttons["notePage.newNote"].tap()
        waitForCard(app).tap()
        XCTAssertTrue(app.staticTexts["3 notes saved"].waitForExistence(timeout: 15))
        waitUntilStill(app.buttons["notePage.done"])
        XCTAssertTrue(app.staticTexts["Note 3 of 3"].exists, "The page opens on the newest")
        XCTAssertTrue(app.staticTexts[script[2]].exists)
        XCTAssertFalse(app.buttons["notePage.later"].isEnabled, "Nothing after the newest")
        keepScreenshot("notes-in-a-row-newest")

        app.buttons["notePage.earlier"].tap()
        XCTAssertTrue(app.staticTexts["Note 2 of 3"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts[script[1]].exists, "The second note's words")
        app.buttons["notePage.earlier"].tap()
        XCTAssertTrue(app.staticTexts[script[0]].waitForExistence(timeout: 3), "The first note's words")
        XCTAssertFalse(app.buttons["notePage.earlier"].isEnabled, "Nothing before the oldest")
        keepScreenshot("notes-in-a-row-oldest")

        app.buttons["notePage.copyAll"].tap()
        XCTAssertTrue(app.buttons["notePage.copyAll"].label.contains("Copied"), "Copy all says it copied")

        // Edit the first note in place: the edit lands on the note showing, not the newest.
        app.buttons["notePage.edit"].tap()
        let editor = app.textViews["notePage.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.typeText(" edited")
        app.buttons["notePage.saveEdit"].tap()
        XCTAssertTrue(app.staticTexts[script[0] + " edited"].waitForExistence(timeout: 5))

        app.buttons["notePage.later"].tap()
        XCTAssertTrue(app.staticTexts[script[1]].waitForExistence(timeout: 3))
        app.buttons["notePage.delete"].tap()
        app.buttons["Delete note"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["2 notes saved"].waitForExistence(timeout: 5), "Deleting one keeps the page on the rest")
        XCTAssertFalse(app.staticTexts[script[1]].exists)
        app.buttons["notePage.done"].tap()
        waitForGone(app.staticTexts["2 notes saved"], "Done closes the page")
    }

    /// Pause is on the card, between the bars and the check: before, the only pause for a note
    /// was inside the expanded Dynamic Island.
    func testPauseOnTheCardHoldsTheNoteAndResumeGoesOn() {
        let app = launch(["Paused and then saved"])
        dictateNote(app)
        _ = waitForCard(app)
        let pause = app.buttons["noteCard.pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "the card's pause button")
        waitUntilStill(pause)
        XCTAssertEqual(pause.label, "Pause note")
        pause.tap()
        XCTAssertTrue(app.staticTexts["Paused"].waitForExistence(timeout: 5), "the card says Paused")
        XCTAssertEqual(pause.label, "Resume note")
        pause.tap()
        XCTAssertTrue(app.staticTexts["New note"].waitForExistence(timeout: 5), "resumed: the card is a note again")
        XCTAssertEqual(pause.label, "Pause note")
        app.buttons["noteCard.save"].tap()
        waitForPage(app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Paused and then saved'")).firstMatch.exists
                      || app.textViews.matching(NSPredicate(format: "value CONTAINS 'Paused and then saved'")).firstMatch.exists,
                      "the note kept its words through the pause")
    }

    /// Changed with the behavior: silence is thinking time, not a note's Save button.
    func testAQuietNoteKeepsRecordingUntilSaved() {
        let app = XCUIApplication()
        app.launchArguments = settled + ["-zoneFakeSpeech", "Said and then silent",
                                         "-zone.settings.finishWhenQuiet", "YES",
                                         "-zone.settings.finishWhenQuietWait", "3"]
        app.launchEnvironment["ZONE_SIM_CLIP"] = "1"
        app.launch()
        dictateNote(app)
        _ = waitForCard(app)
        // Wait beyond even the longest offered quiet wait. Poll the forbidden state so an
        // early save cannot disappear between two snapshots and make this test pass.
        let saved = app.staticTexts["Note saved"]
        XCTAssertFalse(saved.waitForExistence(timeout: 35), "Silence must never save a note")
        XCTAssertFalse(app.staticTexts["Quiet"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Saving in'")).firstMatch.exists)
        XCTAssertTrue(app.buttons["noteCard.save"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "note continues through silence"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["noteCard.save"].tap()
        XCTAssertTrue(saved.waitForExistence(timeout: 50), "Explicit Save keeps the note")
    }

    /// Simulator approximation: a fresh process runs the real Voice note intent after launch.
    /// The simulator cannot emulate system Action Button routing or first-unlock protection.
    func testKilledColdNoteDuringModelLoadHasPeakAndZeroTriesOnHome() {
        let app = XCUIApplication()
        let fixture = UUID().uuidString
        app.launchEnvironment["ZONE_TEST_BLOCKED_RECOVERY"] = fixture
        app.launchEnvironment["ZONE_SIM_CLIP"] = "1"
        let base = settled + ["-zoneFakeSpeech", "Not submitted", "-zone.settings.autoArm", "NO"]
        app.launchArguments = base + ["-zoneWhatsNewIntent", "-zoneHoldSpeechModelLoading"]
        app.launch()
        _ = waitForCard(app)
        let listening = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Recording for ' AND NOT (label IN {'Recording for 0:00', 'Recording for 0:01'})"))
        XCTAssertTrue(listening.firstMatch.waitForExistence(timeout: 12), "Samples arrive while the speech model is held")
        app.terminate()
        app.launchArguments = base
        app.launch()
        let group = app.buttons.matching(NSPredicate(format: "label CONTAINS 'recording to recover' OR label CONTAINS 'recordings to recover'")).firstMatch
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'recovery.row.' AND label CONTAINS 'Not tried yet' AND label CONTAINS 'dBFS'")).firstMatch
        if !row.exists {
            for _ in 0..<6 where !group.isHittable { app.swipeUp() }
            XCTAssertTrue(group.waitForExistence(timeout: 10))
            group.tap()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Cold note after termination during model loading"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testColdLaunchVoiceNoteIntentStartsWithoutAHomeTap() {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = settled + ["-zoneFakeSpeech", "Cold launch note",
                                         "-zoneWhatsNewIntent", "-zone.settings.autoArm", "NO"]
        app.launch()
        let save = waitForCard(app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Cold launch note")).firstMatch.waitForExistence(timeout: 10),
                      "The cold intent receives microphone samples and produces live words")
        waitUntilStill(save)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "cold process voice note intent"
        shot.lifetime = .keepAlways
        add(shot)
        save.tap()
        waitForPage(app)
    }

    func testDiscardAsksFirstAndKeepsNothing() {
        let app = launch(["Words to throw away"])
        dictateNote(app)
        _ = waitForCard(app)
        app.buttons["Discard note"].tap()
        let discard = app.alerts["Discard this recording?"].buttons["Discard"]
        XCTAssertTrue(discard.waitForExistence(timeout: 5), "X asks first")
        discard.tap()
        waitForGone(app.buttons["noteCard.save"], "the card goes")
        XCTAssertFalse(app.staticTexts["Note saved"].exists, "no page for a discarded note")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Words to throw away'")).firstMatch.exists)
        // Home's own controls work again after the alert from the card's window.
        XCTAssertTrue(app.buttons["home.settings"].isHittable)
    }

    func testDeleteOnThePageAsksFirst() {
        let app = launch(["A note I did not mean"])
        dictateNote(app)
        waitForCard(app).tap()
        waitForPage(app)
        app.buttons["notePage.delete"].tap()
        let delete = app.buttons["Delete note"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "Delete asks first")
        keepScreenshot("note-delete-confirmation")
        delete.tap()
        waitForGone(app.staticTexts["Note saved"], "the page closes")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS 'A note I did not mean'")).firstMatch.exists)
    }

    func testSwipingDownClosesThePage() {
        let app = launch(["Swipe me away"])
        dictateNote(app)
        waitForCard(app).tap()
        waitForPage(app)
        let title = app.staticTexts["Note saved"]
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        waitForGone(title, "a swipe down closes the page")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Swipe me away'")).firstMatch.exists, "the note stays")
    }

    func testANoteWithNoWordsSaysSoAndSavesNothing() {
        let app = launch([""])
        dictateNote(app)
        waitForCard(app).tap()
        XCTAssertTrue(app.staticTexts["Nothing heard"].waitForExistence(timeout: 10), "the card says nothing was heard")
        XCTAssertFalse(app.staticTexts["Note saved"].exists)
        keepScreenshot("note-card-no-words")
        waitForGone(app.staticTexts["Nothing heard"], timeout: 8, "the card folds away by itself")
    }
}
