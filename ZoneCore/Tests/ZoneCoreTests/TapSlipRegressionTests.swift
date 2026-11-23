// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class TapSlipRegressionTests: XCTestCase {
    func testReportedContractionsAndTerminalSpaceSlips() {
        let corrector = Autocorrector(words: WordListTests.list)
        for (typed, expected) in [
            ("Hesxhavingxfun", "He's having fun"), ("hesvhavingvfun", "he's having fun"),
            ("he'sxhavingxfun", "he's having fun"), ("shesvhavingvfun", "she's having fun"),
            ("socmuchcfunx", "so much fun"), ("socmuchcfunv", "so much fun"),
            ("socmuchcfunc", "so much fun"), ("havingxfunx", "having fun"),
            ("fuckxyeah", "fuck yeah"), ("fuckxyeahx", "fuck yeah"),
            ("Fuckxthisx", "Fuck this"), ("shitvhappens", "shit happens")
        ] {
            XCTAssertEqual(corrector.evaluate(typed, autoCapitalized: true).replacement, expected, typed)
        }
    }

    func testSlippedTailNeverStripsOrdinaryWordsOrInventsFuzzyPhrases() {
        let corrector = Autocorrector(words: WordListTests.list)
        for word in ["fox", "box", "complex", "music", "panic", "civic", "have", "funx", "socmuchxfox", "getxbox"] {
            let result = corrector.evaluate(word)
            if ["socmuchxfox", "getxbox"].contains(word) {
                XCTAssertTrue(result.replacement?.hasSuffix(word == "getxbox" ? "box" : "fox") ?? true, word)
            } else {
                XCTAssertFalse(result.replacement?.contains(" ") ?? false, word)
            }
        }
        corrector.learn("hes")
        XCTAssertNotEqual(corrector.evaluate("hesxhavingxfun").replacement, "he's having fun")
        corrector.setPersonalWords(["he's"])
        XCTAssertEqual(corrector.evaluate("he'sxhavingxfun").replacement, "he's having fun")
        XCTAssertNotEqual(corrector.evaluate("duckxyeah").replacement, "fuck yeah")
    }

    func testCasualCleanupPreservesMatchedExplicitCompoundsAndPhrases() {
        for style in [TextStyle.casual, .veryCasual] {
            for word in ["Auto-Correct Pro", "Pre-Auto-Correct", "Why?? Pro"] {
                XCTAssertEqual(style.apply(word, personalWords: [word]), word, "\(style): \(word)")
            }
            XCTAssertTrue(style.apply("use Auto-Correct Pro with auto-correct", personalWords: ["Auto-Correct Pro"])
                .contains("Auto-Correct Pro with autocorrect"))
            XCTAssertTrue(style.apply("use Auto-Correct Pro and Pre-Auto-Correct",
                personalWords: ["Auto-Correct Pro", "Pre-Auto-Correct"]).contains("Auto-Correct Pro and Pre-Auto-Correct"))
            XCTAssertTrue(style.apply("auto-correct is on", personalWords: ["Auto-Correct Pro"])
                .lowercased().contains("autocorrect is on"))
        }
    }

    func testCasualCleanupProtectsExplicitPossessivesWithoutProtectingOtherCompounds() {
        for style in [TextStyle.casual, .veryCasual] {
            for suffix in ["'s", "’s", "'", "’"] {
                let output = style.apply("Auto-Correct" + suffix + " settings", personalWords: ["Auto-Correct"])
                XCTAssertTrue(output.lowercased().contains("auto-correct" + suffix), output)
            }
            XCTAssertTrue(style.apply("Pre-Auto-Correct's settings", personalWords: ["Auto-Correct"])
                .lowercased().contains("pre-autocorrect's"))
        }
    }

    func testCasualRecognizerQuestionRunsCollapseButSpokenCommandsAndLiteralsRemain() {
        for style in [TextStyle.casual, .veryCasual] {
            for input in ["why hasn't it been pushed??", "why hasn't it been pushed? ?", "why hasn't it been pushed???"] {
                XCTAssertEqual(style.apply(input).filter { $0 == "?" }.count, 1, input)
            }
            XCTAssertEqual(style.apply("why question mark question mark").filter { $0 == "?" }.count, 2)
            XCTAssertTrue(style.apply("`what??`").contains("what??"))
            XCTAssertTrue(style.apply("auto-correct is on").lowercased().contains("autocorrect is on"))
            XCTAssertTrue(style.apply("`auto-correct`").contains("auto-correct"))
            XCTAssertTrue(style.apply("Auto-Correct", personalWords: ["Auto-Correct"]).contains("Auto-Correct"))
        }
        XCTAssertTrue(TextStyle.formal.apply("really??").hasSuffix("??"))
    }
}
