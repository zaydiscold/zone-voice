// by zayd/cold @ zayd.wtf

import XCTest

final class CursorTouchTests: XCTestCase {
    private func launch(_ args: [String] = [], text: String = "abcdef") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--text", text] + args
        app.launch()
        XCTAssertTrue(app.buttons["Space"].waitForExistence(timeout: 10))
        return app
    }
    private func scrub(_ app: XCUIApplication, dx: CGFloat, hold: TimeInterval = 0.5) {
        let space = app.buttons["Space"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        space.press(forDuration: hold, thenDragTo: space.withOffset(CGVector(dx: dx, dy: 0)),
                    withVelocity: .slow, thenHoldForDuration: 0.05)
    }
    func testHoldDragAndTapWithSwipeCaptureEnabled() {
        verifyCursor([])
    }
    func testHoldDragAndTapWithPlainTouchHandling() {
        verifyCursor(["--no-swipe"])
    }
    private func verifyCursor(_ args: [String]) {
        let app = launch(args)
        scrub(app, dx: -24)
        XCTAssertEqual(app.staticTexts["output"].label, "abcdef")
        XCTAssertEqual(app.staticTexts["caret"].label, "Cursor: 3")
        app.buttons["x"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.08)
        XCTAssertEqual(app.staticTexts["output"].label, "abcxdef")
        app.buttons["Space"].tap()
        XCTAssertEqual(app.staticTexts["output"].label, "abcx def")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Cursor insertion after hold and drag"; shot.lifetime = .keepAlways; add(shot)
    }
    func testHoldWithoutMovementSuppressesSpaceAndNextTapStillTypes() {
        let app = launch()
        app.buttons["Space"].press(forDuration: 0.5)
        XCTAssertEqual(app.staticTexts["output"].label, "abcdef")
        app.buttons["Space"].tap()
        XCTAssertEqual(app.staticTexts["output"].label, "abcdef ")
    }
    func testRealDocumentProxyAcrossEmojiInBothDirections() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-proxy", "--text", "a👩🏽‍🎓e\u{301}🇺🇸z"]
        app.launch()
        XCTAssertTrue(app.buttons["Space"].waitForExistence(timeout: 10))
        let text = app.textViews["native-field"]
        scrub(app, dx: -24)
        XCTAssertEqual(app.staticTexts["caret"].label, "UTF16: 8") // after a + graduate
        app.buttons["x"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.08)
        XCTAssertEqual(text.value as? String, "a👩🏽‍🎓xe\u{301}🇺🇸z")
        scrub(app, dx: 16)
        app.buttons["q"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.08)
        XCTAssertEqual(text.value as? String, "a👩🏽‍🎓xe\u{301}🇺🇸qz")
    }
    /// The November 8 recording: a slide before the hold typed a space mid-word ("i f").
    func testQuickSlideMovesCaretAndNeverTypesASpace() {
        let app = launch(text: "but if it")
        let space = app.buttons["Space"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        space.press(forDuration: 0.05, thenDragTo: space.withOffset(CGVector(dx: -60, dy: 0)),
                    withVelocity: .default, thenHoldForDuration: 0.05)
        XCTAssertEqual(app.staticTexts["output"].label, "but if it")
        XCTAssertNotEqual(app.staticTexts["caret"].label, "Cursor: 9")
    }
    /// Typing a word and its space, then holding space to go back: the everyday case that
    /// used to refuse activation and type a second space.
    func testTypeThenHoldAfterTrailingSpaceMovesBack() {
        let app = launch(text: "")
        for letter in ["h", "i"] {
            app.buttons[letter].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.03)
        }
        app.buttons["Space"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.03)
        scrub(app, dx: -24, hold: 0.45)
        XCTAssertEqual(app.staticTexts["output"].label, "hi ")
        XCTAssertEqual(app.staticTexts["caret"].label, "Cursor: 0")
    }
    /// Many scrubs in a row, both directions, through the real document proxy: no stall, no text.
    func testRepeatedScrubsThroughRealProxyNeverStall() {
        verifyRepeatedScrubs([])
    }
    func testRepeatedScrubsWithPlainTouchHandling() {
        verifyRepeatedScrubs(["--no-swipe"])
    }
    private func verifyRepeatedScrubs(_ args: [String]) {
        let app = XCUIApplication()
        app.launchArguments = ["--native-proxy", "--audit-cursor", "--text", "one two three four five"] + args
        app.launch()
        XCTAssertTrue(app.buttons["Space"].waitForExistence(timeout: 10))
        let text = app.textViews["native-field"]
        var positions: [String] = []
        for dx: CGFloat in [-40, 24, -40, 24, -40] {
            scrub(app, dx: dx, hold: 0.4)
            // Here the keyboard is an in-process inputViewController of a real UITextView, and
            // UIKit holds that window's touches for a moment after the caret moves (measured
            // 2026-11-08: every press within about 0.5 s was lost, none reached the grid; a
            // 0.6 s gap or any extra window recognizer avoided it). Zone's extension runs in its
            // own process, and back-to-back scrubs through the fake host land every time
            // (testRepeatedScrubsThroughFakeHost), so this gap belongs to the harness.
            Thread.sleep(forTimeInterval: 0.6)
            positions.append(app.staticTexts["caret"].label + " req " + app.staticTexts["cursor-requests"].label)
        }
        XCTAssertEqual(text.value as? String, "one two three four five")
        XCTAssertEqual(Set(positions).count, positions.count, "every scrub moved the caret: \(positions)")
    }
    func testRealHostReplacementKeepsCaretConsistent() throws {
        try verifyHostReplacement([])
    }
    func testNotifiedHostReplacementKeepsCaretConsistent() throws {
        try verifyHostReplacement(["--notify-input-delegate"])
    }
    private func verifyHostReplacement(_ args: [String]) throws {
        let app = launch(["--native-proxy", "--replace-during-cursor", "--audit-cursor"] + args)
        scrub(app, dx: -64)
        let audit = app.staticTexts["cursor-requests"]
        // Await observed application of submitted movements, not an arbitrary sleep.
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label ENDSWITH %@", ",0,replaced"), object: audit)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
        let counts = audit.label.split(separator: ",")
        XCTAssertEqual(counts.count, 4)
        guard counts.count == 4 else { return }
        XCTAssertGreaterThan(try XCTUnwrap(Int(counts[0])), 0)
        // The drag may keep moving inside the replacement, as on Apple's keyboard; what
        // matters is that every move landed and the text and next keystroke are intact.
        XCTAssertEqual(counts[2], "0", "Every submitted movement must be observed before typing")
        XCTAssertEqual(counts[3], "replaced")
        XCTAssertEqual(app.textViews["native-field"].value as? String, "replacement")
        let position = try XCTUnwrap(Int(app.staticTexts["caret"].label.replacingOccurrences(of: "UTF16: ", with: "")))
        guard (0...11).contains(position) else { XCTFail("Caret is outside the replacement text"); return }
        let expected = String("replacement".prefix(position)) + "x" + String("replacement".dropFirst(position))
        app.buttons["x"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.08)
        let typed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: app.textViews["native-field"])
        XCTAssertEqual(XCTWaiter.wait(for: [typed], timeout: 5), .completed)
    }
    /// Back to back with no pause: lift, press again, keep going, as a thumb does.
    func testRepeatedScrubsThroughFakeHost() {
        let app = launch(text: "one two three four five")
        var positions: [String] = []
        for dx: CGFloat in [-40, 24, -40, 24, -40] {
            scrub(app, dx: dx, hold: 0.4)
            positions.append(app.staticTexts["caret"].label)
        }
        XCTAssertEqual(app.staticTexts["output"].label, "one two three four five")
        XCTAssertEqual(positions, ["Cursor: 18", "Cursor: 21", "Cursor: 16", "Cursor: 19", "Cursor: 14"])
    }
    /// Up and down through the real document proxy in a multi-line UITextView.
    func testVerticalLanesThroughRealProxy() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-proxy", "--text", #"one two\nthree four\nfive six"#] // see the host
        app.launch()
        XCTAssertTrue(app.buttons["Space"].waitForExistence(timeout: 10))
        let space = app.buttons["Space"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        space.press(forDuration: 0.45, thenDragTo: space.withOffset(CGVector(dx: 0, dy: -40)),
                    withVelocity: .slow, thenHoldForDuration: 0.05)
        XCTAssertEqual(app.staticTexts["caret"].label, "UTF16: 16") // "three fo|ur"
        Thread.sleep(forTimeInterval: 0.6) // see verifyRepeatedScrubs: in-process host gap
        let lower = app.buttons["Space"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.0))
        lower.press(forDuration: 0.45, thenDragTo: lower.withOffset(CGVector(dx: 0, dy: 34)),
                    withVelocity: .slow, thenHoldForDuration: 0.05)
        XCTAssertEqual(app.staticTexts["caret"].label, "UTF16: 27") // back to "five six|" (27 characters)
        XCTAssertEqual(app.textViews["native-field"].value as? String, "one two\nthree four\nfive six")
    }
}
