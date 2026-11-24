// by zayd/cold @ zayd.wtf

import XCTest

/// Clipboard history in the app: off until it is turned on, the Clipboard section in History
/// with the newest copies and one search over dictations and copies, the Clipboard screen with
/// its settings, deletes that ask, and what the Save to Zone Clipboard shortcut does.
/// The copies are seeded with `-zoneClipboardSeed` (`ClipboardDebug`), oldest first.
final class ClipboardHistoryUITests: XCTestCase {
    private var settled: [String] {
        let version = Bundle(for: Self.self).infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.5"
        return ["-zone.settings.onboardingDone", "YES", "-zone.tour.seen", "YES", "-zoneWhatsNewAfter", version,
                "-zoneClipboardClear"]
    }
    private let on = ["-zone.settings.clipboardHistory", "<true/>"]
    private let off = ["-zone.settings.clipboardHistory", "<false/>"]
    private let seed = ["-zoneClipboardSeed", "Pick up the dry cleaning before six|https://example.com/menu|Gate code is on the fridge|Call Dana about the deck"]

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = settled + extra
        app.launch()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 30), "Home")
        return app
    }

    private func openHistory(_ app: XCUIApplication) {
        app.buttons["History"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 10), "History")
    }

    private func openClipboard(_ app: XCUIApplication) {
        openHistory(app)
        let all = app.descendants(matching: .any)["history.clipboard.all"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 10), "the way to all copies")
        all.tap()
        XCTAssertTrue(app.navigationBars["Clipboard"].waitForExistence(timeout: 10), "the Clipboard screen")
    }

    private func keepScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func text(_ app: XCUIApplication, _ words: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !(element.exists && element.isHittable) { app.swipeUp() }
    }

    @MainActor
    func testOptingInAutomaticallySavesExternalTextAndAnImage() {
        let app = launch(on + ["-zone.settings.clipboardAutomatic", "<false/>"])
        openClipboard(app)
        let toggle = app.switches["clipboard.automatic"]
        scrollTo(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "0")
        let marker = "Automatic clipboard fixture."
        UIPasteboard.general.string = marker + String(repeating: "\nParagraph with café and 中文.", count: 3_000)
        if toggle.switches.firstMatch.exists { toggle.switches.firstMatch.tap() } else { toggle.tap() }
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        XCTAssertTrue(text(app, marker).waitForExistence(timeout: 10))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { ctx in
            UIColor.green.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        UIPasteboard.general.image = image
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        XCTAssertTrue(app.buttons["clipboard.image"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testImmediateNativePastesKeepThreeExternalCopies() {
        let app = launch(on + ["-zone.settings.clipboardSkipsSecrets", "<false/>"])
        openClipboard(app)
        let paste = app.buttons["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        let words = ["External copy one", "481516", "External copy three"]
        for value in words {
            UIPasteboard.general.string = value
            paste.tap()
        }
        for value in words {
            XCTAssertTrue(text(app, value).waitForExistence(timeout: 5), value)
        }
        keepScreenshot("three-external-copies")
    }

    func testSavingAnImageShowsItsThumbnail() {
        let app = launch(on + ["-zoneClipboardImage"])
        openClipboard(app)
        app.buttons["Paste"].tap()
        XCTAssertTrue(app.buttons["clipboard.image"].waitForExistence(timeout: 10))
        let row = app.buttons["clipboard.image"]
        // The fixture is a green leaf. Verify that its pixels reached the row.
        let leaf = NSPredicate { _, _ in
            guard let image = row.screenshot().image.cgImage else { return false }
            let w = 64, h = 32
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            return pixels.withUnsafeMutableBytes { bytes in
                guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                              bytesPerRow: 4 * w, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return stride(from: 0, to: bytes.count, by: 4).contains {
                    Int(bytes[$0 + 1]) > max(Int(bytes[$0]), Int(bytes[$0 + 2])) + 40
                }
            }
        }
        let rendered = expectation(for: leaf, evaluatedWith: nil)
        wait(for: [rendered], timeout: 10)
        keepScreenshot("clipboard-image-list")
        app.buttons["clipboard.image"].press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Share"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Pin"].exists)
        keepScreenshot("clipboard-image-hold")
        app.buttons["Delete"].tap()
        XCTAssertTrue(app.buttons["Delete copy"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["clipboard.image"].exists)
        app.buttons["clipboard.image"].tap()
        XCTAssertTrue(app.images["Saved image"].waitForExistence(timeout: 10))
        app.buttons["Copy image"].tap()
        XCTAssertTrue(app.buttons["Copied"].exists)
        app.buttons["Keep until I delete it"].tap()
        XCTAssertTrue(app.buttons["Stop keeping"].exists)
        keepScreenshot("clipboard-image-detail")
        app.terminate()
        app.launchArguments.removeAll { $0 == "-zoneClipboardClear" || $0 == "-zoneClipboardImage" }
        app.launch()
        openClipboard(app)
        app.buttons["clipboard.image"].tap()
        XCTAssertTrue(app.buttons["Stop keeping"].waitForExistence(timeout: 10))
        app.buttons["Delete image"].tap()
        app.buttons["Delete copy"].tap()
        XCTAssertTrue(app.buttons["clipboard.image"].waitForNonExistence(timeout: 10))
    }

    func testHistoryShowsTheNewestCopiesAndOneSearchFindsAnOlderOne() {
        let app = launch(on + seed)
        openHistory(app)
        XCTAssertTrue(app.staticTexts["Clipboard"].waitForExistence(timeout: 10), "the Clipboard section")
        XCTAssertTrue(text(app, "Call Dana about the deck").waitForExistence(timeout: 10), "the newest copy")
        XCTAssertTrue(text(app, "Gate code is on the fridge").exists)
        XCTAssertTrue(text(app, "https://example.com/menu").exists)
        XCTAssertFalse(text(app, "Pick up the dry cleaning").exists, "only the newest three sit in History")
        XCTAssertTrue(text(app, "All 4 copies").exists, "the rest are one tap away")
        XCTAssertTrue(app.buttons["Copy saved text"].firstMatch.isHittable, "Copy is on the row")
        keepScreenshot("history-clipboard-section")

        // One search field covers dictations and copies.
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the search field")
        field.tap()
        field.typeText("dry cleaing")
        XCTAssertTrue(text(app, "Pick up the dry cleaning before six").waitForExistence(timeout: 10), "the older copy is found")
        XCTAssertFalse(text(app, "Call Dana about the deck").exists, "copies that do not match are gone")
        keepScreenshot("history-search-finds-a-copy")
    }

    @MainActor
    func testLinkFirstCopyShowsThePassageAndOpensTheOriginal() {
        let passage = Array(repeating: "Bluebirds return each spring.", count: 20).joined(separator: " ")
        let original = "https://example.com/field-notes\n\n" + passage
        let app = launch(on)
        openClipboard(app)
        UIPasteboard.general.string = original
        app.buttons["Paste"].tap()
        let row = text(app, "Bluebirds return each spring.")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(text(app, "Link and 80 words").exists)
        keepScreenshot("app-link-first-passage")
        row.tap()
        let full = app.staticTexts["clip.text"]
        XCTAssertTrue(full.waitForExistence(timeout: 10))
        XCTAssertEqual(full.label, original)
    }

    func testACopyOpensInFullAndCopyingItSaysSo() {
        let app = launch(on + seed)
        openHistory(app)
        let row = text(app, "Gate code is on the fridge")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.navigationBars["Copy"].waitForExistence(timeout: 10), "the copy in full")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "pasted with Zone")).firstMatch.exists)
        keepScreenshot("copy-sheet")
        app.buttons["clip.more"].tap()
        XCTAssertTrue(app.buttons["Keep until I delete it"].exists)
        let hasPairedComputer = app.buttons["Send to computer"].exists
        XCTAssertTrue(app.buttons[hasPairedComputer ? "Add to Notes and sync" : "Add to Notes"].exists)
        app.buttons["Keep until I delete it"].tap()
        app.buttons["clip.more"].tap()
        XCTAssertTrue(app.buttons["Stop keeping"].waitForExistence(timeout: 5))
        app.buttons["Stop keeping"].tap()
        app.buttons["clip.copy"].tap()
        XCTAssertEqual(app.buttons["clip.copy"].label, "Copied")
        app.buttons["clip.more"].tap()
        app.buttons["Keep until I delete it"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(text(app, "Kept").waitForExistence(timeout: 10), "the row says it is kept")
    }

    func testDeleteAllAsksFirstAndThenTheListIsEmpty() {
        let app = launch(on + seed)
        openClipboard(app)
        XCTAssertTrue(text(app, "Pick up the dry cleaning before six").waitForExistence(timeout: 10), "all four are here")
        keepScreenshot("clipboard-screen")
        let deleteAll = app.buttons["Delete all copies"]
        scrollTo(deleteAll, in: app)
        keepScreenshot("clipboard-settings")
        deleteAll.tap()
        let confirm = app.buttons["Delete all"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "deleting asks first")
        XCTAssertTrue(text(app, "Call Dana about the deck").exists || text(app, "Pick up the dry cleaning").exists
                      || app.staticTexts["Delete all copies?"].exists, "nothing is gone before the answer")
        confirm.tap()
        XCTAssertTrue(app.staticTexts["No copies yet"].waitForExistence(timeout: 10), "the list is empty")
        XCTAssertFalse(text(app, "Call Dana about the deck").exists)
    }

    func testARowsDeleteAsksFirst() {
        let app = launch(on + seed)
        openClipboard(app)
        let row = text(app, "Call Dana about the deck")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.press(forDuration: 1.2)
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "the row's menu")
        XCTAssertTrue(app.buttons["Pin"].exists, "Pin is in the menu too")
        keepScreenshot("clipboard-hold")
        delete.tap()
        let confirm = app.buttons["Delete copy"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the delete asks")
        confirm.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 10), "the copy is gone")
        XCTAssertTrue(text(app, "Gate code is on the fridge").exists, "the others stay")
    }

    func testSwipedCopyCanBeKeptOrDeletedFromEitherList() {
        let app = launch(on + seed)
        openHistory(app)
        let row = text(app, "Call Dana about the deck")
        row.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Delete copy"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(row.exists)

        app.descendants(matching: .any)["history.clipboard.all"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Clipboard"].waitForExistence(timeout: 10))
        row.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        app.buttons["Delete copy"].tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 10))
        XCTAssertTrue(text(app, "Gate code is on the fridge").exists)
    }

    func testOffByDefaultAndOneSwitchTurnsItOn() {
        let app = launch(off)
        app.buttons["home.settings"].tap()
        let data = app.buttons["settings.yourData"]
        for _ in 0..<10 where !data.isHittable { app.swipeUp() }
        data.tap()
        let row = app.descendants(matching: .any)["settings.clipboard"].firstMatch
        for _ in 0..<10 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.isHittable, "the Clipboard history row in Your data")
        XCTAssertEqual(row.label, "Clipboard history")
        row.tap()
        XCTAssertTrue(app.navigationBars["Clipboard"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Keep what you copy"].exists, "what it is, before it is on")
        XCTAssertFalse(app.switches["clipboard.skipSecrets"].exists, "nothing else to set while it is off")
        keepScreenshot("clipboard-off")
        let toggle = app.switches["clipboard.switch"]
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        XCTAssertTrue(app.staticTexts["No copies yet"].waitForExistence(timeout: 10), "on, and empty")
        let secrets = app.switches["clipboard.skipSecrets"]
        XCTAssertTrue(secrets.waitForExistence(timeout: 5))
        XCTAssertEqual(secrets.value as? String, "0", "the password filter starts off")
        XCTAssertTrue(app.staticTexts["30 days"].exists || text(app, "30 days").exists, "kept for 30 days by default")
        keepScreenshot("clipboard-on-empty")
    }

    func testSaveControlPrecedesTheCopies() {
        // This case exercises the own-copy marker. Only the enabled privacy filter rejects it.
        let app = launch(on + seed + ["-zone.settings.clipboardSkipsSecrets", "<true/>"])
        openClipboard(app)
        XCTAssertTrue(app.staticTexts["Save what is copied now"].isHittable)
        let paste = app.buttons["Paste"].firstMatch
        XCTAssertTrue(paste.exists)
        keepScreenshot("clipboard-save")
        app.buttons["Copy saved text"].firstMatch.tap()
        XCTAssertTrue(paste.isHittable)
        paste.tap()
        XCTAssertTrue(app.staticTexts["That is already in Zone."].waitForExistence(timeout: 5),
                      "a native paste delivered the text and its own-copy marker")
    }

    func testTheShortcutKeepsTextAndSkipsACode() {
        let kept = launch(on + ["-zoneClipboardShortcut", "Sent from the Action Button"])
        openClipboard(kept)
        XCTAssertTrue(text(kept, "Sent from the Action Button").waitForExistence(timeout: 10), "the shortcut's text is in the list")
        kept.terminate()

        let skipped = launch(on + ["-zone.settings.clipboardSkipsSecrets", "<true/>", "-zoneClipboardShortcut", "481516"])
        openClipboard(skipped)
        XCTAssertTrue(skipped.staticTexts["No copies yet"].waitForExistence(timeout: 10), "a code is not kept")
        let tally = skipped.descendants(matching: .any)["clipboard.tally"].firstMatch
        scrollTo(tally, in: skipped)
        XCTAssertTrue(tally.exists, "and the screen says one was not kept")
        XCTAssertTrue(tally.label.contains("1 that looked like a password or code"), tally.label)
        XCTAssertFalse(text(skipped, "481516").exists, "without its text")
    }

    // MARK: History's search with notes (the Notes branch's Everything scope)

    /// A word in a kept copy and in a note, searched in History.
    private let fridgeNote = ["-zoneNotesAdd", "Fridge filter needs changing before the guests come"]

    @discardableResult
    private func searchHistory(_ app: XCUIApplication, _ words: String) -> XCUIElement {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "History's search field")
        field.tap()
        field.typeText(words)
        return field
    }

    private func noteRow(_ app: XCUIApplication, _ words: String) -> XCUIElement {
        app.buttons.matching(identifier: "note.row").matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
    }

    /// On: History's own search still finds the copy, says a note has the word too, and under
    /// Everything lists the note while the copy stays.
    func testHistorySearchFindsTheCopyAndEverythingAddsTheNote() {
        let app = launch(on + seed + fridgeNote)
        openHistory(app)
        searchHistory(app, "fridge")
        XCTAssertTrue(text(app, "Gate code is on the fridge").waitForExistence(timeout: 10), "the copy is found in History")
        let elsewhere = app.buttons["search.elsewhere"]
        XCTAssertTrue(elsewhere.waitForExistence(timeout: 15), "History says another list has the word")
        XCTAssertTrue(elsewhere.label.contains("note"), elsewhere.label)
        XCTAssertFalse(noteRow(app, "Fridge filter").exists, "the note itself is listed only under Everything")
        elsewhere.tap()
        XCTAssertTrue(noteRow(app, "Fridge filter").waitForExistence(timeout: 10), "Everything lists the note")
        XCTAssertTrue(text(app, "Gate code is on the fridge").exists, "and the copy is still there")
        keepScreenshot("history-everything-copy-and-note")
    }

    /// Off: copies already in the store never show in History, under either scope, while the
    /// note with the same word still does.
    func testHistorySearchShowsNoCopiesWhileClipboardHistoryIsOff() {
        let app = launch(off + seed + fridgeNote)
        openHistory(app)
        XCTAssertFalse(text(app, "Call Dana about the deck").exists, "no copies sit in History while it is off")
        let field = searchHistory(app, "fridge")
        XCTAssertEqual(field.placeholderValue, "Search your dictations", "the field does not offer copies")
        let elsewhere = app.buttons["search.elsewhere"]
        XCTAssertTrue(elsewhere.waitForExistence(timeout: 15), "the note is still counted")
        XCTAssertFalse(text(app, "Gate code is on the fridge").exists, "the copy is not found")
        elsewhere.tap()
        XCTAssertTrue(noteRow(app, "Fridge filter").waitForExistence(timeout: 10), "Everything lists the note")
        XCTAssertFalse(text(app, "Gate code is on the fridge").exists, "and still no copy")
        keepScreenshot("history-everything-clipboard-off")
    }
}
