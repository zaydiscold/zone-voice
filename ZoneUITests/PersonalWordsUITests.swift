// by zayd/cold @ zayd.wtf

import XCTest

/// My words (Settings): words are added from one field, shown as keys, and each can be fixed or
/// removed on its own. Changes save as they are made. The Back button is a key, and swiping
/// back still works without the system's button.
final class PersonalWordsUITests: XCTestCase {
    private var settled: [String] {
        let version = Bundle(for: Self.self).infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.6"
        return ["-zone.settings.onboardingDone", "YES", "-zone.tour.seen", "YES", "-zoneWhatsNewAfter", version]
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

    private func openMyWords(_ app: XCUIApplication) {
        let gear = app.buttons["home.settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 30), "Home")
        gear.tap()
        enterMyWords(app)
    }

    private func enterMyWords(_ app: XCUIApplication) {
        let row = app.buttons["My words"]
        for _ in 0..<12 where !row.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(row.isHittable, "the My words row")
        row.tap()
        XCTAssertTrue(app.textFields["words.field"].waitForExistence(timeout: 10) || app.textViews["words.field"].exists, "My words")
    }

    private func field(_ app: XCUIApplication) -> XCUIElement {
        app.textFields["words.field"].exists ? app.textFields["words.field"] : app.textViews["words.field"]
    }

    private func type(_ text: String, into app: XCUIApplication) {
        let field = field(app)
        field.tap()
        field.typeText(text)
    }

    func testColonEmojiInWordField() {
        let app = XCUIApplication()
        app.launchArguments = settled
        app.launch()
        openMyWords(app)
        type("Lunch :pizza", into: app)
        let pizza = app.buttons["Insert pizza"]
        XCTAssertTrue(pizza.waitForExistence(timeout: 8))
        pizza.tap()
        XCTAssertEqual(field(app).value as? String, "Lunch 🍕")
        XCTAssertFalse(pizza.exists)
    }

    func testHandleHoldOffersCopyEditAndConfirmedDelete() {
        let app = XCUIApplication()
        app.launchArguments = settled + ["-zone.settings.handleRecognition", "<false/>"]
        app.launch()
        openMyWords(app)
        let disclosure = app.buttons["Saved @handles"]
        for _ in 0..<8 where !disclosure.isHittable { app.swipeUp() }
        disclosure.tap()
        let draft = app.textFields["Add a handle"]
        for _ in 0..<6 where !draft.isHittable { app.swipeUp() }
        XCTAssertTrue(draft.isHittable)
        let handle = "holdtest" + UUID().uuidString.prefix(8).lowercased()
        draft.tap()
        draft.typeText(handle + "\n")
        let row = app.staticTexts["@" + handle]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.press(forDuration: 1.1)
        XCTAssertTrue(app.buttons["Copy"].exists)
        app.buttons["Edit"].tap()
        app.alerts.textFields.firstMatch.tap()
        app.alerts.textFields.firstMatch.typeText("x")
        app.buttons["Save"].tap()
        let renamed = app.staticTexts["@" + handle + "x"]
        XCTAssertTrue(renamed.waitForExistence(timeout: 5))
        renamed.press(forDuration: 1.1)
        app.buttons["Delete"].tap()
        app.buttons["Cancel"].tap()
        XCTAssertTrue(renamed.exists)
        renamed.press(forDuration: 1.1)
        app.buttons["Delete"].tap()
        app.buttons["Delete handle"].tap()
        XCTAssertFalse(renamed.exists)
    }

    func testImportFromTheWordListRow() {
        let app = XCUIApplication()
        app.launchArguments = settled
        app.launch()
        openMyWords(app)
        let transfer = app.buttons["Import or export words"]
        for _ in 0..<8 where !transfer.isHittable { app.swipeUp() }
        transfer.tap()
        let editor = app.textViews["Words to import"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Import"].isEnabled)
        keepScreenshot("word-list-import")
        editor.tap()
        editor.typeText("QuillBerry")
        app.buttons["Import"].tap()
        let saved = app.buttons["Remove QuillBerry"]
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        keepScreenshot("word-list-restored")
        saved.press(forDuration: 1.1)
        XCTAssertTrue(app.buttons["Edit"].exists)
        keepScreenshot("word-hold")
        app.buttons["Delete"].tap()
        app.buttons["Delete word"].tap()
    }

    func testAddFixRemoveAndUndo() {
        let app = XCUIApplication()
        app.launchArguments = settled
        app.launch()
        openMyWords(app)

        // A pasted-style list: commas split it, and a phrase keeps its space.
        type("Zonetestia, Quux Corp, zzyzxly", into: app)
        app.buttons["words.add"].tap()
        for word in ["Zonetestia", "Quux Corp", "zzyzxly"] {
            XCTAssertTrue(app.buttons["Remove \(word)"].waitForExistence(timeout: 5), "\(word) is a key")
        }
        XCTAssertEqual(field(app).value as? String, "Add a word or name", "the field clears after adding")
        keepScreenshot("words-added")

        // Tap a word to fix its spelling in place.
        app.buttons["zzyzxly"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5), "fixing shows Cancel")
        field(app).typeText("x")
        app.buttons["words.add"].tap()
        XCTAssertTrue(app.buttons["Remove zzyzxlyx"].waitForExistence(timeout: 5), "the fixed spelling")
        XCTAssertFalse(app.buttons["Remove zzyzxly"].exists, "the old spelling is gone")

        // Remove one, then bring it back.
        app.buttons["Remove Quux Corp"].tap()
        app.buttons["Delete word"].tap()
        XCTAssertTrue(app.buttons["words.undo"].waitForExistence(timeout: 5), "Undo is offered")
        XCTAssertFalse(app.buttons["Remove Quux Corp"].exists)
        app.buttons["words.undo"].tap()
        XCTAssertTrue(app.buttons["Remove Quux Corp"].waitForExistence(timeout: 5), "Undo brings the word back")

        // Nothing to save: leaving and coming back shows the same words.
        app.buttons["nav.back"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "the Back key returns to Settings")
        enterMyWords(app)
        for word in ["Zonetestia", "Quux Corp", "zzyzxlyx"] {
            XCTAssertTrue(app.buttons["Remove \(word)"].waitForExistence(timeout: 5), "\(word) was saved")
        }

        // Clean up, so a second run starts from the same place.
        for word in ["Zonetestia", "Quux Corp", "zzyzxlyx"] {
            let remove = app.buttons["Remove \(word)"]
            remove.tap()
            let confirmation = app.alerts.buttons["Delete word"]
            XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
            confirmation.tap()
            XCTAssertTrue(remove.waitForNonExistence(timeout: 5))
        }
        XCTAssertFalse(app.buttons["Remove Zonetestia"].exists)
    }

    func testSwipingBackWorksWithTheKeyBackButton() {
        let app = XCUIApplication()
        app.launchArguments = settled
        app.launch()
        openMyWords(app)
        XCTAssertTrue(app.buttons["nav.back"].exists, "the Back key")
        // From the screen's left edge.
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "an edge swipe goes back to Settings")
        XCTAssertFalse(field(app).exists, "My words is gone")
        // Settings is itself pushed from Home: its Back key works too, and Home has none.
        app.buttons["nav.back"].tap()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 10), "Home")
        XCTAssertFalse(app.buttons["nav.back"].exists, "the first screen has no Back key")
    }
}
