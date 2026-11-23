// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class LowercaseAutocorrectTests: XCTestCase {
    private var corrector: Autocorrector { Autocorrector(words: WordListTests.list) }

    func testLowercaseKeepsSpellingAndSpaceRepairsWithoutDictionaryCapitals() {
        let corrector = corrector
        for (typed, expected) in [("im", "i'm"), ("teh", "the"), ("inbhouston", "in houston"),
                                  ("butcibpressed", "but i pressed"), ("youxarexproud", "you are proud")] {
            XCTAssertEqual(corrector.evaluate(typed, preserveLowercase: true).replacement, expected, typed)
            let edit = TypingEdits.separator(" ", typedWord: typed, before: typed, after: "", corrector: corrector,
                                             preserveLowercase: true)
            XCTAssertEqual(edit.insert, expected + " ", typed)
            XCTAssertEqual(TypingEdits.revert(edit.correction!, before: expected + " ")?.insert, typed)
        }
    }

    func testRecasingOnlyDisappearsAndMemoTracksPreference() {
        let corrector = corrector
        XCTAssertEqual(corrector.evaluate("monday").replacement, "Monday")
        XCTAssertNil(corrector.evaluate("monday", preserveLowercase: true).replacement)
        XCTAssertEqual(corrector.evaluate("monday").replacement, "Monday")
        let evaluation = corrector.evaluate("mond", preserveLowercase: true)
        XCTAssertFalse(evaluation.suggestions.isEmpty)
        XCTAssertTrue(evaluation.suggestions.allSatisfy { $0.text == $0.text.lowercased() })
        XCTAssertEqual(Set(evaluation.suggestions.map(\.text)).count, evaluation.suggestions.count)
    }

    func testDeliberateCapitalsNamesAndAuthoredPhrases() {
        let corrector = corrector
        XCTAssertEqual(corrector.evaluate("Teh", autoCapitalized: false, preserveLowercase: true).replacement, "The")
        XCTAssertNil(corrector.evaluate("NASA", preserveLowercase: true).replacement)
        XCTAssertNil(corrector.evaluate("iPhone", preserveLowercase: true).replacement)
        corrector.setSystemLexicon(names: ["Xylophora"], replacements: ["omw": "On My Way!"])
        XCTAssertNil(corrector.evaluate("xylophora", preserveLowercase: true).replacement)
        XCTAssertEqual(corrector.evaluate("omw", preserveLowercase: true).replacement, "On My Way!")
    }

    func testPreferenceMigrationAndRoundTrip() throws {
        let old = try JSONDecoder().decode(KeyboardPreferences.self, from: Data(#"{"autocorrectEnabled":false}"#.utf8))
        XCTAssertTrue(old.autoCapitalizationEnabled)
        XCTAssertFalse(old.autocorrectEnabled)
        let off = KeyboardPreferences(autoCapitalizationEnabled: false)
        XCTAssertEqual(try JSONDecoder().decode(KeyboardPreferences.self, from: JSONEncoder().encode(off)), off)
    }
}
