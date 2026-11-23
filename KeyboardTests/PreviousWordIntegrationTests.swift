// by zayd/cold @ zayd.wtf

import XCTest
import UIKit
import ZoneCore

/// Tap autocorrect reading the word before the typo, through the real `KeyboardModel` and a text
/// host: the strip and the space bar must agree, and nothing may change where the host hides the
/// text before the cursor.
@MainActor
final class PreviousWordIntegrationTests: XCTestCase {
    typealias Proxy = SwipeIntegrationTests.Proxy

    static let pairs: WordPairs? = WordList.shared.flatMap { words in
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ZoneKeyboard/Resources/en-pairs.bin")
        return WordPairs(url: url, words: words)
    }

    override func tearDown() async throws {
        SpellingStore.useWordPairs(nil)
    }

    /// A model whose dictionary has loaded, with or without the word-pair table.
    private func model(_ p: Proxy, pairs: Bool = true, suggestions: Bool = true) async throws -> KeyboardModel {
        let warm = Proxy(), loader = KeyboardModel(proxy: warm)
        loader.refreshTraits()
        loader.apply(KeyboardPreferences(autocorrectEnabled: true, showSuggestions: true))
        for c in "helo" { loader.handleTap(.character(String(c))) }
        for _ in 0..<300 {
            if !loader.suggestions.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(loader.suggestions.isEmpty, "the dictionary never loaded")
        loader.keyboardWillDisappear()
        SpellingStore.useWordPairs(pairs ? try XCTUnwrap(Self.pairs, "en-pairs.bin is missing or was built from another word list") : nil)
        let m = KeyboardModel(proxy: p)
        m.refreshTraits()
        m.apply(KeyboardPreferences(autocorrectEnabled: true, showSuggestions: suggestions))
        // The shared corrector is handed over on a later main-queue turn.
        try await Task.sleep(for: .milliseconds(50))
        return m
    }

    /// Every key and the space with no pause between them, as a fast thumb types.
    private func type(_ text: String, into m: KeyboardModel) {
        for c in text { m.handleTap(c == " " ? .space : .character(String(c))) }
    }

    func testTheSameTypoIsFixedByTheWordBeforeIt() async throws {
        for (typed, wanted) in [("the fpod ", "the food "), ("so fpod ", "so good "), ("an houe ", "an hour "), ("my houe ", "my house "),
                                ("in bes ", "in bed "), ("the bes ", "the best ")] {
            let p = Proxy(), m = try await model(p)
            type(typed, into: m)
            XCTAssertEqual(p.text, wanted, typed)
            m.keyboardWillDisappear()
        }
    }

    /// "iff" is a word to Apple's dictionary, so it stays whatever came before it: a word either
    /// dictionary knows is never traded for a likelier one.
    func testAWordAppleKnowsStaysAfterAnyWord() async throws {
        let p = Proxy(), m = try await model(p)
        type("got iff ", into: m)
        XCTAssertEqual(p.text, "got iff ")
        m.keyboardWillDisappear()
    }

    /// Zayd, November 15: "a USB From micro Center" and "Imma go homexmske pasta", typed by tap.
    func testTypedNamesAndASlippedSpaceBesideATypo() async throws {
        let p = Proxy(); p.capitalizes = true; p.text = "Getting a USB from "
        let m = try await model(p)
        type("micro center today ", into: m)
        XCTAssertEqual(p.text, "Getting a USB from Micro Center today ")
        p.text = "Imma go "
        type("homexmske pasta ", into: m)
        XCTAssertEqual(p.text, "Imma go home make pasta ")
        p.text = "Got "
        type("smth for the vid ", into: m)
        XCTAssertEqual(p.text, "Got smth for the vid ")
        m.keyboardWillDisappear()
    }

    /// Delete right after the name puts both words back as typed, and the next space keeps them.
    func testDeleteUndoesATypedName() async throws {
        // Keeping the undone "centwr" below saves it as a learned word; a later run must start without it.
        func forgetTypo() {
            let key = "zone.keyboard.learnedWords"
            UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: key) ?? []).filter { $0 != "centwr" }, forKey: key)
        }
        forgetTypo()
        defer { forgetTypo() }
        let p = Proxy(); p.capitalizes = true; p.text = "Going to "
        let m = try await model(p)
        type("micro center ", into: m)
        XCTAssertEqual(p.text, "Going to Micro Center ")
        m.keyDown(.delete); m.endDeleteRepeat()
        XCTAssertEqual(p.text, "Going to micro center")
        type(" now ", into: m)
        XCTAssertEqual(p.text, "Going to micro center now ")
        // Later, the same words are the name again.
        type("micro center ", into: m)
        XCTAssertEqual(p.text, "Going to micro center now Micro Center ")
        // A typo the name also fixed comes back too, and stays, as after any undone correction.
        p.text = "Going to "
        type("micro centwr ", into: m)
        XCTAssertEqual(p.text, "Going to Micro Center ")
        m.keyDown(.delete); m.endDeleteRepeat()
        XCTAssertEqual(p.text, "Going to micro centwr")
        type(" ", into: m)
        XCTAssertEqual(p.text, "Going to micro centwr ")
        m.keyboardWillDisappear()
    }

    /// A field that never capitalizes keeps typing lowercase, names included.
    func testALowercaseFieldKeepsTypedNamesLowercase() async throws {
        let p = Proxy(); p.text = "going to "
        let m = try await model(p)
        type("micro center ", into: m)
        XCTAssertEqual(p.text, "going to micro center ")
        m.keyboardWillDisappear()
    }

    func testWithoutTheTableTypingIsAsBefore() async throws {
        for (typed, wanted) in [("the fpod ", "the fpod "), ("an houe ", "an house "), ("in bes ", "in best ")] {
            let p = Proxy(), m = try await model(p, pairs: false)
            type(typed, into: m)
            XCTAssertEqual(p.text, wanted, typed)
            m.keyboardWillDisappear()
        }
    }

    func testAWholeSentenceTypedFastWithSuggestionsHidden() async throws {
        let p = Proxy(), m = try await model(p, suggestions: false)
        type("can you pass the fpod in an houe ", into: m)
        XCTAssertEqual(p.text, "can you pass the food in an hour ")
        m.keyboardWillDisappear()
    }

    /// What the strip arms is what space commits.
    func testTheStripAndTheSpaceBarAgree() async throws {
        let p = Proxy(), m = try await model(p)
        type("the fpod", into: m)
        for _ in 0..<100 {
            if m.suggestions.contains(where: { $0.autoApplies }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(m.suggestions.first(where: { $0.autoApplies })?.text, "food")
        m.handleTap(.space)
        XCTAssertEqual(p.text, "the food ")
        // Delete right after puts the typed word back, as after any correction.
        m.keyDown(.delete); m.endDeleteRepeat()
        XCTAssertEqual(p.text, "the fpod")
        m.keyboardWillDisappear()
    }

    /// A sentence start, a number, a new line, an empty field: no previous word, so as before.
    func testNoPreviousWordMeansNoChange() async throws {
        for start in ["", "Done. ", "at 5 ", "one\n", "\u{1F600} "] {
            let p = Proxy(), m = try await model(p)
            p.text = start
            type("fpod ", into: m)
            XCTAssertEqual(p.text, start + "fpod ", start.debugDescription)
            m.keyboardWillDisappear()
        }
    }

    /// Hosts that hide the text before the cursor, show only a few characters of it, or forbid
    /// autocorrection: the typed word stands and nothing else in the field is touched.
    func testHostsThatHideContextAreLeftAlone() async throws {
        var p = Proxy(), m = try await model(p)
        p.text = "the "
        p.contextLimit = 4
        type("fpod ", into: m)
        XCTAssertEqual(p.text, "the fpod ")
        m.keyboardWillDisappear()

        p = Proxy(); m = try await model(p)
        p.text = "the "
        p.unknown = true
        type("fpod ", into: m)
        XCTAssertEqual(p.text, "the fpod ")
        m.keyboardWillDisappear()

        p = Proxy(); p.allowed = false; m = try await model(p)
        m.refreshTraits()
        type("the fpod ", into: m)
        XCTAssertEqual(p.text, "the fpod ")
        m.keyboardWillDisappear()
    }

    /// Text after the cursor (editing mid-sentence) and a word the keyboard knows are untouched.
    func testKnownWordsAndMidSentenceEditsAreUntouched() async throws {
        var p = Proxy(), m = try await model(p)
        type("the food is good and so is the best door ", into: m)
        XCTAssertEqual(p.text, "the food is good and so is the best door ")
        m.keyboardWillDisappear()

        p = Proxy(); m = try await model(p)
        p.text = "the "
        p.tail = "truck"
        type("fpod", into: m)
        m.handleTap(.space)
        XCTAssertEqual(p.text + p.tail, "the fpod truck")
        m.keyboardWillDisappear()
    }

    /// Delete right after the correction puts the typed word back, as after any correction.
    /// (Space after that would teach the keyboard the word for good, which a test must not do.)
    func testDeleteAfterTheCorrectionRestoresTheTypedWord() async throws {
        let p = Proxy(), m = try await model(p)
        type("the fpod ", into: m)
        XCTAssertEqual(p.text, "the food ")
        m.keyDown(.delete); m.endDeleteRepeat()
        XCTAssertEqual(p.text, "the fpod")
        m.keyboardWillDisappear()
    }
}
