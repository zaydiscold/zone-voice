// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class PronounITests: XCTestCase {
    func testLowercasePronounIsCapitalized() {
        XCTAssertEqual(TextStyle.capitalizingPronounI("that's great what about battery i want numbers"),
                       "that's great what about battery I want numbers")
        XCTAssertEqual(TextStyle.capitalizingPronounI("i think i'm late and i'll call, i'd say i've"),
                       "I think I'm late and I'll call, I'd say I've")
        XCTAssertEqual(TextStyle.capitalizingPronounI("so i."), "so I.")
    }

    func testOtherIsAreLeftAlone() {
        for text in ["i.e. this", "my iPhone", "the wi-fi", "see ~/i/notes", "@i", "#i", "pi", "item i-5"] {
            XCTAssertEqual(TextStyle.capitalizingPronounI(text), text, text)
        }
    }

    func testStylesCapitalizeExceptVeryCasual() {
        XCTAssertEqual(TextStyle.formal.apply("yes i agree"), "Yes I agree.")
        XCTAssertTrue(TextStyle.casual.apply("yes i agree").contains(" I "))
        XCTAssertFalse(TextStyle.veryCasual.apply("yes i agree").contains("I"))
    }
}

final class AbbreviationCommaTests: XCTestCase {
    func testSpokenCommaKeepsAbbreviationPeriod() {
        XCTAssertEqual(TextStyle.formal.apply("We met at Acme Inc. comma and then left"), "We met at Acme Inc., and then left.")
        XCTAssertEqual(TextStyle.formal.apply("Apples, pears, etc. comma and more"), "Apples, pears, etc., and more.")
        XCTAssertEqual(TextStyle.formal.apply("It is ready. comma and done"), "It is ready, and done.")
    }
}

final class NameAfterSpokenCommaTests: XCTestCase {
    func testNamesKeepTheirCapitalAfterSpokenComma() {
        XCTAssertEqual(TextStyle.formal.apply("it is ready comma. John said so"), "It is ready, John said so.")
        XCTAssertEqual(TextStyle.formal.apply("it is ready comma. Grace said so"), "It is ready, Grace said so.")
        XCTAssertEqual(TextStyle.formal.apply("it is ready comma. Will you come"), "It is ready, will you come.")
        XCTAssertEqual(TextStyle.formal.apply("it is ready comma. Then we go"), "It is ready, then we go.")
    }
}
