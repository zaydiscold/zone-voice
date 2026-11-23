// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class WordErrorRateTests: XCTestCase {
    func testIdenticalTextScoresZero() {
        let score = WordErrorRate.score(reference: "The meeting is at noon.", hypothesis: "the meeting is at noon")
        XCTAssertEqual(score.errors, 0)
        XCTAssertEqual(score.referenceWords, 5)
        XCTAssertEqual(score.rate, 0)
    }

    func testCountsEachEditKind() {
        // "cat" -> "bat" substitution, "the" deleted, "very" inserted.
        let score = WordErrorRate.score(reference: "the cat sat on the mat", hypothesis: "bat sat on very the mat")
        XCTAssertEqual(score.referenceWords, 6)
        XCTAssertEqual(score.errors, 3)
        XCTAssertEqual(score.rate, 0.5, accuracy: 1e-9)
    }

    func testEmptyHypothesisIsAllDeletions() {
        let score = WordErrorRate.score(reference: "one two three", hypothesis: "")
        XCTAssertEqual(score.deletions, 3)
        XCTAssertEqual(score.rate, 1)
    }

    func testEmptyReference() {
        XCTAssertEqual(WordErrorRate.score(reference: "", hypothesis: "").rate, 0)
        XCTAssertEqual(WordErrorRate.score(reference: "", hypothesis: "hello").insertions, 1)
    }

    func testDigitsAndWordsMatch() {
        let words = "The meeting is at three thirty, not four. Budget is twelve point five percent."
        let digits = "The meeting is at 3:30, not 4. Budget is 12.5%."
        XCTAssertEqual(WordErrorRate.score(reference: words, hypothesis: digits).errors, 0)
    }

    func testClockAndMoneyAndOrdinals() {
        XCTAssertEqual(WordErrorRate.normalize("3:05"), ["three", "oh", "five"])
        XCTAssertEqual(WordErrorRate.normalize("7:00"), ["seven"])
        XCTAssertEqual(WordErrorRate.normalize("$20"), ["twenty", "dollars"])
        XCTAssertEqual(WordErrorRate.normalize("the 21st and 3rd"), ["the", "twenty", "first", "and", "third"])
        XCTAssertEqual(WordErrorRate.normalize("1,250"), ["one", "thousand", "two", "hundred", "fifty"])
    }

    func testDottedTimesAfterTimeWordsAreClockTimes() {
        XCTAssertEqual(WordErrorRate.normalize("at 3.30, not 4"), ["at", "three", "thirty", "not", "four"])
        XCTAssertEqual(WordErrorRate.normalize("before 6.05"), ["before", "six", "oh", "five"])
        // Without a time word it stays a decimal.
        XCTAssertEqual(WordErrorRate.normalize("rate 3.30"), ["rate", "three", "point", "three", "zero"])
    }

    func testPunctuationApostrophesAndFillers() {
        XCTAssertEqual(WordErrorRate.normalize("Don't, um, call—me!"), ["dont", "call", "me"])
        XCTAssertEqual(WordErrorRate.normalize("follow-up/next"), ["follow", "up", "next"])
        XCTAssertEqual(WordErrorRate.normalize("Zayd\u{2019}s phone?"), ["zayds", "phone"])
    }

    func testPooledSumsErrorsOverReferenceWords() {
        let a = WordErrorRate.score(reference: "a b c d", hypothesis: "a b c d")
        let b = WordErrorRate.score(reference: "e f", hypothesis: "e x")
        let pooled = WordErrorRate.pooled([a, b])
        XCTAssertEqual(pooled.referenceWords, 6)
        XCTAssertEqual(pooled.errors, 1)
        XCTAssertEqual(pooled.rate, 1.0 / 6.0, accuracy: 1e-9)
    }
}
