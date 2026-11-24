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

    // MARK: Numbers agree, and the texting styles write digits

    private func texted(_ text: String) -> String { SpokenNumbers.writingDigits(text, small: .digits) }

    /// "8 or 9 maybe seven" (Zayd's phone, 2026-11-19): a lone small number beside digits is a digit.
    func testALoneSmallNumberAgreesWithDigitsBesideIt() {
        XCTAssertEqual(SpokenNumbers.writingDigits("eight or nine, maybe seven, any time after then"),
                       "8 or 9, maybe 7, any time after then")
        XCTAssertEqual(SpokenNumbers.writingDigits("eight or nine? Maybe seven. Anytime after then."),
                       "8 or 9? Maybe 7. Anytime after then.")
        XCTAssertEqual(SpokenNumbers.writingDigits("at 8:30 or maybe nine if that works"), "at 8:30 or maybe 9 if that works")
        XCTAssertEqual(SpokenNumbers.writingDigits("around 10, or seven"), "around 10, or 7")
    }

    func testAgreementLeavesCountsTitlesAndFarNumbersAlone() {
        // A number counting something is not standing on its own.
        XCTAssertEqual(SpokenNumbers.writingDigits("at 5 pm two people came"), "at 5 pm two people came")
        XCTAssertEqual(SpokenNumbers.writingDigits("I got 12 emails and three calls"), "I got 12 emails and three calls")
        // Too far away to be the same thought.
        XCTAssertEqual(SpokenNumbers.writingDigits("I have 12 things to do before I leave and then maybe seven"),
                       "I have 12 things to do before I leave and then maybe seven")
        XCTAssertEqual(SpokenNumbers.writingDigits("at 8 we watched Seven, it was good"), "at 8 we watched Seven, it was good")
        XCTAssertEqual(SpokenNumbers.writingDigits("around seven"), "around seven")
        XCTAssertEqual(SpokenNumbers.writingDigits("2026, maybe one"), "2026, maybe one")
    }

    func testAgreementIsStableOnASecondPass() {
        for text in ["twelve nine. okay", "forty five people and then, well, maybe seven", "eight or nine, maybe seven",
                     "T three or four, five"] {
            let once = SpokenNumbers.writingDigits(text)
            XCTAssertEqual(SpokenNumbers.writingDigits(once), once, text)
            let textedOnce = texted(text)
            XCTAssertEqual(texted(textedOnce), textedOnce, text)
        }
    }

    func testTextingWritesSmallNumbersAsDigits() {
        XCTAssertEqual(texted("I'll probably get out of here around seven"), "I'll probably get out of here around 7")
        XCTAssertEqual(texted("the first three lines are great"), "the first 3 lines are great")
        XCTAssertEqual(texted("Two things I noticed"), "2 things I noticed")
        XCTAssertEqual(texted("broke two fingers. The other two buttons aren't"), "broke 2 fingers. The other 2 buttons aren't")
        XCTAssertEqual(texted("an hour or two ago"), "an hour or 2 ago")
        XCTAssertEqual(texted("noon to two or something"), "noon to 2 or something")
        XCTAssertEqual(texted("handle all of those two."), "handle all of those 2.")
        XCTAssertEqual(texted("we need nine, not ten"), "we need 9, not 10")
    }

    func testTextingKeepsOneFractionsSayingsTitlesAndSequences() {
        for kept in ["this one works", "no one came", "one of them", "give me one second", "zero chance",
                     "two thirds the size", "three quarters done", "high five", "take five", "on cloud nine",
                     "I ate at Five Guys", "Take Two Interactive made it", "one two three go", "they came two by two",
                     "catch one and two maybe", "one apple and two pears", "one shot and two supporting sentences"] {
            XCTAssertEqual(texted(kept), kept, kept)
        }
    }

    /// "No" was once a label like "number", which wrote "no 1 came" in every style.
    func testNoOneAndNoTwoStayWords() {
        XCTAssertEqual(SpokenNumbers.writingDigits("no one came and no two are alike"), "no one came and no two are alike")
        XCTAssertEqual(SpokenNumbers.writingDigits("number one and number two"), "number 1 and number 2")
    }

    /// "One I hope that's done, but two there's a button": a point being made, not a count.
    func testTextingKeepsTheNumberOfASpokenPoint() {
        XCTAssertEqual(texted("So one I hope that's out the way but two like maybe these cards"),
                       "So one I hope that's out the way but two like maybe these cards")
        XCTAssertEqual(texted("that is imported. But two I want this to work"), "that is imported. But two I want this to work")
        XCTAssertEqual(texted("open close notes but two there's a big button"), "open close notes but two there's a big button")
        // A count in the same places is still a digit, and so is a number that is the subject.
        XCTAssertEqual(texted("but two people came. Two things: go"), "but 2 people came. 2 things: go")
        XCTAssertEqual(texted("Seven is fine. Two don't work and three just broke"), "7 is fine. 2 don't work and 3 just broke")
    }

    func testTextingLeavesLiteralsAndLargerNumbersAsBefore() {
        XCTAssertEqual(texted("see example.com/two/three and v2"), "see example.com/two/three and v2")
        XCTAssertEqual(texted("forty five miles in five minutes"), "45 miles in 5 minutes")
        XCTAssertEqual(texted("twenty four seven"), "24/7")
        XCTAssertEqual(texted("at nine thirty"), "at 9:30")
    }
}
