// by zayd/cold @ zayd.wtf

import XCTest
import UIKit
import ZoneCore

@MainActor
final class EmojiShortcodeGridTests: XCTestCase {
    private final class Touch: UITouch {
        let point: CGPoint
        let owner: UIView
        init(_ point: CGPoint, in owner: UIView) { self.point = point; self.owner = owner; super.init() }
        override var view: UIView? { owner }
        override var timestamp: TimeInterval { ProcessInfo.processInfo.systemUptime }
        override func location(in view: UIView?) -> CGPoint { point }
    }

    private func makeGrid(_ proxy: SwipeIntegrationTests.Proxy, swipe: Bool = true,
                          side: OneHandedSide? = nil, split: Bool = false) throws -> (KeyboardModel, KeyGridView, UIView) {
        let suite = "EmojiShortcodeGridTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let model = KeyboardModel(proxy: proxy)
        model.handMemory = LocalKeyboardHand(defaults: defaults)
        model.refreshTraits()
        model.apply(KeyboardPreferences(showsEmojiKey: split, swipeTypingEnabled: swipe, swipeLearningEnabled: false,
                                        oneHandedEnabled: side != nil, oneHandedSide: side ?? .right))
        let grid = KeyGridView(model: model, mic: MicController(), controller: nil)
        let keyboard = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 250))
        keyboard.addSubview(grid)
        let column = OneHandedLayout.column(width: 393, fraction: 0.8, hand: model.hand)
        grid.frame = CGRect(x: column?.x ?? 0, y: 0, width: column?.width ?? 393, height: 250)
        if split {
            grid.duo = .innerLandscape
            grid.windowInset = 75
            grid.splitKeys = true
            keyboard.frame.size.width = 801
            grid.frame.size = CGSize(width: 801, height: 203.1)
        }
        grid.sync()
        return (model, grid, keyboard)
    }

    private func touch(_ key: String, _ grid: KeyGridView) throws -> Touch {
        grid.sync()
        let elements = try XCTUnwrap(grid.accessibilityElements as? [UIAccessibilityElement])
        let match = try XCTUnwrap(elements.first { $0.accessibilityLabel?.lowercased() == key.lowercased() }, key)
        let frame = match.accessibilityFrameInContainerSpace
        return Touch(CGPoint(x: frame.midX, y: frame.midY), in: grid)
    }

    private func tap(_ key: String, _ grid: KeyGridView) throws {
        let touch = try touch(key, grid)
        grid.touchesBegan([touch], with: nil)
        grid.touchesEnded([touch], with: nil)
    }

    private func colon(_ grid: KeyGridView) throws {
        try tap("Numbers", grid)
        try tap(":", grid)
        try tap("Letters", grid)
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<120 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for emoji shortcode")
    }

    func testFastOrdinaryWordInSplitGridPreservesWordChoiceAndRejectsStaleEmoji() async throws {
        let proxy = SwipeIntegrationTests.Proxy()
        let (model, grid, keyboard) = try makeGrid(proxy, split: true)
        defer { model.keyboardWillDisappear(); withExtendedLifetime(keyboard) {} }
        try await until { model.isCorrectorReady }
        for key in "pizza" { try tap(String(key), grid) }
        try await until { model.suggestions.dropFirst().first?.text == "🍕" }
        let emoji = try XCTUnwrap(model.suggestions.dropFirst().first)
        let literal = try XCTUnwrap(model.suggestions.first { $0.kind == .literal })
        XCTAssertFalse(emoji.autoApplies)
        XCTAssertEqual(model.stripContent(hasUnsureWords: true), .unsureWord)
        model.choose(literal)
        XCTAssertEqual(proxy.text, "pizza ")
        model.choose(emoji)
        XCTAssertEqual(proxy.text, "pizza ")
        for key in "pizza" { try tap(String(key), grid) }
        try await until { model.suggestions.dropFirst().first?.text == "🍕" }
        let second = try XCTUnwrap(model.suggestions.dropFirst().first)
        proxy.session = "new-field"
        model.choose(second)
        XCTAssertEqual(proxy.text, "pizza pizza")
        model.hostTextDidChange()
    }

    func testSensitiveFieldSwitchAndPreferenceVetoAnAlreadyDrawnEmoji() async throws {
        let proxy = SwipeIntegrationTests.Proxy()
        let (model, grid, keyboard) = try makeGrid(proxy)
        defer { model.keyboardWillDisappear(); withExtendedLifetime(keyboard) {} }
        for key in "fire" { try tap(String(key), grid) }
        try await until { model.suggestions.dropFirst().first?.text == "🔥" }
        let emoji = try XCTUnwrap(model.suggestions.dropFirst().first)
        proxy.allowed = false
        model.choose(emoji)
        XCTAssertEqual(proxy.text, "fire")
        proxy.allowed = true
        model.apply(KeyboardPreferences(emojiPredictions: false))
        model.choose(emoji)
        XCTAssertEqual(proxy.text, "fire")
        try await until { !model.suggestions.contains(emoji) }
    }

    func testEmojiIsStillATappableChoiceWithAutocorrectOff() async throws {
        let proxy = SwipeIntegrationTests.Proxy()
        let (model, grid, keyboard) = try makeGrid(proxy)
        defer { model.keyboardWillDisappear(); withExtendedLifetime(keyboard) {} }
        model.apply(KeyboardPreferences(autocorrectEnabled: false))
        for key in "pizza" { try tap(String(key), grid) }
        try await until { model.suggestions.first?.text == "🍕" }
        let choice = try XCTUnwrap(model.suggestions.first)
        XCTAssertEqual(proxy.text, "pizza")
        proxy.allowed = false
        model.choose(choice)
        XCTAssertEqual(proxy.text, "pizza")
        proxy.allowed = true
        model.choose(choice)
        XCTAssertEqual(proxy.text, "🍕")
    }

    func testDictatedWordDoesNotOfferEmoji() async throws {
        let proxy = SwipeIntegrationTests.Proxy()
        let (model, _, keyboard) = try makeGrid(proxy)
        defer { model.keyboardWillDisappear(); withExtendedLifetime(keyboard) {} }
        proxy.insert("pizza")
        model.dictationInserted("pizza")
        model.hostTextDidChange()
        try await until { model.isCorrectorReady }
        XCTAssertFalse(model.suggestions.contains { $0.text == "🍕" })
    }

    func testFastRolloverExactConversionAndUndoWithSwipeOnAndOff() async throws {
        let cases: [(Bool, OneHandedSide?)] = [(true, nil), (true, .left), (false, .right)]
        for (swipe, side) in cases {
            let proxy = SwipeIntegrationTests.Proxy()
            let (model, grid, keyboard) = try makeGrid(proxy, swipe: swipe, side: side)
            XCTAssertEqual(model.hand.side, side)
            try colon(grid)
            let f = try touch("f", grid), i = try touch("i", grid)
            grid.touchesBegan([f], with: nil)
            grid.touchesBegan([i], with: nil)
            grid.touchesEnded([f], with: nil)
            grid.touchesEnded([i], with: nil)
            try tap("r", grid)
            try tap("e", grid)
            try await until { model.emojiSuggestions.first?.emoji == "🔥" }
            try colon(grid)
            XCTAssertEqual(proxy.text, "🔥")
            try tap("Delete", grid)
            XCTAssertEqual(proxy.text, ":fire:")
            model.keyboardWillDisappear()
            withExtendedLifetime(keyboard) {}
        }
    }

    func testSplitPagesAndEmojiPickerYieldToDictation() async throws {
        let proxy = SwipeIntegrationTests.Proxy()
        let (model, grid, keyboard) = try makeGrid(proxy, split: true)
        defer { model.keyboardWillDisappear(); withExtendedLifetime(keyboard) {} }
        try tap("Numbers", grid)
        try tap("Symbols", grid)
        try tap("=", grid)
        XCTAssertEqual(proxy.text, "=")
        // An equals sign marks a code context where shortcodes stay literal.
        try tap("Delete", grid)
        try tap("Letters", grid)
        try tap("Space", grid)
        try colon(grid)
        for key in "fire" { try tap(String(key), grid) }
        try await until { model.emojiSuggestions.first?.emoji == "🔥" }
        XCTAssertEqual(model.stripContent(hasUnsureWords: true), .emojiPicker)
        model.setDictationOwnsStrip(true)
        XCTAssertEqual(model.stripContent(hasUnsureWords: true), .dictation)
        XCTAssertEqual(proxy.text, " :fire")
        model.setDictationOwnsStrip(false)
        try tap("Emoji", grid)
        XCTAssertTrue(model.showsEmoji)
        model.closeEmoji()
        XCTAssertFalse(model.showsEmoji)
    }

    func testLateHostContextDelaysReplacementAndFieldChangeCancels() async throws {
        let proxy = SwipeIntegrationTests.Proxy()
        proxy.text = "Café 👋 "
        proxy.contextLimit = 64
        let (model, grid, keyboard) = try makeGrid(proxy)
        try colon(grid)
        for key in "fire" { try tap(String(key), grid) }
        try await until { model.emojiSuggestions.first?.emoji == "🔥" }
        let match = try XCTUnwrap(model.emojiSuggestions.first)
        proxy.lagsContext = true
        // Simulate the host's snapshots lagging behind the actual keystrokes.
        proxy.setShortcodeTestLag(before: "Café 👋 :f")
        model.chooseEmojiSuggestion(match)
        XCTAssertEqual(proxy.text, "Café 👋 :fire")
        try await until { proxy.text == "Café 👋 🔥" }
        proxy.setShortcodeTestLag(before: "Café 👋 :fire")
        try tap("Delete", grid)
        XCTAssertEqual(proxy.text, "Café 👋 🔥")
        try await until { proxy.text == "Café 👋 :fire" }
        try await until { model.emojiSuggestions.first?.emoji == "🔥" }
        proxy.session = "b"
        proxy.text = "Café 👋 :fire"
        model.chooseEmojiSuggestion(try XCTUnwrap(model.emojiSuggestions.first))
        model.hostTextDidChange()
        XCTAssertEqual(proxy.text, "Café 👋 :fire")
        XCTAssertTrue(model.emojiSuggestions.isEmpty)
        model.keyboardWillDisappear()
        withExtendedLifetime(keyboard) {}
    }

    func testDictationClosesPickerAndKeepsFacesAndTimesLiteral() async throws {
        let proxy = SwipeIntegrationTests.Proxy()
        let (model, grid, keyboard) = try makeGrid(proxy)
        XCTAssertEqual(model.stripContent(hasUnsureWords: true), .unsureWord)
        try colon(grid)
        for key in "fire" { try tap(String(key), grid) }
        try await until { model.stripContent(hasUnsureWords: true) == .emojiPicker }

        model.setDictationOwnsStrip(true)
        XCTAssertTrue(model.emojiSuggestions.isEmpty)
        XCTAssertEqual(model.stripContent(hasUnsureWords: false), .dictation)
        XCTAssertEqual(proxy.text, ":fire")
        try colon(grid)
        XCTAssertEqual(proxy.text, ":fire:")
        model.setDictationOwnsStrip(false)

        for phrase in [" :D", " :P", " :)", " 2:15"] {
            let before = proxy.text
            proxy.insert(phrase)
            model.dictationInserted(phrase)
            XCTAssertEqual(model.stripContent(hasUnsureWords: true), .unsureWord)
            XCTAssertEqual(proxy.text, before + phrase)
        }
        XCTAssertTrue(model.emojiSuggestions.isEmpty)
        model.keyboardWillDisappear()
        withExtendedLifetime(keyboard) {}
    }

    /// `:fi`, Delete, `i` again is the same query as before the Delete. The picker must come back:
    /// the Delete cleared it, so the remembered query no longer describes what is on screen.
    func testRetypingTheSameShortcodeAfterDeleteShowsThePickerAgain() async throws {
        let proxy = SwipeIntegrationTests.Proxy()
        let (model, grid, keyboard) = try makeGrid(proxy)
        defer { model.keyboardWillDisappear(); withExtendedLifetime(keyboard) {} }
        try colon(grid)
        for key in "fi" { try tap(String(key), grid) }
        try await until { model.stripContent(hasUnsureWords: false) == .emojiPicker }
        let shown = model.emojiSuggestions
        try tap("Delete", grid)
        XCTAssertEqual(proxy.text, ":f")
        XCTAssertTrue(model.emojiSuggestions.isEmpty)
        try tap("i", grid)
        XCTAssertEqual(proxy.text, ":fi")
        try await until { model.emojiSuggestions == shown }
        XCTAssertEqual(model.stripContent(hasUnsureWords: false), .emojiPicker)

        // The same after a longer query: `:fir`, two Deletes, `i`.
        try tap("r", grid)
        try await until { model.emojiSuggestions.first?.emoji == "🔥" }
        try tap("Delete", grid)
        try tap("Delete", grid)
        XCTAssertEqual(proxy.text, ":f")
        try tap("i", grid)
        try await until { model.emojiSuggestions == shown }
        // A tap on the restored picker still converts, so the choice is live and not a stale draw.
        let fire = try XCTUnwrap(model.emojiSuggestions.first { $0.emoji == "🔥" })
        model.chooseEmojiSuggestion(fire)
        try await until { proxy.text == "🔥" }
    }

    func testDeletingThePickerReturnsToNextWords() async throws {
        let proxy = SwipeIntegrationTests.Proxy()
        proxy.text = "thank "
        SpellingStore.useWordPairs(try XCTUnwrap(PreviousWordIntegrationTests.pairs))
        defer { SpellingStore.useWordPairs(nil) }
        let (model, grid, keyboard) = try makeGrid(proxy)
        try await until { model.stripContent(hasUnsureWords: false) == .nextWords }
        try colon(grid)
        for key in "fi" { try tap(String(key), grid) }
        try await until { model.stripContent(hasUnsureWords: false) == .emojiPicker }
        for _ in 0..<3 { try tap("Delete", grid) }
        try await until { model.stripContent(hasUnsureWords: false) == .nextWords }
        XCTAssertEqual(model.suggestions.first?.text, "you")
        XCTAssertEqual(proxy.text, "thank ")
        model.keyboardWillDisappear()
        withExtendedLifetime(keyboard) {}
    }

    func testFieldTraitsSuppressShortcodesInSensitiveAndCodeFields() {
        let document = TextProxyGateTests.Document()
        XCTAssertTrue(FieldTraits(reading: document, needsGlobeKey: false).allowsEmojiShortcodes)
        for kind in [UIKeyboardType.URL, .emailAddress, .phonePad, .numberPad, .decimalPad,
                                     .asciiCapable, .numbersAndPunctuation] {
            document._keyboardType = kind
            XCTAssertFalse(FieldTraits(reading: document, needsGlobeKey: false).allowsEmojiShortcodes, "\(kind)")
        }
        document._keyboardType = .webSearch
        XCTAssertTrue(FieldTraits(reading: document, needsGlobeKey: false).allowsEmojiShortcodes)
        document._keyboardType = .default
        for kind in [UITextContentType.username, .password, .newPassword, .oneTimeCode,
            .telephoneNumber, .creditCardNumber, .creditCardSecurityCode, .creditCardExpiration] {
            document._contentType = kind
            XCTAssertFalse(FieldTraits(reading: document, needsGlobeKey: false).allowsEmojiShortcodes, kind.rawValue)
        }
        document._contentType = nil
        document._secure = true
        XCTAssertFalse(FieldTraits(reading: document, needsGlobeKey: false).allowsEmojiShortcodes)
        document._secure = false
        document._autocorrectionType = .no
        XCTAssertTrue(FieldTraits(reading: document, needsGlobeKey: false).allowsEmojiShortcodes)
    }

    func testLiteralFieldsAndUnknownShortcodesStayTyped() async throws {
        let proxy = SwipeIntegrationTests.Proxy()
        let (model, grid, keyboard) = try makeGrid(proxy, swipe: false)
        try await until { model.isCorrectorReady }
        try colon(grid)
        for key in "teh" { try tap(String(key), grid) }
        try tap("Space", grid)
        XCTAssertEqual(proxy.text, ":teh ")
        proxy.allowed = false
        model.refreshTraits()
        try colon(grid)
        for key in "fire" { try tap(String(key), grid) }
        try colon(grid)
        XCTAssertEqual(proxy.text, ":teh :fire:")
        XCTAssertTrue(model.emojiSuggestions.isEmpty)
        model.keyboardWillDisappear()
        withExtendedLifetime(keyboard) {}
    }
}
