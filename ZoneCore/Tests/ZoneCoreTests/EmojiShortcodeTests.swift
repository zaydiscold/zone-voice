// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class EmojiShortcodeTests: XCTestCase {
    func testMissingCatalogDoesNotPublishAnEmptySearchIndex() {
        XCTAssertNil(EmojiSearchIndex.loadBundled(available: []))
        XCTAssertEqual(EmojiSearchIndex.loadBundled(available: ["🍕"])?.exact("pizza"), "🍕")
    }

    func testOrdinaryWordsRequireReviewedExactMeanings() throws {
        let catalog = try XCTUnwrap(EmojiCatalog.loadBundled())
        let available = Set(catalog.categories.flatMap { $0.emoji.map(\.text) })
        let search = try XCTUnwrap(EmojiSearchIndex.loadBundled(available: available))
        for (word, glyph) in ["PIZZA": "🍕", "sob": "😭", "fire": "🔥", "birthday": "🎂", "crying": "😭"] {
            XCTAssertEqual(search.prediction(word)?.emoji, glyph)
        }
        for word in ["pizz", "pizzaa", "frie", "in", "you", "nice", "face", "bank", "rather", "火"] {
            XCTAssertNil(search.prediction(word), word)
        }
        var history = EmojiHistory()
        history.use("😢", base: nil)
        XCTAssertEqual(search.prediction("crying", history: history)?.emoji, "😢")
        XCTAssertNil(EmojiSearchIndex(tsv: "🍕\tpizza", available: []).prediction("pizza"))
        XCTAssertTrue(try JSONDecoder().decode(KeyboardPreferences.self, from: Data("{}".utf8)).emojiPredictions)
    }

    func testBoundariesAndLiteralSyntax() throws {
        for prefix in ["3", "1/2", "note", "word.", "https", "https://example.org",
                       "`code ", "```swift\nprint(", "let x = ", "const values = [", "// "] {
            XCTAssertNil(EmojiShortcode(before: prefix, after: nil, selection: nil, hasText: true), prefix)
        }
        for prefix in ["", "Hi ", "Hi (", "Café 👋 ", "note: text "] {
            var code = try XCTUnwrap(EmojiShortcode(before: prefix, after: nil, selection: nil, hasText: !prefix.isEmpty))
            XCTAssertFalse(code.isSearchable)
            XCTAssertFalse(code.append(")"))
            XCTAssertFalse(code.append(" "))
            XCTAssertFalse(code.append("/"))
            XCTAssertTrue(code.append("D"))
            XCTAssertFalse(code.isSearchable)
            XCTAssertTrue(code.removeLast())
            XCTAssertFalse(code.removeLast())
        }
        XCTAssertNil(EmojiShortcode(before: nil, after: nil, selection: nil, hasText: true))
        XCTAssertNil(EmojiShortcode(before: "", after: "", selection: "selected", hasText: true))
        XCTAssertNil(EmojiShortcode(before: "Hi ", after: "word", selection: nil, hasText: true))
    }

    func testReplacementRequiresTheEntireTokenAndItsAnchor() throws {
        let prefix = String(repeating: "é👩🏽‍💻 ", count: 80)
        var code = try XCTUnwrap(EmojiShortcode(before: prefix, after: ") ok", selection: nil, hasText: true))
        for letter in "fire" { XCTAssertTrue(code.append(String(letter))) }
        XCTAssertTrue(code.owns(":fire", before: String(prefix.suffix(16)) + ":fire", after: ") ok", selection: nil))
        XCTAssertTrue(code.couldBeEcho(of: ":fire", before: prefix + ":fi", after: ") ok", selection: nil))
        XCTAssertFalse(code.owns(":fire", before: prefix + ":fi", after: ") ok", selection: nil))
        XCTAssertFalse(code.owns(":fire", before: prefix + ":fire", after: ") moved", selection: nil))
        XCTAssertFalse(code.owns(":fire", before: prefix + ":fire", after: ") ok", selection: "selection"))
        XCTAssertFalse(code.owns(":fire", before: ":fire", after: ") ok", selection: nil))
    }

    func testBundledAliasesKeywordsTyposAndSupport() throws {
        let catalog = try XCTUnwrap(EmojiCatalog.loadBundled())
        let available = Set(catalog.categories.flatMap { $0.emoji.map(\.text) })
        let before = MemoryFootprint.current()
        let clock = ProcessInfo.processInfo.systemUptime
        let search = try XCTUnwrap(EmojiSearchIndex.loadBundled(available: available))
        let loaded = MemoryFootprint.current()
        let loadTime = ProcessInfo.processInfo.systemUptime - clock
        XCTAssertGreaterThan(search.count, 1_900)
        XCTAssertEqual(search.matches("fi").first?.emoji, "🔥")
        XCTAssertEqual(search.exact("FIRE"), "🔥")
        XCTAssertEqual(search.exact("flame"), "🔥")
        XCTAssertEqual(search.exact("+1"), "👍")
        XCTAssertEqual(search.exact("flag_us"), "🇺🇸")
        XCTAssertEqual(search.exact("satisfied"), "😆")
        XCTAssertEqual(search.exact("octocat"), nil)
        XCTAssertTrue(search.matches("happy").contains { $0.emoji == "😄" })
        XCTAssertTrue(search.matches("frie").contains { $0.emoji == "🔥" })
        XCTAssertNil(search.exact("frie"))
        XCTAssertEqual(search.matches("PISA").first?.emoji, "🍕")
        XCTAssertNil(search.exact("pisa"))
        XCTAssertNil(search.prediction("Pisa"))
        XCTAssertNil(search.exact("happy"))
        XCTAssertTrue(search.matches("D").isEmpty)
        let searchStart = ProcessInfo.processInfo.systemUptime
        for query in ["fi", "fire", "happy", "frie", "thumbs", "coffee", "kwzz"] {
            _ = search.matches(query)
        }
        print("Emoji search: \(search.count) entries, footprint delta \(Int64(loaded ?? 0) - Int64(before ?? 0)) bytes, load \(Int(loadTime * 1_000)) ms, seven lookups \(Int((ProcessInfo.processInfo.systemUptime - searchStart) * 1_000)) ms")
        let unsupported = try XCTUnwrap(EmojiSearchIndex.loadBundled(available: ["😄"]))
        XCTAssertNil(unsupported.exact("fire"))
        XCTAssertEqual(unsupported.exact("smile"), "😄")
    }

    func testPersonalRankingAndRememberedToneSurviveLegacyHistory() throws {
        let search = EmojiSearchIndex(tsv: "🔥\tfire\thot\n❤️‍🔥\theart_on_fire\thot\n👍\tthumbsup|+1\tyes", available: ["🔥", "❤️‍🔥", "👍"])
        var history = try JSONDecoder().decode(EmojiHistory.self, from: Data(#"{"recents":["❤️‍🔥"],"tones":{"👍":"👍🏽"}}"#.utf8))
        XCTAssertEqual(search.matches("hot", history: history).first?.emoji, "❤️‍🔥")
        for _ in 0..<8 { history.use("🔥", base: nil) }
        history.use("❤️‍🔥", base: nil)
        history.use("👍🏽", base: "👍")
        history = try JSONDecoder().decode(EmojiHistory.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(search.matches("hot", history: history).first?.emoji, "🔥")
        let thumb = Emoji(text: "👍", version: 1.0, tones: [.init(text: "👍🏽", version: 1.0)])
        XCTAssertEqual(history.shown(thumb), "👍🏽")
    }

    /// ":us" showed two territories' flags ahead of the United States: a two-letter code that is
    /// a flag's own code comes before flags that only mention it, and after ordinary names.
    func testACountryCodeShowsThatCountrysFlagBeforeFlagsThatMentionIt() throws {
        let catalog = try XCTUnwrap(EmojiCatalog.loadBundled())
        let search = try XCTUnwrap(EmojiSearchIndex.loadBundled(available: Set(catalog.categories.flatMap { $0.emoji.map(\.text) })))
        XCTAssertEqual(search.matches("us").first?.emoji, "🇺🇸")
        XCTAssertEqual(search.matches("jp").first?.emoji, "🇯🇵")
        XCTAssertEqual(search.matches("fi").map(\.emoji), ["🔥", "✊", "🐟"], "ordinary names still come first")
        XCTAssertEqual(search.matches("sm").first?.emoji, "😄")
    }

    func testWhatMustNeverOpenAPickerOrConvert() throws {
        for (before, after) in [("3", ""), ("at 3", ""), ("12", ""), ("https", ""), ("mailto", ""), ("note", ""), ("std:", ""),
                                ("Hi,", ""), ("\"", ""), ("Hi ", "there"), ("x = y ?", "")] {
            XCTAssertNil(EmojiShortcode(before: before, after: after, selection: nil, hasText: true), before + "|" + after)
        }
        var code = try XCTUnwrap(EmojiShortcode(before: "ok ", after: "", selection: nil, hasText: true))
        // A face, a time and a ratio typed after an opening colon end the code at once.
        for stop in [")", "(", "/", " ", "'", ".", ":"] { XCTAssertFalse(code.append(stop), stop) }
        // One letter is ":D" or ":P", never a search.
        XCTAssertTrue(code.append("D"))
        XCTAssertFalse(code.isSearchable)
        // 48 bytes of name is the most a code holds.
        for _ in 0..<60 { _ = code.append("a") }
        XCTAssertLessThanOrEqual(code.literal.utf8.count, 49)
        XCTAssertFalse(code.append("a"))
    }
}
