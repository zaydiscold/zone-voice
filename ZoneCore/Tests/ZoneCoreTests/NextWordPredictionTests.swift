// by zayd/cold @ zayd.wtf

import Foundation
import XCTest
@testable import ZoneCore

/// Whole next words between words, and completions ranked by the word before, both read from
/// the pair table the keyboard already ships (ZoneKeyboard/Resources/en-pairs.bin).
final class NextWordPredictionTests: XCTestCase {
    private func shipped() throws -> (Autocorrector, WordPairs, WordList) {
        let words = try XCTUnwrap(WordList.loadBundled())
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ZoneKeyboard/Resources/en-pairs.bin")
        let pairs = try XCTUnwrap(WordPairs(url: url, words: words))
        let corrector = Autocorrector(words: words)
        corrector.context = pairs
        return (corrector, pairs, words)
    }

    func testSuccessorsAreTheCheapestPairsInOrder() throws {
        let (_, pairs, words) = try shipped()
        for previous in ["thank", "going", "i", "the", "of", "can't"] {
            let p = try XCTUnwrap(words.lookup(previous)?.index)
            let top = pairs.successors(after: p, limit: 5)
            XCTAssertEqual(top.count, 5, previous)
            XCTAssertEqual(Set(top).count, 5, previous)
            let costs = try top.map { try XCTUnwrap(pairs.cost(of: $0, after: p)) }
            XCTAssertEqual(costs, costs.sorted(), previous)
            // Nothing the table holds after this word is cheaper than the last one returned.
            let cheapestSeen = try XCTUnwrap(costs.first)
            XCTAssertLessThan(cheapestSeen, pairs.backoff(after: p) + pairs.unigramCost(of: top[0]), previous)
        }
        XCTAssertEqual(pairs.successors(after: -1, limit: 3), [])
        XCTAssertEqual(pairs.successors(after: words.count, limit: 3), [])
        XCTAssertEqual(pairs.successors(after: 0, limit: 0), [])
    }

    func testSuccessorsHonorTheFilterAndStillFillTheList() throws {
        let (_, pairs, words) = try shipped()
        let p = try XCTUnwrap(words.lookup("thank")?.index)
        let you = try XCTUnwrap(words.lookup("you")?.index)
        XCTAssertEqual(pairs.successors(after: p, limit: 1), [you])
        let without = pairs.successors(after: p, limit: 3) { $0 != you }
        XCTAssertEqual(without.count, 3)
        XCTAssertFalse(without.contains(you))
    }

    func testEverydayPredictions() throws {
        let (corrector, _, _) = try shipped()
        func top(_ previous: String) -> [String] { corrector.predictions(after: previous).map(\.text) }
        XCTAssertEqual(top("thank").first, "you")
        XCTAssertEqual(top("going").first, "to")
        XCTAssertTrue(top("on").contains("the"))
        XCTAssertTrue(top("how").contains("are") || top("how").contains("do"))
        XCTAssertEqual(top("Thank"), top("thank"), "the previous word's capitals do not matter")
        for word in ["thank", "going", "i", "the", "my", "oh", "what", "will"] {
            let offered = corrector.predictions(after: word)
            XCTAssertEqual(offered.count, 3, word)
            XCTAssertTrue(offered.allSatisfy { $0.kind == .prediction && !$0.autoApplies }, word)
        }
    }

    func testPredictionsKeepDictionaryCapitals() throws {
        let (corrector, _, _) = try shipped()
        // "I" and its contractions are written as the list writes them.
        let afterThink = corrector.predictions(after: "think", limit: 12).map(\.text)
        XCTAssertTrue(afterThink.contains("I") || afterThink.contains("I'm"), "\(afterThink)")
        XCTAssertFalse(afterThink.contains("i"))
    }

    func testNothingUnsuggestibleOrGrimIsOffered() throws {
        let (corrector, _, words) = try shipped()
        for previous in ["the", "my", "oh", "what", "you", "i", "will", "to", "a", "holy", "go", "shut", "so", "fucking", "this"] {
            for suggestion in corrector.predictions(after: previous, limit: 12) {
                let entry = try XCTUnwrap(words.lookup(suggestion.text), suggestion.text)
                XCTAssertTrue(entry.isSuggestible, "\(previous) \(suggestion.text)")
                XCTAssertFalse(Autocorrector.neverPredicted.contains(suggestion.text.lowercased()), "\(previous) \(suggestion.text)")
            }
        }
    }

    func testNoPredictionsWithoutATableOrAKnownWord() throws {
        let (corrector, _, words) = try shipped()
        XCTAssertEqual(corrector.predictions(after: "zqxjv"), [])
        XCTAssertEqual(corrector.predictions(after: ""), [])
        XCTAssertEqual(Autocorrector(words: words).predictions(after: "thank"), [])
    }

    /// A completion follows the word before: "on my w" is "way", "thank y" is "you".
    func testCompletionsFollowThePreviousWord() throws {
        let (corrector, _, _) = try shipped()
        func completions(_ typed: String, after previous: String?) -> [String] {
            corrector.evaluate(typed, previous: previous).suggestions.filter { $0.kind == .completion }.map(\.text)
        }
        XCTAssertEqual(completions("morn", after: "good").first, "morning")
        XCTAssertEqual(completions("lu", after: "good").first, "luck")
        XCTAssertNotEqual(completions("lu", after: nil).first, "luck")
        // Without a previous word nothing changes.
        let plain = Autocorrector(words: try XCTUnwrap(WordList.loadBundled()))
        XCTAssertEqual(completions("morn", after: nil), plain.evaluate("morn").suggestions.filter { $0.kind == .completion }.map(\.text))
        // The word before never changes what a separator does to a word the keyboard accepts,
        // and a completion is never armed.
        for (typed, previous) in [("more", "good"), ("the", "on"), ("luck", "good"), ("way", "my"), ("to", "going")] {
            let evaluation = corrector.evaluate(typed, previous: previous)
            XCTAssertNil(evaluation.replacement, typed)
            XCTAssertEqual(evaluation.replacement, corrector.evaluate(typed).replacement, typed)
            XCTAssertFalse(evaluation.suggestions.contains { $0.kind == .completion && $0.autoApplies }, typed)
        }
    }

    /// A one or two letter prefix whose row is full of spelling alternatives still shows the
    /// word that follows the one before: "thank y" must offer "you".
    func testAShortPrefixStillOffersTheWordThatFollows() throws {
        let (corrector, _, _) = try shipped()
        for (typed, previous, wanted) in [("y", "thank", "you"), ("t", "going", "to"), ("m", "good", "morning"), ("l", "good", "luck")] {
            let row = corrector.evaluate(typed, previous: previous).suggestions
            XCTAssertTrue(row.contains { $0.text == wanted && !$0.autoApplies }, "\(previous) \(typed): \(row.map(\.text))")
            XCTAssertEqual(row.first?.kind, .literal, typed)
            XCTAssertLessThanOrEqual(row.count, Autocorrector.maxSuggestions)
            // What a separator does is untouched.
            XCTAssertEqual(corrector.evaluate(typed, previous: previous).replacement, corrector.evaluate(typed).replacement, typed)
        }
        // Without a word before, the row is exactly what it was.
        let plain = Autocorrector(words: try XCTUnwrap(WordList.loadBundled()))
        for typed in ["y", "t", "m", "w", "th"] {
            XCTAssertEqual(corrector.evaluate(typed).suggestions, plain.evaluate(typed).suggestions, typed)
        }
    }

    func testPredictionAndCompletionLookupsAreFast() throws {
        let (corrector, _, _) = try shipped()
        let start = Date()
        for _ in 0..<200 {
            _ = corrector.predictions(after: "the")
            _ = corrector.evaluate("wa", previous: "the")
            _ = corrector.evaluate("w", previous: "my")
        }
        // 600 lookups, the longest run in the table among them. Generous: debug build, shared CI.
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}
