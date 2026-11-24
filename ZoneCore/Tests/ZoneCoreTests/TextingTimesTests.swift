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
    func testApolloMessage() {
        let input = "Hey Apollo, um anytime after 215, let me know whatever would be easiest for you. Perhaps a call at like five or so. Or if you're down for like a late night at one like 10-ish, maybe ten thirty, but Does three thirty work?"
        let expected = "Hey Apollo anytime after 2:15 let me know whatever would be easiest for you. Perhaps a call at like 5 or so. Or if you're down for like a late night at one like 10-ish maybe 10:30 but does 3:30 work?"
        XCTAssertEqual(casual(input), expected)
    }

    func testDecoderVariantsFromTheSameSyntheticAudio() {
        for (input, expected) in [
            ("Does 330 work?", "Does 3:30 work?"),
            ("Does 3.30 work?", "Does 3:30 work?"),
            ("Anytime after 2.15, let me know.", "Anytime after 2:15 let me know"),
            ("Meet by 805.", "Meet by 8:05"),
            ("Try half past nine.", "Try 9:30"),
            ("Available from 2.15 to 3.30.", "Available from 2:15 to 3:30"),
            ("Fly 215 tonight.", "Fly 215 tonight"),
            ("Flight 215 tonight.", "Flight 215 tonight"),
            ("130 second.", "130 second"),
        ] {
            XCTAssertEqual(casual(input), expected, input)
        }
    }

    func testClockCandidatesInsideLiteralsKeepTheirSpelling() {
        let input = "Compare `at 215` with `at 3.30` and meet after 330"
        XCTAssertEqual(casual(input), "Compare `at 215` with `at 3.30` and meet after 3:30")
    }

    func testContextualClockTimesInEveryStyle() {
        let rows: [(String, String, String, String, String)] = [
            ("after 215", "After 2:15", "after 2:15", "After 2:15.", "After 2:15!"),
            ("does 330 work?", "Does 3:30 work?", "does 3:30 work?", "Does 3:30 work?", "Does 3:30 work?"),
            ("say 10 30 tonight", "Say 10:30 tonight", "say 10:30 tonight", "Say 10:30 tonight.", "Say 10:30 tonight!"),
            ("meet before twelve forty five", "Meet before 12:45", "meet before 12:45", "Meet before 12:45.", "Meet before 12:45!"),
            ("meet by eight oh five", "Meet by 8:05", "meet by 8:05", "Meet by 8:05.", "Meet by 8:05!"),
            ("try half past nine", "Try 9:30", "try 9:30", "Try 9:30.", "Try 9:30!"),
            ("try a quarter to eight PM", "Try 7:45 pm", "try 7:45 pm", "Try 7:45 PM.", "Try 7:45 PM!"),
            ("quarter to twelve PM", "11:45 am", "11:45 am", "11:45 AM.", "11:45 AM!"),
            ("meet at 215 on Friday", "Meet at 2:15 on Friday", "meet at 2:15 on friday", "Meet at 2:15 on Friday.", "Meet at 2:15 on Friday!"),
            ("from 215 to 330 PM", "From 2:15 to 3:30 pm", "from 2:15 to 3:30 pm", "From 2:15 to 3:30 PM.", "From 2:15 to 3:30 PM!"),
            ("try noon or midnight", "Try noon or midnight", "try noon or midnight", "Try noon or midnight.", "Try noon or midnight!"),
            ("meet by one o'clock", "Meet by 1 o'clock", "meet by 1 o'clock", "Meet by 1 o'clock.", "Meet by 1 o'clock!"),
            ("maybe 215-ish or three thirty-ish", "Maybe 2:15-ish or 3:30-ish", "maybe 2:15-ish or 3:30-ish", "Maybe 2:15-ish or 3:30-ish.", "Maybe 2:15-ish or 3:30-ish!"),
            ("meet around five-ish or at 6:30", "Meet around 5-ish or at 6:30", "meet around 5-ish or at 6:30", "Meet around 5-ish or at 6:30.", "Meet around 5-ish or at 6:30!"),
            ("available from 215 to 330", "Available from 2:15 to 3:30", "available from 2:15 to 3:30", "Available from 2:15 to 3:30.", "Available from 2:15 to 3:30!"),
            ("215 people came", "215 people came", "215 people came", "215 people came.", "215 people came!"),
            ("it breaks after 215 pounds", "It breaks after 215 pounds", "it breaks after 215 pounds", "It breaks after 215 pounds.", "It breaks after 215 pounds!"),
            ("use room 330", "Use room 330", "use room 330", "Use room 330.", "Use room 330!"),
            ("a 330 page book", "A 330 page book", "a 330 page book", "A 330 page book.", "A 330 page book!"),
            ("released in 2026", "Released in 2026", "released in 2026", "Released in 2026.", "Released in 2026!"),
            ("it cost one fifty", "It cost one fifty", "it cost one fifty", "It cost one fifty.", "It cost one fifty!"),
            ("the price is $3.30.", "The price is $3.30", "the price is $3.30", "The price is $3.30.", "The price is $3.30!"),
            ("I live at 215 Oak Street", "I live at 215 Oak Street", "i live at 215 oak street", "I live at 215 Oak Street.", "I live at 215 Oak Street!"),
            ("area code 330 works", "Area code 330 works", "area code 330 works", "Area code 330 works.", "Area code 330 works!"),
            ("flight 215 tonight", "Flight 215 tonight", "flight 215 tonight", "Flight 215 tonight.", "Flight 215 tonight!"),
            ("one thirty second", "One thirty second", "one thirty second", "One thirty second.", "One thirty second!"),
            ("read chapters 1 30", "Read chapters 1 30", "read chapters 1 30", "Read chapters 1 30.", "Read chapters 1 30!"),
            ("215", "215", "215", "215.", "215!"),
        ]
        for (input, casual, veryCasual, formal, excited) in rows {
            for (style, expected) in [(TextStyle.casual, casual), (.veryCasual, veryCasual), (.formal, formal), (.excited, excited)] {
                XCTAssertEqual(style.apply(input), expected, "\(style) | \(input)")
            }
        }
    }

    // MARK: Review of 2026-11-21

    /// A time said as words after "at", "by" or "around" was a time before contextual clocks,
    /// whatever came next. The new tail check kept "I woke up at six fifteen this morning" in words.
    func testASpokenTimeWithACueIsATimeWhateverFollows() {
        for (input, expected) in [
            ("at nine thirty we left", "At 9:30 we left"),
            ("I woke up at six fifteen this morning", "I woke up at 6:15 this morning"),
            ("the meeting at two thirty got moved", "The meeting at 2:30 got moved"),
            ("she left at five forty five yesterday", "She left at 5:45 yesterday"),
            ("come by around seven thirty with the car", "Come by around 7:30 with the car"),
            ("until ten thirty every night", "Until 10:30 every night"),
            ("dinner at seven thirty at my place", "Dinner at 7:30 at my place"),
            ("it's twelve thirty here", "It's 12:30 here"),
            ("it was nine thirty already", "It was 9:30 already"),
            ("my flight lands at six forty in the morning", "My flight lands at 6:40 in the morning"),
            ("call me after five thirty when you're free", "Call me after 5:30 when you're free"),
            ("let's do nine thirty if that works", "Let's do 9:30 if that works"),
            ("we could meet nine thirty on Friday", "We could meet 9:30 on Friday"),
        ] {
            XCTAssertEqual(casual(input), expected, input)
        }
    }

    func testASpokenPairBeforeAUnitOrAfterAPriceWordStaysInWords() {
        for (input, expected) in [
            ("take ten fifteen minute breaks", "Take 10 15 minute breaks"),
            ("it cost one fifty", "It cost one fifty"),
            ("we bought two fifty inch screens", "We bought two 50 inch screens"),
            ("one thirty second", "One thirty second"),
        ] {
            XCTAssertEqual(casual(input), expected, input)
        }
    }

    /// The recognizer writes "two hundred" as 200 and "one fifty" as 150. After "by", "at" or
    /// "around" those are amounts far more often than clock times, and nobody says a time on
    /// the hour as "two hundred".
    func testRoundNumbersAndAmountsAreNotClockTimes() {
        for (input, expected) in [
            ("it went up by 100.", "It went up by 100"),
            ("there were around 500.", "There were around 500"),
            ("the price dropped to around 200, which is great", "The price dropped to around 200 which is great"),
            ("we're at 100.", "We're at 100"),
            ("valued at 1000.", "Valued at 1000"),
            ("multiply by 1000.", "Multiply by 1000"),
            ("it grew by 300 and then by 400", "It grew by 300 and then by 400"),
            ("after 500, we stop", "After 500 we stop"),
            ("I bought it at 250.", "I bought it at 250"),
            ("the temperature peaked at 105.", "The temperature peaked at 105"),
            ("increase it by 250.", "Increase it by 250"),
            ("I weigh around 150.", "I weigh around 150"),
            ("it was off by 115.", "It was off by 115"),
            ("after 911, everything changed", "After 911 everything changed"),
        ] {
            XCTAssertEqual(casual(input), expected, input)
        }
    }

    /// The same leads still read a packed time when nothing says amount.
    func testPackedTimesAfterEverydayVerbsStayTimes() {
        for (input, expected) in [
            ("I got up at 730.", "I got up at 7:30"),
            ("pick me up at 215.", "Pick me up at 2:15"),
            ("I get off at 530.", "I get off at 5:30"),
            ("showed up at 1130, which was late", "Showed up at 11:30 which was late"),
            ("be there by 845.", "Be there by 8:45"),
            ("said you couldn't wait till 839", "Said you couldn't wait till 8:39"),
            ("we can meet today after 1130? I'm coming back", "We can meet today after 11:30? I'm coming back"),
            ("be at my office at 1125 if that's okay", "Be at my office at 11:25 if that's okay"),
            ("Hey Apollo, um anytime after 215, let me know", "Hey Apollo anytime after 2:15 let me know"),
        ] {
            XCTAssertEqual(casual(input), expected, input)
        }
    }

    /// Zayd's report was three dictations, not one: the draft ended "but", and "Does three
    /// thirty work?" came nine minutes later. Each is checked the way it was inserted.
    func testTheApolloMessageAsItWasDictated() {
        let draft = casual("Perhaps a call at like five or so. Or if you're down for like a late night at one like 10-ish, maybe ten thirty, but")
        XCTAssertEqual(draft, "Perhaps a call at like 5 or so. Or if you're down for like a late night at one like 10-ish maybe 10:30 but")
        XCTAssertEqual(casual("Does three thirty work?", after: draft), " does 3:30 work?")
        XCTAssertEqual(casual("Does three thirty work?", after: nil), "Does 3:30 work?")
        for style in TextStyle.allCases {
            XCTAssertTrue(style.apply("Hey Apollo, um anytime after 215, let me know whatever would be easiest for you.").contains("after 2:15"), "\(style)")
            XCTAssertTrue(style.apply("Does three thirty work?").hasSuffix("oes 3:30 work?"), "\(style)")
        }
    }

    /// Two times joined by "or": when one is written as a clock the other is too.
    func testATimeBesideAWrittenClockIsAClock() {
        XCTAssertEqual(casual("right now so 1118 or 1218 pm."), "Right now so 11:18 or 12:18 pm")
        XCTAssertEqual(casual("is 215 or 3:30 better"), "Is 2:15 or 3:30 better")
        XCTAssertEqual(casual("we have 215 or 330 seats"), "We have 215 or 330 seats")
    }

    func testClockReadingsFromTheReplayAudit() {
        let readings = [
            ("at 215", "At 2:15"),
            ("by three thirty", "By 3:30"),
            ("room 215", "Room 215"),
            ("215 dollars", "215 dollars"),
            ("flight 215", "Flight 215"),
            ("in 2015", "In 2015"),
            ("a quarter past", "A quarter past"),
            ("half three", "3:30"),
            ("noon", "Noon"),
            ("three thirty ish", "3:30 ish"),
            ("from 2 to 430", "From 2 to 430"),
            ("1030 tomorrow", "10:30 tomorrow"),
            ("five to nine", "5 to 9"),
            ("215", "215"),
            ("three thirty", "3:30"),
            ("meet at 215 when school ends", "Meet at 2:15 when school ends"),
            ("meet at 215 outside the station", "Meet at 2:15 outside the station"),
            ("our table is ready at 215 sharp", "Our table is ready at 2:15 sharp"),
            ("set the alarm for 0705", "Set the alarm for 7:05"),
            ("the train leaves at 1745", "The train leaves at 17:45"),
            ("wake me at 900 am", "Wake me at 9:00 am"),
            ("call me at 911 pm", "Call me at 9:11 pm"),
            ("dial 911", "Dial 911"),
            ("build 215 works for me", "Build 215 works for me"),
            ("version 3.30 works for me", "Version 3.30 works for me"),
            ("meet at 215 Oak Avenue", "Meet at 215 Oak Avenue"),
            ("the venue seats around 215", "The venue seats around 215"),
            ("the bid closed at 215 pm", "The bid closed at 2:15 pm"),
            ("nine eleven was the time", "9:11 was the time"),
            ("the bid closed at 215", "The bid closed at 215"),
            ("the score stood at 215", "The score stood at 215"),
            ("the model ends in 215", "The model ends in 215"),
            ("the fee went from 215 to 430 dollars", "The fee went from 215 to 430 dollars"),
            ("the printer stopped at 3.30 percent", "The printer stopped at 3.30 percent"),
            ("a quarter past eight", "8:15"),
            ("a quarter to twelve PM", "11:45 am"),
            ("from 215 to 430 tomorrow", "From 2:15 to 4:30 tomorrow"),
            ("after eight oh five", "After 8:05"),
            ("meet at three twenty seven", "Meet at 3:27"),
            ("at 1265", "At 1265"),
            ("at 2.15 pm", "At 2:15 pm"),
            ("215 Broadway tomorrow", "215 Broadway tomorrow"),
            ("three thirty dollar gift cards", "Three 30 dollar gift cards"),
            ("update the firmware to 3.30 tomorrow", "Update the firmware to 3.30 tomorrow"),
            ("meet at half three", "Meet at 3:30"),
            ("meet at five to nine", "Meet at 8:55"),
            ("meet at 215, then call", "Meet at 2:15 then call"),
            ("the share price settled at 215", "The share price settled at 215"),
            ("our final headcount settled at 215", "Our final headcount settled at 215"),
            ("the home team's final score was 215", "The home team's final score was 215"),
            ("set the thermostat to 215", "Set the thermostat to 215"),
            ("version 3.30 tomorrow", "Version 3.30 tomorrow"),
            ("our ZIP code starts with 215", "Our ZIP code starts with 215"),
            ("the count rose from 215 to 430", "The count rose from 215 to 430"),
            ("nine eleven was a tragedy", "Nine eleven was a tragedy"),
            ("make it like 1230", "Make it like 1230"),
            ("the clock says 12 45", "The clock says 12:45"),
            ("meet me at two fifteen", "Meet me at 2:15"),
            ("does three thirty work", "Does 3:30 work"),
            ("the time below says 12 45 on screen", "The time below says 12:45 on screen"),
            ("the alarm is set for 0600", "The alarm is set for 6:00"),
            ("meet from 2 to 430", "Meet from 2 to 4:30"),
            ("meet at five to twelve PM", "Meet at 11:55 am"),
        ]
        for (heard, expected) in readings {
            XCTAssertEqual(casual(heard), expected, heard)
        }
    }
}
