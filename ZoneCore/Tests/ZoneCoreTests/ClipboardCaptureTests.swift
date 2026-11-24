// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// Noticing a new copy: what is looked at, in which order, and what is never read.
@MainActor final class ClipboardCaptureTests: XCTestCase {
    final class FakeClipboard: AutomaticClipboardSource, @unchecked Sendable {
        var changeCount = 1
        var text: String? = nil
        var types = ["public.utf8-plain-text"]
        var providerTypes: [String] = []
        var providerFilters: [Bool] = []
        var onProviderCheck: ((Bool) -> Void)?
        var hasText: Bool { text != nil }
        /// How many times the text itself was read: the thing iOS may ask about.
        var reads = 0
        /// What iOS hands back; nil is a refusal.
        var refuses = false
        /// Holds the answer until `answer()` is called, like a question waiting on screen.
        var holds = false
        private var pending: [() -> Void] = []

        func copy(_ text: String?, types: [String] = ["public.utf8-plain-text"]) {
            self.text = text
            self.types = types
            changeCount += 1
        }

        func inspect(ignoring count: Int?, allowed: @escaping @Sendable () -> Bool, _ done: @escaping @MainActor @Sendable (AutomaticClipboardSnapshot?) -> Void) {
            done(!allowed() || changeCount == count ? nil : .init(count: changeCount, hasContent: hasText, types: types))
        }

        func readCopy(for count: Int, skipsSecrets: Bool, allowed: @escaping @Sendable () -> Bool,
                      _ done: @escaping @MainActor @Sendable (Int, AutomaticClipboardValue?) -> Void) {
            providerFilters.append(skipsSecrets)
            onProviderCheck?(skipsSecrets)
            guard allowed(), ClipboardPolicy.skipBeforeReading(types: providerTypes, field: .ordinary, skipsSecrets: skipsSecrets) == nil else {
                done(count, nil)
                return
            }
            readText { text in Task { @MainActor in done(self.changeCount, text.map(AutomaticClipboardValue.text)) } }
        }

        func readText(_ done: @escaping @Sendable (String?) -> Void) {
            reads += 1
            let value = refuses ? nil : text
            if holds { pending.append { done(value) } } else { DispatchQueue.main.async { done(value) } }
        }

        func answer(at index: Int = 0) { pending.remove(at: index)() }
    }

    final class Seen: ClipboardSeenStore {
        var privateChangeCount: Int?
        var seenChangeCount: Int?
        var secretFieldOpen = false
    }

    private var directory: URL!
    private var board: FakeClipboard!
    private var seen: Seen!
    private var history: ClipboardHistory!
    private var time = Date(timeIntervalSince1970: 1_795_000_000)
    private let on = ClipboardCapture.Settings(enabled: true, skipsSecrets: true)

    func testFilterOffKeepsExplicitPastesInAndAfterPrivateFields() async {
        let capture = capture()
        let settings = ClipboardCapture.Settings(enabled: true, skipsSecrets: false)
        for field: ClipboardField in [.secret, .ordinary, .signIn] {
            let words = UUID().uuidString
            board.copy(words)
            let outcome = await look(capture, settings, field: field)
            XCTAssertEqual(outcome, .waitingForTap)
            guard case .saved = capture.keepPasted(words, settings: settings, field: field) else {
                return XCTFail("Explicit paste must be kept with the filter off")
            }
        }
    }

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-capture-\(UUID().uuidString)")
        board = FakeClipboard()
        seen = Seen()
        history = ClipboardHistory(directory: directory)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func capture(route: ClipboardRoute = .keyboard) -> ClipboardCapture {
        ClipboardCapture(source: board, history: history, seen: seen, clock: { [unowned self] in self.time })
    }

    private func look(_ capture: ClipboardCapture, _ settings: ClipboardCapture.Settings? = nil,
                      field: ClipboardField = .ordinary) async -> ClipboardCapture.Outcome {
        await withCheckedContinuation { continuation in
            capture.check(settings ?? on, field: field) { continuation.resume(returning: $0) }
        }
    }

    private var texts: [String] { history.entries(now: time).map(\.text) }

    func testExplicitSaveAfterKeyboardClosedInPasswordField() {
        seen.secretFieldOpen = true
        let outcome = ClipboardCapture.keepDelivered("a password", types: [], tappedChangeCount: 2,
            deliveredChangeCount: 2, settings: .init(enabled: true, skipsSecrets: false),
            history: history, seen: seen)
        guard case .saved = outcome else { return XCTFail("Save refused") }
    }

    func testFastPasteWithDefaultSettingsKeepsEachCopy() {
        let capture = capture()
        for text in ["first", "second", "third"] {
            board.copy(text)
            let token = capture.notePasteTap()
            guard case .saved = capture.keepPasted(text, settings: .init(enabled: true, skipsSecrets: false), token: token)
            else { return XCTFail("Fast paste was dropped") }
        }
        XCTAssertEqual(Set(texts), ["first", "second", "third"])
    }

    private let auto = ClipboardCapture.Settings(enabled: true, skipsSecrets: true, automatic: true)

    func testAutomaticReadsOnlyAfterSeparateConsentAndKeepsLongTextOnce() async {
        let capture = capture()
        let text = String(repeating: "test paragraph with an embedded link https://example.org\n", count: 4_000)
        board.copy(text)
        capture.captureAutomatically(route: .app, eligibility: { self.on })
        XCTAssertEqual(board.reads, 0)
        let result = await withCheckedContinuation { continuation in
            capture.captureAutomatically(route: .app, eligibility: { self.auto }) { continuation.resume(returning: $0) }
        }
        guard case .saved(let entry) = result else { return XCTFail("Expected an automatic save") }
        XCTAssertEqual(entry.route, .app)
        XCTAssertEqual(texts, [text])
        capture.captureAutomatically(route: .keyboard, eligibility: { self.auto })
        XCTAssertEqual(board.reads, 1)
    }

    func testAutomaticReadsSkipPrivateAndMarkedCopiesBeforeReading() {
        let capture = capture()
        board.copy("ordinary words", types: ["public.text", "org.nspasteboard.ConcealedType"])
        capture.captureAutomatically(route: .app, eligibility: { self.auto })
        board.copy("private field")
        seen.secretFieldOpen = true
        capture.captureAutomatically(route: .app, eligibility: { self.auto })
        seen.secretFieldOpen = false
        seen.privateChangeCount = board.changeCount
        capture.captureAutomatically(route: .keyboard, eligibility: { self.auto })
        XCTAssertEqual(board.reads, 0)
        XCTAssertTrue(texts.isEmpty)
    }

    func testAutomaticSaveRecoversAfterStorageBecomesAvailable() async throws {
        let capture = capture()
        board.copy("recover this clipboard item")
        try FileManager.default.removeItem(at: directory)
        try Data().write(to: directory)
        let failed = expectation(description: "storage unavailable")
        capture.captureAutomatically(route: .app, eligibility: { self.auto }) { result in
            XCTAssertEqual(result, .failed)
            failed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 2)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        capture.captureAutomatically(route: .app, eligibility: { self.auto })
        XCTAssertEqual(board.reads, 1, "Avoid requesting the same copy on every poll")
        time = time.addingTimeInterval(60)
        let saved = expectation(description: "same copy saved")
        capture.captureAutomatically(route: .app, eligibility: { self.auto }) { _ in saved.fulfill() }
        await fulfillment(of: [saved], timeout: 2)
        XCTAssertEqual(texts, ["recover this clipboard item"])
    }

    func testRefusedAutomaticReadIsNotRetriedEveryPoll() async {
        let capture = capture()
        board.copy("no permission")
        board.refuses = true
        for _ in 0..<3 { capture.captureAutomatically(route: .app, eligibility: { self.auto }) }
        await Task.yield()
        XCTAssertEqual(board.reads, 1)
        XCTAssertTrue(texts.isEmpty)
    }

    func testNewestAutomaticCopySurvivesReversedDelivery() async {
        let capture = capture()
        board.holds = true
        board.copy("first")
        capture.captureAutomatically(route: .app, eligibility: { self.auto }) { _ in XCTFail("Stale copy delivered") }
        board.copy("second")
        let saved = expectation(description: "new copy persisted")
        capture.captureAutomatically(route: .app, eligibility: { self.auto }) { _ in saved.fulfill() }
        board.answer(at: 1)
        await fulfillment(of: [saved], timeout: 2)
        board.answer()
        await Task.yield()
        XCTAssertEqual(texts, ["second"])
        XCTAssertEqual(seen.seenChangeCount, board.changeCount)
    }

    func testEnablingSecretFilterBeforeDeliveryRechecksProviderForSameCopy() async {
        let capture = capture()
        board.holds = true
        board.copy("synthetic private note")
        board.providerTypes = ["org.nspasteboard.ConcealedType"]
        var settings = ClipboardCapture.Settings(enabled: true, skipsSecrets: false, automatic: true)
        let resolved = expectation(description: "read resolved under the updated setting")
        board.onProviderCheck = { filtered in
            if filtered { resolved.fulfill() }
        }
        capture.captureAutomatically(route: .app, eligibility: { settings }) { _ in
            XCTFail("Unfiltered provider result was accepted")
            resolved.fulfill()
        }
        settings = auto
        board.answer()
        await fulfillment(of: [resolved], timeout: 2)

        XCTAssertEqual(board.providerFilters, [false, true])
        XCTAssertEqual(board.reads, 1, "The newly filtered provider must be rejected before reading its text")
        XCTAssertTrue(texts.isEmpty)
    }

    func testOrdinaryCopyRetriesWhenChangedFilterInvalidatesPendingRead() async {
        let capture = capture()
        board.copy("an ordinary delayed copy")
        board.holds = true
        board.refuses = true
        var settings = ClipboardCapture.Settings(enabled: true, skipsSecrets: false, automatic: true)
        let saved = expectation(description: "ordinary copy persisted after a filtered read")
        capture.captureAutomatically(route: .keyboard, eligibility: { settings }) { outcome in
            guard case .saved = outcome else { return XCTFail("Expected an automatic save") }
            saved.fulfill()
        }
        settings = auto
        board.holds = false
        board.refuses = false
        board.answer()
        await fulfillment(of: [saved], timeout: 2)

        capture.captureAutomatically(route: .keyboard, eligibility: { settings })
        XCTAssertEqual(board.providerFilters, [false, true])
        XCTAssertEqual(texts, ["an ordinary delayed copy"])
    }

    func testLateAutomaticDeliveryChecksBoardFieldAndConsentAgain() async {
        let capture = capture()
        var allowed = true
        board.holds = true
        for change in 0..<4 {
            board.copy("private test \(change)")
            seen.privateChangeCount = nil
            allowed = true
            capture.captureAutomatically(route: .keyboard, eligibility: { allowed ? self.auto : nil })
            switch change {
            case 0: board.copy("a replacement")
            case 1: seen.privateChangeCount = board.changeCount
            case 2: allowed = false
            default: capture.cancelAutomaticRead()
            }
            board.answer()
            await Task.yield()
        }
        XCTAssertEqual(board.reads, 4)
        XCTAssertTrue(texts.isEmpty)
    }

    func testANewCopyIsKeptOnceAndNotReadAgain() async {
        let capture = capture()
        board.copy("the gate code is on the fridge")
        let outcome = await look(capture)
        XCTAssertEqual(outcome, .waitingForTap)
        XCTAssertTrue(texts.isEmpty)
        guard case .saved = capture.keepPasted("the gate code is on the fridge", settings: on) else { return XCTFail() }
        let again = await look(capture)
        XCTAssertEqual(again, .unchanged)
        XCTAssertEqual(board.reads, 0)
    }

    func testOffNothingIsLookedAtOrRead() async {
        let capture = capture()
        board.copy("anything")
        let outcome = await look(capture, .init(enabled: false, skipsSecrets: true))
        XCTAssertEqual(outcome, .off)
        XCTAssertEqual(board.reads, 0)
        XCTAssertNil(seen.seenChangeCount)
        XCTAssertTrue(texts.isEmpty)
    }

    func testWhatTheKeyboardKeptTheAppDoesNotReadAgain() async {
        board.copy("shared between the two")
        let keyboard = capture()
        _ = await look(keyboard)
        _ = keyboard.keepPasted("shared between the two", settings: on)
        let app = await look(capture(route: .app))
        XCTAssertEqual(app, .unchanged, "they share the last change dealt with")
        XCTAssertEqual(board.reads, 0)
    }

    func testAnImageIsNotTextAndIsMarkedDealtWith() async {
        let capture = capture()
        board.copy(nil, types: ["public.png"])
        let outcome = await look(capture)
        XCTAssertEqual(outcome, .notText)
        XCTAssertEqual(board.reads, 0)
        let again = await look(capture)
        XCTAssertEqual(again, .unchanged)
    }

    func testZonesOwnCopyIsNeverReadOrCounted() async {
        let capture = capture()
        board.copy("a dictation already in History", types: ["public.utf8-plain-text", ClipboardPolicy.ownType])
        _ = await look(capture)
        let outcome = capture.keepPasted(board.text ?? "", settings: on, types: board.types)
        XCTAssertEqual(outcome, .skipped(.own))
        XCTAssertEqual(board.reads, 0)
        XCTAssertTrue(history.skips.isEmpty)
        XCTAssertTrue(texts.isEmpty)
    }

    func testAConcealedCopyIsNeverReadHereOrLater() async {
        let capture = capture()
        board.copy("hunter2hunter2", types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"])
        _ = await look(capture)
        let outcome = capture.keepPasted(board.text ?? "", settings: on, types: board.types)
        XCTAssertEqual(outcome, .skipped(.concealed))
        let later = await look(capture)
        XCTAssertEqual(later, .unchanged)
        XCTAssertEqual(board.reads, 0)
        XCTAssertEqual(history.skips, [.concealed: 1])
    }

    func testACopySeenInAPasswordFieldIsNeverReadEvenInTheNextField() async {
        let capture = capture()
        board.copy("just an ordinary looking phrase")
        let inPassword = await look(capture, field: .secret)
        XCTAssertEqual(inPassword, .skipped(.privateField))
        let inMessages = await look(capture, field: .ordinary)
        XCTAssertEqual(capture.keepPasted("just an ordinary looking phrase", settings: on), .skipped(.privateField))
        XCTAssertEqual(inMessages, .unchanged, "copied for a password field: not picked up afterwards either")
        XCTAssertEqual(board.reads, 0)
        XCTAssertTrue(texts.isEmpty)
    }

    func testAUserNameFieldHoldsTheCopyBackWithoutCondemningIt() async {
        let capture = capture()
        board.copy("remember to email Dana the deck")
        for _ in 0..<3 {
            let held = await look(capture, field: .signIn)
            XCTAssertEqual(held, .heldBack)
        }
        XCTAssertEqual(board.reads, 0)
        XCTAssertTrue(history.skips.isEmpty, "looked at every second while the keyboard is up: nothing is counted")
        let ordinary = await look(capture, field: .ordinary)
        XCTAssertEqual(ordinary, .waitingForTap)
        XCTAssertTrue(texts.isEmpty)
    }

    func testDeliveredProviderKeepsItsPrivacyMarkerAfterAnotherCopy() {
        board.copy("replacement")
        XCTAssertEqual(capture().keepPasted("old", settings: on, types: ["org.nspasteboard.ConcealedType"]), .skipped(.concealed))
        XCTAssertTrue(texts.isEmpty)
    }

    func testPastedTextIsKeptUnderTheSameRules() async {
        let capture = capture()
        board.copy("pasted with the Paste key")
        _ = await look(capture)
        guard case .saved = capture.keepPasted("pasted with the Paste key", settings: on) else { return XCTFail() }
        board.copy("481516")
        _ = await look(capture)
        XCTAssertEqual(capture.keepPasted("481516", settings: on), .skipped(.code))
        XCTAssertEqual(capture.keepPasted("x", settings: .init(enabled: false, skipsSecrets: true)), .off)
        XCTAssertEqual(capture.keepPasted("typed into a user name field", settings: on, field: .signIn), .heldBack)
        board.copy("p", types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"])
        XCTAssertEqual(capture.keepPasted("p", settings: on, types: board.types), .skipped(.concealed))
        XCTAssertEqual(board.reads, 0, "a paste never reads the clipboard a second time")
        XCTAssertEqual(texts, ["pasted with the Paste key"])
    }

    func testTheSeenStoreKeepsItsNumberInTheSharedDefaults() {
        let suite = "clipboard-seen-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SharedClipboardSeenStore(defaults: defaults)
        XCTAssertNil(store.seenChangeCount)
        store.seenChangeCount = 57
        XCTAssertEqual(SharedClipboardSeenStore(defaults: defaults).seenChangeCount, 57)
        store.seenChangeCount = nil
        XCTAssertNil(SharedClipboardSeenStore(defaults: defaults).seenChangeCount)
        XCTAssertFalse(store.secretFieldOpen)
        store.secretFieldOpen = true
        store.privateChangeCount = 58
        XCTAssertTrue(SharedClipboardSeenStore(defaults: defaults).secretFieldOpen, "the app reads what the keyboard wrote")
        XCTAssertEqual(SharedClipboardSeenStore(defaults: defaults).privateChangeCount, 58)
        store.secretFieldOpen = false
        XCTAssertFalse(SharedClipboardSeenStore(defaults: defaults).secretFieldOpen)
    }

    // MARK: A copy the last look did not see

    func testFirstPasteSavesWithoutPollingEvenWithTheFilterOn() {
        board.copy("buy more tea")
        guard case .saved = capture().keepPasted("buy more tea", settings: on) else { return XCTFail() }
        XCTAssertEqual(texts, ["buy more tea"])
    }

    func testAPasteInACardFieldMarksTheCopyItPastedNotTheOneBefore() async {
        // The bug at ec206b52: the mark went on the change count of the last look, so a copy made
        // in the card field after that look stayed unmarked and the next field offered it.
        let capture = capture()
        board.copy("an old ordinary copy")
        _ = await look(capture, field: .secret)
        board.copy("4111 1111 1111 1111 and a name")
        XCTAssertEqual(capture.keepPasted("4111 1111 1111 1111 and a name", settings: on, field: .secret), .skipped(.privateField))
        XCTAssertEqual(seen.privateChangeCount, board.changeCount)
        let inMessages = await look(capture, field: .ordinary)
        XCTAssertEqual(inMessages, .unchanged)
        XCTAssertEqual(capture.keepPasted("4111 1111 1111 1111 and a name", settings: on), .skipped(.privateField))
        XCTAssertTrue(texts.isEmpty)
        XCTAssertEqual(history.skips, [.privateField: 2], "the old copy once, the card copy once, however often it is pasted")
    }

    func testACopyMadeInASecretFieldAfterItsLastLookIsMarkedAtTheNextLookElsewhere() async {
        let capture = capture()
        _ = await look(capture, field: .secret)
        XCTAssertTrue(seen.secretFieldOpen)
        board.copy("copied in the card field between two looks")
        let next = await look(capture, field: .ordinary)
        XCTAssertEqual(next, .skipped(.privateField), "it may have been copied in the field just left")
        XCTAssertFalse(seen.secretFieldOpen)
        board.copy("copied later, in the ordinary field")
        let later = await look(capture, field: .ordinary)
        XCTAssertEqual(later, .waitingForTap, "only the copy that could have come from the secret field is held")
        XCTAssertEqual(board.reads, 0)
    }

    func testTheLookOnTheWayOutOfASecretFieldMarksItsCopyAndClosesTheField() async {
        let keyboard = capture()
        _ = await look(keyboard, field: .secret)
        board.copy("copied in the card field, then the keyboard went away")
        let leaving = await withCheckedContinuation { continuation in
            keyboard.check(on, field: .secret, leaving: true) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(leaving, .skipped(.privateField))
        XCTAssertEqual(seen.privateChangeCount, board.changeCount)
        XCTAssertFalse(seen.secretFieldOpen, "what is copied after the keyboard has gone was copied elsewhere")
        board.copy("copied in Safari afterwards")
        guard case .saved = keepInApp("copied in Safari afterwards") else { return XCTFail("an ordinary copy was refused") }
    }

    func testAKeyboardThatEndedInASecretFieldHoldsTheNextKeyboardsFirstCopyToo() async {
        _ = await look(capture(), field: .secret)
        // That keyboard's process ended without looking again.
        board.copy("made while nobody was looking")
        let fresh = await look(capture(), field: .ordinary)
        XCTAssertEqual(fresh, .skipped(.privateField))
        XCTAssertTrue(texts.isEmpty)
    }

    // MARK: One token per paste

    func testALookDuringTheLoadCannotVouchForTheTappedPaste() async {
        let capture = capture()
        board.copy("what the tap pasted")
        _ = await look(capture)
        let token = capture.notePasteTap()
        board.copy("copied while the text loaded")
        _ = await look(capture)
        XCTAssertEqual(capture.keepPasted("what the tap pasted", settings: on, token: token), .changedSinceLook)
        XCTAssertTrue(texts.isEmpty)
    }

    func testLookDuringDeliveryStillKeepsTheTappedCopy() async {
        let capture = capture()
        board.copy("buy more tea")
        let token = capture.notePasteTap()
        _ = await look(capture)
        guard case .saved = capture.keepPasted("buy more tea", settings: on, token: token) else { return XCTFail() }
        XCTAssertEqual(texts, ["buy more tea"])
    }

    func testPastesFinishingInReverseAreEachJudgedByTheirOwnTap() async {
        let capture = capture()
        board.copy("first copy")
        _ = await look(capture)
        let first = capture.notePasteTap()
        board.copy("second copy")
        _ = await look(capture)
        let second = capture.notePasteTap()
        guard case .saved = capture.keepPasted("second copy", settings: on, token: second) else { return XCTFail() }
        XCTAssertEqual(capture.keepPasted("first copy", settings: on, token: first), .changedSinceLook)
        XCTAssertEqual(texts, ["second copy"])
    }

    func testATappedChangeMarkedPrivateStaysPrivateAfterTheBoardMoves() async {
        let capture = capture()
        board.copy("a phrase that passes every text rule")
        _ = await look(capture, field: .secret)
        let token = capture.notePasteTap()
        board.copy("an ordinary later copy")
        _ = await look(capture, field: .ordinary)
        XCTAssertEqual(capture.keepPasted("a phrase that passes every text rule", settings: on, token: token), .skipped(.privateField))
        XCTAssertTrue(texts.isEmpty)
    }

    func testTheAppJudgesEachDeliveryByItsOwnTapsToken() {
        board.copy("first copy")
        let first = ClipboardPasteToken(changeCount: board.changeCount)
        board.copy("second copy")
        let second = ClipboardPasteToken(changeCount: board.changeCount)
        func deliver(_ text: String, _ token: ClipboardPasteToken) -> ClipboardCapture.Outcome {
            ClipboardCapture.keepDelivered(text, types: board.types, token: token, deliveredChangeCount: board.changeCount,
                                           settings: on, history: history, seen: seen, now: time)
        }
        guard case .saved = deliver("second copy", second) else { return XCTFail() }
        XCTAssertEqual(deliver("first copy", first), .changedSinceLook)
        XCTAssertEqual(texts, ["second copy"])
    }

    // MARK: Save in the app

    /// The app's Save: `tapped` is the change count noted at the tap (nil: none was noted), the
    /// count at delivery is the board's now.
    private func keepInApp(_ text: String, tapped: Int?? = .none, sharedStore: Bool = true) -> ClipboardCapture.Outcome {
        let count = board.changeCount
        return ClipboardCapture.keepDelivered(text, types: board.types, tappedChangeCount: tapped ?? count,
                                              deliveredChangeCount: count, settings: on,
                                              history: history, seen: sharedStore ? seen : nil, now: time)
    }

    func testTheAppKeepsAnOrdinaryCopyAndTheKeyboardDoesNotOfferItAgain() async {
        board.copy("copied in Safari, saved in Zone")
        guard case .saved(let entry) = keepInApp("copied in Safari, saved in Zone") else { return XCTFail() }
        XCTAssertEqual(entry.route, .saved)
        let keyboard = await look(capture())
        XCTAssertEqual(keyboard, .unchanged)
        XCTAssertEqual(board.reads, 0)
    }

    func testTheAppDoesNotKeepACopyTheKeyboardSawInASecretField() async {
        // The bug at ec206b52: the app's Save took every copy as from an ordinary field.
        board.copy("a phrase that passes every text rule")
        let keyboard = capture()
        _ = await look(keyboard, field: .secret)
        _ = await look(keyboard, field: .ordinary)
        XCTAssertEqual(keepInApp("a phrase that passes every text rule"), .skipped(.privateField))
        XCTAssertTrue(texts.isEmpty)
        XCTAssertEqual(history.skips, [.privateField: 1], "counted once, by the keyboard")
    }

    func testTheAppKeepsNothingWhileTheKeyboardNeverReportedLeavingASecretField() async {
        _ = await look(capture(), field: .secret)
        board.copy("copied in the code field, then straight to Zone")
        XCTAssertEqual(keepInApp("copied in the code field, then straight to Zone"), .skipped(.privateField))
        // The keyboard comes back in an ordinary field: that copy stays held, a new one is fine.
        _ = await look(capture(), field: .ordinary)
        XCTAssertFalse(seen.secretFieldOpen)
        XCTAssertEqual(keepInApp("copied in the code field, then straight to Zone"), .skipped(.privateField))
        board.copy("a later copy from Notes")
        guard case .saved = keepInApp("a later copy from Notes") else { return XCTFail() }
        XCTAssertEqual(texts, ["a later copy from Notes"])
    }

    func testTheAppKeepsNothingWhenTheBoardMovesDuringThePaste() {
        board.copy("what the tap pasted")
        let tapped = board.changeCount
        board.copy("what arrived on the board a moment later")
        XCTAssertEqual(keepInApp("what the tap pasted", tapped: tapped), .changedSinceLook)
        XCTAssertTrue(texts.isEmpty)
        XCTAssertNotEqual(seen.seenChangeCount, board.changeCount)
    }

    func testTheAppKeepsNothingItCannotCheckAndStillHonorsMarkers() {
        board.copy("no shared store")
        XCTAssertEqual(keepInApp("no shared store", sharedStore: false), .failed, "the keyboard's marks cannot be read")
        XCTAssertEqual(ClipboardCapture.keepDelivered("x", types: [], tappedChangeCount: nil, deliveredChangeCount: board.changeCount,
                                                      settings: .init(enabled: false, skipsSecrets: true), history: history, seen: seen), .off)
        board.copy("p", types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"])
        XCTAssertEqual(keepInApp("p"), .skipped(.concealed))
        board.copy("481516")
        XCTAssertEqual(keepInApp("481516", tapped: .some(nil)), .skipped(.code), "no tap noted: the count at delivery is used")
        XCTAssertTrue(texts.isEmpty)
    }
}
