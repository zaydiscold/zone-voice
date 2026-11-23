// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// The corrections added for fast two-thumb typing: dropped letters cost less
/// than extra ones, short-word slips, possessives without the apostrophe, and fused words with a
/// rarer part. Each rule also has its "leave it alone" side.
final class AutocorrectorFastTypingTests: XCTestCase {
    private var corrector: Autocorrector { Autocorrector(words: WordListTests.list) }
    private func centered(_ count: Int) -> [KeyTouch] { Array(repeating: .center, count: count) }

    func testDroppedLettersComeBack() {
        for (typed, expected) in [("kow", "know"), ("hve", "have"), ("wuld", "would"), ("becuse", "because"),
                                  ("somthing", "something"), ("thik", "think")] {
            XCTAssertEqual(corrector.evaluate(typed).replacement, expected, typed)
        }
        // A restored letter costs less than a removed one, and the apostrophe least of all.
        XCTAssertLessThan(EditCost.insertion, EditCost.deletion)
        XCTAssertLessThan(EditCost.apostrophe, EditCost.insertion)
    }

    func testADoubledFirstKeyCollapsesOntoAVeryCommonWord() {
        for (typed, expected) in [("tto", "to"), ("sso", "so"), ("mme", "me"), ("oor", "or"), ("ii", "I")] {
            XCTAssertEqual(corrector.evaluate(typed).replacement, expected, typed)
        }
        XCTAssertEqual(corrector.evaluate("Tto", autoCapitalized: true).replacement, "To")
        // Words, names and drawn-out words stay.
        for word in ["too", "all", "ass", "see", "off", "add", "ohh", "noo", "soo", "mmm", "zzz"] {
            XCTAssertNil(corrector.evaluate(word).replacement, word)
        }
        // A name is recased, never shrunk.
        XCTAssertEqual(corrector.evaluate("ann").replacement, "Ann")
    }

    func testSwappedTwoLetterWordsNeedTouchEvidence() {
        for (typed, expected) in [("ot", "to"), ("fo", "of"), ("si", "is"), ("ti", "it"), ("em", "me"), ("eb", "be"), ("ni", "in")] {
            XCTAssertEqual(corrector.evaluate(typed, touches: centered(2)).replacement, expected, typed)
        }
        // Without taps there is no telling a swap from a slip: "ti" stays, "ot" stays.
        XCTAssertNil(corrector.evaluate("ti").replacement)
        XCTAssertNil(corrector.evaluate("ot").replacement)
        // A tap near the edge of a key that makes a common word by itself is that word instead.
        XCTAssertEqual(corrector.evaluate("si", touches: [.center, KeyTouch(dx: 0.45, dy: 0)]).replacement, "so")
        XCTAssertEqual(corrector.evaluate("fo", touches: [KeyTouch(dx: 0.45, dy: 0), .center]).replacement, "go")
        // Chat words are not swaps.
        for word in ["ma", "eh", "ew", "ah", "na", "ya", "yo", "oh", "ok", "no", "on"] {
            XCTAssertNil(corrector.evaluate(word, touches: centered(2)).replacement, word)
        }
    }

    func testPossessivesGetTheirApostrophe() {
        XCTAssertEqual(corrector.evaluate("womens").replacement, "women's")
        XCTAssertEqual(corrector.evaluate("childrens").replacement, "children's")
        XCTAssertEqual(corrector.evaluate("marys").replacement, "Mary's")
        // Plurals and words stay plurals and words.
        for word in ["dads", "moms", "friends", "its", "lets"] {
            XCTAssertNil(corrector.evaluate(word).replacement, word)
        }
    }

    func testContactNamesStayAndTextReplacementsExpand() {
        let engine = corrector
        // Before the lexicon, an unknown name is "fixed" into a word.
        XCTAssertNotNil(engine.evaluate("zainy").replacement)
        engine.setSystemLexicon(names: ["Zainy Palacios", "Will", "O\u{2019}Neil"], replacements: ["omw": "On my way!", "x": "kiss"])
        XCTAssertEqual(engine.evaluate("zainy").replacement, "Zainy")
        XCTAssertNil(engine.evaluate("Zainy", autoCapitalized: true).replacement)
        XCTAssertEqual(engine.evaluate("palacios").replacement, "Palacios")
        XCTAssertEqual(engine.evaluate("o'neil").replacement, "O'Neil")
        // A contact never recases a dictionary word.
        XCTAssertNil(engine.evaluate("will").replacement)
        XCTAssertEqual(engine.evaluate("omw").replacement, "On my way!")
        // One-letter shortcuts expand, as on Apple's keyboard (changed 2026-11-14; they were dropped).
        XCTAssertEqual(engine.evaluate("x").replacement, "kiss")
        // Typos are still typos.
        XCTAssertEqual(engine.evaluate("teh").replacement, "the")
        engine.setSystemLexicon(names: [], replacements: [:])
        XCTAssertNotEqual(engine.evaluate("zainy").replacement, "Zainy")
    }

    func testFusedWordsWithARarerPart() {
        for (typed, expected) in [("thediscussion", "the discussion"), ("i'mglad", "I'm glad"), ("everyoneelse", "everyone else")] {
            XCTAssertEqual(corrector.evaluate(typed).replacement, expected, typed)
        }
        // Names are never split, even into two real words.
        for word in ["dahlsson", "thisxaople"] {
            XCTAssertFalse(corrector.evaluate(word).replacement?.contains(" ") ?? false, word)
        }
    }
}
