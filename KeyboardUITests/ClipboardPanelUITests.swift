// by zayd/cold @ zayd.wtf

import XCTest

final class ClipboardPanelUITests: XCTestCase {
    @MainActor func testSaveImageInKeyboardPanel() throws {
        // Make the photo in the test runner. Its full bitmap never enters the keyboard host.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: 4032, height: 3024)
        let data = UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.85) { canvas in
            UIColor.systemGreen.setFill()
            canvas.fill(CGRect(origin: .zero, size: size))
            UIColor.systemBlue.setFill()
            canvas.fill(CGRect(x: 500, y: 400, width: 1900, height: 2300))
        }
        UIPasteboard.general.setData(data, forPasteboardType: "public.jpeg")
        let app = XCUIApplication()
        app.launchArguments = ["--clipboard-panel", "--clipboard-image", "--no-swipe"]
        app.launch()
        app.buttons["History"].tap()
        app.buttons["Paste"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label == %@", "Image")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "keyboard-image-panel"
        shot.lifetime = .keepAlways
        add(shot)
        row.tap()
        XCTAssertFalse(row.exists)
        let output = app.staticTexts["output"].label
        XCTAssertTrue(output.hasPrefix("Touch and hold in the app, then tap Paste."), output)
        let measurement = XCTAttachment(string: output)
        measurement.name = "4032x3024-keyboard-host-memory"
        measurement.lifetime = .keepAlways
        add(measurement)
    }

    @MainActor func testNewExternalCopyKeepsTheSelectedTabAndCanBeInsertedInFull() {
        let app = XCUIApplication()
        app.launchArguments = ["--clipboard-panel", "--clipboard-automatic", "--no-swipe"]
        app.launch()
        let history = app.buttons["History"]
        history.tap()
        let dictations = app.buttons["keyboard.history.tab.dictations"]
        dictations.tap()
        app.buttons["Close recent dictations"].tap()

        let words = "Keyboard external selection." + String(repeating: "\nA paragraph with café and https://example.org.", count: 1800)
        UIPasteboard.general.string = words
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        history.tap()
        XCTAssertTrue(dictations.isSelected)
        app.buttons["keyboard.history.tab.clipboard"].tap()
        let saved = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Keyboard external selection.")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        saved.tap()
        XCTAssertTrue(app.staticTexts["output"].label == words, "Every character was inserted at the cursor")
    }

    func testNativeSaveAndCloseRespondAtThePanelEdges() {
        let app = XCUIApplication()
        app.launchArguments = ["--clipboard-panel", "--clipboard-save", "--no-swipe"]
        app.launch()
        app.buttons["History"].tap()
        let paste = app.buttons["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(paste.frame.height, 44)
        paste.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
        let saved = app.buttons.matching(NSPredicate(format: "label == %@", "new edge copy")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        let close = app.buttons["Close clipboard"]
        close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
        XCTAssertFalse(saved.exists)
    }

    func testLinkFirstCopyShowsThePassageAndInsertsTheOriginal() {
        let passage = Array(repeating: "Bluebirds return each spring.", count: 20).joined(separator: " ")
        let original = "https://example.com/field-notes\n\n" + passage
        let app = XCUIApplication()
        app.launchArguments = ["--clipboard-panel", "--no-swipe"]
        app.launchEnvironment["ZONE_TEST_SAVED_COPY"] = original
        app.launch()
        app.buttons["History"].tap()
        let row = app.buttons["keyboard.clipboard.row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.hasPrefix("Bluebirds return each spring."), row.label)
        XCTAssertEqual(row.value as? String, "Link and 80 words")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "keyboard-link-first-passage"
        shot.lifetime = .keepAlways
        add(shot)
        row.tap()
        XCTAssertEqual(app.staticTexts["output"].label, original)
    }

    func testOpenRecentAndInsertSavedTextAtTheCursor() {
        let app = XCUIApplication()
        app.launchArguments = ["--clipboard-panel", "--no-swipe", "--text", "Already typed: "]
        app.launch()
        app.buttons["History"].tap()
        let dictations = app.buttons["keyboard.history.tab.dictations"]
        XCTAssertGreaterThanOrEqual(dictations.frame.height, 44)
        XCTAssertGreaterThanOrEqual(app.buttons["Close clipboard"].frame.height, 44)
        dictations.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
        XCTAssertTrue(dictations.isSelected)
        app.buttons["keyboard.history.tab.clipboard"].tap()
        let row = app.buttons["keyboard.clipboard.row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "keyboard-clipboard-panel"
        shot.lifetime = .keepAlways
        add(shot)
        row.tap()
        XCTAssertEqual(app.staticTexts["output"].label, "Already typed: older saved copy")
        XCTAssertFalse(row.exists)
    }
}
