// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class WordScaleTests: XCTestCase {
    func testHeadlineIsTheBiggestTextPassed() {
        XCTAssertNil(WordScale.headline(words: 0))
        XCTAssertNil(WordScale.headline(words: 8))
        XCTAssertEqual(WordScale.headline(words: 60), "That's 10 tweets.")
        XCTAssertEqual(WordScale.headline(words: 136), "Halfway through the Gettysburg Address.")
        XCTAssertEqual(WordScale.headline(words: 272), "That's all of the Gettysburg Address.")
        XCTAssertEqual(WordScale.headline(words: 3_808), "That's 14 Gettysburg Addresses.")
        XCTAssertEqual(WordScale.headline(words: 9_086), "The US Constitution, twice over.")
        XCTAssertEqual(WordScale.headline(words: 56_513), "That's 1.2 Great Gatsbys.")
        XCTAssertEqual(WordScale.headline(words: 115_416), "The first Harry Potter book, 1.5 times over.")
        XCTAssertEqual(WordScale.headline(words: 2_168_340), "Every Harry Potter book, twice over.")
        XCTAssertEqual(WordScale.headline(words: 40_000_000), "Every Harry Potter book, 37 times over.")
    }

    func testCycleRunsSmallToHugeAndEndsWithWhereTheCountIsSaved() {
        let lines = WordScale.cycle(words: 56_513)
        XCTAssertEqual(lines.first, "That's 1.2 Great Gatsbys.")
        XCTAssertEqual(lines.last, "Your word count is saved on this iPhone.")
        XCTAssertTrue(lines.contains("That's 208 Gettysburg Addresses."))
        XCTAssertTrue(lines.contains("About 0.014% of the Library of Alexandria."))
        XCTAssertTrue(lines.contains("About 0.0011% of English Wikipedia."))
        XCTAssertEqual(Set(lines).count, lines.count, "no line twice")
        // Texts more than ten times smaller than the total are still in; tiny fractions are not.
        XCTAssertFalse(lines.contains { $0.contains("King James") }, "6% of a text is noise in the cycle")
        XCTAssertTrue(WordScale.cycle(words: 0).isEmpty)
    }

    func testPercentKeepsTwoSignificantFiguresUnderOne() {
        XCTAssertEqual(WordScale.percent(0.4), "40%")
        XCTAssertEqual(WordScale.percent(0.0025), "0.25%")
        XCTAssertEqual(WordScale.percent(0.005), "0.5%")
        XCTAssertEqual(WordScale.percent(0.00000019), "0.000019%")
    }

    func testLibraryLineSaysHowSmallTextIs() {
        let line = WordScale.libraryLine(words: 48_210, bytes: 290_000)
        XCTAssertTrue(line.hasPrefix("48,210 words, 290 KB of text."), line)
        XCTAssertTrue(line.contains("about 2.4 GB"), line)
    }
}
