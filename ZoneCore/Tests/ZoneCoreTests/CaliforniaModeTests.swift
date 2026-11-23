// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// California Mode, pinned from the 2026-11-12 measurement: three labeled corpora spoken by four
/// macOS voices and recognized by Fluid Speech Mini, plus five novels, 30,000 DailyDialog turns and
/// the Santa Barbara Corpus of Spoken American English. Inputs are written the way the recognizer
/// wrote them, which is mostly without commas ("I was like really tired"). The meaning cases
/// include every "like" the real text showed being removed by mistake while the rules were built.
final class CaliforniaModeTests: XCTestCase {
    private func light(_ text: String) -> String { TextStyle.formal.apply(text, california: .light) }
    private func aggressive(_ text: String) -> String { TextStyle.formal.apply(text, california: .aggressive) }
    /// What formal writes for a sentence with no "like" in it: dictated numbers become digits
    /// ("five minutes" is "5 minutes"), which these cases were written before.
    private func written(_ text: String) -> String { TextStyle.formal.apply(text) }

    // MARK: The Beta setting

    func testOffByDefault() {
        XCTAssertEqual(TextStyle.formal.apply("It was, like, so good."), "It was, like, so good.")
        XCTAssertEqual(TextStyle.formal.apply("It was, like, so good.", california: .off), "It was, like, so good.")
        XCTAssertEqual(TextStyle.formal.insertion(of: "I was like really tired.", contextBefore: nil,
                                                  fieldCapitalizesSentences: true),
                       "I was like really tired.")
    }

    func testOlderPreferencesDecodeWithCaliforniaModeOff() throws {
        let old = Data(#"{"autocorrectEnabled":true,"spokenCorrections":true}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(KeyboardPreferences.self, from: old).californiaMode, .off)
        XCTAssertEqual(KeyboardPreferences().californiaMode, .off)
        for mode in CaliforniaMode.allCases {
            let stored = try JSONEncoder().encode(KeyboardPreferences(californiaMode: mode))
            XCTAssertEqual(try JSONDecoder().decode(KeyboardPreferences.self, from: stored).californiaMode, mode)
        }
        // A level this build does not know falls back alone, without resetting the other switches.
        let future = Data(#"{"autocorrectEnabled":false,"californiaMode":"hyphy"}"#.utf8)
        let decoded = try JSONDecoder().decode(KeyboardPreferences.self, from: future)
        XCTAssertEqual(decoded.californiaMode, .off)
        XCTAssertFalse(decoded.autocorrectEnabled)
    }

    // MARK: Light

    func testLightRemovesFillers() {
        let cases = [
            ("It was, like, so good.", "It was so good."),
            ("Like, I don't even know what happened.", "I don't even know what happened."),
            ("I was like really tired after the game.", "I was really tired after the game."),
            ("She's like super nice to everyone.", "She's super nice to everyone."),
            ("So like what are we doing tonight?", "So what are we doing tonight?"),
            ("But like why would he say that?", "But why would he say that?"),
            ("So like how long is this going to take?", "So how long is this going to take?"),
            ("I don't know, like.", "I don't know."),
            ("Like honestly I don't care anymore.", "Honestly I don't care anymore."),
            ("The movie was like really long but like pretty good.", "The movie was really long but pretty good."),
            ("And like, we just sat there for an hour.", "And we just sat there for an hour."),
            ("I mean, like, it's fine I guess.", "I mean, it's fine I guess."),
            ("Like seriously, stop texting me.", "Seriously, stop texting me."),
            ("Wait, like, really?", "Wait, really?"),
            ("I got there late, like, really late.", "I got there late, really late."),
            ("It's, like, really hard to explain.", "It's really hard to explain."),
            ("We went to the beach and it was like amazing.", "We went to the beach and it was amazing."),
            ("It was like the worst traffic ever.", "It was the worst traffic ever."),
            ("The test was like kind of hard.", "The test was kind of hard."),
            ("I'm just like so tired of this.", "I'm just so tired of this."),
            ("It got like really cold last night.", "It got really cold last night."),
            ("That movie was like such a waste of time.", "That movie was such a waste of time."),
        ]
        for (input, expected) in cases { XCTAssertEqual(light(input), written(expected), input) }
    }

    /// From the Santa Barbara Corpus: before a verb, "like" is neither the verb nor a comparison.
    func testLightRemovesFillersBeforeAVerb() {
        let cases = [
            ("And we like made out at the lakefront.", "And we made out at the lakefront."),
            ("And so, which like made me think about it.", "And so, which made me think about it."),
            ("You'd have to like pay fifty bucks to go out.", "You'd have to pay fifty bucks to go out."),
            ("I was just like idolizing these guys.", "I was just idolizing these guys."),
            ("I'll be just like dropping it off.", "I'll be just dropping it off."),
        ]
        for (input, expected) in cases { XCTAssertEqual(light(input), written(expected), input) }
    }

    func testHesitationsAroundAFillerGoTogether() {
        XCTAssertEqual(light("Um, like, I think we should leave."), "I think we should leave.")
    }

    func testFillerSaidTwiceIsOneFiller() {
        XCTAssertEqual(light("It was, like, like, the best concert I've been to."), "It was the best concert I've been to.")
        XCTAssertEqual(light("It was like, like, the best concert."), "It was the best concert.")
    }

    func testANewSentenceKeepsItsCapital() {
        XCTAssertEqual(light("I got there late. Like, really late."), "I got there late. Really late.")
        XCTAssertEqual(light("We finally got there. Like."), "We finally got there.")
    }

    func testLightKeepsHedges() {
        for text in ["It took like five minutes to get there.", "And like we went home after that.", "She like goes there every day.",
                     "There were like a hundred people at the party.", "You know like the guy from the gym?"] {
            XCTAssertEqual(light(text), written(text))
        }
    }

    // MARK: Aggressive

    func testAggressiveAlsoRemovesHedges() {
        let cases = [
            ("It took like five minutes to get there.", "It took five minutes to get there."),
            ("There were like a hundred people at the party.", "There were a hundred people at the party."),
            ("I waited for like an hour.", "I waited for an hour."),
            ("I have like 20 tabs open right now.", "I have 20 tabs open right now."),
            ("We should leave at like 6.", "We should leave at 6."),
            ("It's like 2 in the morning.", "It's 2 in the morning."),
            ("She called like a dozen times.", "She called a dozen times."),
            ("And like we went home after that.", "And we went home after that."),
            ("So like I was thinking we could go tomorrow.", "So I was thinking we could go tomorrow."),
            ("But like nobody showed up.", "But nobody showed up."),
            ("Or like we could just stay home.", "Or we could just stay home."),
            ("I mean like it's not that deep.", "I mean it's not that deep."),
            ("Do you know like anyone here?", "Do you know anyone here?"),
            ("I said Norm, instead of like President Nixon?", "I said Norm, instead of President Nixon?"),
            ("You aren't burning much more than like eighteen hundred calories.",
             "You aren't burning much more than eighteen hundred calories."),
            ("Adults are supposed to be anywhere from like ninety-three on up.",
             "Adults are supposed to be anywhere from ninety-three on up."),
            ("He had auburn hair and he was like, six foot.", "He had auburn hair and he was six foot."),
            ("Yeah, like if you're approaching them, flick your brights.", "Yeah, if you're approaching them, flick your brights."),
            ("Since he like cancelled all this stuff, we stayed.", "Since he cancelled all this stuff, we stayed."),
            ("She like goes there every day.", "She goes there every day."),
        ]
        for (input, expected) in cases { XCTAssertEqual(aggressive(input), written(expected), input) }
    }

    /// From Switchboard: before a time, after "there's" and after "have" or "got", "like" cannot
    /// compare; at the start of a sentence before a clause it is a filler unless it is sarcasm.
    func testAggressiveRemovesWhatCannotBeASimile() {
        let cases = [
            ("It comes on like at nine o'clock.", "It comes on at nine o'clock."),
            ("I moved here like in late August.", "I moved here in late August."),
            ("We got really into it like during the Christmas season.", "We got really into it during the Christmas season."),
            ("There's like certain types of country I can't handle.", "There's certain types of country I can't handle."),
            ("She's got like just a small patch of lawn.", "She's got just a small patch of lawn."),
            ("They have like a three year waiting list.", "They have a three year waiting list."),
            ("Like we have peach trees in the yard.", "We have peach trees in the yard."),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(aggressive(input), written(expected), input)
            XCTAssertEqual(light(input), written(input), "light: \(input)")
        }
    }

    /// A stuttered "like like" loses only the copy; what is left is judged on its own.
    func testStutterKeepsOneLike() {
        XCTAssertEqual(aggressive("Like like you say, it can be a water ski."), "Like you say, it can be a water ski.")
        XCTAssertEqual(aggressive("I hope I never am like like everybody else."), "I hope I never am like everybody else.")
        XCTAssertEqual(light("And like like you know, nothing."), light("And like you know, nothing."))
        XCTAssertEqual(aggressive("Do you like like him?"), "Do you like like him?")
        XCTAssertEqual(light("It was like, like, the best."), "It was the best.")
        XCTAssertEqual(light("And like, like, we left."), "And we left.")
        // A verb followed by an example is not a stutter, whoever the subject is.
        for text in ["Stuff people like, like hiking and surfing.", "Foods the kids like, like pizza.",
                     "The music my parents like, like jazz."] {
            XCTAssertEqual(light(text), written(text))
            XCTAssertEqual(aggressive(text), text)
        }
    }

    // MARK: Meaning stays, at every level

    func testMeaningfulLikeStays() {
        let kept = [
            // The verb.
            "I like pizza.", "Do you like it?", "I would like a coffee please.", "I'd like two tickets, please.",
            "I like really spicy food.", "They like super long walks.", "My friends like really loud music.",
            "I don't like really loud places.", "I like five of them.", "I'll like your post later.",
            "Do you like like him?", "I'd like the biggest one, please.", "I like how much effort you put in.",
            // Comparisons and "as if".
            "It looks like rain.", "I feel like we should go.", "Life is like a box of chocolates.",
            "It was like a dream.", "He was like a brother to me.", "She's like her sister.",
            "It's like you never left.", "It's just like riding a bike.", "It's like that sometimes.",
            "It was like the last time we went.", "It's nothing like how long it used to take.",
            "She's like the best friend I never had.", "It seemed like a year.", "It felt like forever.",
            "People like us don't give up.", "Just like that, it was over.", "Something like that.",
            "What does it look like?", "It's like one of those days.", "Like father, like son.",
            // Quotes, sarcasm, "like I said", examples.
            "I was like, no way.", "And she was like, are you serious?", "I was like, so what?",
            "She was like really?", "My mom was like, go to bed.", "Like I said, the meeting is at noon.",
            "And like I said, we're fine.", "Like I care.", "Like what?", "Like who cares?",
            "Things I like, like pizza and pasta.", "Cities like Paris are expensive.",
            "And like a fool, I believed him.", "And like everyone else, I signed up.",
            "Like most people, I hate Mondays.", "Like.",
        ]
        for text in kept {
            XCTAssertEqual(light(text), text, "light: \(text)")
            XCTAssertEqual(aggressive(text), text, "aggressive: \(text)")
        }
    }

    /// Each of these was removed by an earlier draft, found by running novels and dialogue through it.
    func testRealTextThatAnEarlierDraftGotWrong() {
        let kept = [
            "They are nice people and like such things.",             // the verb after "and"
            "They knocked their heads together till they cracked like a couple of nuts.",
            "I felt mean and like I couldn't look her in the face.",  // "as if", after "felt"
            "Like they hadn't ever expected it and then like they had.",
            "Lots of activities too, you know, like fencing or theater or something.",  // examples
            "Still and Sunday—like.",                                  // a dash compound
            "Sure, just push the button, like ...",                    // trailing into "like this"
            "All I'm trying to say is that life is like ... er ... this painting.",
            "I could see myself lecturing and, like, oh honey, by the way.",          // a quote
            "All also, you know, like the dolphins, they metabolize the water.",     // an example
            "Oh, just as you like, said she.",
            "Yes, I would like make a reservation for tomorrow.",                     // "to" was lost
            "The spring sunshine streamed in like a benediction.",                    // a phrasal verb
            "You two caught on like a house on fire.",
            "Don't go on like this.", "He turned to the crowd and says, about like this.",
            "I'm after things to stuff dumplings with, like Chinese cabbage.",
            "We got to dig in like all get out.",
            "Does she like it?", "What's he like normally?", "Would he like some water?",  // questions
            "This company needs someone like you.", "You can't be torn to pieces by somebody like that.",
            // From Switchboard, removed by an earlier draft.
            "What's the weather like in winter?", "Can you see what his schedule is like on Wednesday?",
            "There's always like I say a moral to it.", "Like we do here.", "Like she used to be.",
            "Like I'd ever do that.", "Like it matters.", "Like I'm gonna do that.",
            "He's probably like a lot of quarterbacks.", "I'm like a lot of other people now.",
            "You know like the conservation corps.", "Well like I was saying, it's fine.",
            "Because like we we said earlier, it's fine.", "Yeah like you would when you're up north.",
            "It costs several hundred dollars, like, tires for the car.", "Like, Queen's Reich, if you ever heard of them.",
            "Just like in the movies.", "It's like in the old days.",
        ]
        for text in kept {
            XCTAssertEqual(aggressive(text), TextStyle.formal.apply(text), text)
        }
    }

    // MARK: Aggressive on real dictation (November 16)

    /// The casual keyboard insert with Aggressive, as Zayd's phone runs it.
    private func inserted(_ raw: String, _ mode: CaliforniaMode = .aggressive) -> String {
        TextStyle.casual.insertion(of: raw, contextBefore: "", fieldCapitalizesSentences: true, california: mode)
    }

    /// Zayd's own test dictations from November 16, as the recognizer wrote them. On the rules
    /// before, Aggressive removed one "like" in all five. The "like"s he talks about ("say something
    /// like like", "or like is a big one", "saying like but") and "something like that" and "seems
    /// like" stay.
    func testZaydsDictationsOnAggressive() {
        let cases = [
            ("California mode so like and if I say something like like too much",
             "California mode so and if I say something like like too much"),
            ("California mode, so like for instance, wouldn't you say that word too much? Like, um you know how like sometimes there's a Pokemon card and",
             "California mode so for instance wouldn't you say that word too much? You know how sometimes there's a pokemon card and"),
            ("I was like really tired.", "I was really tired"),
            ("Maybe there wasn't enough of this in the prompt, but Or like maybe it didn't look through enough of like teenage girls speak or something like that, but especially or like is a big one. And I see that's being picked up.",
             "Maybe there wasn't enough of this in the prompt but or maybe it didn't look through enough of teenage girls speak or something like that but especially or like is a big one. And I see that's being picked up"),
            ("Yeah, like especially if I have to I mean I'm still saying like but especially if I have to insert because I was out of the window and I wanted to click insert on the text um definitely not seeing any unsure thing pop up. So it seems like all of these settings aren't really shit like tested. within like together or maybe in the whole system, they don't seem to really be working. Especially like California mode was my number one trial.",
             "Yeah especially if I have to I mean I'm still saying like but especially if I have to insert because I was out of the window and I wanted to click insert on the text definitely not seeing any unsure thing pop up. So it seems like all of these settings aren't really shit tested. within together or maybe in the whole system they don't seem to really be working. Especially California mode was my number 1 trial"),
            // Sent the same day.
            ("There's a ton of like tiny personal agents that have all the extra stuff stripped out.",
             "There's a ton of tiny personal agents that have all the extra stuff stripped out"),
            ("Like I said like in this transcript I just transcribed earlier", "Like I said in this transcript I just transcribed earlier"),
            ("and it's like embarrassing", "And it's embarrassing"),
            ("Same I just keep saying like and none of it's filtering out", "Same I just keep saying like and none of it's filtering out"),
        ]
        for (raw, expected) in cases { XCTAssertEqual(inserted(raw), expected, raw) }
    }

    /// A "like" opening a sentence keeps the sentence's capital on the next real word, past an
    /// "um" that is removed after it.
    func testTheCapitalSkipsAHesitation() {
        XCTAssertEqual(inserted("That's too much? Like, um you know how it goes.", .light), "That's too much? You know how it goes")
        XCTAssertEqual(light("That's it. Like, uh we should go."), "That's it. We should go.")
    }

    /// The loose fillers from a labeled set of Zayd's dictations (written here as paraphrases):
    /// Aggressive removes every "like" that nothing protects.
    func testAggressiveRemovesLooseFillers() {
        let cases = [
            ("Or like maybe we could try it.", "Or maybe we could try it."),
            ("You know how like sometimes it breaks.", "You know how sometimes it breaks."),
            ("It just didn't read enough of like teen slang.", "It just didn't read enough of teen slang."),
            ("It should work within like the whole app.", "It should work within the whole app."),
            ("Especially like the keyboard was my first try.", "Especially the keyboard was my first try."),
            ("Turn off the like stuff showing up in the middle.", "Turn off the stuff showing up in the middle."),
            ("The button can like prime the mic.", "The button can prime the mic."),
            ("I'm like paranoid about it.", "I'm paranoid about it."),
            ("This loading screen is like whatever.", "This loading screen is whatever."),
            ("There should be like an enter key too.", "There should be an enter key too."),
            ("Wait, is there like a meeting mode?", "Wait, is there a meeting mode?"),
            ("Give them like a one-liner each.", "Give them a one-liner each."),
            ("It's better in terms of like speed.", "It's better in terms of speed."),
            ("It goes to the l- like my left ear.", "It goes to the l- my left ear."),
            ("Can I like drop off the prints?", "Can I drop off the prints?"),
            ("The settings aren't really like tested.", "The settings aren't really tested."),
            ("It's like sketchy.", "It's sketchy."),
            ("I mean like soon.", "I mean soon."),
            ("You should get like deeper blacks.", "You should get deeper blacks."),
        ]
        for (input, expected) in cases { XCTAssertEqual(aggressive(input), written(expected), input) }
    }

    /// Light also takes the loose fillers between small words, never a hedge before an amount.
    func testLightRemovesFillersBetweenSmallWords() {
        let cases = [
            ("So like for instance, it broke.", "So for instance, it broke."),
            ("But like right now it works.", "But right now it works."),
            ("Yeah, like especially at night.", "Yeah, especially at night."),
            ("Especially like the keyboard.", "Especially the keyboard."),
            ("I'm like paranoid about it.", "I'm paranoid about it."),
        ]
        for (input, expected) in cases { XCTAssertEqual(light(input), written(expected), input) }
        for text in ["And like for an hour we waited.", "It comes on like at nine o'clock."] {
            XCTAssertEqual(light(text), written(text), text)
        }
    }

    /// What the new Aggressive rules first removed in novels and DailyDialog, each now protected.
    func testAggressiveKeepsWhatTheLooseRulesMustNotTouch() {
        let kept = [
            // The verb, with its subject or auxiliary further back.
            "I would also like some sweet and sour sauce.", "Girls usually like looking after pets.",
            "I do not particularly like your way of getting husbands.", "You certainly do like teasing me.",
            "I want people to like you.", "I've grown to like second-hand things.", "That's a good reason to like something.",
            "Would you like go with me?", "I agree, but I like wire frames.", "I myself like very much to listen.",
            "I never did like it anyway.", "Girls are quiet and like to play nurse.",
            // Comparisons and examples.
            "What will the weather be like tomorrow?", "What is it like living on campus?",
            "Like most students.", "Like this one?", "Can I get my hair done like his?",
            "This office has become like a second home to me.", "You can't just light up like before.",
            "She could work like three women in one.", "Take it like a man.", "Thinking how like an Italian he looked.",
            "Did she act in a like manner?", "The others flew about like gauzy butterflies.",
            "The windows loomed like dark, shapeless blurs.", "They slept like dead people.",
            "She cheered like mad.", "It's like living in a nest of doves.", "It's like riding a bike.",
            "You know like Dahmer?", "He's like keep trying.", "She was like really.",
            "Like a VPS but for phones.", "Like the cost center.", "There's an enter key on the right, like a return key.",
            "Like that immortal hero, she rested awhile.", "Like sunshine after a storm were the weeks that followed.",
            "Whether it is like or not.", "Should be like the other side.", "More like fine details.",
            "Who do you like more?", "Like you said, it's too late.", "There's always like I say a moral to it.",
        ]
        for text in kept { XCTAssertEqual(aggressive(text), written(text), text) }
    }

    // MARK: Where it runs

    func testEveryStyleUsesIt() {
        XCTAssertEqual(TextStyle.casual.apply("It was, like, so good.", california: .light), "It was so good")
        XCTAssertEqual(TextStyle.veryCasual.apply("Like, I was like really tired.", california: .light), "i was really tired")
        XCTAssertEqual(TextStyle.excited.apply("It was like so good.", california: .light), "It was so good!")
    }

    /// A dictation that continues a sentence is judged by the words before the cursor.
    func testContinuingASentenceReadsTheWordsBeforeTheCursor() {
        XCTAssertEqual(TextStyle.casual.insertion(of: "like really tired", contextBefore: "I was",
                                                  fieldCapitalizesSentences: true, california: .light),
                       " really tired")
        XCTAssertEqual(TextStyle.casual.insertion(of: "like really spicy food", contextBefore: "I",
                                                  fieldCapitalizesSentences: true, california: .aggressive),
                       " like really spicy food")
    }

    func testLiteralsAndPersonalWordsAreNeverTouched() {
        XCTAssertEqual(light("It was like really good, see example.com/like for more."),
                       "It was really good, see example.com/like for more.")
        XCTAssertEqual(TextStyle.formal.apply("It was Like Totally playing tonight.", personalWords: ["Like Totally"],
                                              california: .aggressive),
                       "It was Like Totally playing tonight.")
    }

    func testOtherWordsAreNeverChanged() {
        // Only "like" is ever removed: the rest of the dictation matches Off word for word.
        let text = "So like I was like, no way, and it was, like, so good but like I like pizza at like 6."
        let off = TextStyle.casual.apply(text).split(separator: " ").filter { $0.lowercased() != "like" && $0.lowercased() != "like," }
        for level in [CaliforniaMode.light, .aggressive] {
            let words = TextStyle.casual.apply(text, california: level).split(separator: " ")
                .filter { $0.lowercased() != "like" && $0.lowercased() != "like," }
            XCTAssertEqual(words.map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() },
                           off.map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }, level.rawValue)
        }
    }
}
