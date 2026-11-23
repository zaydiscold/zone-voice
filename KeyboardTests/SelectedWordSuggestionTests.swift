// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// Selecting a word offers its alternatives; a tap replaces exactly that selection.
@MainActor final class SelectedWordSuggestionTests: XCTestCase {
    typealias Proxy = SwipeIntegrationTests.Proxy
    private func prepared(_ p: Proxy, suggestions: Bool = true) async throws -> KeyboardModel {
        let m = KeyboardModel(proxy: p)
        m.refreshTraits()
        m.apply(KeyboardPreferences(autocorrectEnabled: true, showSuggestions: suggestions, swipeTypingEnabled: false))
        // The shared corrector loads once per process; a typed word shows it has arrived.
        try await waitFor { m.handleTap(.character("q")); m.keyDown(.delete); m.endDeleteRepeat(); return m.isCorrectorReady }
        p.text = ""; p.tail = ""
        return m
    }
    private func waitFor(_ predicate: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("timed out")
    }
    private func select(_ word: String, in m: KeyboardModel, _ p: Proxy, before: String, after: String) async throws {
        p.text = before; p.tail = after; p.selection = word
        m.hostSelectionDidChange()
        try await Task.sleep(for: .milliseconds(150))
    }

    func testSelectedMisspellingShowsItsFix() async throws {
        let p = Proxy(), m = try await prepared(p)
        try await select("tomorow", in: m, p, before: "see you ", after: " soon")
        XCTAssertTrue(m.suggestions.contains { $0.text == "tomorrow" }, "\(m.suggestions)")
        XCTAssertFalse(m.suggestions.contains { $0.autoApplies })
        XCTAssertFalse(m.suggestions.contains { $0.kind == .literal })
    }
    func testTapReplacesOnlyTheSelection() async throws {
        let p = Proxy(), m = try await prepared(p)
        try await select("tomorow", in: m, p, before: "see you ", after: " soon")
        let fix = try XCTUnwrap(m.suggestions.first { $0.text == "tomorrow" })
        m.choose(fix)
        XCTAssertEqual(p.text + p.tail, "see you tomorrow soon")
        XCTAssertNil(p.selection)
        XCTAssertTrue(m.suggestions.isEmpty)
    }
    func testFirstWordOfAFieldWithNilEdges() async throws {
        let p = Proxy(), m = try await prepared(p)
        p.boundaryContextIsNil = true
        try await select("tomorow", in: m, p, before: "", after: "")
        let fix = try XCTUnwrap(m.suggestions.first { $0.text == "tomorrow" })
        m.choose(fix)
        XCTAssertEqual(p.text + p.tail, "tomorrow")
    }
    func testSelectionGoneBeforeTheTapInsertsNothing() async throws {
        let p = Proxy(), m = try await prepared(p)
        try await select("tomorow", in: m, p, before: "a ", after: " b")
        let fix = try XCTUnwrap(m.suggestions.first { $0.text == "tomorrow" })
        p.selection = nil
        m.choose(fix)
        XCTAssertEqual(p.text + p.tail, "a  b")
    }
    func testFieldChangedBeforeTheTapInsertsNothing() async throws {
        let p = Proxy(), m = try await prepared(p)
        try await select("tomorow", in: m, p, before: "a ", after: " b")
        let fix = try XCTUnwrap(m.suggestions.first { $0.text == "tomorrow" })
        p.session = "other"
        m.choose(fix)
        XCTAssertEqual(p.text + p.tail, "a  b")
    }
    func testADifferentSelectionBeforeTheTapInsertsNothing() async throws {
        let p = Proxy(), m = try await prepared(p)
        try await select("tomorow", in: m, p, before: "a ", after: " b")
        let fix = try XCTUnwrap(m.suggestions.first { $0.text == "tomorrow" })
        p.selection = "other"
        m.choose(fix)
        XCTAssertEqual(p.text + p.tail, "a  b")
        XCTAssertEqual(p.selection, "other")
    }
    func testTwoWordsAndPartialWordsShowNothing() async throws {
        let p = Proxy(), m = try await prepared(p)
        try await select("see yuo", in: m, p, before: "", after: "")
        XCTAssertTrue(m.suggestions.isEmpty)
        try await select("morow", in: m, p, before: "to", after: " x")
        XCTAssertTrue(m.suggestions.isEmpty)
        try await select("tomor", in: m, p, before: "a ", after: "ow")
        XCTAssertTrue(m.suggestions.isEmpty)
    }
    func testDeselectingClearsTheRow() async throws {
        let p = Proxy(), m = try await prepared(p)
        try await select("tomorow", in: m, p, before: "a ", after: " b")
        XCTAssertFalse(m.suggestions.isEmpty)
        p.selection = nil; m.hostSelectionDidChange()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(m.suggestions.isEmpty)
    }
    func testFieldsThatRefuseAutocorrectShowNothing() async throws {
        let p = Proxy(), m = try await prepared(p)
        p.allowed = false
        try await select("tomorow", in: m, p, before: "a ", after: " b")
        XCTAssertTrue(m.suggestions.isEmpty)
    }
    func testSuggestionsOffShowsNothing() async throws {
        let p = Proxy(), m = try await prepared(p, suggestions: false)
        try await select("tomorow", in: m, p, before: "a ", after: " b")
        XCTAssertTrue(m.suggestions.isEmpty)
    }
    func testRepeatedSelectAndFix() async throws {
        let p = Proxy(), m = try await prepared(p)
        for _ in 0..<5 {
            try await select("recieve", in: m, p, before: "i ", after: " it")
            let fix = try XCTUnwrap(m.suggestions.first { $0.text == "receive" })
            m.choose(fix)
            XCTAssertEqual(p.text + p.tail, "i receive it")
        }
    }
}
