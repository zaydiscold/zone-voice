// by zayd/cold @ zayd.wtf

import AppIntents
import UIKit
import XCTest
import ZoneCore
@testable import Zone

/// The Dynamic Island's buttons, through the real intent (`ZoneIslandIntent.perform`) and the
/// production coordinator and microphone. Only speech recognition is a stand-in.
@MainActor
final class IslandControlTests: XCTestCase {
    private var coordinator: DictationCoordinator!
    private var engine: IslandSpeechEngine!
    private var suite: String!
    private var settings: AppSettings!
    private var card: RecordingLiveActivity!

    override func setUpWithError() throws {
        suite = "island-control-" + UUID().uuidString
        let reviews = ReviewPrompter(store: ReviewPromptStore(suiteName: suite), appVersion: "test")
        let store = UserDefaultsSharedStore(suiteName: suite)
        settings = AppSettings(defaults: UserDefaults(suiteName: suite)!, store: store)
        settings.soundsEnabled = false
        settings.startsSessionOnOpen = false
        engine = IslandSpeechEngine()
        card = RecordingLiveActivity()
        coordinator = DictationCoordinator(settings: settings, store: store, engine: engine, reviews: reviews,
                                           requestSessionPermission: { true }, recordingLiveActivity: card)
    }

    override func tearDownWithError() throws {
        coordinator.cancelDictation(playsSound: false)
        coordinator.endSession(reason: .user)
        if let note = coordinator.lastSavedNote { coordinator.notes.delete(note) }
        coordinator = nil
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    private func standby() async throws {
        await coordinator.prepareModelAndWait()
        try await coordinator.armSession()
        XCTAssertTrue(coordinator.isArmed)
    }

    private func press(_ action: IslandAction) async throws {
        _ = try await ZoneIslandIntent(action).perform()
    }

    private func expectRefusal(_ action: IslandAction, message: String,
                               file: StaticString = #filePath, line: UInt = #line) async throws {
        do {
            try await press(action)
            XCTFail("Expected the island to explain the refused press", file: file, line: line)
        } catch let refusal as DictationCoordinator.ShortcutFailure {
            XCTAssertEqual(refusal.message, message, file: file, line: line)
        }
    }

    private var isRecording: Bool {
        if case .recording = coordinator.activity { return true }
        return false
    }

    // MARK: Start

    func testDictateOnStandbyRecordsThenStopCopiesAndStandbyRemains() async throws {
        try await standby()
        engine.text = "Words spoken from the island."
        settings.defaultTextStyle = .casual
        UIPasteboard.general.string = "something older"

        try await press(.dictate)
        XCTAssertTrue(isRecording, "Dictate on standby must record: \(coordinator.activity)")
        XCTAssertEqual(engine.starts, 1)

        try await press(.stop)
        guard case .finished(let result, _) = coordinator.activity else {
            return XCTFail("Stop must finish the dictation: \(coordinator.activity)")
        }
        XCTAssertEqual(result.text, "Words spoken from the island.")
        // The copy goes through the person's text style, as the keyboard's insert does: the
        // casual style drops the final period.
        XCTAssertEqual(UIPasteboard.general.string, "Words spoken from the island",
                       "A dictation with no text field copies its words, from the island as from the Shortcut")
        XCTAssertTrue(coordinator.isArmed, "The island's own recording must hand the island back to standby, not turn Zone off")
    }

    func testKeyboardTapAtStandbyDeadlineStartsOnce() async throws {
        try await standby()
        let deadline = try XCTUnwrap(coordinator.armedUntil)
        let store = UserDefaultsSharedStore(suiteName: suite)
        let request = DictationRequest(id: UUID(), generation: 1, createdAt: deadline, inputSession: nil, contextBefore: nil)
        store.request = request
        store.status = DictationStatus(requestID: request.id, generation: 1, phase: .requested,
                                       updatedAt: deadline, message: nil)
        await coordinator.standbyReachedDeadline(deadline)
        XCTAssertTrue(isRecording)
        XCTAssertEqual(store.status?.requestID, request.id)
        XCTAssertEqual(engine.starts, 1)
        let state = StandbyControlState.read()
        XCTAssertNil(state.until)
        XCTAssertTrue(state.isOn())
    }

    func testKeyboardTapJustAfterStandbyDeadlineCannotTakeTheMicrophone() async throws {
        try await standby()
        let deadline = try XCTUnwrap(coordinator.armedUntil)
        let store = UserDefaultsSharedStore(suiteName: suite)
        let request = DictationRequest(id: UUID(), generation: 1, createdAt: deadline.addingTimeInterval(0.001),
                                       inputSession: nil, contextBefore: nil)
        store.request = request
        store.status = DictationStatus(requestID: request.id, generation: 1, phase: .requested,
                                       updatedAt: deadline, message: nil)
        await coordinator.standbyReachedDeadline(deadline)
        XCTAssertFalse(isRecording)
        XCTAssertFalse(coordinator.isArmed)
        XCTAssertEqual(engine.starts, 0)
    }

    /// Finish when quiet: the card says "Quiet" with a ring to the moment the recording ends,
    /// and stops saying it when a voice is back, on a pause, and once the recording is over.
    func testTheCardSaysQuietUntilAVoiceAPauseOrTheEnd() async throws {
        try await standby()
        try await press(.dictate)
        XCTAssertNil(card.latestState?.quiet)
        let now = Date()
        card.quiet(until: now.addingTimeInterval(8), now: now)
        XCTAssertEqual(card.latestState?.quiet, now...now.addingTimeInterval(8))
        // The same quiet, a moment later: the ring's start does not move.
        card.quiet(until: now.addingTimeInterval(8), now: now.addingTimeInterval(1))
        XCTAssertEqual(card.latestState?.quiet?.lowerBound, now)
        card.quiet(until: nil)
        XCTAssertNil(card.latestState?.quiet, "a voice is back")

        card.quiet(until: Date().addingTimeInterval(8))
        try await press(.pause)
        XCTAssertNil(card.latestState?.quiet, "a pause is not quiet")
        try await press(.pause)

        card.quiet(until: Date().addingTimeInterval(8))
        XCTAssertNotNil(card.latestState?.quiet)
        try await press(.stop)
        XCTAssertNil(card.latestState?.quiet, "nothing is quiet once the recording is over")
        // An end already in the past says nothing.
        card.quiet(until: Date().addingTimeInterval(-1))
        XCTAssertNil(card.latestState?.quiet)
    }

    func testANoteNeverAdvertisesAQuietCountdown() async throws {
        try await standby()
        try await press(.note)
        card.quiet(until: Date().addingTimeInterval(8))
        XCTAssertNil(card.latestState?.quiet)
        try await press(.stop)
    }

    func testDictateAgainRightAfterTheLastOne() async throws {
        try await standby()
        for text in ["First.", "Second."] {
            engine.text = text
            try await press(.dictate)
            XCTAssertTrue(isRecording)
            try await press(.stop)
            XCTAssertEqual(coordinator.lastResult?.text, text)
            XCTAssertTrue(coordinator.isArmed)
        }
        XCTAssertEqual(engine.starts, 2)
    }

    func testNoteOnStandbySavesANoteAndStandbyRemains() async throws {
        try await standby()
        engine.text = "A note from the island."
        try await press(.note)
        XCTAssertTrue(isRecording, "Note on standby must record: \(coordinator.activity)")
        try await press(.stop)
        let saved = try XCTUnwrap(coordinator.lastSavedNote, "Stop must save the note")
        XCTAssertTrue(coordinator.notes.notes.contains { $0.id == saved.id })
        XCTAssertTrue(coordinator.isArmed)
    }

    /// A delivered Note or Dictate action can wake Zone and must own a new visible card.
    func testColdIslandStartRecordsAndStops() async throws {
        await coordinator.prepareModelAndWait()
        for action in [IslandAction.dictate, .note] {
            XCTAssertFalse(coordinator.isArmed)
            try await press(action)
            XCTAssertTrue(isRecording)
            XCTAssertEqual(card.latestState?.phase, .recording)
            try await press(.stop)
            XCTAssertFalse(isRecording)
            coordinator.endSession(reason: .user)
        }
    }

    func testSecondDictateTapNeitherStopsNorStartsAnother() async throws {
        try await standby()
        try await press(.dictate)
        let first = coordinator.activity
        try await expectRefusal(.dictate, message: RecordingRefusal.recording)
        try await expectRefusal(.note, message: RecordingRefusal.recording)
        XCTAssertEqual(coordinator.activity, first, "A double tap must leave the first recording alone")
        XCTAssertEqual(engine.starts, 1)
    }

    // MARK: Stop

    /// The Action Button's Off for dictation ignores a note (`NoteActionPolicy`), so it can
    /// never end the wrong recording. The island's Stop is drawn on the recording's own card,
    /// so it ends whichever one that is.
    func testStopEndsARecordingAnotherSurfaceStarted() async throws {
        await coordinator.prepareModelAndWait()
        await coordinator.dictateNote()
        XCTAssertTrue(isRecording)

        var unrelatedOff = SetZoneRecordingIntent(noteMode: false)
        unrelatedOff.value = false
        _ = try await unrelatedOff.perform()
        XCTAssertTrue(isRecording, "The dictation control's Off must still leave a note alone")

        try await press(.stop)
        XCTAssertFalse(isRecording, "The island's Stop ends the recording on its card")
        XCTAssertNotNil(coordinator.lastSavedNote, "and the note is saved, not discarded")
    }

    func testStopWithNothingRecordingDoesNothing() async throws {
        try await standby()
        try await expectRefusal(.stop, message: RecordingRefusal.idle)
        try await expectRefusal(.pause, message: RecordingRefusal.idle)
        XCTAssertTrue(coordinator.isArmed)
        XCTAssertEqual(coordinator.activity, .idle)
        XCTAssertEqual(engine.starts, 0)
    }

    // MARK: The check

    /// The standby card as the island last drew it. These tests need a real card, which the
    /// simulator grants a foreground test host.
    private func standbyCard() async throws -> RecordingActivityAttributes.ContentState {
        try XCTSkipUnless(card.isActive, "No Live Activity in this environment")
        return try XCTUnwrap(card.latestState)
    }

    func testAFinishedDictationEarnsTheCheckAndItsWordCount() async throws {
        try await standby()
        engine.text = "Five words kept right here."
        try await press(.dictate)
        try await press(.stop)
        var state = try await standbyCard()
        XCTAssertEqual(state.phase, .ready)
        XCTAssertEqual(state.justFinished, true, "A dictation that kept words shows the check")
        XCTAssertEqual(state.words, 5, "with the words it kept, not a live count")

        // Clearing the result is not a second finish: the same check stays, and still ends.
        coordinator.acknowledgeActivity()
        state = try await standbyCard()
        XCTAssertEqual(state.justFinished, true)
        XCTAssertEqual(state.words, 5)
        try await Task.sleep(for: .seconds(RecordingLiveActivity.doneFor + 0.5))
        state = try await standbyCard()
        XCTAssertNil(state.justFinished, "The check is a moment: clearing the result must not make it stay")
        XCTAssertEqual(state.words, 5)
    }

    func testACancelledDictationShowsNoCheckAndNoWords() async throws {
        try await standby()
        engine.text = "Twelve words that the person then threw away with the X."
        try await press(.dictate)
        coordinator.cancelDictation(playsSound: false)
        XCTAssertEqual(coordinator.activity, .idle)
        let state = try await standbyCard()
        XCTAssertEqual(state.phase, .ready)
        XCTAssertNil(state.justFinished, "A cancel keeps nothing, so it must not say Saved")
        XCTAssertNil(state.words, "and there are no kept words to count")
    }

    func testADictationThatHeardNothingShowsNoCheck() async throws {
        try await standby()
        engine.text = ""
        try await press(.dictate)
        try await press(.stop)
        XCTAssertFalse(isRecording)
        let state = try await standbyCard()
        XCTAssertNil(state.justFinished, "No words were kept")
    }

    func testOnlyAFinishWithWordsCountsAsKept() {
        func result(_ text: String) -> DictationResult {
            DictationResult(requestID: UUID(), generation: 1, text: text, audioSeconds: 1, createdAt: Date(), inputSession: nil)
        }
        typealias Activity = DictationCoordinator.Activity
        XCTAssertEqual(Activity.finished(result("one two  three\nfour"), origin: .keyboard).keptWords, 4)
        XCTAssertNil(Activity.finished(result("  \n"), origin: .app).keptWords)
        XCTAssertNil(Activity.idle.keptWords)
        XCTAssertNil(Activity.failed("Could not save the note.").keptWords)
        XCTAssertNil(Activity.transcribing(requestID: UUID()).keptWords)
        XCTAssertNil(Activity.recording(requestID: UUID(), startedAt: Date()).keptWords)
    }

    // MARK: One owner for every control

    /// A dictation started on the island has no text field, exactly like one started by the
    /// Action Button, so the Dictate and copy control must show it as recording and stop it.
    /// It used to show Off, send On, and do nothing.
    func testTheDictateControlSeesAndStopsAnIslandDictation() async throws {
        try await standby()
        engine.text = "Started on the island."
        settings.defaultTextStyle = .casual
        UIPasteboard.general.string = "something older"
        try await press(.dictate)
        XCTAssertTrue(isRecording)

        XCTAssertTrue(coordinator.shouldRunRecordingControl(noteMode: false, desiredState: false),
                      "The control's Off applies to this recording")
        XCTAssertFalse(coordinator.shouldRunRecordingControl(noteMode: true, desiredState: false),
                       "The Voice note control still leaves a dictation alone")
        if card.isActive {
            XCTAssertEqual(card.latestState?.controlOwned, true, "The card says a control owns it")
            let widget = CarWidgetState.read()
            XCTAssertEqual(widget.phase, .recording, "so the control draws Stop, not Dictate")
            XCTAssertFalse(widget.noteMode)
        }

        var off = SetZoneRecordingIntent(noteMode: false)
        off.value = false
        _ = try await off.perform()
        XCTAssertFalse(isRecording, "The control's Off stops the island's dictation")
        XCTAssertEqual(coordinator.lastResult?.text, "Started on the island.")
        XCTAssertEqual(UIPasteboard.general.string, "Started on the island", "and copies it, as its own stop does")
    }

    /// A save with the microphone off (standby off) gets no heartbeat, and recognition may take a
    /// minute or more. The card refreshes itself, so the island, the widget and the controls do
    /// not call a working Zone dead after `CarWidgetState.staleAfter`.
    func testASaveWithTheMicrophoneOffStaysFresh() async throws {
        try card.start(noteMode: true, controlOwned: true, onLost: { _ in })
        try XCTSkipUnless(card.isActive, "Live Activities are unavailable on this simulator")
        card.processing()
        let first = CarWidgetState.read()
        XCTAssertEqual(first.phase, .processing)
        try await Task.sleep(for: .seconds(RecordingLiveActivity.refreshInterval + 2))
        let later = CarWidgetState.read()
        XCTAssertEqual(later.phase, .processing)
        XCTAssertGreaterThan(later.updatedAt, first.updatedAt, "refreshed with no microphone heartbeat")
        XCTAssertEqual(later.controlShows(noteMode: true, now: first.updatedAt.addingTimeInterval(CarWidgetState.staleAfter + 1)),
                       .saving, "still Saving past the limit the first write alone would allow")
        card.end()
    }

    /// A keyboard dictation has a text field waiting for it. No control owns it.
    func testAKeyboardDictationIsNotControlOwned() async throws {
        try await standby()
        await coordinator.startAppDictation(contextBefore: nil)
        XCTAssertTrue(isRecording)
        XCTAssertFalse(coordinator.shouldRunRecordingControl(noteMode: false, desiredState: false))
        if card.isActive {
            XCTAssertNotEqual(card.latestState?.controlOwned, true)
            let widget = CarWidgetState.read()
            XCTAssertEqual(widget.phase, .recording, "Zone is not free, so the file says so")
            XCTAssertEqual(widget.controlOwned, false)
            XCTAssertEqual(widget.controlShows(noteMode: false), .busy(note: false, saving: false),
                           "Dictate and copy shows Dictating, not a Stop it cannot perform")
            XCTAssertEqual(widget.controlShows(noteMode: true), .busy(note: false, saving: false),
                           "and Voice note does not claim Off")
        }
    }

    // MARK: Pause

    func testPauseThenResumeThenStopKeepsTheWords() async throws {
        try await standby()
        engine.text = "Paused in the middle."
        try await press(.dictate)
        XCTAssertFalse(coordinator.isPaused)

        try await press(.pause)
        XCTAssertTrue(coordinator.isPaused)
        XCTAssertTrue(isRecording, "Pause holds the recording; it does not end it")

        try await press(.pause)
        XCTAssertFalse(coordinator.isPaused, "The same button resumes")

        try await press(.pause)
        try await press(.stop)
        XCTAssertFalse(coordinator.isPaused, "Stop while paused finishes and clears the pause")
        XCTAssertEqual(coordinator.lastResult?.text, "Paused in the middle.")
    }

    func testAnUnknownActionIsIgnored() async throws {
        try await standby()
        var intent = ZoneIslandIntent()
        intent.action = "selfDestruct"
        _ = try await intent.perform()
        XCTAssertTrue(coordinator.isArmed)
        XCTAssertEqual(engine.starts, 0)
    }
}

// MARK: - The caption

final class IslandCaptionTests: XCTestCase {
    func testCaptionShowsWordsWithoutPunctuationChurn() {
        // A recognizer that adds a comma, then a period, then rewrites both must not change
        // the caption at all.
        let drafts = ["so the island hears me", "so, the island hears me", "So the island hears me."]
        XCTAssertEqual(Set(drafts.map { IslandCaption.tail(of: $0)?.lowercased() }).count, 1)
        XCTAssertEqual(IslandCaption.tail(of: "Well, it's a well-known trick: right?"), "Well it's a well-known trick right")
    }

    func testLongCaptionStartsOnAWordAndKeepsTheNewest() {
        let text = (1...40).map { "word\($0)" }.joined(separator: ", ")
        let tail = try! XCTUnwrap(IslandCaption.tail(of: text))
        XCTAssertTrue(tail.hasPrefix("…word"), tail)
        XCTAssertTrue(tail.hasSuffix("word40"), tail)
        XCTAssertLessThanOrEqual(tail.count, IslandCaption.maxCharacters + 1)
    }

    func testEmptyAndPunctuationOnlyHaveNoCaption() {
        XCTAssertNil(IslandCaption.tail(of: ""))
        XCTAssertNil(IslandCaption.tail(of: " ,.  "))
    }
}

// MARK: - The stand-in recognizer

private final class IslandSpeechEngine: SpeechEngine {
    let kind: EngineKind = .fluidMiniCPU
    var isReady = true
    var text = "Island."
    var starts = 0
    func assetsPresent() -> Bool { true }
    func bytesOnDisk() -> Int64 { 0 }
    func removeAssets() throws {}
    func downloadAssets(progress: @escaping @Sendable (Double, String) -> Void) async throws {}
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {}
    func setContextHints(_ text: String) {}
    func beginUtterance() throws -> UtteranceSession {
        starts += 1
        return IslandUtterance(textSoFar: text)
    }
    func unload() {}
}

private final class IslandUtterance: UtteranceSession {
    let textSoFar: String
    var audioSeconds: Double { 0 }
    var failure: Error? { nil }
    var availableAudioSamples: Int { 0 }
    init(textSoFar: String) { self.textSoFar = textSoFar }
    func feed(_ samples: [Float]) {}
    func finish() async throws -> String { textSoFar }
    func cancel() {}
}
