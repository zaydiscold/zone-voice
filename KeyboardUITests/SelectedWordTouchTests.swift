// by zayd/cold @ zayd.wtf

import XCTest

/// Selecting a misspelled word in a real text view offers its fix, and tapping the fix replaces
/// exactly that word, through the real input proxy and its selection callbacks.
final class SelectedWordTouchTests: XCTestCase {
    @MainActor func testWordPredictionsGrowAndStayWithinTheStrip() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--prediction-strip"]
        app.launch()
        let strip = app.descendants(matching: .any)["prediction-strip"].firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 5))
        for width: CGFloat in [155, 220] {
            if width == 220 { app.buttons["Wider"].tap() }
            var pictures: [Data] = []
            for size in ["Normal", "Large", "Largest"] {
                app.buttons[size].tap()
                XCTAssertTrue(app.buttons["Mountainside, next word"].isHittable)
                // The accessibility group bounds the buttons and excludes their one-point
                // outside padding when the slots fit. A scrolling viewport uses the full width.
                XCTAssertGreaterThanOrEqual(strip.frame.width, width - 2)
                XCTAssertLessThanOrEqual(strip.frame.width, width)
                XCTAssertGreaterThanOrEqual(strip.frame.height, 36)
                XCTAssertLessThanOrEqual(strip.frame.height, 40)
                let screenshot = strip.screenshot()
                let attachment = XCTAttachment(screenshot: screenshot)
                attachment.name = "Predictions at \(width) points, \(size)"
                attachment.lifetime = .keepAlways
                add(attachment)
                pictures.append(try XCTUnwrap(screenshot.image.pngData()))
            }
            XCTAssertNotEqual(pictures[0], pictures[1])
            XCTAssertEqual(pictures[1], pictures[2])
        }
    }

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
