// by zayd/cold @ zayd.wtf

import XCTest

/// Smart punctuation with real touches on Zone's keys, through the real input proxy into a real
/// text view, switching layers the way a thumb does.
final class SmartPunctuationTouchTests: XCTestCase {
    private func tap(_ character: Character, in app: XCUIApplication) {
        let name = character == " " ? "Space" : String(character)
        if app.buttons[name].exists { app.buttons[name].tap(); return }
        if app.buttons["Numbers"].exists {
            app.buttons["Numbers"].tap()
            if app.buttons[name].exists { app.buttons[name].tap(); return }
            app.buttons["Symbols"].tap()
        } else if app.buttons["Symbols"].exists {
            app.buttons["Symbols"].tap()
            if app.buttons[name].exists { app.buttons[name].tap(); return }
            app.buttons["Letters"].tap()
        } else {
            app.buttons["Letters"].tap()
        }
        XCTAssertTrue(app.buttons[name].exists, "no key for \(name)")
        app.buttons[name].tap()
    }
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--native-proxy", "--no-swipe", "--text", ""] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["Space"].waitForExistence(timeout: 10))
        return app
    }

    func testQuotesDashesEllipsisAndLeadingApostrophes() {
        let app = launch(["--smart-punctuation"])
        for character in "he said \"it's\"--ok... the '90s" { tap(character, in: app) }
        XCTAssertEqual(app.textViews["native-field"].value as? String,
                       "he said \u{201C}it\u{2019}s\u{201D}\u{2014}ok\u{2026} the \u{2019}90s")
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Smart punctuation typed on Zone's keys"; proof.lifetime = .keepAlways
        add(proof)
    }
    func testDeleteAfterADashRestoresTheHyphens() {
        let app = launch(["--smart-punctuation"])
        for character in "a--" { tap(character, in: app) }
        XCTAssertEqual(app.textViews["native-field"].value as? String, "a\u{2014}")
        app.buttons["Delete"].tap()
        XCTAssertEqual(app.textViews["native-field"].value as? String, "a--")
    }
    func testOffLeavesEveryKeyAsTyped() {
        let app = launch([])
        for character in "\"it's\"--ok..." { tap(character, in: app) }
        XCTAssertEqual(app.textViews["native-field"].value as? String, "\"it's\"--ok...")
    }
}
