// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// Randomized and adversarial input for every text style and the spoken-command pass.
/// Invariants: nothing crashes, no ordinary word is lost or invented, protected spans come back
/// byte for byte, plain prose is a fixed point after one pass, and each call stays fast.
final class TextStyleFuzzTests: XCTestCase {
    // MARK: Vocabulary

    /// Ordinary words that are neither spoken commands nor hesitation tokens.
    private static let prose = [
        "the", "a", "and", "so", "we", "I", "you", "it", "is", "was", "going", "to", "meet", "at", "noon",
        "tomorrow", "Paris", "France", "lunch", "coffee", "really", "think", "that", "this", "works", "for",
        "me", "they", "said", "don't", "it's", "I'm", "we'll", "okay", "yeah", "like", "well", "honestly",
        "project", "deadline", "Friday", "Monday", "build", "phone", "keyboard", "dictation", "zone", "fine",
        "lol", "tbh", "idk", "btw", "NASA", "iOS", "McDonald", "O'Brien", "x", "z", "nine", "twelve",
        "café", "nai\u{0308}ve", "東京", "会议", "مرحبا", "שלום", "Привет", "Ελλάδα", "İstanbul", "straße",
    ]
    /// Everything that can be (part of) a spoken command, filtered from both sides before comparing.
    private static let commandWords: Set<String> = [
        "comma", "period", "colon", "semicolon", "semi", "cola", "quote", "unquote", "open", "close", "begin", "end",
        "bullet", "point", "next", "item", "start", "numbered", "list", "new", "line", "paragraph", "insert", "full",
        "stop", "question", "mark", "exclamation", "parenthesis", "parentheses", "literal",
    ]
    private static let commandPhrases = [
        "comma", "period", "full stop", "question mark", "exclamation point", "new line", "new paragraph",
        "open quote", "close quote", "quote", "unquote", "end quote", "bullet point", "next bullet", "bullet",
        "start numbered list", "next item", "end list", "open parenthesis", "close parenthesis", "insert comma",
        "insert period", "insert semicolon", "semi-colon", "colon", "literal comma", "literal new line",
        "the comma", "a period", "grace period", "colon cancer", "oxford comma",
    ]
    private static let fillers = ["um", "uh", "ah", "Um", "UH"]
    private static let oddities = [
        "👍🏽", "🏳️‍🌈", "👨‍👩‍👧‍👦", "\u{200B}", "\u{200D}", "\u{FEFF}", "\u{202E}", "\u{2066}", "e\u{0301}\u{0301}",
        "...", "?!", "\u{2014}", "\"", "'", "(", ")", "[", "]", "{", "}", "«", "»", "“", "”", "‘", "’", "\t", "\n", "\r\n",
        ",", ";", ":", "!", "?", ".", "…", "\u{E000}", "\u{E001}", "\u{E002}", "\u{E003}", "0", "12", "3.14", "%",
    ]
    private static let literals = [
        "https://example.com/a?b=1&c=two#frag", "http://x.io/path_(with)_parens", "first.last+tag@example.co.uk",
        "`let x = a.b(c)`", "~/Desktop/notes.txt", "/usr/local/bin/tool", "1.2.3", "10.0.0.180", "camelCaseName",
        "iPhone", "snake_case_name", "zone://dictate?request=abc", "ftp://files.example.org/x.tar.gz",
    ]
    /// Personal words whose spelling is full of regex syntax; each must come out exactly as stored.
    private static let metaWords = ["C++", "a.b*c", "(foo)", "[x]", "$HOME", "\\d+", "x|y", "^caret", "Zayd?", "{n}", "Dahlsson", "Snakebyte"]

    // MARK: Helpers

    private static let wordExpression = try! NSRegularExpression(pattern: #"[\p{L}\p{M}]+(?:['’][\p{L}\p{M}]+)*"#)

    /// Case-folded words, in order; folding makes "ß" and its capital "SS" the same word.
    private static func words(_ text: String, dropping: Set<String> = []) -> [String] {
        let source = text as NSString
        return wordExpression.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap {
            let word = source.substring(with: $0.range).folding(options: [.caseInsensitive], locale: nil)
            return dropping.contains(word) ? nil : word
        }
    }

    private static let ignorable: Set<String> = commandWords.union(["um", "uh", "ah"])

    private func randomText(_ rng: inout StressRNG, tokens: Int, commands: Double, fillers: Double, oddities: Double) -> String {
        var parts: [String] = []
        for _ in 0..<tokens {
            let roll = Double.random(in: 0..<1, using: &rng)
            if roll < commands { parts.append(rng.pick(Self.commandPhrases)) }
            else if roll < commands + fillers { parts.append(rng.pick(Self.fillers)) }
            else if roll < commands + fillers + oddities { parts.append(rng.pick(Self.oddities)) }
            else {
                var word = rng.pick(Self.prose)
                if rng.chance(0.08) { word += rng.pick([",", ".", "?", "!"]) }
                parts.append(word)
            }
        }
        return parts.joined(separator: rng.chance(0.1) ? "  " : " ")
    }

    // MARK: Invariants

    func testRandomTranscriptsNeverLoseOrInventOrdinaryWords() {
        var rng = StressRNG(seed: 0x5EED_0001)
        let rounds = Stress.iterations(150, heavy: 6_000)
        for round in 0..<rounds {
            let text = randomText(&rng, tokens: rng.int(0...40), commands: 0.12, fillers: 0.06, oddities: 0.12)
            // The deliberate losses: an accidental doubled word ("I I", "to to") keeps one copy, and
            // a number said in words is written in digits ("twelve" is 12).
            for style in TextStyle.allCases {
                // The texting styles also write two to nine as digits.
                let expected = Self.words(SpokenNumbers.writingDigits(
                    SpokenRepair.collapsingStutters(text), small: style.writesSmallNumbersAsDigits ? .digits : .asSaid),
                    dropping: Self.ignorable)
                let out = style.apply(text)
                XCTAssertEqual(Self.words(out, dropping: Self.ignorable), expected,
                               "round \(round) \(style): \(text.debugDescription) -> \(out.debugDescription)")
                let inserted = style.insertion(of: text, contextBefore: rng.pick([nil, "", "Hi. ", "and then ", "line\n"]),
                                               fieldCapitalizesSentences: rng.chance(0.5))
                XCTAssertEqual(Self.words(inserted, dropping: Self.ignorable), expected,
                               "round \(round) \(style) insertion: \(text.debugDescription) -> \(inserted.debugDescription)")
            }
        }
    }

    func testFillersNeverSurviveOutsideProtectedSpans() {
        var rng = StressRNG(seed: 0x5EED_0002)
        for _ in 0..<Stress.iterations(100, heavy: 3_000) {
            let text = randomText(&rng, tokens: rng.int(1...30), commands: 0.05, fillers: 0.3, oddities: 0.05)
            for style in TextStyle.allCases {
                let out = style.apply(text)
                XCTAssertFalse(Self.words(out).contains(where: { ["um", "uh", "ah"].contains($0) }), "\(style): \(text) -> \(out)")
            }
        }
    }

    func testProtectedSpansComeBackByteForByte() {
        var rng = StressRNG(seed: 0x5EED_0003)
        for round in 0..<Stress.iterations(150, heavy: 4_000) {
            var parts: [String] = []
            var used: [String] = []
            for _ in 0..<rng.int(1...12) {
                if rng.chance(0.35) {
                    let literal = rng.pick(Self.literals)
                    used.append(literal)
                    parts.append(literal + (rng.chance(0.2) ? rng.pick([".", ",", "!"]) : ""))
                } else {
                    parts.append(rng.chance(0.25) ? rng.pick(Self.commandPhrases) : rng.pick(Self.prose))
                }
            }
            let text = parts.joined(separator: " ")
            for style in TextStyle.allCases {
                let out = style.apply(text, personalWords: rng.chance(0.3) ? ["Zayd", "Dahlsson"] : [])
                for literal in Set(used) {
                    XCTAssertEqual(out.components(separatedBy: literal).count, text.components(separatedBy: literal).count,
                                   "round \(round) \(style) lost \(literal): \(text) -> \(out)")
                }
                XCTAssertFalse(out.unicodeScalars.contains { (0xE000...0xE003).contains($0.value) && !text.unicodeScalars.contains($0) },
                               "a placeholder leaked: \(out.debugDescription)")
            }
        }
    }

    /// Placeholders are built so no later pass can read a word inside them. Before the fix they
    /// were hexadecimal UUIDs, so a personal word that sounds like a run such as "edd" or "bde"
    /// rewrote the middle of a placeholder and the URL or email it stood for was lost.
    func testPersonalWordsNeverReachInsideAPlaceholder() {
        let personal = ["Eddie", "Bede", "Abed", "Cade", "Fadi", "Dede", "Bebe", "Abba", "Faced", "Decaf"]
        let text = "mail first.last+tag@example.co.uk or open https://example.com/x and run `make`"
        for _ in 0..<Stress.iterations(500, heavy: 20_000) {
            let out = TextStyle.formal.apply(text, personalWords: personal)
            guard out.contains("first.last+tag@example.co.uk"), out.contains("https://example.com/x"), out.contains("`make`") else {
                return XCTFail("a literal was lost: \(out.debugDescription)")
            }
        }
    }

    func testPersonalWordsWithRegexSyntaxComeOutAsStored() {
        var rng = StressRNG(seed: 0x5EED_0004)
        for _ in 0..<Stress.iterations(150, heavy: 2_000) {
            let chosen = Array(Self.metaWords.shuffled(using: &rng).prefix(rng.int(1...Self.metaWords.count)))
            var parts: [String] = []
            for _ in 0..<rng.int(1...20) { parts.append(rng.chance(0.3) ? rng.pick(chosen) : rng.pick(Self.prose)) }
            let text = parts.joined(separator: " ")
            for style in TextStyle.allCases {
                let out = style.apply(text, personalWords: chosen)
                for word in chosen where text.contains(word) {
                    XCTAssertTrue(out.contains(word), "\(style) lost \(word): \(text) -> \(out)")
                }
            }
        }
    }

    func testPlainProseIsAFixedPointAfterOnePass() {
        var rng = StressRNG(seed: 0x5EED_0005)
        for round in 0..<Stress.iterations(150, heavy: 5_000) {
            let text = randomText(&rng, tokens: rng.int(1...30), commands: 0, fillers: 0.05, oddities: 0.05)
            for style in TextStyle.allCases {
                let once = style.apply(text)
                XCTAssertEqual(style.apply(once), once, "round \(round) \(style): \(text.debugDescription)")
            }
        }
    }

    // MARK: Adversarial shapes

    func testAdversarialShapesDoNotCrashAndKeepTheirWords() {
        let cases: [String] = [
            "", " ", "\n\n\n", ".", "...", "?!?!", String(repeating: ",", count: 500), String(repeating: ". ", count: 300),
            String(repeating: "comma ", count: 400), String(repeating: "period period ", count: 200),
            String(repeating: "quote ", count: 101), String(repeating: "open quote ", count: 50) + String(repeating: "close quote ", count: 60),
            String(repeating: "bullet point one next bullet ", count: 80), String(repeating: "start numbered list a next item b end list ", count: 40),
            String(repeating: "new line ", count: 300), String(repeating: "um ", count: 500), String(repeating: "uh, ", count: 300),
            String(repeating: "literal literal ", count: 100), String(repeating: "spell z a y d ", count: 50),
            "open parenthesis open parenthesis close parenthesis", String(repeating: "\"nested 'quotes' (and [brackets])\" ", count: 50),
            String(repeating: "\u{E000}", count: 2_000), String(repeating: "\u{E002}0\u{E003}", count: 200),
            String(repeating: "\u{0301}", count: 1_000), String(repeating: "👨‍👩‍👧‍👦", count: 500), String(repeating: "\u{200B}", count: 3_000),
            String(repeating: "@", count: 1_000), String(repeating: "a.", count: 1_000), String(repeating: "x://", count: 500),
            String(repeating: "`", count: 999), String(repeating: "```", count: 333), String(repeating: "/a", count: 2_000),
            String(repeating: "1.", count: 2_000), String(repeating: "aB", count: 2_000), String(repeating: "a_", count: 2_000),
            String(repeating: "a", count: 20_000) + "@", String(repeating: "a.b+", count: 4_000),
        ]
        for text in cases {
            for style in TextStyle.allCases {
                var out = ""
                let seconds = Stress.time { out = style.apply(text, personalWords: ["Zayd", "C++"]) }
                XCTAssertLessThan(seconds, 2, "\(style) took \(seconds) s on \(text.prefix(40).debugDescription)")
                // "spell z a y d" collapses into one word by design.
                let spelled: Set<String> = text.contains("spell") ? ["spell", "zayd", "z", "a", "y", "d"] : []
                let kept = Self.words(out, dropping: Self.ignorable.union(spelled))
                let expected = Self.words(text, dropping: Self.ignorable.union(spelled))
                XCTAssertEqual(kept, expected, "\(style) on \(text.prefix(60).debugDescription)")
            }
        }
    }

    // MARK: Performance

    /// A long dictation (about 50,000 characters, roughly an hour of speech) in one call.
    func testFiftyThousandCharactersStayWithinTheBound() {
        var rng = StressRNG(seed: 0x5EED_0006)
        var text = ""
        while text.utf16.count < 50_000 {
            text += randomText(&rng, tokens: 40, commands: 0.04, fillers: 0.04, oddities: 0.04) + ". "
        }
        text += " https://example.com/end"
        for style in TextStyle.allCases {
            var out = ""
            let seconds = Stress.time { out = style.apply(text, personalWords: ["Zayd", "Dahlsson", "Snakebyte"]) }
            XCTAssertLessThan(seconds, 1.5, "\(style) took \(seconds) s for 50k characters")
            XCTAssertTrue(out.contains("https://example.com/end"))
        }
    }

    /// The usual dictation: a sentence or two. The keyboard waits on this, so it must be quick.
    func testTypicalDictationIsWellUnderTenMilliseconds() {
        var rng = StressRNG(seed: 0x5EED_0007)
        let samples = (0..<200).map { _ in randomText(&rng, tokens: 30, commands: 0.05, fillers: 0.05, oddities: 0.02) }
        let personal = ["Zayd", "Dahlsson", "Snakebyte", "Tailscale", "Moonshine"]
        let seconds = Stress.time { for text in samples { _ = TextStyle.casual.insertion(of: text, contextBefore: "So ", fieldCapitalizesSentences: true, personalWords: personal) } }
        XCTAssertLessThan(seconds / Double(samples.count), 0.01, "mean \(seconds / Double(samples.count) * 1_000) ms per call")
    }

    /// A personal dictionary of 500 words, the most anyone will type in.
    func testFiveHundredPersonalWordsStayFast() {
        var rng = StressRNG(seed: 0x5EED_0008)
        let personal = (0..<500).map { index -> String in
            let letters = "bcdfghjklmnpqrstvwxz"
            let name = String((0..<rng.int(4...9)).map { _ in letters.randomElement(using: &rng)! })
            return name.prefix(1).uppercased() + name.dropFirst() + (index % 7 == 0 ? "-\(index)" : "")
        }
        let text = randomText(&rng, tokens: 60, commands: 0.05, fillers: 0.05, oddities: 0) + " " + personal[42] + " " + personal[499]
        var out = ""
        let seconds = Stress.time { for _ in 0..<10 { out = TextStyle.formal.apply(text, personalWords: personal) } }
        XCTAssertLessThan(seconds / 10, 0.025, "mean \(seconds / 10 * 1_000) ms per call with 500 personal words")
        XCTAssertTrue(out.contains(personal[42]) && out.contains(personal[499]))
    }

    /// The vocabulary prefilter is only a speedup: with it and without it, every transcript
    /// formats to the same text, whatever forms (exact, spaced letters, "spell", odd case,
    /// apostrophes, hyphens, punctuation, regex syntax) the personal words appear in.
    func testVocabularyPrefilterNeverChangesTheResult() {
        var rng = StressRNG(seed: 0x5EED_0009)
        let words = ["Zayd", "Dahlsson", "Snakebyte", "C++", "New York", "Jean-Luc", "O'Neil", "Term999", "a.b*c", "ŞAHİN",
                     "Straße", "東京", "Zoë", "ab", "AB", "x|y", "Ünal", "ΟΔΥΣΣΕΥΣ", "Kelvin"]
        func variant(_ word: String) -> String {
            switch rng.int(0...8) {
            case 7: return word.decomposedStringWithCanonicalMapping + rng.pick(["", "\u{0308}", "\u{0301}"])
            case 8: return word.replacingOccurrences(of: "K", with: "\u{212A}").replacingOccurrences(of: "s", with: "\u{017F}")
            case 0: return word.uppercased()
            case 1: return word.lowercased()
            case 2: return word.map(String.init).joined(separator: rng.pick([" ", "  ", "\t"]))
            case 3: return "spell " + word.map(String.init).joined(separator: " ")
            case 4: return word + rng.pick(["'s", "-ish", ".", ",", "’", "s"])
            case 5: return rng.pick(["x", "_", "-", "'"]) + word
            default: return word
            }
        }
        for round in 0..<Stress.iterations(300, heavy: 6_000) {
            let chosen = Array(words.shuffled(using: &rng).prefix(rng.int(1...words.count)))
            var parts: [String] = []
            for _ in 0..<rng.int(1...16) {
                parts.append(rng.chance(0.5) ? variant(rng.pick(words)) : rng.pick(Self.prose + Self.commandPhrases))
            }
            let text = parts.joined(separator: rng.pick([" ", "  ", ", "]))
            let fast = SpokenFormatting.process(text, personalWords: chosen)
            let reference = SpokenFormatting.process(text, personalWords: chosen, prefilter: false)
            XCTAssertEqual(fast.restore(fast.text), reference.restore(reference.text), "round \(round): \(text.debugDescription) with \(chosen)")
        }
    }

    // MARK: Regressions found by the fuzzer

    /// Casual and very casual drop a stray end mark; its space used to stay, so the text ended in
    /// a space (and the next dictation joined with two).
    func testDroppedStrayMarksLeaveNoSpaceBehind() {
        XCTAssertEqual(TextStyle.casual.apply("see you at noon ."), "See you at noon")
        XCTAssertEqual(TextStyle.veryCasual.apply("see you at noon ,"), "see you at noon")
        XCTAssertEqual(TextStyle.veryCasual.apply(". think about it"), "think about it")
        XCTAssertEqual(TextStyle.casual.insertion(of: "sounds good .", contextBefore: "Okay. ", fieldCapitalizesSentences: true), "Sounds good")
    }

    /// Found under ZONE_STRESS=1: a dropped leading comma left a space where the capital went,
    /// and a filler inside a comma series made casual judge a list that was not one.
    func testCasualIsStableAroundLeadingCommasAndFillers() {
        XCTAssertEqual(TextStyle.casual.apply(", a"), "A")
        XCTAssertEqual(TextStyle.casual.apply(", see you tomorrow"), "See you tomorrow")
        XCTAssertEqual(TextStyle.casual.apply("think, for um, lunch?"), "Think for lunch?")
        for text in [", a", "think, for um, lunch?", "eggs, um, milk, and bread", "so, uh, yeah, okay"] {
            let once = TextStyle.casual.apply(text)
            XCTAssertEqual(TextStyle.casual.apply(once), once, text)
        }
    }

    /// Placeholders hold no letters, digits or spaces, whatever the transcript contains.
    func testPlaceholderPrefixIsLetterFree() {
        for _ in 0..<200 {
            let prefix = SpokenFormatting.placeholderPrefix(lead: "\u{E000}", avoiding: "")
            XCTAssertFalse(prefix.dropLast().contains { $0.isLetter || $0.isNumber || $0.isWhitespace || $0.isPunctuation })
            XCTAssertEqual(prefix.unicodeScalars.count, 18)
        }
    }
}
