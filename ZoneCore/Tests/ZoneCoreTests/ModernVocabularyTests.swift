// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class ModernVocabularyTests: XCTestCase {
    private func casual(_ said: String, personalWords: [String] = []) -> String {
        TextStyle.casual.apply(said, personalWords: personalWords)
    }

    private func formal(_ said: String) -> String { TextStyle.formal.apply(said) }

    /// The spellings the recognizer writes for these names in dictation. Formal writes each the
    /// company's way.
    func testFormalWritesCurrentNamesTheStandardWay() {
        XCTAssertEqual(formal("to send to their clawed code shortly"), "To send to their Claude Code shortly.")
        XCTAssertEqual(formal("how to go to Cloud Code and a"), "How to go to Claude Code and a")
        XCTAssertEqual(formal("I told her to get him clawed"), "I told her to get him Claude.")
        XCTAssertEqual(formal("I'm pretty sure a clawed agent or something"), "I'm pretty sure a Claude agent or something.")
        XCTAssertEqual(formal("I asked clad about it"), "I asked Claude about it.")
        XCTAssertEqual(formal("with thank God for claude you can do"), "With thank God for Claude you can do.")
        XCTAssertEqual(formal("Finish that anthropic essay and apply."), "Finish that Anthropic essay and apply.")
        XCTAssertEqual(formal("most up-to-date version on test flight so that"), "Most up-to-date version on TestFlight so that.")
        XCTAssertEqual(formal("Read the chat GPT stuff."), "Read the ChatGPT stuff.")
        XCTAssertEqual(formal("Anthropic and open AI paved the way"), "Anthropic and OpenAI paved the way.")
        XCTAssertEqual(formal("the VPN which is tail scale and it routes"), "The VPN which is Tailscale and it routes.")
        XCTAssertEqual(formal("are running a local quen"), "Are running a local Qwen.")
        XCTAssertEqual(formal("you to Apple and Whisper flow than money."), "You to Apple and Wispr Flow than money.")
        XCTAssertEqual(formal("the solidworks api is out there"), "The SolidWorks API is out there.")
        XCTAssertEqual(formal("claude's answer and two llms"), "Claude's answer and two LLMs.")
        XCTAssertEqual(formal("Auto correct had a bug. it doesn't auto correct"), "Autocorrect had a bug. It doesn't autocorrect.")
        XCTAssertEqual(TextStyle.excited.apply("i use deep seek and chat GPT"), "I use DeepSeek and ChatGPT!")
    }

    /// Casual is texting: the name is spelled right and takes no capital, unless it opens a
    /// sentence. Acronyms and names that start lowercase keep their casing.
    func testCasualSpellsNamesRightInLowercase() {
        XCTAssertEqual(casual("to send to their clawed code shortly"), "To send to their claude code shortly")
        XCTAssertEqual(casual("I asked clad about it"), "I asked claude about it")
        XCTAssertEqual(casual("I use OpenAI and deep seek and Chat GPT on test flight"), "I use openai and deepseek and chatgpt on testflight")
        XCTAssertEqual(casual("Read the chat GPT stuff. open AI made it"), "Read the chatgpt stuff. OpenAI made it")
        XCTAssertEqual(casual("claude's answer and two llms"), "Claude's answer and two LLMs")
        XCTAssertEqual(casual("the solidworks api on my iphone"), "The solidworks API on my iPhone")
        XCTAssertEqual(casual("I looked on Google and Reddit"), "I looked on google and reddit")
        XCTAssertEqual(TextStyle.veryCasual.apply("I asked Clawed Code and open AI"), "i asked claude code and openai")
        XCTAssertEqual(casual("ask Reddit", personalWords: ["Reddit"]), "Ask Reddit")
    }

    func testOrdinaryEnglishIsLeftAlone() {
        for said in ["The cat clawed at the door", "She clawed her way back", "A knight clad in armor", "It's an iron clad rule",
                     "Move the cursor to the cloud", "I'm at a low whisper",
                     "That's the notion of slack time", "Zoom in on the stripe", "I read it on the way",
                     "The test went well and the flight was late", "I message him every day"] {
            XCTAssertEqual(casual(said), said)
        }
        XCTAssertEqual(formal("We use Google Cloud Code here"), "We use Google Cloud Code here.")
    }

    func testThePersonsOwnSpellingWins() {
        XCTAssertEqual(casual("ask clawed about it", personalWords: ["Clawed"]), "Ask Clawed about it")
        XCTAssertEqual(casual("the quen build", personalWords: ["Quen"]), "The Quen build")
    }

    func testLiteralsKeepTheirSpelling() {
        XCTAssertEqual(casual("see github.com/anthropic and @openai"), "See github.com/anthropic and @openai")
    }

    func testListIsWellFormed() throws {
        let list = try XCTUnwrap(WordList.shared)
        XCTAssertGreaterThan(ModernVocabulary.entries.count, 150)
        XCTAssertEqual(Set(ModernVocabulary.entries.map { $0.word.lowercased() }).count, ModernVocabulary.entries.count, "duplicate entry")
        var forms = Set<String>()
        for entry in ModernVocabulary.entries {
            // A respelling of an everyday word ("colour", "cookin") is ranked 40,000 so that swipe
            // never prefers it to the standard word.
            XCTAssertTrue((1...40_000).contains(entry.rank), entry.word)
            for form in entry.heard {
                XCTAssertTrue(forms.insert(form).inserted || form == entry.word.lowercased(), "\(form) is listed twice")
                // A spoken form must not be an ordinary word of its own, or dictation would rewrite prose.
                if !form.contains(" "), form != entry.word.lowercased(), let found = list.lookup(form) {
                    XCTFail("\(form) for \(entry.word) is the dictionary word \(found.display)")
                }
            }
        }
        // The keyboard only takes a name over an ordinary word where the list says so.
        XCTAssertEqual(ModernVocabulary.forcedNames["google"], "Google")
        XCTAssertNil(ModernVocabulary.names["cursor"])
    }

    func testTapAutocorrectKeepsTheWordsAndCapitalizesTheNames() throws {
        let corrector = Autocorrector(words: try XCTUnwrap(WordList.shared))
        for word in ["chatbot", "repo", "agentic", "pickleball", "doomscrolling", "Reddit", "TikTok", "ChatGPT"] {
            XCTAssertNil(corrector.evaluate(word).replacement, word)
            XCTAssertTrue(corrector.recognizes(word), word)
        }
        XCTAssertEqual(corrector.evaluate("reddit").replacement, "Reddit")
        XCTAssertEqual(corrector.evaluate("chatgpt").replacement, "ChatGPT")
        XCTAssertEqual(corrector.evaluate("google").replacement, "Google")
        XCTAssertEqual(corrector.evaluate("tiktok").replacement, "TikTok")
        XCTAssertNil(corrector.evaluate("reddit", preserveLowercase: true).replacement)
        corrector.setPersonalWords(["reddit"])
        XCTAssertNil(corrector.evaluate("reddit").replacement)
    }

    func testSwipeWritesTheWordsInTheirCasing() throws {
        let layout = SwipeLayout.qwerty()
        func path(_ word: String) -> [SwipePoint] {
            let keys = word.lowercased().utf8.filter { (97...122).contains($0) }.map { Int($0 - 97) }
            var result: [SwipePoint] = []
            for (a, b) in zip(keys, keys.dropFirst()) where a != b {
                for j in 0..<12 {
                    let t = Float(j) / 12
                    result.append(SwipePoint(x: layout.x[a] + t * (layout.x[b] - layout.x[a]),
                                            y: layout.y[a] + t * (layout.y[b] - layout.y[a]), t: Float(result.count) / 60))
                }
            }
            result.append(SwipePoint(x: layout.x[keys.last!], y: layout.y[keys.last!], t: Float(result.count) / 60))
            return result
        }
        var tuning = SwipeTuning(); tuning.visitRadius = 0; tuning.shortlist = 160
        let decoder = SwipeDecoder(words: try XCTUnwrap(WordList.shared), tuning: tuning)
        let neural = try XCTUnwrap(SwipeNeuralScorer())
        var missed: [String] = []
        for (word, _) in ModernVocabulary.swipeWords where Set(word.lowercased()).count >= 3 {
            let points = path(word)
            let ranked = neural.rank(decoder.decode(points, layout: layout, limit: 96), points: points, layout: layout)
            if !ranked.prefix(3).contains(where: { $0.word == word }) { missed.append("\(word): \(ranked.prefix(3).map(\.word))") }
        }
        XCTAssertLessThanOrEqual(missed.count, ModernVocabulary.swipeWords.count / 20, "\(missed)")
        // The everyday words they resemble still come first.
        for word in ["read", "great", "good", "clause", "over", "list", "apple", "repeat", "config", "table"] {
            let points = path(word)
            let ranked = neural.rank(decoder.decode(points, layout: layout, limit: 96), points: points, layout: layout)
            XCTAssertEqual(ranked.first?.word.lowercased(), word, "\(word): \(ranked.prefix(3).map(\.word))")
        }
    }
}
