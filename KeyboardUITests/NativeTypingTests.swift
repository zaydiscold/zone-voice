// by zayd/cold @ zayd.wtf

import XCTest

final class NativeTypingTests: XCTestCase {
    func testNativeRegularTypingRepairsReportedSpaceSlipsWithAutocorrectOn() {
        verifyRegularTapCorrections(swipeEnabled: false)
    }
    func testNativeRegularTypingRepairsSlipsWhileSwipeIsEnabled() {
        verifyRegularTapCorrections(swipeEnabled: true)
    }
    private func verifyRegularTapCorrections(swipeEnabled: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--native-proxy", "--autocorrect"] + (swipeEnabled ? [] : ["--no-swipe"])
        app.launch()
        XCTAssertTrue(app.buttons["Space"].waitForExistence(timeout: 10))
        let field = app.textViews["native-field"]
        for character in "hesxhavingxfun socmuchcfunx fuckxyeahx " {
            app.buttons[character == " " ? "Space" : String(character)].tap()
        }
        XCTAssertEqual(field.value as? String, "he's having fun so much fun fuck yeah ")
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Regular taps with autocorrect - reported space slips"
        proof.lifetime = .keepAlways
        add(proof)
    }
    /// Reported Nov 8: "thata" (a beside s) stayed a typo while "thatd" became "that'd", because the
    /// word list had no "'s" contractions. Regular taps through the real keyboard and input proxy.
    func testNativeContractionSlipsGetTheirApostrophe() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-proxy", "--autocorrect", "--no-swipe"]
        app.launch()
        XCTAssertTrue(app.buttons["Space"].waitForExistence(timeout: 10))
        for character in "thata hows thats its " {
            app.buttons[character == " " ? "Space" : String(character)].tap()
        }
        XCTAssertEqual(app.textViews["native-field"].value as? String, "that's how's that's its ")
    }
    func testNativeOrdinarySpaceCommitsImmediatelyWithSwipeDisabled() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-proxy", "--no-swipe"]
        app.launch()
        XCTAssertTrue(app.buttons["Space"].waitForExistence(timeout: 10))
        app.buttons["h"].tap(); app.buttons["i"].tap(); app.buttons["Space"].tap()
        XCTAssertEqual(app.textViews["native-field"].value as? String, "hi ")
        XCTAssertNotEqual(app.buttons["Space"].value as? String, "Cursor control")
    }
    func testNativeNonemptyPrefixSwipeDeleteAndTapSpacing() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-proxy", "--text", "hi "]
        app.launch()
        XCTAssertTrue(app.buttons["Space"].waitForExistence(timeout: 10))
        let field = app.textViews["native-field"]
        let t = app.buttons["t"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let o = app.buttons["o"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        t.press(forDuration: 0.05, thenDragTo: o, withVelocity: .slow, thenHoldForDuration: 0.02)
        expectation(for: NSPredicate(format: "value IN %@", ["hi to", "hi too"]), evaluatedWith: field)
        waitForExpectations(timeout: 5)
        app.buttons["Delete"].tap()
        XCTAssertEqual(field.value as? String, "hi ")
        t.press(forDuration: 0.05, thenDragTo: o, withVelocity: .slow, thenHoldForDuration: 0.02)
        expectation(for: NSPredicate(format: "value IN %@", ["hi to", "hi too"]), evaluatedWith: field)
        waitForExpectations(timeout: 5)
        let committed = field.value as? String ?? ""
        app.buttons["x"].tap()
        XCTAssertEqual(field.value as? String, committed + " x")
    }
    func testNativeInputControllerTapsSwipeAndDeleteWithSwipeEnabled() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-proxy", "--text", ""]
        app.launch()
        XCTAssertTrue(app.buttons["Space"].waitForExistence(timeout: 10))
        let field = app.textViews["native-field"]
        app.buttons["h"].tap(); app.buttons["i"].tap()
        XCTAssertEqual(field.value as? String, "hi")
        app.buttons["Delete"].tap(); app.buttons["Delete"].tap()
        XCTAssertEqual(field.value as? String, "")
        let t = app.buttons["t"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let o = app.buttons["o"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        t.press(forDuration: 0.05, thenDragTo: o, withVelocity: .slow, thenHoldForDuration: 0.02)
        expectation(for: NSPredicate(format: "value IN %@", ["to", "too"]), evaluatedWith: field)
        waitForExpectations(timeout: 5)
        app.buttons["Delete"].tap()
        XCTAssertEqual(field.value as? String, "")
        app.buttons["x"].tap()
        XCTAssertEqual(field.value as? String, "x")
    }
}
