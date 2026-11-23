// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// What measuring everyday chat changed (November 15): ranks for words the list filed as rare,
/// current words autocorrect used to rewrite, and drawn-out words.
final class ChatVocabularyTests: XCTestCase {
    private static let plainList: WordList = {
        let url = Bundle.zoneSwipeResources.url(forResource: "en-words", withExtension: "txt")!
        return WordList(data: try! Data(contentsOf: url))!
    }()

    private static let chatRanks: [(word: String, rank: Int)] = {
        let url = Bundle.zoneSwipeResources.url(forResource: "chat-ranks", withExtension: "txt")!
        return try! String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { line in
            guard !line.hasPrefix("#") else { return nil }
            let fields = line.split(separator: "\t")
            return (String(fields[0]), Int(fields[1])!)
        }
    }()

    // MARK: Ranks

    func testEverydayWordsAreNoLongerRankedAsObscure() throws {
        let list = try XCTUnwrap(WordList.shared)
        for word in ["nah", "lemme", "congrats", "yup", "it'll", "should've", "would've", "anyways", "convo"] {
            let before = try XCTUnwrap(Self.plainList.lookup(word)).rank
            let after = try XCTUnwrap(list.lookup(word)).rank
            XCTAssertGreaterThan(before, 20_000, word)
            XCTAssertLessThan(after, 10_000, word)
        }
    }

    func testChatRanksOnlyLiftLowercaseWordsTheListHas() throws {
        let list = try XCTUnwrap(WordList.shared)
        XCTAssertGreaterThan(Self.chatRanks.count, 100)
        for (word, rank) in Self.chatRanks {
            let plain = try XCTUnwrap(Self.plainList.lookup(word), "\(word) is not in the list")
            XCTAssertEqual(plain.display, word, "\(word) is a name or acronym in the list")
            XCTAssertTrue(plain.isSuggestible, "\(word) is never offered")
            XCTAssertGreaterThan(plain.rank, rank, "\(word) would be made rarer")
            // Never common enough to be half of a split or a bold two-slip target.
            XCTAssertGreaterThanOrEqual(rank, Autocorrector.splitMaximumRank, word)
            XCTAssertEqual(list.lookup(word)?.rank, rank, word)
        }
    }

    /// The word-pair table carries a digest of the list's words; a rank is not part of it.
    func testTheWordPairTableStillMatchesTheList() throws {
        let list = try XCTUnwrap(WordList.shared)
        XCTAssertEqual(WordPairs.digest(of: list), WordPairs.digest(of: Self.plainList))
        XCTAssertEqual(list.count, Self.plainList.count)
    }

    func testARarerRankOrAnUnknownWordChangesNothing() throws {
        let data = try Data(contentsOf: XCTUnwrap(Bundle.zoneSwipeResources.url(forResource: "en-words", withExtension: "txt")))
        let list = try XCTUnwrap(WordList(data: data, rankOverrides: Data("the\t50000\nnotaword\t5\n# note\nnah\t4000\n".utf8)))
        XCTAssertEqual(list.lookup("the")?.rank, Self.plainList.lookup("the")?.rank)
        XCTAssertNil(list.lookup("notaword"))
        XCTAssertEqual(list.lookup("nah")?.rank, 4_000)
    }

    func testSlipsOntoEverydayWordsAreFixed() throws {
        let corrector = Autocorrector(words: try XCTUnwrap(WordList.shared))
        XCTAssertEqual(corrector.evaluate("congarts").replacement, "congrats")
        XCTAssertEqual(corrector.evaluate("lemmr").replacement, "lemme")
        XCTAssertEqual(corrector.evaluate("yupp").replacement, "yup")
    }

    // MARK: Words

    func testCurrentWordsAreKeptAndNamesTakeTheirSpelling() throws {
        let corrector = Autocorrector(words: try XCTUnwrap(WordList.shared))
        // Each of these used to be rewritten: btw, cram, oath, "open law", Kansan, Tesla, etc.
        XCTAssertEqual(corrector.evaluate("btc").replacement, "BTC")
        XCTAssertEqual(corrector.evaluate("vram").replacement, "VRAM")
        XCTAssertEqual(corrector.evaluate("oauth").replacement, "OAuth")
        XCTAssertEqual(corrector.evaluate("openclaw").replacement, "OpenClaw")
        XCTAssertEqual(corrector.evaluate("etf").replacement, "ETF")
        for word in ["kanban", "ik", "dw", "notifs", "recs", "webapp", "tmux", "colour", "realise", "cookin", "trynna"] {
            XCTAssertNil(corrector.evaluate(word).replacement, word)
            XCTAssertTrue(corrector.recognizes(word), word)
        }
    }

    /// A short word one slip from a far more common one is not listed, so the slip is still fixed.
    func testSlipsOntoVeryCommonWordsAreStillFixed() throws {
        let corrector = Autocorrector(words: try XCTUnwrap(WordList.shared))
        XCTAssertEqual(corrector.evaluate("og").replacement, "of")
        XCTAssertNil(ModernVocabulary.names["og"])
        XCTAssertFalse(ModernVocabulary.words.contains("ig"))
    }

    func testRespellingsNeverOutrankTheStandardWordInSwipe() {
        let ranks = Dictionary(ModernVocabulary.swipeWords.map { ($0.word, $0.rank) }, uniquingKeysWith: min)
        for word in ["colour", "favourite", "cookin", "trynna", "realise"] {
            XCTAssertEqual(ranks[word], 40_000, word)
        }
        XCTAssertLessThan(ranks["OpenClaw"] ?? .max, 40_000)
    }

    // MARK: Drawn-out words

    func testAWordDrawnOutOnItsLastLetterIsKept() throws {
        let corrector = Autocorrector(words: try XCTUnwrap(WordList.shared))
        for word in ["sooo", "gooo", "nooo", "yesss", "damnnn", "brooo", "lmaooo", "Sooo"] {
            XCTAssertNil(corrector.evaluate(word).replacement, word)
        }
        // The plain word is still one tap away.
        XCTAssertTrue(corrector.evaluate("sooo").suggestions.contains { $0.text == "so" && !$0.autoApplies })
        XCTAssertTrue(corrector.evaluate("yesss").suggestions.contains { $0.text == "yes" })
    }

    func testARepeatedKeyInsideAWordIsStillATypo() throws {
        let corrector = Autocorrector(words: try XCTUnwrap(WordList.shared))
        XCTAssertEqual(corrector.evaluate("toook").replacement, "took")
        XCTAssertEqual(corrector.evaluate("helllo").replacement, "hello")
        // One letter too many on a common word that ends in a double.
        XCTAssertEqual(corrector.evaluate("willl").replacement, "will")
        XCTAssertEqual(corrector.evaluate("seee").replacement, "see")
        // One tap on the key beside the right one: r is beside e.
        XCTAssertEqual(corrector.evaluate("weee").replacement, "were")
        // Held longer than a slip, it is drawn out.
        XCTAssertNil(corrector.evaluate("alllll").replacement)
    }
}
