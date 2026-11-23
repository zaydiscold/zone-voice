// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// A word fixed by hand after a dictation: a slip made while fixing it is not shielded from
/// autocorrect (and so not learned), a word the person insists on is, and the unsure-word check
/// hears of every hand fix.
@MainActor final class CorrectionLearningTests: XCTestCase {
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
    private func backspace(_ count: Int, _ m: KeyboardModel) {
        for _ in 0..<count { m.keyDown(.delete); m.endDeleteRepeat() }
    }
    /// The mic inserts text behind the keyboard's back, then tells the model.
    private func dictate(_ text: String, _ p: Proxy, _ m: KeyboardModel) {
        p.insert(text)
        m.dictationInserted(text)
    }

    func testASlipTypedOverADictatedWordIsCorrectedNotKept() async throws {
        let p = Proxy(), m = try await prepared(p)
        var fixes: [[String]] = []
        m.onWordCorrected = { fixes.append([$0, $1]) }
        dictate("that is defiantly", p, m)
        backspace(9, m)
        type("definitly ", m)
        XCTAssertEqual(p.text, "that is definitely ", "the slip is fixed by the space, as any typed word is")
        XCTAssertEqual(fixes, [["defiantly", "definitly"]], "the unsure-word check still hears of the hand fix")
    }

    func testAWordTypedOverWhatAutocorrectWouldWriteIsKept() async throws {
        let p = Proxy(), m = try await prepared(p)
        var fixes: [[String]] = []
        m.onWordCorrected = { fixes.append([$0, $1]) }
        dictate("on my frostbite", p, m)
        backspace(3, m)
        type("yte ", m)
        XCTAssertEqual(p.text, "on my frostbyte ", "the person refused frostbite, so frostbyte stands")
        XCTAssertEqual(fixes, [["frostbite", "frostbyte"]])
    }

    func testANameTypedWithAChosenCapitalIsKept() async throws {
        let p = Proxy(), m = try await prepared(p)
        dictate("we pay with bricks", p, m)
        backspace(6, m)
        m.handleTap(.shift)
        type("Brex ", m)
        XCTAssertEqual(p.text, "we pay with Brex ", "a capital the person chose marks a name, not a slip")
    }

    func testAnEditElsewhereIsNotAHandFix() async throws {
        let p = Proxy(), m = try await prepared(p)
        var fixes = 0
        m.onWordCorrected = { _, _ in fixes += 1 }
        dictate("sounds good", p, m)
        type(" thanks ", m)
        XCTAssertEqual(fixes, 0)
        XCTAssertEqual(p.text, "sounds good thanks ")
    }
}
