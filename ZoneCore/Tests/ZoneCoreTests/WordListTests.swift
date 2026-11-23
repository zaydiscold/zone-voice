// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class WordListTests: XCTestCase {
    static let list: WordList = {
        guard let list = WordList.loadBundled() else { fatalError("en-words.txt missing or corrupt") }
        return list
    }()

    func testBundledListLoadsAndRanksTheFirst() {
        let list = Self.list
        XCTAssertGreaterThan(list.count, 70_000)
        XCTAssertEqual(list.lookup("the")?.rank, 0)
        XCTAssertEqual(list.lookup("THE")?.display, "the")
    }

    func testLookupIsCaseInsensitiveAndKeepsDictionaryCasing() {
        let list = Self.list
        XCTAssertEqual(list.lookup("monday")?.display, "Monday")
        XCTAssertEqual(list.lookup("i'm")?.display, "I'm")
        XCTAssertEqual(list.lookup("may")?.display, "may")
        XCTAssertNil(list.lookup("teh"))
        XCTAssertNil(list.lookup("hello2"))
        XCTAssertNil(list.lookup(""))
    }

    func testCompletionsPreferFrequentWords() {
        let list = Self.list
        let texts = list.completions(of: "tomorr", limit: 3).map(\.display)
        XCTAssertEqual(texts.first, "tomorrow")
        let th = list.completions(of: "th", limit: 3).map(\.display)
        XCTAssertEqual(th.first, "the")
        XCTAssertEqual(th.count, 3)
        XCTAssertTrue(list.completions(of: "zzzzq", limit: 3).isEmpty)
    }

    func testNeighborsFindSingleEdits() {
        let list = Self.list
        // A restored letter ("tech", 0.65) is now cheaper than a swap; frequency picks "the" in
        // the corrector (AutocorrectorTests), the search only has to find it at the swap's cost.
        let teh = list.neighbors(of: "teh", maxCost: 1, limit: 5)
        XCTAssertEqual(teh.first(where: { $0.entry.display == "the" })?.cost, EditCost.transposition)
        XCTAssertTrue(list.neighbors(of: "recieve", maxCost: 1, limit: 5).map(\.entry.display).contains("receive"))
        XCTAssertTrue(list.neighbors(of: "untill", maxCost: 1, limit: 5).map(\.entry.display).contains("until"))
        XCTAssertTrue(list.neighbors(of: "hwllo", maxCost: 1, limit: 5).map(\.entry.display).contains("hello"))
    }

    func testNeighborsFindTwoEditsOnLongWords() {
        let list = Self.list
        XCTAssertTrue(list.neighbors(of: "tommorow", maxCost: 2, limit: 8).map(\.entry.display).contains("tomorrow"))
        XCTAssertTrue(list.neighbors(of: "definately", maxCost: 2, limit: 8).map(\.entry.display).contains("definitely"))
    }

    func testCorruptDataIsRejected() {
        XCTAssertNil(WordList(data: Data("zebra\t1\napple\t0\n".utf8)))
        XCTAssertNil(WordList(data: Data("ab\t1\na\t0\n".utf8)))
        XCTAssertNil(WordList(data: Data("a\tx\n".utf8)))
        XCTAssertNil(WordList(data: Data("a\t1\ty\n".utf8)))
        XCTAssertNotNil(WordList(data: Data("a\t1\nI\t0\nto\t2\n".utf8)))
        let flagged = WordList(data: Data("a\t1\nox\t0\tx\nto\t2\n".utf8))
        XCTAssertEqual(flagged?.lookup("ox")?.isSuggestible, false)
        XCTAssertEqual(flagged?.lookup("ox")?.rank, 0)
        XCTAssertEqual(flagged?.completions(of: "o", limit: 3), [])
    }

    func testProximityMatchesQwerty() {
        XCTAssertTrue(KeyboardProximity.areAdjacent(UInt8(ascii: "w"), UInt8(ascii: "e")))
        XCTAssertTrue(KeyboardProximity.areAdjacent(UInt8(ascii: "s"), UInt8(ascii: "w")))
        XCTAssertTrue(KeyboardProximity.areAdjacent(UInt8(ascii: "n"), UInt8(ascii: "m")))
        XCTAssertFalse(KeyboardProximity.areAdjacent(UInt8(ascii: "q"), UInt8(ascii: "p")))
        XCTAssertFalse(KeyboardProximity.areAdjacent(UInt8(ascii: "a"), UInt8(ascii: "'")))
    }

    func testNeighborScanIsFastEnoughForEveryKeystroke() {
        let list = Self.list
        measure {
            for word in ["hwllo", "definately", "seperate", "becuase", "thier", "wrod"] {
                _ = list.neighbors(of: word, maxCost: 2, limit: 8)
            }
        }
    }
}
