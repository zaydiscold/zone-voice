// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// Smart punctuation through the keyboard's own typing path: the keys, autocorrect and Backspace.
@MainActor final class SmartPunctuationTypingTests: XCTestCase {
    typealias Proxy = SwipeIntegrationTests.Proxy
    private func model(_ p: Proxy, smart: Bool = true, autocorrect: Bool = false) -> KeyboardModel {
        let m = KeyboardModel(proxy: p)
        m.refreshTraits()
        m.apply(KeyboardPreferences(autocorrectEnabled: autocorrect, swipeTypingEnabled: false, smartPunctuation: smart))
        return m
    }
    private func type(_ text: String, _ m: KeyboardModel) {
        for character in text {
            switch character {
            case " ": m.handleTap(.space)
            case "\n": m.handleTap(.newline)
            default: m.handleTap(.character(String(character)))
            }
        }
    }
    private func backspace(_ m: KeyboardModel) { m.keyDown(.delete); m.endDeleteRepeat() }

    func testOffByDefaultTypesExactlyWhatWasKeyed() {
        let p = Proxy(), m = model(p, smart: false)
        type("he said \"it's\"--ok... 'tis ", m)
        XCTAssertEqual(p.text, "he said \"it's\"--ok... 'tis ")
        XCTAssertFalse(KeyboardPreferences().smartPunctuation)
    }
    func testQuotesDashesAndEllipsis() {
        let p = Proxy(), m = model(p)
        type("he said \"it's\"--ok... (\"yes\")", m)
        XCTAssertEqual(p.text, "he said \u{201C}it\u{2019}s\u{201D}\u{2014}ok\u{2026} (\u{201C}yes\u{201D})")
    }
    func testLeadingApostrophes() {
        let p = Proxy(), m = model(p)
        type("'tis the '90s, rock 'n' roll", m)
        XCTAssertEqual(p.text, "\u{2019}tis the \u{2019}90s, rock \u{2019}n\u{2019} roll")
    }
    func testMeasurementsAndAddressesStayStraight() {
        let p = Proxy(), m = model(p)
        type("6'2\" at https://a.com/?q='x'--y", m)
        XCTAssertEqual(p.text, "6'2\" at https://a.com/?q='x'--y")
    }
    func testBackspaceAfterADashPutsTheHyphensBack() {
        let p = Proxy(), m = model(p)
        type("wait--", m)
        XCTAssertEqual(p.text, "wait\u{2014}")
        backspace(m)
        XCTAssertEqual(p.text, "wait--")
        backspace(m)
        XCTAssertEqual(p.text, "wait-")
        type("-", m)
        XCTAssertEqual(p.text, "wait\u{2014}", "the dash can be made again")
    }
    func testBackspaceAfterAnEllipsisPutsThePeriodsBack() {
        let p = Proxy(), m = model(p)
        type("so...", m); backspace(m)
        XCTAssertEqual(p.text, "so...")
    }
    func testBackspaceAfterACurlyQuoteJustDeletesIt() {
        let p = Proxy(), m = model(p)
        type("a \"", m); backspace(m)
        XCTAssertEqual(p.text, "a ")
    }
    func testALaterBackspaceIsAnOrdinaryDelete() {
        let p = Proxy(), m = model(p)
        type("a--b", m); backspace(m); backspace(m)
        XCTAssertEqual(p.text, "a")
    }
    func testFieldThatRefusesQuotesKeepsThemStraight() {
        let p = Proxy(); p.smartQuotes = false
        let m = model(p)
        type("\"a\"--b", m)
        XCTAssertEqual(p.text, "\"a\"\u{2014}b")
    }
    func testFieldThatRefusesDashesKeepsHyphens() {
        let p = Proxy(); p.smartDashes = false
        let m = model(p)
        type("\"a\"--b...", m)
        XCTAssertEqual(p.text, "\u{201C}a\u{201D}--b...")
    }
    func testUnknownContextChangesNothing() {
        let p = Proxy(), m = model(p)
        p.text = "existing"; p.unknown = true
        m.hostSelectionDidChange()
        let expectation = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
        type("\"", m)
        XCTAssertTrue(p.text.hasSuffix("\""), p.text)
    }
    func testQuoteAfterTextAlreadyInTheField() {
        let p = Proxy(); p.text = "she said "
        let m = model(p)
        type("\"no\"", m)
        XCTAssertEqual(p.text, "she said \u{201C}no\u{201D}")
    }
    func testFastMixedTypingKeepsEveryKey() {
        let p = Proxy(), m = model(p)
        let line = "\"don't\"--'90s... "
        for _ in 0..<40 { type(line, m) }
        let once = "\u{201C}don\u{2019}t\u{201D}\u{2014}\u{2019}90s\u{2026} "
        XCTAssertEqual(p.text, String(repeating: once, count: 40))
    }
}
