// by zayd/cold @ zayd.wtf

import XCTest
import Vision

/// Notes after they are saved: three on Home with See all, the Notes page and its search, and
/// the read page, where nothing opens a keyboard until Edit. `-zoneNotesSeed 50` fills the list
/// with made-up notes (fixed ids, so a shared pool simulator is seeded once), and
/// `-zoneNotesAdd` adds fresh ones for the tests that edit and delete.
final class NotesReadingUITests: XCTestCase {
    private var settled: [String] {
        let version = Bundle(for: Self.self).infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.5"
        let environment = ProcessInfo.processInfo.environment
        // `TEST_RUNNER_ZONE_APPEARANCE=dark` and `TEST_RUNNER_ZONE_TEXT_SIZE=UICTContentSizeCategoryAccessibilityXXXL`
        // take the screenshots dark, or at the largest text size.
        let appearance = environment["ZONE_APPEARANCE"].map { ["-zone.settings.appearance", $0] } ?? []
        let size = environment["ZONE_TEXT_SIZE"].map { ["-UIPreferredContentSizeCategoryName", $0] } ?? []
        return ["-zone.settings.onboardingDone", "YES", "-zone.tour.seen", "YES", "-zoneWhatsNewAfter", version,
                "-zone.home.mode", "transcribe", "-zoneNotesSeed", "50"] + appearance + size
    }

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(adding notes: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = settled + (notes.isEmpty ? [] : ["-zoneNotesAdd", notes.joined(separator: "|")])
        app.launch()
        return app
    }

    private func keepScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

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

    private func waitForGone(_ element: XCUIElement, timeout: TimeInterval = 8, _ what: String) {
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: element)
        waitForExpectations(timeout: timeout)
        XCTAssertFalse(element.exists, what)
    }

    private func row(_ app: XCUIApplication, containing words: String) -> XCUIElement {
        app.buttons.matching(identifier: "note.row").matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
    }

    /// Home, scrolled until Notes and its See all can be tapped.
    private func seeAll(_ app: XCUIApplication) -> XCUIElement {
        let seeAll = app.buttons["home.seeAllNotes"]
        XCTAssertTrue(seeAll.waitForExistence(timeout: 30), "Home's See all for notes")
        for _ in 0..<6 where !seeAll.isHittable { app.swipeUp() }
        waitUntilStill(seeAll)
        return seeAll
    }

    private func openNotes(_ app: XCUIApplication) {
        seeAll(app).tap()
        XCTAssertTrue(app.navigationBars["Notes"].waitForExistence(timeout: 10), "See all opens the Notes page")
        XCTAssertTrue(app.buttons.matching(identifier: "note.row").firstMatch.waitForExistence(timeout: 10))
    }

    private func search(_ app: XCUIApplication, _ words: String) {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the Notes page has a search field")
        field.tap()
        // Clear what an earlier search left, with the field's own button.
        let clear = field.buttons["Clear text"]
        if clear.exists { clear.tap() }
        field.typeText(words)
    }

    private var text: String { "noteRead.text" }

    func testUnlockScreenExplainsFirstUnlock() {
        let app = XCUIApplication()
        app.launchArguments = settled + ["-zoneShowUnlockScreen"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Unlock your iPhone once to open Zone."].waitForExistence(timeout: 10))
        keepScreenshot("waiting-for-unlock")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 15))
    }

    func testTourEndsOnHome() {
        let app = XCUIApplication()
        app.launchArguments = ["-zone.settings.onboardingDone", "YES", "-zone.tour.seen", "NO",
                               "-zoneWhatsNewAfter", Bundle(for: Self.self).infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.6"]
        app.launch()
        let next = app.buttons["Next"]
        XCTAssertTrue(next.waitForExistence(timeout: 15))
        for _ in 0..<5 { next.tap() }
        let home = app.buttons["Go to Home"]
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        keepScreenshot("tour-last-page")
        home.tap()
        XCTAssertTrue(app.buttons["home.dictateNote"].waitForExistence(timeout: 10))
    }

    // MARK: Home

    /// Home shows three notes and See all, like History: no chevron, no "Show all" that makes
    /// Home as long as the notes are many.
    func testHoldNoteOpensEditorAndHistoryHoldsFullText() {
        let app = XCUIApplication()
        app.launchArguments = settled + ["-zoneLinkSeed", "20", "-zoneNotesAdd", "Saffron hold menu"]
        app.launch()
        let note = row(app, containing: "Saffron hold menu")
        for _ in 0..<5 where !note.isHittable { app.swipeUp() }
        note.press(forDuration: 1.1)
        XCTAssertTrue(app.buttons["Share"].exists)
        XCTAssertTrue(app.buttons["Delete"].exists)
        keepScreenshot("note-hold")
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["nav.back"].firstMatch.tap()
        let history = app.buttons["See all dictation history"]
        for _ in 0..<5 where !history.isHittable { app.swipeDown() }
        history.tap()
        let dictation = app.buttons.matching(identifier: "library.row").firstMatch
        XCTAssertTrue(dictation.waitForExistence(timeout: 8))
        dictation.press(forDuration: 1.1)
        XCTAssertTrue(app.buttons["Copy"].exists)
        XCTAssertTrue(app.buttons["Share"].exists)
        XCTAssertFalse(app.buttons["Clean up"].exists)
        XCTAssertTrue(app.buttons["Delete"].exists)
        keepScreenshot("dictation-hold")
    }

    func testHistoryDetailDisplaysTheRecordedWords() {
        let app = XCUIApplication()
        app.launchArguments = settled + ["-zoneLinkSeed", "1"]
        app.launch()
        app.buttons["History"].firstMatch.tap()
        search(app, "draft before lunch")
        let words = "Can you send me the draft before lunch. Sample 1."
        let record = app.buttons.matching(identifier: "library.row")
            .matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 8))
        record.tap()
        XCTAssertTrue(app.navigationBars["Dictation"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[words].exists)
        XCTAssertFalse(app.staticTexts["Saved version"].exists)
        XCTAssertFalse(app.staticTexts["Original"].exists)
    }

    func testHomeShowsThreeNotesAndSeeAllOpensTheNotesPage() {
        let app = launch()
        let link = seeAll(app)
        XCTAssertEqual(app.buttons.matching(identifier: "note.row").count, 3, "Home shows the newest three notes, however many there are")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show all'")).firstMatch.exists, "Nothing unfolds on Home")
        XCTAssertFalse(app.buttons["Hide notes"].exists || app.buttons["Show notes"].exists, "The chevron is gone")
        XCTAssertTrue(app.buttons["home.dictateNote"].exists, "New note stays on Home")
        keepScreenshot("home-notes-three-and-see-all")
        link.tap()
        XCTAssertTrue(app.navigationBars["Notes"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5), "the Notes page searches")
        XCTAssertTrue(app.buttons["notes.newNote"].exists, "and starts a note")
        XCTAssertTrue(app.staticTexts["Today"].exists, "Notes are grouped under when they were said")
        keepScreenshot("notes-page")
        // The lazy list may fit fewer than four rows on one screen at larger text sizes.
        let rows = app.buttons.matching(identifier: "note.row")
        var seen = Set(rows.allElementsBoundByIndex.map(\.label))
        for _ in 0..<5 where seen.count <= 3 {
            app.swipeUp()
            seen.formUnion(rows.allElementsBoundByIndex.map(\.label))
        }
        XCTAssertGreaterThan(seen.count, 3, "The full library scrolls beyond the three Home notes")
    }

    // MARK: Reading

    func testReadThreeThousandWordsAtLargestSizeToLastLine() throws {
        let app = XCUIApplication()
        let heading = "Walk " + String(UUID().uuidString.prefix(6))
        let ending = "Blue lantern"
        app.launchArguments = settled + ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
                                         "-zoneLongReaderSeed", heading]
        app.launch()
        let row = row(app, containing: heading)
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 20))
        for _ in 0..<10 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.exists && row.isHittable)
        row.tap()
        let reader = app.textViews[text]
        XCTAssertTrue(reader.waitForExistence(timeout: 10))
        let note = try XCTUnwrap(reader.value as? String)
        XCTAssertEqual(note.split(whereSeparator: \.isWhitespace).count, 3000)
        XCTAssertTrue(note.hasSuffix(ending))
        XCTAssertEqual(app.keyboards.count, 0)
        // A text view exposes all 3,000 words to accessibility even at the top. Read
        // the actual pixels so the last line only passes once it is on screen.
        func seesLastLine() throws -> Bool {
            let shot = try XCTUnwrap(reader.screenshot().image.cgImage)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: shot).perform([request])
            let visible = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            return visible.localizedCaseInsensitiveContains(ending)
        }
        XCTAssertFalse(try seesLastLine())
        // Grab UIKit's scroll indicator near the top and pull it to the bottom.
        // Some simulator versions hide the handle before XCTest can press it.
        reader.swipeUp(velocity: .fast)
        let handle = reader.coordinate(withNormalizedOffset: CGVector(dx: 0.993, dy: 0.03))
        let bottom = reader.coordinate(withNormalizedOffset: CGVector(dx: 0.993, dy: 0.99))
        handle.press(forDuration: 0.6, thenDragTo: bottom)
        XCTAssertEqual(app.keyboards.count, 0)
        if try !seesLastLine() {
            // Stop once the visible text stops moving. OCR runs only at the ends.
            var previous: Data?
            for _ in 0..<18 {
                for _ in 0..<10 {
                    reader.swipeUp(velocity: .fast)
                    XCTAssertEqual(app.keyboards.count, 0)
                }
                let pixels = reader.screenshot().pngRepresentation
                if pixels == previous, try seesLastLine() { break }
                previous = pixels
            }
        }
        XCTAssertTrue(try seesLastLine(), "The last line did not appear in the reader.")
        keepScreenshot("reader-last-line")
    }

    /// The complaint this fixes: tapping a note opened an editor and the keyboard. Now a tap
    /// opens the note to read, whole, and Edit is a second, deliberate step.
    func testANoteOpensToReadWithNoKeyboardAndEditIsASecondStep() {
        let run = String(UUID().uuidString.prefix(6))
        let words = "Reading test \(run). The whole note is here to read, every word of it, and no keyboard comes up until Edit."
        let app = launch(adding: [words])
        _ = seeAll(app)
        let onHome = row(app, containing: run)
        XCTAssertTrue(onHome.waitForExistence(timeout: 10), "the newest note is one of Home's three")
        for _ in 0..<4 where !onHome.isHittable { app.swipeUp() }
        waitUntilStill(onHome)
        onHome.tap()

        let page = app.textViews[text]
        XCTAssertTrue(page.waitForExistence(timeout: 10), "a tap opens the note to read")
        XCTAssertEqual(page.value as? String, words, "all of the note, not two lines of it")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(app.keyboards.count, 0, "Reading a note never brings up the keyboard")
        XCTAssertTrue(app.buttons["noteRead.edit"].exists && app.buttons["noteRead.copy"].exists
                      && app.buttons["noteRead.share"].exists && app.buttons["noteRead.delete"].exists,
                      "Edit, Copy, Share and Delete are on the page")
        // Touching the words does not start an edit either.
        page.tap()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(app.keyboards.count, 0, "A tap on the words does not open the keyboard")
        keepScreenshot("note-read")

        app.buttons["noteRead.copy"].tap()
        XCTAssertTrue(app.buttons["noteRead.copy"].label.contains("Copied"), "Copy says it copied")

        // The second step.
        app.buttons["noteRead.edit"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Edit brings the keyboard")
        XCTAssertFalse(app.buttons["noteRead.saveEdit"].isEnabled, "Nothing to save until something changes")
        page.typeText(" Edited here.")
        keepScreenshot("note-read-editing")
        app.buttons["noteRead.saveEdit"].tap()
        waitForGone(app.keyboards.firstMatch, "Save puts the keyboard away")
        XCTAssertEqual(page.value as? String, words + " Edited here.", "the edit is saved, on the same page")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Edited'")).firstMatch.exists, "the page says it was edited")

        // The bar's keys step to the next note in the list without going back.
        XCTAssertTrue(app.buttons["noteRead.next"].exists && !app.buttons["noteRead.previous"].isEnabled,
                      "Opened on the newest note: there is a note below and none above")
        app.buttons["noteRead.next"].tap()
        let below = NSPredicate(format: "NOT (value CONTAINS %@)", run)
        expectation(for: below, evaluatedWith: page)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.keyboards.count, 0, "Stepping never brings the keyboard")
        XCTAssertTrue(app.navigationBars.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '2 of '")).firstMatch.exists, "the bar says where in the list this is")
        app.buttons["noteRead.previous"].tap()
        XCTAssertEqual(page.value as? String, words + " Edited here.", "and back up to the note it came from")

        // Cancel throws the typing away.
        app.buttons["noteRead.edit"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        page.typeText(" Not kept.")
        app.buttons["noteRead.cancelEdit"].tap()
        waitForGone(app.keyboards.firstMatch, "Cancel puts the keyboard away")
        XCTAssertEqual(page.value as? String, words + " Edited here.", "Cancel keeps the note as it was")

        app.buttons["nav.back"].tap()
        XCTAssertTrue(row(app, containing: "Edited here").waitForExistence(timeout: 5), "Back on Home, the row has the edit")
    }

    // MARK: Search

    /// A word from the last sentence of a 159-word note finds it, the row shows the words around
    /// it, and the note opens at that word.
    func testSearchFindsAWordInTheMiddleOfALongNote() {
        let app = launch()
        openNotes(app)
        search(app, "kettle")
        let found = row(app, containing: "kettle")
        XCTAssertTrue(found.waitForExistence(timeout: 10), "the row shows the words around the match, far past its first lines")
        XCTAssertTrue(found.label.contains("Trip planning for March"), "under the note's own lead: \(found.label)")
        XCTAssertFalse(row(app, containing: "Pick up oat milk").exists, "notes without the word are not listed")
        keepScreenshot("notes-search-middle-of-long-note")
        found.tap()
        let page = app.textViews[text]
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        XCTAssertTrue((page.value as? String)?.contains("mornings without tea were grim") == true, "the whole note opens")
        XCTAssertEqual(app.keyboards.count, 0, "and the search keyboard is gone while reading")
        keepScreenshot("note-read-from-search")
    }

    /// "dentest" is in no note. The search says so, says what it read instead, and finds the
    /// notes with "dentist".
    func testSearchFindsANoteByASlightlyWrongSpelling() {
        let app = launch()
        openNotes(app)
        search(app, "dentest")
        let summary = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Showing dentist'")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "the page says which word it read instead")
        XCTAssertTrue(summary.label.contains("dentest"), summary.label)
        XCTAssertTrue(app.buttons.matching(identifier: "note.row").matching(NSPredicate(format: "label CONTAINS[c] 'dentist'")).firstMatch.exists,
                      "a note with dentist is found")
        keepScreenshot("notes-search-wrong-spelling")

        // By sound: the note says Kowalski.
        search(app, "kowalsky")
        XCTAssertTrue(row(app, containing: "Kowalski").waitForExistence(timeout: 10), "a name spelled by ear is found")

        // Nothing like it anywhere.
        search(app, "zzqxv")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Nothing matches'")).firstMatch.waitForExistence(timeout: 10))
        keepScreenshot("notes-search-nothing")
    }

    /// One search: from the Notes page the same words are found in dictations and in a meeting's
    /// transcript, counted under the notes and listed under Everything, in the same rows.
    /// `-zoneLinkSeed` adds dictations (one sentence says "dentist") and a meeting whose
    /// transcript says "Thanks for joining".
    func testEverythingAlsoFindsDictationsAndMeetings() {
        let app = XCUIApplication()
        app.launchArguments = settled + ["-zoneLinkSeed", "20"]
        app.launch()
        openNotes(app)

        // A word only the meeting has.
        search(app, "joining")
        let elsewhere = app.buttons["search.elsewhere"]
        XCTAssertTrue(elsewhere.waitForExistence(timeout: 15), "Scoped to notes, the page says what the other lists hold")
        XCTAssertTrue(elsewhere.label.contains("meeting"), elsewhere.label)
        XCTAssertFalse(app.buttons["meeting.row"].exists, "The meeting itself is listed only under Everything")
        keepScreenshot("notes-search-also-elsewhere")
        elsewhere.tap()
        let meeting = app.buttons.matching(identifier: "meeting.row").matching(NSPredicate(format: "label CONTAINS 'Zone Link sample meeting'")).firstMatch
        XCTAssertTrue(meeting.waitForExistence(timeout: 10), "Everything lists the meeting, by name")
        XCTAssertTrue(meeting.label.contains("joining"), "with the words around the match: \(meeting.label)")
        XCTAssertTrue(app.buttons.matching(identifier: "library.copy").firstMatch.exists, "and Copy beside it, as on every row")
        keepScreenshot("notes-search-everything-meeting")
        // The result can extend below the search keyboard. Hold its visible title.
        let titlePoint = meeting.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 24, dy: 18))
        titlePoint.press(forDuration: 1.1)
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 5))
        keepScreenshot("search-meeting-hold")
        app.buttons["Rename"].tap()
        app.buttons["Cancel"].tap()
        meeting.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Zone Link sample meeting'")).firstMatch.waitForExistence(timeout: 10)
                      || app.textFields.matching(NSPredicate(format: "value CONTAINS 'Zone Link sample meeting'")).firstMatch.exists,
                      "a tap opens the meeting")
        app.buttons["nav.back"].firstMatch.tap()

        // Both Link seeds contain these words. Old restored notes contain “shipping”
        // but lack “sample”, so they cannot bury the matching dictations on a reused simulator.
        search(app, "sample shipping")
        XCTAssertTrue(row(app, containing: "Sample note 1").waitForExistence(timeout: 10))
        let heading = app.descendants(matching: .any)["search.group.dictations"].firstMatch
        // The search keyboard can still cover the lower half of the results.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.48))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.24))
        for _ in 0..<12 where !heading.waitForExistence(timeout: 0.6) {
            start.press(forDuration: 0.04, thenDragTo: end)
        }
        XCTAssertTrue(heading.exists, "Missing dictation results for the Link sample: " + app.debugDescription)
        XCTAssertTrue(heading.label.hasPrefix("Dictations"), heading.label)
        let match = app.buttons.matching(identifier: "library.row")
            .matching(NSPredicate(format: "label CONTAINS[c] 'shipping'")).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 5), "A matching dictation appears under its heading")
    }

    // MARK: Delete

    /// Delete always asks: on the read page, and after a swipe in the list.
    func testDeleteAsksFirstOnTheReadPageAndAfterASwipe() {
        let run = String(UUID().uuidString.prefix(6))
        let app = launch(adding: ["Delete from the page \(run)", "Delete with a swipe \(run)"])
        openNotes(app)

        let first = row(app, containing: "Delete from the page \(run)")
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.tap()
        XCTAssertTrue(app.textViews[text].waitForExistence(timeout: 10))
        app.buttons["noteRead.delete"].tap()
        let confirm = app.buttons["Delete note"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Delete asks first")
        XCTAssertTrue(app.textViews[text].exists, "and nothing is gone until the answer")
        keepScreenshot("note-read-delete-asks")
        confirm.tap()
        XCTAssertTrue(app.navigationBars["Notes"].waitForExistence(timeout: 10), "the page closes back to the list")
        waitForGone(first, "the note is gone")

        let second = row(app, containing: "Delete with a swipe \(run)")
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        second.swipeLeft()
        let swipeDelete = app.buttons["Delete"]
        XCTAssertTrue(swipeDelete.waitForExistence(timeout: 5), "the swipe shows Delete")
        swipeDelete.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "and Delete still asks")
        XCTAssertTrue(second.exists, "the note is still there until the answer")
        confirm.tap()
        waitForGone(second, "then it is gone")
    }

    // MARK: Pictures for the design folder

    /// Not a check of behavior: walks the screens and keeps a picture of each, for
    /// docs/design/notes-reading-2026-11-20. Run alone, with the appearance and text size wanted.
    func testTourForScreenshots() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ZONE_NOTES_TOUR"] == "1", "Only for taking the design screenshots")
        let app = launch()
        _ = seeAll(app)
        Thread.sleep(forTimeInterval: 1)
        keepScreenshot("1-home")
        app.buttons["home.seeAllNotes"].tap()
        XCTAssertTrue(app.navigationBars["Notes"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        keepScreenshot("2-notes")
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1)
        keepScreenshot("3-notes-scrolled")
        app.swipeUp(velocity: .fast)
        app.swipeUp(velocity: .fast)
        Thread.sleep(forTimeInterval: 1)
        keepScreenshot("4-notes-older")
        search(app, "kettle")
        Thread.sleep(forTimeInterval: 1.5)
        keepScreenshot("5-search-middle")
        search(app, "dentest")
        Thread.sleep(forTimeInterval: 1.5)
        keepScreenshot("6-search-misspelled")
        search(app, "kettle")
        let found = row(app, containing: "kettle")
        XCTAssertTrue(found.waitForExistence(timeout: 10))
        found.tap()
        XCTAssertTrue(app.textViews[text].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1.5)
        keepScreenshot("7-read-from-search")
        app.buttons["noteRead.edit"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        keepScreenshot("8-edit")
        app.buttons["noteRead.cancelEdit"].tap()
        app.buttons["noteRead.delete"].tap()
        XCTAssertTrue(app.buttons["Delete note"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        keepScreenshot("9-delete-asks")
    }
}
