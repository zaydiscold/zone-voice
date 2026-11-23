// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// Regressions from the spoken-handle evaluation (`docs/evidence/2026-11-06-spoken-handles.md`).
/// Most inputs are what Fluid Speech Mini wrote for synthetic speech, punctuation and all, so the
/// table holds the behavior measured there; the evaluation itself is `scripts/handle-eval`.
final class SpokenMentionTests: XCTestCase {
    private func on(_ text: String, _ style: TextStyle = .casual, words: [String] = [], handles: [String] = []) -> String {
        style.apply(text, personalWords: words, mentions: true, handles: handles)
    }

    func testRecognizedTagsBecomeHandles() {
        let cases: [(String, String)] = [
            ("At Kevin, what do you think?", "@kevin what do you think?"),
            ("Hey at Dan, can you check this?", "Hey @dan can you check this?"),
            ("CC at Lena and at Omar.", "CC @lena and @omar"),
            ("At Kevin, at Dan, the meeting moved to 3.", "@kevin @dan the meeting moved to 3"),
            ("Good game at Chris.", "Good game @chris"),
            ("Wait at Noah, really?", "Wait @noah really?"),
            ("I think At Jordan knows the answer.", "I think @jordan knows the answer"),
            ("Shout out to At Marcus for the help.", "Shout out to @marcus for the help"),
            ("At Madison. Did you see the clip?", "@madison. Did you see the clip?"),
            ("At Chase, you still playing?", "@chase you still playing?"),
            ("At Kofi, the server is down.", "@kofi the server is down"),
            ("at Nick when you are done.", "@nick when you are done"),
            ("At Kevin, I need you on this.", "@kevin I need you on this"),
            ("At Max, what's up?", "@max what's up?"),
        ]
        for (heard, written) in cases { XCTAssertEqual(on(heard), written, heard) }
    }

    func testSpelledAndRepeatedNamesBecomeOneHandle() {
        let cases: [(String, String)] = [
            ("At D A A N, are you there?", "@daan are you there?"),
            ("at D-A-A-N are you there", "@daan are you there"),
            ("At KENJI, nice work.", "@kenji nice work"),
            ("At K E NJI, nice work.", "@kenji nice work"),
            ("at K E N J I nice work", "@kenji nice work"),
            ("at D A A N I think so", "@daan I think so"),
            // Said, then spelled; spelled, then said. The spelling wins.
            ("At Dan, D-A-A-N, are you there?", "@daan, are you there?"),
            ("At D A A N, Don, are you there?", "@daan, Don are you there?"),
            ("at Dan D A A N are you there", "@daan are you there"),
        ]
        for (heard, written) in cases { XCTAssertEqual(on(heard), written, heard) }
    }

    func testMisheardAtBeforeAFirstName() {
        XCTAssertEqual(on("CC Ad Lena and Ad Omar."), "CC @lena and @omar")
        XCTAssertEqual(on("Sorry Ad Ethan, my bad."), "Sorry @ethan my bad")
        XCTAssertEqual(on("Shout out to Admarcus for the help."), "Shout out to @marcus for the help")
        XCTAssertEqual(on("Did Athanna see this?"), "Did @hanna see this?")
        // Real words and real names stay.
        for sentence in ["Add Mike to the server.", "Aunt Emily is visiting.", "Adam said hi.", "Adrian is coming too.",
                         "The ad Kevin made was funny.", "Okay Admin, your turn.", "We flew to Atlanta.", "And Kevin said no."] {
            XCTAssertFalse(on(sentence).contains("@"), sentence)
        }
    }

    func testNamesAfterTheirOwnWordsAndPlaces() {
        for sentence in [
            "Look at Kevin go.", "I was mad at Dan yesterday.", "Stop laughing at Kevin.", "Throw it at Josh.",
            "Throw the ball at Liam.", "Look right at Kevin.", "Don't get mad at Max.", "He's always mad at Hunter.",
            "She works at Google now.", "I'll grab coffee at Starbucks.", "My account at Chase is locked.",
            "I'm at Chase right now.", "We arrive at Austin by noon.", "The game is at Lincoln.",
            "We booked a table at Rosa.", "The concert at Phoenix was sold out.", "She's at Georgia Tech.",
            "The concert at Madison Square Garden was loud.", "She was born at Mercy Hospital.",
            "I'm at Kevin's place.", "Drop it off at Grace's.", "At Kevin's request we moved it.",
            "See you at Starbucks.", "We met at Stanford.", "she studied at MIT", "We landed at JFK.",
            "At least it works.", "At Christmas we visit family.", "We'll get there at dawn.", "At will employment.",
            "Set it at max.", "Leave it at that.", "Not at all.", "Look at sign language.", "I'll call you at five.",
        ] {
            XCTAssertFalse(on(sentence).contains("@"), sentence)
        }
    }

    func testOffChangesNothingButTheExplicitAtSign() {
        for sentence in ["At Kevin, what do you think?", "CC Ad Lena and Ad Omar.", "At D A A N, are you there?", "Did Athanna see this?"] {
            for style in TextStyle.allCases {
                XCTAssertFalse(style.apply(sentence).contains("@"), sentence)
            }
        }
        XCTAssertEqual(TextStyle.casual.apply("At sign Kevin, hi."), "@kevin hi")
        XCTAssertEqual(TextStyle.casual.apply("at symbol kevin123 hi"), "@kevin123 hi")
        XCTAssertEqual(TextStyle.casual.apply("at sign here hi"), "@here hi")
        XCTAssertEqual(TextStyle.casual.apply("Type the at sign key"), "Type the at sign key")
    }

    func testHandleKeepsItsCaseInEveryStyleAndAtTheCursor() {
        XCTAssertEqual(on("at Kevin did you see this", .formal), "@kevin did you see this.")
        XCTAssertEqual(on("at Kevin did you see this", .excited), "@kevin did you see this!")
        XCTAssertEqual(on("At Kevin, did you see this?", .veryCasual), "@kevin did you see this?")
        XCTAssertEqual(on("Okay. At Kevin, go.", .formal), "Okay. @kevin, go.")
        XCTAssertEqual(TextStyle.formal.insertion(of: "at Kevin look", contextBefore: "Done.", fieldCapitalizesSentences: true,
                                                  mentions: true), " @kevin look.")
        XCTAssertEqual(TextStyle.casual.insertion(of: "And at Dan too", contextBefore: "thanks", fieldCapitalizesSentences: true,
                                                  mentions: true), " and @dan too")
    }

    func testPersonalWordsAndCommandsAroundAHandle() {
        XCTAssertEqual(on("At Zaid, look at this."), "@zayd look at this")
        XCTAssertEqual(on("at snakebyte gg", words: ["Snakebyte"]), "@snakebyte gg")
        XCTAssertEqual(on("at Daan are you there"), "At Daan are you there")
        XCTAssertEqual(on("at Daan are you there", words: ["Daan"]), "@daan are you there")
        XCTAssertEqual(on("At Ryan, comma, check this, new line, thanks."), "@ryan, check this\nthanks")
        XCTAssertEqual(on("quote at Kevin unquote"), "\"@kevin\"")
        XCTAssertEqual(on("mail kevin@example.com at Kevin"), "Mail kevin@example.com @kevin")
    }

    func testThePersonsOwnHandlesTagEvenWhenTheyAreWords() {
        let mine = ["cold", "snakebyte", "everyone", "will", "x_9"]
        let cases: [(String, String)] = [
            ("At cold, what do you think?", "@cold what do you think?"),
            ("hey at cold can you check this", "Hey @cold can you check this"),
            ("Thanks at cold.", "Thanks @cold"),
            ("At cold.", "@cold"),
            ("GG at cold, at Dan.", "gg @cold @dan"),
            ("at snake byte you on", "@snakebyte you on"),
            ("At Snakebyte, nice clip.", "@snakebyte nice clip"),
            ("At sign everyone, please read this.", "@everyone please read this"),
            ("at X 9 you up", "@x_9 you up"),
            ("At will, are you coming?", "@will are you coming?"),
        ]
        for (heard, written) in cases { XCTAssertEqual(on(heard, handles: mine), written, heard) }
        for sentence in [
            "It's cold at night.", "Served at cold temperatures.", "Leave it at cold.", "Wash it at cold.",
            "I'm good at cold calls.", "At will employment.", "We stopped at Cold Stone.", "Look at everyone.",
            "Mad at everyone, honestly.", "Throw it at cold water.", "She works at Snakebyte.",
        ] {
            XCTAssertFalse(on(sentence, handles: mine).contains("@"), sentence)
        }
        // Without the handle, "at cold" is two words; with the setting off, a handle needs "at sign".
        XCTAssertEqual(on("at cold what's up"), "At cold what's up")
        XCTAssertFalse(TextStyle.casual.apply("At cold, what's up?", handles: mine).contains("@"))
        XCTAssertEqual(TextStyle.casual.apply("at sign snake byte gg", handles: mine), "@snakebyte gg")
    }

    func testHandleIntentTrapsAndExplicitSpelling() {
        let mine = ["cold", "will", "txm", "zade", "snakebyte", "everyone", "here"]
        for text in ["You can leave at will", "Hired at will", "At will employment",
                     "Throwing at zade", "Throwing at T X M", "Look at txm", "He got bit at snakebyte camp",
                     "We interviewed at Kevin", "At everyone please read", "At here we wait",
                     "at E V E R Y O N E please read", "at spelling E V E R Y O N E please read"] {
            for style in TextStyle.allCases {
                XCTAssertFalse(on(text, style, handles: mine).contains("@"), text)
            }
        }
        for (text, handle) in [("at txm hi", "@txm"), ("at T X M hi", "@txm"),
                               ("at T-X-M hi", "@txm"), ("at zade hi", "@zade"),
                               ("at Z A D E hi", "@zade"), ("at sign everyone hi", "@everyone"),
                               ("at sign here hi", "@here")] {
            for style in TextStyle.allCases {
                XCTAssertTrue(on(text, style, handles: mine).contains(handle), text)
            }
        }
        // An alias shared by two accounts must not select one based on list order.
        for handles in [["snake_byte", "snake.byte"], ["snake.byte", "snake_byte"]] {
            XCTAssertFalse(on("at snake byte hi", handles: handles).contains("@"))
            // Literal identifiers remain protected by TextStyle; spell them to dictate a tag.
            XCTAssertEqual(on("at snake_byte hi", handles: handles), "At snake_byte hi")
        }
        XCTAssertEqual(on("at snakebyte hi", handles: ["snakebyte", "snake_byte"]), "@snakebyte hi")
        XCTAssertFalse(on("at cold temperatures", words: ["cold"]).contains("@"))
        XCTAssertFalse(on("at Will employment").contains("@"))
        // Saving the literal spelling must prevent built-in Zade -> Zayd rewriting in mentions.
        XCTAssertEqual(on("at zade hi", handles: ["zade"]), "@zade hi")
    }

    func testSayingAtSignTeachesAHandle() {
        XCTAssertEqual(PersonalVocabulary.handles(taughtIn: "At sign cold, what's up?"), ["cold"])
        XCTAssertEqual(on("At sign cold, what's up?"), "@cold what's up?")
        XCTAssertEqual(PersonalVocabulary.handles(taughtIn: "at sign D A A N are you there"), ["daan"])
        XCTAssertEqual(PersonalVocabulary.handles(taughtIn: "at sign snakebyte and at sign cold"), ["snakebyte", "cold"])
        // Names and the person's words tag already; phrases teach nothing.
        for sentence in ["At sign Kevin, hi.", "Look at sign language.", "Type the at sign key", "At sign up, enter your email.",
                         "At Kevin, hi.", "Good at sign language."] {
            XCTAssertEqual(PersonalVocabulary.handles(taughtIn: sentence), [], sentence)
        }
        XCTAssertEqual(PersonalVocabulary.handles(taughtIn: "at sign Daan hi", personalWords: ["Daan"]), [])
        XCTAssertEqual(PersonalVocabulary.handles(taughtIn: "at sign snake byte hi", knownHandles: ["snakebyte"]), ["snakebyte"])
    }

    func testSpelledLettersAreExactAndDoNotEatFollowingWords() {
        let cases = [
            ("at d-a-a-n hi", "@daan hi"),
            ("at d a a n hi", "@daan hi"),
            ("at D A A N AND at Kevin", "@daan AND @kevin"),
            ("At D-A-A-N AT D-A-A-N AT D-A-A-N", "@daan @daan @daan"),
            ("at J E F F GO", "@jeff GO"),
            ("at A N N A OK", "@anna OK"),
            ("at Q Y Z I hello", "@qyzi hello"),
            ("at D A A N I think so", "@daan I think so"),
            ("at D A A N Dana says hello", "@daan Dana says hello"),
        ]
        for (input, expected) in cases { XCTAssertEqual(on(input), expected, input) }
        // Every letter wins over shorter saved handles and over the spoken name before it.
        XCTAssertEqual(on("at D A A N hi", handles: ["da", "dan"]), "@daan hi")
        XCTAssertEqual(on("at Dan D A A N hi", handles: ["dan"]), "@daan hi")
        // No invented letter: DAN is not a request to write DAAN.
        XCTAssertEqual(on("at D A N hi"), "@dan hi")
        XCTAssertEqual(on("at DAN hi"), "@dan hi")
        // A mixed chunk that is also a word is uncertain. Do not emit a partial/wrong handle.
        XCTAssertFalse(on("At D AN.").contains("@"))
        XCTAssertFalse(on("At sign D AN.").contains("@"))
        for input in ["throw it at d-a-a-n", "look at d a a n", "at a b testing",
                      "look at spelling mistakes", "good at spelling bees", "at spelling bee"] {
            XCTAssertFalse(on(input).contains("@"), input)
        }
    }

    func testSpellingMatrixAcrossStylesAndRepeatedLetters() {
        for name in ["daan", "dan", "anna", "jeff", "lloyd", "txm", "qyzi", "xyzzy"] {
            for separator in [" ", "-"] {
                for spelling in [name, name.uppercased()] {
                    let spoken = spelling.map(String.init).joined(separator: separator)
                    for style in TextStyle.allCases {
                        let result = on("at " + spoken + " please review", style)
                        XCTAssertTrue(result.hasPrefix("@" + name + " "), result)
                        XCTAssertTrue(result.contains("please review"), result)
                        XCTAssertFalse(on("throwing at " + spoken, style).contains("@"))
                    }
                }
            }
        }
        let long = Array(repeating: "Z", count: 33).joined(separator: " ")
        XCTAssertFalse(on("at " + long).contains("@"), "Do not truncate a spelling into a different account")
        XCTAssertFalse(on("at sign " + long).contains("@"))
    }

    /// Everyday sentences where "at" is where something happens, found by the November 8 review.
    func testWhereSomethingHappensStaysProse() {
        for sentence in [
            "Grab it at Chase on the way", "Pick them up at Austin tomorrow", "Drop her at Madison on the way",
            "I'll see him at Grace on Sunday", "I left my jacket at Ashley", "I stayed up late at Kevin and then left",
            "I'll wait for you at Lincoln", "They're playing at Jackson tonight", "Thanks for having me at Kevin",
            "I'm going to be late at Mike", "I'm impressed at Kevin", "I'm proud at Kevin", "Email me at Jordan",
            "I forgot my keys at Tyler", "We saw your brother at Austin", "Bring them back at Noah",
        ] {
            XCTAssertFalse(on(sentence).contains("@"), sentence)
        }
        // Addressing someone still tags: at the start, after a greeting or thanks, after a preposition.
        let cases: [(String, String)] = [
            ("Thank you at Kevin", "Thank you @kevin"),
            ("Thanks a lot at Sarah", "Thanks a lot @sarah"),
            ("Happy birthday at Kevin", "Happy birthday @kevin"),
            ("Good morning at Kevin, you up?", "Good morning @kevin you up?"),
            ("Love you at Mia", "Love you @mia"),
            ("Send it to at Kevin", "Send it to @kevin"),
        ]
        for (heard, written) in cases { XCTAssertEqual(on(heard), written, heard) }
    }

    func testAccentedNamesTagAsTheStoreSavesThem() {
        XCTAssertEqual(on("At José, see this"), "@jose see this")
        XCTAssertEqual(on("at Zoë what's up"), "@zoe what's up")
        XCTAssertEqual(on("At sign José see this"), "@jose see this")
        XCTAssertEqual(TextStyle.casual.apply("at sign Zoë hi"), "@zoe hi")
        XCTAssertEqual(PersonalVocabulary.normalizedHandles(["José"]), ["jose"])
        XCTAssertFalse(on("I'm at José's place").contains("@"))
    }

    /// Fluid Speech hears a spelled "D A A N" as "D A N", "DAN" or "D AN" (3 of 4 synthetic clips).
    /// Once Daan is saved, a spelling one doubled letter short is that handle. A said "Dan" is not.
    func testSpellingThatLostADoubledLetterFindsTheSavedHandle() {
        let mine = ["daan", "lloyd"]
        let cases: [(String, String)] = [
            ("at D A N can you check", "@daan can you check"),
            ("At DAN, can you check?", "@daan can you check?"),
            ("At D AN, are you there?", "@daan are you there?"),
            ("at d-a-n review this", "@daan review this"),
            ("at sign D A N hi", "@daan hi"),
            ("At Dan, D A N, are you there?", "@daan, are you there?"),
            ("at L O Y D hi", "@lloyd hi"),
            ("at D A A N hi", "@daan hi"),
        ]
        for (heard, written) in cases { XCTAssertEqual(on(heard, handles: mine), written, heard) }
        // A said name is not a spelling; nothing saved, nothing recovered; both saved, exact wins.
        XCTAssertEqual(on("at Dan can you check", handles: mine), "@dan can you check")
        XCTAssertEqual(on("at D A N can you check"), "@dan can you check")
        XCTAssertEqual(on("at D A N hi", handles: ["daan", "dan"]), "@dan hi")
        // Two saved handles that collapse alike: no guess.
        XCTAssertEqual(on("at D A N hi", handles: ["daan", "dann"]), "@dan hi")
        XCTAssertFalse(on("look at D A N", handles: mine).contains("@"))
    }

    func testSavedHandlesAreBounded() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("words.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = PersonalVocabulary(fileURL: url)
        try store.addHandles((0..<(PersonalVocabulary.maxHandles + 50)).map { "user\($0)" })
        let saved = try store.handles()
        XCTAssertEqual(saved.count, PersonalVocabulary.maxHandles)
        // The newest survive; teaching the oldest again keeps it through the next addition.
        XCTAssertEqual(saved.last, "user\(PersonalVocabulary.maxHandles + 49)")
        XCTAssertEqual(saved.first, "user50")
        try store.addHandles(["user50"])
        try store.addHandles(["newcomer"])
        let after = try store.handles()
        XCTAssertTrue(after.contains("user50"))
        XCTAssertFalse(after.contains("user51"))
        XCTAssertEqual(after.count, PersonalVocabulary.maxHandles)
    }

    /// How Fluid Speech Mini actually wrote "at sign" before a spelled handle (scripts/handle-eval).
    func testMisheardAtSignBeforeCapitalsStillTags() {
        for style in TextStyle.allCases {
            for mentions in [true, false] {
                for (heard, handle) in [("Absign ANNA.", "@anna"), ("Add sine ANNA.", "@anna"), ("At signs ZAD.", "@zad"),
                                        ("At Sign TXM.", "@txm"), ("Absign JEFF", "@jeff"), ("add sign D A A N hi", "@daan")] {
                    XCTAssertTrue(style.apply(heard, mentions: mentions).hasPrefix(handle), "\(heard) \(style)")
                }
            }
        }
        // Lowercase after the misheard words is English, not a spelling.
        for sentence in ["Add sign ups to the list", "The sine wave at signs of trouble", "It was signed by Kevin",
                         "Add sine curves", "absign test"] {
            XCTAssertFalse(on(sentence).contains("@"), sentence)
            XCTAssertFalse(TextStyle.casual.apply(sentence).contains("@"), sentence)
        }
    }

    /// The recognizer can drop "at" altogether (4 of 24 bare clips). Smart @ recovers only a saved
    /// handle spelled in capitals at the start of a sentence.
    func testSavedHandleSpelledWithoutItsAt() {
        let mine = ["daan", "txm", "anna"]
        let cases: [(String, String)] = [
            ("D-A-A-N.", "@daan"), ("TXM.", "@txm"), ("ANNA", "@anna"), ("DAN", "@daan"),
            ("It's signed D A N.", "@daan"), ("Sign TXM", "@txm"), ("That ANNA", "@anna"),
            ("Okay. TXM can you check", "Okay. @txm can you check"),
        ]
        for (heard, written) in cases { XCTAssertEqual(on(heard, handles: mine), written, heard) }
        for (sentence, handles) in [("TXM.", [String]()), ("Txm.", mine), ("The TXM build is out", mine),
                                    ("TXM builds are out", mine), ("ANNA", ["dan"]), ("It's signed by Anna", mine)] {
            XCTAssertFalse(on(sentence, handles: handles).contains("@"), sentence)
        }
        // Smart @ off: without "at sign", nothing is a tag.
        XCTAssertFalse(TextStyle.casual.apply("TXM.", handles: mine).contains("@"))
    }

    func testAtSignAlwaysUsesSavedHandlesAndKeepsFillerNames() {
        // Smart @ off still joins a saved handle the recognizer split, and keeps a saved Zade spelling.
        XCTAssertEqual(TextStyle.casual.apply("at sign snake byte gg", handles: ["snakebyte"]), "@snakebyte gg")
        XCTAssertEqual(TextStyle.casual.apply("at sign zade hi", handles: ["zade"]), "@zade hi")
        XCTAssertEqual(TextStyle.casual.apply("at sign D A N hi", handles: ["daan"]), "@daan hi")
        for style in TextStyle.allCases {
            XCTAssertTrue(style.apply("At sign um, what's up", mentions: true).hasPrefix("@um"), "\(style)")
        }
        XCTAssertEqual(on("so um at Kevin um hi"), "So @kevin hi")
    }

    /// A friend's question: meeting at a festival, "I'm at sign B".
    func testAtSignAsAPlaceStaysWords() {
        for sentence in ["I'm at sign B", "Meet me at sign B", "We'll be at sign 4", "I'm at sign 12 by the stage",
                         "At sign B, see you there", "Look at sign D A A N", "I'm at sign zayd", "Wait for me at sign C",
                         "We're standing at sign Kevin"] {
            for style in TextStyle.allCases {
                XCTAssertFalse(style.apply(sentence).contains("@"), "\(sentence) \(style)")
                XCTAssertFalse(style.apply(sentence, mentions: true).contains("@"), "\(sentence) \(style)")
            }
        }
        // A saved handle is still a tag there; addressing someone still is too.
        XCTAssertEqual(TextStyle.casual.apply("I'm at sign zayd", handles: ["zayd"]), "I'm @zayd")
        XCTAssertEqual(TextStyle.casual.apply("thanks at sign Kevin"), "Thanks @kevin")
        XCTAssertEqual(TextStyle.casual.apply("at sign B2 hi"), "@b2 hi")
        XCTAssertFalse(on("at sign 4 hi").contains("@"))
    }

    /// Findings of the November 8 adversarial review, each reproduced before the fix.
    func testBroadcastAndAcronymsNeverTagWithoutAt() {
        for (sentence, handles) in [("EVERYONE. Listen up", ["everyone", "here"]), ("HERE. Take it", ["here"]),
                                    ("That's EVERYONE", ["everyone"]), ("E V E R Y O N E", ["everyone"]),
                                    ("LOL. That was great", ["lol", "ok"]), ("OK. See you", ["ok"])] {
            XCTAssertFalse(on(sentence, handles: handles).contains("@"), sentence)
        }
    }

    func testSpokenMarksEndTheClauseBeforeAt() {
        XCTAssertEqual(on("Hi at Kevin new line at Sarah check this"), "Hi @kevin\n@sarah check this")
        XCTAssertTrue(TextStyle.casual.apply("hi new line at sign Sarah check this").contains("@sarah"))
        XCTAssertTrue(on("great job exclamation point at Sarah").contains("@sarah"))
        XCTAssertTrue(on("check this comma at Kevin").contains("@kevin"))
        // A mention ends the clause too: "and" after it is the start of the next.
        XCTAssertEqual(on("at sign cold at sign snakebyte gg", handles: ["cold"]), "@cold @snakebyte gg")
    }

    func testTalkingAboutTheAtSignTeachesNothing() {
        for sentence in ["type at sign followed by their name", "you need at sign before the name",
                         "Discord uses at sign mentions", "what does at sign mean", "at sign at Kevin hi", "at sign the"] {
            XCTAssertEqual(PersonalVocabulary.handles(taughtIn: sentence), [], sentence)
            XCTAssertFalse(TextStyle.casual.apply(sentence, mentions: true).contains("@followed"), sentence)
        }
        XCTAssertFalse(on("Discord uses at sign mentions").contains("@"))
        XCTAssertFalse(on("what does at sign mean").contains("@"))
        XCTAssertEqual(on("at sign at Kevin hi"), "At sign @kevin hi")
        // Addressing with an everyday word still tags and teaches.
        XCTAssertEqual(PersonalVocabulary.handles(taughtIn: "hey at sign cold what's up"), ["cold"])
        XCTAssertEqual(PersonalVocabulary.handles(taughtIn: "thanks at sign cold"), ["cold"])
    }

    func testTimesAndNumbersBeforeAPlace() {
        for sentence in ["Concert tonight at Madison", "Game tomorrow at Austin", "Flight lands Friday at Dallas",
                         "Sunday at Allen", "Pickup at 5 at Chase", "Class starts at 9 at Lincoln", "Doors open at 8 pm at Jackson"] {
            XCTAssertFalse(on(sentence).contains("@"), sentence)
        }
        XCTAssertEqual(on("Good morning at Kevin"), "Good morning @kevin")
    }

    func testTheSentenceAlreadyInTheFieldCounts() {
        for (context, heard) in [("I'm looking", "at Kevin"), ("Meet me", "at Kevin"), ("I'll be", "at sign Sarah")] {
            let written = TextStyle.casual.insertion(of: heard, contextBefore: context, fieldCapitalizesSentences: true, mentions: true)
            XCTAssertFalse(written.contains("@"), context + " " + heard)
        }
        // A finished sentence or a greeting before the cursor leaves addressing alone.
        XCTAssertTrue(TextStyle.casual.insertion(of: "at Kevin check this", contextBefore: "Done.",
                                                 fieldCapitalizesSentences: true, mentions: true).contains("@kevin"))
        XCTAssertTrue(TextStyle.casual.insertion(of: "at Kevin check this", contextBefore: "hey",
                                                 fieldCapitalizesSentences: true, mentions: true).contains("@kevin"))
    }

    func testFusedAtIsNotARealNameAsSubject() {
        for sentence in ["Atanas called", "Atrina called me", "Atalia said hi", "Adjani acts"] {
            XCTAssertFalse(on(sentence).contains("@"), sentence)
        }
        XCTAssertEqual(on("Admarcus, look at this"), "@marcus look at this")
        XCTAssertEqual(on("Did Athanna see this?"), "Did @hanna see this?")
    }

    /// "At sign everyone" always pings the channel, on or off; plain "at everyone" never does,
    /// and neither is saved to the handles list.
    func testBroadcastsNeedAtSignAndAreNotSaved() {
        for mentions in [false, true] {
            XCTAssertEqual(TextStyle.casual.apply("At sign everyone, game night is at 8.", mentions: mentions), "@everyone game night is at 8")
            XCTAssertEqual(TextStyle.casual.apply("At sign here, quick update.", mentions: mentions), "@here quick update")
            XCTAssertEqual(TextStyle.casual.apply("At everyone, game night is at 8.", mentions: mentions, handles: ["everyone"]),
                           "At everyone game night is at 8")
        }
        XCTAssertEqual(PersonalVocabulary.handles(taughtIn: "At sign everyone and at sign cold, hi."), ["cold"])
    }

    /// A saved rare name does not take over a common one: Daan in My words leaves Dawn alone.
    func testMyWordsDoNotRewriteACommonFirstName() {
        XCTAssertEqual(on("Tell Dawn I said hi.", words: ["Daan"]), "Tell Dawn I said hi")
        XCTAssertEqual(on("I met Dan and Dawn.", words: ["Daan"]), "I met Dan and Dawn")
        XCTAssertEqual(on("At sign Daan, you there?", words: ["Daan"]), "@daan you there?")
        XCTAssertEqual(on("I use Snakebite for that.", words: ["Snakebyte"]), "I use Snakebyte for that")
    }

    func testPreferenceDefaultsOnForOldRecordsAndOptOutRoundTrips() throws {
        let legacy = Data(#"{"autocorrectEnabled":true,"dictationFollowsShift":false}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(KeyboardPreferences.self, from: legacy).handleRecognition)
        let off = KeyboardPreferences(handleRecognition: false)
        XCTAssertFalse(try JSONDecoder().decode(KeyboardPreferences.self, from: JSONEncoder().encode(off)).handleRecognition)
        let wrong = Data(#"{"handleRecognition":"yes","hapticsEnabled":false}"#.utf8)
        let decoded = try JSONDecoder().decode(KeyboardPreferences.self, from: wrong)
        XCTAssertTrue(decoded.handleRecognition)
        XCTAssertFalse(decoded.hapticsEnabled)
    }
}
