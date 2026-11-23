// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class SpelledLettersTests: XCTestCase {
    private func check(_ said: String, _ written: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(SpelledLetters.joining(said), written, file: file, line: line)
    }

    func testSpelledWordsAreJoined() {
        check("My name is D-A-A-N.", "My name is Daan.")
        check("it's a S-A-A-S company", "it's a Saas company")
        check("My name is D A A N.", "My name is Daan.")
        check("it's a S A A S company", "it's a Saas company")
        check("H A W A I I", "Hawaii")
        check("spelled e-m-a-i-l", "spelled email")
        check("It's N-I-K-A's turn", "It's Nika's turn")
    }

    func testDoubleWritesTheLetterTwice() {
        check("that's D double A N", "that's Daan")
        check("S double A S pricing", "Saas pricing")
        check("B double O K", "Book")
    }

    func testOrdinaryTextIsLeftAlone() {
        for said in ["an A B test", "X-Y plane", "plan B is fine", "a b c d", "I A", "D, A, A, N.",
                     "a double A battery", "A double A battery", "an X Y I think", "well-being",
                     "see example.com/a-b-c", "an up-to-date list", "user@a-b-c.com"] {
            check(said, said)
        }
        check("the letters X Y Z I think", "the letters XYZ I think")
        // A known acronym keeps its capitals; My Words keeps its own spelling.
        check("read the A P I", "read the API")
        XCTAssertEqual(SpelledLetters.joining("ask D A A N", personalWords: ["DaAn"]), "ask DaAn")
    }

    func testStylesWriteTheWord() {
        XCTAssertEqual(TextStyle.casual.apply("my name is D-A-A-N."), "My name is Daan")
        XCTAssertEqual(TextStyle.formal.apply("it's a S A A S company"), "It's a Saas company.")
        XCTAssertEqual(TextStyle.veryCasual.apply("my name is D double A N."), "my name is daan")
    }

    /// Zayd, November 15: "D A A N" came out spaced in capitals, and a spelling the recognizer
    /// wrote with periods ("D. A.N.") was left as it was. A spelled word is written as a name;
    /// Shift locked writes it in capitals, as it does the whole dictation.
    func testASpelledWordIsWrittenAsANameAndFollowsCapsLock() {
        func written(_ said: String, _ opening: DictationOpening) -> String {
            TextStyle.casual.insertion(of: said, contextBefore: "", fieldCapitalizesSentences: true, opening: opening)
        }
        XCTAssertEqual(written("D. A.N. D A A N", .automatic), "Dan Daan")
        XCTAssertEqual(written("D A A N", .capital), "Daan")
        XCTAssertEqual(written("D A A N", .lowercase), "Daan")
        XCTAssertEqual(written("D A A N", .capsLock), "DAAN")
        XCTAssertEqual(written("my name is D. A. A. N. and yours", .automatic), "My name is Daan and yours")
        XCTAssertEqual(written("spell d a a n please", .automatic), "Daan please")
        XCTAssertEqual(written("spell d a a n please", .capsLock), "DAAN PLEASE")
        XCTAssertEqual(TextStyle.veryCasual.apply("D. A.N."), "dan")
    }

    func testLettersWithPeriodsAreJoined() {
        for (said, joined) in [("D. A.N.", "Dan"), ("D. A. N.", "Dan"), ("D.A. N.", "Dan"),
                               ("D. A. A. N. D A N", "Daan D A N"), ("my name is D. A. N. and", "my name is Dan and")] {
            XCTAssertEqual(SpelledLetters.joiningDotted(said), joined, said)
        }
        // Initials before a name, two letters, lowercase abbreviations and commas stay.
        for said in ["J. R. R. Tolkien wrote it", "the U.S. team", "the U.S.A. team", "R.S.V.P. by then", "D.A.N.", "at 5 p.m. today", "i.e. this", "e.g. that",
                     "Plan B. A good one", "D, A, N", "A.M. and P.M."] {
            XCTAssertEqual(SpelledLetters.joiningDotted(said), said, said)
        }
    }
}
