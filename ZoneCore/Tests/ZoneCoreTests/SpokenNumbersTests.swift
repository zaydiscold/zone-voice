// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// Cases follow the constructions the recognizer writes in dictation, each with a neighbor that must not change.
final class SpokenNumbersTests: XCTestCase {
    private func check(_ said: String, _ written: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(SpokenNumbers.writingDigits(said), written, file: file, line: line)
    }

    func testNumbersOfTwoWordsOrFromTenUpAreDigits() {
        check("Mountain Pass, forty five miles, north.", "Mountain Pass, 45 miles, north.")
        check("and some bread from route ninety-nine", "and some bread from route 99")
        check("Ninety day study plan.", "90 day study plan.")
        check("Thirty day prep.", "30 day prep.")
        check("maybe if like fifteen minutes is max", "maybe if like 15 minutes is max")
        check("I have to push two thousand at a time", "I have to push 2,000 at a time")
        check("about one hundred and twenty people", "about 120 people")
        check("it was fifteen hundred", "it was 1500")
        check("two million users and one point five billion views", "2 million users and 1.5 billion views")
        check("back in twenty twenty six", "back in 2026")
        check("since nineteen ninety nine", "since 1999")
        check("open twenty four seven", "open 24/7")
        check("I am one hundred percent sure", "I am 100% sure")
    }

    func testSmallNumbersTakeDigitsBeforeUnitsInRangesAndAfterLabels() {
        check("might not respond for like five minutes.", "might not respond for like 5 minutes.")
        check("a long time, maybe like three minutes.", "a long time, maybe like 3 minutes.")
        check("in the last three weeks of this", "in the last 3 weeks of this")
        check("it was just a seven second clip", "it was just a 7 second clip")
        check("it does eight times as much research", "it does 8 times as much research")
        check("a three-hour drive", "a 3-hour drive")
        check("I've been meeting two to three times a week", "I've been meeting 2 to 3 times a week")
        check("Five to ten minutes, why?", "5 to 10 minutes, why?")
        check("give me like one to two sentences on it", "give me like 1 to 2 sentences on it")
        check("made them like one or two pixels wider", "made them like 1 or 2 pixels wider")
        check("it's like a five to six just constantly,", "it's like a 5 to 6 just constantly,")
        check("the last like five to ten to fifteen", "the last like 5 to 10 to 15")
        check("I keep using T three", "I keep using T3")
        check("It still runs on IE seven", "It still runs on IE 7")
        check("gonna do that? For number two", "gonna do that? For number 2")
        check("person one I'll be person two and export them", "person 1 I'll be person 2 and export them")
        check("GLM five point three hydrogen.", "GLM 5.3 hydrogen.")
        check("Hydrogen one point o API", "Hydrogen 1.0 API")
        check("Oh, and one is point four", "Oh, and one is 0.4")
        check("zero percent chance and five percent off", "0% chance and 5% off")
        check("the options should be like five, six hours, I don't know", "the options should be like 5, 6 hours, I don't know")
        check("is it on iPhone seven or Opus four", "is it on iPhone 7 or Opus 4")
    }

    func testClockTimes() {
        check("Nine thirty", "9:30")
        check("let's meet at nine thirty tomorrow", "let's meet at 9:30 tomorrow")
        check("around twelve fifteen pm", "around 12:15 pm")
        check("be there by nine oh five", "be there by 9:05")
        check("Maybe 12 30.", "Maybe 12:30.")
        check("Let's say 8 or 8 30 if that's", "Let's say 8 or 8:30 if that's")
        check("it cost one fifty", "it cost one fifty")
        check("we get ten fifteen minute breaks", "we get 10 15 minute breaks")
    }

    func testCountsIdiomsAndTitlesStayAsSaid() {
        for said in ["Two things. One, I'm either", "the other two buttons aren't", "wow, we only have three open positions.",
                     "I love the first three lines a lot", "for like an hour or two", "this one is better than that one",
                     "But one second", "One second Computer rebooting.", "I don't have a million things occupying my hands",
                     "All local zero data, comma.", "like two empty lines, short line", "one two three testing",
                     "go one by one", "we went to Five Guys after", "to like two thirds the size",
                     "Claude one-shot this video", "the other day one of my friends called", "catch one and two",
                     "I have four different builds", "Claude one shot this", "unlimited free local AI zero data collection",
                     "Have we been the one?", "that's the point two people made", "see example.com/two/three"] {
            check(said, said)
        }
    }

    func testAlreadyWrittenDigitsAndLiteralsAreUntouched() {
        for said in ["I only get like 15 to 30 minutes.", "Why is it 1.01?", "like 45 mile drives.", "it's $3 in, $5 out.",
                     "between 5 30 people", "version 1.0.2 is out", "call 555 12 34 now"] {
            check(said, said)
        }
    }

    func testStylesWriteTheDigits() {
        XCTAssertEqual(TextStyle.casual.apply("I'll be there in five minutes."), "I'll be there in 5 minutes")
        XCTAssertEqual(TextStyle.formal.apply("we have forty five people"), "We have 45 people.")
        XCTAssertEqual(TextStyle.casual.apply("Nine thirty"), "9:30")
    }
}
