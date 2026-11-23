// by zayd/cold @ zayd.wtf

import XCTest

/// The phone's half of an end-to-end check against a real `zone` on this Mac. Not run with the
/// suite: each test skips unless `TEST_RUNNER_ZONE_E2E=1`, and expects the simulator's Zone to be
/// paired already with a running throwaway computer (AGENTS.md, "Zone Link"). Run one step at
/// a time with `-only-testing:` and check the computer between them (`zone clip`, `zone list`,
/// `zone events --json`). `TEST_RUNNER_ZONE_E2E_TEXT` is the text a step sends.
final class LinkComputerEndToEndUITests: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard environment["ZONE_E2E"] == "1" else {
            throw XCTSkip("set TEST_RUNNER_ZONE_E2E=1 with a computer paired to run this against it")
        }
    }

    private var version: String {
        Bundle(for: Self.self).infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.4"
    }

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-zoneWhatsNewAfter", version] + extra
        app.launch()
        return app
    }

    private func text(_ fallback: String) -> String { environment["ZONE_E2E_TEXT"] ?? fallback }

    /// Opens Send text from the Computers screen.
    private func openSendText(_ app: XCUIApplication) {
        let row = app.buttons["computers.sendText"]
        XCTAssertTrue(row.waitForExistence(timeout: 60), "the Computers screen")
        row.tap()
        let done = app.buttons["clips.done"]
        if !done.waitForExistence(timeout: 5) { row.tap() }
        XCTAssertTrue(done.waitForExistence(timeout: 10), "Send text opens")
    }

    private func waitForSent(_ app: XCUIApplication) {
        let message = app.staticTexts["clips.message"]
        let sent = expectation(for: NSPredicate(format: "label BEGINSWITH 'Sent to'"), evaluatedWith: message)
        wait(for: [sent], timeout: 40)
    }

    /// Types a text into Send text and sends it.
    func testTypedClip() {
        let app = launch(["-zoneLinkComputers"])
        openSendText(app)
        let field = app.descendants(matching: .any)["clips.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(text("https://example.com/builds/42 is ready"))
        app.buttons["clips.send"].tap()
        waitForSent(app)
        XCTAssertTrue(app.staticTexts["clips.message"].label.contains("Studio Mac"), app.staticTexts["clips.message"].label)
    }

    /// Puts a text on the clipboard and sends it with the system Paste button.
    func testPastedClip() {
        UIPasteboard.general.string = text("ssh studio@10.0.0.7")
        let app = launch(["-zoneLinkComputers"])
        openSendText(app)
        let paste = app.buttons["clips.paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 10))
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: paste)
        wait(for: [enabled], timeout: 10)
        paste.tap()
        waitForSent(app)
    }

    /// Deletes the newest dictation in History, then gives the sync time to go.
    func testDeleteNewestDictation() {
        let app = launch([])
        let all = app.buttons["See all dictation history"]
        XCTAssertTrue(all.waitForExistence(timeout: 20), "History on Home")
        all.tap()
        let first = app.cells.element(boundBy: 0)
        XCTAssertTrue(first.waitForExistence(timeout: 10), "a dictation in History")
        let row = app.cells.containing(NSPredicate(format: "label CONTAINS 'Sample'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let label = row.label
        add(XCTAttachment(string: label))
        print("zoneE2E deleting: \(label)")
        row.swipeLeft()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        // A change goes a few seconds later (`LinkCoordinator.changeDelay`), then the session.
        Thread.sleep(forTimeInterval: 15)
    }

    /// Turns on Keep what I delete here, or off with `TEST_RUNNER_ZONE_E2E_KEEP=0`.
    func testKeepWhatIsDeleted() {
        let app = launch(["-zoneLinkComputers"])
        let keep = app.switches["computers.keepDeleted"]
        XCTAssertTrue(keep.waitForExistence(timeout: 60))
        let wanted = environment["ZONE_E2E_KEEP"] == "0" ? "0" : "1"
        if keep.value as? String != wanted {
            keep.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        let settled = expectation(for: NSPredicate(format: "value == %@", wanted), evaluatedWith: keep)
        wait(for: [settled], timeout: 5)
    }
}
