// by zayd/cold @ zayd.wtf

import XCTest
import UIKit
import ZoneCore

/// Whole next words in the row between words, through the real `KeyboardModel` and a text host:
/// a sentence tapped out word after word, and every place the row must stay as it was.
@MainActor
final class NextWordPredictionIntegrationTests: XCTestCase {
    typealias Proxy = SwipeIntegrationTests.Proxy

    override func tearDown() async throws {
        SpellingStore.useWordPairs(nil)
    }

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
        SpellingStore.useWordPairs(pairs ? try XCTUnwrap(PreviousWordIntegrationTests.pairs, "en-pairs.bin is missing or was built from another word list") : nil)
        let m = KeyboardModel(proxy: p)
        m.refreshTraits()
        m.apply(KeyboardPreferences(autocorrectEnabled: true, showSuggestions: suggestions))
        try await Task.sleep(for: .milliseconds(50))
        return m
    }

    private func type(_ text: String, into m: KeyboardModel) {
        for c in text { m.handleTap(c == " " ? .space : .character(String(c))) }
    }

    /// The row follows typing after a short pause (`advisoryDelay`); wait it out.
    private func settle() async throws { try await Task.sleep(for: .milliseconds(200)) }

    private func predictions(_ m: KeyboardModel) -> [String] {
        m.suggestions.filter { $0.kind == .prediction }.map(\.text)
    }

    func testASpaceAfterAWordOffersWhatFollowsIt() async throws {
        let p = Proxy(), m = try await model(p)
        type("thank ", into: m)
        try await settle()
        XCTAssertEqual(predictions(m).first, "you")
        XCTAssertEqual(m.suggestions.count, 3)
        XCTAssertTrue(m.suggestions.allSatisfy { $0.kind == .prediction && !$0.autoApplies })
        XCTAssertEqual(p.text, "thank ")
        m.keyboardWillDisappear()
    }

    /// Zayd, November 8: "I can just start with one letter and immediately start going into a
    /// full-blown sentence just by clicking things in that bar".
    func testASentenceIsTappedOutWordAfterWordWithNoPause() async throws {
        let p = Proxy(), m = try await model(p)
        type("thank ", into: m)
        try await settle()
        var expected = "thank "
        for _ in 0..<12 {
            let next = try XCTUnwrap(m.suggestions.first, "the row ran dry after \(expected)")
            XCTAssertEqual(next.kind, .prediction)
            m.choose(next)
            expected += next.text + " "
            XCTAssertEqual(p.text, expected)
        }
        XCTAssertEqual(p.text.split(separator: " ").count, 13)
        // The host catching up changes nothing: the row already holds what follows the last word.
        let shown = m.suggestions
        try await settle()
        XCTAssertEqual(m.suggestions, shown)
        m.keyboardWillDisappear()
    }

    func testTypingALetterTakesTheRowBackAndAStaleTapWritesNothing() async throws {
        let p = Proxy(), m = try await model(p)
        type("thank ", into: m)
        try await settle()
        let stale = try XCTUnwrap(m.suggestions.first)
        type("y", into: m)
        m.choose(stale) // The finger landed on the old row before it caught up.
        XCTAssertEqual(p.text, "thank y")
        try await settle()
        XCTAssertTrue(predictions(m).isEmpty)
        XCTAssertTrue(m.suggestions.contains { $0.text == "you" }, "\(m.suggestions.map(\.text))")
        m.keyboardWillDisappear()
    }

    func testATapAfterTheTextMovedWritesNothing() async throws {
        let p = Proxy(), m = try await model(p)
        type("thank ", into: m)
        try await settle()
        let stale = try XCTUnwrap(m.suggestions.first)
        p.text = "see you on " // The host changed the text and has not said so yet.
        m.choose(stale)
        XCTAssertEqual(p.text, "see you on ")
        XCTAssertTrue(m.suggestions.isEmpty)
        // Another field altogether.
        p.text = "thank "
        m.hostTextDidChange()
        try await settle()
        let again = try XCTUnwrap(m.suggestions.first)
        p.session = "b"
        m.choose(again)
        XCTAssertEqual(p.text, "thank ")
        m.keyboardWillDisappear()
    }

    func testTheRowStaysEmptyWhereNothingShouldBeOffered() async throws {
        // An empty field, a sentence start, a number, a word the list lacks, a new line.
        for text in ["", "Done. ", "at 5 ", "zqxjv ", "thank\n", "thank", "thank  x "] {
            let p = Proxy(), m = try await model(p)
            p.text = text
            m.hostTextDidChange()
            try await settle()
            XCTAssertTrue(predictions(m).isEmpty, "\"\(text)\" offered \(predictions(m))")
            m.keyboardWillDisappear()
        }
        // In the middle of text.
        let middle = Proxy(), m1 = try await model(middle)
        middle.text = "thank "; middle.tail = "very much"
        m1.hostTextDidChange()
        try await settle()
        XCTAssertTrue(predictions(m1).isEmpty)
        // At the end of a line with more below, the row is offered.
        middle.tail = "\nsecond line"
        m1.hostTextDidChange()
        try await settle()
        XCTAssertEqual(predictions(m1).first, "you")
        m1.keyboardWillDisappear()
        // A host that hides the text, a field that refuses autocorrection, suggestions off, no table.
        let hidden = Proxy(); hidden.unknown = true
        let secure = Proxy(); secure.allowed = false
        for (p, pairs, on) in [(hidden, true, true), (secure, true, true), (Proxy(), true, false), (Proxy(), false, true)] {
            let m = try await model(p, pairs: pairs, suggestions: on)
            type("thank ", into: m)
            try await settle()
            XCTAssertTrue(predictions(m).isEmpty)
            m.keyboardWillDisappear()
        }
    }

    func testPredictionsFollowShiftAndAFieldThatStaysLowercase() async throws {
        // A field that capitalizes: dictionary casing, a capital with Shift, capitals with it locked.
        let p = Proxy(); p.capitalizes = true
        let m = try await model(p)
        type("I think ", into: m)
        try await settle()
        let plain = predictions(m)
        XCTAssertFalse(plain.isEmpty)
        XCTAssertTrue(plain.contains("I") || plain.allSatisfy { $0 == $0.lowercased() }, "\(plain)")
        m.handleTap(.shift)
        XCTAssertEqual(predictions(m), plain.map { $0.prefix(1).uppercased() + $0.dropFirst() })
        let capital = try XCTUnwrap(m.suggestions.first)
        m.choose(capital)
        XCTAssertEqual(p.text, "I think \(capital.text) ")
        XCTAssertEqual(m.shift, .off)
        m.keyboardWillDisappear()
        // A field that never capitalizes keeps even "I" lowercase, as corrections there do.
        let lower = Proxy(), m2 = try await model(lower)
        type("you and ", into: m2)
        try await settle()
        XCTAssertFalse(predictions(m2).isEmpty)
        XCTAssertTrue(predictions(m2).allSatisfy { $0 == $0.lowercased() }, "\(predictions(m2))")
        m2.keyboardWillDisappear()
    }

    func testASecondSpaceAfterAPredictionEndsTheSentenceAndDeleteTakesTheSpace() async throws {
        let p = Proxy(), m = try await model(p)
        type("thank ", into: m)
        try await settle()
        m.choose(try XCTUnwrap(m.suggestions.first))
        XCTAssertEqual(p.text, "thank you ")
        m.keyDown(.delete); m.endDeleteRepeat()
        XCTAssertEqual(p.text, "thank you")
        type(" ", into: m)
        try await settle()
        m.choose(try XCTUnwrap(m.suggestions.first))
        let sentence = p.text
        type(" ", into: m)
        XCTAssertEqual(p.text, String(sentence.dropLast()) + ". ")
        try await settle()
        XCTAssertTrue(predictions(m).isEmpty, "a sentence start offers nothing")
        m.keyboardWillDisappear()
    }

    /// A completion follows the word before: after "good", "morn" is "morning" first.
    func testCompletionsInTheRowFollowTheWordBefore() async throws {
        let p = Proxy(), m = try await model(p)
        type("good morn", into: m)
        try await settle()
        XCTAssertEqual(m.suggestions.first { $0.kind == .completion }?.text, "morning")
        m.keyboardWillDisappear()
    }

    /// Zayd, November 8, in Messages: "Think mine is The best tho". Messages can hand its
    /// compose field a new identity in the middle of a sentence and hide the text before the
    /// cursor while it does. A field that holds text is not a sentence start.
    func testAFieldThatChangesIdentityMidSentenceDoesNotCapitalizeTheNextWord() async throws {
        let p = Proxy(); p.capitalizes = true
        let m = try await model(p)
        type("Think mine is ", into: m)
        XCTAssertEqual(m.shift, .off)
        p.session = "b"
        p.unknown = true
        m.hostTextDidChange()
        m.refreshTraits()
        XCTAssertEqual(m.shift, .off, "a field with text in it is not a sentence start")
        p.unknown = false
        type("the best", into: m)
        XCTAssertEqual(p.text, "Think mine is the best")
        m.keyboardWillDisappear()
    }

    /// The other half of that rule stays: a new, empty field that reports no context at all
    /// still starts with a capital.
    func testANewEmptyFieldThatHidesItsContextStillStartsWithACapital() async throws {
        let p = Proxy(); p.capitalizes = true; p.emptyContextIsNil = true
        let m = try await model(p)
        type("hello there ", into: m)
        p.session = "b"; p.text = ""
        m.hostTextDidChange()
        m.refreshTraits()
        XCTAssertEqual(m.shift, .on)
        type("hi", into: m)
        XCTAssertEqual(p.text, "Hi")
        m.keyboardWillDisappear()
    }
}
