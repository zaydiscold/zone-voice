// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// Zone's corrector with Apple's real checker attached, as the keyboard runs it, over the 345
/// cases of the November 8 audit (`Fixtures/apple-audit-spelling-input.json`). Apple's guesses
/// may only add: every answer Zone showed alone is still shown, and what space applies is
/// unchanged for every case.
@MainActor final class SystemSpellingLiveTests: XCTestCase {
    private struct Case: Decodable { let typed: String; let wanted: String; let autoCap: Bool; let set: String }
    private static let cases: [Case] = {
        let url = Bundle(for: SystemSpellingLiveTests.self).url(forResource: "apple-audit-spelling-input", withExtension: "json")!
        return try! JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    }()
    private func corrector(apple: Bool) -> Autocorrector {
        let c = Autocorrector(words: WordList.shared!)
        c.systemAccepts = { word in MainActor.assumeIsolated { SystemSpelling.accepts(word) } }
        if apple {
            c.systemGuesses = { word in MainActor.assumeIsolated { SystemSpelling.guesses(for: word) } }
            c.systemCompletions = { word in MainActor.assumeIsolated { SystemSpelling.completions(for: word) } }
        }
        return c
    }
    private func shows(_ e: Evaluation, _ wanted: String) -> Bool {
        e.suggestions.contains { $0.text.lowercased() == wanted.lowercased() }
    }

    func testAppleGuessesOnlyAdd() {
        let zone = corrector(apple: false), mixed = corrector(apple: true)
        var lost: [String] = [], changedSpace: [String] = [], gained: [String] = []
        var hits = ["existing": (zone: 0, mixed: 0, total: 0), "new": (zone: 0, mixed: 0, total: 0)]
        for item in Self.cases {
            let a = zone.evaluate(item.typed, autoCapitalized: item.autoCap)
            let b = mixed.evaluate(item.typed, autoCapitalized: item.autoCap)
            if a.replacement != b.replacement { changedSpace.append(item.typed) }
            XCTAssertLessThanOrEqual(b.suggestions.count, Autocorrector.maxSuggestions, item.typed)
            XCTAssertEqual(b.suggestions.first?.kind, .literal, item.typed)
            guard item.wanted.lowercased() != item.typed.lowercased() else { continue }
            let za = shows(a, item.wanted), zb = shows(b, item.wanted)
            hits[item.set]!.total += 1
            if za { hits[item.set]!.zone += 1 }
            if zb { hits[item.set]!.mixed += 1 }
            if za, !zb { lost.append(item.typed) }
            if !za, zb { gained.append(item.typed) }
        }
        print("APPLE-MIX existing zone \(hits["existing"]!.zone) mixed \(hits["existing"]!.mixed) of \(hits["existing"]!.total); new zone \(hits["new"]!.zone) mixed \(hits["new"]!.mixed) of \(hits["new"]!.total); gained \(gained)")
        XCTAssertEqual(lost, [], "answers Zone showed alone that the mixed row hides")
        XCTAssertEqual(changedSpace, [], "what space applies must not change")
        XCTAssertGreaterThanOrEqual(hits["new"]!.mixed, 19)
        XCTAssertGreaterThanOrEqual(hits["existing"]!.mixed, hits["existing"]!.zone)
    }

    func testAppleShowsTheLongerWordZoneLacks() {
        let e = corrector(apple: true).evaluate("donu")
        // Apple offers it as a guess or a completion; either way the row shows the longer word.
        XCTAssertTrue(e.suggestions.contains { $0.kind != .literal && $0.text.hasPrefix("donu") }, "\(e.suggestions)")
        XCTAssertNil(e.replacement)
    }

    /// Every keystroke evaluates the word again: growing prefixes of each case, uncached.
    func testTypingCostStaysSmall() {
        let c = corrector(apple: true)
        let words = Self.cases.prefix(120).map(\.typed)
        var keystrokes = 0
        let start = CFAbsoluteTimeGetCurrent()
        for word in words {
            for end in word.indices.dropFirst() {
                _ = c.evaluate(String(word[...end])); keystrokes += 1
            }
        }
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(keystrokes)
        print("APPLE-MIX mean \(ms) ms per keystroke over \(keystrokes)")
        XCTAssertLessThan(ms, 3)
    }
}
