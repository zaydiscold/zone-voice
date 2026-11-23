// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// Apple's guesses and completions as an extra source (`Autocorrector.systemGuesses`,
/// `systemCompletions`). The stubs answer what UITextChecker answered on the iOS 26.2 simulator
/// on 2026-11-08 (docs/research/2026-11-08-apple-input-audit/deep/spelling-output.jsonl).
final class SystemGuessTests: XCTestCase {
    static let apple: [String: [String]] = [
        "donuut": ["donut"], "glitchyy": ["glitchy"], "backemd": ["backed", "backend"],
        "medss": ["mess", "meds", "Medes"], "kist": ["list", "kiss"], "tomor": ["tom or", "tumor"],
        "teh": ["the", "tech"],
    ]
    private func corrector() -> Autocorrector {
        let c = Autocorrector(words: WordListTests.list)
        c.systemGuesses = { Self.apple[$0] ?? [] }
        return c
    }
    private func texts(_ c: Autocorrector, _ word: String) -> [String] { c.evaluate(word).suggestions.map(\.text) }

    func testAppleSuppliesTheAnswerZoneLacks() {
        let c = corrector()
        XCTAssertTrue(texts(c, "donuut").contains("donut"))
        XCTAssertTrue(texts(c, "glitchyy").contains("glitchy"))
        XCTAssertTrue(texts(c, "backemd").contains("backend"), "the second guess when the first is already shown")
        XCTAssertTrue(texts(c, "medss").contains("meds"))
    }
    func testAnAppleGuessIsNeverAppliedBySpace() {
        let c = corrector()
        for word in Self.apple.keys {
            let plain = Autocorrector(words: WordListTests.list).evaluate(word)
            XCTAssertEqual(c.evaluate(word).replacement, plain.replacement, word)
        }
    }
    func testZonesFirstTwoPlacesAreUntouched() {
        let c = corrector()
        for word in Self.apple.keys {
            let plain = Autocorrector(words: WordListTests.list).evaluate(word).suggestions
            let mixed = c.evaluate(word).suggestions
            XCTAssertEqual(Array(mixed.prefix(2)), Array(plain.prefix(2)), word)
            XCTAssertLessThanOrEqual(mixed.count, Autocorrector.maxSuggestions)
        }
    }
    func testTheLiteralStaysFirst() {
        XCTAssertEqual(corrector().evaluate("donuut").suggestions.first, Suggestion(text: "donuut", kind: .literal))
    }
    func testNoGuessIsAskedForWordsZoneKeeps() {
        var asked: [String] = []
        let c = Autocorrector(words: WordListTests.list)
        c.systemGuesses = { asked.append($0); return ["zzz"] }
        c.setPersonalWords(["Zaydish"])
        _ = c.evaluate("zaydish"); _ = c.evaluate("the"); _ = c.evaluate("gw"); _ = c.evaluate("kist"); _ = c.evaluate("NASAX")
        XCTAssertEqual(asked, [])
    }
    func testNoGuessWhenApplesDictionaryKnowsTheWord() {
        var asked = 0
        let c = Autocorrector(words: WordListTests.list)
        c.systemAccepts = { $0 == "glitchyy" }
        c.systemGuesses = { _ in asked += 1; return ["glitchy"] }
        _ = c.evaluate("glitchyy")
        XCTAssertEqual(asked, 0)
    }
    func testCapitalsFollowTheTypedWord() {
        XCTAssertTrue(texts(corrector(), "Donuut").contains("Donut"))
    }
    func testAppleCompletionOnlyWhereZoneHasNone() {
        let c = Autocorrector(words: WordListTests.list)
        var asked: [String] = []
        c.systemCompletions = { asked.append($0); return $0 == "zzyq" ? ["zzyqua", "zzyq", "other"] : ["WRONG"] }
        let own = c.evaluate("keybo").suggestions
        XCTAssertTrue(own.contains { $0.text == "keyboard" })
        XCTAssertFalse(own.contains { $0.text == "WRONG" })
        let filled = c.evaluate("zzyq").suggestions
        XCTAssertTrue(filled.contains(Suggestion(text: "zzyqua", kind: .completion)))
        XCTAssertFalse(filled.contains { $0.text == "other" })
        XCTAssertNil(c.evaluate("zzyq").replacement)
    }
}
