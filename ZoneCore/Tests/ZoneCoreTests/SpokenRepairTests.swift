// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// Spoken repairs, pinned from the 2026-11-08 measurement: a labeled corpus spoken by four macOS
/// voices and recognized by Fluid Speech Mini, plus 39,275 lines of dialogue and novels run
/// through this build and the one before it. Inputs below are written the way the recognizer
/// wrote them, including its full stops at pauses and its "no weight".
/// Self-corrections are a Beta setting, so these cases turn it on; stutters and clock times
/// always run.
final class SpokenRepairTests: XCTestCase {
    private func formal(_ text: String) -> String { TextStyle.formal.apply(text, spokenCorrections: true) }

    // MARK: The Beta setting

    func testSelfCorrectionsAreOffByDefault() {
        XCTAssertEqual(TextStyle.formal.apply("Let's meet Tuesday, scratch that, Wednesday."),
                       "Let's meet Tuesday, scratch that, Wednesday.")
        XCTAssertEqual(TextStyle.formal.apply("I'll be there at 3, no wait, 4."), "I'll be there at 3, no wait, 4.")
        XCTAssertEqual(TextStyle.formal.insertion(of: "Let's meet Tuesday, scratch that, Wednesday.",
                                                  contextBefore: nil, fieldCapitalizesSentences: true),
                       "Let's meet Tuesday, scratch that, Wednesday.")
        XCTAssertEqual(TextStyle.formal.insertion(of: "Let's meet Tuesday, scratch that, Wednesday.",
                                                  contextBefore: nil, fieldCapitalizesSentences: true,
                                                  spokenCorrections: true),
                       "Let's meet Wednesday.")
    }

    func testStuttersAndClockTimesRunWithTheBetaOff() {
        XCTAssertEqual(TextStyle.formal.apply("I I think we meet at 4.30."), "I think we meet at 4:30.")
    }

    func testOlderPreferencesDecodeWithTheBetaOff() throws {
        let old = Data(#"{"autocorrectEnabled":true,"handleRecognition":true}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(KeyboardPreferences.self, from: old).spokenCorrections)
        XCTAssertFalse(KeyboardPreferences().spokenCorrections)
        let on = KeyboardPreferences(spokenCorrections: true)
        XCTAssertTrue(try JSONDecoder().decode(KeyboardPreferences.self, from: JSONEncoder().encode(on)).spokenCorrections)
    }

    // MARK: Corrections that apply

    func testScratchThatSwapsTheLastName() {
        XCTAssertEqual(formal("Let's meet Tuesday, scratch that, Wednesday."), "Let's meet Wednesday.")
        // A pause becomes a full stop for some voices; the repair still lands mid-sentence.
        XCTAssertEqual(formal("Let's meet Tuesday. Scratch that. Wednesday."), "Let's meet Wednesday.")
    }

    func testRepairKeepsTheWordsBeforeTheSlot() {
        XCTAssertEqual(formal("Dinner is on Friday, scratch that, Saturday night."), "Dinner is on Saturday night.")
        XCTAssertEqual(formal("We need 10 chairs, no wait, 12 chairs."), "We need 12 chairs.")
        XCTAssertEqual(formal("The total is 40 dollars, no wait, 50 dollars."), "The total is 50 dollars.")
    }

    func testRepeatedWordRewindsToIt() {
        XCTAssertEqual(formal("Send it to Mike, scratch that, to Sarah."), "Send it to Sarah.")
        XCTAssertEqual(formal("Get the red one, strike that, the blue one."), "Get the blue one.")
        XCTAssertEqual(formal("I can't make it tonight, scratch that, I can make it tomorrow."), "I can make it tomorrow.")
        XCTAssertEqual(formal("Pick up the milk. Delete that. Pick up the bread."), "Pick up the bread.")
        XCTAssertEqual(formal("Pick up the milk, delete that, pick up the bread."), "Pick up the bread.")
    }

    func testNoWaitSwapsNumbers() {
        XCTAssertEqual(formal("I'll be there at 3, no wait, 4."), "I'll be there at 4.")
        XCTAssertEqual(formal("I'll be there at 3. No wait, 4."), "I'll be there at 4.")
        XCTAssertEqual(formal("The total is 40 dollars, no weight, 50 dollars."), "The total is 50 dollars.")
        XCTAssertEqual(formal("Call me at 5.30, no wait, 6.30."), "Call me at 6:30.")
        // Said as words (Apple and Moonshine can write them): the whole number is the slot.
        XCTAssertEqual(formal("Call me at five thirty, no wait, six thirty."), "Call me at 6:30.")
    }

    func testTrailingScratchThatTakesBackThePhraseOrSentence() {
        XCTAssertEqual(formal("Buy eggs, milk, and butter, scratch that."), "Buy eggs, milk.")
        XCTAssertEqual(formal("See you soon. Buy eggs. Scratch that."), "See you soon.")
    }

    func testRepairAppliesInEveryStyle() {
        XCTAssertEqual(TextStyle.casual.apply("Let's meet Tuesday, scratch that, Wednesday.", spokenCorrections: true),
                       "Let's meet Wednesday")
        XCTAssertEqual(TextStyle.veryCasual.apply("Let's meet Tuesday, scratch that, Wednesday.", spokenCorrections: true),
                       "let's meet wednesday")
    }

    // MARK: Without the recognizer's commas

    /// Zayd's phone, November 15 (Fluid Speech Mini, keyboard): "They're crazy flat scratch that
    /// crazy fast." The recognizer set no commas around the cue, so nothing was repaired. Unfenced,
    /// "scratch that" counts only when the words after it repeat a word just before it, or swap a
    /// number or a name like for like.
    func testUnfencedScratchThatRepairsWhenTheRepairMatches() {
        XCTAssertEqual(formal("They're crazy flat scratch that crazy fast."), "They're crazy fast.")
        XCTAssertEqual(formal("Let's meet Tuesday scratch that Wednesday."), "Let's meet Wednesday.")
        XCTAssertEqual(formal("I'll be there at 3 scratch that 4."), "I'll be there at 4.")
        XCTAssertEqual(formal("We need 10 chairs scratch that 12 chairs."), "We need 12 chairs.")
        XCTAssertEqual(formal("Send it to Mike scratch that to Sarah."), "Send it to Sarah.")
        XCTAssertEqual(formal("I want pizza. Scratch that I want tacos."), "I want tacos.")
        XCTAssertEqual(formal("Tell Mike, scratch that Sarah, that I'm late."), "Tell Sarah, that I'm late.")
        XCTAssertEqual(TextStyle.casual.apply("They're crazy flat scratch that crazy fast.", spokenCorrections: true),
                       "They're crazy fast")
    }

    func testUnfencedScratchThatAsPlainEnglishStays() {
        for text in ["I want to scratch that itch.", "Can you scratch that off the list for me?",
                     "Cats scratch that couch all day.", "Let me scratch that idea.", "The cat will scratch that cat tree.",
                     "I don't know if Scratch that and No8 work.", "Don't scratch that, it's new.",
                     "Please scratch that record off the list.", "I scratch that spot on his back and he loves it.",
                     "We said scratch that a lot."] {
            XCTAssertEqual(formal(text), text, text)
        }
    }

    /// The recognizer's spellings of "no wait": "no weight", "No8" (Zayd's phone, November 16) and
    /// "know wait". Fenced by punctuation they are the cue; a "No8" being talked about is not.
    func testTheRecognizersSpellingsOfNoWait() {
        XCTAssertEqual(formal("I'll be there at 3, No8, 4."), "I'll be there at 4.")
        XCTAssertEqual(formal("I'll be there at 3. No8, 4."), "I'll be there at 4.")
        XCTAssertEqual(formal("I'll be there at 3, know wait, 4."), "I'll be there at 4.")
        XCTAssertEqual(formal("The total is 40 dollars, no weight, 50 dollars."), "The total is 50 dollars.")
        XCTAssertEqual(formal("Is it 3? No8, 4."), "Is it 3? No8, 4.")
        XCTAssertEqual(formal("You know, wait for me."), "You know, wait for me.")
    }

    /// Said on its own, the keyboard takes back the dictation before it. The recognizer writes it
    /// with a capital, a period, an exclamation mark or nothing.
    func testStandaloneScratchThatInTheRecognizersSpellings() {
        for said in ["Scratch that.", "scratch that", "Scratch that!", " Scratch that. ", "Scratch that,", "Strike that."] {
            XCTAssertTrue(SpokenRepair.isStandaloneCommand(said), said)
        }
        for said in ["Scratch that itch.", "No wait.", "Scratch", "that"] {
            XCTAssertFalse(SpokenRepair.isStandaloneCommand(said), said)
        }
    }

    // MARK: Left as said

    func testCueWordsInsideASentenceAreProse() {
        for text in ["I want to scratch that itch.", "Can you delete that file for me?",
                     "He said no wait times at the clinic.", "Don't delete that, it's important.",
                     "No, wait for me at the door.", "Strike that pose for the camera.",
                     "Scratch that off the list."] {
            XCTAssertEqual(formal(text), text, text)
        }
    }

    func testNoWaitAsAnAnswerOrARephraseStays() {
        XCTAssertEqual(formal("Is it Monday? No, wait, it's Tuesday."), "Is it Monday? No, wait, it's Tuesday.")
        XCTAssertEqual(formal("I thought it was Monday. No, wait, it's Tuesday."),
                       "I thought it was Monday. No, wait, it's Tuesday.")
        // A long repair without a matching word is too uncertain for "no wait".
        XCTAssertEqual(formal("OK, make a left here... no wait, I meant make a right."),
                       "OK, make a left here... no wait, I meant make a right.")
    }

    func testIMeanAndActuallyAreNeverCues() {
        XCTAssertEqual(formal("Tell him I'm running late, I mean really late."), "Tell him I'm running late, I mean really late.")
        XCTAssertEqual(formal("The flight is at 6, actually 7."), "The flight is at 6, actually 7.")
    }

    func testCueAtTheStartIsLeftForTheKeyboard() {
        XCTAssertTrue(SpokenRepair.isStandaloneCommand("Scratch that."))
        XCTAssertTrue(SpokenRepair.isStandaloneCommand("delete that"))
        XCTAssertFalse(SpokenRepair.isStandaloneCommand("No wait."))
        XCTAssertFalse(SpokenRepair.isStandaloneCommand("Scratch that off the list."))
        XCTAssertEqual(formal("Scratch that, call me later."), "Scratch that, call me later.")
    }

    func testURLsAreNeverEdited() {
        XCTAssertEqual(formal("Go to zone.app/help, no wait, zone.app/faq."), "Go to zone.app/help, no wait, zone.app/faq.")
    }

    // MARK: Stutters

    func testAccidentalDoublesCollapse() {
        XCTAssertEqual(formal("I I think we should go."), "I think we should go.")
        XCTAssertEqual(formal("There are many things you have to to arrange."), "There are many things you have to arrange.")
        XCTAssertEqual(formal("We always went out and and had fun."), "We always went out and had fun.")
    }

    func testGrammaticalDoublesStay() {
        for text in ["I know that that is true.", "What it is is a scam.", "You can log in in the morning.",
                     "The movie was so so.", "I told you you had a remarkable face.", "He had had enough.",
                     "My my, look at you.", "Type a a few times."] {
            XCTAssertEqual(formal(text), text, text)
        }
    }

    /// Zayd's dictation of November 17, as the recognizer wrote it.
    func testCutOffSoundsAreDropped() {
        XCTAssertEqual(SpokenRepair.collapsingStutters(
            "sometimes I I don't know I was just f- fidgeting I was just p- pivoting I was just g- giving"),
            "sometimes I don't know I was just fidgeting I was just pivoting I was just giving")
        // From his recordings: the sound need not start the next word, and can be longer than a letter.
        XCTAssertEqual(stutters("Um, is this r- healthy?"), "Um, is this healthy?")
        XCTAssertEqual(stutters("because there's channels that I was l- s- looking in"), "because there's channels that I was looking in")
        XCTAssertEqual(stutters("Then why don't you fla- literally flash your data over?"), "Then why don't you literally flash your data over?")
        XCTAssertEqual(stutters("a little bit Too distract- you know, whatever"), "a little bit Too you know, whatever")
        XCTAssertEqual(stutters("what do you mean tw- twenty-three gigabytes"), "what do you mean twenty-three gigabytes")
        XCTAssertEqual(stutters("just complete the E- EHS ones"), "just complete the EHS ones")
        // What a cut-off leaves behind is a doubled word or a restarted phrase, and goes too.
        XCTAssertEqual(stutters("the you know, the s- the stars, the the day"), "the you know, the stars, the day")
        XCTAssertEqual(stutters("I don't understand what you j- what you just did."), "I don't understand what you just did.")
        XCTAssertEqual(stutters("pretty much we've been do- we've been sending plates"), "pretty much we've been sending plates")
        // A sentence that opened with one keeps its capital, and no space is left behind.
        XCTAssertEqual(stutters("Fine. S- so I think we go"), "Fine. So I think we go")
        XCTAssertEqual(stutters("W- we should go"), "We should go")
        XCTAssertEqual(stutters("I was going to the st-"), "I was going to the")
        XCTAssertEqual(stutters("first line\nf- fidgeting"), "first line\nfidgeting")
    }

    func testHangingHyphensThatAreWritingStay() {
        for text in ["The pre- and post-war years.", "Use first- and second-order terms.", "A long- or short-term loan.",
                     "I got a B- in chemistry.", "He was Diddy P- back then.", "Spell it T-A- then N.",
                     "Send an e- mail.", "It is well-known and up-to-date.", "A 5- to 10-minute walk.",
                     "Go to zone.app/a- now."] {
            XCTAssertEqual(stutters(text), text, text)
        }
    }

    func testDoubledWordsFromRecordings() {
        XCTAssertEqual(stutters("bunch of different ones because it's it's too complex"), "bunch of different ones because it's too complex")
        XCTAssertEqual(stutters("Like we're we're trying to"), "Like we're trying to")
        XCTAssertEqual(stutters("you make a a face out of a colon"), "you make a face out of a colon")
        XCTAssertEqual(stutters("or lose all my my notes."), "or lose all my notes.")
        XCTAssertEqual(stutters("Maybe Maybe there could be a toggle"), "Maybe there could be a toggle")
        XCTAssertEqual(stutters("what what do you mean?"), "what do you mean?")
        XCTAssertEqual(stutters("Why is the the the the ship there"), "Why is the ship there")
        XCTAssertEqual(stutters("for the purpose of Of like gathering data"), "for the purpose of like gathering data")
        XCTAssertEqual(stutters("So like like we did before"), "So like we did before")
        XCTAssertEqual(stutters("we went with the the, you know, plan"), "we went with the, you know, plan")
        XCTAssertEqual(stutters("A a couple of them."), "A couple of them.")
    }

    func testDoubledWordsThatCanBeMeantStay() {
        for text in ["If you click it it goes through.", "I told you you could.", "Do this this way.", "It was really really good.",
                     "No no no.", "Wait wait, what is that?", "I'm not not saying it.", "We do do some cleaning.",
                     "Turn it on on Monday.", "Do you like like him?", "Oh my my, that is big.", "Press a a few times.",
                     "D A A N", "A A National", "the, the other one", "It's. It's fine.", "blah blah blah"] {
            XCTAssertEqual(stutters(text), text, text)
        }
    }

    func testRestartedPhrasesKeepOneCopy() {
        XCTAssertEqual(stutters("hold the beads in the in the AMS"), "hold the beads in the AMS")
        XCTAssertEqual(stutters("I don't I don't really know"), "I don't really know")
        XCTAssertEqual(stutters("How is how is my phone connected?"), "How is my phone connected?")
        XCTAssertEqual(stutters("Can you can you open the settings?"), "Can you open the settings?")
        XCTAssertEqual(stutters("but in like a in like a guided tour"), "but in like a guided tour")
        XCTAssertEqual(stutters("they wanted to they wanted to do conversions"), "they wanted to do conversions")
        XCTAssertEqual(stutters("How to how to buy a bus"), "How to buy a bus")
        XCTAssertEqual(stutters("I guess I guess he told me yesterday"), "I guess he told me yesterday")
        XCTAssertEqual(stutters("Upgrade the copper the copper to gold wire"), "Upgrade the copper to gold wire")
        XCTAssertEqual(stutters("I want I want I want to go"), "I want to go")
        XCTAssertEqual(stutters("Let me let me do the soundtrack."), "Let me do the soundtrack.")
    }

    func testRepeatedPhrasesThatCanBeMeantStay() {
        for text in ["Thank you thank you so much.", "Come on come on let's go.", "I know I know but it is hard.",
                     "Send them one by one by one when done.", "It got more and more and more crowded.",
                     "They won back to back to back titles.", "He dropped in from time to time to see us.",
                     "The notions you have to have to finish it.", "Everything I do I do it for you.",
                     "It was on off on off all day.", "Read me one two one two three.", "Oh my oh my goodness.",
                     "I guess. I guess it's good to keep.", "What else? What else?", "the keywords, the keywords and the dictionary",
                     "I enjoy calling a spade a spade and hate fuss.", "New York New York is a song.", "Got it got it thanks.",
                     "I do. I do.", "That is that is.", "in the in the", "At D-A-A-N AT D-A-A-N AT D-A-A-N",
                     "Write at sign B at sign B at sign C."] {
            XCTAssertEqual(stutters(text), text, text)
        }
    }

    /// Whole words go or stay: nothing with no space in it is edited, and spacing is kept.
    func testStutterFilterLeavesEverythingElseAlone() {
        for text in ["", " ", "I", "the", "zone.app/the/the", "the-the", "@the the", "I\n\nI think", "  I think  ",
                     "a  b\tc", "in the\nin the box"] {
            XCTAssertEqual(stutters(text), text, text.debugDescription)
        }
        XCTAssertEqual(stutters("“The the plan”"), "“The plan”")
        XCTAssertEqual(stutters("I  I   think"), "I   think")
        XCTAssertEqual(stutters("(to to be fair)"), "(to be fair)")
        // Running it again changes nothing.
        for text in ["I I I think the the s- the stars in the in the sky", "we we've been we've been here"] {
            let once = stutters(text)
            XCTAssertEqual(stutters(once), once)
        }
    }

    private func stutters(_ text: String) -> String { SpokenRepair.collapsingStutters(text) }

    func testSpelledLettersAreNotAStutter() {
        XCTAssertEqual(SpokenRepair.collapsingStutters("spell D A A N"), "spell D A A N")
        XCTAssertEqual(SpokenRepair.collapsingStutters("H A W A I I"), "H A W A I I")
        XCTAssertEqual(SpokenRepair.collapsingStutters("but I I don't mind"), "but I don't mind")
        // "İstanbul" lowercased is "i" plus a combining dot: one word, not a second "i".
        XCTAssertEqual(TextStyle.veryCasual.apply(TextStyle.veryCasual.apply("I İstanbul trip")),
                       TextStyle.veryCasual.apply("I İstanbul trip"))
    }

    // MARK: Clock times

    func testDottedTimesBecomeColons() {
        XCTAssertEqual(formal("Meet me at 4.30 tomorrow."), "Meet me at 4:30 tomorrow.")
        XCTAssertEqual(formal("It's open until 9.45."), "It's open until 9:45.")
        XCTAssertEqual(formal("The train leaves at 7.15 p.m."), "The train leaves at 7:15 p.m.")
    }

    func testPricesAndDecimalsKeepTheirPoint() {
        for text in ["Gas was 4.30 a gallon.", "Gas was $4.30 a gallon.", "Prices went from 3.50 to 4.30.",
                     "It sold at 4.30 dollars.", "Version 4.30.1 is out.", "It grew by 2.5 percent."] {
            XCTAssertEqual(formal(text), text, text)
        }
    }
}
