// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// The four styles as Wispr Flow defines them, with its own sample sentence.
final class TextStyleTests: XCTestCase {
    private let sample = "hey, are you free for lunch tomorrow? Let's do 12 if that works for you."

    func testVeryCasualStaysLowercaseInAnAutocapitalizingField() {
        // Empty field, sentence capitalization on: the style's lowercase wins.
        XCTAssertEqual(TextStyle.veryCasual.insertion(of: "Hello there.", contextBefore: nil, fieldCapitalizesSentences: true), "hello there")
        XCTAssertEqual(TextStyle.veryCasual.insertion(of: "Hello there.", contextBefore: "Done. ", fieldCapitalizesSentences: true), "hello there")
        // The other styles still get the field's capital at a sentence start.
        XCTAssertEqual(TextStyle.casual.insertion(of: "hello there", contextBefore: nil, fieldCapitalizesSentences: true).first, "H")
    }

    /// A search bar or address bar takes a query: no style's closing period or exclamation mark.
    func testSearchFieldsLeaveOffTheClosingMark() {
        func search(_ style: TextStyle, _ said: String, before: String? = "") -> String {
            style.insertion(of: said, contextBefore: before, fieldCapitalizesSentences: true, searchField: true)
        }
        XCTAssertEqual(search(.formal, "amazon"), "Amazon")
        XCTAssertEqual(search(.excited, "pizza near me"), "Pizza near me")
        XCTAssertEqual(search(.formal, "what time is it"), "What time is it")
        XCTAssertEqual(search(.formal, "wait..."), TextStyle.formal.insertion(of: "wait...", contextBefore: "", fieldCapitalizesSentences: true))
        XCTAssertEqual(search(.formal, "is it open?"), "Is it open?")
        XCTAssertEqual(search(.formal, "first one. Second one."), "First one. Second one")
        XCTAssertEqual(search(.casual, "example.com"), "example.com")
        XCTAssertEqual(search(.formal, "hello", before: "say"), " hello")
        // Outside a search field nothing changes.
        XCTAssertEqual(TextStyle.formal.insertion(of: "amazon", contextBefore: "", fieldCapitalizesSentences: true), "Amazon.")
    }
    func testFormalIsCapsAndPunctuation() {
        XCTAssertEqual(TextStyle.formal.apply(sample), "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you.")
        XCTAssertEqual(TextStyle.formal.apply("see you at nine"), "See you at nine.")
        XCTAssertEqual(TextStyle.formal.apply("Really?"), "Really?")
    }

    func testCasualIsCapsAndLessPunctuation() {
        XCTAssertEqual(TextStyle.casual.apply(sample), "Hey are you free for lunch tomorrow? Let's do 12 if that works for you")
        XCTAssertEqual(TextStyle.casual.apply("Okay."), "Okay")
    }

    func testCasualUsesTextingAcronymsWithoutChangingOtherAcronymsOrNames() {
        XCTAssertEqual(TextStyle.casual.apply("SMH, I used the NASA API. TBH it worked LOL."),
                       "smh I used the NASA API. tbh it worked lol")
        XCTAssertEqual(TextStyle.casual.apply("TBH I asked Zayd.", personalWords: ["TBH", "Zayd"]),
                       "TBH I asked Zayd")
        XCTAssertEqual(TextStyle.casual.apply("Read `SMH, TBH` at https://example.com/TBH."),
                       "Read `SMH, TBH` at https://example.com/TBH")
        XCTAssertEqual(TextStyle.formal.apply("SMH, I used the NASA API."), "SMH, I used the NASA API.")
        XCTAssertEqual(TextStyle.casual.apply("WTF OMFG LMK NVM ISTG TLDR FYI. RN AF FR API NASA."),
                       "wtf omfg lmk nvm istg tldr fyi. RN af fr API NASA")
        XCTAssertEqual(TextStyle.casual.apply("FR that AI is the GOAT.", personalWords: ["GOAT"]), "fr that ai is the GOAT")
    }

    func testCasualReducesOnlyOptionalOpeningCommas() {
        XCTAssertEqual(TextStyle.casual.apply("Okay, I can do that."), "Okay I can do that")
        XCTAssertEqual(TextStyle.casual.apply("Yeah, we can go."), "Yeah we can go")
        XCTAssertEqual(TextStyle.casual.apply("Bring apples, pears, and bread"), "Bring apples, pears, and bread")
        XCTAssertEqual(TextStyle.casual.apply("If it rains, we stay"), "If it rains we stay")
        XCTAssertEqual(TextStyle.casual.apply("Okay, fine, great"), "Okay fine great")
        XCTAssertEqual(TextStyle.casual.apply("So, I think, honestly, it's fine."), "So I think honestly it's fine")
        XCTAssertEqual(TextStyle.casual.apply("We raised 1,000 dollars, nice."), "We raised 1,000 dollars nice")
        XCTAssertEqual(TextStyle.casual.apply("It was November 1, 2026."), "It was November 1, 2026")
        XCTAssertEqual(TextStyle.casual.apply("We flew to Paris, France."), "We flew to Paris, France")
        XCTAssertEqual(TextStyle.casual.apply("Get eggs, milk and bread."), "Get eggs, milk and bread")
        XCTAssertEqual(TextStyle.casual.apply("Pick red, green, blue."), "Pick red, green, blue")
        XCTAssertEqual(TextStyle.casual.apply("Yeah, I can do that."), "Yeah I can do that")
        XCTAssertEqual(TextStyle.formal.apply("If it rains, we stay"), "If it rains, we stay.")
        XCTAssertEqual(TextStyle.casual.apply("okay comma I can do that"), "Okay, I can do that")
        XCTAssertEqual(TextStyle.casual.apply("TBH comma I agree"), "tbh, I agree")
    }

    func testVeryCasualIsNoCapsNoPunctuation() {
        XCTAssertEqual(TextStyle.veryCasual.apply(sample), "hey are you free for lunch tomorrow? let's do 12 if that works for you")
    }

    func testExcitedEndsWithABang() {
        XCTAssertEqual(TextStyle.excited.apply(sample), "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you!")
        XCTAssertEqual(TextStyle.excited.apply("we did it"), "We did it!")
    }

    func testVeryCasualKeepsNumbersAndAddresses() {
        XCTAssertEqual(TextStyle.veryCasual.apply("The raise is 12.5%, at 3.30 p.m., mail a.b@x.com."), "the raise is 12.5% at 3:30 pm mail a.b@x.com")
    }

    func testEmptyStaysEmptyAndCycleWraps() {
        XCTAssertEqual(TextStyle.formal.apply("   "), "")
        XCTAssertEqual(TextStyle.excited.next, .casual)
        XCTAssertEqual(TextStyle.casual.next, .veryCasual)
    }

    func testContinuationUsesCursorContextWithoutChangingRecognizedWords() {
        XCTAssertEqual(TextStyle.casual.insertion(of: "and then we left.", contextBefore: "We ate", fieldCapitalizesSentences: false), " and then we left")
        XCTAssertEqual(TextStyle.casual.insertion(of: "and then we left.", contextBefore: "We ate ", fieldCapitalizesSentences: true), "and then we left")
        XCTAssertEqual(TextStyle.casual.insertion(of: "then we left.", contextBefore: "We ate. ", fieldCapitalizesSentences: true), "Then we left")
        XCTAssertEqual(TextStyle.casual.insertion(of: "Grok helped.", contextBefore: "and ", fieldCapitalizesSentences: true), "Grok helped")
    }

    func testLiteralSpellingSurvivesEveryStyleAndCursorCapitalization() {
        let literals = ["https://example.com/API?Key=AbC", "a.B@Example.com", "iOS", "apiKey", "my_variable", "`let apiKey = \"AbC\"`", "let apiKey = \"AbC\"", "```swift\nlet apiKey = \"AbC\"\n```", "/Users/Zayd/Project", "12.5"]
        for literal in literals {
            for style in TextStyle.allCases {
                XCTAssertEqual(style.apply(literal), literal, "\(style) corrupted \(literal)")
                XCTAssertEqual(style.insertion(of: literal, contextBefore: nil, fieldCapitalizesSentences: true), literal)
            }
        }
        XCTAssertEqual(TextStyle.veryCasual.apply("Use iOS and https://example.com/API, email a.B@Example.com."), "use iOS and https://example.com/API email a.B@Example.com")
        // "U.S." is written "US" (Zayd, November 15); very casual lowercases it like any acronym.
        XCTAssertEqual(TextStyle.veryCasual.apply("Meet the U.S. Army."), "meet the us army")
    }

    func testEllipsesAndQuotedSentenceEndingsStayWellFormed() {
        for style in TextStyle.allCases {
            XCTAssertEqual(style.apply("Wait..."), style == .veryCasual ? "wait..." : "Wait...")
            XCTAssertEqual(style.apply("Wait…"), style == .veryCasual ? "wait…" : "Wait…")
        }
        XCTAssertEqual(TextStyle.formal.apply("He said \"go.\""), "He said \"go.\"")
        XCTAssertEqual(TextStyle.excited.apply("He said \"go.\""), "He said \"go!\"")
        XCTAssertEqual(TextStyle.casual.apply("He said \"go.\""), "He said \"go\"")
        XCTAssertEqual(TextStyle.excited.apply("Really?!"), "Really?!")
    }

    func testMeaningfulSpacingAndMarkerLikeInputArePreserved() {
        XCTAssertEqual(TextStyle.veryCasual.apply("HELLO  THERE\n\n`AbC`"), "hello  there\n\n`AbC`")
        XCTAssertEqual(TextStyle.veryCasual.apply("\u{E000}0\u{E001} iOS."), "\u{E000}0\u{E001} iOS")
    }

    func testExistingStyleNamesRemainStable() {
        XCTAssertEqual(TextStyle.allCases.map(\.rawValue), ["casual", "veryCasual", "formal", "excited"])
        XCTAssertEqual(TextStyle.allCases.map(\.label), ["Casual", "Very casual", "Formal.", "Excited!"])
    }

    func testLongTranscriptRestoresThousandsOfLiteralsWithoutChangingThem() {
        let words = (0..<2_000).map { "https://example.com/API/\($0)?Key=AbC" }
        let text = words.joined(separator: " AND ")
        XCTAssertEqual(TextStyle.veryCasual.apply(text), words.joined(separator: " and "))
        let markerLike = String(repeating: "\u{E000}", count: 20_000)
        XCTAssertEqual(TextStyle.veryCasual.apply(markerLike + " iOS."), markerLike + " iOS")
    }

    func testUnpunctuatedQuotationKeepsItsContentsLiteral() {
        XCTAssertEqual(TextStyle.formal.apply("He said \"go\""), "He said \"go\".")
        XCTAssertEqual(TextStyle.excited.apply("He said \"go\""), "He said \"go\"!")
        XCTAssertEqual(TextStyle.formal.apply("Try it (now)"), "Try it (now).")
    }

    func testAllStylesRemoveOnlyExplicitHesitations() {
        XCTAssertEqual(TextStyle.casual.apply("Um, I think, uh, we can go."), "I think we can go")
        XCTAssertEqual(TextStyle.veryCasual.apply("AH, well, I like it, so um let's go."), "well i like it so let's go")
        XCTAssertEqual(TextStyle.casual.apply("It works. Um. Next step."), "It works. Next step")
        for style in TextStyle.allCases {
            XCTAssertEqual(style.apply("um, uh, ah."), "")
            XCTAssertEqual(style.apply("Um!"), "")
            XCTAssertEqual(style.apply("`um` https://example.com/ah"), "`um` https://example.com/ah")
        }
        XCTAssertEqual(TextStyle.casual.apply("Ahum has an umbrella and umlaut. Aha!"), "Ahum has an umbrella and umlaut. Aha!")
        XCTAssertEqual(TextStyle.veryCasual.apply("um-based Ah's work"), "um-based ah's work")
        XCTAssertEqual(TextStyle.formal.apply("Um, yes."), "Yes.")
        XCTAssertEqual(TextStyle.excited.apply("Uh, yes."), "Yes!")
        XCTAssertEqual(TextStyle.casual.apply("First\nUm, second."), "First\nsecond")
        XCTAssertEqual(TextStyle.casual.apply("Go um 😀"), "Go 😀")
        XCTAssertEqual(TextStyle.casual.apply(String(repeating: "um, ", count: 2_000) + "hello."), "Hello")
    }

    func testHesitationsDoNotChangeExplicitCommandBoundaries() {
        for style in TextStyle.allCases {
            let ending = style == .formal ? "." : style == .excited ? "!" : ""
            XCTAssertEqual(style.insertion(of: "um bullet point milk", contextBefore: "existing", fieldCapitalizesSentences: true), "\n• milk" + ending)
            XCTAssertEqual(style.insertion(of: "um bullet point milk", contextBefore: "", fieldCapitalizesSentences: true), "• milk" + ending)
            XCTAssertEqual(style.insertion(of: "um bullet point milk", contextBefore: "existing\n", fieldCapitalizesSentences: true), "• milk" + ending)
            XCTAssertEqual(style.insertion(of: "um new paragraph", contextBefore: "existing", fieldCapitalizesSentences: true), "\n\n")
            XCTAssertEqual(style.insertion(of: "um insert comma", contextBefore: "existing", fieldCapitalizesSentences: true), ",")
            XCTAssertEqual(style.apply("quote hello close quote um"), "\"hello\"")
        }
        XCTAssertEqual(TextStyle.formal.apply("um", personalWords: ["Um"]), "Um.")
    }

    func testLongOrdinaryTokensAndWhitespacePreserveTheirContent() {
        let word = String(repeating: "a", count: 100_000)
        XCTAssertEqual(TextStyle.casual.apply(word), "A" + word.dropFirst())
        let spaces = String(repeating: " ", count: 100_000)
        XCTAssertEqual(TextStyle.casual.apply("before" + spaces + "after"), "Before" + spaces + "after")
        XCTAssertEqual(TextStyle.casual.apply("before" + spaces + "um" + spaces + "after"), "Before after")
    }


    func testContinuingMidSentenceDoesNotCapitalizeThePlainFirstWord() {
        XCTAssertEqual(TextStyle.formal.insertion(of: "And then we left.", contextBefore: "It was late", fieldCapitalizesSentences: true),
                       " and then we left.")
        XCTAssertEqual(TextStyle.formal.insertion(of: "I think so.", contextBefore: "Well", fieldCapitalizesSentences: true),
                       " I think so.")
        XCTAssertEqual(TextStyle.formal.insertion(of: "Zayd said yes.", contextBefore: "and then", fieldCapitalizesSentences: true, personalWords: ["Zayd"]),
                       " Zayd said yes.")
        XCTAssertEqual(TextStyle.formal.insertion(of: "And then we left.", contextBefore: "Done. ", fieldCapitalizesSentences: true),
                       "And then we left.")
    }

    func testSemicolonVariantsBecomeTheMark() {
        XCTAssertEqual(TextStyle.formal.apply("one semicolon two"), "One; two.")
        XCTAssertEqual(TextStyle.formal.apply("I hit semi-colon okay"), "I hit; okay.")
        XCTAssertEqual(TextStyle.formal.apply("it works semicola then it fails"), "It works; then it fails.")
        XCTAssertEqual(TextStyle.casual.apply("Semicolon okay"), "; okay")
        XCTAssertEqual(TextStyle.formal.apply("Comma placement matters"), "Comma placement matters.")
    }

    func testSlangAndEtcCasing() {
        XCTAssertEqual(TextStyle.casual.apply("Bring snacks, drinks, ETC."), "Bring snacks, drinks, etc")
        XCTAssertEqual(TextStyle.formal.apply("Bring snacks, drinks, Etc."), "Bring snacks, drinks, etc.")
        XCTAssertEqual(TextStyle.casual.apply("WTF that was LMAO. LOL."), "wtf that was lmao. lol")
    }

    func testModelIDKBecomesTheSpokenWords() {
        XCTAssertEqual(TextStyle.casual.apply("IDK. IDK. What is up with that?"), "I don't know. I don't know. What is up with that?")
        XCTAssertEqual(TextStyle.formal.apply("Honestly IDK."), "Honestly I don't know.")
        XCTAssertEqual(TextStyle.casual.apply("idk man"), "idk man")
    }
}
