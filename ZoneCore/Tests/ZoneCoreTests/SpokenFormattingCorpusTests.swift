// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// Dictation phrasing corpus: input as a speech recognizer writes it (Apple Speech, Parakeet and
/// Moonshine capitalize and punctuate, often around the command words themselves), expected
/// output per style. Every mismatch is reported with its row's line, so one run lists them all.
///
/// Decisions pinned here:
/// - A spoken mark replaces the recognizer's own mark next to it ("Hey, comma," is one comma).
/// - After a spoken comma, semicolon or colon the next word continues the sentence: a capital
///   comes down on a word that is never a name ("Then", "and"), or on any ordinary word when the
///   recognizer had ended a sentence there ("semicolon. Then"). Names and "I" keep theirs.
/// - After a spoken period, question mark or exclamation mark the next word is capitalized in
///   every style except very casual.
/// - Texting acronyms (wtf, lmao, lol, omg, idk, tbh) are lowercase in casual and very casual;
///   formal and excited keep the recognizer's spelling. "etc" is lowercase in every style.
/// - Only um, uh and ah (and drawn-out umm, uhh) are removed; "like", "uh huh", "uh oh" stay.
/// - Self-corrections ("no wait", "scratch that") are left as said: removing words is a Beta
///   setting, off unless the person turns it on. These rows pin the default; `SpokenRepairTests`
///   has the cases with the setting on.
/// - URLs, emails and bare domains come back byte for byte.
final class SpokenFormattingCorpusTests: XCTestCase {
    private struct Row {
        let input: String
        let casual: String
        let veryCasual: String
        let formal: String
        let excited: String
        let words: [String]
        let line: UInt

        func expected(_ style: TextStyle) -> String {
            switch style {
            case .casual: return casual
            case .veryCasual: return veryCasual
            case .formal: return formal
            case .excited: return excited
            }
        }
    }

    private static let personal = ["Zayd", "Snakebyte", "Dahlsson"]

    private static func r(_ input: String, _ casual: String, _ veryCasual: String, _ formal: String, _ excited: String,
                          words: [String] = personal, line: UInt = #line) -> Row {
        Row(input: input, casual: casual, veryCasual: veryCasual, formal: formal, excited: excited, words: words, line: line)
    }

    /// Prose whose casual form is `casual`, very casual its lowercase, formal and excited add
    /// their ending. Only for rows without acronyms, literals or explicit end marks.
    private static func prose(_ input: String, _ casual: String, line: UInt = #line) -> Row {
        r(input, casual, casual.lowercased(), casual + ".", casual + "!", line: line)
    }

    /// The same text in every style except very casual, which is lowercase.
    private static func fixed(_ input: String, _ output: String, line: UInt = #line) -> Row {
        r(input, output, output.lowercased(), output, output, line: line)
    }

    private static let rows: [Row] = [
        // MARK: Comma
        prose("Hey comma how are you", "Hey, how are you"),
        prose("Hey, comma, how are you.", "Hey, how are you"),
        fixed("Hey, comma. How are you?", "Hey, how are you?"),
        prose("Okay. Comma. So then what.", "Okay, so then what"),
        fixed("Hello, comma, world period.", "Hello, world."),
        r("Hey Zayd comma how are you", "Hey Zayd, how are you", "hey Zayd, how are you",
          "Hey Zayd, how are you.", "Hey Zayd, how are you!"),
        r("Hey, comma, John, comma, how are you.", "Hey, John, how are you", "hey, john, how are you",
          "Hey, John, how are you.", "Hey, John, how are you!"),
        // A capital that is not a sentence guess stays: it may be a name.
        r("Hello comma World.", "Hello, World", "hello, world", "Hello, World.", "Hello, World!"),
        prose("And then comma we left", "And then, we left"),
        prose("Wait comma And then we left.", "Wait, and then we left"),
        fixed("Insert comma", ","),
        r("hello insert comma world full stop", "Hello, world.", "hello, world.", "Hello, world.", "Hello, world."),
        prose("I think comma I can go", "I think, I can go"),

        // MARK: Period, question mark, exclamation mark
        fixed("Yes, period.", "Yes."),
        fixed("I said no. Period.", "I said no."),
        fixed("Hello period how are you question mark", "Hello. How are you?"),
        fixed("Hello. Period. How are you? Question mark.", "Hello. How are you?"),
        r("Hello full stop how are you", "Hello. How are you", "hello. how are you", "Hello. How are you.", "Hello. How are you!"),
        r("Wait question mark, what happened.", "Wait? What happened", "wait? what happened",
          "Wait? What happened.", "Wait? What happened!"),
        r("Wow exclamation point that is great", "Wow! That is great", "wow! that is great",
          "Wow! That is great.", "Wow! That is great!"),
        r("Wow, exclamation mark. That is great.", "Wow! That is great", "wow! that is great",
          "Wow! That is great.", "Wow! That is great!"),
        fixed("Wait comma what? Question mark.", "Wait, what?"),
        fixed("Seriously question mark exclamation point", "Seriously?!"),
        fixed("Question mark?", "?"),
        r("Done period new line next", "Done.\nNext", "done.\nnext", "Done.\nNext.", "Done.\nNext!"),
        // Noun senses of "period" stay words.
        prose("It lasted a short period.", "It lasted a short period"),
        prose("We studied the Jurassic period.", "We studied the Jurassic period"),

        // MARK: Colon
        prose("Note colon bring snacks", "Note: bring snacks"),
        prose("Note, colon. Bring snacks.", "Note: bring snacks"),
        prose("Dear Sam colon thanks", "Dear Sam: thanks"),
        prose("Use a colon here.", "Use a colon here"),
        prose("I have colon cancer screening.", "I have colon cancer screening"),

        // MARK: Semicolon and its spellings
        prose("I went home semicolon then I slept.", "I went home; then I slept"),
        prose("I went home, semicolon. Then I slept.", "I went home; then I slept"),
        prose("I went home. Semicolon. Then I slept.", "I went home; then I slept"),
        prose("I went home, semi colon, Then I slept.", "I went home; then I slept"),
        prose("I went home semi-colon Then I slept.", "I went home; then I slept"),
        prose("I went home, semi-colon, then I slept.", "I went home; then I slept"),
        prose("I went home, insert semicolon, Then I slept.", "I went home; then I slept"),
        prose("I went home insert semi colon then I slept", "I went home; then I slept"),
        prose("I went home semicolon, Then I slept.", "I went home; then I slept"),
        prose("I went home Semi colon then I slept", "I went home; then I slept"),
        prose("It works semicola then it fails", "It works; then it fails"),
        prose("It's late semicolon And I'm tired.", "It's late; and I'm tired"),
        fixed("Semicolon.", ";"),
        fixed("Semi colon", ";"),
        r("semicolon then I slept", "; then I slept", "; then i slept", "; then I slept.", "; then I slept!"),
        r("Semicolon. Then I slept.", "; then I slept", "; then i slept", "; then I slept.", "; then I slept!"),
        r("We met Zayd semicolon Zayd left.", "We met Zayd; Zayd left", "we met Zayd; Zayd left",
          "We met Zayd; Zayd left.", "We met Zayd; Zayd left!"),
        prose("The semicolon separates clauses.", "The semicolon separates clauses"),
        prose("Type literal semicolon here", "Type semicolon here"),

        // MARK: Quotes
        r("He said open quote I'm done close quote and left.", "He said \"I'm done\" and left",
          "he said \"i'm done\" and left", "He said \"I'm done\" and left.", "He said \"I'm done\" and left!"),
        r("He said quote I'm done unquote and left.", "He said \"I'm done\" and left",
          "he said \"i'm done\" and left", "He said \"I'm done\" and left.", "He said \"I'm done\" and left!"),
        // Casual reads the comma run as a list and keeps the comma before the quote.
        r("He said, quote, I'm done, end quote, and left.", "He said, \"I'm done\" and left",
          "he said \"i'm done\" and left", "He said, \"I'm done\" and left.", "He said, \"I'm done\" and left!"),
        // A closing delimiter at the end is explicit punctuation: no style adds a mark after it.
        fixed("She texted quote on my way unquote.", "She texted \"on my way\""),
        prose("Get a quote.", "Get a quote"),
        prose("The word quote is in the report.", "The word quote is in the report"),

        // MARK: Parentheses
        prose("Call me open parenthesis maybe close parenthesis tomorrow.", "Call me (maybe) tomorrow"),
        prose("Call me, open parenthesis, maybe, close parenthesis, tomorrow.", "Call me (maybe) tomorrow"),
        fixed("Open parentheses, hello, close parentheses.", "(hello)"),

        // MARK: New line, new paragraph
        prose("First line new line second line", "First line\nsecond line"),
        prose("First line, new line, Second line.", "First line\nSecond line"),
        prose("First line. New line. Second line.", "First line.\nSecond line"),
        prose("Intro new paragraph body", "Intro\n\nbody"),
        prose("Intro. New paragraph. Body text.", "Intro.\n\nBody text"),
        prose("Dear Sam comma new line thanks for coming", "Dear Sam,\nthanks for coming"),
        fixed("New paragraph.", "\n\n"),

        // MARK: Lists
        prose("Groceries colon bullet point milk next bullet eggs next bullet bread",
              "Groceries:\n• milk\n• eggs\n• bread"),
        // A recognizer period inside a list item is kept (it may end a sentence in the item).
        prose("Bullet point milk. Next bullet eggs.", "• milk.\n• eggs"),
        prose("Start numbered list wake up next item code next item sleep", "1. wake up\n2. code\n3. sleep"),
        prose("Start numbered list, wake up, next item, code. End list. Done.", "1. wake up\n2. code.\nDone"),
        prose("Bullet trains are fast.", "Bullet trains are fast"),
        prose("The next item is ready.", "The next item is ready"),

        // MARK: Numbers as recognizers write them
        prose("I have 3 kids and 2 dogs.", "I have 3 kids and 2 dogs"),
        r("It costs $5.99 at 3:30 PM.", "It costs $5.99 at 3:30 pm", "it costs $5.99 at 3:30 pm",
          "It costs $5.99 at 3:30 PM.", "It costs $5.99 at 3:30 PM!"),
        r("I ran 10K in 45 minutes, on November 1, 2026.", "I ran 10K in 45 minutes on November 1, 2026",
          "i ran 10k in 45 minutes on november 1 2026", "I ran 10K in 45 minutes, on November 1, 2026.",
          "I ran 10K in 45 minutes, on November 1, 2026!"),
        r("The rate is 12.5%, version 2.1.3.", "The rate is 12.5% version 2.1.3", "the rate is 12.5% version 2.1.3",
          "The rate is 12.5%, version 2.1.3.", "The rate is 12.5%, version 2.1.3!"),
        prose("Call 555-123-4567.", "Call 555-123-4567"),
        prose("We raised $1,000,000 this year.", "We raised $1,000,000 this year"),
        r("Meet at 9:00 a.m. tomorrow.", "Meet at 9:00 am tomorrow", "meet at 9:00 am tomorrow",
          "Meet at 9:00 a.m. tomorrow.", "Meet at 9:00 a.m. tomorrow!"),
        prose("It's 3 to 5 days.", "It's 3 to 5 days"),

        // MARK: Emails, URLs and domains stay byte for byte
        r("Email me at jane.doe@acme.com.", "Email me at jane.doe@acme.com", "email me at jane.doe@acme.com",
          "Email me at jane.doe@acme.com.", "Email me at jane.doe@acme.com!"),
        r("Email me at Jane.Doe@Acme.com, thanks.", "Email me at Jane.Doe@Acme.com thanks",
          "email me at Jane.Doe@Acme.com thanks", "Email me at Jane.Doe@Acme.com, thanks.",
          "Email me at Jane.Doe@Acme.com, thanks!"),
        r("Check https://Example.com/Path?Q=A.", "Check https://Example.com/Path?Q=A", "check https://Example.com/Path?Q=A",
          "Check https://Example.com/Path?Q=A.", "Check https://Example.com/Path?Q=A!"),
        r("Go to www.Example.com/Docs.", "Go to www.Example.com/Docs", "go to www.Example.com/Docs",
          "Go to www.Example.com/Docs.", "Go to www.Example.com/Docs!"),
        r("My site is zayd.wtf.", "My site is zayd.wtf", "my site is zayd.wtf", "My site is zayd.wtf.", "My site is zayd.wtf!"),
        r("Visit GitHub.com/ZaydK today.", "Visit GitHub.com/ZaydK today", "visit GitHub.com/ZaydK today",
          "Visit GitHub.com/ZaydK today.", "Visit GitHub.com/ZaydK today!"),
        r("Send it to a.b@x.co comma please.", "Send it to a.b@x.co, please", "send it to a.b@x.co, please",
          "Send it to a.b@x.co, please.", "Send it to a.b@x.co, please!"),
        r("jane.doe@acme.com is my email", "jane.doe@acme.com is my email", "jane.doe@acme.com is my email",
          "jane.doe@acme.com is my email.", "jane.doe@acme.com is my email!"),
        r("Link period https://example.com/A", "Link. https://example.com/A", "link. https://example.com/A",
          "Link. https://example.com/A", "Link. https://example.com/A"),

        // MARK: Texting acronyms
        r("WTF was that.", "wtf was that", "wtf was that", "WTF was that.", "WTF was that!"),
        r("LMAO that's hilarious.", "lmao that's hilarious", "lmao that's hilarious",
          "LMAO that's hilarious.", "LMAO that's hilarious!"),
        r("LOL, okay.", "lol okay", "lol okay", "LOL, okay.", "LOL, okay!"),
        r("OMG, I can't believe it.", "omg I can't believe it", "omg i can't believe it",
          "OMG, I can't believe it.", "OMG, I can't believe it!"),
        // Recognizer "IDK" is spoken "I don't know" (main, 685f6ef): the words, in every style.
        r("IDK what you mean.", "I don't know what you mean", "i don't know what you mean",
          "I don't know what you mean.", "I don't know what you mean!"),
        r("TBH, I don't care, LOL.", "tbh I don't care lol", "tbh i don't care lol",
          "TBH, I don't care, LOL.", "TBH, I don't care, LOL!"),
        r("That's so funny LMAO.", "That's so funny lmao", "that's so funny lmao",
          "That's so funny LMAO.", "That's so funny LMAO!"),
        r("Lol that's wild.", "lol that's wild", "lol that's wild", "Lol that's wild.", "Lol that's wild!"),
        r("Did you see that, WTF.", "Did you see that wtf", "did you see that wtf",
          "Did you see that, WTF.", "Did you see that, WTF!"),
        r("I work at NASA LOL.", "I work at NASA lol", "i work at nasa lol", "I work at NASA LOL.", "I work at NASA LOL!"),
        r("BRB, getting food.", "brb getting food", "brb getting food", "BRB, getting food.", "BRB, getting food!"),
        r("OMG comma IDK.", "omg, I don't know", "omg, i don't know", "OMG, I don't know.", "OMG, I don't know!"),
        r("OK, sounds good.", "OK sounds good", "ok sounds good", "OK, sounds good.", "OK, sounds good!"),

        // MARK: etc
        r("Bring snacks, drinks, etc.", "Bring snacks, drinks, etc", "bring snacks drinks etc",
          "Bring snacks, drinks, etc.", "Bring snacks, drinks, etc!"),
        r("Bring snacks, drinks, ETC.", "Bring snacks, drinks, etc", "bring snacks drinks etc",
          "Bring snacks, drinks, etc.", "Bring snacks, drinks, etc!"),
        r("Chairs, tables, Etc. are here.", "Chairs, tables, etc. are here", "chairs tables etc are here",
          "Chairs, tables, etc. are here.", "Chairs, tables, etc. are here!"),

        // MARK: Fillers
        prose("Um, I think, uh, we should go.", "I think we should go"),
        prose("Ah, I see.", "I see"),
        prose("So, uh, yeah.", "So yeah"),
        prose("Umm, let me think.", "Let me think"),
        r("I'm like, so tired.", "I'm like so tired", "i'm like so tired", "I'm like, so tired.", "I'm like, so tired!"),
        prose("It was like 5 bucks.", "It was like 5 bucks"),
        prose("Uh huh.", "Uh huh"),
        r("Uh-huh, sounds good.", "Uh-huh sounds good", "uh-huh sounds good", "Uh-huh, sounds good.", "Uh-huh, sounds good!"),
        r("Uh oh, we're late.", "Uh oh we're late", "uh oh we're late", "Uh oh, we're late.", "Uh oh, we're late!"),
        prose("The umbrella is ahead.", "The umbrella is ahead"),
        fixed("Um.", ""),

        // MARK: Self-corrections are left as said (the Beta setting is off)
        r("I'll be there at 5, no wait, 6.", "I'll be there at 5 no wait 6", "i'll be there at 5 no wait 6",
          "I'll be there at 5, no wait, 6.", "I'll be there at 5, no wait, 6!"),
        r("Let's meet Tuesday, scratch that, Wednesday.", "Let's meet Tuesday, scratch that, Wednesday",
          "let's meet tuesday scratch that wednesday", "Let's meet Tuesday, scratch that, Wednesday.",
          "Let's meet Tuesday, scratch that, Wednesday!"),
        r("Actually, I mean, Friday.", "Actually I mean, Friday", "actually i mean friday",
          "Actually, I mean, Friday.", "Actually, I mean, Friday!"),

        // MARK: Sentence endings and casing
        fixed("How are you?", "How are you?"),
        prose("Are you coming", "Are you coming"),
        fixed("I can't wait!", "I can't wait!"),
        prose("It's fine.", "It's fine"),
        r("That's great. See you soon.", "That's great. See you soon", "that's great see you soon",
          "That's great. See you soon.", "That's great! See you soon!"),
        prose("Okay.", "Okay"),
        prose("yes", "Yes"),
        fixed("Wait...", "Wait..."),
        r("the NASA API is down", "The NASA API is down", "the nasa api is down", "The NASA API is down.", "The NASA API is down!"),
        r("I use iOS and macOS.", "I use iOS and macOS", "i use iOS and macOS", "I use iOS and macOS.", "I use iOS and macOS!"),

        // MARK: Personal words
        r("Talk to Zade about it.", "Talk to Zayd about it", "talk to Zayd about it",
          "Talk to Zayd about it.", "Talk to Zayd about it!"),
        r("I use Snakebite daily.", "I use Snakebyte daily", "i use Snakebyte daily",
          "I use Snakebyte daily.", "I use Snakebyte daily!"),
        r("Z A Y D is here", "Zayd is here", "Zayd is here", "Zayd is here.", "Zayd is here!"),
        r("I asked Dahlson, comma. Zayd said yes.", "I asked Dahlsson, Zayd said yes", "i asked Dahlsson, Zayd said yes",
          "I asked Dahlsson, Zayd said yes.", "I asked Dahlsson, Zayd said yes!"),
    ]

    private struct Insertion {
        let style: TextStyle
        let input: String
        let context: String?
        let capitalizes: Bool
        let expected: String
        let line: UInt
    }

    private static func i(_ style: TextStyle, _ input: String, after context: String?, caps: Bool = true,
                          _ expected: String, line: UInt = #line) -> Insertion {
        Insertion(style: style, input: input, context: context, capitalizes: caps, expected: expected, line: line)
    }

    private static let insertions: [Insertion] = [
        i(.casual, "And then we left.", after: "We ate", " and then we left"),
        i(.formal, "And then we left.", after: "It was late", " and then we left."),
        i(.formal, "Then we left.", after: "Done. ", "Then we left."),
        i(.casual, "then we left.", after: "Done. ", caps: false, "then we left"),
        i(.veryCasual, "Hello there.", after: "Done. ", "hello there"),
        i(.casual, "LOL, that's wild.", after: "I saw it", " lol that's wild"),
        i(.excited, "We won.", after: "", "We won!"),
        // A dictionary name keeps its capital mid-sentence.
        i(.formal, "Paris was great.", after: "and then", " Paris was great."),
        i(.formal, "Monday works.", after: "I think", " Monday works."),
        i(.formal, "Zayd said yes.", after: "and then", " Zayd said yes."),
        // A spoken mark that opens a continuation is a command, not a mention.
        i(.formal, "Period.", after: "I said no", "."),
        i(.casual, "Question mark.", after: "Are you coming", "?"),
        i(.casual, "Comma, see you.", after: "Thanks", ", see you"),
        i(.formal, "Comma. And then we left.", after: "We ate", ", and then we left."),
        i(.casual, "Semicolon. Then I slept.", after: "I went home", "; then I slept"),
        i(.casual, "Semi colon then I slept", after: "I went home", "; then I slept"),
        i(.formal, "Colon, milk and eggs.", after: "Buy", ": milk and eggs."),
        // At a sentence start the punctuation word is still a mention.
        i(.formal, "Comma placement matters.", after: "Done. ", "Comma placement matters."),
        i(.casual, "New line. Next part.", after: "First part", "\nNext part"),
        i(.casual, "Bullet point milk next bullet eggs", after: "List", "\n• milk\n• eggs"),
        i(.casual, "My email is jane.doe@acme.com.", after: "Hey", " my email is jane.doe@acme.com"),
        i(.casual, "https://example.com/A", after: "Link: ", "https://example.com/A"),
        i(.casual, "um, okay.", after: "Sure", " okay"),
        i(.casual, "WTF, really?", after: "", "wtf really?"),
    ]

    func testRecognizerPhrasingCorpus() {
        var failures: [String] = []
        for row in Self.rows {
            for style in TextStyle.allCases {
                let got = style.apply(row.input, personalWords: row.words)
                let want = row.expected(style)
                if got != want {
                    failures.append("line \(row.line) \(style): \(row.input.debugDescription) got \(got.debugDescription) want \(want.debugDescription)")
                }
            }
        }
        for item in Self.insertions {
            let got = item.style.insertion(of: item.input, contextBefore: item.context,
                                           fieldCapitalizesSentences: item.capitalizes, personalWords: Self.personal)
            if got != item.expected {
                failures.append("line \(item.line) \(item.style) after \(String(describing: item.context).debugDescription): \(item.input.debugDescription) got \(got.debugDescription) want \(item.expected.debugDescription)")
            }
        }
        XCTAssertGreaterThanOrEqual(Self.rows.count + Self.insertions.count, 80)
        XCTAssert(failures.isEmpty, "\(failures.count) corpus failures:\n" + failures.joined(separator: "\n"))
    }
}
