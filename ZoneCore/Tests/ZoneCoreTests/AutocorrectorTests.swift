// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class AutocorrectorTests: XCTestCase {
    private var corrector: Autocorrector { Autocorrector(words: WordListTests.list) }

    func testUserReportedTypingSamplePreservesAmbiguousAndJoinedWords() {
        for (typed, expected) in [("firgot", "forgot"), ("whst", "what"), ("thibk", "think"), ("stsnd", "stand")] {
            XCTAssertEqual(corrector.evaluate(typed).replacement, expected)
        }
        for word in ["ill", "thisxaople", "tv"] {
            XCTAssertNil(corrector.evaluate(word).replacement, word)
        }
    }

    func testSingleEditTyposAreReplaced() {
        XCTAssertEqual(corrector.evaluate("teh").replacement, "the")
        XCTAssertEqual(corrector.evaluate("Teh").replacement, "The")
        XCTAssertEqual(corrector.evaluate("recieve").replacement, "receive")
        XCTAssertEqual(corrector.evaluate("untill").replacement, "until")
        XCTAssertEqual(corrector.evaluate("becuase").replacement, "because")
    }

    func testFirstLetterOneKeyOffIsFound() {
        // The search used to look only in the typed first and second letters' buckets.
        XCTAssertEqual(corrector.evaluate("rhe").replacement, "the")
        XCTAssertEqual(corrector.evaluate("yhe").replacement, "the")
        XCTAssertEqual(corrector.evaluate("qhat").replacement, "what")
    }

    func testCommonTranspositionsStillCorrect() {
        for (typed, expected) in [("hte", "the"), ("waht", "what"), ("wierd", "weird")] {
            XCTAssertEqual(corrector.evaluate(typed).replacement, expected)
        }
    }

    func testQuietCorrectionLeavesAmbiguousWordsAndNamesAlone() {
        for word in ["hwo", "ne", "ti", "ger", "Dahlsson"] {
            XCTAssertNil(corrector.evaluate(word).replacement, word)
        }
        // Distance-based key costs separate what yes/no adjacency could not: g sits beside h
        // but two keys from c, v sits right under g, and "really" is one doubled letter away
        // where "relay" needs a swap.
        XCTAssertEqual(corrector.evaluate("gello").replacement, "hello")
        XCTAssertEqual(corrector.evaluate("vood").replacement, "good")
        XCTAssertEqual(corrector.evaluate("realy").replacement, "really")
        XCTAssertEqual(corrector.evaluate("woed").replacement, "word")
        XCTAssertEqual(corrector.evaluate("usabke").replacement, "usable")
    }

    func testPersonalVocabularyReplacementInvalidatesCachedCorrections() {
        let engine = corrector
        XCTAssertEqual(engine.evaluate("hte").replacement, "the")
        engine.setPersonalWords(["Hte", "Dahlsson"])
        XCTAssertEqual(engine.evaluate("hte").replacement, "Hte", "a saved word is written the way it was saved")
        engine.setPersonalWords(["Dahlsson"])
        XCTAssertEqual(engine.evaluate("hte").replacement, "the")
        engine.learn("hte")
        engine.setPersonalWords([])
        XCTAssertNil(engine.evaluate("hte").replacement)
    }

    func testPersonalPhrasesProtectTheirIndividualWords() {
        let engine = corrector
        engine.setPersonalWords(["Hte Waht", "Wierd-Dahlsson"])
        for word in ["hte", "waht", "wierd", "Dahlsson"] {
            XCTAssertNil(engine.evaluate(word).replacement, word)
        }
        engine.setPersonalWords([])
        XCTAssertEqual(engine.evaluate("waht").replacement, "what")
    }

    func testTwoEditTyposOnlyOnLongCommonWords() {
        XCTAssertEqual(corrector.evaluate("tommorow").replacement, "tomorrow")
        XCTAssertEqual(corrector.evaluate("definately").replacement, "definitely")
        // One substitution away is confident at any length past two letters.
        XCTAssertEqual(corrector.evaluate("qzark").replacement, "quark")
    }

    func testNeverShrinksIntoATwoLetterWord() {
        // "usa" is a deletion away from "us"; it is recased instead.
        XCTAssertEqual(corrector.evaluate("usa").replacement, "USA")
        for typed in ["uss", "ann", "ohh"] {
            let fix = corrector.evaluate(typed).replacement
            XCTAssertTrue(fix == nil || fix!.count >= 3, "\(typed) -> \(fix ?? "nil")")
        }
    }

    func testTextingWordsStayAsTyped() {
        for word in ["lol", "idk", "btw", "omg", "fyi", "asap", "tbh", "app", "gonna", "lmk", "pls", "thx", "bday"] {
            XCTAssertNil(corrector.evaluate(word).replacement, word)
        }
    }

    func testOrdinaryWordsAreOffered() {
        XCTAssertEqual(WordListTests.list.lookup("duck")?.isSuggestible, true)
    }

    func testKnownWordsAreLeftAlone() {
        XCTAssertNil(corrector.evaluate("the").replacement)
        XCTAssertNil(corrector.evaluate("Hello").replacement)
        XCTAssertNil(corrector.evaluate("HELLO").replacement)
        XCTAssertNil(corrector.evaluate("may").replacement)
        XCTAssertNil(corrector.evaluate("john's").replacement)
        XCTAssertNil(corrector.evaluate("Monday").replacement)
    }

    func testProperNounsAndAcronymsAreRecasedOnlyFromLowercase() {
        XCTAssertEqual(corrector.evaluate("monday").replacement, "Monday")
        XCTAssertEqual(corrector.evaluate("i'm").replacement, "I'm")
        XCTAssertEqual(corrector.evaluate("nasa").replacement, "NASA")
        XCTAssertNil(corrector.evaluate("MONDAY").replacement)
        // Two-letter symbols from the dictionary never recase ordinary typing.
        XCTAssertNil(corrector.evaluate("ac").replacement)
    }

    func testNeverCorrectsAcronymsMixedCaseDigitsOrTinyWords() {
        XCTAssertNil(corrector.evaluate("iPhone").replacement)
        XCTAssertNil(corrector.evaluate("ASAP").replacement)
        XCTAssertNil(corrector.evaluate("3rd").replacement)
        XCTAssertEqual(corrector.evaluate("3rd").suggestions, [])
        XCTAssertNil(corrector.evaluate("xq").replacement)
        XCTAssertNil(corrector.evaluate("ok").replacement)
    }

    func testOverridesFixContractionsAndI() {
        XCTAssertEqual(corrector.evaluate("i").replacement, "I")
        XCTAssertEqual(corrector.evaluate("im").replacement, "I'm")
        XCTAssertEqual(corrector.evaluate("dont").replacement, "don't")
        XCTAssertEqual(corrector.evaluate("Dont").replacement, "Don't")
        XCTAssertEqual(corrector.evaluate("DONT").replacement, "DON'T")
        XCTAssertEqual(corrector.evaluate("hes").replacement, "he's")
        XCTAssertEqual(corrector.evaluate("alot").replacement, "a lot")
    }

    func testLearnedWordsStopCorrections() {
        let corrector = self.corrector
        XCTAssertFalse(corrector.evaluate("zayd").suggestions.isEmpty)
        corrector.learn("Zayd")
        XCTAssertNil(corrector.evaluate("zayd").replacement)
        XCTAssertEqual(corrector.evaluate("Zayd").suggestions.first, Suggestion(text: "Zayd", kind: .literal))
        XCTAssertTrue(corrector.learnedWords.contains("zayd"))
    }

    func testSuggestionSlotsShapes() {
        let typo = corrector.evaluate("teh")
        XCTAssertEqual(typo.suggestions.first, Suggestion(text: "teh", kind: .literal))
        XCTAssertEqual(typo.suggestions[1].text, "the")
        XCTAssertTrue(typo.suggestions[1].autoApplies)
        XCTAssertEqual(typo.suggestions.count, 3)

        let partial = corrector.evaluate("tomorr")
        XCTAssertEqual(partial.suggestions.first?.kind, .literal)
        XCTAssertTrue(partial.suggestions.contains(where: { $0.text == "tomorrow" }))

        let valid = corrector.evaluate("th")
        XCTAssertEqual(valid.suggestions.first, Suggestion(text: "th", kind: .literal))
        XCTAssertEqual(valid.suggestions.dropFirst().map(\.kind), [.completion, .completion])
        XCTAssertFalse(valid.suggestions.contains(where: \.autoApplies))

        let capital = corrector.evaluate("Tomorr")
        XCTAssertTrue(capital.suggestions.contains(where: { $0.text == "Tomorrow" }))
    }

    func testComposingWordDetection() {
        XCTAssertEqual(Autocorrector.composingWord(before: "hello wor", after: nil), "wor")
        XCTAssertEqual(Autocorrector.composingWord(before: "hello wor", after: ""), "wor")
        XCTAssertEqual(Autocorrector.composingWord(before: "wor", after: " next"), "wor")
        XCTAssertEqual(Autocorrector.composingWord(before: "don\u{2019}", after: nil), "don'")
        XCTAssertEqual(Autocorrector.composingWord(before: "(hello", after: nil), "hello")
        XCTAssertNil(Autocorrector.composingWord(before: "hello wor", after: "ld"))
        XCTAssertNil(Autocorrector.composingWord(before: "hello ", after: nil))
        XCTAssertNil(Autocorrector.composingWord(before: "3rd", after: nil))
        XCTAssertNil(Autocorrector.composingWord(before: nil, after: nil))
        XCTAssertNil(Autocorrector.composingWord(before: "", after: nil))
        XCTAssertNil(Autocorrector.composingWord(before: String(repeating: "a", count: 30), after: nil))
    }

    func testCasingHelper() {
        XCTAssertEqual(Autocorrector.Casing(of: "hello"), .lower)
        XCTAssertEqual(Autocorrector.Casing(of: "Hello"), .capitalized)
        XCTAssertEqual(Autocorrector.Casing(of: "I"), .capitalized)
        XCTAssertEqual(Autocorrector.Casing(of: "I'm"), .capitalized)
        XCTAssertEqual(Autocorrector.Casing(of: "NASA"), .upper)
        XCTAssertEqual(Autocorrector.Casing(of: "iPhone"), .mixed)
        XCTAssertEqual(Autocorrector.cased("the", like: .capitalized), "The")
        XCTAssertEqual(Autocorrector.cased("I'm", like: .capitalized), "I'm")
        XCTAssertEqual(Autocorrector.cased("don't", like: .upper), "DON'T")
    }
}

/// The person's own words and contact names in the suggestion row (offered, never applied).
final class OwnWordCompletionTests: XCTestCase {
    private func texts(_ evaluation: Evaluation) -> [String] { evaluation.suggestions.map(\.text) }

    func testASavedWordCompletesInItsSavedSpelling() {
        let engine = Autocorrector(words: WordListTests.list)
        XCTAssertFalse(texts(engine.evaluate("dahls")).contains("Dahlsson"), "unknown before it is saved")
        engine.setPersonalWords(["Dahlsson"])
        let evaluation = engine.evaluate("dahls")
        XCTAssertTrue(texts(evaluation).contains("Dahlsson"))
        XCTAssertFalse(evaluation.suggestions.contains { $0.text == "Dahlsson" && $0.autoApplies }, "offered, never applied")
        engine.setPersonalWords([])
        XCTAssertFalse(texts(engine.evaluate("dahls")).contains("Dahlsson"), "removing the word removes the suggestion")
    }

    func testEachWordOfASavedPhraseCompletes() {
        let engine = Autocorrector(words: WordListTests.list)
        engine.setPersonalWords(["Qorvex Dahlsson"])
        XCTAssertTrue(texts(engine.evaluate("qorv")).contains("Qorvex"))
        XCTAssertTrue(texts(engine.evaluate("Dahls")).contains("Dahlsson"))
    }

    func testAContactNameCompletes() {
        let engine = Autocorrector(words: WordListTests.list)
        engine.setSystemLexicon(names: ["Zbigniew Okonkwo"], replacements: [:])
        XCTAssertTrue(texts(engine.evaluate("zbig")).contains("Zbigniew"))
        XCTAssertTrue(texts(engine.evaluate("okon")).contains("Okonkwo"))
    }

    func testOwnWordsNeedTwoLettersAndNeverRepeatTheTypedWord() {
        let engine = Autocorrector(words: WordListTests.list)
        engine.setPersonalWords(["Dahlsson"])
        XCTAssertFalse(texts(engine.evaluate("d")).contains("Dahlsson"))
        XCTAssertEqual(texts(engine.evaluate("dahlsson")), ["dahlsson", "Dahlsson"], "as typed, and as saved; no completion of itself")
    }

    func testOwnWordsTakeAtMostTwoSlotsAndComeFirst() {
        let engine = Autocorrector(words: WordListTests.list)
        engine.setPersonalWords(["Helmsdeep", "Helmsgard", "Helmsford"])
        let suggestions = texts(engine.evaluate("helms"))
        XCTAssertLessThanOrEqual(suggestions.filter { $0.hasPrefix("Helms") && $0.count == 9 }.count, Autocorrector.maxOwnCompletions)
        XCTAssertLessThanOrEqual(suggestions.count, Autocorrector.maxSuggestions)
    }

    /// Contacts can hold thousands of names; the commonest words must still reach the row.
    func testContactsWaitForThreeLettersAndTakeOneSlot() {
        let engine = Autocorrector(words: WordListTests.list)
        let before = texts(engine.evaluate("th"))
        engine.setSystemLexicon(names: ["Thandiwe Thorvaldsen", "Thembeka Thibodeaux"], replacements: [:])
        XCTAssertEqual(texts(engine.evaluate("th")), before, "two letters: the dictionary's row, as before")
        let row = texts(engine.evaluate("thib"))
        XCTAssertTrue(row.contains("Thibodeaux"))
        engine.setSystemLexicon(names: ["Thandiwe Thandeka Thandolwethu"], replacements: [:])
        XCTAssertEqual(texts(engine.evaluate("thand")).filter { $0.hasPrefix("Thand") }.count, 1)
    }

    /// A contact's "Will" or "Grace" never puts a capital on an everyday word.
    func testAContactNameTheDictionaryKnowsIsLeftToTheDictionary() {
        let engine = Autocorrector(words: WordListTests.list)
        engine.setSystemLexicon(names: ["Grace Willis", "Will Boss"], replacements: [:])
        for prefix in ["gra", "wil", "bos"] {
            XCTAssertFalse(texts(engine.evaluate(prefix)).contains { $0.first?.isUppercase == true && $0.count > 3 },
                           "\(prefix): no capitalized contact word")
        }
    }

    /// The person's own words come before a contact's.
    func testOwnWordsComeBeforeContacts() {
        let engine = Autocorrector(words: WordListTests.list)
        engine.setSystemLexicon(names: ["Qorvella"], replacements: [:])
        XCTAssertTrue(texts(engine.evaluate("qorv")).contains("Qorvella"))
        engine.setPersonalWords(["Qorvex"])
        // "qorv" keeps its best correction ("work"), which leaves one slot to complete.
        let row = texts(engine.evaluate("qorv"))
        XCTAssertTrue(row.contains("Qorvex"), "\(row)")
        XCTAssertFalse(row.contains("Qorvella"), "\(row)")
    }
}
