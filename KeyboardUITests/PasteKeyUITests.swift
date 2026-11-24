// by zayd/cold @ zayd.wtf

import UIKit
import XCTest

final class PasteKeyUITests: XCTestCase {
    func testNativePasteSurvivesAppearanceChangeAndAReleaseOutside() {
        let app = XCUIApplication()
        app.launchArguments = ["--paste-key", "--no-swipe"]
        app.launch()
        let paste = app.buttons["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        capture(app, "light-empty")
        app.buttons["Copy test text"].tap()
        capture(app, "light-text")

        app.buttons["Appearance"].tap()
        capture(app, "dark-after-live-appearance-change")
        guard paste.isHittable else {
            XCTFail("The native control lost its slot on an appearance change")
            return
        }
        let start = paste.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let outside = app.staticTexts["ready"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.2, thenDragTo: outside, withVelocity: .slow, thenHoldForDuration: 0.02)
        XCTAssertFalse(app.staticTexts["clipboard sample"].exists)
        capture(app, "dark-released-outside")

        paste.tap()
        XCTAssertTrue(app.staticTexts["clipboard sample"].waitForExistence(timeout: 5))
        app.buttons["Clear clipboard"].tap()
        assertPasteCapMatchesReturn(in: app, name: "dark-empty")

        app.buttons["Toggle Paste"].tap()
        XCTAssertFalse(paste.exists)
        capture(app, "dark-setting-off")
        app.buttons["Toggle Paste"].tap()
        XCTAssertTrue(paste.isHittable)
        capture(app, "dark-setting-on")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(paste.isHittable)
        capture(app, "dark-landscape")
    }

    func testDarkPasteAtLaunchWithEmptyAndFullClipboard() {
        let app = XCUIApplication()
        app.launchArguments = ["--paste-key", "--dark-paste", "--no-swipe"]
        app.launch()
        let paste = app.buttons["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        assertPasteCapMatchesReturn(in: app, name: "dark-launch-empty")
        app.buttons["Copy test text"].tap()
        assertPasteCapMatchesReturn(in: app, name: "dark-launch-text")
        paste.tap()
        XCTAssertTrue(app.staticTexts["clipboard sample"].waitForExistence(timeout: 5))
        app.buttons["Clear clipboard"].tap()
    }

    // MARK: Review of 2026-11-21

    /// A thumb lands on Paste and rolls a few points off its edge before lifting. Every other
    /// key still types there; Paste did nothing, because a lift outside its exact bounds was
    /// treated as a release somewhere else.
    func testALiftThatDriftsJustOffThePasteKeyStillPastes() {
        for (name, edge, drift) in [("leading", CGVector(dx: 0, dy: 0.5), CGVector(dx: -2, dy: 0)),
                                    ("trailing", CGVector(dx: 1, dy: 0.5), CGVector(dx: 2, dy: 0))] {
            let app = pasteHost()
            let paste = app.buttons["Paste"]
            let start = paste.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = paste.coordinate(withNormalizedOffset: edge).withOffset(drift)
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.02)
            XCTAssertTrue(app.staticTexts["clipboard sample"].waitForExistence(timeout: 3), "\(name) drift pasted nothing")
            capture(app, "drift-\(name)")
            app.terminate()
        }
    }

    /// A tap in the gap beside Paste belongs to Paste, as a tap in the gap beside any key
    /// belongs to the nearest key.
    func testATapInTheGapBesideThePasteKeyPastes() {
        let app = pasteHost()
        let paste = app.buttons["Paste"]
        paste.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: -2, dy: 0)).tap()
        XCTAssertTrue(app.staticTexts["clipboard sample"].waitForExistence(timeout: 3), "a tap 2 pt off the key pasted nothing")
    }

    /// A lift on another key is still a release somewhere else: nothing pastes, nothing types.
    func testALiftOnReturnOrSpaceAfterPressingPasteDoesNothing() {
        let app = pasteHost()
        let paste = app.buttons["Paste"]
        for target in ["return", "Space"] {
            paste.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: app.buttons[target].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                       withVelocity: .slow, thenHoldForDuration: 0.02)
            XCTAssertFalse(app.staticTexts["clipboard sample"].waitForExistence(timeout: 1), target)
        }
        XCTAssertEqual(app.staticTexts["caret"].label, "Cursor: 0", "nothing was typed")
    }

    /// The glyph, not only the cap: a Paste key whose cap matches its neighbors but shows no
    /// clipboard picture is the blank key Zayd reported. Checked with text to paste, in each look.
    func testThePasteKeyShowsItsGlyphInLightAndDark() {
        for dark in [false, true] {
            let app = pasteHost(dark: dark)
            assertGlyphVisible(in: app, name: dark ? "glyph-dark" : "glyph-light")
            app.buttons["Appearance"].tap()
            assertGlyphVisible(in: app, name: dark ? "glyph-dark-then-light" : "glyph-light-then-dark")
            app.buttons["Appearance"].tap()
            app.buttons["Appearance"].tap()
            assertGlyphVisible(in: app, name: dark ? "glyph-dark-flipped-twice" : "glyph-light-flipped-twice")
            app.terminate()
        }
    }

    func testReleaseBeyondTheGridBottomCancels() {
        let app = pasteHost()
        let paste = app.buttons["Paste"]
        let center = paste.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let below = paste.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1)).withOffset(CGVector(dx: 0, dy: 6))
        center.press(forDuration: 0.1, thenDragTo: below)
        XCTAssertFalse(app.staticTexts["clipboard sample"].waitForExistence(timeout: 1))
    }

    private func pasteHost(dark: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--paste-key", "--no-swipe"] + (dark ? ["--dark-paste"] : [])
        app.launch()
        XCTAssertTrue(app.buttons["Paste"].waitForExistence(timeout: 5))
        app.buttons["Copy test text"].tap()
        let enabled = NSPredicate(format: "enabled == true")
        let ready = XCTNSPredicateExpectation(predicate: enabled, object: app.buttons["Paste"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        return app
    }

    /// Some pixel in the middle of the key differs clearly from the cap's fill near its top.
    private func assertGlyphVisible(in app: XCUIApplication, name: String) {
        let shot = app.screenshot()
        capture(app, name, screenshot: shot)
        guard let image = shot.image.cgImage else { return XCTFail("Missing screenshot pixels") }
        let scale = CGFloat(image.width) / app.frame.width
        let paste = app.buttons["Paste"].frame
        guard let fill = rgb(in: image, x: paste.midX * scale, y: (paste.minY + 5) * scale) else { return XCTFail("Missing cap pixel") }
        var strongest = 0
        for dx in stride(from: -10.0, through: 10.0, by: 1) {
            for dy in stride(from: -11.0, through: 11.0, by: 1) {
                guard let pixel = rgb(in: image, x: (paste.midX + dx) * scale, y: (paste.midY + dy) * scale) else { continue }
                strongest = max(strongest, zip(pixel, fill).map { abs(Int($0) - Int($1)) }.max() ?? 0)
            }
        }
        XCTAssertGreaterThan(strongest, 60, "\(name): no glyph stands out from the cap (strongest difference \(strongest) of 255)")
    }

    private func assertPasteCapMatchesReturn(in app: XCUIApplication, name: String) {
        let shot = app.screenshot()
        capture(app, name, screenshot: shot)
        guard let image = shot.image.cgImage else { return XCTFail("Missing screenshot pixels") }
        let scale = CGFloat(image.width) / app.frame.width
        let paste = app.buttons["Paste"].frame
        let enter = app.buttons["return"].frame
        guard let pasteFill = rgb(in: image, x: paste.midX * scale, y: (paste.minY + 7) * scale),
              let returnFill = rgb(in: image, x: enter.midX * scale, y: (enter.minY + 7) * scale) else {
            return XCTFail("Missing cap pixels")
        }
        for (pasteChannel, returnChannel) in zip(pasteFill, returnFill) {
            XCTAssertEqual(Double(pasteChannel), Double(returnChannel), accuracy: 2, name)
        }
    }

    private func rgb(in image: CGImage, x: CGFloat, y: CGFloat) -> [UInt8]? {
        guard let pixel = image.cropping(to: CGRect(x: floor(x), y: floor(y), width: 1, height: 1)) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        return bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return Array(raw.prefix(3))
        }
    }

    private func capture(_ app: XCUIApplication, _ name: String, screenshot: XCUIScreenshot? = nil) {
        let attachment = XCTAttachment(screenshot: screenshot ?? app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
