// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// Apple's spell checker as a second dictionary (`Autocorrector.systemAccepts`). The keyboard asks
/// `UITextChecker`; these tests stand in for it with what UITextChecker answered on the iOS 26.2
/// simulator on 2026-11-08 (see docs/research/2026-11-08-apple-dictionary.md).
final class SystemSpellingTests: XCTestCase {
    /// Words from Apple's 3,000 commonest that Zone's list lacks and was changing on space,
    /// with what Zone changed them to. UITextChecker accepts every one.
    static let mangled: [String: String] = [
        "meds": "mess", "donut": "don't", "gameplay": "game play", "cancelled": "canceled",
        "theatre": "theater", "axe": "are", "devs": "debs",
        "lil": "lol", "glitchy": "glitch", "timeframe": "time frame", "geez": "gees",
        "hav": "have", "goin": "go in", "jus": "just", "judgement": "judgment", "lockdown": "knockdown",
        "keychain": "key chain", "repost": "report", "dreamt": "dreamy", "spelt": "spent",
        "udon": "upon", "kimchi": "Kim hi", "wifey": "wife",
    ]

    /// UITextChecker on iOS 26.2: every word above, plus each typed word of `TypoEvaluationSet`
    /// that it called valid (it lists typos such as "agin" and "oaky" as words).
    static let appleWords: Set<String> = Set(mangled.keys).union([
        "ASAP", "FaceTime", "Hwy", "Im", "McDonald's", "POV", "Siri", "Snapchat", "Uber", "Xbox", "abs",
        "agin", "app", "bet", "bruh", "cant", "cloud", "donuts", "form", "fr", "from", "gonna", "hell",
        "hmm", "hoe", "i", "iPhone", "id", "idk", "ill", "imma", "its", "kist", "lets", "lmao", "lol",
        "lowkey", "ok", "okay", "omg", "pls", "quiet", "quite", "shell", "than", "thats", "the", "then",
        "tho", "thx", "ti", "tv", "ur", "vibe", "wanna", "wed", "well", "were", "whaat", "whats", "wifi",
        "wont", "ya", "yeah", "yesh", "yo",
    ])

    static func corrector() -> Autocorrector {
        let corrector = Autocorrector(words: WordListTests.list)
        corrector.systemAccepts = { appleWords.contains($0) }
        return corrector
    }

    func testWordsOnlyAppleKnowsAreKept() {
        let plain = Autocorrector(words: WordListTests.list)
        let corrector = Self.corrector()
        for (word, wrongFix) in Self.mangled.sorted(by: { $0.key < $1.key }) {
            // The measurement this change rests on: without Apple's checker the word is changed,
            // unless Zone's own supplement lists it now (more-words.txt has gameplay, theatre).
            if ModernVocabulary.words.contains(where: { $0.lowercased() == word }) {
                XCTAssertNil(plain.evaluate(word).replacement, "\(word) is listed and kept")
            } else {
                XCTAssertEqual(plain.evaluate(word).replacement, wrongFix, "baseline for \(word)")
            }
            XCTAssertNil(corrector.evaluate(word).replacement, "\(word) should stay")
            XCTAssertTrue(corrector.recognizes(word), "\(word) is a known word")
        }
    }

    func testKeptWordStillOffersTheCorrection() {
        // Space keeps "meds", but someone who meant "mess" can still tap it.
        let suggestions = Self.corrector().evaluate("meds").suggestions
        XCTAssertEqual(suggestions.first?.text, "meds")
        XCTAssertTrue(suggestions.contains { $0.text == "mess" && !$0.autoApplies })
    }

    func testTyposAppleListsAsWordsAreStillFixed() {
        let corrector = Self.corrector()
        for (typed, wanted) in [("agin", "again"), ("oaky", "okay"), ("yesh", "yeah"), ("whaat", "what")] {
            XCTAssertEqual(corrector.evaluate(typed).replacement, wanted, typed)
        }
    }

    func testCapitalizedWordIsAskedAsTyped() {
        var asked: [String] = []
        let corrector = Autocorrector(words: WordListTests.list)
        corrector.systemAccepts = { asked.append($0); return false }
        _ = corrector.evaluate("Glitchy")
        _ = corrector.evaluate("Glitchy", autoCapitalized: true)
        XCTAssertEqual(asked, ["Glitchy", "glitchy"])
    }

    /// The typo set keeps its score with Apple's checker in the loop.
    func testTypoSetWithAppleChecker() {
        let corrector = Self.corrector()
        var pass = 0
        var failures: [String] = []
        for item in TypoEvaluationSet.cases {
            let got = corrector.evaluate(item.typed, autoCapitalized: item.autoCapitalized).replacement ?? item.typed
            if got == item.wanted { pass += 1 } else { failures.append("\(item.typed) -> \(got) (want \(item.wanted))") }
        }
        print("typo set with Apple's checker: \(pass)/\(TypoEvaluationSet.cases.count); failures: " + failures.joined(separator: "; "))
        XCTAssertGreaterThanOrEqual(pass, TypoEvaluationTests.typoSetFloor)
    }
}
