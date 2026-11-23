// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class CorrectionBoundarySafetyTests: XCTestCase {
    func testStructuralEditsAndInvalidTouchEvidenceNeverPartiallyTrain() {
        for (typed, committed) in [("inthe", "in the"), ("teh", "the"), ("cant", "can"),
                                   ("cant", "can'ts"), ("a", "a"), ("c4nt", "can't")] {
            var model = TouchAdaptation()
            XCTAssertFalse(model.learn(typed: typed, committed: committed,
                touches: Array(repeating: .center, count: typed.count), recognized: true), typed)
            XCTAssertEqual(model, TouchAdaptation())
        }
        for bad in [KeyTouch(dx: .nan, dy: 0), KeyTouch(dx: 0, dy: .infinity), KeyTouch(dx: 3, dy: 0)] {
            var model = TouchAdaptation()
            XCTAssertFalse(model.learn(typed: "the", committed: "the", touches: [.center, bad, .center], recognized: true))
            XCTAssertEqual(model, TouchAdaptation())
        }
    }

    func testOnlyRejectedBottomRowTapsDoNotReportALearnedLesson() {
        var model = TouchAdaptation()
        XCTAssertFalse(model.learn(typed: "vv", committed: "vv",
            touches: Array(repeating: KeyTouch(dx: 0, dy: 0.4), count: 2), recognized: false))
        XCTAssertEqual(model, TouchAdaptation())
    }

    func testJoinedContractionsRestoreApostrophesAndWordBoundariesTogether() {
        let corrector = Autocorrector(words: WordListTests.list)
        for (typed, expected) in [("dontxknow", "don't know"), ("imxready", "I'm ready"),
                                   ("yourexright", "you're right"), ("theyllxcome", "they'll come"),
                                   ("cantxwait", "can't wait"), ("dontknow", "don't know"),
                                   ("itxdoesnt", "it doesn't")] {
            XCTAssertEqual(corrector.evaluate(typed).replacement, expected, typed)
        }
    }

    func testAmbiguousJoinedContractionIsOfferedWithoutForcingIt() {
        let result = Autocorrector(words: WordListTests.list).evaluate("icant")
        XCTAssertNil(result.replacement, "can't and I can't are competing readings")
        XCTAssertTrue(result.suggestions.contains { $0.text == "I can't" })
    }

    func testRealWordApostropheAmbiguitiesAndProtectedWordsStayIntact() {
        let corrector = Autocorrector(words: WordListTests.list)
        for word in ["well", "were", "ill", "shell", "hell", "its", "lets", "shed", "wed", "dads", "emails"] {
            XCTAssertNil(corrector.evaluate(word).replacement, word)
        }
        corrector.learn("dont")
        XCTAssertNil(corrector.evaluate("dont").replacement)
        XCTAssertNotEqual(corrector.evaluate("dontxknow").replacement, "don't know")
    }
    func testUsefulCompletionsAreNotCrowdedOutByTwoCorrections() {
        let corrector = Autocorrector(words: WordListTests.list)
        for prefix in ["keybo", "authen", "glit", "conj", "synch", "sched", "unfor", "calib", "tomor"] {
            let result = corrector.evaluate(prefix)
            XCTAssertEqual(result.suggestions.first?.text, prefix)
            XCTAssertLessThanOrEqual(result.suggestions.count, 3)
            XCTAssertTrue(result.suggestions.contains {
                $0.text.lowercased().hasPrefix(prefix) && $0.text.count > prefix.count
            }, prefix)
            XCTAssertFalse(result.suggestions.contains { $0.kind == .completion && $0.autoApplies })
        }
    }


    /// The -full misspelling of -ful is one word, never a split ("care full") or a tie with -fully.
    /// The newer words Zone ships were accepted as typed but never used to fix a slip.
    func testOneSlipInANewerWordIsFixed() {
        let corrector = Autocorrector(words: WordListTests.list)
        for (typed, expected) in [("soacebar", "spacebar"), ("spacbar", "spacebar"), ("chatgtp", "ChatGPT"),
                                  ("venmi", "Venmo"), ("spotfy", "Spotify"), ("bestei", "bestie")] {
            XCTAssertEqual(corrector.evaluate(typed).replacement, expected, typed)
        }
        // The word itself, its plural, and a dictionary word that fits as well are left alone.
        for word in ["spacebar", "spacebars", "besties", "tiktoks", "clause", "discrd", "rizz"] {
            XCTAssertNil(corrector.evaluate(word).replacement, word)
        }
    }

    /// "we" was just past the rank limit for two-letter fixes, so "wr" never became it.
    func testWrBecomesWeOnlyWhenTheTapLeanedTowardE() {
        let corrector = Autocorrector(words: WordListTests.list)
        XCTAssertEqual(corrector.evaluate("wr", touches: [.center, KeyTouch(dx: -0.3, dy: 0)]).replacement, "we")
        for touches in [nil, [KeyTouch.center, .center], [.center, KeyTouch(dx: -0.1, dy: 0)], [.center, KeyTouch(dx: 0.3, dy: 0)]] {
            XCTAssertNil(corrector.evaluate("wr", touches: touches).replacement)
        }
        XCTAssertNil(corrector.evaluate("la", touches: [.center, KeyTouch(dx: -0.3, dy: 0)]).replacement)
    }

    func testFullSuffixMisspellingBecomesFul() {
        let corrector = Autocorrector(words: WordListTests.list)
        for (typed, expected) in [("carefull", "careful"), ("helpfull", "helpful"), ("hopefull", "hopeful"),
                                  ("thankfull", "thankful"), ("usefull", "useful"), ("beautifull", "beautiful"),
                                  ("Carefull", "Careful")] {
            XCTAssertEqual(corrector.evaluate(typed).replacement, expected, typed)
        }
        // Real words and real two-word runs are untouched.
        for typed in ["full", "careful", "carefully", "handful"] {
            XCTAssertNil(corrector.evaluate(typed).replacement, typed)
        }
        XCTAssertEqual(corrector.evaluate("imfull").replacement, "I'm full")
    }
}
