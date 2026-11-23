// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// Zayd's screenshots of November 15, 2026: messages typed and swiped on Zone. Each case is a
/// sentence from them (or its shape), so the fix stays tied to what went wrong in real use.
///
/// - "No I have to fight The old Man", "IM looking at my Phone With My biggest eye", "I might Go
///   At 3", "micro Center": contact-card words carrying their capital (`ContactCasingTests`
///   covers the rule; here, the exact words from his own lexicon).
/// - "Imma go homexmske pasta": a slipped space and a slipped key in one run.
/// - "a USB From micro Center": a name made of two ordinary words.
/// - "smth" and friends: texting shorthand autocorrect turned into other words.
final class TypingScreenshotTests: XCTestCase {
    private let layout = SwipeLayout.qwerty()

    private func path(_ word: String) -> [SwipePoint] {
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

    private func decoder() throws -> SwipeDecoder {
        var tuning = SwipeTuning(); tuning.visitRadius = 0; tuning.shortlist = 160
        return SwipeDecoder(words: try XCTUnwrap(WordList.shared), tuning: tuning)
    }

    // MARK: Contact-card capitals

    /// The words his phone's lexicon held that came out capitalized in the screenshots.
    func testTheScreenshotsCapitalsAreContactFieldsAndSwipeLowercase() throws {
        let fields = ["Phone", "From", "Go", "The", "Man", "With", "At", "Min", "My", "Center", "Old"]
        let book = SystemLexiconSnapshot(entries: (fields + ["Nika"]).map { (input: $0.lowercased(), text: $0) })
        XCTAssertEqual(book.swipeWords, ["Nika"])
        let decoder = try decoder()
        decoder.setPersonalWords(book.swipeWords)
        for word in fields.map({ $0.lowercased() }) {
            let found = try XCTUnwrap(decoder.decode(path(word), layout: layout, limit: 96).first { $0.word.lowercased() == word }, word)
            XCTAssertEqual(found.word, word)
        }
    }

    /// A job title or initials on a card ("Ceo", "Td") is not how the word is written: the
    /// dictionary's "CEO" is.
    func testACardsTitleCaseAcronymLeavesTheDictionarysCapitals() {
        let book = SystemLexiconSnapshot(entries: ["Ceo", "Td", "Nika", "Dr"].map { (input: $0.lowercased(), text: $0) })
        XCTAssertFalse(book.swipeWords.contains("Ceo"))
        XCTAssertFalse(book.swipeWords.contains("Td"))
        XCTAssertTrue(book.swipeWords.contains("Nika"))
        XCTAssertTrue(book.swipeWords.contains("Dr"))
    }

    // MARK: Swipe

    /// "imma" was not in swipe's vocabulary at all and came out "Ina".
    func testImmaSwipes() throws {
        let decoder = try decoder()
        XCTAssertEqual(decoder.decode(path("imma"), layout: layout, limit: 8).first?.word, "imma")
        // It does not take the words its shape passes through.
        for word in ["in", "I'm", "man", "mama"] {
            XCTAssertEqual(decoder.decode(path(word), layout: layout, limit: 8).first?.word, word, word)
        }
    }

    /// Built-in names swipe in their own casing, and they do not take the words around them.
    func testBuiltInNamesSwipe() throws {
        let decoder = try decoder()
        decoder.setPersonalWords(BuiltInVocabulary.names)
        XCTAssertEqual(decoder.decode(path("zayd"), layout: layout, limit: 8).first?.word, "Zayd")
        XCTAssertEqual(decoder.decode(path("aalia"), layout: layout, limit: 8).first?.word, "Aalia")
        // Like a contact, a personal name outranks a rare word of nearly the same shape ("alias").
        for word in ["all", "says", "also"] {
            XCTAssertEqual(decoder.decode(path(word), layout: layout, limit: 8).first?.word, word, word)
        }
    }

    /// The learned table stores lowercase keys. Handed over as they are, a personal "google" or
    /// "i'm" overrode the dictionary's casing for every later swipe.
    func testLearnedSwipeChoicesKeepTheirCapitals() throws {
        let words = try XCTUnwrap(WordList.shared)
        var learning = SwipeLearning()
        for word in ["Google", "I'm", "imma", "Paris", "wyd"] { learning.chose(word) }
        let spelled = learning.words(spelledBy: words)
        XCTAssertEqual(Set(spelled), ["Google", "I'm", "imma", "Paris", "wyd"])
        let decoder = try decoder()
        decoder.setPersonalWords(spelled)
        XCTAssertEqual(decoder.decode(path("google"), layout: layout, limit: 8).first?.word, "Google")
        XCTAssertEqual(decoder.decode(path("im"), layout: layout, limit: 8).first?.word, "I'm")
    }

    // MARK: Tap typing

    /// "Imma go homexmske pasta": x is the slipped space and s the slipped a.
    func testASlippedSpaceBesideAShortTypo() {
        let corrector = Autocorrector(words: WordListTests.list)
        XCTAssertEqual(corrector.evaluate("homexmske").replacement, "home make")
        XCTAssertEqual(corrector.evaluate("homexmake").replacement, "home make")
        XCTAssertEqual(corrector.evaluate("mskexhome").replacement, "make home")
        // A short misspelled part needs very common company on the other side of the space.
        XCTAssertNil(corrector.evaluate("zorpxmske").replacement)
        // A run that is one word with a typo is still that word.
        XCTAssertEqual(corrector.evaluate("homemske").replacement?.contains(" "), false)
    }

    /// Texting shorthand is a word, not a typo.
    func testTextingShorthandIsKept() {
        let corrector = Autocorrector(words: WordListTests.list)
        corrector.setPersonalWords([])
        for word in ["smth", "mins", "vid", "vids", "rly", "ily", "obvi", "hru", "wym", "aight", "dawg", "otw", "ttys",
                     "yessir", "imma", "idk", "smh", "wyd"] {
            XCTAssertNil(corrector.evaluate(word).replacement, word)
        }
        // Ordinary fixes around them are unchanged.
        XCTAssertEqual(corrector.evaluate("teh").replacement, "the")
        XCTAssertEqual(corrector.evaluate("im").replacement, "I'm")
        XCTAssertEqual(corrector.evaluate("google").replacement, "Google")
    }

    // MARK: Names made of ordinary words

    func testTwoOrdinaryWordsThatMakeANameAreWrittenAsTheName() {
        XCTAssertEqual(PhraseCasing.name(before: "a USB From micro ", word: "center")?.name, "Micro Center")
        XCTAssertEqual(PhraseCasing.name(before: "a USB From micro ", word: "center")?.prefixLength, 6)
        XCTAssertEqual(PhraseCasing.name(before: "Micro ", word: "center")?.name, "Micro Center")
        XCTAssertEqual(PhraseCasing.name(before: "going to taco ", word: "bell")?.name, "Taco Bell")
        XCTAssertEqual(PhraseCasing.name(before: "at trader ", word: "joes")?.name, "Trader Joe's")
        XCTAssertEqual(PhraseCasing.name(before: "the home ", word: "depot")?.name, "Home Depot")
    }

    func testOrdinaryUsesOfThoseWordsStay() {
        // Each word alone, a word between them, the name already written, or a word typed in
        // capitals (the person's own casing) leaves the text alone.
        XCTAssertNil(PhraseCasing.name(before: "the visitor ", word: "center"))
        XCTAssertNil(PhraseCasing.name(before: "a micro ", word: "usb"))
        XCTAssertNil(PhraseCasing.name(before: "micro and ", word: "center"))
        XCTAssertNil(PhraseCasing.name(before: "micro  ", word: "center"))
        XCTAssertNil(PhraseCasing.name(before: "Micro ", word: "Center"))
        XCTAssertNil(PhraseCasing.name(before: "MICRO ", word: "CENTER"))
        XCTAssertNil(PhraseCasing.name(before: "@micro ", word: "center"))
        XCTAssertNil(PhraseCasing.name(before: "micro\n", word: "center"))
        XCTAssertFalse(PhraseCasing.mayEndName("the"))
        XCTAssertTrue(PhraseCasing.mayEndName("center"))
    }

    func testTheSeparatorWritesTheNameAndDeletePutsTheWordsBack() throws {
        let corrector = Autocorrector(words: WordListTests.list)
        let before = "a USB From micro center"
        let edit = TypingEdits.separator(" ", typedWord: "center", before: before, after: "", corrector: corrector)
        XCTAssertEqual(edit.deleteCount, "micro center".count)
        XCTAssertEqual(edit.insert, "Micro Center ")
        let typed = String(before.dropLast(edit.deleteCount)) + edit.insert
        XCTAssertEqual(typed, "a USB From Micro Center ")
        let correction = try XCTUnwrap(edit.correction)
        let undo = try XCTUnwrap(TypingEdits.revert(correction, before: typed))
        XCTAssertEqual(String(typed.dropLast(undo.deleteCount)) + undo.insert, before)
        // Right after that undo, and in a field that keeps typing lowercase, the words stay.
        XCTAssertNil(TypingEdits.separator(" ", typedWord: "center", before: before, after: "", corrector: corrector,
                                           writesNames: false).correction)
        XCTAssertNil(TypingEdits.separator(" ", typedWord: "center", before: before, after: "", corrector: corrector,
                                           preserveLowercase: true).correction)
        // A typo in the last word is fixed and the name written in one step.
        let fixed = TypingEdits.separator(" ", typedWord: "centwr", before: "micro centwr", after: "", corrector: corrector)
        XCTAssertEqual(fixed.insert, "Micro Center ")
    }

    /// Dictation writes the same names, in the style's casing.
    func testDictationWritesTheNewNames() {
        XCTAssertEqual(TextStyle.formal.apply("i'm getting a cable from micro center"), "I'm getting a cable from Micro Center.")
        XCTAssertEqual(TextStyle.casual.apply("meet me at micro center"), "Meet me at micro center")
    }
}
