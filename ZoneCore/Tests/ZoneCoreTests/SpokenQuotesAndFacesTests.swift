// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class SpokenQuotesAndFacesTests: XCTestCase {
    private func casual(_ text: String) -> String { TextStyle.casual.apply(text) }
    private func formal(_ text: String) -> String { TextStyle.formal.apply(text) }

    func testASecondQuoteClosesTheFirst() {
        XCTAssertEqual(formal("he said quote I am done quote and left"), "He said \"I am done\" and left.")
        XCTAssertEqual(formal("he said quote yes quote and she said quote maybe quote"), "He said \"yes\" and she said \"maybe\"")
    }

    func testTheRecognizersSpellingsOfUnquoteClose() {
        for closer in ["on quote", "un quote", "un-quote", "unquote", "end quote"] {
            XCTAssertEqual(casual("he said quote I am done \(closer)"), "He said \"I am done\"", closer)
        }
        // With no quote open, "on quote" is two words.
        XCTAssertEqual(casual("the price is on quote only"), "The price is on quote only")
    }

    func testAQuoteAfterAWordForSpeechRunsToTheEndOfTheSentence() {
        XCTAssertEqual(casual("she said quote hello"), "She said \"hello\"")
        XCTAssertEqual(formal("she was like quote no way. Then she left."), "She was like \"no way.\" Then she left.")
        XCTAssertEqual(casual("she said quote"), "She said quote")
    }

    func testEachSpeakerGetsTheirOwnQuotation() {
        XCTAssertEqual(formal("And then he said, quote, goodbye, and I said, quote, why would you say that?"),
                       "And then he said, \"goodbye\" and I said, \"why would you say that?\"")
        XCTAssertEqual(casual("she was like quote no and then he was like quote yes"),
                       "She was like \"no\" and then he was like \"yes\"")
    }

    func testQuoteUnquoteMarksTheNextWord() {
        XCTAssertEqual(formal("the quote unquote expert said no"), "The \"expert\" said no.")
        XCTAssertEqual(formal("the quote, unquote, expert said no"), "The \"expert\" said no.")
    }

    func testTheNounAndTheVerbStayWords() {
        for said in ["Can you send me a quote for the roof", "I'll quote you on that", "Quote tweet that",
                     "I got a quote and another quote", "The quote was too high so get a new quote",
                     "They quote me one price and quote him another"] {
            XCTAssertEqual(formal(said), said + ".", said)
        }
    }

    func testFacesInTheTextingStyles() {
        XCTAssertEqual(casual("see you soon smiley face"), "See you soon :)")
        XCTAssertEqual(TextStyle.veryCasual.apply("Ok winky face."), "ok ;)")
        XCTAssertEqual(casual("that sucks sad face"), "That sucks :(")
        XCTAssertEqual(casual("Smiley face, see you then"), ":) see you then")
        XCTAssertEqual(casual("miss you crying face kissy face"), "Miss you :'( :*")
        XCTAssertEqual(TextStyle.veryCasual.apply("gotcha tongue face"), "gotcha :P")
    }

    func testFacesStayWordsWhenDescribedOrFormalOrOff() {
        for said in ["Send a smiley face", "She made a sad face", "I saw her crying face", "Draw 2 smiley faces",
                     "The winky face emoji"] {
            XCTAssertEqual(casual(said), said, said)
        }
        XCTAssertEqual(formal("see you soon smiley face"), "See you soon smiley face.")
        XCTAssertEqual(TextStyle.excited.apply("see you soon smiley face"), "See you soon smiley face!")
        XCTAssertEqual(TextStyle.casual.apply("see you soon smiley face", emoticons: false), "See you soon smiley face")
    }

    /// Zayd, November 16: "upside down smiley face" wrote "upside down :)". The upside-down face
    /// is the smiley turned around, "(:".
    func testUpsideDownSmileyIsTheSmileyTurnedAround() {
        XCTAssertEqual(casual("love you upside down smiley face"), "Love you (:")
        XCTAssertEqual(casual("love you upside-down smiley face."), "Love you (:")
        XCTAssertEqual(casual("ok upside down face"), "Ok (:")
        XCTAssertEqual(casual("sure upside down smiling face"), "Sure (:")
        XCTAssertEqual(TextStyle.veryCasual.apply("Upside down smiley face, see you"), "(: see you")
        XCTAssertEqual(casual("the upside down face emoji"), "The upside down face emoji")
        XCTAssertEqual(casual("he landed upside down face first"), "He landed upside down face first")
    }

    func testTheWaysPeopleSayEachFace() {
        let said: [(String, String)] = [
            ("smiley", ":)"), ("smiling", ":)"), ("happy", ":)"), ("smile", ":)"),
            ("winky", ";)"), ("winking", ";)"), ("wink", ";)"),
            ("sad", ":("), ("frowny", ":("), ("frowning", ":("), ("frown", ":("), ("unhappy", ":("),
            ("crying", ":'("), ("cry", ":'("),
            ("kissy", ":*"), ("kissing", ":*"),
            ("tongue", ":P"), ("tongue out", ":P"),
            ("laughing", ":D"), ("grinning", ":D"),
        ]
        for (name, face) in said {
            XCTAssertEqual(casual("ok see you \(name) face"), "Ok see you \(face)", name)
            XCTAssertEqual(casual("ok see you \(name) face, bye"), "Ok see you \(face) bye", name)
        }
    }

    /// A list of faces reads one way: all sent, or all named. "A smiley face or sad face" names
    /// faces, so neither turns into a mark; without the article they are all sent. Three or more
    /// in a row are always sent: that is someone listing emoticons (Zayd, November 16).
    func testAListOfFacesFollowsItsFirstFace() {
        XCTAssertEqual(casual("ok smiley face, sad face, winky face, upside down smiley face."), "Ok :) :( ;) (:")
        XCTAssertEqual(casual("it has a smiley face, sad face, winky face, upside down smiley face."),
                       "It has a :) :( ;) (:")
        XCTAssertEqual(casual("pick a smiley face or sad face"), "Pick a smiley face or sad face")
        XCTAssertEqual(casual("lol smiley face and winky face"), "lol :) and ;)")
    }

    func testFaceTimeAndFaceDownAreNotFaces() {
        XCTAssertEqual(casual("I'm happy face timing you later"), "I'm happy face timing you later")
        XCTAssertEqual(casual("he lay sad face down on the bed"), "He lay sad face down on the bed")
        XCTAssertEqual(casual("we made sad face at him"), "We made sad face at him")
    }

    func testTheFaceSettingDefaultsOnAndSurvivesOlderRecords() throws {
        XCTAssertTrue(KeyboardPreferences().spokenEmoticons)
        let old = Data(#"{"autocorrectEnabled":true}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(KeyboardPreferences.self, from: old).spokenEmoticons)
        let off = KeyboardPreferences(spokenEmoticons: false)
        XCTAssertFalse(try JSONDecoder().decode(KeyboardPreferences.self, from: JSONEncoder().encode(off)).spokenEmoticons)
    }

    func testShorthandSaidAsLetters() {
        XCTAssertEqual(casual("that is TS"), "That is ts")
        XCTAssertEqual(casual("T S pmo"), "ts pmo")
        XCTAssertEqual(casual("T-S is crazy FR"), "ts is crazy fr")
        XCTAssertEqual(casual("LMK when you land"), "lmk when you land")
        XCTAssertEqual(casual("he is the GOAT"), "He is the goat")
        XCTAssertEqual(formal("T-S is crazy FR"), "TS is crazy FR.")
        // Only from capitals: a name, and letters that are part of something else, stay.
        XCTAssertEqual(casual("Ty said hi to Al"), "Ty said hi to Al")
        // "A.I." is written without periods, then lowercased like "AI" (November 15).
        XCTAssertEqual(casual("the A.I. lab and the T S Eliot book"), "The ai lab and the T S Eliot book")
        XCTAssertEqual(casual("the API and my LLMs"), "The API and my LLMs")
    }

    func testNicknamesAndSlang() {
        XCTAssertEqual(formal("I went to TJs and B Dubs then mickey ds"), "I went to TJ's and B-Dubs then Mickey D's.")
        XCTAssertEqual(casual("I went to tj's and bdubs"), "I went to TJ's and b-dubs")
        XCTAssertEqual(formal("we got in n out and whataburger"), "We got In-N-Out and Whataburger.")
        // Ordinary phrases that sound like a name are left alone.
        XCTAssertEqual(formal("what a burger that was"), "What a burger that was.")
        XCTAssertEqual(formal("those five guys left"), "Those five guys left.")
        let corrector = Autocorrector(words: WordList.shared!)
        for word in ["rizzler", "skibidi", "tryna", "finna", "deadass", "yapper", "unc", "sybau"] {
            XCTAssertNil(corrector.evaluate(word).replacement, word)
        }
    }
}
