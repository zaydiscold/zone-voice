// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class AutocorrectorTouchAndSplitTests: XCTestCase {
    private var corrector: Autocorrector { Autocorrector(words: WordListTests.list) }

    /// Taps at key centers, except the letters given a lean toward a neighbour.
    private func touches(_ count: Int, _ leans: [Int: KeyTouch]) -> [KeyTouch] {
        (0..<count).map { leans[$0] ?? .center }
    }

    func testTouchEvidenceDecidesBetweenEquallyCloseWords() {
        // "fot": for (t read as r) and got (f read as g) are both one key off. Where the taps
        // landed decides it.
        XCTAssertEqual(corrector.evaluate("fot", touches: touches(3, [2: KeyTouch(dx: -0.45, dy: 0)])).replacement, "for")
        XCTAssertEqual(corrector.evaluate("fot", touches: touches(3, [0: KeyTouch(dx: 0.45, dy: 0)])).replacement, "got")
    }

    func testTwoSlipsOnAShortWordKeepItsLength() {
        // Zayd's "xang" for "can't": x and g each landed near c and t.
        XCTAssertNotEqual(corrector.evaluate("xang").replacement, "can")
        let leaning = touches(4, [0: KeyTouch(dx: 0.45, dy: 0), 3: KeyTouch(dx: -0.2, dy: -0.45)])
        XCTAssertEqual(corrector.evaluate("xang", touches: leaning).replacement, "can't")
    }

    func testTwoLetterWordsChangeOnlyOnATapNearTheIntendedKey() {
        XCTAssertNil(corrector.evaluate("ib", touches: touches(2, [1: KeyTouch(dx: -0.3, dy: 0)])).replacement)
        XCTAssertEqual(corrector.evaluate("ib", touches: touches(2, [1: KeyTouch(dx: 0.45, dy: 0)])).replacement, "in")
    }

    func testTouchesThatDoNotLineUpAreIgnored() {
        XCTAssertEqual(corrector.evaluate("teh", touches: [.center]).replacement, "the")
    }

    func testContractionsAreGeneratedFromTheList() {
        for (typed, expected) in [("theyll", "they'll"), ("itll", "it'll"), ("wouldve", "would've"), ("couldve", "could've"),
                                  ("theyd", "they'd"), ("thatll", "that'll"), ("howd", "how'd"), ("Mustve", "Must've")] {
            XCTAssertEqual(corrector.evaluate(typed).replacement, expected, typed)
        }
        // A bare spelling that is a word stays a word.
        for word in ["ill", "well", "were", "wed", "shell", "hell", "id"] {
            XCTAssertNil(corrector.evaluate(word).replacement, word)
        }
        XCTAssertEqual(WordListTests.list.contraction(forBare: "theyll")?.display, "they'll")
        XCTAssertNil(WordListTests.list.contraction(forBare: "ohara"))
    }

    func testFusedWordsAndAMissedSpaceBarSplit() {
        for (typed, expected) in [("thisis", "this is"), ("inthe", "in the"), ("iam", "I am"), ("thankyou", "thank you"),
                                  ("inbthe", "in the"), ("canbyou", "can you"), ("Thisis", "This is")] {
            XCTAssertEqual(corrector.evaluate(typed).replacement, expected, typed)
        }
        // Profanity is never offered, names are never split, nonsense stays.
        for word in ["thisxaople", "dahlsson"] {
            let fix = corrector.evaluate(word).replacement
            XCTAssertFalse(fix?.contains(" ") ?? false, "\(word) -> \(fix ?? "nil")")
        }
    }

    func testLowercaseAbbreviationOneSlipFromACommonWord() {
        XCTAssertEqual(corrector.evaluate("amd").replacement, "and")
        XCTAssertEqual(corrector.evaluate("Amd", autoCapitalized: true).replacement, "And")
        // Typed as the abbreviation, it stays.
        XCTAssertNil(corrector.evaluate("AMD").replacement)
        // Never shrinks to two letters, never guesses between two common words.
        XCTAssertNotEqual(corrector.evaluate("ann").replacement, "an")
        XCTAssertNil(corrector.evaluate("ne").replacement)
    }

    func testTwoEditsNeverChangeTheLengthByMoreThanOne() {
        XCTAssertNil(corrector.evaluate("Dahlsson", autoCapitalized: true).replacement)
        XCTAssertEqual(corrector.evaluate("tommorow").replacement, "tomorrow")
    }

    func testConversationalWordsWinOverEncyclopediaWords() {
        XCTAssertEqual(corrector.evaluate("yeha").replacement, "yeah")
        XCTAssertEqual(corrector.evaluate("sorrt").replacement, "sorry")
        XCTAssertNotEqual(corrector.evaluate("yeag").replacement, "year")
    }

    func testDistanceBasedKeyCosts() {
        func cost(_ a: Character, _ b: Character, _ touch: KeyTouch = .center) -> Float {
            KeyboardProximity.substitutionCost(typed: a.asciiValue!, as: b.asciiValue!, touch: touch)
        }
        XCTAssertLessThan(cost("r", "t"), cost("v", "g"))
        XCTAssertLessThan(cost("v", "g"), cost("t", "g"))
        XCTAssertLessThan(cost("t", "g"), EditCost.substitution)
        XCTAssertEqual(cost("q", "p"), EditCost.substitution)
        // A tap on the boundary makes the neighbour nearly free; one on the far side costs more.
        XCTAssertLessThan(cost("r", "t", KeyTouch(dx: 0.5, dy: 0)), 0.2)
        XCTAssertGreaterThan(cost("r", "t", KeyTouch(dx: -0.4, dy: 0)), cost("r", "t"))
        XCTAssertTrue(KeyboardProximity.areAdjacent(UInt8(ascii: "g"), UInt8(ascii: "h")))
        XCTAssertFalse(KeyboardProximity.areAdjacent(UInt8(ascii: "q"), UInt8(ascii: "p")))
    }
}
