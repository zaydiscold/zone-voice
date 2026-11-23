// by zayd/cold @ zayd.wtf

import XCTest

/// Types probe strings through Apple's keyboard and records what lands in the field. This is a
/// measurement, not a pass/fail test: it writes `apple-smart-punctuation-NAME.json`, the
/// source of the table in `SmartPunctuationTests`. Run it when the iOS version changes.
final class AppleSmartPunctuationOracle: XCTestCase {
    static let probes: [String] = [
        // Double quotes
        "\"hi\"", "he said \"hi\"", "(\"hi\")", "[\"hi\"]", "a\"", "a \"", "\"\"", "say \"hi\".",
        "x=\"y\"", "a-\"b\"", "a/\"b\"", "5\"", "5'10\"", "\"'hi'\"", "a\n\"b\"", "a.\"b\"", "1\"2",
        // Apostrophes and single quotes
        "don't", "'hi'", "he said 'hi'", "'tis", "'90s", "the '90s", "rock 'n' roll", "dogs' toys",
        "a'", "''", "('a')", "5'", "a-'b'", "'em", "a 'b", "1'2",
        // Dashes
        "a--b", "a -- b", "a---b", "a --- b", "--", "---", "----", "a-b", "a - b", "-- ", "--a",
        "1--2", "a-- b", "a --b", "-->", "--flag",
        // Other candidates
        "...", "wait...", "(c)", "1/2", "->", "=>", "!=",
        // Code and addresses
        "https://a.com/?q=\"x\"", "me@a-b.com", "print(\"hi\")", "it's a \"test\"--ok",
    ]

    func testRecordDefaultTraits() throws { try record(args: [], name: "default") }
    func testRecordAutocorrectOff() throws { try record(args: ["--autocorrect-no"], name: "autocorrect-no") }
    func testRecordTraitsOff() throws { try record(args: ["--quotes-no", "--dashes-no"], name: "traits-no") }
    /// Which trait owns the ellipsis, and what the address keyboards do, on a short probe list.
    static let short = ["\"hi\"", "don't", "a--b", "a...", "1--2"]
    func testRecordQuotesOffOnly() throws { try record(args: ["--quotes-no"], name: "quotes-no", probes: Self.short) }
    func testRecordDashesOffOnly() throws { try record(args: ["--dashes-no"], name: "dashes-no", probes: Self.short) }
    func testRecordURLKeyboard() throws { try record(args: ["--kbd-url"], name: "kbd-url", probes: Self.short) }
    func testRecordEmailKeyboard() throws { try record(args: ["--kbd-email"], name: "kbd-email", probes: Self.short) }
    func testRecordSearchKeyboard() throws { try record(args: ["--kbd-search"], name: "kbd-search", probes: Self.short) }
    func testRecordTwitterKeyboard() throws { try record(args: ["--kbd-twitter"], name: "kbd-twitter", probes: Self.short) }

    /// One tap on Apple's software keyboard. `typeText` goes in as hardware keys, which skip
    /// smart punctuation entirely (measured 2026-11-14: 95 probes, none changed), so every
    /// character is a real key tap, switching planes the way a thumb would.
    private func tap(_ character: Character, in app: XCUIApplication) {
        // Keys are found by label. Measured on iOS 26.2: every key's label is its character
        // except the ampersand; the plane switch beside the numbers is a button, not a key.
        let name: String = character == " " ? "space" : character == "\n" ? "Return"
            : character == "&" ? "ampersand" : String(character)
        func press() -> Bool {
            for element in [app.keys[name], app.keyboards.buttons[name]] where element.exists {
                element.tap(); return true
            }
            return false
        }
        if press() { return }
        if app.keys["q"].exists {
            app.keys["more"].tap()                                   // letters to numbers
            if press() { return }
            app.keyboards.buttons["shift"].tap()                     // numbers to symbols
        } else {
            app.keyboards.buttons["shift"].tap()                     // numbers and symbols swap
            if press() { return }
            app.keys["more"].tap()                                   // back to letters
        }
        if !press() { XCTFail("no key for \(name)") }
    }

    private func record(args: [String], name: String, probes: [String] = AppleSmartPunctuationOracle.probes) throws {
        // A measurement, about four minutes a recording: it runs only when asked for by name,
        // with TEST_RUNNER_ORACLE_OUT set to the folder that receives the JSON.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ORACLE_OUT"] != nil, "set TEST_RUNNER_ORACLE_OUT to record")
        let app = XCUIApplication()
        app.launchArguments = ["--apple-oracle"] + args
        app.launch()
        let field = app.textViews["oracle"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertTrue(app.keys["more"].waitForExistence(timeout: 10), "the software keyboard must be showing")
        for dismiss in ["Continue", "Not Now"] where app.buttons[dismiss].exists { app.buttons[dismiss].tap() }
        var results: [[String: String]] = []
        for probe in probes {
            app.buttons["clear"].tap()
            for character in probe { tap(character, in: app) }
            results.append(["typed": probe, "apple": field.value as? String ?? ""])
            // Every probe starts from the letters plane, as a fresh message would.
            if !app.keys["q"].exists { app.keys["more"].tap() }
        }
        let data = try! JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        let dir = ProcessInfo.processInfo.environment["ORACLE_OUT"] ?? NSTemporaryDirectory()
        let url = URL(fileURLWithPath: dir).appendingPathComponent("apple-smart-punctuation-\(name).json")
        try! data.write(to: url)
        print("ORACLE WROTE \(url.path)")
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "apple-smart-punctuation-\(name)"; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
