// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class SpokenFormattingTests: XCTestCase {
    func testExplicitDelimitersSurviveEveryStyle() {
        for style in TextStyle.allCases {
            XCTAssertEqual(style.apply("open parentheses hello close parentheses"), "(hello)")
            XCTAssertEqual(style.apply("open quote hello close quote"), "\"hello\"")
            XCTAssertEqual(style.apply("quote hello end quote"), "\"hello\"")
            XCTAssertEqual(style.apply("quote hello unquote"), "\"hello\"")
        }
    }

    func testQuoteCloserSynonymsPairConsistently() {
        for style in TextStyle.allCases {
            for opener in ["quote", "open quote", "begin quote"] {
                for closer in ["close quote", "end quote", "unquote"] {
                    XCTAssertEqual(style.apply("\(opener) hello \(closer)"), "\"hello\"")
                }
            }
        }
    }

    func testExplicitListCommandsSurviveStyles() {
        for style in TextStyle.allCases {
            let ending = style == .formal ? "." : (style == .excited ? "!" : "")
            XCTAssertEqual(style.apply("bullet point apples next bullet pears"), "• apples\n• pears" + ending)
            XCTAssertEqual(style.apply("start numbered list apples next item pears"), "1. apples\n2. pears" + ending)
        }
        XCTAssertEqual(TextStyle.veryCasual.apply("shopping new line bullet point milk next bullet eggs"), "shopping\n• milk\n• eggs")
        XCTAssertEqual(TextStyle.veryCasual.apply("bullet milk next bullet eggs"), "• milk\n• eggs")
        XCTAssertEqual(TextStyle.casual.apply("Bullet trains are fast."), "Bullet trains are fast")
        XCTAssertEqual(TextStyle.casual.apply("A bullet went past next bullet later."), "A bullet went past next bullet later")
    }

    func testOrdinaryListAndQuoteMentionsStayWords() {
        XCTAssertEqual(TextStyle.casual.apply("Add a bullet point to the slide."), "Add a bullet point to the slide")
        XCTAssertEqual(TextStyle.casual.apply("The next item is ready."), "The next item is ready")
        XCTAssertEqual(TextStyle.casual.apply("One apple and two pears."), "One apple and two pears")
        XCTAssertEqual(TextStyle.casual.apply("She said hello."), "She said hello")
        XCTAssertEqual(TextStyle.casual.apply("The word quote is in the report."), "The word quote is in the report")
        XCTAssertEqual(TextStyle.veryCasual.apply("`bullet point next bullet` https://example.com/bullet"), "`bullet point next bullet` https://example.com/bullet")
    }

    func testListsKeepProtectedNamesLiteralsAndExplicitPunctuation() {
        XCTAssertEqual(TextStyle.veryCasual.apply("bullet point NASA next bullet `API, CamelCase` end list done", personalWords: ["NASA"]),
                       "• NASA\n• `API, CamelCase`\ndone")
        XCTAssertEqual(TextStyle.veryCasual.apply("bullet point, milk, next bullet eggs."), "• milk\n• eggs")
        XCTAssertEqual(TextStyle.veryCasual.apply("bullet point milk insert comma next bullet eggs"), "• milk,\n• eggs")
        XCTAssertEqual(TextStyle.veryCasual.apply("start numbered list milk next item eggs next item bread end list done next item later"),
                       "1. milk\n2. eggs\n3. bread\ndone next item later")
        XCTAssertEqual(TextStyle.casual.apply("literal bullet point literal next bullet"), "bullet point next bullet")
        XCTAssertEqual(TextStyle.casual.apply("The open quote is printed here."), "The open quote is printed here")
        XCTAssertEqual(TextStyle.casual.apply("The quote hello close quote is an example."), "The quote hello close quote is an example")
    }

    func testLongExplicitListsRemainStable() {
        let text = "start numbered list first" + String(repeating: " next item item", count: 1_000)
        let expected = "1. first" + (2...1_001).map { "\n\($0). item" }.joined()
        XCTAssertEqual(TextStyle.veryCasual.apply(text), expected)
    }

    func testExplicitListsBeginANewBlockAtTheCursor() {
        for style in TextStyle.allCases {
            let ending = style == .formal ? "." : (style == .excited ? "!" : "")
            let list = "• milk\n• eggs" + ending
            for context in ["existing", "existing ", "https://example.com/path"] {
                XCTAssertEqual(style.insertion(of: "bullet point milk next bullet eggs", contextBefore: context,
                                               fieldCapitalizesSentences: true), "\n" + list)
            }
            for context in ["", "   ", "existing\n", "existing\n  "] {
                XCTAssertEqual(style.insertion(of: "bullet point milk next bullet eggs", contextBefore: context,
                                               fieldCapitalizesSentences: true), list)
            }
            XCTAssertEqual(style.apply("literal new paragraph"), "new paragraph" + ending)
            XCTAssertEqual(style.apply("bullet point milk end list done"), "• milk\ndone" + ending)
        }
    }

    func testBasicSpokenPunctuationAndSynonymsSurviveEveryStyle() {
        for style in TextStyle.allCases {
            for (input, expected) in [("hello period", "hello."), ("hello exclamation point", "hello!"),
                                      ("hello exclamation mark", "hello!"), ("hello semi colon world period", "hello; world."), ("hello question mark", "hello?"),
                                      ("ingredients colon milk semicolon eggs period", "ingredients: milk; eggs."),
                                      ("hello insert colon world insert semicolon done period", "hello: world; done.")] {
                let output = style == .veryCasual ? expected : expected.prefix(1).uppercased() + expected.dropFirst()
                XCTAssertEqual(style.apply(input), output, input)
            }
            for (input, expected) in [("period", "."), ("colon", ":"), ("semicolon", ";"), ("exclamation point", "!")] {
                XCTAssertEqual(style.insertion(of: input, contextBefore: "existing", fieldCapitalizesSentences: true), expected)
            }
        }
    }

    func testPeriodInGeologicalHistoricalAndAcademicContextsStaysLiteral() {
        for input in ["We studied the Jurassic period today", "The Cretaceous period ended", "The Victorian period lasted decades",
                      "Meet me after third period", "This is the first period", "We have history during second period"] {
            XCTAssertEqual(TextStyle.casual.apply(input), input, input)
        }
        XCTAssertEqual(TextStyle.casual.apply("We studied the Jurassic insert period"), "We studied the Jurassic.")
    }

    func testPunctuationWordMentionsAndEscapesStayLiteral() {
        for input in ["A period of time", "This period of time", "It lasted a short period", "Her period pain", "I have colon cancer", "Colon anatomy matters",
                      "Use a colon here", "The semicolon separates clauses", "A comma is punctuation", "An exclamation point is loud"] {
            XCTAssertEqual(TextStyle.casual.apply(input), input, input)
        }
        XCTAssertEqual(TextStyle.veryCasual.apply("literal period literal colon literal semicolon literal exclamation point"),
                       "period colon semicolon exclamation point")
        XCTAssertEqual(TextStyle.veryCasual.apply("`period colon semicolon` https://example.com/period"),
                       "`period colon semicolon` https://example.com/period")
        XCTAssertEqual(TextStyle.casual.apply("colon", personalWords: ["Colon"]), "Colon")
    }

    func testExplicitPunctuationSurvivesCasualCleanup() {
        for style in TextStyle.allCases {
            XCTAssertEqual(style.apply("hello insert comma world full stop"), style == .veryCasual ? "hello, world." : "Hello, world.")
            XCTAssertEqual(style.apply("hello comma world question mark"), style == .veryCasual ? "hello, world?" : "Hello, world?")
        }
        XCTAssertEqual(TextStyle.veryCasual.apply("um hello insert comma world"), "hello, world")
    }

    func testWhitespaceCommandsSurviveTrimAndCursorJoining() {
        for style in TextStyle.allCases {
            XCTAssertEqual(style.apply("new line"), "\n")
            XCTAssertEqual(style.apply("new paragraph"), "\n\n")
            XCTAssertEqual(style.insertion(of: "new line", contextBefore: "existing", fieldCapitalizesSentences: true), "\n")
            XCTAssertEqual(style.insertion(of: "insert comma", contextBefore: "existing", fieldCapitalizesSentences: true), ",")
            XCTAssertEqual(style.apply("hello new paragraph world new line"), style == .veryCasual ? "hello\n\nworld\n" : "Hello\n\nworld\n")
        }
    }

    func testOrdinarySpeechAndExistingLiteralsAreNotCommands() {
        XCTAssertEqual(TextStyle.casual.apply("She said hello."), "She said hello")
        XCTAssertEqual(TextStyle.casual.apply("Please quote the report."), "Please quote the report")
        XCTAssertEqual(TextStyle.casual.apply("Get a quote."), "Get a quote")
        XCTAssertEqual(TextStyle.casual.apply("Use an Oxford comma."), "Use an Oxford comma")
        XCTAssertEqual(TextStyle.casual.apply("A comma is punctuation."), "A comma is punctuation")
        XCTAssertEqual(TextStyle.veryCasual.apply("literal comma literal quote"), "comma quote")
        XCTAssertEqual(TextStyle.veryCasual.apply("`open quote comma new line` https://example.com/comma"), "`open quote comma new line` https://example.com/comma")
        XCTAssertEqual(TextStyle.formal.apply("Hello, world."), "Hello, world.")
    }

    func testSpellingRequiresKnownVocabularyOrExplicitCue() {
        for style in TextStyle.allCases {
            let ending = style == .formal ? "." : (style == .excited ? "!" : "")
            XCTAssertEqual(style.apply("Z A Y D", personalWords: ["Zayd"]), "Zayd" + ending)
            XCTAssertEqual(style.apply("D A H L S S O N", personalWords: ["Dahlsson"]), "Dahlsson" + ending)
            XCTAssertEqual(style.apply("spelled Z A Y D", personalWords: ["Zayd"]), "Zayd" + ending)
            XCTAssertEqual(style.apply("spell A B C end spelling"), "ABC" + ending)
            XCTAssertEqual(style.apply("ZAYD", personalWords: ["Zayd"]), "Zayd" + ending)
        }
        XCTAssertEqual(TextStyle.veryCasual.apply("I am here."), "i am here")
        // An unknown word spelled out loud is still the word, written as a name in the style's casing.
        XCTAssertEqual(TextStyle.veryCasual.apply("D A H L S S O N"), "dahlsson")
        XCTAssertEqual(TextStyle.formal.apply("D A H L S S O N"), "Dahlsson.")
        // Zayd is built in (BuiltInVocabulary), so spelling it needs no personal words.
        XCTAssertEqual(TextStyle.veryCasual.apply("Z A Y D"), "Zayd")
        XCTAssertEqual(TextStyle.veryCasual.apply("`Z A Y D`", personalWords: ["Zayd"]), "`Z A Y D`")
        XCTAssertEqual(TextStyle.casual.apply("spell a word"), "Spell a word")
        XCTAssertEqual(TextStyle.casual.apply("spelled Z A Y D I work here", personalWords: ["Zayd"]), "Zayd I work here")
    }

    func testManyCommandsAndOrdinaryTextRemainStable() {
        let input = String(repeating: "hello insert comma world new line ", count: 2_000)
        let expected = String(repeating: "hello, world\n", count: 2_000)
        XCTAssertEqual(TextStyle.veryCasual.apply(input), expected)
        let plain = String(repeating: "a", count: 100_000)
        XCTAssertEqual(TextStyle.veryCasual.apply(plain), plain)
    }
    func testUserAcceptanceExamplesAndRecognizerCommandPunctuation() {
        for style in TextStyle.allCases {
            XCTAssertEqual(style.apply("open parentheses he said comma she said close parentheses"), "(he said, she said)")
            XCTAssertEqual(style.apply("quote you wear glasses end quote"), "\"you wear glasses\"")
            XCTAssertEqual(style.apply("open parentheses, hello, close parentheses."), "(hello)")
            XCTAssertEqual(style.apply("new paragraph."), "\n\n")
        }
        XCTAssertEqual(TextStyle.casual.apply("hello comma, world."), "Hello, world")
        XCTAssertEqual(TextStyle.casual.apply("the word comma."), "The word comma")
        XCTAssertEqual(TextStyle.casual.apply("comma-separated values"), "Comma-separated values")
        XCTAssertEqual(TextStyle.casual.apply("Comma placement matters."), "Comma placement matters")
        XCTAssertEqual(TextStyle.casual.apply("comma"), ",")
        XCTAssertEqual(TextStyle.formal.apply("hello Zayd", personalWords: ["Zayd"]), "Hello Zayd.")
        XCTAssertEqual(TextStyle.excited.apply("hello Zayd", personalWords: ["Zayd"]), "Hello Zayd!")
    }

    func testVocabularyBeyondEngineHintLimitStillControlsFormatting() {
        let vocabulary = (0..<1_000).map { "Term\($0)" } + ["Dahlsson"]
        XCTAssertEqual(TextStyle.veryCasual.apply("hello term999 D A H L S S O N", personalWords: vocabulary), "hello Term999 Dahlsson")
        let literal = String(repeating: "`term999 new line` ", count: 2_000).trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(TextStyle.veryCasual.apply(literal, personalWords: vocabulary), literal)
    }

}
