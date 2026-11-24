// by zayd/cold @ zayd.wtf

import UIKit
import XCTest

final class EmojiShortcodeTouchTests: XCTestCase {
    func testLightTapAndUndo() {
        let app = launch()
        colon(app)
        type("fire", in: app)
        let result = app.buttons["emoji-suggestion-🔥"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        screenshot(app, named: "colon-emoji-light")
        result.tap()
        XCTAssertEqual(app.textViews["native-field"].value as? String, "🔥")
        app.buttons["Delete"].tap()
        XCTAssertEqual(app.textViews["native-field"].value as? String, ":fire")
    }

    func testDarkClosingColonAndUndoWithoutSwipe() {
        let app = launch(dark: true)
        colon(app)
        type("fire", in: app)
        XCTAssertTrue(app.buttons["emoji-suggestion-🔥"].waitForExistence(timeout: 5))
        screenshot(app, named: "colon-emoji-dark")
        colon(app)
        XCTAssertEqual(app.textViews["native-field"].value as? String, "🔥")
        app.buttons["Delete"].tap()
        XCTAssertEqual(app.textViews["native-field"].value as? String, ":fire:")
    }

    func testOrdinaryWordLightReplaceAndUndo() {
        let app = launch(predictions: true)
        type("sob", in: app)
        let button = app.buttons["Replace sob with 😭"]
        XCTAssertTrue(button.waitForExistence(timeout: 6))
        let row = app.scrollViews["keyboard.wordSuggestions"]
        XCTAssertTrue(row.exists)
        XCTAssertLessThanOrEqual(button.frame.width, 44)
        screenshot(app, named: "emoji-prediction-light")
        button.tap()
        XCTAssertEqual(app.textViews["native-field"].value as? String, "😭")
        app.buttons["Delete"].tap()
        XCTAssertEqual(app.textViews["native-field"].value as? String, "sob")
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        app.buttons["Keep sob"].tap()
        XCTAssertEqual(app.textViews["native-field"].value as? String, "sob ")
    }

    func testOrdinaryWordDarkAppendAndUndo() {
        let app = launch(dark: true, predictions: true)
        type("pizza", in: app)
        app.buttons["Space"].tap()
        let button = app.buttons["Add 🍕"]
        XCTAssertTrue(button.waitForExistence(timeout: 6))
        let row = app.scrollViews["keyboard.wordSuggestions"]
        XCTAssertTrue(row.exists)
        XCTAssertLessThanOrEqual(button.frame.width, 44)
        screenshot(app, named: "emoji-prediction-dark")
        button.tap()
        XCTAssertEqual(app.textViews["native-field"].value as? String, "pizza 🍕")
        app.buttons["Delete"].tap()
        XCTAssertEqual(app.textViews["native-field"].value as? String, "pizza ")
        XCTAssertTrue(button.waitForExistence(timeout: 5))
    }

    func testLongCandidateKeepsItsFullWidthBesideEmoji() {
        for word in ["congratulations", "strawberry"] {
            let app = launch(predictions: true)
            type(word, in: app)
            let literal = app.buttons["Keep \(word)"]
            XCTAssertTrue(literal.waitForExistence(timeout: 6))
            if word == "strawberry" {
                let emoji = app.buttons["Replace strawberry with 🍓"]
                XCTAssertTrue(emoji.waitForExistence(timeout: 6))
                XCTAssertLessThanOrEqual(emoji.frame.width, 44)
            }
            let width = (word as NSString).size(withAttributes: [.font: UIFont.preferredFont(forTextStyle: .body)]).width
            XCTAssertGreaterThanOrEqual(literal.frame.width, width)
            literal.tap()
            XCTAssertEqual(app.textViews["native-field"].value as? String, word + " ")
            app.terminate()
        }
    }

    private func launch(dark: Bool = false, predictions: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--native-proxy", predictions ? "--emoji-predictions" : "--emoji-shortcodes", "--autocorrect"] + (dark ? ["--dark", "--no-swipe"] : [])
        app.launch()
        let space = app.buttons["Space"]
        // A pooled simulator can skip the harness's automatic first-responder transition on
        // the first launch after a previous host. Focus the native field as the person would.
        if !space.waitForExistence(timeout: 3) {
            app.textViews["native-field"].tap()
        }
        XCTAssertTrue(space.waitForExistence(timeout: 10))
        return app
    }

    private func colon(_ app: XCUIApplication) {
        app.buttons["Numbers"].tap()
        app.buttons[":"].tap()
        app.buttons["Letters"].tap()
    }

    private func type(_ text: String, in app: XCUIApplication) {
        for key in text { app.buttons[String(key)].tap() }
    }

    private func screenshot(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
