// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// A dictation's first letter follows the keyboard's Shift key: lowercase Shift means a lowercase
/// start, even at the top of an empty field, unless the word is a name, "I", an acronym or a
/// personal word.
final class DictationOpeningTests: XCTestCase {
    func testLowercaseOpeningHandlesArticleContractionsAndOpeningPunctuation() {
        for (input, expected) in [
            ("A quick test", "a quick test"),
            ("A", "a"),
            ("Don't forget", "don't forget"),
            ("Don’t forget", "don’t forget"),
            ("“Hello there”", "“hello there”"),
            ("(Hello there)", "(hello there)"),
            ("\"Hello there\"", "\"hello there\""),
            ("John called", "John called"),
            ("Mark called", "Mark called"),
            ("Grace called", "Grace called"),
            ("John’s phone works", "John’s phone works"),
            ("Will you come", "will you come"),
            ("May I go", "may I go"),
        ] {
            XCTAssertEqual(TextStyle.casual.insertion(of: input, contextBefore: "",
                fieldCapitalizesSentences: false, opening: .lowercase), expected, input)
        }
    }

    func testCapsLockWritesTheWholeDictationInCapitals() {
        // Formal keeps the recognizer's commas; casual drops them by design.
        XCTAssertEqual(TextStyle.formal.insertion(of: "what, no way. I'm done", contextBefore: "",
                                                  fieldCapitalizesSentences: false, opening: .capsLock),
                       "WHAT, NO WAY. I'M DONE.")
        XCTAssertEqual(TextStyle.casual.insertion(of: "what, no way. I'm done", contextBefore: "",
                                                  fieldCapitalizesSentences: false, opening: .capsLock),
                       "WHAT NO WAY. I'M DONE")
        // Formal keeps its period; very casual is lowercase by design but caps lock still wins.
        XCTAssertEqual(TextStyle.formal.insertion(of: "see you soon", contextBefore: "Hi. ",
                                                  fieldCapitalizesSentences: true, opening: .capsLock), "SEE YOU SOON.")
        XCTAssertEqual(TextStyle.veryCasual.insertion(of: "see you soon", contextBefore: "",
                                                      fieldCapitalizesSentences: false, opening: .capsLock), "SEE YOU SOON")
        // Links keep their spelling.
        XCTAssertEqual(TextStyle.casual.insertion(of: "go to https://zayd.wtf now", contextBefore: "",
                                                  fieldCapitalizesSentences: false, opening: .capsLock), "GO TO https://zayd.wtf NOW")
    }

    func testExcitedMarksEverySentence() {
        // The recognizer capitalizes each sentence it ends; the style turns those stops excited.
        XCTAssertEqual(TextStyle.excited.apply("we won. It was close. See you at 3.5 p.m. tomorrow"),
                       "We won! It was close! See you at 3.5 p.m. tomorrow!")
        XCTAssertEqual(TextStyle.excited.apply("wait... really. \"Yes.\" Okay"), "Wait... really! \"Yes!\" Okay!")
        // Excited starts every sentence with a capital, as formal does, so a period the recognizer
        // left before a lowercase word ends a sentence too. Abbreviations and initials are not stops.
        XCTAssertEqual(TextStyle.excited.apply("hello there. this is great"), "Hello there! This is great!")
        XCTAssertEqual(TextStyle.excited.apply("ask dr. brown about it"), "Ask dr. brown about it!")
        XCTAssertEqual(TextStyle.excited.insertion(of: "we won. It was close", contextBefore: "",
                                                   fieldCapitalizesSentences: false, opening: .capsLock), "WE WON! IT WAS CLOSE!")
    }

    func testCapsLockDropsPunctuationOnlyWithTheBeta() {
        let text = "what, no way. I'm done; it's 3.5 out of 5. really?"
        XCTAssertEqual(TextStyle.formal.insertion(of: text, contextBefore: "", fieldCapitalizesSentences: false,
                                                  opening: .capsLock, capsLockDropsPunctuation: true),
                       "WHAT NO WAY IM DONE ITS 3.5 OUT OF 5 REALLY?")
        XCTAssertEqual(TextStyle.excited.insertion(of: "lets go", contextBefore: "", fieldCapitalizesSentences: false,
                                                   opening: .capsLock, capsLockDropsPunctuation: true), "LETS GO!")
        // Off: capitals only.
        XCTAssertEqual(TextStyle.formal.insertion(of: "what, no way", contextBefore: "", fieldCapitalizesSentences: false,
                                                  opening: .capsLock, capsLockDropsPunctuation: false), "WHAT, NO WAY.")
        // Other openings are untouched by the Beta.
        XCTAssertEqual(TextStyle.formal.insertion(of: "what, no way", contextBefore: "", fieldCapitalizesSentences: false,
                                                  opening: .capital, capsLockDropsPunctuation: true), "What, no way.")
    }

    /// Faces are marks, not punctuation: with caps lock dropping punctuation, a winky face wrote
    /// ")" and a crying face wrote ":(", a sad face.
    func testCapsLockDroppingPunctuationKeepsFaces() {
        func shout(_ said: String) -> String {
            TextStyle.casual.insertion(of: said, contextBefore: nil, fieldCapitalizesSentences: true, opening: .capsLock,
                                       capsLockDropsPunctuation: true)
        }
        XCTAssertEqual(shout("ok winky face"), "OK ;)")
        XCTAssertEqual(shout("miss you crying face"), "MISS YOU :'(")
        XCTAssertEqual(shout("we won, laughing face; it's done"), "WE WON :D ITS DONE")
        XCTAssertEqual(shout("I'm done; it's over winky face, bye"), "IM DONE ITS OVER ;) BYE")
    }

    func testLowercaseShiftLowersTheModelsCapitalAtAFieldStart() {
        // The recognizer writes "Hello"; the field does not auto-capitalize.
        XCTAssertEqual(TextStyle.casual.insertion(of: "Hello there", contextBefore: nil,
                                                  fieldCapitalizesSentences: false, opening: .lowercase), "hello there")
        XCTAssertEqual(TextStyle.formal.insertion(of: "Hello there.", contextBefore: "",
                                                  fieldCapitalizesSentences: false, opening: .lowercase), "hello there.")
        // After a finished sentence too: the user turned Shift off on purpose.
        XCTAssertEqual(TextStyle.casual.insertion(of: "Then we left", contextBefore: "Done. ",
                                                  fieldCapitalizesSentences: true, opening: .lowercase), "then we left")
    }

    func testLowercaseShiftKeepsNamesPronounAcronymsAndPersonalWords() {
        for kept in ["I think so", "I'm here", "NASA called", "iPhone works", "Paris is nice"] {
            XCTAssertEqual(TextStyle.casual.insertion(of: kept, contextBefore: nil,
                                                      fieldCapitalizesSentences: false, opening: .lowercase), kept, kept)
        }
        XCTAssertEqual(TextStyle.casual.insertion(of: "Zayd said yes", contextBefore: nil, fieldCapitalizesSentences: false,
                                                  personalWords: ["Zayd"], opening: .lowercase), "Zayd said yes")
    }

    func testLowercaseShiftLeavesLiteralsAlone() {
        XCTAssertEqual(TextStyle.casual.insertion(of: "https://Example.com", contextBefore: nil,
                                                  fieldCapitalizesSentences: false, opening: .lowercase), "https://Example.com")
        for literal in ["Hello.com", "Hello.com/CaseSensitive", "\"Hello.com\"", "(Hello.com/CaseSensitive)",
                        "`Hello`", "NASA", "iPhone"] {
            XCTAssertEqual(TextStyle.casual.insertion(of: literal, contextBefore: "",
                fieldCapitalizesSentences: false, opening: .lowercase), literal)
        }
    }

    func testSlangStaysLowercaseAfterSpokenSentenceMarksAndCapitalShift() {
        for opening in [DictationOpening.lowercase, .capital, .automatic] {
            for slang in ["imma", "yall"] {
                let output = TextStyle.casual.insertion(of: "Okay period \(slang) ready", contextBefore: "",
                    fieldCapitalizesSentences: true, opening: opening)
                XCTAssertTrue(output.hasSuffix(". \(slang) ready"), output)
            }
        }
    }

    func testCapitalShiftCapitalizesEvenMidSentence() {
        XCTAssertEqual(TextStyle.casual.insertion(of: "john said hi", contextBefore: "I met",
                                                  fieldCapitalizesSentences: true, opening: .capital), " John said hi")
        XCTAssertEqual(TextStyle.casual.insertion(of: "hello", contextBefore: nil,
                                                  fieldCapitalizesSentences: false, opening: .capital), "Hello")
        for (input, expected) in [("“hello there”", "“Hello there”"), ("(hello there)", "(Hello there)"),
                                  ("\"hello there\"", "\"Hello there\"")] {
            XCTAssertEqual(TextStyle.casual.insertion(of: input, contextBefore: "",
                fieldCapitalizesSentences: false, opening: .capital), expected)
        }
    }

    func testVeryCasualStaysLowercaseUnderACapitalShift() {
        XCTAssertEqual(TextStyle.veryCasual.insertion(of: "Hello there.", contextBefore: nil,
                                                      fieldCapitalizesSentences: true, opening: .capital), "hello there")
    }

    func testAutomaticIsTheOldBehavior() {
        let cases: [(String, String?, Bool)] = [
            ("hello there", nil, true), ("Hello there", nil, false), ("And then we left.", "It was late", true),
            ("then we left.", "We ate. ", true), ("Grok helped.", "and ", true),
        ]
        for style in TextStyle.allCases {
            for (text, context, caps) in cases {
                XCTAssertEqual(style.insertion(of: text, contextBefore: context, fieldCapitalizesSentences: caps, opening: .automatic),
                               style.insertion(of: text, contextBefore: context, fieldCapitalizesSentences: caps), "\(style) \(text)")
            }
        }
    }

    func testListsAndSpokenCommandsAreUnchangedByALowercaseShift() {
        XCTAssertEqual(TextStyle.casual.insertion(of: "um bullet point milk", contextBefore: "", fieldCapitalizesSentences: false,
                                                  opening: .lowercase), "• milk")
        XCTAssertEqual(TextStyle.casual.insertion(of: "new paragraph", contextBefore: "existing", fieldCapitalizesSentences: false,
                                                  opening: .lowercase), "\n\n")
    }

    /// Saved words and names are capitals under caps lock like everything else; a handle, a link
    /// and a face keep their own spelling.
    func testCapsLockCapitalizesMyWordsAndNamesButNotHandles() {
        func locked(_ text: String) -> String {
            TextStyle.casual.insertion(of: text, contextBefore: nil, fieldCapitalizesSentences: true,
                                       personalWords: ["Daan"], opening: .capsLock, handles: ["cold"])
        }
        XCTAssertEqual(locked("Tell Zayd and Daan the end."), "TELL ZAYD AND DAAN THE END")
        XCTAssertEqual(locked("My name is spelled D A A N."), "MY NAME IS DAAN")
        XCTAssertEqual(locked("Tell Daan at sign cold said hi smiley face"), "TELL DAAN @cold SAID HI :)")
        XCTAssertEqual(TextStyle.casual.insertion(of: "Tell Daan hi.", contextBefore: nil, fieldCapitalizesSentences: true,
                                                  personalWords: ["Daan"], opening: .capital), "Tell Daan hi")
    }

    func testExcitedKeepsSentenceEndingsWhenWritingNumbers() {
        XCTAssertEqual(TextStyle.excited.apply("Pick 6 or 8? Maybe seven. Bring tape."),
                       "Pick 6 or 8? Maybe 7! Bring tape!")
        XCTAssertEqual(TextStyle.excited.apply("Pick 6 or 8? Maybe seven! Bring tape."),
                       "Pick 6 or 8? Maybe 7! Bring tape!")
        XCTAssertEqual(TextStyle.excited.apply("1. Read the map.\n2. Get ready."), "1. Read the map.\n2. Get ready!")
        XCTAssertEqual(TextStyle.excited.apply("Is it 3.25? Wait... Maybe."), "Is it 3.25? Wait... Maybe!")
    }
}
