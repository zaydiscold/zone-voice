// by zayd/cold @ zayd.wtf

import ActivityKit
import AppIntents
import AVFoundation
import XCTest
import ZoneCore
@testable import Zone

/// Exercises the production coordinator, AVAudioEngine and intent entry points. Speech is
/// deterministic; these tests do not substitute a simulated microphone state machine.
@MainActor
final class RecordingIntentPolicyTests: XCTestCase {
    private var coordinator: DictationCoordinator!
    private var engine: PolicySpeechEngine!
    private var suite: String!
    private var settings: AppSettings!
    /// The rating prompt's record in the test suite, so test recordings never count in the App Group.
    private var reviews: ReviewPrompter!

    override func setUpWithError() throws {
        suite = "recording-policy-" + UUID().uuidString
        reviews = ReviewPrompter(store: ReviewPromptStore(suiteName: suite), appVersion: "test")
        let store = UserDefaultsSharedStore(suiteName: suite)
        settings = AppSettings(defaults: UserDefaults(suiteName: suite)!, store: store)
        settings.soundsEnabled = false
        settings.startsSessionOnOpen = false
        // Most of this file pins the release path: the microphone off and the indicator ended
        // before a press returns. That is what every press does with no standby card to keep the
        // microphone under (`StandbyAfterPress`). The cases that keep standby turn the card on.
        settings.islandWhileReady = false
        engine = PolicySpeechEngine()
        coordinator = DictationCoordinator(settings: settings, store: store, engine: engine, reviews: reviews,
                                           requestSessionPermission: { true })
    }

    override func tearDownWithError() throws {
        coordinator.endSession(reason: .user)
        if let note = coordinator.lastSavedNote { coordinator.notes.delete(note) }
        coordinator = nil
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    private func startNote() async throws {
        await coordinator.prepareModelAndWait()
        await coordinator.dictateNote()
        guard case .recording = coordinator.activity else {
            XCTFail("Production capture did not start: \(coordinator.activity)")
            throw PolicyFailure.failed
        }
    }

    func testNormalAndSilentStopsReleaseHiddenStandbyAfterSaving() async throws {
        for text in ["A policy regression note.", "", "   "] {
            engine.text = text
            try await startNote()
            XCTAssertNil(coordinator.lastSetupIntentNote, "An in-app note cannot confirm the button")
            await coordinator.stopDictation(reason: "shortcut")
            XCTAssertTrue(coordinator.isArmed, "Reproduces the unsafe pre-fix standby state")
            try await coordinator.settleRecordingShortcut()
            XCTAssertFalse(coordinator.isArmed)
            XCTAssertEqual(coordinator.lastResult?.text, text.trimmingCharacters(in: .whitespaces))
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                let saved = try XCTUnwrap(coordinator.lastSavedNote)
                XCTAssertTrue(coordinator.notes.notes.contains { $0.id == saved.id })
                coordinator.notes.delete(saved)
            } else {
                XCTAssertNil(coordinator.lastSavedNote)
            }
        }
    }

    /// Only a recording that ends with words counts toward the rating prompt: not a silent one,
    /// not one whose recognition failed.
    func testOnlyNotesWithWordsCountForTheRatingPrompt() async throws {
        XCTAssertEqual(reviews.state.successes, 0)
        engine.text = "A note that worked."
        try await startNote()
        await coordinator.stopDictation(reason: "shortcut")
        try await coordinator.settleRecordingShortcut()
        guard case .finished = coordinator.activity else { return XCTFail("Not finished: \(coordinator.activity)") }
        XCTAssertEqual(reviews.state.successes, 1)
        if let note = coordinator.lastSavedNote { coordinator.notes.delete(note) }

        engine.text = "   "
        try await startNote()
        await coordinator.stopDictation(reason: "shortcut")
        try await coordinator.settleRecordingShortcut()
        XCTAssertEqual(reviews.state.successes, 1, "A silent recording is not a success")

        engine.text = "Words the recognizer never returns."
        engine.finishFails = true
        try await startNote()
        await coordinator.stopDictation(reason: "shortcut")
        try? await coordinator.settleRecordingShortcut()
        guard case .failed = coordinator.activity else { return XCTFail("Recognition did not fail: \(coordinator.activity)") }
        XCTAssertEqual(reviews.state.successes, 1, "A failed recording is not a success")
        XCTAssertNil(reviews.state.lastAskedVersion, "Finishing a recording never asks by itself")
        coordinator.acknowledgeActivity()
    }

    func testIdleOffUsesRealIntentBoundaryAndNeverStartsRecording() async throws {
        await coordinator.prepareModelAndWait()
        try await coordinator.armSession()
        XCTAssertTrue(coordinator.isArmed)
        for noteMode in [true, false] {
            var intent = SetZoneRecordingIntent(noteMode: noteMode)
            intent.value = false
            let reply = try await intent.perform()
            XCTAssertNotNil((reply as? IntentResultContainer<Never, Never, Never, IntentDialog>)?.dialog)
            XCTAssertFalse(coordinator.isArmed)
            XCTAssertEqual(engine.starts, 0)
        }
    }

    func testOnlyTheSystemControlGetsTheSecondPressHint() async throws {
        let indicator = RecordingLiveActivity()
        coordinator = DictationCoordinator(settings: settings, store: UserDefaultsSharedStore(suiteName: suite),
            engine: engine, reviews: reviews, requestSessionPermission: { true }, recordingLiveActivity: indicator)
        try await startNote()
        XCTAssertEqual(indicator.latestState?.recordingHint, "Tap Stop to finish")
        do {
            try await coordinator.performIslandAction(.dictate)
            XCTFail("The island must not replace the note")
        } catch {
            XCTAssertEqual(indicator.latestState?.pressNotice, RecordingRefusal.note)
            XCTAssertEqual(indicator.latestState?.phase, .recording)
        }
        await coordinator.stopDictation(reason: "app")
        _ = try await DictateNoteIntent().perform()
        XCTAssertEqual(indicator.latestState?.recordingHint, "Tap Stop to finish")
        _ = try await DictateNoteIntent().perform()
        var control = SetZoneRecordingIntent(noteMode: true)
        control.value = true
        _ = try await control.perform()
        XCTAssertEqual(indicator.latestState?.recordingHint, "Press again to stop")
        control.value = false
        _ = try await control.perform()
    }

    func testOnOnOffOffForBothModes() async throws {
        await coordinator.prepareModelAndWait()
        for noteMode in [true, false] {
            var intent = SetZoneRecordingIntent(noteMode: noteMode)
            intent.value = true
            _ = try await intent.perform()
            guard case .recording(let id, _) = coordinator.activity else { return XCTFail("On did not record") }
            XCTAssertEqual(coordinator.lastSetupIntentNote == id, noteMode)
            let first = coordinator.activity
            _ = try await intent.perform()
            XCTAssertEqual(coordinator.activity, first, "Repeated On must not stop or replace recording")
            intent.value = false
            _ = try await intent.perform()
            XCTAssertFalse(coordinator.isArmed)
            let saved = coordinator.lastResult
            _ = try await intent.perform()
            XCTAssertFalse(coordinator.isArmed)
            XCTAssertEqual(coordinator.lastResult, saved)
            if let note = coordinator.lastSavedNote { coordinator.notes.delete(note) }
        }
    }

    /// Dictate and copy from the Action Button runs with Zone in the background. Its finished
    /// screen used to stay set, so it covered Home (and held What's New back) the next time
    /// Zone was opened, however much later.
    func testADictationCopiedOffScreenLeavesNoScreenBehind() async throws {
        await coordinator.prepareModelAndWait()
        coordinator.scenePhaseChanged(.background)
        engine.text = "Copied while Zone was away."
        var intent = SetZoneRecordingIntent(noteMode: false)
        intent.value = true
        _ = try await intent.perform()
        guard case .recording = coordinator.activity else { return XCTFail("On did not record") }
        XCTAssertTrue(coordinator.showsDictationScreen, "While it records, opening Zone shows the recording")
        intent.value = false
        _ = try await intent.perform()
        XCTAssertEqual(coordinator.lastResult?.text, "Copied while Zone was away.")
        XCTAssertFalse(coordinator.showsDictationScreen, "Copied with nobody watching: nothing waits over Home")
        XCTAssertFalse(coordinator.isBusyForWhatsNew)
    }

    /// With Zone on screen the person is looking at that dictation, so its screen stays.
    func testADictationCopiedOnScreenKeepsItsScreen() async throws {
        await coordinator.prepareModelAndWait()
        coordinator.scenePhaseChanged(.active)
        engine.text = "Copied while Zone was open."
        var intent = SetZoneRecordingIntent(noteMode: false)
        intent.value = true
        _ = try await intent.perform()
        guard case .recording = coordinator.activity else { return XCTFail("On did not record") }
        intent.value = false
        _ = try await intent.perform()
        XCTAssertEqual(coordinator.lastResult?.text, "Copied while Zone was open.")
        XCTAssertTrue(coordinator.showsDictationScreen)
    }

    /// A dictation that heard nothing copies nothing; its screen is where that is explained.
    func testADictationThatCopiedNothingKeepsItsScreen() async throws {
        await coordinator.prepareModelAndWait()
        coordinator.scenePhaseChanged(.background)
        engine.text = ""
        var intent = SetZoneRecordingIntent(noteMode: false)
        intent.value = true
        _ = try await intent.perform()
        guard case .recording = coordinator.activity else { return XCTFail("On did not record") }
        intent.value = false
        _ = try? await intent.perform()
        XCTAssertTrue(coordinator.showsDictationScreen)
    }

    func testDuplicateOffWhileRecognitionFinishesSavesOnlyOnce() async throws {
        await coordinator.prepareModelAndWait()
        let gate = PolicyFinishGate()
        engine.finishGate = gate
        var on = SetZoneRecordingIntent(noteMode: true)
        on.value = true
        _ = try await on.perform()
        var off = SetZoneRecordingIntent(noteMode: true)
        off.value = false
        let first = Task { _ = try await off.perform() }
        for _ in 0..<100 {
            if case .transcribing = coordinator.activity { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .transcribing = coordinator.activity else {
            await gate.open(); _ = try? await first.value
            return XCTFail("Stop did not reach pending recognition")
        }
        let second = Task { _ = try await off.perform() }
        await gate.open()
        try await first.value
        try await second.value
        XCTAssertEqual(engine.starts, 1)
        XCTAssertFalse(coordinator.isArmed)
        XCTAssertNotNil(coordinator.lastSavedNote)
    }

    func testStopWithSoundEnabledSettlesAudio() async throws {
        settings.soundsEnabled = true
        await coordinator.prepareModelAndWait()
        _ = try await DictateNoteIntent().perform()
        _ = try await DictateNoteIntent().perform()
        XCTAssertFalse(coordinator.isArmed)
        XCTAssertNotNil(coordinator.lastSavedNote)
    }

    func testLegacyNoteToggleStartStopAndStartAgain() async throws {
        await coordinator.prepareModelAndWait()
        for _ in 0..<3 {
            _ = try await DictateNoteIntent().perform()
            guard case .recording = coordinator.activity else { return XCTFail("Toggle did not record") }
            _ = try await DictateNoteIntent().perform()
            XCTAssertFalse(coordinator.isArmed)
            let note = try XCTUnwrap(coordinator.lastSavedNote)
            coordinator.notes.delete(note)
        }
    }

    /// A note stopped from the app (or the Dynamic Island) is recognized outside the intent
    /// queue. A press during that recognition used to return success and record nothing.
    func testPressDuringRecognitionStartedElsewhereWaitsThenRecords() async throws {
        let gate = PolicyFinishGate()
        engine.finishGate = gate
        try await startNote()
        let stop = Task { await coordinator.stopDictation(reason: "app") }
        for _ in 0..<100 {
            if case .transcribing = coordinator.activity { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .transcribing = coordinator.activity else {
            await gate.open(); await stop.value
            return XCTFail("Stop did not reach pending recognition")
        }
        let press = Task { _ = try await DictateNoteIntent().perform() }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(engine.starts, 1, "The press must wait, not start over the finishing note")
        await gate.open()
        await stop.value
        try await press.value
        XCTAssertEqual(engine.starts, 2, "The press was dropped without recording")
        guard case .recording = coordinator.activity else { return XCTFail("The press did not record") }
        if let first = coordinator.lastSavedNote { coordinator.notes.delete(first) }
        _ = try await DictateNoteIntent().perform()
        XCTAssertFalse(coordinator.isArmed)
    }

    func testPressDuringIndependentRecordingExplainsInsteadOfSilentSuccess() async throws {
        let indicator = RecordingLiveActivity(beforeRequest: {})
        let store = UserDefaultsSharedStore(suiteName: suite)
        coordinator = DictationCoordinator(settings: settings, store: store, engine: engine, reviews: reviews,
            requestSessionPermission: { true }, recordingLiveActivity: indicator)
        try await startNote()
        let before = coordinator.activity
        do {
            _ = try await DictateIntent().perform()
            XCTFail("A press that cannot start must say why")
        } catch let error as DictationCoordinator.ShortcutFailure {
            XCTAssertEqual(error.message, RecordingRefusal.note)
            XCTAssertEqual(coordinator.composerRefusal, error.message)
            for action in [IslandAction.dictate, .note] {
                do { try await coordinator.performIslandAction(action); XCTFail("Started twice") }
                catch { XCTAssertEqual(error.localizedDescription, RecordingRefusal.note) }
            }
        }
        XCTAssertEqual(coordinator.activity, before, "The independent note must keep recording")
        XCTAssertEqual(engine.starts, 1)
        coordinator.cancelDictation()
        try await coordinator.settleRecordingShortcut()
    }

    // MARK: A control that still shows On after its recording ended by itself

    private func pressNoteControl(_ on: Bool) async throws {
        var intent = SetZoneRecordingIntent(noteMode: true)
        intent.value = on
        _ = try await intent.perform()
    }

    private var isRecording: Bool {
        if case .recording = coordinator.activity { return true }
        return false
    }

    /// Zayd's phone, 2026-11-20: a note from the Action Button ended outside its control.
    /// Two seconds later he pressed again; iOS had not redrawn the control, so the press came
    /// as Off, found nothing to stop, and did nothing. It starts the next note now.
    func testAPressAfterANoteEndedByItselfStartsTheNextNote() async throws {
        await coordinator.prepareModelAndWait()
        engine.text = "The first note stopped from the island."
        try await pressNoteControl(true)
        XCTAssertTrue(isRecording)
        await coordinator.stopDictation(reason: "islandStop")
        let first = try XCTUnwrap(coordinator.lastSavedNote)

        engine.text = "The second note."
        try await pressNoteControl(false)
        XCTAssertTrue(isRecording, "The press after a note that ended by itself was dropped: \(coordinator.activity)")
        try await waitUntil(engine.starts == 2)
        XCTAssertEqual(engine.starts, 2)

        try await pressNoteControl(false)
        XCTAssertFalse(isRecording)
        let second = try XCTUnwrap(coordinator.lastSavedNote)
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertTrue(second.text.contains("second note"))
        coordinator.notes.delete(first)
    }

    /// The same press after the island's Stop, which is not the control's press either.
    func testAPressAfterTheIslandsStopStartsTheNextNote() async throws {
        await coordinator.prepareModelAndWait()
        engine.text = "Stopped from the island."
        try await pressNoteControl(true)
        try await coordinator.performIslandAction(.stop)
        let first = try XCTUnwrap(coordinator.lastSavedNote)
        try await pressNoteControl(false)
        XCTAssertTrue(isRecording)
        coordinator.cancelDictation(playsSound: false)
        coordinator.notes.delete(first)
    }

    /// Only one press is owed. Off after the control's own Off, a second Off after the one that
    /// started, and the other control's Off all stay what they were: nothing.
    func testOnlyTheFirstPressAfterThatEndingStarts() async throws {
        await coordinator.prepareModelAndWait()
        engine.text = "Stopped by its own control."
        try await pressNoteControl(true)
        try await pressNoteControl(false)
        let own = try XCTUnwrap(coordinator.lastSavedNote)
        try await pressNoteControl(false)
        XCTAssertFalse(isRecording, "Off after the control's own Off must not start")
        XCTAssertEqual(engine.starts, 1)

        engine.text = "Stopped from the island."
        try await pressNoteControl(true)
        await coordinator.stopDictation(reason: "islandStop")
        let quiet = try XCTUnwrap(coordinator.lastSavedNote)
        var dictate = SetZoneRecordingIntent(noteMode: false)
        dictate.value = false
        _ = try await dictate.perform()
        XCTAssertFalse(isRecording, "Dictate and copy was never showing On")
        XCTAssertEqual(engine.starts, 2)
        coordinator.notes.delete(own)
        coordinator.notes.delete(quiet)
    }

    /// An On press uses the owed press up too: the Off after it stops, and the one after that
    /// does nothing.
    func testAnOnPressAfterThatEndingLeavesNothingOwed() async throws {
        await coordinator.prepareModelAndWait()
        engine.text = "Stopped from the island, then pressed On."
        try await pressNoteControl(true)
        await coordinator.stopDictation(reason: "islandStop")
        let first = try XCTUnwrap(coordinator.lastSavedNote)
        try await pressNoteControl(true)
        XCTAssertTrue(isRecording)
        try await pressNoteControl(false)
        XCTAssertFalse(isRecording)
        try await pressNoteControl(false)
        XCTAssertFalse(isRecording)
        XCTAssertEqual(engine.starts, 2)
        coordinator.notes.delete(first)
    }

    func testCancelThenOffReleasesStandbyAndDoesNotCreateNote() async throws {
        try await startNote()
        coordinator.cancelDictation()
        var intent = SetZoneRecordingIntent(noteMode: true)
        intent.value = false
        _ = try await intent.perform()
        XCTAssertFalse(coordinator.isArmed)
        XCTAssertNil(coordinator.lastSavedNote)
    }

    func testFailedRecognitionThenOffReleasesStandby() async throws {
        engine.finishFails = true
        try await startNote()
        await coordinator.stopDictation(reason: "shortcut")
        guard case .failed = coordinator.activity else { return XCTFail("Expected recognition failure") }
        var intent = SetZoneRecordingIntent(noteMode: true)
        intent.value = false
        _ = try await intent.perform()
        XCTAssertFalse(coordinator.isArmed)
    }

    func testFailedUtteranceStartReleasesStandby() async throws {
        engine.startFails = true
        await coordinator.prepareModelAndWait()
        await coordinator.dictateNote()
        guard case .failed = coordinator.activity else { return XCTFail("Expected start failure") }
        guard case .failed = coordinator.noteCard else { return XCTFail("The note card must say the note failed") }
        XCTAssertNil(coordinator.lastSetupIntentNote)
        try await coordinator.settleRecordingShortcut()
        XCTAssertFalse(coordinator.isArmed)
    }

    func testUnrelatedOffNeverStopsActiveNote() async throws {
        try await startNote()
        let before = coordinator.activity
        var intent = SetZoneRecordingIntent(noteMode: false)
        intent.value = false
        // Without Live Activities, a no-op must throw rather than enter Apple's fatal
        // success check. Either outcome must preserve the unrelated in-app recording.
        do { _ = try await intent.perform() } catch is DictationCoordinator.ShortcutFailure {}
        XCTAssertEqual(coordinator.activity, before)
        XCTAssertTrue(coordinator.isArmed)
        coordinator.cancelDictation()
        try await coordinator.settleRecordingShortcut()
        XCTAssertFalse(coordinator.isArmed)
    }

    func testRepeatedIdleOffDoesNotRearmOnForegroundBounce() async throws {
        await coordinator.prepareModelAndWait()
        try await coordinator.armSession()
        for _ in 0..<20 {
            var intent = SetZoneRecordingIntent(noteMode: true)
            intent.value = false
            _ = try await intent.perform()
            coordinator.scenePhaseChanged(.inactive)
            coordinator.scenePhaseChanged(.active)
            XCTAssertFalse(coordinator.isArmed)
        }
        XCTAssertEqual(engine.starts, 0)
    }

    func testShortcutFinishPreservesAutoArmOnNextRealForeground() async throws {
        settings.startsSessionOnOpen = true
        settings.hasCompletedOnboarding = true
        await coordinator.prepareModelAndWait()
        try await coordinator.armSession()
        var intent = SetZoneRecordingIntent(noteMode: true)
        intent.value = false
        _ = try await intent.perform()
        XCTAssertFalse(coordinator.isArmed)
        coordinator.scenePhaseChanged(.background)
        coordinator.scenePhaseChanged(.active)
        for _ in 0..<100 {
            if coordinator.isArmed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(coordinator.isArmed, "Shortcut stop must not opt out of keyboard auto-arm")
    }

    func testIdleOffInvalidatesPendingArmWithoutIndicatorBeforeReturn() async throws {
        let gate = PolicyFinishGate()
        let entered = expectation(description: "independent arm waiting for permission")
        let store = UserDefaultsSharedStore(suiteName: suite)
        coordinator = DictationCoordinator(settings: settings, store: store, engine: engine, reviews: reviews,
            requestSessionPermission: { entered.fulfill(); await gate.wait(); return true })
        await coordinator.prepareModelAndWait()
        let arm = Task { try await coordinator.armSession() }
        await fulfillment(of: [entered], timeout: 3)
        var off = SetZoneRecordingIntent(noteMode: true)
        off.value = false
        do { _ = try await off.perform() } catch is DictationCoordinator.ShortcutFailure {}
        await gate.open()
        do { try await arm.value; XCTFail("Pending arm must not activate audio after an unindicated intent returns") }
        catch is CancellationError {}
        XCTAssertFalse(coordinator.isArmed)
    }

    func testTwoComposerStartsWhilePermissionIsPendingCreateOneUtterance() async throws {
        let gate = PolicyFinishGate()
        let entered = expectation(description: "waiting for permission")
        var requests = 0
        coordinator = DictationCoordinator(settings: settings, store: UserDefaultsSharedStore(suiteName: suite),
            engine: engine, reviews: reviews, requestSessionPermission: {
                requests += 1
                if requests == 1 { entered.fulfill() }
                await gate.wait()
                return true
            })
        await coordinator.prepareModelAndWait()
        let first = Task { await coordinator.startAppDictation(contextBefore: nil) }
        await fulfillment(of: [entered], timeout: 3)
        let second = Task { await coordinator.startAppDictation(contextBefore: nil) }
        // Both tasks run on the main actor. Queue the gate opening after the second start.
        await Task { @MainActor in await gate.open() }.value
        await first.value
        await second.value
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(engine.starts, 1)
    }

    func testColdKeyboardOpensWithMiniWhenDeveloperSelectedApple() async throws {
        let store = UserDefaultsSharedStore(suiteName: suite)
        let selectedApple = PolicySpeechEngine()
        selectedApple.kind = .appleSpeech
        let mini = try XCTUnwrap(engine)
        let priorChoice = EngineKind.selected
        coordinator = DictationCoordinator(settings: settings, store: store,
            engine: selectedApple, reviews: reviews, modelEngineFactory: { requested in
                XCTAssertEqual(requested, .fluidSpeechMini)
                return mini
            }, requestSessionPermission: { true }, captureHardware: FakeCaptureHardware())
        let request = DictationRequest(id: UUID(), generation: 1, createdAt: Date(), inputSession: "field", contextBefore: nil)
        store.request = request
        store.status = DictationStatus(requestID: request.id, generation: 1, phase: .requested, updatedAt: Date(), message: nil)
        coordinator.handle(url: ZoneContract.dictateURL(requestID: request.id))
        try await waitUntil(mini.starts == 1, seconds: 5)
        XCTAssertEqual(mini.starts, 1)
        XCTAssertEqual(store.status?.phase, .recording)
        XCTAssertEqual(store.status?.requestID, request.id)
        XCTAssertEqual(selectedApple.starts, 0)
        XCTAssertEqual(EngineKind.selected, priorChoice)
        coordinator.cancelDictation(playsSound: false)
    }

    func testHandedOffAudioFinishesOnceAndOffersWordsOnReturn() async throws {
        let storage = AudioRecoveryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: storage.directory) }
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let id = UUID()
        defer { try? storage.discard(id); try? FileManager.default.removeItem(at: inbox) }
        let selectedApple = PolicySpeechEngine()
        selectedApple.kind = .appleSpeech
        let mini = try XCTUnwrap(engine)
        coordinator = DictationCoordinator(settings: settings, store: UserDefaultsSharedStore(suiteName: suite),
            engine: selectedApple, reviews: reviews, recoveryStore: storage, modelEngineFactory: { requested in
                XCTAssertEqual(requested, .fluidSpeechMini)
                return mini
            }, requestSessionPermission: { true })
        let wav = inbox.appendingPathComponent(KeyboardCapture.handoffName(id))
        var writer: KeyboardAudioFile? = try KeyboardAudioFile(url: wav, sampleRate: 16_000)
        writer?.append(PCM16.encode([Float](repeating: 0.2, count: 4096)))
        _ = writer?.finish()
        writer = nil
        try storage.importKeyboardAudio(from: inbox)
        settings.neverAppleSpeech = true
        coordinator.setForeground(true)
        await coordinator.prepareModelAndWait()
        await coordinator.refreshAudioRecovery()
        try await waitUntil(coordinator.lastResult?.requestID == id)
        await coordinator.refreshAudioRecovery()
        let store = UserDefaultsSharedStore(suiteName: suite)
        XCTAssertEqual(store.result?.requestID, id)
        XCTAssertEqual(store.result?.text, engine.text)
        XCTAssertEqual(store.result?.inputSession, "audio-recovery")
        XCTAssertEqual(engine.starts, 1)
        XCTAssertEqual(selectedApple.starts, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.audioURL(id).path))
    }

    func testKeyboardRequestDuringRecoveryKeepsTheRetryAndItsAudio() async throws {
        settings.defaultTextStyle = .casual
        settings.numbers.mode = .words
        engine.text = "I saw 7 birds"
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
        let storage = AudioRecoveryStore(directory: support.appendingPathComponent("AudioRecovery"))
        let id = UUID()
        defer { try? storage.discard(id) }
        let writer = try storage.begin(id: id, engine: "test", source: .app)
        writer.append([Float](repeating: 0.2, count: 4096))
        try await writer.finish()
        try storage.markFailed(id, text: "Earlier words", message: "Retry")
        await coordinator.prepareModelAndWait()
        try await coordinator.armSession()
        let gate = PolicyFinishGate()
        engine.finishGate = gate
        coordinator.retryAudioRecovery(try XCTUnwrap(storage.records().first { $0.id == id }))
        for _ in 0..<100 where engine.starts == 0 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(engine.starts, 1)

        let store = UserDefaultsSharedStore(suiteName: suite)
        let request = DictationRequest(id: UUID(), generation: 1, createdAt: Date(), inputSession: "test", contextBefore: nil)
        store.request = request
        store.status = DictationStatus(requestID: request.id, generation: 1, phase: .requested, updatedAt: Date(), message: nil)
        DarwinNotifier.post(.requestChanged)
        for _ in 0..<100 where store.status?.phase == .requested { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.status?.phase, .failed)
        XCTAssertEqual(coordinator.activity, .transcribing(requestID: id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.audioURL(id).path))
        await gate.open()
        for _ in 0..<100 where coordinator.retryingAudioID != nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(coordinator.lastResult?.requestID, id)
        XCTAssertEqual(coordinator.lastResult?.text, engine.text)
        XCTAssertEqual(coordinator.textForRecoveryCopy(try XCTUnwrap(coordinator.lastResult).text), "I saw seven birds")
    }

    func testStoppingAnInterruptedMeetingClearsUnavailableStandby() async throws {
        await coordinator.prepareModelAndWait()
        try await coordinator.armSession()
        try await coordinator.startMeetingCapture { _ in }
        let interrupted = expectation(description: "capture interrupted")
        coordinator.onMeetingInterruption = { _ in interrupted.fulfill() }
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        await fulfillment(of: [interrupted], timeout: 3)
        coordinator.stopMeetingCapture()
        XCTAssertFalse(coordinator.isArmed)
        try await coordinator.armSession()
        XCTAssertTrue(coordinator.isArmed)
    }

    // MARK: The standby card across interruptions

    private func postInterruption(began: Bool, shouldResume: Bool = false) {
        var info: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: began
            ? AVAudioSession.InterruptionType.began.rawValue : AVAudioSession.InterruptionType.ended.rawValue]
        if !began, shouldResume { info[AVAudioSessionInterruptionOptionKey] = AVAudioSession.InterruptionOptions.shouldResume.rawValue }
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
                                        object: AVAudioSession.sharedInstance(), userInfo: info)
    }

    /// A coordinator whose island refuses new cards once `inBackground` is set, as iOS refuses
    /// `Activity.request` to an app that is not in front.
    private func standbyWithIsland() async throws -> (RecordingLiveActivity, () -> Int, (Bool) -> Void) {
        var requests = 0
        var inBackground = false
        let indicator = RecordingLiveActivity(beforeRequest: {
            requests += 1
            if inBackground { throw RecordingLiveActivity.Failure.foregroundRequired }
        })
        settings.islandWhileReady = true
        let store = UserDefaultsSharedStore(suiteName: suite)
        coordinator = DictationCoordinator(settings: settings, store: store, engine: engine, reviews: reviews,
            requestSessionPermission: { true }, recordingLiveActivity: indicator)
        await coordinator.prepareModelAndWait()
        try await coordinator.armSession()
        // On screen, as when the person turned Zone on: the card is made here.
        coordinator.scenePhaseChanged(.active)
        XCTAssertTrue(indicator.showsStandby, "Standby owns the island")
        return (indicator, { requests }, { inBackground = $0 })
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool, seconds: Double = 3) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    // MARK: A press keeps standby (StandbyAfterPress)

    private func pressNoteTwice() async throws {
        _ = try await DictateNoteIntent().perform()
        guard case .recording = coordinator.activity else {
            XCTFail("The press did not record: \(coordinator.activity)")
            throw PolicyFailure.failed
        }
        _ = try await DictateNoteIntent().perform()
    }

    /// Zayd, November 19: with standby on, a note from the Action Button turned it off. The
    /// island went back to the system's, and the keyboard's next mic tap had to open Zone.
    func testNotesFromThePressKeepAStandbyThatWasOn() async throws {
        let (indicator, requests, setBackground) = try await standbyWithIsland()
        let made = requests()
        setBackground(true)
        coordinator.scenePhaseChanged(.background)
        for round in 1...4 {
            engine.text = "Standby stays, note \(round)."
            try await pressNoteTwice()
            XCTAssertTrue(coordinator.isArmed, "Note \(round) turned standby off")
            XCTAssertTrue(indicator.showsStandby, "Note \(round) left no standby card")
            XCTAssertTrue(StandbyStoppedNotice.isScheduled, "Note \(round) left a ready Zone without its \"Zone is off\" notice")
            let saved = try XCTUnwrap(coordinator.lastSavedNote)
            XCTAssertTrue(saved.text.contains("note \(round)"))
            coordinator.notes.delete(saved)
        }
        XCTAssertEqual(requests(), made, "The one card throughout: iOS grants none from the background")
    }

    /// Standby off, Zone allowed to turn itself on: the press leaves the microphone ready, so
    /// the next press starts at once and the keyboard's mic works where it is.
    func testAPressFromOffLeavesStandbyOnForSomeoneWhoLetsZoneTurnOn() async throws {
        settings.startsSessionOnOpen = true
        settings.islandWhileReady = true
        let indicator = RecordingLiveActivity()
        coordinator = DictationCoordinator(settings: settings, store: UserDefaultsSharedStore(suiteName: suite), engine: engine,
            reviews: reviews, requestSessionPermission: { true }, recordingLiveActivity: indicator)
        await coordinator.prepareModelAndWait()
        XCTAssertFalse(coordinator.isArmed)
        for round in 1...3 {
            engine.text = "From off, note \(round)."
            try await pressNoteTwice()
            XCTAssertTrue(coordinator.isArmed, "Round \(round)")
            XCTAssertTrue(indicator.showsStandby, "Round \(round): audio is live, so the card must be up")
            if let saved = coordinator.lastSavedNote { coordinator.notes.delete(saved) }
        }
    }

    /// "Keep microphone ready" at its shortest: ready after the note, off when the time runs
    /// out, and the next press warms up, records and leaves it ready again. Round after round,
    /// never stuck on and never refusing to start.
    func testKeepReadyTimeRunsOutBetweenPressesAndTheNextPressStartsOver() async throws {
        settings.startsSessionOnOpen = true
        settings.islandWhileReady = true
        settings.sessionTimeout = 0.4
        let indicator = RecordingLiveActivity()
        coordinator = DictationCoordinator(settings: settings, store: UserDefaultsSharedStore(suiteName: suite), engine: engine,
            reviews: reviews, requestSessionPermission: { true }, recordingLiveActivity: indicator)
        await coordinator.prepareModelAndWait()
        for round in 1...3 {
            engine.text = "Timed out between, note \(round)."
            try await pressNoteTwice()
            XCTAssertTrue(coordinator.isArmed, "Round \(round): ready after the note")
            let saved = try XCTUnwrap(coordinator.lastSavedNote, "Round \(round) saved nothing")
            XCTAssertTrue(saved.text.contains("note \(round)"))
            coordinator.notes.delete(saved)
            try await waitUntil(!coordinator.isArmed)
            XCTAssertFalse(coordinator.isArmed, "Round \(round): the time ran out and the microphone went off")
            XCTAssertFalse(indicator.showsStandby, "Round \(round): no standby card without standby")
        }
    }

    /// Someone who turned Zone off gets the microphone back off after the press, and opening
    /// Zone afterwards does not turn it on: the press was not them turning it on.
    func testAPressAfterThePersonTurnedZoneOffGivesTheMicrophoneBack() async throws {
        settings.startsSessionOnOpen = true
        settings.islandWhileReady = true
        let indicator = RecordingLiveActivity()
        coordinator = DictationCoordinator(settings: settings, store: UserDefaultsSharedStore(suiteName: suite), engine: engine,
            reviews: reviews, requestSessionPermission: { true }, recordingLiveActivity: indicator)
        await coordinator.prepareModelAndWait()
        try await coordinator.armSession()
        coordinator.endSession(reason: .user)
        engine.text = "Borrowed microphone."
        try await pressNoteTwice()
        XCTAssertFalse(coordinator.isArmed)
        XCTAssertFalse(indicator.isActive, "No audio, no card")
        coordinator.scenePhaseChanged(.active)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(coordinator.isArmed, "Opening Zone must not undo the person's Off")
    }

    /// No standby card (Settings > Dynamic Island), no Live Activity to keep audio under:
    /// every press releases the microphone, even from a standby that was on.
    func testWithoutTheStandbyCardEveryPressReleasesTheMicrophone() async throws {
        settings.islandWhileReady = false
        let indicator = RecordingLiveActivity()
        coordinator = DictationCoordinator(settings: settings, store: UserDefaultsSharedStore(suiteName: suite), engine: engine,
            reviews: reviews, requestSessionPermission: { true }, recordingLiveActivity: indicator)
        await coordinator.prepareModelAndWait()
        try await coordinator.armSession()
        engine.text = "No card."
        try await pressNoteTwice()
        XCTAssertFalse(coordinator.isArmed)
        XCTAssertFalse(indicator.isActive)
        XCTAssertFalse(StandbyStoppedNotice.isScheduled, "The microphone was given back: nothing to warn about")
    }

    /// Zayd's phone, November 9 to 18: 213 interruptions (Siri, a call, another app's audio) ended
    /// with Zone in the background, and each time standby took the microphone back with no island
    /// card. Zone ended the card when the interruption began, and iOS grants no new card to an app
    /// that is not in front, so iOS drew its wide orange microphone pill instead, for a median of
    /// nine minutes, until Zone was opened. The card has to outlive the interruption.
    func testStandbyCardOutlivesAnInterruption() async throws {
        let (indicator, requests, setBackground) = try await standbyWithIsland()
        let made = requests()
        setBackground(true)
        postInterruption(began: true)
        try await waitUntil(!coordinator.isArmed)
        XCTAssertFalse(coordinator.isArmed, "The interruption takes the microphone")
        XCTAssertTrue(indicator.showsStandby, "The card stays while the microphone is away")
        XCTAssertNotNil(indicator.standbyHeldSince, "drawn as held, not as ready")
        postInterruption(began: false, shouldResume: true)
        try await waitUntil(coordinator.isArmed)
        XCTAssertTrue(coordinator.isArmed, "Standby takes the microphone back")
        XCTAssertTrue(indicator.showsStandby, "and the island with it")
        XCTAssertNil(indicator.standbyHeldSince, "ready again")
        XCTAssertEqual(requests(), made, "The same card, never a new request from the background")
    }

    /// The island counts the session's dictations and words, keeps counting across an
    /// interruption (a call does not start a new session), and forgets them when Zone turns off.
    func testIslandCountsTheSessionAcrossAnInterruption() async throws {
        let (indicator, _, _) = try await standbyWithIsland()
        let since = try XCTUnwrap(coordinator.islandSession?.since)
        engine.text = "Four words right here."
        try await startNote()
        await coordinator.stopDictation(reason: "test")
        try await waitUntil(coordinator.islandSession?.dictations == 1)
        XCTAssertEqual(coordinator.islandSession?.words, 4)
        XCTAssertEqual(indicator.latestState?.session?.dictations, 1, "The card carries the count")
        let note = try XCTUnwrap(coordinator.lastSavedNote)
        XCTAssertTrue(coordinator.notes.update(note, text: "Edited note"))
        await DictationCoordinator.historyAndWait { history in
            let session = history.stats(legacyWords: 0, legacySeconds: 0, since: since)?.1
            XCTAssertEqual(session?.words, 4)
            XCTAssertEqual(session?.kept, 4)
        }
        XCTAssertTrue(coordinator.notes.delete(note))
        postInterruption(began: true)
        try await waitUntil(!coordinator.isArmed)
        postInterruption(began: false, shouldResume: true)
        try await waitUntil(coordinator.isArmed)
        XCTAssertEqual(coordinator.islandSession?.since, since, "Same session after the interruption")
        XCTAssertEqual(coordinator.islandSession?.dictations, 1)
        coordinator.endSession(reason: .user)
        XCTAssertNil(coordinator.islandSession, "Off ends the session's numbers")
    }

    /// The person clears the card from the Lock Screen, or iOS ends it at its time limit. Zone
    /// cannot make a new one from the background; the next time Zone is in front, it does.
    /// A press of the Action Button makes its card before the microphone arms. Zone coming to
    /// the front in between must not take that card for an orphan.
    func testCardMadeBeforeArmingSurvivesZoneComingToTheFront() async throws {
        let indicator = RecordingLiveActivity(beforeRequest: {})
        let store = UserDefaultsSharedStore(suiteName: suite)
        coordinator = DictationCoordinator(settings: settings, store: store, engine: engine, reviews: reviews,
            requestSessionPermission: { true }, recordingLiveActivity: indicator)
        try indicator.prepareReady()
        XCTAssertFalse(coordinator.isArmed)
        coordinator.scenePhaseChanged(.active)
        XCTAssertTrue(indicator.isActive, "The press's card waits for its recording")
        indicator.end()
    }

    /// Clearing the card from the Lock Screen turns standby off (Zayd, 2026-11-20). Before, it
    /// stayed on with iOS's orange pill until Zone was opened. (In front, a card that goes is
    /// made again at once: `IslandUpkeep`, IslandUpkeepFlowTests.)
    func testClearedStandbyCardTurnsStandbyOff() async throws {
        let (indicator, requests, setBackground) = try await standbyWithIsland()
        var notices = 0
        coordinator.postClearedCardNotice = { notices += 1 }
        let made = requests()
        setBackground(true)
        coordinator.scenePhaseChanged(.background)
        for activity in Activity<RecordingActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        try await waitUntil(!coordinator.isArmed)
        XCTAssertFalse(indicator.isActive, "Zone sees its card go")
        XCTAssertFalse(coordinator.isArmed, "Clearing the card turns standby off")
        XCTAssertEqual(notices, 1)
        XCTAssertEqual(requests(), made, "No card is asked for from the background")
    }

    /// The phone's log, November 12 to 20: 12 of 41 presses with Zone off were refused when
    /// the engine would not start from the background (`what`), and a second press 2 to 13
    /// seconds later started every time on the phone's own microphone. The press now tries
    /// again itself.
    private func pressHardware(rate: Double = 16_000, recoveryStore: AudioRecoveryStore? = nil) -> (FakeCaptureHardware, RecordingLiveActivity, UserDefaultsSharedStore) {
        let hardware = FakeCaptureHardware(sampleRate: rate)
        let card = RecordingLiveActivity()
        let store = UserDefaultsSharedStore(suiteName: suite)
        store.defaultTextStyle = .formal
        coordinator = DictationCoordinator(settings: settings, store: store, engine: engine, recoveryStore: recoveryStore,
            requestSessionPermission: { true }, captureHardware: hardware, recordingLiveActivity: card)
        return (hardware, card, store)
    }

    private func pressNote(_ on: Bool) async throws {
        var intent = SetZoneRecordingIntent(noteMode: true)
        intent.value = on
        _ = try await intent.perform()
    }

    private func recoveryURL(_ id: UUID) throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: false)
        return AudioRecoveryStore(directory: support.appendingPathComponent("AudioRecovery")).audioURL(id)
    }

    func testSecondControlPressStopsBeforeModelIsReady() async throws {
        let gate = PolicyFinishGate()
        engine.prepareGate = gate
        let (hardware, card, store) = pressHardware(rate: 48_000)
        try await pressNote(true)
        guard case .recording(let id, _) = coordinator.activity else { return XCTFail("Missing recording") }
        XCTAssertEqual(card.latestState?.phase, .recording)
        XCTAssertEqual(card.latestState?.modelLoading, true)
        XCTAssertEqual(CarWidgetState.read().phase, .recording)
        XCTAssertEqual(store.session?.recording, true)
        XCTAssertThrowsError(try coordinator.turnStandbyOffFromControl())
        let url = try recoveryURL(id)
        for _ in 0..<47 { hardware.deliverBuffer(value: 0.25) }
        AudioHardwareQueue.sync {}
        try await waitUntil(((try? Data(contentsOf: url).count) ?? 0) > 63_000)
        let data = try Data(contentsOf: url)
        let off = Task { try await pressNote(false) }
        try await waitUntil(card.latestState?.phase == .processing)
        XCTAssertEqual(card.latestState?.modelLoading, true)
        XCTAssertFalse(hardware.snapshot.running)
        await gate.open()
        try await off.value
        XCTAssertTrue(PCM16.encode(engine.heard.withLock { $0 }) == data)
        XCTAssertEqual(coordinator.lastSavedNote?.text, engine.text)
    }

    func testAnAdmittedPressSkipsTheSilentLoadRunOnce() {
        let engine = ParakeetEngine(model: .fluidSpeechMini, useNeuralEngine: false)
        engine.skipPendingLoadWarmUp(reason: "launch")
        engine.skipPendingLoadWarmUp()
        XCTAssertEqual(engine.takeLoadWarmUpSkipReason(), "pressDuringLoad")
        XCTAssertNil(engine.takeLoadWarmUpSkipReason())
    }

    func testWarmModelWithStandbyOffSavesBufferInsideHardwareStart() async throws {
        let (hardware, _, _) = pressHardware()
        await coordinator.prepareModelAndWait()
        hardware.deliverFirstBufferOnStart = true
        try await pressNote(true)
        guard case .recording(let id, _) = coordinator.activity else { return XCTFail("Missing recording") }
        let url = try recoveryURL(id)
        let expected = PCM16.encode(Array(repeating: Float(0.25), count: 2048))
        try await waitUntil((try? Data(contentsOf: url)) == expected)
        try await pressNote(false)
        XCTAssertTrue(PCM16.encode(engine.heard.withLock { $0 }) == expected)
    }

    func testUnknownSystemErrorsStayOutOfRecordingScreens() {
        let error = NSError(domain: "AudioFixture", code: 1234,
                            userInfo: [NSLocalizedDescriptionKey: "internal-diagnostic-1234"])
        for action in [RecordingProblem.microphone, .load, .transcribe, .storage, .removeModel] {
            XCTAssertEqual(action.message(for: error), action.rawValue)
        }
        XCTAssertEqual(RecordingProblem.microphone.message(for: CaptureError.interrupted), CaptureError.interrupted.errorDescription)
    }

    func testMiniBufferAndDigitalSilenceNeverCountAsModelSubmission() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = AudioRecoveryStore(directory: directory)
        let writer = try storage.begin(id: UUID(), engine: "Mini", source: .note)
        let decode = ParakeetUtterance.decoder(manager: MiniModelLoader.manager(at: directory, repeatMargin: nil),
                                              decoderLayers: 2, lane: SerialRecognitionDecoder())
        let silent = ParakeetUtterance(decode: decode, submission: writer.submission)
        silent.feed(Array(repeating: 0, count: 16_000))
        let words = try await silent.finish()
        XCTAssertEqual(words, "")
        XCTAssertEqual(try storage.records().first?.attempts?.count, 0)
        let spoken = ParakeetUtterance(decode: decode, submission: writer.submission)
        spoken.feed(Array(repeating: 0.2, count: 16_000))
        XCTAssertEqual(try storage.records().first?.attempts?.count, 0)
        _ = try? await spoken.finish()
        XCTAssertEqual(try storage.records().first?.attempts?.count, 1)
        try await writer.finish()
    }

    func testColdPressRefusesWhenNeitherRecoveryFolderCanOpen() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let storage = AudioRecoveryStore(directory: path, fallbackDirectory: path.appendingPathComponent("fallback"))
        let (hardware, card, _) = pressHardware(recoveryStore: storage)
        do { try await pressNote(true); XCTFail("The press needed a recovery file") }
        catch { XCTAssertEqual(error.localizedDescription, AudioRecoveryError.unavailable.localizedDescription) }
        XCTAssertEqual(hardware.snapshot.activations, 0)
        XCTAssertFalse(card.isActive)
        XCTAssertFalse(coordinator.activity.isRecording)
    }

    func testColdPressUsesGroupFallbackBeforeOpeningMicrophone() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent("blocked")
        try Data().write(to: primary)
        let fallback = root.appendingPathComponent("group")
        let storage = AudioRecoveryStore(directory: primary, fallbackDirectory: fallback)
        let (hardware, _, _) = pressHardware(recoveryStore: storage)
        hardware.deliverFirstBufferOnStart = true
        try await pressNote(true)
        guard case .recording(let id, _) = coordinator.activity else { return XCTFail("Missing recording") }
        let file = fallback.appendingPathComponent(id.uuidString + ".pcm")
        try await waitUntil((try? Data(contentsOf: file)) == PCM16.encode([Float](repeating: 0.25, count: 2048)))
        try await pressNote(false)
        XCTAssertEqual(coordinator.lastSavedNote?.text, engine.text)
    }

    func testFailedColdModelLeavesAudioOnHome() async throws {
        let gate = PolicyFinishGate()
        engine.prepareGate = gate
        engine.prepareFails = true
        let (hardware, _, _) = pressHardware()
        try await pressNote(true)
        guard case .recording(let id, _) = coordinator.activity else { return XCTFail("Missing recording") }
        for _ in 0..<24 { hardware.deliverBuffer(value: 0.5) }
        AudioHardwareQueue.sync {}
        await gate.open()
        try await waitUntil(coordinator.audioRecoveryRecords.contains { $0.id == id && $0.audioBytes == 24 * 4096 })
        XCTAssertTrue(coordinator.lastError?.contains("Home") == true)
        XCTAssertEqual(coordinator.audioRecoveryRecords.first { $0.id == id }?.attempts?.count, 0)
    }

    func testMissingModelRefusesBeforeActivationOrDownload() async throws {
        // The default test coordinator can already be preparing its installed model.
        // This launch has a separate engine whose files have never been available.
        engine = PolicySpeechEngine()
        engine.filesPresent = false
        let (hardware, _, _) = pressHardware()
        do { try await pressNote(true); XCTFail("Missing model") }
        catch { XCTAssertTrue(error.localizedDescription.contains("download the speech model")) }
        XCTAssertEqual(hardware.snapshot.activations, 0)
        XCTAssertEqual(engine.prepareCalls, 0)
    }

    func testClockAndPauseFollowActualSamplesDuringLoad() async throws {
        let gate = PolicyFinishGate()
        engine.prepareGate = gate
        let (hardware, card, _) = pressHardware()
        try await pressNote(true)
        settings.soundsEnabled = true
        let armed = Date()
        try await Task.sleep(for: .milliseconds(400))
        hardware.deliverBuffer(value: 0.25)
        AudioHardwareQueue.sync {}
        try await waitUntil((card.latestState?.startedAt.timeIntervalSince(armed) ?? 0) > 0.35)
        guard case .recording(let id, let began) = coordinator.activity else { return XCTFail("Missing recording") }
        XCTAssertEqual(card.latestState?.startedAt, began)
        XCTAssertTrue(Journal.app?.events(since: armed).contains { $0.name == "pressStartCue" } == true)
        XCTAssertTrue(coordinator.recentLevels.contains { $0 > 0 })
        try await coordinator.performIslandAction(.pause)
        hardware.deliverBuffer(value: 0.5)
        AudioHardwareQueue.sync {}
        XCTAssertEqual(coordinator.noteRecordingDuration(startedAt: began, now: Date()), 2048.0 / 16_000, accuracy: 0.001)
        try await coordinator.performIslandAction(.pause)
        hardware.deliverBuffer(value: 0.75)
        AudioHardwareQueue.sync {}
        let url = try recoveryURL(id)
        let expected = PCM16.encode([Float](repeating: 0.25, count: 2048) + [Float](repeating: 0.75, count: 2048))
        try await waitUntil((try? Data(contentsOf: url)) == expected)
        let stop = Task { try await coordinator.performIslandAction(.stop) }
        try await waitUntil(card.latestState?.phase == .processing)
        await gate.open()
        try await stop.value
        XCTAssertTrue(PCM16.encode(engine.heard.withLock { $0 }) == expected)
    }

    func testKeyboardClaimArrivingDuringPermissionWaitRefusesPress() async throws {
        let hardware = FakeCaptureHardware()
        let store = UserDefaultsSharedStore(suiteName: suite)
        coordinator = DictationCoordinator(settings: settings, store: store, engine: engine,
            requestSessionPermission: {
                store.keyboardRecordingClaim = KeyboardRecordingClaim(requestID: UUID(), since: Date(), heartbeat: Date())
                return true
            }, captureHardware: hardware)
        do { try await pressNote(true); XCTFail("The keyboard owns this microphone") }
        catch { XCTAssertEqual(error.localizedDescription, KeyboardRecordingClaim.pressRefusal) }
        XCTAssertEqual(hardware.snapshot.activations, 0)
        XCTAssertFalse(store.session?.recording == true)
    }

    func testCallDuringLoadHoldsAudioAndSaves() async throws {
        let gate = PolicyFinishGate()
        engine.prepareGate = gate
        let (hardware, card, _) = pressHardware()
        try await pressNote(true)
        for _ in 0..<16 { hardware.deliverBuffer(value: 0.25) }
        AudioHardwareQueue.sync {}
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        XCTAssertTrue(coordinator.isHeld)
        XCTAssertEqual(card.latestState?.phase, .paused)
        let stop = Task { try await pressNote(false) }
        try await waitUntil(card.latestState?.phase == .processing)
        await gate.open()
        try await stop.value
        XCTAssertEqual(engine.heard.withLock { $0.count }, 16 * 2048)
        XCTAssertEqual(coordinator.lastSavedNote?.text, engine.text)
    }

    func testPressRefusedOnceFromTheBackgroundTriesAgainAndRecords() async throws {
        var arms = 0
        let store = UserDefaultsSharedStore(suiteName: suite)
        coordinator = DictationCoordinator(settings: settings, store: store, engine: engine, reviews: reviews,
            requestSessionPermission: { true },
            armSessionCapture: {
                arms += 1
                if arms == 1 { throw NSError(domain: "com.apple.coreaudio.avfaudio", code: 2_003_329_396) }
            })
        coordinator.pressFindsZoneInFront = { false }
        coordinator.pressArmPauses = [.milliseconds(20), .milliseconds(20), .milliseconds(20)]
        await coordinator.prepareModelAndWait()
        // The press's own preparation: the microphone here is a stand-in, so the recording
        // that follows it is not part of this test.
        try await coordinator.prepareRecordingShortcut(noteMode: true)
        XCTAssertEqual(arms, 2, "One refusal, one more try inside the same press")
        XCTAssertTrue(coordinator.isArmed, "The second try turned the microphone on")
        coordinator.endSession(reason: .user)
    }

    /// Refused every time: the press gives up after its tries and leaves no microphone and no
    /// card behind.
    func testPressRefusedEveryTimeGivesUpWithNothingLeftOn() async throws {
        var arms = 0
        let indicator = RecordingLiveActivity()
        let store = UserDefaultsSharedStore(suiteName: suite)
        coordinator = DictationCoordinator(settings: settings, store: store, engine: engine, reviews: reviews,
            requestSessionPermission: { true },
            armSessionCapture: {
                arms += 1
                throw NSError(domain: "com.apple.coreaudio.avfaudio", code: 2_003_329_396)
            }, recordingLiveActivity: indicator)
        coordinator.pressFindsZoneInFront = { false }
        coordinator.pressArmPauses = [.milliseconds(20), .milliseconds(20), .milliseconds(20)]
        await coordinator.prepareModelAndWait()
        do {
            _ = try await DictateNoteIntent().perform()
            XCTFail("A press that cannot record must say why")
        } catch {}
        XCTAssertGreaterThanOrEqual(arms, 4, "The first try and three more")
        XCTAssertFalse(coordinator.isArmed)
        XCTAssertFalse(indicator.isActive, "No card is left up for a microphone that never started")
        XCTAssertEqual(engine.starts, 0)
    }

    /// In front the microphone starts or it does not: nothing is waited for.
    func testPressRefusedInFrontIsNotRetried() async throws {
        var arms = 0
        let store = UserDefaultsSharedStore(suiteName: suite)
        coordinator = DictationCoordinator(settings: settings, store: store, engine: engine, reviews: reviews,
            requestSessionPermission: { true },
            armSessionCapture: {
                arms += 1
                throw NSError(domain: "com.apple.coreaudio.avfaudio", code: 2_003_329_396)
            })
        coordinator.pressFindsZoneInFront = { true }
        await coordinator.prepareModelAndWait()
        do { _ = try await DictateNoteIntent().perform(); XCTFail("Must fail") } catch {}
        XCTAssertEqual(arms, 1)
    }

    /// An interruption that ends without the hint to resume ends standby, and its card with it:
    /// keeping the card must never leave one up with the microphone off.
    func testInterruptionEndingStandbyEndsItsCard() async throws {
        let (indicator, _, setBackground) = try await standbyWithIsland()
        setBackground(true)
        postInterruption(began: true)
        try await waitUntil(!coordinator.isArmed)
        postInterruption(began: false, shouldResume: false)
        try await waitUntil(!indicator.isActive)
        XCTAssertFalse(coordinator.isArmed)
        XCTAssertFalse(indicator.isActive, "No standby, no card")
    }

    /// The person turned Zone back on while the interruption still ran (Zone was opened during a
    /// call). When iOS later reports the end, the new standby keeps its card.
    func testLateInterruptionEndKeepsTheCardOfAStandbyArmedMeanwhile() async throws {
        let (indicator, _, _) = try await standbyWithIsland()
        postInterruption(began: true)
        try await waitUntil(!coordinator.isArmed)
        try await coordinator.armSession()
        coordinator.scenePhaseChanged(.active)
        XCTAssertTrue(indicator.showsStandby)
        postInterruption(began: false, shouldResume: false)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(coordinator.isArmed)
        XCTAssertTrue(indicator.showsStandby, "A late end of an old interruption must not take this card")
    }

    func testOffDuringMeetingDoesNotReleaseItsMicrophone() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = UserDefaults.standard.object(forKey: "zone.meetings.labelSpeakers")
        defer { UserDefaults.standard.set(previous, forKey: "zone.meetings.labelSpeakers") }
        let meetings = MeetingCoordinator(dictation: coordinator, store: MeetingStore(directory: root),
                                          recover: { _ in }, requestPermission: { true })
        meetings.labelsSpeakers = false
        await coordinator.prepareModelAndWait()
        try await coordinator.armSession()
        await meetings.startRecording()
        XCTAssertTrue(meetings.hasRecordingLiveActivity)
        for mode in [true, false] {
            var intent = SetZoneRecordingIntent(noteMode: mode)
            intent.value = false
            _ = try await intent.perform()
            XCTAssertTrue(coordinator.meetingCaptureActive)
            XCTAssertTrue(meetings.isRecording)
        }
        await meetings.discardRecording()
        XCTAssertFalse(coordinator.isArmed, "A meeting touched by an intent must release standby before ending its indicator")
    }

    func testMissingIndicatorIsRestoredWithoutStoppingIndependentNote() async throws {
        var requests = 0
        let indicator = RecordingLiveActivity(beforeRequest: {
            requests += 1
            if requests == 1 { throw RecordingLiveActivity.Failure.foregroundRequired }
        })
        let store = UserDefaultsSharedStore(suiteName: suite)
        coordinator = DictationCoordinator(settings: settings, store: store, engine: engine, reviews: reviews,
            requestSessionPermission: { true }, recordingLiveActivity: indicator)
        try await startNote()
        let before = coordinator.activity
        var off = SetZoneRecordingIntent(noteMode: false)
        off.value = false
        _ = try await off.perform()
        XCTAssertEqual(coordinator.activity, before)
        XCTAssertTrue(indicator.isActive)
        XCTAssertEqual(requests, 2)
        coordinator.cancelDictation()
        try await coordinator.settleRecordingShortcut()
    }

    /// Zayd's phone, November 10: after one Action Button note, the next press started nothing
    /// until Zone was opened (12 of 12 presses in the recording log, none after a fresh launch).
    /// The finished note was cleared after the standby card was made, which ended that card,
    /// and iOS does not grant a backgrounded press a second one.
    func testStartAfterFinishedNoteKeepsItsFirstIndicator() async throws {
        try await startAfterFinishedNoteKeepsItsFirstIndicator()
    }

    /// This file runs with "Show Zone during standby" off, where arming used to end the press's
    /// card as an unwanted standby card (until November 19), costing the press a second
    /// request. The same must hold with the standby card on.
    func testStartAfterFinishedNoteKeepsItsFirstIndicatorWithTheStandbyCardOn() async throws {
        settings.islandWhileReady = true
        try await startAfterFinishedNoteKeepsItsFirstIndicator()
    }

    private func startAfterFinishedNoteKeepsItsFirstIndicator() async throws {
        var requests = 0
        let indicator = RecordingLiveActivity(beforeRequest: { requests += 1 })
        let store = UserDefaultsSharedStore(suiteName: suite)
        coordinator = DictationCoordinator(settings: settings, store: store, engine: engine, reviews: reviews,
            requestSessionPermission: { true }, recordingLiveActivity: indicator)
        await coordinator.prepareModelAndWait()
        engine.text = "The first note."
        var on = SetZoneRecordingIntent(noteMode: true)
        on.value = true
        var off = SetZoneRecordingIntent(noteMode: true)
        off.value = false
        _ = try await on.perform()
        _ = try await off.perform()
        guard case .finished = coordinator.activity else { return XCTFail("First note did not finish: \(coordinator.activity)") }
        if let note = coordinator.lastSavedNote { coordinator.notes.delete(note) }
        XCTAssertFalse(coordinator.isArmed)
        requests = 0
        _ = try await on.perform()
        guard case .recording = coordinator.activity else { return XCTFail("Second note did not start: \(coordinator.activity)") }
        XCTAssertEqual(requests, 1, "The card made for this press must survive until the recording uses it")
        XCTAssertTrue(indicator.isActive)
        _ = try await off.perform()
    }

    /// The phone's log: a press during a call or while Siri listens failed with !pri or siri,
    /// and the fallback asked a locked phone for its passcode, which could not help.
    func testBusyMicrophoneSaysSoInsteadOfOpeningZone() async throws {
        for code in [561_017_449, 1_936_290_409] {
            let store = UserDefaultsSharedStore(suiteName: suite)
            coordinator = DictationCoordinator(settings: settings, store: store, engine: engine, reviews: reviews,
                requestSessionPermission: { true },
                armSessionCapture: { throw NSError(domain: NSOSStatusErrorDomain, code: code) })
            await coordinator.prepareModelAndWait()
            do {
                _ = try await DictateNoteIntent().perform()
                XCTFail("A press that cannot record must say why")
            } catch let failure as DictationCoordinator.ShortcutFailure {
                XCTAssertTrue(failure.message.contains("call or Siri"), failure.message)
            }
            XCTAssertFalse(coordinator.isArmed)
            XCTAssertEqual(engine.starts, 0)
        }
    }

    /// "Busy" (!act) came with no call or Siri on the phone, and a second press worked, so it
    /// must not be blamed on a call or Siri.
    func testSessionBusyIsNotBlamedOnACallOrSiri() async throws {
        let error = NSError(domain: NSOSStatusErrorDomain, code: 561_015_905)
        XCTAssertFalse(DictateNoteIntent.microphoneIsBusy(error))
        XCTAssertTrue(DictateNoteIntent.microphoneIsBusy(NSError(domain: NSOSStatusErrorDomain, code: 561_017_449)))
        XCTAssertTrue(DictateNoteIntent.microphoneIsBusy(NSError(domain: NSOSStatusErrorDomain, code: 1_936_290_409)))
    }

    /// A press that could not start says what worked on the phone, never "Open Zone once".
    func testPressRefusalSaysWhatWorked() {
        XCTAssertEqual(DictateNoteIntent.pressRefusal(carPlay: false), "Zone's microphone did not start. Press again.")
        XCTAssertTrue(DictateNoteIntent.pressRefusal(carPlay: true).contains("Open Zone, then press again"))
        for carPlay in [false, true] {
            XCTAssertFalse(DictateNoteIntent.pressRefusal(carPlay: carPlay).contains("Open Zone once"))
        }
    }

    /// Presses run one at a time. A recognizer that never answered held the stop press, and
    /// with it every later press, until Zone was closed.
    func testHungRecognitionEndsThePressAndTheNextOneRecords() async throws {
        let gate = PolicyFinishGate()
        engine.finishGate = gate
        coordinator.recognitionLimitOverride = 0.4
        await coordinator.prepareModelAndWait()
        var on = SetZoneRecordingIntent(noteMode: true)
        on.value = true
        var off = SetZoneRecordingIntent(noteMode: true)
        off.value = false
        _ = try await on.perform()
        do {
            _ = try await off.perform()
            XCTFail("A recognizer that never answers must fail the press, not hold it")
        } catch let failure as DictationCoordinator.ShortcutFailure {
            XCTAssertTrue(failure.message.contains("did not respond"), failure.message)
        }
        XCTAssertFalse(coordinator.isArmed)
        engine.finishGate = nil
        _ = try await on.perform()
        guard case .recording = coordinator.activity else { return XCTFail("The next press did not record: \(coordinator.activity)") }
        _ = try await off.perform()
        if let note = coordinator.lastSavedNote { coordinator.notes.delete(note) }
        await gate.open()
    }

    func testToggleZoneTurnsStandbyOnAndOff() async throws {
        await coordinator.prepareModelAndWait()
        var on = SetZoneStandbyIntent()
        on.value = true
        var off = SetZoneStandbyIntent()
        off.value = false
        _ = try await off.perform()
        XCTAssertFalse(coordinator.isArmed, "Off while off does nothing")
        _ = try await on.perform()
        for _ in 0..<300 where !coordinator.isArmed { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(coordinator.isArmed)
        _ = try await on.perform()
        XCTAssertTrue(coordinator.isArmed, "On while on keeps the session")
        _ = try await off.perform()
        XCTAssertFalse(coordinator.isArmed)
        XCTAssertEqual(engine.starts, 0, "The control primes the microphone; it never records")
    }

    func testToggleZoneOffNeverDiscardsARecording() async throws {
        try await startNote()
        var off = SetZoneStandbyIntent()
        off.value = false
        do {
            _ = try await off.perform()
            XCTFail("Off during a recording must refuse")
        } catch let failure as DictationCoordinator.ShortcutFailure {
            XCTAssertTrue(failure.message.contains("recording"), failure.message)
        }
        guard case .recording = coordinator.activity else { return XCTFail("The recording was lost: \(coordinator.activity)") }
        coordinator.cancelDictation()
        try await coordinator.settleRecordingShortcut()
    }

    func testToggleZoneShowsOffOnceItsDeadlinePasses() {
        let now = Date()
        XCTAssertTrue(StandbyControlState(isOn: true, until: nil).isOn(at: now))
        XCTAssertTrue(StandbyControlState(isOn: true, until: now.addingTimeInterval(60)).isOn(at: now))
        XCTAssertFalse(StandbyControlState(isOn: true, until: now.addingTimeInterval(-1)).isOn(at: now))
        XCTAssertFalse(StandbyControlState(isOn: false, until: now.addingTimeInterval(60)).isOn(at: now))
    }

    func testDeadStandbyAndOldSnapshotsReadOff() throws {
        let old = try JSONDecoder().decode(StandbyControlState.self, from: Data(#"{"isOn":true}"#.utf8))
        XCTAssertFalse(old.isOn())
        let now = Date()
        let state = StandbyControlState(isOn: true, until: nil, refreshedAt: now)
        XCTAssertTrue(state.isOn(at: now.addingTimeInterval(10)))
        XCTAssertFalse(state.isOn(at: now.addingTimeInterval(CarWidgetState.staleAfter)))
    }

    func testIndependentNoteWinsDuringPressPreparation() async throws {
        try await startNote()
        let before = coordinator.activity
        do {
            try await coordinator.runRecordingShortcut(noteMode: false, finishing: nil, trigger: .control)
            XCTFail("A losing start must explain why")
        } catch let error as RecordingUnchanged {
            XCTAssertTrue(error.message.contains("another recording"))
        }
        XCTAssertEqual(coordinator.activity, before)
        XCTAssertEqual(engine.starts, 1)
    }

    func testDeactivationFailureKeepsIndicatorUntilSuccessfulRetry() async throws {
        let indicator = RecordingLiveActivity()
        var fails = true
        let store = UserDefaultsSharedStore(suiteName: suite)
        coordinator = DictationCoordinator(settings: settings, store: store, engine: engine, reviews: reviews,
            requestSessionPermission: { true }, recordingLiveActivity: indicator,
            deactivateShortcutAudio: {
                if fails { throw PolicyFailure.failed }
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            })
        await coordinator.prepareModelAndWait()
        try await coordinator.armSession()
        try indicator.prepareReady()
        do { try await coordinator.settleRecordingShortcut(); XCTFail("Expected deactivation failure") }
        catch PolicyFailure.failed {}
        XCTAssertTrue(indicator.isActive, "Never end the indicator before confirmed audio deactivation")
        fails = false
        try await coordinator.settleRecordingShortcut()
        XCTAssertFalse(indicator.isActive)
        XCTAssertFalse(coordinator.isArmed)
    }

    func testDeactivationFailureWithoutIndicatorRestoresOne() async throws {
        // An armed microphone shows the island's standby card by default (Settings > Dynamic
        // Island). This case is about arming with no indicator at all, so that card is off here.
        settings.islandWhileReady = false
        let indicator = RecordingLiveActivity()
        let store = UserDefaultsSharedStore(suiteName: suite)
        coordinator = DictationCoordinator(settings: settings, store: store, engine: engine, reviews: reviews,
            requestSessionPermission: { true }, recordingLiveActivity: indicator,
            deactivateShortcutAudio: { throw PolicyFailure.failed })
        await coordinator.prepareModelAndWait()
        try await coordinator.armSession()
        XCTAssertFalse(indicator.isActive)
        do { try await coordinator.settleRecordingShortcut(); XCTFail("Expected deactivation failure") }
        catch PolicyFailure.failed {}
        XCTAssertTrue(indicator.isActive)
    }

    func testInAppStopAfterIntentReleasesAudioBeforeEndingIndicator() async throws {
        await coordinator.prepareModelAndWait()
        _ = try await DictateNoteIntent().perform()
        await coordinator.stopDictation(reason: "user")
        for _ in 0..<100 {
            if !coordinator.isArmed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(coordinator.isArmed)
        XCTAssertNotNil(coordinator.lastSavedNote)
    }

    func testUnavailableIndicatorSavesIndependentNoteBeforeReturningError() async throws {
        let indicator = RecordingLiveActivity(beforeRequest: { throw RecordingLiveActivity.Failure.disabled })
        let store = UserDefaultsSharedStore(suiteName: suite)
        coordinator = DictationCoordinator(settings: settings, store: store, engine: engine, reviews: reviews,
            requestSessionPermission: { true }, recordingLiveActivity: indicator)
        try await startNote()
        var off = SetZoneRecordingIntent(noteMode: false)
        off.value = false
        do { _ = try await off.perform(); XCTFail("Expected explanation of safe stop") }
        catch let error as DictationCoordinator.ShortcutFailure {
            XCTAssertTrue(error.message.contains("Open Zone to check the result"))
        }
        XCTAssertFalse(coordinator.isArmed)
        XCTAssertEqual(coordinator.lastResult?.text, engine.text)
        XCTAssertTrue(coordinator.lastSavedNote?.text.hasPrefix("A policy regression note") == true)
        guard case .finished = coordinator.activity else { return XCTFail("The note must be saved, not cancelled") }
    }

    func testRealAudioTapDeliversSamplesAcrossRepeatedArms() async throws {
        let capture = AudioCaptureEngine()
        defer { capture.disarm() }
        for _ in 0..<5 {
            let received = expectation(description: "converted samples after rearm")
            let first = Locked(false)
            capture.onSamples = { samples in
                guard !samples.isEmpty else { return }
                let notify = first.withLock { sent in
                    if sent { return false }; sent = true; return true
                }
                if notify { received.fulfill() }
            }
            try await capture.arm()
            capture.startRecording()
            await fulfillment(of: [received], timeout: 3)
            capture.stopRecording()
            capture.disarm()
            XCTAssertEqual(capture.state, .stopped)
        }
    }
}

private enum PolicyFailure: Error { case failed }
private final class PolicySpeechEngine: SpeechEngine {
    var kind: EngineKind = .fluidMiniCPU
    var isReady = true
    var text = "A policy regression note."
    var starts = 0
    var startFails = false
    var finishFails = false
    let heard = Locked<[Float]>([])
    var prepareFails = false
    var prepareGate: PolicyFinishGate?
    var finishGate: PolicyFinishGate?
    var prepareCalls = 0
    var filesPresent = true
    func assetsPresent() -> Bool { filesPresent }
    func bytesOnDisk() -> Int64 { 0 }
    func removeAssets() throws {}
    func downloadAssets(progress: @escaping @Sendable (Double, String) -> Void) async throws {}
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        prepareCalls += 1
        await prepareGate?.wait()
        if prepareFails { throw PolicyFailure.failed }
    }
    func setContextHints(_ text: String) {}
    func beginUtterance() throws -> UtteranceSession {
        starts += 1
        if startFails { throw PolicyFailure.failed }
        let session = PolicyUtterance(text: text, fails: finishFails, gate: finishGate)
        session.receive = { [heard] samples in heard.withLock { $0 += samples } }
        return session
    }
    func unload() {}
}
private final class PolicyUtterance: UtteranceSession {
    let textSoFar: String
    let fails: Bool
    let gate: PolicyFinishGate?
    var audioSeconds: Double { 2 }
    var failure: Error? { nil }
    var availableAudioSamples: Int { Int.max }
    init(text: String, fails: Bool, gate: PolicyFinishGate?) { textSoFar = text; self.fails = fails; self.gate = gate }
    var receive: (([Float]) -> Void)?
    func feed(_ samples: [Float]) { receive?(samples) }
    func finish() async throws -> String {
        await gate?.wait()
        if fails { throw PolicyFailure.failed }
        return textSoFar
    }
    func cancel() {}
}

private actor PolicyFinishGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
