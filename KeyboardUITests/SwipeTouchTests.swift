// by zayd/cold @ zayd.wtf

import XCTest

final class SwipeTouchTests: XCTestCase {
    func testNativeInputControllerKeepsQuickTapsAndSwipeInput() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-proxy"]
        app.launch()
        let field = app.textViews["native-field"]
        XCTAssertTrue(app.buttons["h"].waitForExistence(timeout: 10))
        app.buttons["h"].tap(); app.buttons["i"].tap()
        XCTAssertEqual(field.value as? String, "hi")
        app.buttons["Space"].tap()
        let start = app.buttons["t"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = app.buttons["o"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.02)
        expectation(for: NSPredicate(format: "value IN %@", ["hi to", "hi too"]), evaluatedWith: field)
        waitForExpectations(timeout: 5)
        app.buttons["Delete"].tap()
        XCTAssertEqual(field.value as? String, "hi ")
        app.buttons["q"].tap(); app.buttons["p"].tap()
        XCTAssertEqual(field.value as? String, "hi qp")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Native input controller swipe and taps"; shot.lifetime = .keepAlways; add(shot)
    }
    func testProductionGridSwipeThenDeleteAndOrdinaryTaps() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Swipe ready"].waitForExistence(timeout: 10))
        let start = app.buttons["t"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = app.buttons["o"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.02)
        let output = app.staticTexts["output"]
        expectation(for: NSPredicate(format: "label.length > 0"), evaluatedWith: output)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(["to", "too"].contains(output.label), output.label)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Production grid swipe"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Delete"].tap()
        app.buttons["h"].tap(); app.buttons["i"].tap()
        XCTAssertEqual(output.label, "hi")
        app.buttons["Space"].tap()
        app.buttons["q"].tap(); app.buttons["p"].tap()
        XCTAssertEqual(output.label, "hi qp")
    }
}
