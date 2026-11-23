// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// Typing gives the same word the answer swipe and dictation give, and a word that ends another
/// path's text is corrected as any typed word is.
@MainActor final class TypingCohesionTests: XCTestCase {
    typealias Proxy = SwipeIntegrationTests.Proxy
    private func prepared(_ p: Proxy) async throws -> KeyboardModel {
        let m = KeyboardModel(proxy: p)
        m.refreshTraits()
        m.apply(KeyboardPreferences(autocorrectEnabled: true, swipeTypingEnabled: false))
        for _ in 0..<200 where !m.isCorrectorReady {
            m.handleTap(.character("q")); m.keyDown(.delete); m.endDeleteRepeat()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(m.isCorrectorReady)
        p.text = ""
        return m
    }
    private func type(_ text: String, _ m: KeyboardModel) {
        for character in text {
            if character == " " { m.handleTap(.space) } else { m.handleTap(.character(String(character))) }
        }
    }

    // MARK: Handles and tags

    func testAPlainTypoIsStillCorrected() async throws {
        let p = Proxy(), m = try await prepared(p)
        type("teh ", m)
        XCTAssertEqual(p.text, "the ")
    }
    func testAHandleIsLeftAsKeyed() async throws {
        let p = Proxy(), m = try await prepared(p)
        type("ask @teh now", m)
        XCTAssertEqual(p.text, "ask @teh now")
    }
    func testATagIsLeftAsKeyed() async throws {
        let p = Proxy(), m = try await prepared(p)
        type("#teh.", m)
        XCTAssertEqual(p.text, "#teh.")
    }
    func testTheWordAfterTheHandleIsCorrectedAgain() async throws {
        let p = Proxy(), m = try await prepared(p)
        type("@sam teh ", m)
        XCTAssertEqual(p.text, "@sam the ")
    }
    func testTagDetection() {
        XCTAssertTrue(KeyboardModel.isTag("teh", before: "ask @teh"))
        XCTAssertTrue(KeyboardModel.isTag("teh", before: "#teh"))
        XCTAssertFalse(KeyboardModel.isTag("teh", before: "ask teh"))
        XCTAssertFalse(KeyboardModel.isTag("teh", before: "@ teh"))
        XCTAssertFalse(KeyboardModel.isTag("teh", before: nil))
        XCTAssertFalse(KeyboardModel.isTag("", before: "@"))
    }

    // MARK: After a dictation

    func testAWordTypedRightAfterADictationIsCorrected() async throws {
        let p = Proxy(), m = try await prepared(p)
        // A word in progress, then the mic inserts text behind the keyboard's back.
        type("ok", m)
        p.insert(" sounds good ")
        m.dictationInserted(" sounds good ")
        type("teh ", m)
        XCTAssertEqual(p.text, "ok sounds good the ")
    }

    // MARK: Kept words

    func testAKeptWordKeepsOnlyInnerCapitals() {
        XCTAssertEqual(SpellingStore.storedForm(of: "OpenRouter"), "OpenRouter")
        XCTAssertEqual(SpellingStore.storedForm(of: "iPhone"), "iPhone")
        XCTAssertEqual(SpellingStore.storedForm(of: "Teh"), "teh", "a sentence-start capital is not the word's")
        XCTAssertEqual(SpellingStore.storedForm(of: "LOL"), "lol")
        XCTAssertEqual(SpellingStore.storedForm(of: "skrrt"), "skrrt")
    }
}
