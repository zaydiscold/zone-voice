// by zayd/cold @ zayd.wtf

import XCTest
import UIKit
import ZoneCore

/// Cases the colon picker's own tests left out (review of 2026-11-21): a cursor that moved
/// before Delete, deleting on past a restored code, colons that are not codes, a host that
/// rewrites the code, and a code at the start of a sentence.
@MainActor
final class EmojiShortcodeReviewTests: XCTestCase {
    typealias Proxy = SwipeIntegrationTests.Proxy

    private func make(_ proxy: Proxy, autocorrect: Bool = false) -> KeyboardModel {
        let model = KeyboardModel(proxy: proxy)
        model.refreshTraits()
        model.apply(KeyboardPreferences(autocorrectEnabled: autocorrect, swipeTypingEnabled: false, swipeLearningEnabled: false))
        return model
    }

    private func type(_ text: String, _ model: KeyboardModel) {
        for character in text {
            if character == " " { model.handleTap(.space) } else { model.handleTap(.character(String(character))) }
        }
    }

    private func delete(_ model: KeyboardModel) {
        model.keyDown(.delete)
        model.endDeleteRepeat()
    }

    private func until(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<160 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for \(what)")
    }

    /// Types ":fire" and waits for the picker, so the search is loaded before a closing colon.
    private func openFire(_ model: KeyboardModel) async throws {
        type(":fire", model)
        try await until("the picker") { model.emojiSuggestions.first?.emoji == "🔥" }
    }

    func testOpeningStylesDismissesThePickerAndKeepsTheTypedCode() async throws {
        let proxy = Proxy()
        let model = make(proxy)
        try await openFire(model)
        model.dismissEmojiPickerForStyles()
        XCTAssertNotEqual(model.stripContent(hasUnsureWords: false), .emojiPicker)
        XCTAssertEqual(proxy.text, ":fire")
        for _ in 0..<5 { delete(model) }
        XCTAssertTrue(model.emojiSuggestions.isEmpty)
    }

    func testDeleteAfterTheCursorMovedDeletesACharacterAndNeverRestoresTheCode() async throws {
        for hostSaysSo in [true, false] {
            let proxy = Proxy()
            proxy.text = "Hi "
            let model = make(proxy)
            try await openFire(model)
            type(":", model)
            XCTAssertEqual(proxy.text, "Hi 🔥")
            // The person taps earlier in the text: the caret now sits after "Hi", before the emoji.
            proxy.text = "Hi"
            proxy.tail = " 🔥"
            if hostSaysSo { model.hostSelectionDidChange() }
            delete(model)
            XCTAssertEqual(proxy.text + proxy.tail, "H 🔥", "hostSaysSo \(hostSaysSo)")
            model.keyboardWillDisappear()
        }
    }

    func testDeleteInAnotherFieldNeverRestoresTheCode() async throws {
        let proxy = Proxy()
        let model = make(proxy)
        try await openFire(model)
        type(":", model)
        XCTAssertEqual(proxy.text, "🔥")
        // Another field that happens to end the same way.
        proxy.session = "other"
        delete(model)
        XCTAssertEqual(proxy.text, "")
        model.keyboardWillDisappear()
    }

    func testDeletingOnPastARestoredCodeEmptiesTheField() async throws {
        let proxy = Proxy()
        let model = make(proxy)
        try await openFire(model)
        type(":", model)
        XCTAssertEqual(proxy.text, "🔥")
        delete(model)
        XCTAssertEqual(proxy.text, ":fire:")
        for expected in [":fire", ":fir", ":fi", ":f", ":", "", ""] {
            delete(model)
            XCTAssertEqual(proxy.text, expected)
        }
        XCTAssertTrue(model.emojiSuggestions.isEmpty)
        type("ok", model)
        XCTAssertEqual(proxy.text, "ok")
        model.keyboardWillDisappear()
    }

    func testATypedKeyAfterTheEmojiEndsTheUndo() async throws {
        let proxy = Proxy()
        let model = make(proxy)
        try await openFire(model)
        type(":", model)
        type("a", model)
        delete(model)
        XCTAssertEqual(proxy.text, "🔥")
        delete(model)
        XCTAssertEqual(proxy.text, "", "the second Delete removes the emoji, it does not bring the code back")
        model.keyboardWillDisappear()
    }

    func testColonsThatAreNotCodesStayAsTyped() async throws {
        let proxy = Proxy()
        let model = make(proxy)
        // Make sure the search is loaded, so a wrong conversion could happen.
        try await openFire(model)
        for _ in 0..<5 { delete(model) }
        XCTAssertEqual(proxy.text, "")
        for text in ["3:30 ", "at 12:fire: ", "note:fire: ", "https://fire: ", "ok :) ", "a :d ", "x :-) ", "ratio 1:100: "] {
            let before = proxy.text
            type(text, model)
            XCTAssertEqual(proxy.text, before + text, text)
            XCTAssertTrue(model.emojiSuggestions.isEmpty, text)
        }
        model.keyboardWillDisappear()
    }

    func testAHostThatRewritesTheCodeCancelsIt() async throws {
        let proxy = Proxy()
        proxy.text = "Hi "
        let model = make(proxy)
        try await openFire(model)
        // A web editor rewrites what was typed (its own autocorrect, a mention popup).
        proxy.text = "Hi :Fire"
        model.hostTextDidChange()
        XCTAssertTrue(model.emojiSuggestions.isEmpty)
        type(":", model)
        XCTAssertEqual(proxy.text, "Hi :Fire:")
        model.keyboardWillDisappear()
    }

    func testACodeAtTheStartOfASentenceIsLowercaseAndConverts() async throws {
        let proxy = Proxy()
        proxy.capitalizes = true
        let model = make(proxy)
        var preferences = KeyboardPreferences(autocorrectEnabled: false, swipeTypingEnabled: false, swipeLearningEnabled: false)
        preferences.autoCapitalizationEnabled = true
        model.apply(preferences)
        model.refreshTraits()
        XCTAssertTrue(model.shift.isActive, "an empty field starts with Shift on")
        try await openFire(model)
        XCTAssertEqual(proxy.text, ":fire")
        type(":", model)
        XCTAssertEqual(proxy.text, "🔥")
        model.keyboardWillDisappear()
    }

    func testASelectionIsReplacedByAnOrdinaryColon() async throws {
        let proxy = Proxy()
        proxy.text = "Hi "
        proxy.selection = "there"
        let model = make(proxy)
        type(":fire", model)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(model.emojiSuggestions.isEmpty)
        XCTAssertEqual(proxy.text, "Hi :fire")
        model.keyboardWillDisappear()
    }
}
