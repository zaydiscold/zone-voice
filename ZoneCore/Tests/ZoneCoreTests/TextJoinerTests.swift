// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class TextJoinerTests: XCTestCase {
    func testFieldStartCapitalizes() {
        XCTAssertEqual(TextJoiner.join(contextBefore: nil, transcript: "hello", capitalizeSentences: true), "Hello")
        XCTAssertEqual(TextJoiner.join(contextBefore: "", transcript: "hello", capitalizeSentences: true), "Hello")
    }

    func testAfterSentenceEndAddsSpaceAndCapital() {
        XCTAssertEqual(TextJoiner.join(contextBefore: "Hi there.", transcript: "next one", capitalizeSentences: true), " Next one")
        XCTAssertEqual(TextJoiner.join(contextBefore: "Really?", transcript: "yes", capitalizeSentences: true), " Yes")
    }

    func testMidSentenceAddsSpaceOnly() {
        XCTAssertEqual(TextJoiner.join(contextBefore: "Hi there", transcript: "next", capitalizeSentences: true), " next")
    }

    func testExistingTrailingSpaceIsNotDoubled() {
        XCTAssertEqual(TextJoiner.join(contextBefore: "Hi there ", transcript: "next", capitalizeSentences: true), "next")
        XCTAssertEqual(TextJoiner.join(contextBefore: "Done. ", transcript: "next", capitalizeSentences: true), "Next")
    }

    func testQuoteAtSentenceStartCapitalizes() {
        XCTAssertEqual(TextJoiner.join(contextBefore: "Done. \"", transcript: "yes", capitalizeSentences: true), "Yes")
        XCTAssertEqual(TextJoiner.join(contextBefore: "\u{201C}", transcript: "go", capitalizeSentences: true), "Go")
        XCTAssertEqual(TextJoiner.join(contextBefore: "He said \"", transcript: "yes", capitalizeSentences: true), "yes")
        XCTAssertEqual(TextJoiner.join(contextBefore: "That was it.\"", transcript: "next", capitalizeSentences: true), " Next")
    }

    func testNoSpaceAfterOpeners() {
        XCTAssertEqual(TextJoiner.join(contextBefore: "(", transcript: "x", capitalizeSentences: false), "x")
        XCTAssertEqual(TextJoiner.join(contextBefore: "path/", transcript: "x", capitalizeSentences: false), "x")
    }

    func testNewlineStartsASentence() {
        XCTAssertEqual(TextJoiner.join(contextBefore: "line\n", transcript: "new", capitalizeSentences: true), "New")
    }

    func testLeadingPunctuationGetsNoSpace() {
        XCTAssertEqual(TextJoiner.join(contextBefore: "a", transcript: ",", capitalizeSentences: true), ",")
        XCTAssertEqual(TextJoiner.join(contextBefore: "a", transcript: ". Then", capitalizeSentences: true), ". Then")
    }

    func testTranscriptIsTrimmed() {
        XCTAssertEqual(TextJoiner.join(contextBefore: "a", transcript: "  spaced  ", capitalizeSentences: false), " spaced")
        XCTAssertEqual(TextJoiner.join(contextBefore: "a", transcript: "   ", capitalizeSentences: true), "")
    }

    func testCapitalizationOffLeavesCase() {
        XCTAssertEqual(TextJoiner.join(contextBefore: nil, transcript: "hello", capitalizeSentences: false), "hello")
    }

    func testAlreadyCapitalizedStaysPut() {
        XCTAssertEqual(TextJoiner.join(contextBefore: nil, transcript: "iPhone is great", capitalizeSentences: true), "IPhone is great")
    }
}
