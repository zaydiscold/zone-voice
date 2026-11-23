// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// Tap autocorrect reads an unknown word against the word before it, with the word-pair table
/// swipe typing ships (`Autocorrector.context`).
final class PreviousWordAutocorrectTests: XCTestCase {
    private func correctors() throws -> (plain: Autocorrector, contextual: Autocorrector) {
        let pairs = try XCTUnwrap(TypoEvaluationTests.pairs, "en-pairs.bin is missing or was built from another word list")
        let contextual = Autocorrector(words: WordListTests.list)
        contextual.context = pairs
        return (Autocorrector(words: WordListTests.list), contextual)
    }

    private func fix(_ corrector: Autocorrector, _ typed: String, after previous: String?) -> String {
        corrector.evaluate(typed, previous: previous).replacement ?? typed
    }

    /// The same typo after two different words: the word before says which was meant.
    func testThePreviousWordSettlesACloseCall() throws {
        let (plain, contextual) = try correctors()
        for (previous, typed, wanted) in [
            ("the", "fpod", "food"), ("so", "fpod", "good"),
            ("an", "houe", "hour"), ("my", "houe", "house"),
            ("in", "bes", "bed"), ("the", "bes", "best"),
            ("you", "wat", "want"), ("us", "wat", "what"),
            ("the", "soor", "door"), ("really", "kobg", "long"), ("by", "noom", "noon"),
            ("got", "iff", "off"), ("tell", "hee", "her"), ("a", "vit", "bit"), ("you", "hwar", "hear"),
        ] {
            XCTAssertEqual(fix(contextual, typed, after: previous), wanted, "\(previous) \(typed)")
        }
        // Without the table none of the pairs above can be told apart.
        XCTAssertEqual(fix(plain, "fpod", after: "the"), fix(plain, "fpod", after: "so"))
        XCTAssertEqual(fix(plain, "houe", after: "an"), "house")
        XCTAssertEqual(fix(plain, "bes", after: "in"), "best")
    }

    /// Fixes that needed no help keep working after any word.
    func testAClearFixStaysAfterAnyWord() throws {
        let (_, contextual) = try correctors()
        for (previous, typed, wanted) in [("i", "lovr", "love"), ("to", "fic", "fix"), ("thank", "yoi", "you"), ("of", "thr", "the"),
                                           ("all", "thr", "the"), ("i", "wsnt", "want"), ("how", "abiut", "about"), ("see", "yiu", "you")] {
            XCTAssertEqual(fix(contextual, typed, after: previous), wanted, "\(previous) \(typed)")
        }
    }

    /// No previous word, a previous word the list does not have, or no table: exactly as before.
    func testWithoutAPreviousWordNothingChanges() throws {
        let (plain, contextual) = try correctors()
        for item in TypoEvaluationSet.cases {
            let expected = plain.evaluate(item.typed, autoCapitalized: item.autoCapitalized)
            XCTAssertEqual(contextual.evaluate(item.typed, autoCapitalized: item.autoCapitalized).suggestions, expected.suggestions, item.typed)
            XCTAssertEqual(contextual.evaluate(item.typed, autoCapitalized: item.autoCapitalized, previous: "zqxjk").suggestions, expected.suggestions, item.typed)
            XCTAssertEqual(plain.evaluate(item.typed, autoCapitalized: item.autoCapitalized, previous: "the").suggestions, expected.suggestions, item.typed)
        }
    }

    /// A word the keyboard accepts is never traded for a likelier one: context ranks the
    /// candidates for a word it does not know, and (since the next-word row, November 18) which
    /// longer words are offered as completions. Completions are never armed, so what stays
    /// pinned here is everything a separator can act on: the typed word, any correction, and
    /// that nothing replaces it.
    func testAKnownWordIsNeverChangedByContext() throws {
        let (plain, contextual) = try correctors()
        for sentence in TypoEvaluationSet.sentences + TypoEvaluationSet.heldOutSentences {
            var previous: String?
            for word in sentence.split(separator: " ").map(String.init) {
                defer { previous = word }
                guard WordListTests.list.lookup(word) != nil else { continue }
                let withContext = contextual.evaluate(word, previous: previous), without = plain.evaluate(word)
                XCTAssertEqual(withContext.suggestions.filter { $0.kind != .completion }, without.suggestions.filter { $0.kind != .completion }, "\(previous ?? "-") \(word)")
                XCTAssertEqual(withContext.replacement, without.replacement, "\(previous ?? "-") \(word)")
                XCTAssertEqual(withContext.suggestions.count, without.suggestions.count, "\(previous ?? "-") \(word)")
                XCTAssertFalse(withContext.suggestions.contains { $0.kind == .completion && $0.autoApplies }, word)
                XCTAssertFalse(contextual.evaluate(word, previous: previous).dependsOnPrevious, word)
            }
        }
        for item in TypoEvaluationSet.cases where item.category == "keep" {
            for previous in ["the", "i", "you", "to", "and"] {
                XCTAssertNil(contextual.evaluate(item.typed, autoCapitalized: item.autoCapitalized, previous: previous).replacement, "\(previous) \(item.typed)")
            }
        }
    }

    /// Only an unknown word asks the keyboard to read the text before it.
    func testOnlyAnUnknownWordDependsOnThePreviousWord() throws {
        let (plain, contextual) = try correctors()
        XCTAssertTrue(contextual.evaluate("fpod").dependsOnPrevious)
        XCTAssertFalse(contextual.evaluate("food").dependsOnPrevious)
        XCTAssertFalse(contextual.evaluate("dont").dependsOnPrevious)
        XCTAssertFalse(plain.evaluate("fpod").dependsOnPrevious)
    }

    func testThePreviousWordIsReadFromTheTextBeforeTheCursor() {
        XCTAssertEqual(Autocorrector.previousWord(before: "pass the fpod", composing: "fpod"), "the")
        XCTAssertEqual(Autocorrector.previousWord(before: "I\u{2019}m fpod", composing: "fpod"), "I'm")
        XCTAssertNil(Autocorrector.previousWord(before: "Done. fpod", composing: "fpod"))
        XCTAssertNil(Autocorrector.previousWord(before: "at 5 fpod", composing: "fpod"))
        XCTAssertNil(Autocorrector.previousWord(before: "line\nfpod", composing: "fpod"))
        XCTAssertNil(Autocorrector.previousWord(before: "fpod", composing: "fpod"))
        XCTAssertNil(Autocorrector.previousWord(before: nil, composing: "fpod"))
    }
}
