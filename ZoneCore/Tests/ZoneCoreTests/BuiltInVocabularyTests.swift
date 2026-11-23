// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// Words every install knows: "Zayd" for a friend's phone that has never been taught the name,
/// and the texting spellings "imma" and "yall" in the casual styles.
final class BuiltInVocabularyTests: XCTestCase {
    func testAaliaIsSpelledRightWithAnEmptyDictionary() {
        for heard in ["Alia", "Aaliya", "Aliya", "Aaliyah", "Aliyah", "alia", "ALIA"] {
            XCTAssertEqual(TextStyle.casual.apply("I told \(heard) about it"), "I told Aalia about it", heard)
            XCTAssertEqual(TextStyle.formal.apply("\(heard) is here"), "Aalia is here.", heard)
        }
        XCTAssertEqual(TextStyle.casual.insertion(of: "Alia said hi", contextBefore: nil,
            fieldCapitalizesSentences: false, opening: .lowercase), "Aalia said hi")
        XCTAssertEqual(TextStyle.casual.apply("that's Alia’s car"), "That's Aalia’s car")
        XCTAssertEqual(TextStyle.casual.apply("that's Alia's car"), "That's Aalia's car")
    }

    func testAaliaRespectsPersonalSpellingsAndOtherWords() {
        for name in ["Alia", "Aliya", "Aaliyah"] {
            XCTAssertEqual(TextStyle.casual.apply("I told \(name)", personalWords: [name]), "I told \(name)")
        }
        XCTAssertEqual(TextStyle.casual.apply("Ali and Alice saw an alias"), "Ali and Alice saw an alias")
        XCTAssertEqual(TextStyle.casual.apply("Alia-team and xAlia and Alia2"), "Alia-team and xAlia and Alia2")
        XCTAssertEqual(TextStyle.formal.apply("this includes, inter alia, Alia"), "This includes, inter alia, Aalia.")
        XCTAssertEqual(BuiltInVocabulary.correctingMishearings("INTER\tALIA and alia", personalWords: []),
                       "INTER\tALIA and Aalia")
    }

    func testZaydIsSpelledRightWithAnEmptyDictionary() {
        for heard in ["Zaid", "Zayed", "Zade"] {
            XCTAssertEqual(TextStyle.casual.apply("I told \(heard) about it"), "I told Zayd about it", heard)
            XCTAssertEqual(TextStyle.formal.apply("\(heard) is here"), "Zayd is here.", heard)
        }
        XCTAssertEqual(TextStyle.casual.insertion(of: "Zaid said hi", contextBefore: nil, fieldCapitalizesSentences: true),
                       "Zayd said hi")
        // The name survives a lowercase Shift.
        XCTAssertEqual(TextStyle.casual.insertion(of: "Zaid said hi", contextBefore: nil, fieldCapitalizesSentences: false,
                                                  opening: .lowercase), "Zayd said hi")
    }

    func testEveryListedMishearingBecomesZayd() {
        for heard in BuiltInVocabulary.mishearings["Zayd"]! + ["zaid", "ZAID"] {
            XCTAssertEqual(TextStyle.casual.apply("I told \(heard) about it"), "I told Zayd about it", heard)
            XCTAssertEqual(TextStyle.veryCasual.apply("\(heard) said hi"), "Zayd said hi", heard)
            XCTAssertEqual(TextStyle.formal.apply("I told \(heard), then left"), "I told Zayd, then left.", heard)
        }
        XCTAssertEqual(TextStyle.casual.apply("Zaid Khan called"), "Zayd Khan called")
    }

    func testPossessivesKeepTheirEnding() {
        XCTAssertEqual(TextStyle.casual.apply("that's Zaid's car"), "That's Zayd's car")
        XCTAssertEqual(TextStyle.casual.apply("that's Zade’s car"), "That's Zayd’s car")
        XCTAssertEqual(TextStyle.casual.apply("ask Dahlson's team", personalWords: ["Dahlsson"]), "Ask Dahlsson's team")
    }

    func testZaydDoesNotTouchEverydayWordsOrOtherNames() {
        XCTAssertEqual(TextStyle.casual.apply("he said the side was sad"), "He said the side was sad")
        XCTAssertEqual(TextStyle.casual.apply("Saad and Sayed came"), "Saad and Sayed came")
        // Real names that sound close: the built-in list is closed, so a stranger's friends keep theirs.
        for name in ["Zahid", "Zaida", "Zayda", "Zada", "Zod", "Zoid", "Zed", "Said", "Saeed", "Sayid", "Zayn", "Zane", "Sade", "Jade", "Zaheed"] {
            XCTAssertEqual(TextStyle.casual.apply("I told \(name) about it"), "I told \(name) about it", name)
        }
        XCTAssertEqual(TextStyle.casual.apply("Zaids everywhere"), "Zaids everywhere")
    }

    func testAFriendNamedZaidKeepsTheirSpelling() {
        // Their own word wins over the built-in one, and its sound-alikes follow their spelling.
        XCTAssertEqual(TextStyle.casual.apply("I told Zaid", personalWords: ["Zaid"]), "I told Zaid")
        XCTAssertEqual(TextStyle.casual.apply("I told Zade", personalWords: ["Zaid"]), "I told Zaid")
    }

    func testPeopleWhoAddZaydThemselvesKeepTheSoundAlikeMatcher() {
        // On a phone that added Zayd to its own words, unlisted sound-alikes still resolve.
        XCTAssertEqual(TextStyle.casual.apply("I told Zaydie", personalWords: ["Zayd"]), "I told Zayd")
    }

    func testCasualWritesImmaAndYallLowercaseWithoutApostrophes() {
        // (heard, casual, very casual). Casual still capitalizes a sentence's other first words.
        let cases = [
            ("I'ma head out", "imma head out", "imma head out"),
            ("I'mma head out", "imma head out", "imma head out"),
            ("Imma head out", "imma head out", "imma head out"),
            ("Ima head out", "imma head out", "imma head out"),
            ("ok so ima go", "Ok so imma go", "ok so imma go"),
            ("Y'all ready?", "yall ready?", "yall ready?"),
            ("are ya'll coming", "Are yall coming", "are yall coming"),
            ("see y’all there", "See yall there", "see yall there"),
            ("Yall good", "yall good", "yall good"),
            ("done. Imma sleep", "Done. imma sleep", "done imma sleep"),
        ]
        for (heard, casual, veryCasual) in cases {
            XCTAssertEqual(TextStyle.casual.apply(heard), casual, heard)
            XCTAssertEqual(TextStyle.veryCasual.apply(heard), veryCasual, heard)
        }
    }

    func testTextingSpellingsLeaveNamesAndOtherWordsAlone() {
        XCTAssertEqual(TextStyle.casual.apply("I told Ima the plan"), "I told Ima the plan")
        XCTAssertEqual(TextStyle.casual.apply("Ima Hogg was a governor's daughter"), "Ima Hogg was a governor's daughter")
        XCTAssertEqual(TextStyle.casual.apply("I'm a nurse"), "I'm a nurse")
        XCTAssertEqual(TextStyle.casual.apply("Emma and Ali went to Yale"), "Emma and Ali went to Yale")
        XCTAssertEqual(TextStyle.casual.apply("we all left"), "We all left")
    }

    func testFormalKeepsTheRecognizersSpelling() {
        XCTAssertEqual(TextStyle.formal.apply("Y'all ready"), "Y'all ready.")
        XCTAssertEqual(TextStyle.formal.apply("I'ma head out"), "I'ma head out.")
    }

    func testBuiltInWordsAreAddedOnceAndPersonalSpellingsWin() {
        XCTAssertEqual(BuiltInVocabulary.withAll([]), ["Zayd", "Aalia", "imma", "yall"])
        XCTAssertEqual(BuiltInVocabulary.withNames(["zayd", "Hooke"]), ["zayd", "Hooke", "Aalia"])
        XCTAssertEqual(BuiltInVocabulary.withNames(["Hooke"]), ["Hooke", "Zayd", "Aalia"])
    }

    func testAutocorrectLeavesBuiltInWordsAlone() {
        // Fresh, and after the keyboard clears the person's words (no Full Access).
        let fresh = Autocorrector(words: WordListTests.list)
        let cleared = Autocorrector(words: WordListTests.list)
        cleared.setPersonalWords([])
        for corrector in [fresh, cleared] {
            for word in ["Zayd", "Aalia", "imma", "Imma", "yall"] {
                XCTAssertNil(corrector.evaluate(word).replacement, word)
            }
            // A name typed in lowercase only gets its capital, as swipe and dictation write it.
            XCTAssertEqual(corrector.evaluate("zayd").replacement, "Zayd")
            XCTAssertEqual(corrector.evaluate("aalia").replacement, "Aalia")
        }
    }
}
