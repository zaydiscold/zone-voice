// by zayd/cold @ zayd.wtf

import XCTest
import UIKit
import ZoneCore

/// `TextProxyGate`: when the keyboard may read the host's document, how many reads it makes, and
/// the recording-log trace of dropped input. The host here is a `UITextDocumentProxy` that counts
/// every property read, so the read budget is measured, not estimated.
@MainActor
final class TextProxyGateTests: XCTestCase {

    // MARK: Host

    /// A host document behind the real `UITextDocumentProxy` protocol. Every trait property and
    /// the document identifier count their reads.
    @MainActor final class Document: NSObject, UITextDocumentProxy {
        var text = ""
        var tail = ""
        var identifier = UUID()
        var reads: [String: Int] = [:]
        var contextReads = 0
        private func count(_ name: String) { reads[name, default: 0] += 1 }
        var traitReads: Int { reads.filter { $0.key != "documentIdentifier" }.values.reduce(0, +) }
        var identifierReads: Int { reads["documentIdentifier", default: 0] }

        var _keyboardType: UIKeyboardType = .default
        var _returnKeyType: UIReturnKeyType = .default
        var _autocapitalizationType: UITextAutocapitalizationType = .sentences
        var _autocorrectionType: UITextAutocorrectionType = .default
        var _secure = false
        var _contentType: UITextContentType?
        var _enablesReturn = false
        var _appearance: UIKeyboardAppearance = .default
        var _smartQuotes: UITextSmartQuotesType = .default
        var _smartDashes: UITextSmartDashesType = .default

        var keyboardType: UIKeyboardType { get { count("keyboardType"); return _keyboardType } set {} }
        var returnKeyType: UIReturnKeyType { get { count("returnKeyType"); return _returnKeyType } set {} }
        var autocapitalizationType: UITextAutocapitalizationType { get { count("autocapitalizationType"); return _autocapitalizationType } set {} }
        var autocorrectionType: UITextAutocorrectionType { get { count("autocorrectionType"); return _autocorrectionType } set {} }
        var isSecureTextEntry: Bool { @objc(isSecureTextEntry) get { count("isSecureTextEntry"); return _secure } set {} }
        var textContentType: UITextContentType! { get { count("textContentType"); return _contentType } set {} }
        var enablesReturnKeyAutomatically: Bool { get { count("enablesReturnKeyAutomatically"); return _enablesReturn } set {} }
        var keyboardAppearance: UIKeyboardAppearance { get { count("keyboardAppearance"); return _appearance } set {} }
        var smartQuotesType: UITextSmartQuotesType { get { count("smartQuotesType"); return _smartQuotes } set {} }
        var smartDashesType: UITextSmartDashesType { get { count("smartDashesType"); return _smartDashes } set {} }

        var documentIdentifier: UUID { count("documentIdentifier"); return identifier }
        var documentContextBeforeInput: String? { contextReads += 1; return text }
        var documentContextAfterInput: String? { contextReads += 1; return tail }
        var selectedText: String? { nil }
        var documentInputMode: UITextInputMode? { nil }
        var hasText: Bool { contextReads += 1; return !(text + tail).isEmpty }
        func adjustTextPosition(byCharacterOffset offset: Int) {
            let joined = (text + tail) as NSString
            let position = min(joined.length, max(0, text.utf16.count + offset))
            text = joined.substring(to: position); tail = joined.substring(from: position)
        }
        func setMarkedText(_ markedText: String, selectedRange: NSRange) {}
        func unmarkText() {}
        func insertText(_ text: String) { self.text += text }
        func deleteBackward() { if !text.isEmpty { text.removeLast() } }

        /// Another field takes focus: new identifier, new traits.
        func moveToField(keyboard: UIKeyboardType, returnKey: UIReturnKeyType) {
            identifier = UUID(); text = ""; tail = ""
            _keyboardType = keyboard; _returnKeyType = returnKey
        }
    }

    /// The model's view of the host through the gate: the same one-line forwards as
    /// `KeyboardViewController`'s `TextProxyActions` conformance.
    final class GatedProxy: TextProxyActions {
        let document: Document
        let gate: TextProxyGate
        init(document: Document, gate: TextProxyGate) { self.document = document; self.gate = gate }
        func userTouchedKeyboard() { gate.touched() }
        func insert(_ text: String) { if gate.canWrite(.insert) { document.insertText(text) } }
        func deleteBackward() { if gate.canWrite(.deleteBackward) { document.deleteBackward() } }
        func adjustTextPosition(byCharacterOffset offset: Int) {
            if gate.canWrite(.adjustTextPosition) { document.adjustTextPosition(byCharacterOffset: offset) }
        }
        func contextBefore() -> String? { gate.isLive ? document.documentContextBeforeInput : nil }
        func contextAfter() -> String? { gate.isLive ? document.documentContextAfterInput : nil }
        func fieldHasText() -> Bool { gate.isLive ? document.hasText : true }
        func selectedText() -> String? { gate.isLive ? document.selectedText : nil }
        func currentInputSession() -> String? { gate.session() }
        func reloadFieldTraits() { gate.reloadTraitsIfStale() }
        var returnKeyLabel: String { gate.traits.returnKeyLabel }
        var autocapitalizesSentences: Bool { gate.traits.autocapitalizesSentences }
        var fieldNeverCapitalizes: Bool { gate.traits.fieldNeverCapitalizes }
        var allowsAutocorrection: Bool { gate.traits.allowsAutocorrection }
        var allowsSwipeTyping: Bool { gate.traits.allowsSwipeTyping }
        var allowsSmartQuotes: Bool { gate.traits.allowsSmartQuotes }
        var allowsSmartDashes: Bool { gate.traits.allowsSmartDashes }
        var prefersNumbers: Bool { gate.traits.prefersNumbers }
        var fieldKeys: [String] { gate.traits.fieldKeys }
        var capitalization: FieldCapitalization { gate.traits.capitalization }
        var isSearchField: Bool { gate.traits.isSearchField }
        var dimsReturnWhenEmpty: Bool { gate.traits.dimsReturnWhenEmpty }
        var hasOpenAccess: Bool { false }
        var explicitDarkAppearance: Bool? { gate.traits.explicitDarkAppearance }
        var needsGlobeKey: Bool { gate.traits.needsGlobeKey }
        func advanceToNextInputMode() {}
        func playClick() {}
        func open(_ url: URL) {}
    }

    /// The controller's getters as they were before the gate (commit 48e154b): every call read
    /// the proxy again. Kept only to measure the reads the gate removed.
    final class LegacyProxy: TextProxyActions {
        let document: Document
        init(document: Document) { self.document = document }
        func userTouchedKeyboard() {}
        func insert(_ text: String) { document.insertText(text) }
        func deleteBackward() { document.deleteBackward() }
        func adjustTextPosition(byCharacterOffset offset: Int) { document.adjustTextPosition(byCharacterOffset: offset) }
        func contextBefore() -> String? { document.documentContextBeforeInput }
        func contextAfter() -> String? { document.documentContextAfterInput }
        func fieldHasText() -> Bool { document.hasText }
        func selectedText() -> String? { document.selectedText }
        func currentInputSession() -> String? { document.documentIdentifier.uuidString }
        var allowsAutocorrection: Bool {
            let proxy: UITextDocumentProxy = document
            if proxy.autocorrectionType == .no { return false }
            if proxy.keyboardType == .webSearch { return false }
            return !fieldTakesLiteralText
        }
        var allowsSwipeTyping: Bool { !fieldTakesLiteralText }
        /// Smart punctuation came after the gate; the model reads these only while it is on.
        var allowsSmartQuotes: Bool { false }
        var allowsSmartDashes: Bool { false }
        private var fieldTakesLiteralText: Bool {
            let proxy: UITextDocumentProxy = document
            if proxy.isSecureTextEntry == true { return true }
            switch proxy.keyboardType ?? .default {
            case .URL, .emailAddress, .numberPad, .decimalPad, .phonePad, .asciiCapableNumberPad: return true
            default: break
            }
            if let contentType = proxy.textContentType ?? nil {
                let literal: Set<UITextContentType> = [.username, .password, .newPassword, .oneTimeCode, .emailAddress, .URL]
                if literal.contains(contentType) { return true }
            }
            return false
        }
        var returnKeyLabel: String { _ = (document as UITextDocumentProxy).returnKeyType; return "return" }
        var prefersNumbers: Bool { _ = (document as UITextDocumentProxy).keyboardType; return false }
        var fieldKeys: [String] { _ = (document as UITextDocumentProxy).keyboardType; return [] }
        var capitalization: FieldCapitalization { _ = (document as UITextDocumentProxy).autocapitalizationType; return .sentences }
        var isSearchField: Bool {
            let proxy: UITextDocumentProxy = document
            switch proxy.returnKeyType ?? .default {
            case .search, .google, .yahoo: return true
            default: return proxy.keyboardType == .webSearch || proxy.keyboardType == .URL
            }
        }
        var dimsReturnWhenEmpty: Bool { (document as UITextDocumentProxy).enablesReturnKeyAutomatically == true }
        var autocapitalizesSentences: Bool { _ = (document as UITextDocumentProxy).autocapitalizationType; return true }
        var fieldNeverCapitalizes: Bool { _ = (document as UITextDocumentProxy).autocapitalizationType; return false }
        var hasOpenAccess: Bool { false }
        var explicitDarkAppearance: Bool? { _ = (document as UITextDocumentProxy).keyboardAppearance; return nil }
        /// `needsInputModeSwitchKey` reads the same document state; counted as a trait read.
        var needsGlobeKey: Bool { document.reads["needsInputModeSwitchKey", default: 0] += 1; return false }
        /// The old `handOffEmailFieldIfNeeded`, run by every live `textDidChange`.
        func emailHandOffCheck() {
            let proxy: UITextDocumentProxy = document
            _ = proxy.keyboardType == .emailAddress || (proxy.textContentType ?? nil) == .emailAddress
        }
        func advanceToNextInputMode() {}
        func playClick() {}
        func open(_ url: URL) {}
    }

    /// Main-queue turns under the test's control.
    @MainActor final class Turns {
        private var work: [@MainActor () -> Void] = []
        var pending: Int { work.count }
        /// The delays asked for, in order.
        private(set) var delays: [TimeInterval] = []
        func schedule(_ delay: TimeInterval, _ block: @escaping @MainActor () -> Void) { delays.append(delay); work.append(block) }
        /// Runs what is queued now (one turn); work queued meanwhile waits for the next.
        func runOne() { let now = work; work = []; now.forEach { $0() } }
    }

    private var journalDirectory: URL!
    private var journal: RecordingJournal!
    private var clock: TimeInterval = 1_000

    override func setUp() async throws {
        journalDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("gate-\(UUID().uuidString)")
        journal = RecordingJournal(directory: journalDirectory, process: "keyboard")
        TextProxyGate.resetForTesting()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: journalDirectory)
    }

    private func makeGate(_ document: Document, turns: Turns, needsGlobe: Bool = false) -> TextProxyGate {
        TextProxyGate(readTraits: { FieldTraits(reading: document, needsGlobeKey: needsGlobe) },
                      readSession: { document.documentIdentifier.uuidString },
                      schedule: { turns.schedule($0, $1) },
                      now: { [unowned self] in self.clock },
                      journal: journal)
    }

    /// The controller's wiring: going live reads everything the appearance skipped.
    private func wire(_ gate: TextProxyGate, _ model: KeyboardModel) {
        gate.onLive = { [weak model] _ in model?.setSystemDark(false); model?.refreshTraits() }
    }

    private func events(_ name: String) -> [JournalEvent] {
        journal.events().filter { $0.name == name }
    }

    // MARK: Traits

    func testOneBatchReadsEachTraitPropertyOnceAndDerivesWhatTheGettersDid() {
        let document = Document()
        document._keyboardType = .numberPad
        document._returnKeyType = .go
        document._autocapitalizationType = .none
        document._appearance = .dark
        document._enablesReturn = true
        let traits = FieldTraits(reading: document, needsGlobeKey: true)
        XCTAssertEqual(document.traitReads, FieldTraits.proxyReadsPerBatch)
        XCTAssertTrue(document.reads.values.allSatisfy { $0 == 1 }, "\(document.reads)")
        XCTAssertEqual(document.identifierReads, 0)
        XCTAssertEqual(traits.returnKeyLabel, "go")
        XCTAssertTrue(traits.prefersNumbers)
        XCTAssertFalse(traits.allowsAutocorrection)
        XCTAssertFalse(traits.allowsSwipeTyping)
        XCTAssertFalse(traits.allowsSmartQuotes)
        XCTAssertFalse(traits.allowsSmartDashes)
        XCTAssertEqual(traits.capitalization, FieldCapitalization.none)
        XCTAssertTrue(traits.fieldNeverCapitalizes)
        XCTAssertFalse(traits.autocapitalizesSentences)
        XCTAssertEqual(traits.explicitDarkAppearance, true)
        XCTAssertTrue(traits.dimsReturnWhenEmpty)
        XCTAssertTrue(traits.needsGlobeKey)
        XCTAssertFalse(traits.isEmailField)

        // Every derived trait against the old getters, across the field types that matter.
        let fields: [(UIKeyboardType, UIReturnKeyType, UITextContentType?, Bool, UITextAutocorrectionType)] = [
            (.default, .default, nil, false, .default), (.webSearch, .search, nil, false, .default),
            (.URL, .go, nil, false, .default), (.emailAddress, .next, nil, false, .default),
            (.default, .done, .emailAddress, false, .default), (.default, .send, .oneTimeCode, false, .default),
            (.default, .default, nil, true, .default), (.twitter, .default, nil, false, .no),
            (.decimalPad, .done, nil, false, .default), (.numbersAndPunctuation, .join, .username, false, .yes),
        ]
        for (keyboard, returnKey, content, secure, autocorrection) in fields {
            let document = Document()
            document._keyboardType = keyboard; document._returnKeyType = returnKey
            document._contentType = content; document._secure = secure; document._autocorrectionType = autocorrection
            let traits = FieldTraits(reading: document, needsGlobeKey: false)
            let legacy = LegacyProxy(document: document)
            let label = "\(keyboard.rawValue)/\(returnKey.rawValue)/\(content?.rawValue ?? "-")/\(secure)"
            XCTAssertEqual(traits.allowsAutocorrection, legacy.allowsAutocorrection, label)
            XCTAssertEqual(traits.allowsSwipeTyping, legacy.allowsSwipeTyping, label)
            XCTAssertEqual(traits.isSearchField, legacy.isSearchField, label)
            XCTAssertEqual(traits.isEmailField, keyboard == .emailAddress || content == .emailAddress, label)
            XCTAssertEqual(traits.isCodeField, content == .oneTimeCode, label)
            XCTAssertEqual(traits.handsOffToSystemKeyboard,
                           keyboard == .emailAddress || content == .emailAddress || content == .oneTimeCode, label)
        }
        XCTAssertEqual(FieldTraits(reading: { let d = Document(); d._keyboardType = .URL; return d }(), needsGlobeKey: false).fieldKeys, [".", "/"])
        // Smart punctuation: on in ordinary text (autocorrection off too), off where the field says
        // so or wants literal characters.
        let prose = FieldTraits(reading: { let d = Document(); d._autocorrectionType = .no; return d }(), needsGlobeKey: false)
        XCTAssertTrue(prose.allowsSmartQuotes && prose.allowsSmartDashes)
        let noQuotes = FieldTraits(reading: { let d = Document(); d._smartQuotes = .no; return d }(), needsGlobeKey: false)
        XCTAssertFalse(noQuotes.allowsSmartQuotes); XCTAssertTrue(noQuotes.allowsSmartDashes)
        let noDashes = FieldTraits(reading: { let d = Document(); d._smartDashes = .no; return d }(), needsGlobeKey: false)
        XCTAssertTrue(noDashes.allowsSmartQuotes); XCTAssertFalse(noDashes.allowsSmartDashes)
        for keyboard: UIKeyboardType in [.URL, .emailAddress, .asciiCapable, .numbersAndPunctuation] {
            let traits = FieldTraits(reading: { let d = Document(); d._keyboardType = keyboard; return d }(), needsGlobeKey: false)
            XCTAssertFalse(traits.allowsSmartQuotes || traits.allowsSmartDashes, "\(keyboard.rawValue)")
        }
        XCTAssertEqual(FieldTraits(reading: { let d = Document(); d._returnKeyType = .google; return d }(), needsGlobeKey: false).returnKeyLabel, "search")
    }

    /// A phone or card number field marked only by its content type, on the default keyboard (a
    /// web form's `autocomplete="tel"` or `"cc-number"`): no swiped words, no corrections, no curled
    /// quotes. An ordinary field on the same keyboard keeps all three.
    func testPhoneAndCardNumberFieldsTakeLiteralText() {
        for content: UITextContentType in [.telephoneNumber, .creditCardNumber, .creditCardSecurityCode] {
            let traits = FieldTraits(reading: { let d = Document(); d._contentType = content; return d }(), needsGlobeKey: false)
            XCTAssertFalse(traits.allowsSwipeTyping, content.rawValue)
            XCTAssertFalse(traits.allowsAutocorrection, content.rawValue)
            XCTAssertFalse(traits.allowsSmartQuotes, content.rawValue)
            XCTAssertFalse(traits.handsOffToSystemKeyboard, content.rawValue)
        }
        let name = FieldTraits(reading: { let d = Document(); d._contentType = .name; return d }(), needsGlobeKey: false)
        XCTAssertTrue(name.allowsSwipeTyping && name.allowsAutocorrection && name.allowsSmartQuotes)
    }

    // MARK: Going live

    /// The Nov 8 crash read the proxy inside `viewDidAppear`. Nothing reads there now: with no
    /// host callback, the appearance goes live after `didAppearFallback`, and the traits are
    /// right before the first key.
    func testNothingReadsUntilOneTurnAfterDidAppearAndTheFieldIsRightBeforeTheFirstKey() {
        let document = Document(), turns = Turns()
        document._keyboardType = .numberPad; document._returnKeyType = .done
        let gate = makeGate(document, turns: turns, needsGlobe: true)
        let proxy = GatedProxy(document: document, gate: gate), model = KeyboardModel(proxy: proxy)
        defer { withExtendedLifetime(proxy) {} }
        wire(gate, model)

        gate.willAppear()
        model.apply(KeyboardPreferences(autocorrectEnabled: false))
        model.refreshTraits()
        var handedOff = false
        gate.didAppear { handedOff = true }
        XCTAssertFalse(gate.isLive)
        XCTAssertEqual(document.traitReads + document.identifierReads + document.contextReads, 0, "read during the appearance: \(document.reads)")

        XCTAssertEqual(turns.delays, [TextProxyGate.didAppearFallback])
        turns.runOne()
        XCTAssertTrue(gate.isLive)
        XCTAssertTrue(handedOff)
        XCTAssertEqual(document.traitReads, FieldTraits.proxyReadsPerBatch, "\(document.reads)")
        XCTAssertEqual(document.identifierReads, 1)
        XCTAssertEqual(model.layer, .numbers)
        XCTAssertEqual(model.returnLabel, "done")
        XCTAssertTrue(model.needsGlobe)
    }

    /// UIKit delivers host callbacks after it replaced the document state: the first one makes
    /// the document live, and the `viewDidAppear` fallback then reads nothing more.
    func testAHostCallbackGoesLiveFirstAndTheDeferredTurnDoesNotReadAgain() {
        let document = Document(), turns = Turns()
        let gate = makeGate(document, turns: turns)
        let proxy = GatedProxy(document: document, gate: gate), model = KeyboardModel(proxy: proxy)
        defer { withExtendedLifetime(proxy) {} }
        wire(gate, model)
        gate.willAppear()
        gate.didAppear()
        XCTAssertTrue(gate.hostCallback(.textWillChange))
        XCTAssertFalse(gate.hostCallback(.textDidChange), "already live")
        let traitReads = document.traitReads
        turns.runOne()
        turns.runOne()
        XCTAssertEqual(document.traitReads, traitReads)
        XCTAssertEqual(traitReads, FieldTraits.proxyReadsPerBatch)
    }

    /// A go-live deferred from one appearance must not fire inside the next one's transition.
    func testAnOldAppearancesDeferredTurnNeverMakesTheNextOneLive() {
        let document = Document(), turns = Turns()
        let gate = makeGate(document, turns: turns)
        gate.willAppear(); gate.didAppear()
        gate.willDisappear(); gate.didDisappear()
        gate.willAppear()
        turns.runOne()
        XCTAssertFalse(gate.isLive)
        XCTAssertEqual(document.traitReads + document.identifierReads, 0)
    }

    /// A fast thumb starts typing during the slide-in, before `viewDidAppear`: the first touch
    /// makes the document live, so not one key of the burst is dropped.
    func testTheFirstKeysAfterAnAppearanceAreNeverDropped() throws {
        let document = Document(), turns = Turns()
        let gate = makeGate(document, turns: turns)
        let proxy = GatedProxy(document: document, gate: gate), model = KeyboardModel(proxy: proxy)
        defer { withExtendedLifetime(proxy) {} }
        wire(gate, model)
        gate.willAppear()
        model.apply(KeyboardPreferences(autocorrectEnabled: false, showsEmojiKey: false, autoCapitalizationEnabled: false))
        let grid = KeyGridView(model: model, mic: MicController(), controller: nil)
        grid.frame = CGRect(x: 0, y: 0, width: 402, height: 250)
        grid.sync()
        // Rollover: each next finger lands before the last one lifts.
        var previous: Touch?
        for letter in "hello" {
            let touch = try touch(String(letter), in: grid)
            grid.touchesBegan([touch], with: nil)
            if let previous { grid.touchesEnded([previous], with: nil) }
            previous = touch
        }
        if let previous { grid.touchesEnded([previous], with: nil) }
        gate.didAppear()
        turns.runOne()
        XCTAssertEqual(document.text, "hello")
        XCTAssertTrue(events("keyboardDroppedWrite").isEmpty)
        // One batch for the appearance, none for the five keys.
        XCTAssertEqual(document.traitReads, FieldTraits.proxyReadsPerBatch, "\(document.reads)")
    }

    // MARK: Snapshot

    /// Keys read no traits; a host change that is not the keyboard's own echo, or a new document
    /// identifier, reads them again, so another field's return key and layer still follow.
    func testTraitsAreReadOncePerFieldAndFollowAFieldChange() {
        let document = Document(), turns = Turns()
        let gate = makeGate(document, turns: turns)
        let proxy = GatedProxy(document: document, gate: gate), model = KeyboardModel(proxy: proxy)
        defer { withExtendedLifetime(proxy) {} }
        wire(gate, model)
        model.apply(KeyboardPreferences(autocorrectEnabled: false, autoCapitalizationEnabled: true))
        gate.willAppear(); gate.didAppear(); turns.runOne()
        XCTAssertEqual(model.returnLabel, "return")
        let afterAppear = document.traitReads

        for letter in "typing fast" {
            model.handleTap(letter == " " ? .space : .character(String(letter)))
            // The host echoes each edit.
            gate.hostCallback(.textWillChange); gate.hostCallback(.textDidChange)
            model.hostTextDidChange()
            turns.runOne()
        }
        XCTAssertEqual(document.text, "Typing fast")
        XCTAssertEqual(document.traitReads, afterAppear, "keystrokes read traits: \(document.reads)")

        // Return moves the host to a number field: its callback is not an echo.
        document.moveToField(keyboard: .numberPad, returnKey: .go)
        gate.hostCallback(.textWillChange); gate.hostCallback(.textDidChange)
        model.hostTextDidChange()
        XCTAssertEqual(model.returnLabel, "go")
        XCTAssertEqual(model.layer, .numbers)
        XCTAssertEqual(document.traitReads, afterAppear + FieldTraits.proxyReadsPerBatch)

        // A new identifier noticed on a later turn reads the traits too, even with no refresh.
        turns.runOne()
        document.moveToField(keyboard: .default, returnKey: .send)
        _ = gate.session()
        XCTAssertEqual(gate.traits.returnKeyLabel, "send")
        XCTAssertEqual(document.traitReads, afterAppear + 2 * FieldTraits.proxyReadsPerBatch)
    }

    /// The document identifier is read once per turn, and again after any host callback.
    func testTheIdentifierIsReadOncePerTurn() {
        let document = Document(), turns = Turns()
        let gate = makeGate(document, turns: turns)
        gate.willAppear(); gate.didAppear(); turns.runOne()
        turns.runOne()
        let reads = document.identifierReads
        for _ in 0..<10 { _ = gate.session() }
        XCTAssertEqual(document.identifierReads, reads + 1)
        gate.hostCallback(.selectionDidChange)
        _ = gate.session()
        XCTAssertEqual(document.identifierReads, reads + 2)
        turns.runOne()
        _ = gate.session()
        XCTAssertEqual(document.identifierReads, reads + 3)
    }

    /// The read budget, measured: one appearance and twenty keystrokes with the host's echo, the
    /// old getters against the gate, through the real `KeyboardModel`.
    func testReadBudgetPerAppearanceAndPerKeystroke() async throws {
        let keys = Array("the quick brown fox ")
        try await warmDictionary()
        // Before: every getter read the proxy.
        let old = Document()
        let legacy = LegacyProxy(document: old)
        let oldModel = KeyboardModel(proxy: legacy)
        oldModel.apply(KeyboardPreferences(autocorrectEnabled: true, showSuggestions: true, swipeTypingEnabled: true))
        try await Task.sleep(for: .milliseconds(50))
        old.reads = [:]; old.contextReads = 0
        oldModel.setSystemDark(false); oldModel.refreshTraits(); legacy.emailHandOffCheck()
        let oldAppear = (traits: old.traitReads, ids: old.identifierReads, context: old.contextReads)
        old.reads = [:]; old.contextReads = 0
        for key in keys {
            oldModel.handleTap(key == " " ? .space : .character(String(key)))
            oldModel.hostTextDidChange(); legacy.emailHandOffCheck()
        }
        let oldKeys = (traits: old.traitReads, ids: old.identifierReads, context: old.contextReads)

        // After: the gate.
        let new = Document(), turns = Turns()
        let gate = makeGate(new, turns: turns, needsGlobe: false)
        let newProxy = GatedProxy(document: new, gate: gate), newModel = KeyboardModel(proxy: newProxy)
        defer { withExtendedLifetime(newProxy) {} }
        wire(gate, newModel)
        newModel.apply(KeyboardPreferences(autocorrectEnabled: true, showSuggestions: true, swipeTypingEnabled: true))
        try await Task.sleep(for: .milliseconds(50))
        gate.willAppear(); gate.didAppear(); turns.runOne()
        let newAppear = (traits: new.traitReads, ids: new.identifierReads, context: new.contextReads)
        new.reads = [:]; new.contextReads = 0
        for key in keys {
            turns.runOne()
            newModel.handleTap(key == " " ? .space : .character(String(key)))
            gate.hostCallback(.textWillChange); gate.hostCallback(.textDidChange)
            newModel.hostTextDidChange()
        }
        let newKeys = (traits: new.traitReads, ids: new.identifierReads, context: new.contextReads)

        let n = Double(keys.count)
        let report = String(format: "read budget: appearance traits %d -> %d, identifier %d -> %d, context %d -> %d; per keystroke traits %.2f -> %.2f, identifier %.2f -> %.2f, context %.2f -> %.2f",
                            oldAppear.traits, newAppear.traits, oldAppear.ids, newAppear.ids, oldAppear.context, newAppear.context,
                            Double(oldKeys.traits) / n, Double(newKeys.traits) / n, Double(oldKeys.ids) / n, Double(newKeys.ids) / n,
                            Double(oldKeys.context) / n, Double(newKeys.context) / n)
        print(report)
        XCTAssertEqual(old.text, new.text, "the gate changed what was typed")
        XCTAssertEqual(newKeys.traits, 0, report)
        // One in the key's own turn, one in the host's echo callback (which may follow a reset).
        XCTAssertLessThanOrEqual(newKeys.ids, 2 * keys.count, report)
        XCTAssertLessThan(newKeys.ids, oldKeys.ids, report)
        XCTAssertLessThanOrEqual(newAppear.traits, oldAppear.traits, report)
        XCTAssertEqual(newKeys.context, oldKeys.context, "context reads are not cached: \(report)")
    }

    // MARK: Dropped input in the recording log

    func testDroppedWritesAreJournaledOncePerAppearanceWithoutText() {
        let document = Document(), turns = Turns()
        let gate = makeGate(document, turns: turns)
        let proxy = GatedProxy(document: document, gate: gate)
        gate.willAppear(); clock += 0.1; gate.didAppear(); turns.runOne()
        clock += 5; gate.willDisappear()
        clock += 0.04
        proxy.insert("secret"); proxy.insert("words"); proxy.deleteBackward()
        XCTAssertEqual(document.text, "")
        var dropped = events("keyboardDroppedWrite")
        XCTAssertEqual(dropped.count, 1)
        let fields = dropped[0].f
        XCTAssertEqual(fields["op"], "insert")
        XCTAssertEqual(fields["onScreen"], "false")
        XCTAssertEqual(fields["live"], "false")
        XCTAssertEqual(fields["since"], "wD")
        XCTAssertEqual(fields["sinceMs"], "40")
        XCTAssertNil(dropped[0].r)
        XCTAssertFalse(fields.values.contains { $0.contains("secret") || $0.contains("words") })

        // The next appearance can log its own, once.
        gate.didDisappear()
        gate.willAppear(); gate.willDisappear()
        proxy.adjustTextPosition(byCharacterOffset: -1); proxy.deleteBackward()
        dropped = events("keyboardDroppedWrite")
        XCTAssertEqual(dropped.count, 2)
        XCTAssertEqual(dropped[1].f["op"], "adjustTextPosition")
    }

    /// The case the log exists for: a dismissal that UIKit cancels without a new
    /// `viewWillAppear` leaves the keys on screen but not live. Keys there are dropped, and the
    /// log shows it; the keyboard does not go live on its own (see `TextProxyGate.offScreenTouch`).
    func testKeysAfterACancelledDismissalAreLoggedNotTrusted() {
        let document = Document(), turns = Turns()
        let gate = makeGate(document, turns: turns)
        gate.viewState = { (true, false) }
        let proxy = GatedProxy(document: document, gate: gate)
        gate.willAppear(); gate.didAppear(); turns.runOne()
        gate.willDisappear()
        let readsBefore = document.traitReads + document.identifierReads
        proxy.userTouchedKeyboard(); proxy.insert("a")
        proxy.userTouchedKeyboard(); proxy.insert("b")
        XCTAssertFalse(gate.isLive)
        XCTAssertEqual(document.text, "")
        XCTAssertEqual(document.traitReads + document.identifierReads, readsBefore, "read the proxy after viewWillDisappear")
        let dropped = events("keyboardDroppedWrite")
        XCTAssertEqual(dropped.map { $0.f["op"] }, ["touch", "insert"])
        XCTAssertEqual(dropped[0].f["inWindow"], "true")
        XCTAssertEqual(dropped[0].f["hidden"], "false")

        // UIKit brings it back: the visit records the reappearance, then the keys work.
        gate.willAppear(); gate.didAppear(); turns.runOne()
        proxy.userTouchedKeyboard(); proxy.insert("c")
        XCTAssertEqual(document.text, "c")
        gate.willDisappear(); gate.didDisappear()
        let visits = events("keyboardVisit")
        XCTAssertEqual(visits.count, 1)
        let anomalies = visits[0].f["anomalies"] ?? ""
        XCTAssertTrue(anomalies.contains("droppedWrites") && anomalies.contains("offScreenTouches") && anomalies.contains("reappeared"), anomalies)
        XCTAssertEqual(visits[0].f["droppedWrites"], "2")
        let sequence = visits[0].f["seq"] ?? ""
        XCTAssertTrue(sequence.hasPrefix("wA dA+0 live:didAppear+0 wD+0 wA+0"), sequence)
    }

    /// An ordinary visit leaves one baseline line per process and nothing after it.
    func testOrdinaryVisitsCostOneLinePerProcess() {
        let document = Document(), turns = Turns()
        let gate = makeGate(document, turns: turns)
        for _ in 0..<5 {
            gate.willAppear(); clock += 0.3; gate.didAppear(); turns.runOne()
            gate.hostCallback(.textDidChange)
            clock += 4; gate.willDisappear(); clock += 0.25; gate.didDisappear()
            turns.runOne()
        }
        let visits = events("keyboardVisit")
        XCTAssertEqual(visits.count, 1)
        XCTAssertEqual(visits.first?.f["anomalies"], "none")
        XCTAssertEqual(visits.first?.f["seq"], "wA dA+300 live:didAppear+300 cb:textDidChange+300 wD+4300 dD+4550")
    }

    // MARK: Helpers

    /// Loads the shared dictionary, so autocorrect runs in both halves of the budget.
    private func warmDictionary() async throws {
        let warm = SwipeIntegrationTests.Proxy(), loader = KeyboardModel(proxy: warm)
        defer { withExtendedLifetime(warm) {} }
        loader.refreshTraits()
        loader.apply(KeyboardPreferences(autocorrectEnabled: true, showSuggestions: true))
        for c in "helo" { loader.handleTap(.character(String(c))) }
        for _ in 0..<300 where loader.suggestions.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(loader.suggestions.isEmpty, "the dictionary never loaded")
        loader.keyboardWillDisappear()
    }

    private final class Touch: UITouch {
        let point: CGPoint
        let owner: UIView
        init(_ point: CGPoint, in owner: UIView) { self.point = point; self.owner = owner; super.init() }
        override var view: UIView? { owner }
        override var timestamp: TimeInterval { ProcessInfo.processInfo.systemUptime }
        override func location(in view: UIView?) -> CGPoint { point }
    }

    private func touch(_ name: String, in grid: KeyGridView) throws -> Touch {
        let elements = try XCTUnwrap(grid.accessibilityElements as? [UIAccessibilityElement])
        let element = try XCTUnwrap(elements.first { $0.accessibilityLabel == name }, "no key \(name)")
        let frame = element.accessibilityFrameInContainerSpace
        return Touch(CGPoint(x: frame.midX, y: frame.midY), in: grid)
    }
}
