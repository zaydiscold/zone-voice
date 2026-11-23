// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class SentenceBoundaryTests: XCTestCase {
    private func typing(_ context: String) -> Bool { SentenceBoundary.startsSentenceWhileTyping(after: context) }

    func testTypingAfterAClosingQuote() {
        XCTAssertTrue(typing("Done.\" "))
        XCTAssertTrue(typing("Done.\u{201D} "))
        XCTAssertTrue(typing("Really?' "))
    }
    func testTypingAfterAnOpeningQuoteAtASentenceStart() {
        XCTAssertTrue(typing("\""))
        XCTAssertTrue(typing("Done. \""))
        XCTAssertTrue(typing("Done.\n\u{201C}"))
        XCTAssertFalse(typing("he said \""))
        XCTAssertFalse(typing("don'"))
    }
    func testTypingKeepsItsEarlierRules() {
        XCTAssertTrue(typing(""))
        XCTAssertTrue(typing("one\n"))
        XCTAssertTrue(typing("Done. "))
        XCTAssertTrue(typing("Done!  "))
        XCTAssertFalse(typing("Done."))
        XCTAssertFalse(typing("and then "))
        XCTAssertFalse(typing("he said \" "))
    }
    func testDictationMatchesTheJoiner() {
        XCTAssertTrue(SentenceBoundary.startsSentence(after: "Done."))
        XCTAssertTrue(SentenceBoundary.startsSentence(after: "Done. \""))
        XCTAssertTrue(SentenceBoundary.startsSentence(after: "Done.\""))
        XCTAssertFalse(SentenceBoundary.startsSentence(after: "and then"))
        XCTAssertFalse(SentenceBoundary.startsSentence(after: "he said \""))
    }
}
