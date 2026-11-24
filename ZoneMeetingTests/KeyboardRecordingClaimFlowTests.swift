// by zayd/cold @ zayd.wtf

import AppIntents
import CryptoKit
import XCTest
import ZoneCore
@testable import Zone

/// The Action Button, the island, Home and the keyboard's link into Zone while the Zone keyboard
/// records by itself (`KeyboardRecordingClaim`), through the production coordinator and the real
/// Voice note and Dictate and copy intents. A live claim refuses every start with one sentence;
/// a dead one is cleared and never blocks; with no claim, every start is as it always was.
@MainActor
final class KeyboardRecordingClaimFlowTests: XCTestCase {
    private var coordinator: DictationCoordinator!
    private var engine: ClaimFlowSpeechEngine!
    private var store: UserDefaultsSharedStore!
    private var suite: String!
    private var settings: AppSettings!
    private var permission: ClaimFlowGate!
    private var notesBefore: Set<UUID> = []

    override func setUpWithError() throws {
        suite = "claim-flow-" + UUID().uuidString
        store = UserDefaultsSharedStore(suiteName: suite)
        settings = AppSettings(defaults: UserDefaults(suiteName: suite)!, store: store)
        settings.soundsEnabled = false
        settings.startsSessionOnOpen = false
        engine = ClaimFlowSpeechEngine()
        permission = ClaimFlowGate(open: true)
        let gate = permission!
        coordinator = DictationCoordinator(settings: settings, store: store, engine: engine,
                                           reviews: ReviewPrompter(store: ReviewPromptStore(suiteName: suite), appVersion: "test"),
                                           requestSessionPermission: { await gate.wait(); return true })
        notesBefore = Set(coordinator.notes.notes.map(\.id))
    }

    override func tearDown() async throws {
        await permission.open()
        if coordinator.activity.isRecording { coordinator.cancelDictation() }
        try? await coordinator.settleRecordingShortcut()
        coordinator.endSession(reason: .user)
        for note in coordinator.notes.notes where !notesBefore.contains(note.id) { coordinator.notes.delete(note) }
        coordinator = nil
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    private func claim(heartbeatAge: TimeInterval = 0, id: UUID = UUID()) -> KeyboardRecordingClaim {
        KeyboardRecordingClaim(requestID: id, since: Date().addingTimeInterval(-20), heartbeat: Date().addingTimeInterval(-heartbeatAge))
    }

    private func message(of error: Error) -> String? {
        (error as? DictationCoordinator.ShortcutFailure)?.message
    }

    private func waitFor(_ what: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func pairingCode(name: String) -> (endpoint: String, code: String) {
        let endpoint = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        let secret = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return (endpoint, "zone://pair?v=1&n=\(endpoint)&s=\(secret)\(secret)&name=\(name)")
    }

    func testOutsidePairingLinksAreIgnoredColdWarmDuringRecordingAndRepeated() async throws {
        let graph = AppGraph(engine: engine)
        let url = try XCTUnwrap(URL(string: pairingCode(name: "Example").code))
        graph.open(url)
        XCTAssertNil(graph.link.pendingPairing)
        let now = ContinuousClock.now
        graph.link.beginPairingInput(now: now)
        graph.link.offerPairing(url.absoluteString, now: now + .seconds(300))
        XCTAssertNil(graph.link.pendingPairing)
        graph.link.beginPairingInput(now: now)
        graph.link.offerPairing(url.absoluteString, now: now)
        XCTAssertEqual(graph.link.pendingPairing?.name, "Example")
        graph.link.declinePairing()
        graph.link.offerPairing(url.absoluteString, now: now)
        XCTAssertNil(graph.link.pendingPairing)
        graph.link.beginPairingInput()
        graph.open(url)
        graph.open(url)
        XCTAssertNil(graph.link.pendingPairing)
        await graph.coordinator.prepareModelAndWait()
        await graph.coordinator.startAppDictation(contextBefore: nil)
        defer { graph.coordinator.cancelDictation(); graph.coordinator.endSession(reason: .user) }
        XCTAssertTrue(graph.coordinator.activity.isRecording)
        graph.open(url)
        XCTAssertNil(graph.link.pendingPairing)
    }

    func testConfirmedCodeCannotBeUsedInAnotherWindow() throws {
        let graph = AppGraph(engine: engine)
        let (endpoint, code) = pairingCode(name: "Test")
        defer { graph.link.forget(endpoint) }
        XCTAssertFalse(graph.link.computers.contains { $0.endpointID == endpoint })
        let now = ContinuousClock.now
        graph.link.beginPairingInput(now: now)
        graph.link.offerPairing(code + "&exp=101", now: now, wallTime: Date(timeIntervalSince1970: 100))
        XCTAssertNotNil(graph.link.pendingPairing)
        graph.link.confirmPairing(now: now + .seconds(1), wallTime: Date(timeIntervalSince1970: 101))
        XCTAssertFalse(graph.link.computers.contains { $0.endpointID == endpoint })
        graph.link.beginPairingInput(now: now)
        graph.link.offerPairing(code + "&exp=1", now: now)
        XCTAssertNil(graph.link.pendingPairing)
        graph.link.beginPairingInput(now: now)
        graph.link.offerPairing(code, now: now + .seconds(299))
        XCTAssertNotNil(graph.link.pendingPairing)
        graph.link.confirmPairing(now: now + .seconds(299))
        XCTAssertTrue(graph.link.computers.contains { $0.endpointID == endpoint })
        graph.link.forget(endpoint)
        let reopened = AppGraph(engine: engine)
        reopened.link.beginPairingInput()
        reopened.link.offerPairing(code)
        XCTAssertNil(reopened.link.pendingPairing)
        XCTAssertTrue(reopened.link.notice?.contains("already used") == true)
    }

    func testExistingClipboardSettingsKeepSecretsUnlessSomeoneChoseTheFilter() {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "zone.settings.clipboardHistory")
        let upgraded = AppSettings(defaults: defaults, store: store)
        XCTAssertFalse(upgraded.clipboardSkipsSecrets)
        XCTAssertFalse(store.keyboardPreferences.clipboardSkipsSecrets)
        upgraded.clipboardSkipsSecrets = true
        let reopened = AppSettings(defaults: defaults, store: store)
        XCTAssertTrue(reopened.clipboardSkipsSecrets)
        XCTAssertTrue(store.keyboardPreferences.clipboardSkipsSecrets)
    }

    func testShortcutsChooseOneDestinationAndReturnRecentFinishedWords() throws {
        let a = PairedComputer(endpointID: "a", name: "Office")
        let b = PairedComputer(endpointID: "b", name: "Home")
        XCTAssertEqual(try SendToComputerIntent.destination(nil, from: [a]).endpointID, "a")
        XCTAssertThrowsError(try SendToComputerIntent.destination(nil, from: [a, b]))
        XCTAssertThrowsError(try SendToComputerIntent.destination("c", from: [a, b]))
        XCTAssertEqual(try SendToComputerIntent.destination("b", from: [a, b]).endpointID, "b")
        let now = Date()
        var r = TranscriptRecord(id: UUID(), text: "words", createdAt: now, updatedAt: now, audioSeconds: 0,
                                 engine: "", source: .app, status: .finished)
        XCTAssertEqual(LastDictationIntent.recentResult(r, now: now), "words")
        r.finishedAt = now
        r.updatedAt = now.addingTimeInterval(60)
        XCTAssertEqual(LastDictationIntent.recentResult(r, now: now), "words")
        XCTAssertNil(LastDictationIntent.recentResult(r, now: now.addingTimeInterval(301)))
        XCTAssertEqual(LastDictationIntent.recentResult(r, now: now.addingTimeInterval(-1)), "words")
        r.status = .cutOff
        XCTAssertNil(LastDictationIntent.recentResult(r, now: now))
    }

    func testQuietNoticeGrantedWhileLockedIsExplainedOnce() {
        XCTAssertTrue(ZoneNoticePermission.needsExplanation(requested: false, status: .provisional, explained: false))
        XCTAssertFalse(ZoneNoticePermission.needsExplanation(requested: false, status: .provisional, explained: true))
        XCTAssertFalse(ZoneNoticePermission.needsExplanation(requested: false, status: .notDetermined, explained: false))
    }

    func testNoWordsAnnouncementIncludesTheAudioOutcome() {
        XCTAssertEqual(NoteCardPhase.noWords.announcement(noWordsDetail: "Zone kept the audio."),
                       "No words heard. Zone kept the audio.")
    }

    func testSavedShortcutCanResolveAPausedComputer() async throws {
        let store = LinkCoordinator.makeStore()
        var computer = PairedComputer(endpointID: UUID().uuidString, name: "Test computer")
        computer.pausedAt = Date()
        store.add(computer)
        defer { store.remove(computer.endpointID) }
        let query = ShortcutComputer.Query()
        let saved = try await query.entities(for: [computer.endpointID])
        let choices = await query.suggestedEntities()
        XCTAssertEqual(saved.map(\.id), [computer.endpointID])
        XCTAssertFalse(choices.contains { $0.id == computer.endpointID })
        let other = PairedComputer(endpointID: UUID().uuidString, name: "Another computer")
        XCTAssertThrowsError(try SendToComputerIntent.destination(computer.endpointID, from: [other, computer])) {
            XCTAssertTrue($0.localizedDescription.contains("turn on sending to Test computer"))
        }
    }

    // MARK: The Action Button

    func testTheActionButtonRefusesBothModesWhileTheKeyboardRecords() async throws {
        await coordinator.prepareModelAndWait()
        store.keyboardRecordingClaim = claim()
        for (name, press) in [("note", { _ = try await DictateNoteIntent().perform() }),
                              ("dictate", { _ = try await DictateIntent().perform() })] as [(String, () async throws -> Void)] {
            do {
                try await press()
                XCTFail("\(name): a press while the keyboard records must be refused")
            } catch {
                XCTAssertEqual(message(of: error), KeyboardRecordingClaim.pressRefusal, name)
            }
        }
        XCTAssertEqual(NoteStartFailureRecord.standard.current(now: Date())?.message, KeyboardRecordingClaim.pressRefusal)
        XCTAssertEqual(engine.starts, 0, "Zone's microphone never armed over the keyboard's")
        XCTAssertFalse(coordinator.isArmed)
        XCTAssertFalse(coordinator.activity.isBusy)
        XCTAssertNotNil(store.keyboardRecordingClaim, "a live claim is the keyboard's; the app leaves it")
    }

    func testClearWayRefusesUnderALiveClaimForBothModes() async throws {
        store.keyboardRecordingClaim = claim(heartbeatAge: 7)
        for noteMode in [true, false] {
            do {
                try await coordinator.clearWayForShortcutStart(noteMode: noteMode)
                XCTFail("refused for noteMode \(noteMode)")
            } catch {
                XCTAssertEqual(message(of: error), KeyboardRecordingClaim.pressRefusal)
            }
        }
    }

    /// iOS ended the keyboard mid-recording: its claim went quiet. It never blocks a press.
    func testADeadClaimIsClearedAndThePressRecords() async throws {
        await coordinator.prepareModelAndWait()
        store.keyboardRecordingClaim = claim(heartbeatAge: 30)
        _ = try await DictateNoteIntent().perform()
        guard case .recording = coordinator.noteCard else { return XCTFail("The note did not start: \(String(describing: coordinator.noteCard))") }
        XCTAssertNil(store.keyboardRecordingClaim, "cleared")
        _ = try await DictateNoteIntent().perform()
        XCTAssertNotNil(coordinator.notePage)
    }

    /// `NoteActionPolicy`: a press never ends or disturbs a keyboard dictation, and a stop press
    /// for Zone's own note is never refused.
    func testAStopPressIsNeverRefused() async throws {
        await coordinator.prepareModelAndWait()
        _ = try await DictateNoteIntent().perform()
        guard case .recording = coordinator.noteCard else { return XCTFail("The note did not start") }
        store.keyboardRecordingClaim = claim()
        _ = try await DictateNoteIntent().perform()
        XCTAssertNotNil(coordinator.notePage, "the second press stopped and saved the note")
        // A saved note drops the sentence's last period.
        XCTAssertTrue(newNotesContain("A note"))
    }

    private func newNotesContain(_ text: String) -> Bool {
        coordinator.notes.notes.contains { !notesBefore.contains($0.id) && $0.text.contains(text) }
    }

    // MARK: The island, Home and the keyboard's link

    func testTheIslandsDictateAndNoteRefuseUnderALiveClaim() async throws {
        store.keyboardRecordingClaim = claim()
        for action in [IslandAction.dictate, .note] {
            do {
                try await coordinator.performIslandAction(action)
                XCTFail("\(action) refused")
            } catch {
                XCTAssertEqual(message(of: error), KeyboardRecordingClaim.pressRefusal)
            }
        }
        // Stop and Pause never read the claim.
        for action in [IslandAction.stop, .pause] {
            do { try await coordinator.performIslandAction(action); XCTFail("Nothing to stop") }
            catch { XCTAssertEqual(message(of: error), RecordingRefusal.idle) }
        }
    }

    func testClockJumpCannotReleaseTheKeyboardsMic() throws {
        let keyboard = UserDefaultsSharedStore(suiteName: suite)
        let id = UUID()
        XCTAssertTrue(keyboard.microphoneOwnership.reserveForKeyboard(recordingID: id, report: { _, code in XCTFail("Unexpected microphone lock error \(code)") }))
        defer {
            keyboard.keyboardRecordingClaim = nil
            keyboard.microphoneOwnership.keyboardStopped(recordingID: id)
        }
        for age in [-60.0, 60.0] {
            keyboard.keyboardRecordingClaim = claim(heartbeatAge: age, id: id)
            XCTAssertEqual(coordinator.keyboardRecordingRefusal(RecordingRefusal.keyboard, from: "press"), RecordingRefusal.keyboard)
            XCTAssertNotNil(keyboard.keyboardRecordingClaim)
        }
    }

    func testStalledModelEndsTheWaitAndRejectsLateCompletion() async throws {
        let gate = ClaimFlowGate(open: false)
        // A coordinator starts loading an installed model during initialization.
        let engine = ClaimFlowSpeechEngine(prepareGate: gate)
        let coordinator = DictationCoordinator(settings: settings, store: store, engine: engine)
        coordinator.modelIdleLimit = 0.05
        await coordinator.prepareModelAndWait()
        guard case .failed(let reason) = coordinator.modelState else {
            await gate.open(); return XCTFail("Still waiting for the model")
        }
        XCTAssertTrue(reason.contains("open it again"))
        XCTAssertTrue(coordinator.modelDeletionBlocker?.contains("open it again") == true)
        await gate.open()
        try await waitFor("the stalled load to close") { !coordinator.isPreparingModel }
        XCTAssertEqual(coordinator.modelState, .failed(reason))
        XCTAssertEqual(engine.starts, 0)
    }

    func testHomesStartIsRefusedUnderALiveClaim() async throws {
        await coordinator.prepareModelAndWait()
        store.keyboardRecordingClaim = claim()
        await coordinator.startAppDictation(contextBefore: nil)
        XCTAssertEqual(coordinator.activity, .failed(KeyboardRecordingClaim.appRefusal))
        XCTAssertFalse(coordinator.isArmed)
        XCTAssertEqual(engine.starts, 0)
        await coordinator.startAppDictation(contextBefore: nil, replaceActive: false, asNote: true)
        XCTAssertEqual(coordinator.noteCard, .failed(KeyboardRecordingClaim.appRefusal))
        XCTAssertEqual(engine.starts, 0)
    }

    func testTheKeyboardsLinkIntoZoneIsRefusedForAnotherRequest() async throws {
        await coordinator.prepareModelAndWait()
        let request = DictationRequest(id: UUID(), generation: 1, createdAt: Date(), inputSession: "a", contextBefore: nil)
        store.request = request
        store.status = DictationStatus(requestID: request.id, generation: 1, phase: .requested, updatedAt: Date(), message: nil)
        store.keyboardRecordingClaim = claim()
        coordinator.handle(url: ZoneContract.dictateURL(requestID: request.id))
        try await waitFor("the refusal") { coordinator.activity == .failed(KeyboardRecordingClaim.appRefusal) }
        XCTAssertEqual(store.status?.phase, .failed)
        XCTAssertEqual(store.status?.message, KeyboardRecordingClaim.appRefusal)
        XCTAssertEqual(engine.starts, 0)
    }

    func testMeetingRefusesALiveKeyboardClaimAndAcceptsAnExpiredOne() {
        store.keyboardRecordingClaim = claim()
        XCTAssertEqual(coordinator.meetingStartRefusal, KeyboardRecordingClaim.appRefusal)
        store.keyboardRecordingClaim = claim(heartbeatAge: 30)
        XCTAssertNil(coordinator.meetingStartRefusal)
    }

    // MARK: No claim: exactly as before

    func testAppStartsWithAnUnreadableLockAndReportsTheFileError() async throws {
        // The file and both ownership checks are real. Give this test a known input route.
        let hardware = FakeCaptureHardware()
        coordinator = DictationCoordinator(settings: settings, store: store, engine: engine,
                                           requestSessionPermission: { true }, captureHardware: hardware)
        let file = try XCTUnwrap(store.microphoneOwnership.file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: file) }
        let since = Date()
        let stale = claim(heartbeatAge: 30)
        store.keyboardRecordingClaim = stale
        let savedClaim = try XCTUnwrap(store.keyboardRecordingClaim)
        XCTAssertNil(coordinator.keyboardRecordingRefusal("Busy", from: "lockFileTest"))
        XCTAssertEqual(store.keyboardRecordingClaim, savedClaim, "Without the lock we cannot remove another owner's claim")

        await coordinator.prepareModelAndWait()
        await coordinator.startAppDictation(contextBefore: nil)
        XCTAssertTrue(coordinator.activity.isRecording)
        XCTAssertEqual(hardware.snapshot.starts, 1)
        XCTAssertEqual(store.session?.holdsMicrophoneLease, false)
        let events = try XCTUnwrap(Journal.app).events(since: since)
        XCTAssertTrue(events.contains {
            $0.name == "microphoneLockUnavailable" && $0.f["operation"] == "open"
                && $0.f["errno"] == String(EISDIR) && $0.f["from"] == "armCapture"
        })
    }

    func testWithNoClaimEveryStartIsAsBefore() async throws {
        XCTAssertNil(store.keyboardRecordingClaim)
        try await coordinator.clearWayForShortcutStart(noteMode: true)
        try await coordinator.clearWayForShortcutStart(noteMode: false)
        try await coordinator.performIslandAction(.dictate)
        XCTAssertTrue(coordinator.activity.isRecording, "A delivered island press can start with Zone off")
        XCTAssertNil(store.keyboardRecordingClaim)
        try await coordinator.performIslandAction(.stop)
        XCTAssertFalse(coordinator.activity.isRecording)
        await coordinator.prepareModelAndWait()
        _ = try await DictateNoteIntent().perform()
        guard case .recording = coordinator.noteCard else { return XCTFail("The note did not start") }
        XCTAssertNil(store.keyboardRecordingClaim, "the app never writes a claim")
    }

    // MARK: The heartbeat while the microphone is being claimed

    /// An Action Button note on a resumed process arms for about a second. The keyboard reads a
    /// fresh heartbeat as "Zone is taking the microphone", so arming stamps one at once.
    func testArmingStampsAFreshHeartbeatBeforeTheMicrophoneIsOn() async throws {
        await coordinator.prepareModelAndWait()
        store.session = SessionState(isArmed: false, armedUntil: nil, modelReady: true, heartbeat: Date().addingTimeInterval(-600))
        await permission.close()
        let arming = Task { try await coordinator.armSession() }
        try await waitFor("the arming heartbeat") {
            guard let beat = store.session?.heartbeat else { return false }
            return abs(beat.timeIntervalSinceNow) < 2
        }
        XCTAssertFalse(coordinator.isArmed, "stamped before the microphone is on")
        XCTAssertEqual(KeyboardCapture.route(enabled: true, systemSupports: true, microphoneGranted: true, speechAssetInstalled: true,
                                             appHeartbeat: store.session?.heartbeat, failures: .init(), now: Date()), .app)
        await permission.open()
        try await arming.value
        XCTAssertTrue(coordinator.isArmed)
    }

    func testPermissionThatReturnsAfterTimeoutCannotStartANote() async {
        await coordinator.prepareModelAndWait()
        await permission.close()
        coordinator.micStartLimit = 0.02
        await coordinator.dictateNote()
        guard case .failed(let reason) = coordinator.noteCard else { await permission.open(); return XCTFail("Still starting") }
        XCTAssertTrue(reason.contains("Settings"))
        await permission.open()
        await Task.yield()
        XCTAssertEqual(engine.starts, 0)
        XCTAssertFalse(coordinator.isArmed)
    }
}


/// Speaks "A note." for every recording.
private final class ClaimFlowSpeechEngine: SpeechEngine {
    let kind: EngineKind = .fluidMiniCPU
    var isReady = true
    var starts = 0
    private let prepareGate: ClaimFlowGate?
    init(prepareGate: ClaimFlowGate? = nil) { self.prepareGate = prepareGate }
    func assetsPresent() -> Bool { true }
    func bytesOnDisk() -> Int64 { 0 }
    func removeAssets() throws {}
    func downloadAssets(progress: @escaping @Sendable (Double, String) -> Void) async throws {}
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws { await prepareGate?.wait() }
    func setContextHints(_ text: String) {}
    func beginUtterance() throws -> UtteranceSession {
        starts += 1
        return ClaimFlowUtterance()
    }
    func unload() {}
}

private final class ClaimFlowUtterance: UtteranceSession {
    var textSoFar: String { "A note." }
    var audioSeconds: Double { 0 }
    var failure: Error? { nil }
    var availableAudioSamples: Int { 0 }
    func feed(_ samples: [Float]) {}
    func finish() async throws -> String { textSoFar }
    func cancel() {}
}

/// Holds whoever waits until it is opened.
private actor ClaimFlowGate {
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(open: Bool) { isOpen = open }
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
    func close() { isOpen = false }
}
