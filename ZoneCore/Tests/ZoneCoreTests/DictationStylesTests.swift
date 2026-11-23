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

    func testFillersNumbersAndTimesAreTheSameInEveryStyle() {
        check("So, um, it said eleven percent at nine thirty.",
              casual: "So it said 11% at 9:30",
              veryCasual: "so it said 11% at 9:30",
              formal: "So it said 11% at 9:30.",
              excited: "So it said 11% at 9:30!")
        check("I'm gonna be there in five minutes. Two things came up.",
              casual: "I'm gonna be there in 5 minutes. Two things came up",
              veryCasual: "i'm gonna be there in 5 minutes two things came up",
              formal: "I'm gonna be there in 5 minutes. Two things came up.",
              excited: "I'm gonna be there in 5 minutes! Two things came up!")
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
}
