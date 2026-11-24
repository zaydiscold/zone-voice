// by zayd/cold @ zayd.wtf

import Observation
import UniformTypeIdentifiers
import XCTest
@testable import ZoneCore

/// Clipboard history in the keyboard: a copy made while the keyboard was away is kept when the
/// keyboard appears, one made while it is up is kept within a second, the Paste key's text is
/// kept too, and the panel's Clipboard list puts a copy back at the cursor.
@MainActor final class ClipboardKeyboardTests: XCTestCase {
    typealias Proxy = SwipeIntegrationTests.Proxy

    final class Board: AutomaticClipboardSource, @unchecked Sendable {
        var changeCount = 10
        var text: String?
        var types = ["public.utf8-plain-text"]
        var hasText: Bool { text != nil }
        var reads = 0
        private(set) var availabilityCountReads = 0
        private(set) var availabilityFlagReads = 0
        var holdsInspections = false
        private(set) var inspections: [@MainActor () -> Void] = []
        func deliverInspection(file: StaticString = #filePath, line: UInt = #line) {
            guard !inspections.isEmpty else { return XCTFail("No pending inspection", file: file, line: line) }
            inspections.removeFirst()()
        }
        func copy(_ text: String, types: [String] = ["public.utf8-plain-text"]) {
            self.text = text
            self.types = types
            changeCount += 1
        }
        func inspectAvailability(reusing cached: AutomaticClipboardSnapshot?, allowed: @escaping @Sendable () -> Bool,
                                 _ done: @escaping @MainActor @Sendable (AutomaticClipboardSnapshot?) -> Void) {
            let snapshot = AutomaticClipboardSnapshot.availability(reusing: cached, allowed: allowed, changeCount: {
                availabilityCountReads += 1
                return changeCount
            }, hasContent: {
                availabilityFlagReads += 1
                return hasText
            })
            deliver(snapshot, done)
        }

        func inspect(ignoring count: Int?, allowed: @escaping @Sendable () -> Bool, _ done: @escaping @MainActor @Sendable (AutomaticClipboardSnapshot?) -> Void) {
            let snapshot: AutomaticClipboardSnapshot? = !allowed() || changeCount == count ? nil : .init(count: changeCount, hasContent: hasText, types: types)
            deliver(snapshot, done)
        }

        private func deliver(_ snapshot: AutomaticClipboardSnapshot?, _ done: @escaping @MainActor @Sendable (AutomaticClipboardSnapshot?) -> Void) {
            // Model an IPC reply already in transit, including after a subsequent cancellation.
            if holdsInspections { inspections.append { done(snapshot) } }
            else { done(snapshot) }
        }

        func readCopy(for count: Int, skipsSecrets: Bool, allowed: @escaping @Sendable () -> Bool,
                      _ done: @escaping @MainActor @Sendable (Int, AutomaticClipboardValue?) -> Void) {
            guard allowed() else { done(count, nil); return }
            readText { text in Task { @MainActor in done(self.changeCount, text.map(AutomaticClipboardValue.text)) } }
        }

        func readText(_ done: @escaping @Sendable (String?) -> Void) {
            reads += 1
            let value = text
            DispatchQueue.main.async { done(value) }
        }
    }

    func testStalledPasteboardProbeLeavesMainActorFreeAndDropsLateResultAfterOptOut() async throws {
        let isolated = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: isolated.name) }
        isolated.string = "private synthetic fixture"
        let entered = expectation(description: "read started")
        let returned = expectation(description: "blocked accessor released")
        let blocked = DispatchSemaphore(value: 0)
        let reader = SystemClipboard {
            XCTAssertFalse(Thread.isMainThread)
            entered.fulfill()
            _ = blocked.wait(timeout: .now() + 4)
            returned.fulfill()
            return isolated
        }
        let capture = ClipboardCapture(source: reader, history: history, seen: Seen())
        let settings = ClipboardCapture.Settings(enabled: true, skipsSecrets: false, automatic: true)
        var optedIn = true
        let began = Date()
        for _ in 0..<100 {
            capture.captureAutomatically(route: .app, eligibility: { optedIn ? settings : nil })
        }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertLessThan(Date().timeIntervalSince(began), 2)
        optedIn = false
        capture.cancelAutomaticRead()
        blocked.signal()
        await fulfillment(of: [returned], timeout: 2)
        await Task.yield()
        XCTAssertTrue(history.entries().isEmpty)
    }

    func testAutomaticSystemReadPersistsLatestNamedPasteboardText() async throws {
        let isolated = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: isolated.name) }
        isolated.string = "synthetic automatic readback"
        let capture = ClipboardCapture(source: SystemClipboard { isolated }, history: history, seen: Seen())
        let saved = expectation(description: "persisted current copy")
        capture.captureAutomatically(route: .app, eligibility: {
            .init(enabled: true, skipsSecrets: false, automatic: true)
        }) { outcome in
            guard case .saved = outcome else { return XCTFail("Expected an automatic save") }
            saved.fulfill()
        }
        await fulfillment(of: [saved], timeout: 8)
        XCTAssertEqual(ClipboardHistory(directory: history.directory).entries().first?.text, isolated.string)
    }

    final class Seen: ClipboardSeenStore {
        var privateChangeCount: Int?
        var seenChangeCount: Int?
        var secretFieldOpen = false
    }

    private var directory: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var board: Board!
    private var history: ClipboardHistory!
    private var enabled = true
    private var automatic = false
    private var skipsSecrets = true
    private var field = ClipboardField.ordinary
    private var fullAccess = true

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-keyboard-\(UUID().uuidString)")
        suite = "clipboard-keyboard-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        board = Board()
        history = ClipboardHistory(directory: directory)
        enabled = true; automatic = false; skipsSecrets = true; field = .ordinary; fullAccess = true
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }

    private func controller(reachable: Bool = true, seen: ClipboardSeenStore = Seen(), source: ClipboardSource? = nil,
                            readPanel: @escaping ClipboardController.PanelRead = ClipboardController.readRecent) -> ClipboardController {
        ClipboardController(
            source: source ?? board, history: reachable ? history : nil, seen: seen, readPanel: readPanel, defaults: defaults,
            settings: { [unowned self] in .init(enabled: self.enabled, skipsSecrets: self.skipsSecrets, automatic: self.automatic) },
            field: { [unowned self] in self.field },
            hasOpenAccess: { [unowned self] in self.fullAccess })
    }

    private func settle(_ seconds: TimeInterval = 0.25) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private var texts: [String] { history.entries().map(\.text) }

    // MARK: Capture on appear

    func testUnchangedKeyboardPollReadsOnlyTheCountAndStillUpdatesPrivateFields() {
        let seen = Seen()
        let clipboard = controller(seen: seen)
        board.copy("initial ordinary text")
        clipboard.keyboardBecameLive()
        XCTAssertEqual(board.availabilityCountReads, 2)
        XCTAssertEqual(board.availabilityFlagReads, 1)
        for _ in 0..<10 { clipboard.check() }
        field = .secret
        clipboard.check()
        XCTAssertTrue(seen.secretFieldOpen)
        XCTAssertEqual(seen.privateChangeCount, board.changeCount)
        field = .ordinary
        clipboard.check()
        XCTAssertFalse(seen.secretFieldOpen)
        XCTAssertFalse(clipboard.hasUnsavedCopy)
        XCTAssertEqual(board.availabilityCountReads, 14)
        XCTAssertEqual(board.availabilityFlagReads, 1)
        board.copy("new ordinary text")
        clipboard.check()
        XCTAssertEqual(board.availabilityCountReads, 16)
        XCTAssertEqual(board.availabilityFlagReads, 2)
        XCTAssertTrue(clipboard.hasUnsavedCopy)
        XCTAssertEqual(board.reads, 0)
        enabled = false
        clipboard.keyboardWillDisappear()
    }

    func testKeyboardPassivePollKeepsMainActorResponsiveDuringStalledPasteboardIPC() async throws {
        let isolated = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: isolated.name) }
        isolated.string = "available without a paste tap"
        let entered = expectation(description: "worker entered")
        let release = DispatchSemaphore(value: 0)
        let reader = SystemClipboard {
            XCTAssertFalse(Thread.isMainThread)
            entered.fulfill()
            _ = release.wait(timeout: .now() + 8)
            return isolated
        }
        let clipboard = controller(source: reader)
        clipboard.keyboardBecameLive()
        defer {
            enabled = false
            clipboard.keyboardWillDisappear()
            release.signal()
        }
        await fulfillment(of: [entered], timeout: 2)
        for _ in 0..<100 { clipboard.check() }
        XCTAssertFalse(clipboard.hasUnsavedCopy)
        let offered = expectation(description: "clipboard copy offered after service resumes")
        withObservationTracking { _ = clipboard.hasUnsavedCopy } onChange: { offered.fulfill() }
        release.signal()
        await fulfillment(of: [offered], timeout: 3)
        XCTAssertTrue(clipboard.hasUnsavedCopy)
        XCTAssertTrue(texts.isEmpty)
    }

    func testStalledKeyboardFieldTransitionsKeepTheCopyPrivateAcrossAppAndKeyboard() {
        let app = SharedClipboardSeenStore(defaults: defaults)
        let clipboard = controller(seen: SharedClipboardSeenStore(defaults: defaults))
        board.holdsInspections = true
        board.copy("ordinary before the stalled probe")
        clipboard.keyboardBecameLive()
        field = .secret
        clipboard.check()
        board.copy("synthetic text copied in a card field")
        field = .ordinary
        clipboard.check()
        let settings = ClipboardCapture.Settings(enabled: true, skipsSecrets: true)
        func appSave() -> ClipboardCapture.Outcome {
            ClipboardCapture.keepDelivered(board.text!, types: board.types, tappedChangeCount: board.changeCount,
                                           deliveredChangeCount: board.changeCount, settings: settings, history: history, seen: app)
        }
        XCTAssertTrue(app.secretFieldOpen)
        XCTAssertEqual(appSave(), .skipped(.privateField))
        XCTAssertEqual(board.inspections.count, 1)
        board.deliverInspection()
        XCTAssertTrue(app.secretFieldOpen, "the older ordinary result cannot clear the guard")
        board.deliverInspection()
        XCTAssertFalse(app.secretFieldOpen)
        XCTAssertEqual(app.privateChangeCount, board.changeCount)
        XCTAssertEqual(appSave(), .skipped(.privateField))
        board.copy("ordinary after the field boundary")
        guard case .saved = appSave() else { return XCTFail("a later ordinary copy should save") }
        XCTAssertEqual(texts, ["ordinary after the field boundary"])
        enabled = false
        clipboard.keyboardWillDisappear()
    }

    func testPublishedSettingsStartAndStopAnAlreadyVisibleKeyboardWithoutReopening() async {
        enabled = false
        automatic = true
        let clipboard = controller()
        board.copy("enabled while already typing")
        board.holdsInspections = true
        clipboard.keyboardBecameLive()
        XCTAssertTrue(board.inspections.isEmpty)
        enabled = true
        fullAccess = false
        clipboard.refreshSettings()
        XCTAssertTrue(board.inspections.isEmpty)
        fullAccess = true
        clipboard.refreshSettings()
        XCTAssertEqual(board.inspections.count, 1)
        automatic = false
        clipboard.refreshSettings()
        board.deliverInspection() // old automatic opt-in
        board.deliverInspection() // metadata-only availability
        XCTAssertTrue(clipboard.hasUnsavedCopy)
        XCTAssertEqual(board.reads, 0)
        XCTAssertTrue(texts.isEmpty)
        automatic = true
        clipboard.refreshSettings()
        board.deliverInspection()
        board.deliverInspection() // opted-in read checks the current providers
        XCTAssertEqual(board.reads, 1)
        enabled = false
        clipboard.refreshSettings()
        XCTAssertFalse(clipboard.hasUnsavedCopy)
        clipboard.keyboardWillDisappear()
        enabled = true
        clipboard.refreshSettings()
        XCTAssertTrue(board.inspections.isEmpty, "a settings publication cannot restart a hidden keyboard")
        await Task.yield()
        XCTAssertTrue(texts.isEmpty, "revocation invalidated the undelivered provider")
    }

    func testRevokingAccessOrHistoryDropsAKeyboardProbeAlreadyInTransit() {
        let clipboard = controller()
        automatic = true
        board.copy("never eligible after revocation")
        board.holdsInspections = true
        for revokeHistory in [false, true] {
            enabled = true
            fullAccess = true
            clipboard.keyboardBecameLive()
            clipboard.check()
            XCTAssertEqual(board.inspections.count, 1)
            if revokeHistory { enabled = false } else { fullAccess = false }
            clipboard.check()
            board.deliverInspection()
            XCTAssertFalse(clipboard.hasUnsavedCopy)
            XCTAssertTrue(board.inspections.isEmpty)
            XCTAssertEqual(board.reads, 0)
            XCTAssertTrue(texts.isEmpty)
            clipboard.keyboardWillDisappear()
        }
    }

    func testAnOlderKeyboardExitCannotCloseTheNewKeyboardsSecretField() {
        let app = SharedClipboardSeenStore(defaults: defaults)
        let first = controller(seen: SharedClipboardSeenStore(defaults: defaults))
        let second = controller(seen: SharedClipboardSeenStore(defaults: defaults))
        field = .secret
        first.keyboardBecameLive()
        let oldTap = first.pasteTapped()
        board.holdsInspections = true
        first.keyboardWillDisappear()
        second.keyboardBecameLive()
        board.copy("copied in the second keyboard")
        board.deliverInspection() // delayed departure of the first keyboard
        XCTAssertTrue(app.secretFieldOpen)
        field = .ordinary
        first.pasted("old keyboard's late paste", token: oldTap)
        XCTAssertTrue(app.secretFieldOpen, "a retired keyboard delivery cannot release the new field")
        second.check()
        board.deliverInspection() // second keyboard's stale secret probe
        XCTAssertTrue(app.secretFieldOpen)
        board.deliverInspection() // fresh ordinary boundary
        XCTAssertEqual(app.privateChangeCount, board.changeCount)
        XCTAssertFalse(app.secretFieldOpen)
        enabled = false
        second.keyboardWillDisappear()
    }

    func testAStaleMarkedPasteLeavesTheNewCopyEligibleAndPreservesSharedReadback() async throws {
        let seen = Seen()
        let capture = ClipboardCapture(source: board, history: history, seen: seen)
        let settings = ClipboardCapture.Settings(enabled: true, skipsSecrets: true, automatic: true)
        for marker in ["org.nspasteboard.ConcealedType", ClipboardPolicy.ownType] {
            board.copy("old marked copy", types: [marker])
            let old = capture.notePasteTap()
            let replacement = "ordinary replacement for " + marker
            board.copy(replacement)
            capture.check(settings)
            XCTAssertTrue(capture.hasUnsavedCopy)
            _ = capture.keepPasted("old marked copy", settings: settings, types: [marker], token: old)
            XCTAssertTrue(capture.hasUnsavedCopy)
            XCTAssertNotEqual(seen.seenChangeCount, board.changeCount)
            let saved = expectation(description: "new replacement saved automatically")
            capture.captureAutomatically(route: .keyboard, eligibility: { settings }) { outcome in
                guard case .saved(let entry) = outcome else { return XCTFail("new copy should save") }
                XCTAssertEqual(entry.text, replacement)
                saved.fulfill()
            }
            await fulfillment(of: [saved], timeout: 2)
            _ = ClipboardCapture.keepDelivered("old marked copy", types: [marker], token: old,
                                               deliveredChangeCount: board.changeCount, settings: settings,
                                               history: history, seen: seen)
            XCTAssertEqual(seen.seenChangeCount, board.changeCount)
            XCTAssertEqual(texts.first, replacement)
            XCTAssertTrue(history.skips.isEmpty)
        }
    }

    func testACopyMadeWhileTheKeyboardWasAwayIsOfferedWhenItAppears() async throws {
        let clipboard = controller()
        board.copy("the note I meant to paste")
        clipboard.keyboardBecameLive()
        try await settle()
        XCTAssertTrue(texts.isEmpty)
        XCTAssertTrue(clipboard.hasUnsavedCopy)
        clipboard.keyboardWillDisappear()
    }

    func testTheSameClipboardOnTheNextAppearanceIsNotReadAgain() async throws {
        let clipboard = controller()
        board.copy("once")
        clipboard.keyboardBecameLive()
        try await settle()
        clipboard.keyboardWillDisappear()
        clipboard.keyboardBecameLive()
        try await settle()
        clipboard.keyboardWillDisappear()
        XCTAssertEqual(board.reads, 0)
        XCTAssertTrue(texts.isEmpty)
    }

    func testACopyMadeWhileTheKeyboardIsUpIsOfferedWithinItsNextLooks() async throws {
        let clipboard = controller()
        clipboard.keyboardBecameLive()
        try await settle()
        XCTAssertTrue(texts.isEmpty)
        board.copy("copied from the field being typed in")
        // The keyboard looks once a second (with some tolerance) while it is on screen.
        try await settle(ClipboardController.pollSeconds + 0.8)
        XCTAssertTrue(clipboard.hasUnsavedCopy)
        XCTAssertTrue(texts.isEmpty)
        board.copy("and the one after it")
        try await settle(ClipboardController.pollSeconds + 0.8)
        clipboard.pasted("and the one after it")
        XCTAssertEqual(texts, ["and the one after it"])
        clipboard.keyboardWillDisappear()
    }

    func testNothingIsLookedAtOnceTheKeyboardIsGone() async throws {
        let clipboard = controller()
        clipboard.keyboardBecameLive()
        try await settle()
        clipboard.keyboardWillDisappear()
        board.copy("copied with the keyboard down")
        try await settle(ClipboardController.pollSeconds + 0.8)
        XCTAssertEqual(board.reads, 0)
        XCTAssertTrue(texts.isEmpty)
    }

    func testOffNothingIsRead() async throws {
        enabled = false
        let clipboard = controller()
        board.copy("private")
        clipboard.keyboardBecameLive()
        try await settle(ClipboardController.pollSeconds + 0.6)
        XCTAssertEqual(board.reads, 0)
        XCTAssertTrue(texts.isEmpty)
        XCTAssertFalse(clipboard.isEnabled)
        clipboard.keyboardWillDisappear()
    }

    func testWithoutFullAccessNothingIsRead() async throws {
        fullAccess = false
        let clipboard = controller()
        board.copy("out of reach")
        clipboard.keyboardBecameLive()
        try await settle()
        XCTAssertEqual(board.reads, 0)
        clipboard.keyboardWillDisappear()
    }

    func testAPasswordFieldAndAMarkedCopyAreNeverRead() async throws {
        let clipboard = controller()
        field = .secret
        board.copy("looks ordinary, copied for a password field")
        clipboard.keyboardBecameLive()
        try await settle()
        clipboard.keyboardWillDisappear()
        field = .ordinary
        clipboard.keyboardBecameLive()
        try await settle()
        board.copy("hidden", types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"])
        clipboard.pasted("hidden", types: board.types)
        board.copy("a dictation", types: ["public.utf8-plain-text", ClipboardPolicy.ownType])
        clipboard.pasted("a dictation", types: board.types)
        try await settle()
        clipboard.keyboardWillDisappear()
        XCTAssertEqual(board.reads, 0)
        XCTAssertTrue(texts.isEmpty)
    }

    func testAPasswordShapedCopyIsNotKeptUnlessTheSwitchIsOff() async throws {
        let clipboard = controller()
        board.copy("nXg8-pwTz.4hKq")
        clipboard.check()
        clipboard.pasted("nXg8-pwTz.4hKq")
        try await settle()
        XCTAssertTrue(texts.isEmpty)
        skipsSecrets = false
        board.copy("nXg8-pwTz.4hKq")
        clipboard.check()
        clipboard.pasted("nXg8-pwTz.4hKq")
        try await settle()
        XCTAssertEqual(texts, ["nXg8-pwTz.4hKq"])
    }

    // MARK: The Paste key

    func testTextPastedWithThePasteKeyIsKept() async throws {
        let clipboard = controller()
        let proxy = Proxy()
        let model = KeyboardModel(proxy: proxy)
        model.refreshTraits()
        model.pasteSaving = clipboard.saving
        board.copy("pasted through Apple's button")
        let target = PasteTarget(session: { model.currentSession }, saving: model.pasteSaving) { model.insertPasted($0) }
        target.paste(itemProviders: [NSItemProvider(object: "pasted through Apple's button" as NSString)])
        try await settle(0.4)
        XCTAssertEqual(proxy.text, "pasted through Apple's button")
        XCTAssertEqual(texts, ["pasted through Apple's button"])
        XCTAssertEqual(history.entries().first?.route, .pasteKey)
        XCTAssertEqual(board.reads, 0, "the paste button handed the text over; the clipboard was not read again")
        // And the look that follows finds nothing new.
        clipboard.check()
        try await settle()
        XCTAssertEqual(board.reads, 0)
    }

    func testImmediatePasteInsertsAndKeepsTheCopy() async throws {
        let clipboard = controller()
        let proxy = Proxy()
        let model = KeyboardModel(proxy: proxy)
        model.refreshTraits()
        model.pasteSaving = clipboard.saving
        clipboard.keyboardBecameLive()
        try await settle()
        board.copy("copied a moment ago")
        // Pasted before the once-a-second look: the keyboard cannot say which field it was copied in.
        let target = PasteTarget(session: { model.currentSession }, saving: model.pasteSaving) { model.insertPasted($0) }
        target.paste(itemProviders: [NSItemProvider(object: "copied a moment ago" as NSString)])
        try await settle(0.2)
        XCTAssertEqual(proxy.text, "copied a moment ago", "the paste itself always goes in")
        XCTAssertEqual(texts, ["copied a moment ago"])
        try await settle(ClipboardController.pollSeconds + 0.8)
        XCTAssertFalse(clipboard.hasUnsavedCopy)
        clipboard.keyboardWillDisappear()
        XCTAssertEqual(board.reads, 0)
    }

    /// A provider whose text arrives only when the test says so, as a slow `loadObject` does.
    /// Touched only on the main queue.
    final class HeldText: @unchecked Sendable {
        private var waiting: [String: () -> Void] = [:]
        func provider(_ text: String) -> NSItemProvider {
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { [weak self] completion in
                DispatchQueue.main.async { self?.waiting[text] = { completion(Data(text.utf8), nil) } }
                return nil
            }
            return provider
        }
        var isWaiting: Set<String> { Set(waiting.keys) }
        func deliver(_ text: String) { waiting.removeValue(forKey: text)?() }
    }

    private func pasteKey(_ clipboard: ClipboardController) -> (Proxy, KeyboardModel, PasteTarget) {
        let proxy = Proxy()
        let model = KeyboardModel(proxy: proxy)
        model.refreshTraits()
        model.pasteSaving = clipboard.saving
        return (proxy, model, PasteTarget(session: { model.currentSession }, saving: model.pasteSaving) { model.insertPasted($0) })
    }

    func testALookWhileThePastedTextLoadsCannotVouchForIt() async throws {
        let clipboard = controller()
        board.copy("what the tap pasted")
        clipboard.check()
        let (proxy, _, target) = pasteKey(clipboard)
        let held = HeldText()
        target.paste(itemProviders: [held.provider("what the tap pasted")])
        try await settle(0.2)
        XCTAssertEqual(held.isWaiting, ["what the tap pasted"])
        // A new copy, then the once-a-second look sees it, all before the tapped text arrives.
        board.copy("copied while the paste was loading")
        clipboard.check()
        held.deliver("what the tap pasted")
        try await settle()
        XCTAssertEqual(proxy.text, "what the tap pasted", "the paste itself always goes in")
        XCTAssertTrue(texts.isEmpty, "the text is the tapped change's, not the one the look saw")
        XCTAssertTrue(clipboard.hasUnsavedCopy, "the newer copy is still offered as usual")
        XCTAssertEqual(board.reads, 0)
    }

    func testTwoPastesFinishingInReverseAreEachJudgedByTheirOwnTap() async throws {
        let clipboard = controller()
        board.copy("first copy")
        clipboard.check()
        let (proxy, _, target) = pasteKey(clipboard)
        let held = HeldText()
        target.paste(itemProviders: [held.provider("first copy")])
        board.copy("second copy")
        clipboard.check()
        target.paste(itemProviders: [held.provider("second copy")])
        try await settle(0.2)
        XCTAssertEqual(held.isWaiting, ["first copy", "second copy"])
        held.deliver("second copy")
        try await settle()
        held.deliver("first copy")
        try await settle()
        XCTAssertEqual(proxy.text, "second copyfirst copy", "both pastes go in, in the order they arrived")
        XCTAssertEqual(texts, ["second copy"], "the late first paste does not borrow the second tap's change")
        XCTAssertEqual(board.reads, 0)
    }

    func testAPasteTappedWithHistoryOffOrNoFullAccessIsNotKeptWhenItArrives() async throws {
        let clipboard = controller()
        board.copy("tapped while off")
        clipboard.check()
        let (proxy, _, target) = pasteKey(clipboard)
        let held = HeldText()
        enabled = false
        target.paste(itemProviders: [held.provider("tapped while off")])
        fullAccess = false
        target.paste(itemProviders: [held.provider("tapped without access")])
        enabled = true
        fullAccess = true
        clipboard.check()
        try await settle(0.2)
        held.deliver("tapped while off")
        try await settle()
        held.deliver("tapped without access")
        try await settle()
        XCTAssertEqual(proxy.text, "tapped while offtapped without access")
        XCTAssertTrue(texts.isEmpty)
        XCTAssertEqual(board.reads, 0)
    }

    func testObservedFieldTransitionsBetweenPollsProtectTheCopy() {
        let seen = Seen()
        let clipboard = controller(seen: seen)
        let gate = TextProxyGate(readTraits: { [unowned self] in
            var traits = FieldTraits()
            traits.clipboardField = self.field
            return traits
        }, readSession: { "test" }, journal: nil)
        gate.onClipboardFieldChange = { clipboard.check() }
        gate.willAppear()
        gate.touched()
        field = .secret
        _ = gate.hostCallback(.textDidChange)
        gate.reloadTraitsIfStale()
        board.copy("synthetic clipboard sample")
        field = .ordinary
        _ = gate.hostCallback(.textDidChange)
        gate.reloadTraitsIfStale()
        clipboard.pasted("synthetic clipboard sample")
        XCTAssertEqual(seen.privateChangeCount, board.changeCount)
        XCTAssertTrue(texts.isEmpty)
        XCTAssertEqual(board.reads, 0)
    }

    func testLeavingACardFieldMarksACopyMadeThereBeforeZonesOwnSaveCanKeepIt() async throws {
        let seen = Seen()
        let clipboard = controller(seen: seen)
        field = .secret
        clipboard.keyboardBecameLive()
        try await settle()
        // Copied in the card field, then straight to Zone before the next look.
        board.copy("a name and the card's number")
        clipboard.keyboardWillDisappear()
        XCTAssertEqual(seen.privateChangeCount, board.changeCount, "the last look on the way out marked it")
        XCTAssertFalse(seen.secretFieldOpen, "and closed the field: the keyboard looked as it left")
        let app = ClipboardCapture.keepDelivered("a name and the card's number", types: board.types,
                                                 tappedChangeCount: board.changeCount, deliveredChangeCount: board.changeCount,
                                                 settings: .init(enabled: true, skipsSecrets: true), history: history, seen: seen)
        XCTAssertEqual(app, .skipped(.privateField))
        XCTAssertTrue(texts.isEmpty)
        XCTAssertEqual(board.reads, 0)
    }

    // MARK: The panel

    func testAChosenCopyGoesInAsItWasCopiedAndIsNotKeptTwice() async throws {
        let clipboard = controller()
        let proxy = Proxy()
        let model = KeyboardModel(proxy: proxy)
        model.refreshTraits()
        model.pasteSaving = clipboard.saving
        history.add("  two  spaces, kept exactly\n", route: .keyboard)
        history.add("newer", route: .keyboard)
        clipboard.panelOpened()
        try await settle()
        guard case .loaded(let entries) = clipboard.panel else { return XCTFail("the list did not load") }
        XCTAssertEqual(entries.map(\.text), ["newer", "  two  spaces, kept exactly\n"])
        for character in "hi" { model.handleTap(.character(String(character))) }
        model.insertPasted(entries[1].text)
        XCTAssertEqual(proxy.text, "hi  two  spaces, kept exactly\n")
        XCTAssertEqual(texts, ["newer", "  two  spaces, kept exactly\n"], "putting an old copy in the field does not move or double it")
    }

    func testLatePanelReadsCannotReplaceTheCurrentList() {
        var replies: [@MainActor ([ClipboardEntry]) -> Void] = []
        let clipboard = controller(readPanel: { _, reply in replies.append(reply) })
        clipboard.panelOpened()
        clipboard.panelClosed()
        clipboard.panelOpened()
        clipboard.loadPanel()
        XCTAssertEqual(replies.count, 3)
        replies[2]([])
        history.add("older copy", route: .saved)
        let older = history.entries()
        XCTAssertFalse(older.isEmpty)
        replies[1](older)
        XCTAssertEqual(clipboard.panel, .loaded([]))
        replies[0](older)
        XCTAssertEqual(clipboard.panel, .loaded([]))
    }

    func testStalledReadOffersRetryAndIgnoresLateReply() async throws {
        var replies: [@MainActor ([ClipboardEntry]) -> Void] = []
        let clipboard = controller(readPanel: { _, reply in replies.append(reply) })
        clipboard.panelWait = .zero
        clipboard.panelOpened()
        try await settle()
        XCTAssertEqual(clipboard.panel, .timedOut)
        clipboard.loadPanel()
        replies[0]([])
        XCTAssertEqual(clipboard.panel, .loading)
        replies[1]([])
        XCTAssertEqual(clipboard.panel, .loaded([]))
    }

    func testVisibleKeyboardAutomaticallyKeepsTextOnlyWithOptInAndAccess() async throws {
        let clipboard = controller()
        board.copy("first paragraph")
        clipboard.keyboardBecameLive()
        XCTAssertEqual(board.reads, 0)
        automatic = true
        fullAccess = false
        clipboard.check()
        XCTAssertEqual(board.reads, 0)
        fullAccess = true
        clipboard.check()
        try await settle()
        XCTAssertEqual(texts, ["first paragraph"])
        clipboard.keyboardWillDisappear()
        board.copy("copied after closing")
        clipboard.check()
        XCTAssertEqual(board.reads, 1)
    }

    func testPanelRemembersTheLastSelectionAcrossNewCopiesAndKeyboardInstances() {
        let clipboard = controller()
        clipboard.panelOpened()
        XCTAssertEqual(clipboard.tab, .dictations)
        clipboard.panelClosed()
        board.copy("pending")
        clipboard.check()
        clipboard.panelOpened()
        XCTAssertEqual(clipboard.tab, .dictations)
        clipboard.tab = .clipboard
        clipboard.panelClosed()
        XCTAssertEqual(controller().tab, .clipboard)
        clipboard.tab = .dictations
        clipboard.pasted("pending")
        clipboard.panelOpened()
        XCTAssertEqual(clipboard.tab, .dictations)
        XCTAssertEqual(controller().tab, .dictations)
    }

    func testSavingWithPanelOpenKeepsItsTabOnReopen() {
        let clipboard = controller()
        clipboard.panelOpened()
        board.copy("save from this tab")
        clipboard.check()
        clipboard.pasted("save from this tab")
        clipboard.tab = .dictations
        clipboard.panelClosed()
        clipboard.panelOpened()
        XCTAssertEqual(clipboard.tab, .dictations)
    }

    func testPermissionAndSharedHistoryLabels() {
        fullAccess = false
        let clipboard = controller(reachable: false)
        clipboard.tab = .clipboard
        clipboard.panelOpened()
        XCTAssertEqual(clipboard.panel, .needsFullAccess)
        XCTAssertEqual(clipboard.historyTitle, "History")
        XCTAssertEqual(clipboard.panelAnnouncement, "History, Clipboard")
        enabled = false
        clipboard.panelOpened()
        XCTAssertEqual(clipboard.historyTitle, "Recent dictations")
        XCTAssertEqual(clipboard.panelAnnouncement, clipboard.historyTitle)
    }

    func testOffThePanelHasNoClipboardTab() {
        let clipboard = controller()
        clipboard.tab = .clipboard
        enabled = false
        clipboard.panelOpened()
        XCTAssertEqual(clipboard.tab, .dictations)
        XCTAssertNil(clipboard.panel)
        enabled = true
        XCTAssertEqual(controller().tab, .clipboard, "Hiding the tab preserves the last selection")
    }

    func testNewCopyWaitsForATapInThePanel() async throws {
        let clipboard = controller()
        board.copy("copied in another app")
        clipboard.keyboardBecameLive()
        try await settle()
        XCTAssertEqual(board.reads, 0, "Zone stopped reading by itself")
        XCTAssertTrue(clipboard.hasUnsavedCopy)
        clipboard.panelOpened()
        XCTAssertEqual(clipboard.tab, .dictations)
        clipboard.tab = .clipboard
        // The tap on the panel's paste button hands the text over.
        clipboard.pasted("copied in another app")
        try await settle()
        XCTAssertFalse(clipboard.hasUnsavedCopy)
        XCTAssertEqual(texts, ["copied in another app"])
        guard case .loaded(let entries) = clipboard.panel else { return XCTFail() }
        XCTAssertEqual(entries.map(\.text), ["copied in another app"])
        clipboard.keyboardWillDisappear()
    }

    func testTheContainerOutOfReachShowsThatAndReadsNothing() async throws {
        let clipboard = controller(reachable: false)
        board.copy("no container")
        clipboard.keyboardBecameLive()
        try await settle()
        XCTAssertEqual(board.reads, 0)
        clipboard.panelOpened()
        XCTAssertEqual(clipboard.panel, .unreachable)
        clipboard.keyboardWillDisappear()
    }

    func testTheControllerIsFreedWithItsKeyboard() async throws {
        weak var freed: ClipboardController?
        do {
            let clipboard = controller()
            clipboard.keyboardBecameLive()
            freed = clipboard
            clipboard.keyboardWillDisappear()
        }
        try await settle()
        XCTAssertNil(freed, "a running timer must not keep an old keyboard's controller alive")
    }
}
