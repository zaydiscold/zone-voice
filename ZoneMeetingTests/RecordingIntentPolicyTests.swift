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
            _ = try await intent.perform()
            XCTAssertFalse(coordinator.isArmed)
            XCTAssertEqual(engine.starts, 0)
        }
    }

    func testOnOnOffOffForBothModes() async throws {
        await coordinator.prepareModelAndWait()
        for noteMode in [true, false] {
            var intent = SetZoneRecordingIntent(noteMode: noteMode)
            intent.value = true
            _ = try await intent.perform()
            guard case .recording = coordinator.activity else { return XCTFail("On did not record") }
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
            XCTAssertTrue(error.message.contains("already recording"), error.message)
        }
        XCTAssertEqual(coordinator.activity, before, "The independent note must keep recording")
        XCTAssertEqual(engine.starts, 1)
        coordinator.cancelDictation()
        try await coordinator.settleRecordingShortcut()
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

    func testKeyboardRequestDuringRecoveryKeepsTheRetryAndItsAudio() async throws {
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
        if let note = coordinator.lastSavedNote { coordinator.notes.delete(note) }
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

    func testClearedStandbyCardComesBackWhenZoneIsInFront() async throws {
        let (indicator, requests, _) = try await standbyWithIsland()
        let made = requests()
        for activity in Activity<RecordingActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        try await waitUntil(!indicator.isActive)
        XCTAssertFalse(indicator.isActive, "Zone sees its card go")
        XCTAssertTrue(coordinator.isArmed, "Clearing the card does not turn standby off")
        coordinator.scenePhaseChanged(.active)
        XCTAssertTrue(indicator.showsStandby, "In front, standby takes the island back")
        XCTAssertEqual(requests(), made + 1)
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
        for code in [561_017_449, 1_936_290_409, 561_015_905] {
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
            XCTAssertTrue(error.message.contains("kept in Zone"))
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
    let kind: EngineKind = .fluidMiniCPU
    var isReady = true
    var text = "A policy regression note."
    var starts = 0
    var startFails = false
    var finishFails = false
    var finishGate: PolicyFinishGate?
    func assetsPresent() -> Bool { true }
    func bytesOnDisk() -> Int64 { 0 }
    func removeAssets() throws {}
    func downloadAssets(progress: @escaping @Sendable (Double, String) -> Void) async throws {}
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {}
    func setContextHints(_ text: String) {}
    func beginUtterance() throws -> UtteranceSession {
        starts += 1
        if startFails { throw PolicyFailure.failed }
        return PolicyUtterance(text: text, fails: finishFails, gate: finishGate)
    }
    func unload() {}
}
private final class PolicyUtterance: UtteranceSession {
    let textSoFar: String
    let fails: Bool
    let gate: PolicyFinishGate?
    var audioSeconds: Double { 0 }
    var failure: Error? { nil }
    var availableAudioSamples: Int { Int.max }
    init(text: String, fails: Bool, gate: PolicyFinishGate?) { textSoFar = text; self.fails = fails; self.gate = gate }
    func feed(_ samples: [Float]) {}
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
