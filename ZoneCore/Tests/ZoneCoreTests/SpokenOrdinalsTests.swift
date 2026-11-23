// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// Zayd, November 15: "But I was in tenth and got bumped to eleventh", typed in Discord.
final class SpokenOrdinalsTests: XCTestCase {
    func testTenthAndUpAreAlwaysDigits() {
        for (said, written) in [
            ("I was in tenth and got bumped to eleventh", "I was in 10th and got bumped to 11th"),
            ("the twenty first of May", "the 21st of May"), ("the twenty-first", "the 21st"),
            ("the fifty second floor", "the 52nd floor"), ("my thirty third birthday", "my 33rd birthday"),
            ("the hundredth time", "the 100th time"), ("Tenth place again", "10th place again"),
            ("the twelfth and thirteenth", "the 12th and 13th"),
        ] {
            XCTAssertEqual(SpokenOrdinals.writing(said), written, said)
        }
    }

    func testFirstThroughNinthFollowTheSetting() {
        for (said, on) in [
            ("I came in second", "I came in 2nd"), ("I came in second place", "I came in 2nd place"),
            ("my first car", "my 1st car"), ("the first of May", "the 1st of May"), ("May second works", "May 2nd works"),
            ("her third try", "her 3rd try"), ("seventh grade", "7th grade"), ("for the second time", "for the 2nd time"),
            ("the first and second place", "the 1st and 2nd place"),
        ] {
            XCTAssertEqual(SpokenOrdinals.writing(said), said, "off: \(said)")
            XCTAssertEqual(SpokenOrdinals.writing(said, small: true), on, said)
        }
    }

    func testWordsThatOnlyLookLikeRanksStay() {
        for said in ["wait a second", "one second", "on second thought", "at first I", "first of all", "first and foremost",
                     "the second I saw it", "a second chance", "first, second, third", "a tenth of a second", "one fifth of it",
                     "Fifth Avenue is nice", "two thirds", "we went fourth", "Twenty First Century"] {
            XCTAssertEqual(SpokenOrdinals.writing(said, small: true), said, said)
        }
        XCTAssertEqual(SpokenOrdinals.writing("go to example.com/tenth"), "go to example.com/tenth")
    }

    func testStylesAndCapsLock() {
        XCTAssertEqual(TextStyle.casual.apply("But I was in tenth and got bumped to eleventh"), "But I was in 10th and got bumped to 11th")
        XCTAssertEqual(TextStyle.formal.apply("I came in second place", smallOrdinals: true), "I came in 2nd place.")
        XCTAssertEqual(TextStyle.veryCasual.apply("I came in second", smallOrdinals: false), "i came in second")
        XCTAssertEqual(TextStyle.casual.insertion(of: "eleventh", contextBefore: "", fieldCapitalizesSentences: true, opening: .capsLock), "11TH")
    }

    /// The keyboard's casual insert, as Fluid Speech Mini writes it: words ("second") or digits
    /// ("2nd"), with its commas at every breath.
    func testTheCasualInsertWithTheRecognizersSpellings() {
        func insert(_ said: String, small: Bool = true) -> String {
            TextStyle.casual.insertion(of: said, contextBefore: nil, fieldCapitalizesSentences: true, smallOrdinals: small)
        }
        XCTAssertEqual(insert("This is the second point, but seeing backup is confusing."),
                       "This is the 2nd point but seeing backup is confusing")
        XCTAssertEqual(insert("This is the 2nd point."), "This is the 2nd point")
        XCTAssertEqual(insert("I came in second."), "I came in 2nd")
        XCTAssertEqual(insert("My first car was red."), "My 1st car was red")
        XCTAssertEqual(insert("See you May third."), "See you May 3rd")
        XCTAssertEqual(insert("Wait a second, at first I didn't get it. On second thought, fine."),
                       "Wait a second at first I didn't get it. On second thought fine")
        XCTAssertEqual(insert("I came in second.", small: false), "I came in second")
        XCTAssertEqual(insert("It's on the twenty first."), "It's on the 21st")
    }

    /// A list of ordinals reads one way. Once one of them is in digits ("127th", or "third place"),
    /// first through ninth beside it are digits too; a bare list of words being talked about
    /// ("first, second, third") stays words.
    func testAListOfOrdinalsIsWrittenOneWay() {
        XCTAssertEqual(SpokenOrdinals.writing("I got second and third place", small: true), "I got 2nd and 3rd place")
        XCTAssertEqual(SpokenOrdinals.writing("the second, third and fourth floors", small: true), "the 2nd, 3rd and 4th floors")
        XCTAssertEqual(SpokenOrdinals.writing("I don't know if second, third, fourth, ninth, 127th, 9,772nd is all gonna work", small: true),
                       "I don't know if 2nd, 3rd, 4th, 9th, 127th, 9,772nd is all gonna work")
        XCTAssertEqual(SpokenOrdinals.writing("ninth and tenth", small: true), "9th and 10th")
        XCTAssertEqual(SpokenOrdinals.writing("ninth and tenth"), "ninth and 10th", "off, first through ninth stay words")
        XCTAssertEqual(SpokenOrdinals.writing("first, second, third", small: true), "first, second, third")
        XCTAssertEqual(SpokenOrdinals.writing("first and foremost the tenth", small: true), "first and foremost the 10th")
        XCTAssertEqual(SpokenOrdinals.writing("second. Third place went to him", small: true), "second. 3rd place went to him")
    }

    /// A contact called Cali turned every "CLI" into "Cali".
    func testAContactNeverReplacesAnAcronymOrACurrentWord() {
        let book = SystemLexiconSnapshot(entries: ["Cali", "Nika"].map { (input: $0.lowercased(), text: $0) })
        for (said, written) in [("Set up CLI proxy", "Set up CLI proxy"), ("Set up C L I proxy", "Set up CLI proxy"),
                                ("I put it in the cli", "I put it in the CLI"), ("I'm in Cali now", "I'm in Cali now"),
                                ("I saw cali today", "I saw Cali today")] {
            XCTAssertEqual(TextStyle.casual.apply(said, systemWords: book.speechWords), written, said)
        }
    }

    func testAbbreviationsAreWrittenWithoutPeriods() {
        for (said, written) in [("I live in the U.S.A. now", "I live in the USA now"), ("U.S.A.", "USA."),
                                ("the U.S. Army", "the US Army"), ("the U.S. It was big", "the US. It was big"),
                                ("R.S.V.P. by Friday", "RSVP by Friday"), ("We met in D.C. and then", "We met in DC and then"),
                                ("at 5 p.m. today", "at 5 p.m. today"), ("i.e. this", "i.e. this"), ("see a.b.c.com", "see a.b.c.com")] {
            XCTAssertEqual(SpelledLetters.droppingAbbreviationPeriods(said), written, said)
        }
        XCTAssertEqual(TextStyle.formal.apply("I live in the U.S.A."), "I live in the USA.")
    }
}
