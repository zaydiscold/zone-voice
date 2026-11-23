// by zayd/cold @ zayd.wtf

import Foundation
import XCTest
@testable import ZoneCore

/// The keyboard ships `en-pairs.bin` (ZoneKeyboard/Resources). It is keyed to the word list's
/// exact bytes, so a list change without a rebuild would silently turn swipe context off; this
/// fails instead. Rebuild with scripts/swipe-eval/build-wordpairs.py.
final class WordPairsResourceTests: XCTestCase {
    private func shipped() throws -> (WordPairs, WordList) {
        let words = try XCTUnwrap(WordList.loadBundled())
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ZoneKeyboard/Resources/en-pairs.bin")
        let pairs = try XCTUnwrap(WordPairs(url: url, words: words), "en-pairs.bin is missing or was built from another word list")
        return (pairs, words)
    }

    private func cost(_ pairs: WordPairs, _ words: WordList, _ word: String, after previous: String) throws -> Float {
        let w = try XCTUnwrap(words.lookup(word)?.index, word)
        let p = try XCTUnwrap(words.lookup(previous)?.index, previous)
        return try XCTUnwrap(pairs.cost(of: w, after: p))
    }

    func testShippedTableMatchesTheWordListAndPrefersConversationalPairs() throws {
        let (pairs, words) = try shipped()
        XCTAssertGreaterThan(pairs.pairCount, 500_000)
        // Same-shape swipe confusions the previous word should settle.
        for (previous, good, bad) in [("thank", "you", "yew"), ("going", "to", "too"), ("i", "love", "live"),
                                       ("what", "are", "arr"), ("on", "my", "mu"), ("see", "you", "yo"),
                                       ("oh", "my", "mu"), ("i", "think", "thing")] {
            XCTAssertLessThan(try cost(pairs, words, good, after: previous), try cost(pairs, words, bad, after: previous),
                              "\(previous) \(good) vs \(bad)")
        }
    }

    func testPersonalWordsPayTheSameContextScaleAsUnseenDictionaryPairs() throws {
        let (pairs, words) = try shipped()
        let previous = try XCTUnwrap(words.lookup("the")?.index)
        let personal = try XCTUnwrap(pairs.cost(rank: SwipeDecoder.personalRank, after: previous))
        // Finite and positive, and no cheaper than a seen everyday pair.
        XCTAssertTrue(personal.isFinite)
        XCTAssertGreaterThan(personal, try cost(pairs, words, "same", after: "the"))
        XCTAssertNil(pairs.cost(rank: .nan, after: previous))
    }

    /// With a previous word every dictionary candidate pays the context term; a personal word
    /// outside the list must pay it too, or it would win every close call after any known word.
    func testDecoderChargesPersonalWordsTheContextTerm() throws {
        let (pairs, words) = try shipped()
        let layout = SwipeLayout.qwerty()
        let keys = "zqxj".utf8.map { Int($0 - 97) }
        let points = keys.enumerated().map { SwipePoint(x: layout.x[$0.element], y: layout.y[$0.element], t: Float($0.offset) * 0.1) }
        let plain = SwipeDecoder(words: words)
        let contextual = SwipeDecoder(words: words, context: pairs)
        for decoder in [plain, contextual] { decoder.setPersonalWords(["Zqxj"]) }
        let without = try XCTUnwrap(plain.decode(points, layout: layout, context: SwipeContext(previousWord: "the"), limit: 10).first { $0.word == "Zqxj" })
        let with = try XCTUnwrap(contextual.decode(points, layout: layout, context: SwipeContext(previousWord: "the"), limit: 10).first { $0.word == "Zqxj" })
        let the = try XCTUnwrap(words.lookup("the")?.index)
        let expected = contextual.tuning.contextWeight * (try XCTUnwrap(pairs.cost(rank: SwipeDecoder.personalRank, after: the)))
        XCTAssertEqual(with.score - without.score, expected, accuracy: 1e-4)
        XCTAssertGreaterThan(expected, 0)
    }
}
