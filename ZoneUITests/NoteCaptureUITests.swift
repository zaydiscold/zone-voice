// by zayd/cold @ zayd.wtf

import XCTest

/// The note card and the Note saved page in the app itself, with `-zoneFakeSpeech` standing in
/// for the speech model (one script line per note) and the real microphone engine underneath.
/// The simulator needs microphone permission first:
/// `xcrun simctl privacy <udid> grant microphone wtf.zayd.zone`.
final class NoteCaptureUITests: XCTestCase {
    private var settled: [String] {
        let version = Bundle(for: Self.self).infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.4"
        // `TEST_RUNNER_ZONE_APPEARANCE=light xcodebuild test ...` takes the screenshots in light.
        let appearance = ProcessInfo.processInfo.environment["ZONE_APPEARANCE"].map { ["-zone.settings.appearance", $0] } ?? []
        return ["-zone.settings.onboardingDone", "YES", "-zone.tour.seen", "YES", "-zoneWhatsNewAfter", version,
                "-zone.home.notesCollapsed", "NO", "-zone.home.mode", "transcribe"] + appearance
    }

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ script: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = settled + ["-zoneFakeSpeech", script.joined(separator: "|")]
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
        button.tap()
    }

    private func waitForCard(_ app: XCUIApplication, _ file: StaticString = #filePath, _ line: UInt = #line) -> XCUIElement {
        let save = app.buttons["noteCard.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 15), "the note card's save button", file: file, line: line)
        return save
    }

    private func waitForPage(_ app: XCUIApplication, _ file: StaticString = #filePath, _ line: UInt = #line) {
        XCTAssertTrue(app.staticTexts["Note saved"].waitForExistence(timeout: 15), "the Note saved page", file: file, line: line)
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

    // MARK: Tests

    /// Recording is a card over Home, not a screen in front of it; the saved page edits in place
    /// and Added to Notes lands on the note.
    func testCardThenPageThenEditInPlaceThenAddedToNotes() {
        let app = launch(["Pick up oat milk"])
        dictateNote(app)
        let save = waitForCard(app)
        XCTAssertTrue(app.buttons["Discard note"].exists, "X sits on the card")
        // Home is still there under the card, and usable.
        XCTAssertTrue(app.staticTexts["History"].exists, "Home stays on screen while a note records")
        sleep(2)
        keepScreenshot("note-card-recording")
        save.tap()
        waitForPage(app)
        XCTAssertTrue(app.staticTexts["Pick up oat milk"].exists, "the saved words on the page")
        XCTAssertTrue(app.buttons["notePage.edit"].exists && app.buttons["notePage.copy"].exists
                      && app.buttons["notePage.delete"].exists, "Edit, Copy and Delete on the page")
        XCTAssertTrue(app.buttons["notePage.openNotes"].exists, "Added to Notes is a button")
        XCTAssertFalse(app.buttons["Review cleanup"].exists, "Cleanup is no longer a big button")
        keepScreenshot("note-saved-page")

        app.buttons["notePage.edit"].tap()
        let editor = app.textViews["notePage.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "the editor, in place")
        editor.tap()
        app.typeText(" and bread")
        keepScreenshot("note-saved-page-editing")
        app.buttons["notePage.saveEdit"].tap()
        XCTAssertTrue(app.staticTexts["Pick up oat milk and bread"].waitForExistence(timeout: 5), "the edit is saved on the page")

        app.buttons["notePage.openNotes"].tap()
        waitForGone(app.staticTexts["Note saved"], "Added to Notes closes the page")
        let onHome = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Pick up oat milk and bread'")).firstMatch
        XCTAssertTrue(onHome.waitForExistence(timeout: 5), "the edited note is in Notes on Home")
        XCTAssertTrue(onHome.isHittable, "Notes scrolled into view")
        keepScreenshot("notes-on-home-revealed")
    }

    /// Five notes as fast as the page allows: record, save, the page's mic, again. Each press
    /// takes the last page away and every note lands.
    func testFiveNotesInARowFromThePagesMic() {
        // Words no earlier run left in Notes.
        let run = UUID().uuidString.prefix(4)
        let script = (1...5).map { "Rapid \(run) note \($0)" }
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
        // Notes is a lazy list: rows below the fold do not exist until scrolled to.
        let showAll = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show all'")).firstMatch
        for _ in 0..<8 where !(showAll.exists && showAll.isHittable) { app.swipeUp() }
        XCTAssertTrue(showAll.isHittable, "Show all, with more than three notes")
        showAll.tap()
        for (round, line) in script.enumerated() {
            let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", line)).firstMatch
            for _ in 0..<6 where !row.exists { app.swipeUp() }
            XCTAssertTrue(row.exists, "note \(round + 1) of 5 is in Notes")
        }
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
