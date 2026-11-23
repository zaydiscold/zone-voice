// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// Reported Nov 8 from Messages: "so this was This was one of those times". The speaker restarted
/// and the recognizer wrote the restart as a new sentence with no mark before it.
final class RecognizerRestartCaseTests: XCTestCase {
    func testARestartMidSentenceLosesTheRecognizersCapital() {
        // Since November 17 the stutter filter keeps one copy of a phrase said twice like this.
        let heard = "It was not bad I usually just sleep super exhausted so this was This was one of those times"
        XCTAssertEqual(TextStyle.casual.apply(heard),
                       "It was not bad I usually just sleep super exhausted so this was one of those times")
        // A restart in other words keeps both, and still loses the capital.
        XCTAssertEqual(TextStyle.casual.apply("so this was That was one of those times"),
                       "So this was that was one of those times")
        XCTAssertEqual(TextStyle.formal.apply("we went home And then we slept"), "We went home and then we slept.")
        XCTAssertEqual(TextStyle.casual.apply("honestly That's fine with me"), "Honestly that's fine with me")
        XCTAssertEqual(TextStyle.casual.insertion(of: "and so It works now", contextBefore: "ok ",
                                                  fieldCapitalizesSentences: true), "and so it works now")
    }

    /// Found in the Nov 8 audit: a restart followed by "I" kept its capital.
    func testRestartsBeforeIAreLowered() {
        XCTAssertEqual(TextStyle.casual.apply("I went home Then I slept"), "I went home then I slept")
        XCTAssertEqual(TextStyle.casual.apply("we left early So I'm home now"), "We left early so I'm home now")
    }

    func testRealCapitalsStay() {
        let kept = [
            "so I think I'll go", "we watched The Office last night", "I loved It Follows",
            "she starts in May and leaves in June", "ask Will about it", "we met John and Grace there",
            "I use NASA data on my iPhone", "so this was. This was one of those times",
            "we saw This Is Us", "see you at the Apple store", "I love This Is Us so much",
            "we watched The Office and it was fun", "she said Will I be there",
            "I listened to The Beatles today", "my favorite artist is The Weeknd okay",
            "he said no, John was there", "it was fine; May is better", "pick options A and B",
            "so this was, This was one of those times", "I lift it up, To the light",
        ]
        for text in kept {
            let formal = TextStyle.formal.apply(text)
            XCTAssertEqual(formal.hasSuffix(".") ? String(formal.dropLast()) : formal,
                           text.prefix(1).uppercased() + text.dropFirst(), text)
        }
    }

    func testSpokenMarksAndLiteralsAreUntouched() {
        XCTAssertEqual(TextStyle.casual.apply("check https://example.com/The thing"), "Check https://example.com/The thing")
        XCTAssertEqual(TextStyle.formal.apply("done period This is next"), "Done. This is next.")
    }
}

/// Reported Nov 8: a dictation continuing a sentence kept "The" or "My" capitalized. "the" was in
/// the bundled names list, so it was never lowered, and a recording stopped mid-sentence ended
/// "I went to the." so the next one opened a new sentence.
final class UnfinishedSentenceCapsTests: XCTestCase {
    func testTheContinuesASentenceLikeAnyPlainWord() {
        XCTAssertEqual(TextStyle.casual.insertion(of: "The store was closed.", contextBefore: "I went to",
                                                  fieldCapitalizesSentences: true), " the store was closed")
        XCTAssertEqual(TextStyle.formal.insertion(of: "The keys?", contextBefore: "Can you grab",
                                                  fieldCapitalizesSentences: true), " the keys?")
        XCTAssertEqual(SegmentText.join("so this was", "The best day ever."), "so this was the best day ever.")
        for word in ["the", "no", "think", "those", "trying", "real"] {
            XCTAssertFalse(TextStyle.givenNames.contains(word), word)
        }
        // Names keep their capitals; a period before the dictation still starts a sentence.
        XCTAssertEqual(TextStyle.casual.insertion(of: "Mark about it.", contextBefore: "I talked to",
                                                  fieldCapitalizesSentences: true), " Mark about it")
        XCTAssertEqual(TextStyle.casual.insertion(of: "The plan works.", contextBefore: "Hey.",
                                                  fieldCapitalizesSentences: true), " The plan works")
    }

    func testAStopAfterAnUnfinishedWordIsNotASentenceEnd() {
        XCTAssertEqual(TextStyle.formal.apply("I went to the."), "I went to the")
        XCTAssertEqual(TextStyle.formal.apply("I love my dog and. The cat is fine."), "I love my dog and the cat is fine.")
        XCTAssertEqual(SegmentText.join("so we went to my.", "Friend's house."), "so we went to my friend's house.")
        XCTAssertEqual(TextStyle.casual.insertion(of: "My friend came too.", contextBefore: TextStyle.formal.apply("I went to the"),
                                                  fieldCapitalizesSentences: true), " my friend came too")
    }

    func testRealSentenceEndsStay() {
        for text in ["Oh my. That was close.", "We picked plan A. The rest failed.", "Meet at 10 a.m. The room is booked.",
                     "I want to go to the. Mark said no.", "It is mine and. I think so.", "Fill in n/a.", "At D AN."] {
            XCTAssertEqual(TextStyle.formal.apply(text), text, text)
        }
        XCTAssertEqual(TextStyle.formal.apply("I don't want to"), "I don't want to.")
    }
}
