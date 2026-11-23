// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// Times as the 2026-11-19 Teams message showed them: "7 AM" in a casual text, "later than
/// twelve forty-five" left in words, and "work?." from the recognizer.
final class TextingTimesTests: XCTestCase {
    private func casual(_ text: String, after context: String? = nil) -> String {
        TextStyle.casual.insertion(of: text, contextBefore: context, fieldCapitalizesSentences: true)
    }

    private func formal(_ text: String) -> String {
        TextStyle.formal.insertion(of: text, contextBefore: nil, fieldCapitalizesSentences: true)
    }

    func testCasualWritesAmAndPmInLowercase() {
        XCTAssertEqual(casual("I had a few meetings since 7 AM, but I'm free"), "I had a few meetings since 7 am but I'm free")
        XCTAssertEqual(casual("see you at 12:45 PM"), "See you at 12:45 pm")
        XCTAssertEqual(casual("at 7 a.m. and 8 P.M."), "At 7 am and 8 pm")
        XCTAssertEqual(casual("let's do 7AM tomorrow"), "Let's do 7am tomorrow")
    }

    func testCasualKeepsTheSentencePeriodAfterADottedTime() {
        XCTAssertEqual(casual("I land at 7 a.m. Then we drive"), "I land at 7 am. Then we drive")
        XCTAssertEqual(casual("I land at 7 a.m."), "I land at 7 am")
    }

    func testAmAndPmWithoutANumberKeepTheirCapitals() {
        XCTAssertEqual(casual("the PM said hi at 3 PM"), "The PM said hi at 3 pm")
        XCTAssertEqual(casual("I AM serious"), "I AM serious")
    }

    func testVeryCasualDropsTheDotsToo() {
        XCTAssertEqual(TextStyle.veryCasual.insertion(of: "Meet at 7 a.m. and 8 PM.", contextBefore: nil, fieldCapitalizesSentences: true),
                       "meet at 7 am and 8 pm")
    }

    func testFormalKeepsTheRecognizersMeridiem() {
        XCTAssertEqual(formal("I had meetings since 7 AM"), "I had meetings since 7 AM.")
    }

    func testLaterThanASpokenTimeIsATime() {
        XCTAssertEqual(casual("I'll be a little bit later than twelve forty-five."), "I'll be a little bit later than 12:45")
        XCTAssertEqual(casual("no earlier than nine thirty please"), "No earlier than 9:30 please")
    }

    func testThanAloneIsNotATime() {
        XCTAssertEqual(casual("it cost more than one fifty"), "It cost more than one fifty")
    }

    func testAQuestionMarkAndAPeriodBecomeTheQuestionMark() {
        XCTAssertEqual(formal("Does after about one fifteen work?. I'm so sorry for the delay"),
                       "Does after about 1:15 work? I'm so sorry for the delay.")
        XCTAssertEqual(casual("no way!. ok"), "No way! ok")
        XCTAssertEqual(formal("Wait, what?... Really"), "Wait, what?... Really.")
    }

    /// The whole 12:17 dictation into Teams, after typed text that ends mid-sentence.
    func testTheTeamsMessage() {
        let raw = "Or any time after, whenever is convenient. I was working from home because I had a few meetings since 7 AM, but it will be easier to work on this with you in person, so I'm coming to the office but will be a little bit later than twelve forty-five."
        XCTAssertEqual(casual(raw, after: "Hi riju any chance we can move the meeting to around 1:30 "),
                       "or any time after whenever is convenient. I was working from home because I had a few meetings since 7 am but it will be easier to work on this with you in person so I'm coming to the office but will be a little bit later than 12:45")
    }
}
