// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// One answer for the same word whichever way it was entered: typing agrees with what swipe and
/// dictation already do.
final class WordSourceCohesionTests: XCTestCase {
    private func corrector(_ words: [String] = []) -> Autocorrector {
        let c = Autocorrector(words: WordListTests.list)
        c.setPersonalWords(words)
        return c
    }

    func testBuiltInNamesGetTheirCapitalWhenTyped() {
        let c = corrector()
        XCTAssertEqual(c.evaluate("zayd").replacement, "Zayd")
        XCTAssertEqual(c.evaluate("aalia").replacement, "Aalia")
        XCTAssertNil(c.evaluate("Zayd").replacement)
    }
    func testBuiltInNamesAreRecasedBeforeAnyPersonalWordsLoad() {
        XCTAssertEqual(Autocorrector(words: WordListTests.list).evaluate("zayd").replacement, "Zayd")
    }
    func testThePersonsOwnSpellingBeatsTheBuiltInOne() {
        XCTAssertEqual(corrector(["ZAYD"]).evaluate("zayd").replacement, "ZAYD")
    }
    func testEverydayWordsAreNotPersonalWords() {
        let c = corrector()
        XCTAssertTrue(c.isEverydayWord("The"))
        XCTAssertTrue(c.isEverydayWord("will"))
        XCTAssertFalse(c.isEverydayWord("Zayd"))
        XCTAssertFalse(c.isEverydayWord("OpenRouter"))
        XCTAssertFalse(c.isEverydayWord("qzxv"))
    }

    func testAShortcutOnAModernWordExpands() {
        let c = corrector()
        c.setSystemLexicon(names: [], replacements: ["ily": "I love you"])
        XCTAssertEqual(c.evaluate("ily").replacement, "I love you")
    }
    func testAShortcutOnABuiltInWordExpands() {
        let c = corrector()
        c.setSystemLexicon(names: [], replacements: ["imma": "I'm going to"])
        XCTAssertEqual(c.evaluate("imma").replacement, "I'm going to")
    }
    func testTheirOwnWordStillBeatsTheirShortcut() {
        let c = corrector(["omw"])
        c.setSystemLexicon(names: [], replacements: ["omw": "On my way!"])
        XCTAssertNil(c.evaluate("omw").replacement)
    }
    func testWithoutAShortcutModernWordsStayProtected() {
        XCTAssertNil(corrector().evaluate("ily").replacement)
    }

    func testAKeptWordSavedWithItsCapitalsIsStillKept() {
        let c = Autocorrector(words: WordListTests.list, learnedWords: ["OpenRouter", "teh"])
        XCTAssertNil(c.evaluate("openrouter").replacement)
        XCTAssertNil(c.evaluate("teh").replacement)
        XCTAssertTrue(c.learnedWords.contains("openrouter"))
    }

    // MARK: Learned words

    func testALearnedEverydayWordIsNotApplied() {
        var document = PersonalVocabulary.Document(words: ["The", "OpenRouter", "Apple", "Will"])
        document.learned = ["the", "openrouter", "apple"]
        // "Will" was typed into My words by the person; "OpenRouter" is not an everyday word.
        XCTAssertEqual(document.appliedWords, ["OpenRouter", "Will"])
        XCTAssertEqual(document.words, ["The", "OpenRouter", "Apple", "Will"], "the list itself is untouched")
    }
    func testWithNothingLearnedEveryWordApplies() {
        XCTAssertEqual(PersonalVocabulary.Document(words: ["The", "Will"]).appliedWords, ["The", "Will"])
    }
    func testALearnedPhraseApplies() {
        XCTAssertEqual(PersonalVocabulary.applied(["Micro Center"], learned: ["micro center"]), ["Micro Center"])
    }
}
