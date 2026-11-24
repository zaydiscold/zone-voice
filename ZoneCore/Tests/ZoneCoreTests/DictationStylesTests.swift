// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// The table in `docs/dictation-styles.md`, held to the code. Change one and change the other.
final class DictationStylesTests: XCTestCase {
    private let contacts = SystemLexiconSnapshot(
        entries: ["Sarah", "Brown", "The", "Nita"].map { (input: $0.lowercased(), text: $0) }).speechWords

    private func check(_ said: String, casual: String, veryCasual: String, formal: String, excited: String,
                       file: StaticString = #filePath, line: UInt = #line) {
        for (style, written) in [(TextStyle.casual, casual), (.veryCasual, veryCasual), (.formal, formal), (.excited, excited)] {
            XCTAssertEqual(style.apply(said, systemWords: contacts), written, style.rawValue, file: file, line: line)
        }
    }

    func testPunctuationAndSentenceCapitals() {
        check("Hello there. this is great, right",
              casual: "Hello there. this is great right",
              veryCasual: "hello there this is great right",
              formal: "Hello there. This is great, right.",
              excited: "Hello there! This is great, right!")
        check("Is it ready? i think so.",
              casual: "Is it ready? I think so",
              veryCasual: "is it ready? i think so",
              formal: "Is it ready? I think so.",
              excited: "Is it ready? I think so!")
    }

    func testFillersAndTimesAreTheSameInEveryStyleAndSmallNumbersFollowIt() {
        check("So, um, it said eleven percent at nine thirty.",
              casual: "So it said 11% at 9:30",
              veryCasual: "so it said 11% at 9:30",
              formal: "So it said 11% at 9:30.",
              excited: "So it said 11% at 9:30!")
        check("I'm gonna be there in five minutes. Two things came up.",
              casual: "I'm gonna be there in 5 minutes. 2 things came up",
              veryCasual: "i'm gonna be there in 5 minutes 2 things came up",
              formal: "I'm going to be there in 5 minutes. Two things came up.",
              excited: "I'm gonna be there in 5 minutes! Two things came up!")
    }

    /// Zayd's four dictations of one message (2026-11-19): every style wrote "8 or 9 maybe seven".
    func testTheSameMessageInEveryStyle() {
        check("Hello, sorry, does later tonight work? Like I don't know, eight or nine, maybe seven, any time after then.",
              casual: "Hello sorry does later tonight work? Like I don't know 8 or 9 maybe 7 any time after then",
              veryCasual: "hello sorry does later tonight work? like i don't know 8 or 9 maybe 7 any time after then",
              formal: "Hello, sorry, does later tonight work? Like I don't know, 8 or 9, maybe 7, any time after then.",
              excited: "Hello, sorry, does later tonight work? Like I don't know, 8 or 9, maybe 7, any time after then!")
        check("I'll probably get out of here around seven",
              casual: "I'll probably get out of here around 7",
              veryCasual: "i'll probably get out of here around 7",
              formal: "I'll probably get out of here around seven.",
              excited: "I'll probably get out of here around seven!")
        check("cuz I kinda wanna see the first three and we gotta go",
              casual: "Cuz I kinda wanna see the first 3 and we gotta go",
              veryCasual: "cuz i kinda wanna see the first 3 and we gotta go",
              formal: "Because I kind of want to see the first three and we have to go.",
              excited: "Cuz I kinda wanna see the first three and we gotta go!")
    }

    func testCasualLowercasesCommonNamesAtSentenceOpeningsWithCapitalsOff() {
        for name in ["Apple", "Oracle", "Warp", "Notes", "Home"] {
            let written = TextStyle.casual.insertion(of: "Look again. \(name) appears here.",
                contextBefore: "", fieldCapitalizesSentences: false, opening: .lowercase, autoCapitalization: false)
            XCTAssertEqual(written, "look again. \(name.lowercased()) appears here")
        }
    }

    func testCompanyAndProductNames() {
        check("I asked open AI and clawed code about the API on my iphone",
              casual: "I asked openai and claude code about the API on my iPhone",
              veryCasual: "i asked openai and claude code about the api on my iphone",
              formal: "I asked OpenAI and Claude Code about the API on my iPhone.",
              excited: "I asked OpenAI and Claude Code about the API on my iPhone!")
    }

    func testPeopleAndSpelledWords() {
        check("i met sarah brown at the brown house with nita",
              casual: "I met Sarah Brown at the brown house with Nita",
              veryCasual: "i met Sarah Brown at the brown house with Nita",
              formal: "I met Sarah Brown at the brown house with Nita.",
              excited: "I met Sarah Brown at the brown house with Nita!")
        check("My name is D-A-A-N",
              casual: "My name is Daan",
              veryCasual: "my name is daan",
              formal: "My name is Daan.",
              excited: "My name is Daan!")
    }

    func testFormalSentenceCapitalsSkipAbbreviationsAndLiterals() {
        for said in ["Ask Dr. brown about it.", "It is 5 vs. three.", "See example.com. then call.", "Wait... what."] {
            let written = TextStyle.formal.apply(said)
            XCTAssertFalse(written.contains(". T") || written.contains(". B") || written.contains("... W"), written)
        }
        XCTAssertEqual(TextStyle.capitalizingSentences("one. two! three? four"), "one. Two! Three? Four")
        XCTAssertEqual(TextStyle.capitalizingSentences("the U.S. economy. it grew"), "the U.S. economy. It grew")
    }

    func testShorthandQuotesAndFaces() {
        check("TS is crazy FR, she was like quote no way quote smiley face",
              casual: "ts is crazy fr she was like \"no way\" :)",
              veryCasual: "ts is crazy fr she was like \"no way\" :)",
              formal: "TS is crazy FR, she was like \"no way\" smiley face.",
              excited: "TS is crazy FR, she was like \"no way\" smiley face!")
        check("I use AI a lot, DM me ASAP",
              casual: "I use ai a lot, dm me asap",
              veryCasual: "i use ai a lot dm me asap",
              formal: "I use AI a lot, DM me ASAP.",
              excited: "I use AI a lot, DM me ASAP!")
    }

    func testTextingKeepsThePauseAfterAListMarker() {
        for cue in ["but", "and", "so", "then", "also", "first", "second"] {
            let raw = "Ready. " + cue + " two, I need tape"
            XCTAssertTrue(TextStyle.casual.apply(raw).contains("two, I need tape"))
            XCTAssertTrue(TextStyle.veryCasual.apply(raw).contains("2, i need tape"))
        }
        XCTAssertEqual(TextStyle.casual.apply("One, check the paint. Two, check the roof"),
                       "One, check the paint. Two, check the roof")
        XCTAssertEqual(TextStyle.veryCasual.apply("One, check the paint. Two, check the roof"),
                       "one, check the paint 2, check the roof")
        XCTAssertEqual(TextStyle.casual.apply("Buy one, then buy two, please"), "Buy one, then buy 2, please")
        XCTAssertFalse(TextStyle.veryCasual.apply("I picked one and two, maybe").contains(","))
        XCTAssertFalse(TextStyle.veryCasual.apply("Move the first one, please").contains(","))
        XCTAssertTrue(TextStyle.casual.apply("But two\nI need tape").contains("two,"))
        XCTAssertTrue(TextStyle.veryCasual.apply("But two\nI need tape").contains("2,"))
        XCTAssertEqual(TextStyle.casual.apply("But two people came"), "But 2 people came")
    }

    /// Zayd's casual dictations (November 23, reworded): the recognizer's capitals on ordinary
    /// words came through half lowercase ("my calendar says ai Summit, great Naming Convention").
    func testCasualDoesNotLeaveTheRecognizersTitleCapitalsHalfLowercase() {
        // Shorthand inside a name keeps its capitals; alone it is still texting shorthand.
        XCTAssertEqual(TextStyle.casual.apply("My invite says AI Summit."), "My invite says AI Summit")
        XCTAssertEqual(TextStyle.casual.apply("We bought Google AI Ultra."), "We bought google AI Ultra")
        XCTAssertEqual(TextStyle.casual.apply("Thank God for AI."), "Thank God for ai")
        XCTAssertEqual(TextStyle.casual.apply("Text Sarah ASAP."), "Text Sarah asap", "a first name is not a title")
        // A run with a verb's -ing form is no name.
        XCTAssertEqual(TextStyle.casual.apply("Great Naming Convention."), "Great naming convention")
        XCTAssertEqual(TextStyle.casual.apply("Then fix the Search Field Typing."), "Then fix the search field typing")
        // A filler word capitalized after a comma is the recognizer starting over.
        XCTAssertEqual(TextStyle.casual.apply("We should talk, Yeah I think so."), "We should talk, yeah I think so")
        // Names keep their capitals: no -ing form, a place, a given name, the person's own words.
        for kept in ["I shop at Whole Foods", "Meet me at the App Store", "It is on Evening Spring Court",
                     "Go to the Visitor Center", "We land at Thanksgiving", "I told Mark about it", "We met at Rocket Money"] {
            XCTAssertEqual(TextStyle.casual.apply(kept + "."), kept)
        }
        XCTAssertEqual(TextStyle.casual.apply("See you at Morning Glory.", personalWords: ["Morning Glory"]), "See you at Morning Glory")
        XCTAssertEqual(TextStyle.casual.apply("He is Running Point.", personalWords: ["Running Point"]), "He is Running Point")
        // Only casual: formal writes what the recognizer wrote.
        XCTAssertEqual(TextStyle.formal.apply("Great Naming Convention."), "Great Naming Convention.")
    }

    func testVerbIngForms() {
        for word in ["naming", "typing", "running", "pushing", "turning"] { XCTAssertTrue(TextStyle.isVerbIngForm(word), word) }
        for word in ["thanksgiving", "evening", "morning", "king", "sterling", "spring", "string"] { XCTAssertFalse(TextStyle.isVerbIngForm(word), word) }
    }
}
