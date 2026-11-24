// by zayd/cold @ zayd.wtf

import XCTest
import UIKit
import ZoneCore

/// A word kept by accident, one slip from an everyday word, through the real `KeyboardModel`:
/// Zayd undid a correction of "bsby" once, the keyboard kept it, and from then on never fixed it
/// and wrote it for every swiped "baby" (November 20). The word is still left as typed, but it
/// stays out of swipe, the row offers "baby", and taking that offer forgets it.
@MainActor
final class KeptSlipIntegrationTests: XCTestCase {
    typealias Proxy = SwipeIntegrationTests.Proxy

    private static let learnedKey = "zone.keyboard.learnedWords"
    private static let slipsKey = "zone.keyboard.learnedSlips"
    private static let checkedKey = "zone.keyboard.learnedSlipsChecked"

    /// The shared corrector and the saved lists, without "bsby".
    private func forgetTheSlip() {
        let defaults = UserDefaults.standard
        SpellingStore.current?.forget("bsby")
        defaults.set((defaults.stringArray(forKey: Self.learnedKey) ?? []).filter { $0 != "bsby" }, forKey: Self.learnedKey)
        var slips = defaults.dictionary(forKey: Self.slipsKey) as? [String: String] ?? [:]
        slips["bsby"] = nil
        defaults.set(slips, forKey: Self.slipsKey)
        defaults.set((defaults.stringArray(forKey: Self.learnedKey) ?? []).count, forKey: Self.checkedKey)
    }

    override func setUp() async throws { forgetTheSlip() }
    override func tearDown() async throws { forgetTheSlip() }

    /// A model whose dictionary has loaded.
    private func model(_ p: Proxy, swipe: Bool = false) async throws -> KeyboardModel {
        let m = KeyboardModel(proxy: p)
        m.refreshTraits()
        m.apply(KeyboardPreferences(autocorrectEnabled: true, showSuggestions: true, swipeTypingEnabled: swipe, swipeLearningEnabled: false))
        for _ in 0..<300 {
            if SpellingStore.current != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(SpellingStore.current, "the dictionary never loaded")
        // The shared corrector is handed over on a later main-queue turn.
        try await Task.sleep(for: .milliseconds(50))
        return m
    }

    private func type(_ text: String, into m: KeyboardModel) {
        for c in text { m.handleTap(c == " " ? .space : .character(String(c))) }
    }

    /// The row is drawn once typing pauses; this waits for the offer of `word` in it.
    private func offer(of word: String, in m: KeyboardModel) async throws -> Suggestion {
        for _ in 0..<150 {
            if let found = m.suggestions.first(where: { $0.text == word }) { return found }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try XCTUnwrap(m.suggestions.first { $0.text == word }, "the row never offered \(word): \(m.suggestions)")
    }

    func testUndoingTheCorrectionKeepsTheWordButOffersTheEverydayOne() async throws {
        let p = Proxy(); p.text = "my "
        let m = try await model(p)
        type("bsby ", into: m)
        XCTAssertEqual(p.text, "my baby ")
        // Delete puts the typed word back; the next space keeps it, as after any undone correction.
        m.keyDown(.delete); m.endDeleteRepeat()
        XCTAssertEqual(p.text, "my bsby")
        type(" ", into: m)
        XCTAssertEqual(p.text, "my bsby ")
        XCTAssertTrue(SpellingStore.learnedWords.contains("bsby"))
        XCTAssertEqual(SpellingStore.keptSlips["bsby"], "baby")
        XCTAssertFalse(SpellingStore.swipeableLearnedWords.contains("bsby"), "swipe is never given the slip")

        // Typed again it is left alone, and the row offers the everyday word without applying it.
        type("bsby", into: m)
        let offered = try await offer(of: "baby", in: m)
        XCTAssertEqual(offered.kind, .correction)
        XCTAssertFalse(offered.autoApplies)
        type(" ", into: m)
        XCTAssertEqual(p.text, "my bsby bsby ")

        // Taking the offer writes the word and forgets the slip for good.
        type("bsby", into: m)
        m.choose(try await offer(of: "baby", in: m))
        XCTAssertTrue(p.text.hasPrefix("my bsby bsby baby"), p.text)
        XCTAssertFalse(SpellingStore.learnedWords.contains("bsby"))
        XCTAssertNil(SpellingStore.keptSlips["bsby"])
        p.text = "my "
        type("bsby ", into: m)
        XCTAssertEqual(p.text, "my baby ", "corrected again, like any typo")
        m.keyboardWillDisappear()
    }

    /// Zayd's phone already holds the word: kept before this check existed. The next time the
    /// keyboard loads, the words kept so far are looked at once.
    func testAWordKeptByAnEarlierBuildIsFoundWhenTheKeyboardLoads() async throws {
        let p = Proxy()
        let m = try await model(p, swipe: true)
        let defaults = UserDefaults.standard
        let kept = (defaults.stringArray(forKey: Self.learnedKey) ?? []) + ["skrrt", "bsby", "OpenRouter"]
        defaults.set(kept, forKey: Self.learnedKey)
        defaults.set(0, forKey: Self.checkedKey)
        for word in ["skrrt", "bsby", "OpenRouter"] { SpellingStore.current?.learn(word) }
        defer {
            for word in ["skrrt", "OpenRouter"] { SpellingStore.current?.forget(word) }
            defaults.set((defaults.stringArray(forKey: Self.learnedKey) ?? []).filter { !["skrrt", "OpenRouter"].contains($0) }, forKey: Self.learnedKey)
        }
        XCTAssertTrue(SpellingStore.swipeableLearnedWords.contains("bsby"), "an earlier build gave it to swipe")

        SpellingStore.checkKeptWords()
        for _ in 0..<200 {
            if defaults.integer(forKey: Self.checkedKey) >= kept.count { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(defaults.integer(forKey: Self.checkedKey), kept.count, "every kept word was looked at")
        XCTAssertEqual(SpellingStore.keptSlips["bsby"], "baby")
        XCTAssertNil(SpellingStore.keptSlips["skrrt"], "a new word of the person's own is not a slip")
        XCTAssertNil(SpellingStore.keptSlips["openrouter"])
        XCTAssertFalse(SpellingStore.swipeableLearnedWords.contains("bsby"))
        XCTAssertTrue(SpellingStore.swipeableLearnedWords.contains("skrrt"))
        XCTAssertTrue(SpellingStore.swipeableLearnedWords.contains("OpenRouter"))

        // And the swipe that used to write it: a trace that turns on s, beside a.
        let swipes = SwipeIntegrationTests()
        p.text = "my "
        m.handleSwipe(swipes.path("bsby"), layout: swipes.layout)
        try await swipes.waitFor { p.text != "my " }
        XCTAssertEqual(p.text, "my baby")
        m.keyboardWillDisappear()
    }
}
