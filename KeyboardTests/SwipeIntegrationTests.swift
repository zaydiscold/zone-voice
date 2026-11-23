// by zayd/cold @ zayd.wtf

import XCTest
import UIKit
import ZoneCore

@MainActor
final class SwipeIntegrationTests: XCTestCase {
    final class Proxy: TextProxyActions {
        var text = ""
        var tail = ""
        var session = "a"
        var allowed = true
        var swipeAllowed = true
        var capitalizes = false
        var emptyContextIsNil = false
        var boundaryContextIsNil = false
        var contextLimit: Int?
        var unknown = false
        var selection: String?
        var onCursorAdjustment: (() -> Void)?
        var cursorAdjustments: [Int] = []
        var defersCursorAdjustments = false
        private var queuedCursorAdjustments: [Int] = []
        func userTouchedKeyboard() {}
        /// UIKit replaces a selection with the inserted text; the fake keeps the selection apart
        /// from `text` and `tail`, so replacing it is dropping it.
        func insert(_ text: String) { selection = nil; self.text += text }
        /// A web view: the move lands, but the context reads stay stale until a later turn.
        var lagsContext = false
        /// UITextView: context stops at the caret's own paragraph (verified Nov 8 on the
        /// simulator: "five six|" reads as "five six" in "one two\nthree four\nfive six").
        var paragraphContext = false
        private var staleContext: (before: String, after: String)?
        func adjustTextPosition(byCharacterOffset offset: Int) {
            cursorAdjustments.append(offset)
            if defersCursorAdjustments { queuedCursorAdjustments.append(offset); return }
            if lagsContext, staleContext == nil {
                staleContext = (text, tail)
                DispatchQueue.main.async { [weak self] in self?.staleContext = nil }
            }
            applyCursorAdjustment(offset)
        }
        /// The host applies the oldest move it has been sent, as it reports them one at a time.
        func settleNextCursorAdjustment() {
            guard !queuedCursorAdjustments.isEmpty else { return }
            applyCursorAdjustment(queuedCursorAdjustments.removeFirst())
        }
        func settleCursorAdjustments() {
            let queued = queuedCursorAdjustments
            queuedCursorAdjustments.removeAll()
            for offset in queued { applyCursorAdjustment(offset) }
        }
        private func applyCursorAdjustment(_ offset: Int) {
            selection = nil // UIKit collapses a selection when the caret moves
            let joined = (text + tail) as NSString
            let position = min(joined.length, max(0, text.utf16.count + offset))
            text = joined.substring(to: position)
            tail = joined.substring(from: position)
            onCursorAdjustment?()
        }
        func deleteBackward() { if !text.isEmpty { text.removeLast() } }
        func contextBefore() -> String? {
            if let staleContext {
                let before = paragraphContext ? String(staleContext.before.reversed().prefix(while: { !$0.isNewline }).reversed()) : staleContext.before
                return before.isEmpty && boundaryContextIsNil ? nil : before
            }
            return liveBefore()
        }
        func contextAfter() -> String? {
            if let staleContext {
                let after = paragraphContext ? String(staleContext.after.prefix(while: { !$0.isNewline })) : staleContext.after
                return after.isEmpty && boundaryContextIsNil ? nil : after
            }
            return liveAfter()
        }
        private func liveBefore() -> String? {
            guard paragraphContext else { return rawBefore() }
            return rawBefore().map { String($0.reversed().prefix(while: { !$0.isNewline }).reversed()) }
        }
        private func liveAfter() -> String? {
            guard paragraphContext else { return rawAfter() }
            return rawAfter().map { String($0.prefix(while: { !$0.isNewline })) }
        }
        private func rawBefore() -> String? { unknown || ((emptyContextIsNil || boundaryContextIsNil) && text.isEmpty) ? nil : contextLimit.map { String(text.suffix($0)) } ?? text }
        private func rawAfter() -> String? { unknown || (emptyContextIsNil && text.isEmpty) || (boundaryContextIsNil && tail.isEmpty) ? nil : tail }
        func fieldHasText() -> Bool { !text.isEmpty || !tail.isEmpty || selection?.isEmpty == false }
        func selectedText() -> String? { selection }
        func currentInputSession() -> String? { session }
        var returnKeyLabel: String { "return" }
        var autocapitalizesSentences: Bool { capitalizes }
        var fieldNeverCapitalizes: Bool { !capitalizes }
        var allowsAutocorrection: Bool { allowed }
        var allowsSwipeTyping: Bool { swipeAllowed }
        var smartQuotes = true, smartDashes = true
        var allowsSmartQuotes: Bool { smartQuotes }
        var allowsSmartDashes: Bool { smartDashes }
        var prefersNumbers: Bool { false }
        var fieldKeys: [String] = []
        var fieldCapitalization: FieldCapitalization?
        var capitalization: FieldCapitalization { fieldCapitalization ?? (capitalizes ? .sentences : .none) }
        var isSearchField = false
        var dimsReturnWhenEmpty = false
        var hasOpenAccess = false
        var explicitDarkAppearance: Bool? { nil }
        var needsGlobeKey: Bool { false }
        func advanceToNextInputMode() {}
        func playClick() {}
        func open(_ url: URL) {}
    }
    let layout = SwipeLayout.qwerty()
    func path(_ word: String) -> [SwipePoint] {
        let keys = word.utf8.map { Int($0 - 97) }
        var result: [SwipePoint] = []
        for i in 0..<keys.count - 1 {
            for j in 0..<10 {
                let a = Float(j) / 10, k = keys[i], n = keys[i + 1]
                result.append(SwipePoint(x: layout.x[k] + a * (layout.x[n] - layout.x[k]),
                    y: layout.y[k] + a * (layout.y[n] - layout.y[k]), t: Float(result.count) / 60))
            }
        }
        result.append(SwipePoint(x: layout.x[keys.last!], y: layout.y[keys.last!], t: Float(result.count) / 60))
        return result
    }
    func prepared(_ p: Proxy) -> KeyboardModel {
        let m = KeyboardModel(proxy: p)
        m.refreshTraits()
        m.apply(KeyboardPreferences(autocorrectEnabled: false, swipeTypingEnabled: true, swipeLearningEnabled: false))
        return m
    }
    func waitFor(_ predicate: @escaping () -> Bool) async throws {
        for _ in 0..<150 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for decoder / queued input")
    }
    func swipe(_ m: KeyboardModel, _ p: Proxy, _ word: String = "hello") async throws {
        let before = p.text
        m.handleSwipe(path(word), layout: layout)
        try await waitFor { p.text != before }
    }
    /// Contacts called "The Old Man" and "Mom And Dad" hand the keyboard "The", "Man" and "And" as
    /// terms. The reported message read "No I have to fight The old Man".
    func testOrdinaryWordsOnContactCardsSwipeLowercase() async throws {
        // A field that capitalizes sentences, as Messages does; a lowercase-only field hides the bug.
        let p = Proxy(); p.capitalizes = true; p.text = "No I have to fight "
        let m = prepared(p)
        m.applySystemLexicon(["The", "Old", "Man", "And", "From", "Nita"].map { (input: $0.lowercased(), text: $0) })
        try await swipe(m, p, "the")
        try await swipe(m, p, "old")
        try await swipe(m, p, "man")
        try await swipe(m, p, "and")
        try await swipe(m, p, "nita")
        XCTAssertEqual(p.text, "No I have to fight the old man and Nita")
        m.keyboardWillDisappear()
    }
    /// Zayd, November 15: "Baby I'm getting a USB From micro Center". A swiped word that finishes
    /// a name of ordinary words writes the whole name, whether the word before was swiped or typed.
    func testASwipedWordFinishesATwoWordName() async throws {
        let p = Proxy(); p.capitalizes = true; p.text = "Getting a USB from "
        let m = prepared(p)
        m.apply(KeyboardPreferences(autocorrectEnabled: true, swipeTypingEnabled: true, swipeLearningEnabled: false))
        m.applySystemLexicon(["From", "Center"].map { (input: $0.lowercased(), text: $0) })
        try await swipe(m, p, "micro")
        try await swipe(m, p, "center")
        XCTAssertEqual(p.text, "Getting a USB from Micro Center")
        try await swipe(m, p, "today")
        XCTAssertEqual(p.text, "Getting a USB from Micro Center today")
        // The word before typed by hand, then the swipe.
        p.text = "at taco "
        try await swipe(m, p, "bell")
        XCTAssertEqual(p.text, "at Taco Bell")
        // Deleting the swipe removes only the swiped word.
        m.hostTextDidChange(); m.hostSelectionDidChange()
        m.keyDown(.delete); m.endDeleteRepeat()
        XCTAssertEqual(p.text, "at Taco ")
        m.keyboardWillDisappear()
    }
    /// A field that keeps typing lowercase, or autocorrect turned off, leaves the words as swiped.
    func testATwoWordNameStaysAsSwipedWhereCasingIsTheWriters() async throws {
        let lower = Proxy(); lower.text = "from micro "
        let m = prepared(lower)
        m.apply(KeyboardPreferences(autocorrectEnabled: true, swipeTypingEnabled: true, swipeLearningEnabled: false))
        try await swipe(m, lower, "center")
        XCTAssertEqual(lower.text, "from micro center")
        m.keyboardWillDisappear()
        let off = Proxy(); off.capitalizes = true; off.text = "From micro "
        let n = prepared(off)
        try await swipe(n, off, "center")
        XCTAssertEqual(off.text, "From micro center")
        n.keyboardWillDisappear()
    }
    func testAContactSurnameThatIsAWordSwipesCapitalAfterAFirstName() async throws {
        let p = Proxy(); p.capitalizes = true; p.text = "I saw the "
        let m = prepared(p)
        m.applySystemLexicon(["Sarah", "Brown"].map { (input: $0.lowercased(), text: $0) })
        try await swipe(m, p, "brown")
        try await swipe(m, p, "house")
        try await swipe(m, p, "with")
        try await swipe(m, p, "sarah")
        try await swipe(m, p, "brown")
        XCTAssertEqual(p.text, "I saw the brown house with Sarah Brown")
        m.keyboardWillDisappear()
    }
    func testNilDocumentBoundaryPreservesSwipeOwnershipAndSpacing() async throws {
        let p = Proxy(); p.boundaryContextIsNil = true; p.text = "hi "
        let m = prepared(p)
        XCTAssertTrue(m.canBeginSwipe)
        try await swipe(m, p)
        XCTAssertEqual(p.text, "hi hello")
        m.hostTextDidChange(); m.hostSelectionDidChange()
        m.keyDown(.delete); m.endDeleteRepeat()
        XCTAssertEqual(p.text, "hi ")
        try await swipe(m, p)
        m.handleTap(.character("x"))
        XCTAssertEqual(p.text, "hi hello x")
        p.unknown = true
        XCTAssertFalse(m.canBeginSwipe)
        m.keyboardWillDisappear()
    }
    func testNilBeforeKnownTailCanSwipeButTailChangeRejectsQueuedEdits() async throws {
        let p = Proxy(); p.boundaryContextIsNil = true; p.tail = "existing"
        let m = prepared(p)
        XCTAssertTrue(m.canBeginSwipe)
        m.handleSwipe(path("hello"), layout: layout)
        m.handleTap(.character("x"))
        p.tail = "changed"
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(p.text, "")
        XCTAssertEqual(p.tail, "changed")
        m.keyboardWillDisappear()
    }
    func testOwnEchoPreservesAlternativesAndWholeWordDelete() async throws {
        let p = Proxy(), m = prepared(p)
        try await swipe(m, p)
        XCTAssertEqual(p.text, "hello")
        m.hostTextDidChange()
        XCTAssertTrue(m.hasSwipeAlternatives)
        let chosen = try XCTUnwrap(m.suggestions.last)
        m.choose(chosen)
        XCTAssertEqual(p.text, chosen.text)
        for _ in 0..<10 { m.hostTextDidChange() } // replacement may echo once per deletion
        XCTAssertTrue(m.hasSwipeAlternatives)
        m.hostTextDidChange()
        m.keyDown(.delete); m.endDeleteRepeat()
        XCTAssertEqual(p.text, "")
        m.keyboardWillDisappear()
    }
    func testFastSwipeTapAndEarlierEchoPreserveOrder() async throws {
        let p = Proxy(), m = prepared(p)
        try await swipe(m, p)
        m.handleSwipe(path("world"), layout: layout)
        m.handleTap(.character("x"))
        m.hostTextDidChange() // deferred own echo from hello, while world and x are queued
        m.hostSelectionDidChange() // another host echo beyond the estimated callback count
        try await waitFor { p.text.hasSuffix("x") }
        XCTAssertEqual(p.text, "hello world x")
        m.keyboardWillDisappear()
    }
    func testFreshEmptyNilContextAndUnknownNonemptyContext() async throws {
        let p = Proxy(); p.emptyContextIsNil = true
        let m = prepared(p)
        try await swipe(m, p)
        XCTAssertEqual(p.text, "hello")
        m.keyDown(.delete); m.endDeleteRepeat()
        XCTAssertEqual(p.text, "")
        p.text = "private"; p.unknown = true
        XCTAssertFalse(m.canBeginSwipe)
        m.handleSwipe(path("hello"), layout: layout)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(p.text, "private")
        m.keyboardWillDisappear()
    }
    func testSwipeThenPunctuationAndSingleSpace() async throws {
        let p = Proxy(), m = prepared(p)
        try await swipe(m, p)
        m.hostTextDidChange()
        m.handleTap(.character("!"))
        XCTAssertEqual(p.text, "hello!")
        m.handleTap(.space)
        m.handleTap(.character("w"))
        XCTAssertEqual(p.text, "hello! w")
        m.keyboardWillDisappear()
    }
    func testSwipeThenTapPaysSpaceOnce() async throws {
        let p = Proxy(), m = prepared(p)
        try await swipe(m, p)
        m.hostTextDidChange()
        m.handleTap(.character("w")); m.handleTap(.character("e"))
        XCTAssertEqual(p.text, "hello we")
        m.keyboardWillDisappear()
    }
    func testGestureTokenRejectsFieldAndSelectionChangesBeforeLift() async throws {
        let p = Proxy(), m = prepared(p)
        let token = m.swipeInputToken
        p.session = "b"; m.hostTextDidChange()
        m.handleSwipe(path("hello"), layout: layout, token: token)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(p.text, "")
        let next = m.swipeInputToken
        p.selection = "selected"; m.hostSelectionDidChange()
        m.handleSwipe(path("hello"), layout: layout, token: next)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(p.text, "")
        m.keyboardWillDisappear()
    }
    func testCursorMoveInsideOwnEchoWindowInvalidatesGestureBeforeLift() async throws {
        let p = Proxy(), m = prepared(p)
        try await swipe(m, p)
        let token = m.swipeInputToken
        p.text = "he"; p.tail = "llo"
        m.hostSelectionDidChange()
        m.handleSwipe(path("world"), layout: layout, token: token)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(p.text, "he")
        XCTAssertFalse(m.hasSwipeAlternatives)
        m.keyboardWillDisappear()
    }
    func testTruncatedOwnEchoPreservesQueuedSwipeAndTap() async throws {
        let p = Proxy(); p.text = String(repeating: "word ", count: 12); p.contextLimit = 50
        let prefix = p.text
        let m = prepared(p)
        try await swipe(m, p)
        m.handleSwipe(path("world"), layout: layout)
        m.handleTap(.character("x"))
        m.hostTextDidChange()
        try await waitFor { p.text.hasSuffix("x") }
        XCTAssertEqual(p.text, prefix + "hello world x")
        m.keyboardWillDisappear()
    }
    func testLateFieldCallbackCannotSendQueuedEditsIntoNewField() async throws {
        let p = Proxy(), m = prepared(p)
        m.handleSwipe(path("hello"), layout: layout)
        m.keyDown(.delete); m.endDeleteRepeat()
        m.handleTap(.character("x")); m.insertPasted("paste"); m.insertEmoji("🙂")
        p.session = "b"; p.text = "destination"
        // Deliberately no host callback: completion must validate ownership itself.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(p.text, "destination")
        m.keyboardWillDisappear()
    }
    func testFieldChangeDuringDecodeRejectsLateResult() async throws {
        let p = Proxy(), m = prepared(p)
        m.handleSwipe(path("hello"), layout: layout)
        p.session = "b"; m.hostTextDidChange()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(p.text, "")
        m.keyboardWillDisappear()
    }
    func testDeleteReleasedBeforeDecodeDoesNotKeepRepeating() async throws {
        let p = Proxy(); p.text = "keep"
        let m = prepared(p)
        m.handleSwipe(path("hello"), layout: layout)
        m.keyDown(.delete); m.endDeleteRepeat()
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(p.text, "keep")
        m.keyboardWillDisappear()
    }
    func testDeleteHeldThroughDecodeRepeats() async throws {
        let p = Proxy(); p.text = "keep"
        let m = prepared(p)
        m.handleSwipe(path("hello"), layout: layout)
        m.keyDown(.delete)
        try await Task.sleep(for: .milliseconds(900))
        m.endDeleteRepeat()
        XCTAssertLessThan(p.text.count, 4)
        m.keyboardWillDisappear()
    }
    func testSwipeHonorsDisabledAutoCapitalizationAndManualShift() async throws {
        let p = Proxy(); p.text = "end."; p.capitalizes = true
        let m = prepared(p)
        m.apply(KeyboardPreferences(autocorrectEnabled: false, swipeTypingEnabled: true,
            swipeLearningEnabled: false, autoCapitalizationEnabled: false))
        try await swipe(m, p)
        XCTAssertEqual(p.text, "end. hello")
        m.handleTap(.shift)
        try await swipe(m, p, "world")
        XCTAssertEqual(p.text, "end. hello World")
        try await swipe(m, p, "london")
        XCTAssertTrue(p.text.hasSuffix(" london"), p.text)
        m.keyboardWillDisappear()
    }
    /// Search bars and address bars turn autocorrection off (Messages, Passwords, Safari, Chrome).
    /// Swipes there used to type the first letter under the finger and nothing else (2026-11-10).
    func testSearchFieldWithAutocorrectionOffStillSwipes() async throws {
        let p = Proxy(); p.emptyContextIsNil = true; p.allowed = false
        let m = KeyboardModel(proxy: p)
        m.refreshTraits()
        m.apply(KeyboardPreferences(swipeTypingEnabled: true, swipeLearningEnabled: false))
        XCTAssertTrue(m.canBeginSwipe)
        try await swipe(m, p)
        XCTAssertEqual(p.text, "hello")
        try await swipe(m, p, "world")
        XCTAssertEqual(p.text, "hello world")
        // The field's own choice still holds for taps: nothing is corrected.
        for c in " teh " { m.handleTap(c == " " ? .space : .character(String(c))) }
        XCTAssertEqual(p.text, "hello world teh ")
        m.keyboardWillDisappear()
    }
    /// An address bar: swipe a word, tap the period on the letters layer, swipe the next word.
    /// The period joins them like any punctuation key and never takes the keys to another layer.
    func testAddressBarHasAPeriodBesideSpaceThatJoinsSwipedWords() async throws {
        let p = Proxy(); p.emptyContextIsNil = true; p.allowed = false
        let m = KeyboardModel(proxy: p)
        m.refreshTraits()
        m.apply(KeyboardPreferences(swipeTypingEnabled: true, swipeLearningEnabled: false))
        XCTAssertFalse(m.rows[3].contains(.character(".")))
        p.fieldKeys = ["."]
        m.refreshTraits()
        let bottom = m.rows[3]
        XCTAssertEqual(bottom.firstIndex(of: .character(".")), bottom.firstIndex(of: .space).map { $0 + 1 })
        try await swipe(m, p, "example")
        m.handleTap(.character("."))
        for c in "com" { m.handleTap(.character(String(c))) }
        XCTAssertEqual(p.text, "example.com")
        XCTAssertEqual(m.layer, .letters)
        m.handleTap(.switchLayer(.numbers, label: "123"))
        XCTAssertEqual(m.rows[3].filter { $0 == .character(".") }.count, 0)
        m.keyboardWillDisappear()
    }
    /// Safari and Chrome open the address bar with the whole address selected and report no
    /// text on either side of it (seen on the simulator, 2026-11-10). A swipe replaces it.
    func testSwipeReplacesTheSelectedAddress() async throws {
        let p = Proxy(); p.emptyContextIsNil = true; p.allowed = false
        p.selection = "https://example.com"
        let m = KeyboardModel(proxy: p)
        m.refreshTraits()
        m.apply(KeyboardPreferences(swipeTypingEnabled: true, swipeLearningEnabled: false))
        XCTAssertTrue(m.canBeginSwipe)
        try await swipe(m, p)
        XCTAssertEqual(p.text, "hello")
        XCTAssertNil(p.selection)
        try await swipe(m, p, "world")
        XCTAssertEqual(p.text, "hello world")
        m.keyboardWillDisappear()
    }
    /// The selection a swipe started over is the one it replaces: another one made while the
    /// word was being decoded is left alone.
    func testSelectionChangedDuringDecodeIsNotReplaced() async throws {
        let p = Proxy(); p.text = "one "; p.selection = "two"
        let m = prepared(p)
        m.handleSwipe(path("hello"), layout: layout)
        p.selection = "three"
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(p.text, "one ")
        XCTAssertEqual(p.selection, "three")
        m.keyboardWillDisappear()
    }
    /// A name field asks for a capital on every word, a code field for all capitals.
    func testWordAndAllCapitalFieldsSetShiftForTapsAndSwipes() async throws {
        let p = Proxy(); p.fieldCapitalization = .words
        let m = prepared(p)
        XCTAssertTrue(m.shift.isActive)
        for c in "ada" { m.handleTap(.character(String(c))) }
        m.handleTap(.space)
        XCTAssertTrue(m.shift.isActive)
        try await swipe(m, p, "world")
        XCTAssertEqual(p.text, "Ada World")
        m.keyboardWillDisappear()

        let q = Proxy(); q.fieldCapitalization = .allCharacters
        let n = prepared(q)
        for c in "ab" { n.handleTap(.character(String(c))) }
        try await swipe(n, q)
        XCTAssertEqual(q.text, "AB HELLO")
        n.keyboardWillDisappear()

        XCTAssertFalse(FieldCapitalization.words.capitalizesNext(after: "Ada"))
        XCTAssertTrue(FieldCapitalization.sentences.capitalizesNext(after: "Done. "))
        XCTAssertFalse(FieldCapitalization.none.capitalizesNext(after: ""))
        XCTAssertEqual(FieldCapitalization.words.dictated(" ada lovelace"), " Ada Lovelace")
        XCTAssertEqual(FieldCapitalization.allCharacters.dictated("ab 12"), "AB 12")
        XCTAssertEqual(FieldCapitalization.sentences.dictated("the iPhone"), "the iPhone")
    }
    /// URL fields add a slash, social fields @ and #. Emoji gives way only when Paste is there too.
    func testFieldKeysFollowTheKeyboardType() {
        let url = KeyboardLayout.rows(for: .letters, shifted: false, needsGlobe: true, pasteKey: true, emojiKey: true, fieldKeys: [".", "/"])[3]
        XCTAssertEqual(url, [.switchLayer(.numbers, label: "123"), .globe, .space, .character("."), .character("/"), .paste, .newline])
        let social = KeyboardLayout.rows(for: .letters, shifted: false, needsGlobe: false, emojiKey: true, fieldKeys: ["@", "#"])[3]
        XCTAssertEqual(social, [.switchLayer(.numbers, label: "123"), .emoji, .space, .character("@"), .character("#"), .newline])
        let numbers = KeyboardLayout.rows(for: .numbers, shifted: false, needsGlobe: false, fieldKeys: [".", "/"])[3]
        XCTAssertEqual(numbers, [.switchLayer(.letters, label: "ABC"), .space, .newline])
    }
    /// A search bar has no use for return while it is empty.
    func testReturnDimsOnAnEmptySearchBarAndWakesWithText() async throws {
        let p = Proxy(); p.dimsReturnWhenEmpty = true
        let m = prepared(p)
        XCTAssertFalse(m.returnEnabled)
        m.handleTap(.character("a"))
        try await waitFor { m.returnEnabled }
        m.keyDown(.delete); m.endDeleteRepeat()
        try await waitFor { !m.returnEnabled }
        p.dimsReturnWhenEmpty = false
        m.refreshTraits()
        XCTAssertTrue(m.returnEnabled)
        m.keyboardWillDisappear()
    }
    /// The host makes a new keyboard for nearly every appearance, and all of them share one decoder
    /// whose personal index is rebuilt only when the word list changes (`SwipeEngine.indexedWords`).
    /// Each appearance must still swipe its own names: the same list again keeps the index, a list
    /// without a name drops it, and the name comes back with the list that has it. The earlier
    /// keyboards stay alive while the next one decodes, as the outgoing controller does.
    func testEachAppearanceSwipesItsOwnNamesOnTheSharedDecoder() async throws {
        let name = [(input: "zeltrova", text: "Zeltrova")]
        var kept: [KeyboardModel] = []
        func appearance(_ lexicon: [(input: String, text: String)]) -> (Proxy, KeyboardModel) {
            let p = Proxy(), m = prepared(p)
            m.applySystemLexicon(lexicon)
            kept.append(m)
            return (p, m)
        }
        for round in 1...3 {
            let (p, m) = appearance(name)
            try await swipe(m, p, "zeltrova")
            XCTAssertEqual(p.text.lowercased(), "zeltrova", "appearance \(round) with the name")
            try await swipe(m, p, "world")
            XCTAssertEqual(p.text.lowercased(), "zeltrova world", "appearance \(round) with the name")
            m.keyboardWillDisappear()
        }
        let (p, m) = appearance([])
        try await swipe(m, p, "zeltrova")
        XCTAssertNotEqual(p.text.lowercased(), "zeltrova", "a list without the name must rebuild the index")
        m.keyboardWillDisappear()
        let (p2, m2) = appearance(name)
        try await swipe(m2, p2, "zeltrova")
        XCTAssertEqual(p2.text.lowercased(), "zeltrova", "the name comes back with its list")
        m2.keyboardWillDisappear()
        XCTAssertEqual(kept.count, 5)
    }
    /// Two keyboards up at once take turns on the shared decoder: each decode puts its own words
    /// back first, even though the skip keeps an equal list from being rebuilt.
    func testTwoLiveKeyboardsTakeTurnsWithTheirOwnNames() async throws {
        let pa = Proxy(), a = prepared(pa)
        a.applySystemLexicon([(input: "zeltrova", text: "Zeltrova")])
        let pb = Proxy(), b = prepared(pb)
        b.applySystemLexicon([])
        for round in 1...3 {
            pa.text = ""; pb.text = ""
            try await swipe(a, pa, "zeltrova")
            XCTAssertEqual(pa.text.lowercased(), "zeltrova", "round \(round): the keyboard with the name")
            try await swipe(b, pb, "zeltrova")
            XCTAssertNotEqual(pb.text.lowercased(), "zeltrova", "round \(round): the keyboard without it")
        }
        a.keyboardWillDisappear()
        b.keyboardWillDisappear()
    }
    func testSensitiveFieldAndSwipeDisabledDoNotDecode() async throws {
        let p = Proxy(), m = prepared(p)
        p.allowed = false
        p.swipeAllowed = false
        XCTAssertFalse(m.canSwipe)
        m.handleSwipe(path("hello"), layout: layout)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(p.text, "")
        p.allowed = true
        p.swipeAllowed = true
        m.apply(KeyboardPreferences())
        XCTAssertFalse(m.canSwipe)
        m.keyboardWillDisappear()
    }
}

extension SwipeIntegrationTests {
    private func learningModel(_ p: Proxy, enabled: Bool = true) -> KeyboardModel {
        let m = prepared(p)
        var prefs = m.preferences
        prefs.swipeLearningEnabled = enabled
        prefs.swipeLearningReset = UUID().uuidString
        m.apply(prefs)
        return m
    }
    private func swipeLearning() -> SwipeLearning {
        guard let data = UserDefaults.standard.data(forKey: "zone.swipe.corrections.v1"),
              let learning = try? JSONDecoder().decode(SwipeLearning.self, from: data) else { return SwipeLearning() }
        return learning
    }
    private func replaceSwipe(_ m: KeyboardModel, with word: String) {
        m.keyDown(.delete); m.endDeleteRepeat()
        for c in word { m.handleTap(.character(String(c))) }
        m.handleTap(.space)
    }
    func testDeletedSwipeLearnsOnlyCompletedReplacementAndNextDecode() async throws {
        let p = Proxy(), m = learningModel(p)
        try await swipe(m, p)
        replaceSwipe(m, with: "zorbax")
        XCTAssertEqual(p.text, "zorbax ")
        try await waitFor { self.swipeLearning().choices(of: "zorbax") == 1 }
        XCTAssertEqual(swipeLearning().rejections(of: "hello"), 1)
        for _ in 0..<5 { m.hostTextDidChange() }
        try await swipe(m, p, "zorbax")
        XCTAssertTrue(m.suggestions.contains { $0.text.lowercased() == "zorbax" })
        XCTAssertEqual(swipeLearning().choices(of: "zorbax"), 1, "Automatic prediction must not self-train")
        m.keyboardWillDisappear()
        let nextProxy = Proxy()
        let next = KeyboardModel(proxy: nextProxy)
        next.refreshTraits()
        next.apply(m.preferences)
        try await swipe(next, nextProxy, "zorbax")
        XCTAssertTrue(next.suggestions.contains { $0.text.lowercased() == "zorbax" }, "Learned words survive engine reload")
        var prefs = next.preferences; prefs.swipeLearningEnabled = false; next.apply(prefs)
        try await swipe(next, nextProxy, "zorbax")
        XCTAssertFalse(next.suggestions.contains { $0.text.lowercased() == "zorbax" }, "Off removes learned influence")
        prefs.swipeLearningEnabled = true; next.apply(prefs)
        try await swipe(next, nextProxy, "zorbax")
        XCTAssertTrue(next.suggestions.contains { $0.text.lowercased() == "zorbax" })
        prefs.swipeLearningReset = UUID().uuidString; next.apply(prefs)
        try await swipe(next, nextProxy, "zorbax")
        XCTAssertFalse(next.suggestions.contains { $0.text.lowercased() == "zorbax" }, "Reset removes learned-only words")
        next.keyboardWillDisappear()
    }
    func testDeletionAloneAndDisabledLearningDoNotTrain() async throws {
        let p = Proxy(), m = learningModel(p)
        try await swipe(m, p)
        m.keyDown(.delete); m.endDeleteRepeat()
        m.handleTap(.space)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(swipeLearning().choices.isEmpty)
        XCTAssertTrue(swipeLearning().rejections.isEmpty)
        var prefs = m.preferences; prefs.swipeLearningEnabled = false; m.apply(prefs)
        try await swipe(m, p)
        replaceSwipe(m, with: "zorbax")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(swipeLearning().choices.isEmpty)
        m.keyboardWillDisappear()
    }
    func testReplacementRestoresOwedSpaceButDoesNotLearnAcrossChangedField() async throws {
        let p = Proxy(), m = learningModel(p)
        p.text = "say"
        try await swipe(m, p)
        replaceSwipe(m, with: "zorbax")
        XCTAssertEqual(p.text, "say zorbax ")
        try await waitFor { self.swipeLearning().choices(of: "zorbax") == 1 }
        XCTAssertEqual(swipeLearning().pairs(previous: "say", word: "zorbax"), 1)
        try await swipe(m, p)
        m.keyDown(.delete); m.endDeleteRepeat()
        for c in "newword" { m.handleTap(.character(String(c))) }
        p.session = "other" // even without a host callback, final ownership must fail
        m.handleTap(.space)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(swipeLearning().choices(of: "newword"), 0)
        m.keyboardWillDisappear()
    }
    func testReplacementCancellationAndResetPreserveExplicitVocabulary() async throws {
        let p = Proxy(), m = learningModel(p)
        m.applySystemLexicon([(input: "Nica", text: "Nica")])
        try await swipe(m, p)
        m.keyDown(.delete); m.endDeleteRepeat()
        for c in "newword" { m.handleTap(.character(String(c))) }
        let cursor = m.beginCursorControl()
        if let cursor { m.endCursorControl(cursor) }
        m.handleTap(.space)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(swipeLearning().choices(of: "newword"), 0)
        try await swipe(m, p)
        replaceSwipe(m, with: "zorbax")
        try await waitFor { self.swipeLearning().choices(of: "zorbax") == 1 }
        var prefs = m.preferences; prefs.swipeLearningReset = UUID().uuidString; m.apply(prefs)
        try await swipe(m, p, "nica")
        XCTAssertTrue(swipeLearning().choices.isEmpty)
        XCTAssertTrue(m.suggestions.contains { $0.text.lowercased() == "nica" })
        m.keyboardWillDisappear()
    }
}

extension SwipeIntegrationTests {
    func testChoosingLMFAOChangesNextSwipeWithoutAutomaticSelfTraining() async throws {
        let p = Proxy(), m = learningModel(p)
        try await swipe(m, p, "lmfao")
        let intended = try XCTUnwrap(m.suggestions.first { $0.text.lowercased() == "lmfao" })
        m.choose(intended)
        try await waitFor { self.swipeLearning().choices(of: "lmfao") == 1 }
        m.handleTap(.space)
        try await swipe(m, p, "lmfao")
        XCTAssertEqual(m.suggestions.first?.text.lowercased(), "lmfao")
        XCTAssertEqual(swipeLearning().choices(of: "lmfao"), 1)
        m.keyboardWillDisappear()
    }
    func testManualCorrectionEditsAndForeignContextAreNotConfused() async throws {
        let p = Proxy(), m = learningModel(p)
        p.text = "say"
        try await swipe(m, p)
        m.keyDown(.delete); m.endDeleteRepeat()
        m.handleTap(.character("x"))
        m.keyDown(.delete); m.endDeleteRepeat()
        for c in "zorbax" { m.handleTap(.character(String(c))) }
        m.handleTap(.space)
        XCTAssertEqual(p.text, "say zorbax ")
        try await waitFor { self.swipeLearning().choices(of: "zorbax") == 1 }
        try await swipe(m, p)
        m.keyDown(.delete); m.endDeleteRepeat()
        for c in "newword" { m.handleTap(.character(String(c))) }
        p.tail = "changed" // host edit without a callback must invalidate the saved after-anchor
        m.handleTap(.space)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(swipeLearning().choices(of: "newword"), 0)
        m.keyboardWillDisappear()
    }
}
