// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// What a hand correction may teach My Words. Zayd found misspellings there on 2026-11-16: any
/// word typed over a selected word was saved and then shielded from autocorrect.
final class CorrectionLearningGateTests: XCTestCase {
    private func corrector() throws -> Autocorrector { Autocorrector(words: try XCTUnwrap(WordList.shared)) }

    func testAMisspellingTypedOverAnotherWordIsASlip() throws {
        let corrector = try corrector()
        XCTAssertNotNil(corrector.evaluate("definitly").replacement)
        XCTAssertTrue(corrector.isSlip("definitly", replacing: "defiantly"))
        XCTAssertTrue(corrector.isSlip("recieve", replacing: "relieve"))
        // At the start of a sentence the keyboard's own capital does not make it a name.
        XCTAssertTrue(corrector.isSlip("Recieve", replacing: "Relieve", autoCapitalized: true))
    }

    func testANewWordAutocorrectLeavesAloneIsNotASlip() throws {
        let corrector = try corrector()
        for word in ["zaydwick", "qorvexa", "supabase", "tailscale", "xcodegen"] {
            XCTAssertFalse(corrector.isSlip(word, replacing: "something"), word)
        }
    }

    /// The gate first written for this refused 23 of 64 unknown names and brands, because they
    /// sit one key from a common word. A capital the person chose says it is a name.
    func testANameOneKeyFromACommonWordIsLearnedWhenThePersonCapitalizedIt() throws {
        let corrector = try corrector()
        for name in ["Brex", "Stytch", "Trino", "Dagster", "Raycast", "Pinecone"] where !corrector.recognizes(name) {
            XCTAssertNotNil(corrector.evaluate(name).replacement, "\(name) is one autocorrect would change")
            XCTAssertFalse(corrector.isSlip(name, replacing: "something"), name)
        }
        XCTAssertFalse(corrector.isSlip("openRouterr", replacing: "something"), "an inner capital is chosen too")
    }

    /// Lowercase, the same names are refused once. Autocorrect then changes the word, and typing
    /// it again over that change is the person refusing the change.
    func testALowercaseNearMissIsLearnedOnTheSecondTry() throws {
        let corrector = try corrector()
        let fix = try XCTUnwrap(corrector.evaluate("frostbyte").replacement)
        XCTAssertTrue(corrector.isSlip("frostbyte", replacing: "something"))
        XCTAssertFalse(corrector.isSlip("frostbyte", replacing: fix))
    }

    func testAWordTheKeyboardKnowsIsNotASlip() throws {
        let corrector = try corrector()
        XCTAssertFalse(corrector.isSlip("their", replacing: "there"))
        corrector.setPersonalWords(["frostbyte"])
        XCTAssertFalse(corrector.isSlip("frostbyte", replacing: "something"))
    }
}
