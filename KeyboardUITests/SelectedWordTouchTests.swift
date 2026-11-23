// by zayd/cold @ zayd.wtf

import XCTest

/// Selecting a misspelled word in a real text view offers its fix, and tapping the fix replaces
/// exactly that word, through the real input proxy and its selection callbacks.
final class SelectedWordTouchTests: XCTestCase {
    func testSelectAWordAndTapItsFix() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-proxy", "--autocorrect", "--no-swipe", "--suggestions",
                               "--text", "see you tomorow soon", "--select", "tomorow"]
        app.launch()
        XCTAssertTrue(app.buttons["Space"].waitForExistence(timeout: 10))
        let field = app.textViews["native-field"]
        app.buttons["select-word"].tap()
        let fix = app.buttons["suggestion-tomorrow"]
        XCTAssertTrue(fix.waitForExistence(timeout: 10), "the fix is offered for the selected word")
        fix.tap()
        XCTAssertEqual(field.value as? String, "see you tomorrow soon")
        // Typing afterwards continues after the fixed word, not somewhere else.
        app.buttons["x"].tap()
        XCTAssertEqual(field.value as? String, "see you tomorrowx soon")
    }
    func testAWordAtTheStartOfTheField() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-proxy", "--autocorrect", "--no-swipe", "--suggestions",
                               "--text", "recieve it", "--select", "recieve"]
        app.launch()
        XCTAssertTrue(app.buttons["Space"].waitForExistence(timeout: 10))
        app.buttons["select-word"].tap()
        let fix = app.buttons["suggestion-receive"]
        XCTAssertTrue(fix.waitForExistence(timeout: 10))
        fix.tap()
        XCTAssertEqual(app.textViews["native-field"].value as? String, "receive it")
    }
}
