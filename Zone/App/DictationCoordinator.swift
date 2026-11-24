// by zayd/cold @ zayd.wtf

import AVFoundation
import Foundation
import Observation
import SwiftUI
import ZoneCore
import UIKit

/// Orchestrates one dictation at a time across the keyboard, the microphone and the engine.
///
/// Warm path: the keyboard writes a request and pings `requestChanged`; if the session is armed
/// the coordinator starts recording at once and the user never leaves their app. Cold path: the
/// keyboard opens `zone://dictate?request=…`; the app arms in the foreground, records, and the
/// user returns with the system back affordance. Both paths end the same way: a result in the
/// shared store and a `resultReady` ping.
@MainActor
@Observable
final class DictationCoordinator {
    static weak var shortcutCoordinator: DictationCoordinator?
    private let recordingLiveActivity: RecordingLiveActivity
    private var shortcutNeedsLiveActivity = false
    private var requiredCardRequestID: UUID?
    private var stoppedForMissingCardID: UUID?
    private let cardStopNotice: RecordingCardStopNotice
    private(set) var recordingCardStopMessage: String?
    var postRecordingCardStop: (String) async -> Void = RecordingCardStopNotice.notify
    private var shortcutActivityRequestFailed = false
    private var shortcutAudioPolicyPending = false
    private let deactivateShortcutAudio: () throws -> Void
    var shortcutCanRunWarm: Bool { activity.isBusy || (isArmed && (modelIsReady || openingPress != nil) && capture.state == .armed) }

    private var shortcutHasAudioWork: Bool {
        activity.isBusy || startingNote || meetingCaptureActive || clipSink != nil
            || armingSessions > 0 || pendingColdRequestID != nil
    }

    /// True while a dictation or a note is recording, being recognized, starting, or getting the
    /// microphone ready, while a recording screen, the note card or the Note saved page is up.
    /// What's New waits for false (`WhatsNewGate`), so it never lands on someone who is
    /// dictating or about to.
    var isBusyForWhatsNew: Bool {
        shortcutHasAudioWork || retryingAudioID != nil || showsDictationScreen
            || noteCard != nil || notePage != nil
    }

    /// An error or a warning is on screen, the same list the rating prompt stays away from.
    var showsNotice: Bool {
        if case .failed = activity { return true }
        return audioRecoveryWarning != nil || holdNotice != nil || autoStopNotice != nil
    }

    /// AppIntents checks the process-wide audio session even after a failed perform.
    /// Every exit must leave inactive audio or an owned recording indicator. A recording
    /// without an indicator is saved before releasing audio; throwing alone is not safe.
    func settleRecordingShortcut(finishingSession: UInt64? = nil) async throws {
        if !shortcutHasAudioWork { await sounds.finishStopCue() }
        if let finishingSession {
            // A deferred terminal callback belongs to the previous recording. A new
            // press may be arming its microphone while the stop cue finishes.
            guard sessionGeneration == finishingSession, openingPress == nil, !shortcutHasAudioWork else { return }
        }
        var notice: String?
        // Persistence yields the actor. Recheck ownership if another recording starts while
        // the previous one is being saved; never return based on a pre-await snapshot.
        while shortcutHasAudioWork {
            let visibleRecording = recordingLiveActivity.showsRecording
                || (meetingCaptureActive && MeetingCoordinator.current?.hasRecordingLiveActivity == true)
            if visibleRecording {
                shortcutAudioPolicyPending = true
                Journal.log("shortcutAudioSettled", ["state": "busyWithLiveActivity"])
                if let notice { throw ShortcutFailure(message: notice) }
                return
            }
            if case .recording(let id, _) = activity {
                do {
                    try startRecordingIndicator(for: id, noteMode: activeNoteRequestID == id,
                                                controlOwned: activeNoteRequestID == id || activeShortcutRequestID == id)
                    guard recordingLiveActivity.isActive else { throw RecordingLiveActivity.Failure.foregroundRequired }
                    continue
                } catch {
                    Journal.log("shortcutIndicatorUnavailable", ["error": JournalFormat.error(error)])
                    await stopDictation(reason: "shortcutPolicy")
                    notice = "The recording card closed. Open Zone to check the result."
                    continue
                }
            }
            if meetingCaptureActive {
                if let meeting = MeetingCoordinator.current, meeting.isRecording {
                    if meeting.restoreRecordingLiveActivity() { continue }
                    await meeting.stopRecording()
                    notice = "Live Activities are unavailable. The meeting was stopped and saved in Zone."
                } else {
                    stopMeetingCapture()
                }
                continue
            }
            // Recognition can finish with the microphone off. A pending arm must be
            // invalidated so it cannot activate unindicated audio after this intent returns.
            if armingSessions > 0 || pendingColdRequestID != nil {
                notice = "Recording setup was interrupted. Try recording again in Zone."
            }
            break
        }
        pressHoldsReadyCard = false
        if notice == nil, !shortcutHasAudioWork, keepStandbyAfterPress() {
            Journal.log("shortcutAudioSettled", ["state": "standbyKept"])
            return
        }
        // A diagnostic clip keeps its accumulated samples for stopClipCapture to return.
        capture.stopRecording()
        sounds.stopPlayback()
        MeetingPlayback.current?.stop()
        SpeakerSamplePlayer.current?.stop()
        endSession(reason: .shortcutFinished, keepingRecordingIndicator: true)
        do {
            try deactivateShortcutAudio()
        } catch {
            // Deactivation can fail with busy audio I/O. An error result is still checked
            // by AppIntents: retain (or restore) the indicator until audio is confirmed off.
            if !recordingLiveActivity.isActive { try? recordingLiveActivity.prepareReady() }
            Journal.log("shortcutAudioDeactivationFailed", ["error": JournalFormat.error(error),
                "indicator": String(recordingLiveActivity.isActive)])
            throw error
        }
        recordingLiveActivity.end()
        Journal.log("shortcutAudioSettled", ["state": "inactive"])
        if let notice { throw ShortcutFailure(message: notice) }
    }

    /// A finished press leaves the microphone ready when `StandbyAfterPress` says so and the
    /// standby card is up to show it. The card is the Live Activity iOS asks a recording intent
    /// to leave behind while audio is live, so without one this is false and the caller turns
    /// the microphone off, as every press did before the card existed. Kept, the session is an
    /// ordinary standby from here: its "Keep microphone ready" time starts again now.
    private func standbyPolicyAfterPress() -> StandbyAfterPress.Outcome {
        StandbyAfterPress.outcome(.init(
            isArmed: isArmed && capture.state == .armed, armedByPress: sessionArmedByPress,
            showsStandbyCard: settings.islandWhileReady, turnsOnWhenZoneOpens: settings.startsSessionOnOpen,
            turnedOffByPerson: userEndedSession, carKeepsItsAudio: carPlayRoute() && !standbyChosenInCar))
    }

    private func keepStandbyAfterPress() -> Bool {
        guard standbyPolicyAfterPress() == .keep else { return false }
        if !recordingLiveActivity.showsStandby {
            if recordingLiveActivity.isActive {
                // The recording's own card becomes the standby card, with its check.
                settleIslandAfterRecording(kept: activity.keptWords)
            } else {
                // No card at all (cleared from the Lock Screen, say). A press may make one.
                showStandbyIsland(canCreate: true)
            }
        }
        guard recordingLiveActivity.showsStandby else { return false }
        sessionArmedByPress = false
        // The recording withdrew the "Zone is off" notice. Standby is waiting again.
        StandbyStoppedNotice.keepAlive(force: true)
        touchActivity()
        return true
    }

    /// Called only from a user-triggered LiveActivityIntent. Create the visible activity
    /// before activating audio; a cold Action Button press need not first open the app.
    /// For a note, the note card says "Starting" meanwhile when Zone is on screen: this is
    /// where a press turns on a speech engine that was off.
    func prepareRecordingShortcut(noteMode: Bool = false, pressedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) async throws {
        guard !meetingCaptureActive else { throw ShortcutFailure(message: Self.meetingRefusal) }
        if let clipRefusal { throw ShortcutFailure(message: clipRefusal) }
        guard microphonePermission == .granted else {
            throw ShortcutFailure(message: "Open Zone and allow microphone access, then press again.")
        }
        try checkPressOwner()
        guard openingPress == nil else { throw ShortcutFailure(message: "Zone is opening the microphone.") }
        guard !shortcutCanRunWarm else { return }
        guard !isDeletingModels else { throw ShortcutFailure(message: "Zone is cleaning up model storage. Press again when it finishes.") }
        guard modelIsReady || engine.assetsPresent() else {
            throw ShortcutFailure(message: "Open Zone to download the speech model, then press again.")
        }
        if noteMode {
            noteStartWithdrawn = false
            preparingNote = true
            // The press is for the next note: the last one's page goes now, not after the
            // microphone and the engine are on.
            closeNotePage(reason: "newNote")
            clearNoteOutcome()
        }
        defer { if noteMode { preparingNote = false } }
        // The last note's result is cleared when the next recording begins, and clearing it
        // ends the standby card. Clear it before this press makes its card, not after: iOS
        // does not grant a backgrounded press a second card, so the start then asked for the
        // passcode on a locked phone.
        if !activity.isBusy { acknowledgeActivity() }
        PressTiming.mark("card")
        let hadActivity = recordingLiveActivity.isActive
        try recordingLiveActivity.prepareStarting(noteMode: noteMode)
        PressTiming.mark("cardDone")
        let id = UUID()
        PressTiming.mark("writer")
        let writer: AudioRecoveryWriter
        do {
            writer = try audioRecoveryStore.begin(id: id, engine: engine.kind.rawValue, source: noteMode ? .note : .keyboard,
                                                  dateFromFirstSample: true)
        } catch {
            if !hadActivity { recordingLiveActivity.end() }
            throw ShortcutFailure(message: AudioRecoveryError.unavailable.localizedDescription)
        }
        PressTiming.mark("writerReady")
        let press = PressRecording(id: id, writer: writer, url: audioRecoveryStore.audioURL(id), pressedAt: pressedAt)
        openingPress = press
        let gate = pauseGate
        setPaused(false)
        capture.recordOnArm { [weak self] samples in
            guard !gate.isPaused else { return }
            press.append(samples) { date in
                let delay = Int((ProcessInfo.processInfo.systemUptime - pressedAt) * 1000)
                Task { @MainActor in
                    Journal.log("pressFirstSample", recording: id, ["intentMs": String(delay)])
                    guard let self, self.openingPress === press || self.recordingPress === press else { return }
                    if self.openingPress === press { RecordingSafetyNotice.arm() }
                    if self.settings.soundsEnabled, self.openingPress === press || self.activity.isRecording {
                        self.sounds.use(self.settings.soundSet)
                        self.sounds.playStart()
                        Journal.log("pressStartCue", recording: id)
                        PressTiming.mark("startCue")
                    }
                    guard case .recording(let current, _) = self.activity, current == id else { return }
                    if self.pressWaitingForSamples {
                        let engine = self.engine.kind.rawValue
                        let source: TranscriptSource = noteMode ? .note : .keyboard
                        Self.history { $0.begin(id: id, engine: engine, source: source, now: date) }
                    }
                    self.pressWaitingForSamples = false
                    self.recordingStartedAt = date
                    self.activity = .recording(requestID: id, startedAt: date)
                    self.recordingLiveActivity.firstSample(at: date)
                }
            }
        }
        if !modelIsReady { (engine as? ParakeetEngine)?.skipPendingLoadWarmUp() }
        prepareModel(allowDownload: false)
        pressHoldsReadyCard = true
        let wasArmed = isArmed, turnedOffByPerson = userEndedSession
        do { try await armSessionForPress(pressedAt: pressedAt) }
        catch {
            abandonOpeningPress()
            pressHoldsReadyCard = false
            if !activity.isBusy { RecordingSafetyNotice.disarm() }
            if !hadActivity && !activity.isBusy && !meetingCaptureActive { recordingLiveActivity.end() }
            if noteMode && noteStartWithdrawn { return }
            if error is CancellationError || isInterrupted(error) {
                throw ShortcutFailure(message: "The microphone was interrupted. Check Home for saved audio.")
            }
            throw error
        }
        press.markArmed()
        Journal.log("pressMicArmed", recording: id, ["intentMs": String(Int((ProcessInfo.processInfo.systemUptime - pressedAt) * 1000))])
        if !wasArmed {
            sessionArmedByPress = true
            // Arming clears "the person turned Zone off". A press is not the person turning it
            // back on: when this press is done the microphone goes off again, and opening Zone
            // later must not turn it on by itself.
            userEndedSession = turnedOffByPerson
        }
    }

    /// Switches the microphone on for a press. From the background iOS sometimes refuses the
    /// first start and allows the same one moments later (`PressArmRetry`, from the phone's
    /// log), so a refused start is tried again inside the press, under the card the press has
    /// already made, before the press gives up and asks to be pressed again.
    private func isInterrupted(_ error: Error) -> Bool {
        if case CaptureError.interrupted = error { return true }
        return false
    }

    private func armSessionForPress(pressedAt: TimeInterval) async throws {
        do { return try await armSession(pressedAt: pressedAt) }
        catch {
            var failure = error
            for (index, pause) in pressArmPauses.enumerated() {
                let refused = failure as NSError
                guard PressArmRetry.worthRetrying(domain: refused.domain, code: refused.code,
                                                  inFront: pressFindsZoneInFront(),
                                                  carPlay: carPlayRoute()) else { break }
                try await Task.sleep(for: pause)
                try checkPressOwner()
                // Something else answered the press meanwhile: Zone was opened and turned on, a
                // recording began, or the person called the note off.
                guard openingPress != nil else { throw CancellationError() }
                if isArmed { return }
                guard !activity.isBusy, !meetingCaptureActive, !(preparingNote && noteStartWithdrawn) else { break }
                do {
                    try await armSession(pressedAt: pressedAt)
                    Journal.log("pressArmRetried", ["attempt": String(index + 2), "started": "true"])
                    return
                } catch {
                    Journal.log("pressArmRetried", ["attempt": String(index + 2), "started": "false",
                                                    "error": JournalFormat.error(error)])
                    failure = error
                }
            }
            throw failure
        }
    }

    /// A start press that lands while the last recording is still being recognized (stopped
    /// from the app, the Dynamic Island or the keyboard, not through the intent queue) used to
    /// return success having done nothing. Wait for recognition, which usually ends in a few
    /// seconds, then start. If another recording still holds the microphone, say so.
    func clearWayForShortcutStart(noteMode: Bool, timeout: Duration = .seconds(12)) async throws {
        // The keyboard is recording by itself: arming here would fight it for the microphone.
        if let refusal = keyboardRecordingRefusal(KeyboardRecordingClaim.pressRefusal, from: noteMode ? "noteButton" : "dictateButton") {
            throw ShortcutFailure(message: refusal)
        }
        let deadline = ContinuousClock.now + timeout
        var waited = false
        while case .transcribing = activity, ContinuousClock.now < deadline {
            waited = true
            try await Task.sleep(for: .milliseconds(100))
        }
        if waited, let refusal = keyboardRecordingRefusal(KeyboardRecordingClaim.pressRefusal, from: "afterSave") { throw ShortcutFailure(message: refusal) }
        if waited { Journal.log("shortcutWaitedForRecognition", ["finished": String(!activity.isBusy)]) }
        if let startRefusal { throw ShortcutFailure(message: startRefusal) }
    }

    var startRefusal: String? {
        if meetingCaptureActive { return Self.meetingRefusal }
        if let clipRefusal { return clipRefusal }
        if retryingAudioID != nil { return Self.retryRefusal }
        if case .transcribing = activity { return RecordingRefusal.writing }
        if activity.isRecording { return noteIsLive ? Self.noteRefusal : RecordingRefusal.recording }
        if startingNote || preparingNote || startingAppDictation { return RecordingRefusal.starting }
        return nil
    }

    var composerRefusal: String? {
        if let startRefusal { return startRefusal }
        switch modelState {
        case .ready: return nil
        case .missing: return "Download the speech model in setup to dictate."
        case .failed: return "Try the speech model again in setup to dictate."
        case .loading, .downloading: return "Try again when the speech model is ready."
        }
    }

    func shortcutRequestToFinish(noteMode: Bool) -> UUID? {
        guard case .recording(let id, _) = activity else { return nil }
        return (noteMode ? activeNoteRequestID : activeShortcutRequestID) == id ? id : nil
    }

    enum RecordingTrigger { case inApp, shortcut, control }

    func runRecordingShortcut(noteMode: Bool, finishing expectedID: UUID?, trigger: RecordingTrigger) async throws {
        if expectedID == nil, let press = openingPress {
            defer { if openingPress === press { abandonOpeningPress() } }
            try checkPressOwner()
            guard recordingLiveActivity.isActive else {
                noteMissingRecordingCard(press.id)
                let outcome = await abandonOpeningPress()?.value ?? .unconfirmed
                throw ShortcutFailure(message: outcome.message)
            }
            let request = DictationRequest(id: press.id, generation: noteMode ? 0 : max(store.request?.generation ?? 0, store.ledger.droppedGeneration) + 1,
                                          createdAt: press.bridge.firstSample ?? Date(), inputSession: noteMode ? "app" : nil, contextBefore: nil)
            noteSessionID = UUID()
            lastSavedNote = nil
            showsDictationScreen = !noteMode
            if !noteMode {
                store.control = nil
                store.request = request
                lastHandledRequestID = request.id
            }
            shortcutNeedsLiveActivity = true
            shortcutActivityRequestFailed = false
            beginRecording(for: request, origin: noteMode ? .app : .keyboard, note: noteMode, shortcut: !noteMode, trigger: trigger)
            if shortcutActivityRequestFailed { throw RecordingLiveActivity.Failure.foregroundRequired }
            if case .failed(let message) = activity { throw ShortcutFailure(message: message) }
            return
        }
        if let expectedID {
            guard shortcutRequestToFinish(noteMode: noteMode) == expectedID else { throw RecordingUnchanged(message: startRefusal ?? RecordingRefusal.idle) }
        } else {
            // A start admitted before foreground/model preparation must never become a stop
            // of independent work that appeared during those awaits.
            if let startRefusal { throw RecordingUnchanged(message: startRefusal) }
            try checkPressOwner()
            // X on the note card while this press was getting ready: the person called it off.
            if noteMode, noteStartWithdrawn {
                noteStartWithdrawn = false
                Journal.log("noteStartWithdrawn", ["step": "afterPreparation"])
                return
            }
        }
        guard shortcutCanRunWarm else { throw ShortcutFailure(message: "The microphone stopped before recording could start. Press again.") }
        shortcutActivityRequestFailed = false
        shortcutNeedsLiveActivity = !activity.isBusy
        defer { shortcutNeedsLiveActivity = false }
        let finishingID = currentRequest?.id
        let ownsDictation = !noteMode && activeShortcutRequestID == finishingID && finishingID != nil
        await beginShortcut(noteMode: noteMode, trigger: trigger)
        if ownsDictation { copyFinishedDictation(finishingID) }
        if shortcutActivityRequestFailed { throw RecordingLiveActivity.Failure.foregroundRequired }
        if case .failed(let message) = activity { throw ShortcutFailure(message: message) }
    }
    /// "Dictate and copy" has no text field to write into: when it finishes with words, they go
    /// to the clipboard. Shared by the Shortcut's second press and the island's Stop.
    private func copyFinishedDictation(_ finishingID: UUID?) {
        guard case .finished(let result, .keyboard) = activity, result.requestID == finishingID,
              !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Copied to paste anywhere, so it writes handles the way the keyboard does.
        let styled = textStyle.apply(result.text, personalWords: personalWords, mentions: settings.handleRecognition,
                                     handles: handles, systemWords: systemWords,
                                     spokenCorrections: settings.spokenCorrections, emoticons: settings.spokenEmoticons, smallOrdinals: settings.smallOrdinals, numbers: settings.numbers, california: settings.californiaMode, misheard: settings.misheard)
        guard !styled.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Clipboard.copy(styled, automatic: true)
        confirmKept(result.requestID, text: styled)
        learnHandles(from: result.text, renderedText: styled)
        useRecoveredText(result.requestID)
        // Nobody watched this dictation and its words are already on the clipboard. Its
        // finished screen must not be waiting over Home, holding What's New back, whenever
        // Zone is next opened. A dictation that failed or heard nothing keeps its screen: that
        // is where the reason is shown.
        if !appIsActive { showsDictationScreen = false }
    }

    // MARK: Island buttons

    /// A button on Zone's own card in the Dynamic Island or on the Lock Screen
    /// (`ZoneIslandIntent`). Runs in the background; Zone is never brought forward.
    ///
    /// Stop ends whatever dictation or note is recording, whichever surface started it. That is
    /// safe here and not for the Action Button, because the button is drawn on that
    /// recording's card. A keyboard dictation delivers its words as it would after the
    /// keyboard's own stop; a dictation that began on the island copies them.
    ///
    /// A delivered Dictate or Note action may cold-start capture under its own recording card.
    func performIslandAction(_ action: IslandAction) async throws {
        do { try await runIslandAction(action) }
        catch let refusal as ShortcutFailure {
            await recordingLiveActivity.showPressNotice(refusal.message)
            throw refusal
        }
    }

    private func runIslandAction(_ action: IslandAction) async throws {
        switch action {
        case .stop:
            guard case .recording(let id, _) = activity else { throw ShortcutFailure(message: startRefusal ?? RecordingRefusal.idle) }
            let copies = activeShortcutRequestID == id
            await stopDictation(reason: "island")
            if copies { copyFinishedDictation(id) }
        case .pause:
            guard activity.isRecording else { throw ShortcutFailure(message: startRefusal ?? RecordingRefusal.idle) }
            togglePause()
        case .dictate, .note:
            // A second tap while the first is still starting, or a tap that lost to the
            // keyboard, must not start a second recording or stop the first.
            if let startRefusal { throw ShortcutFailure(message: startRefusal) }
            if let refusal = keyboardRecordingRefusal(KeyboardRecordingClaim.pressRefusal, from: "island") {
                throw ShortcutFailure(message: refusal)
            }
            if !shortcutCanRunWarm {
                try await prepareRecordingShortcut(noteMode: action == .note)
            }
            try await runRecordingShortcut(noteMode: action == .note, finishing: nil, trigger: .control)
            try await settleRecordingShortcut()
            if case .failed(let message) = activity { throw ShortcutFailure(message: message) }
        }
    }

    struct ShortcutFailure: LocalizedError, CustomLocalizedStringResourceConvertible {
        let message: String
        var errorDescription: String? { message }
        var localizedStringResource: LocalizedStringResource { "\(message)" }
    }

    /// The keyboard's recording claim (`KeyboardRecordingClaim`), checked by every start that
    /// would arm Zone's own microphone: `message` while the keyboard records by itself, nil
    /// otherwise. A dead claim (a keyboard iOS ended mid-recording) is cleared and never blocks.
    /// Stops, standby Off and everything else never read it. With the keyboard route unused no
    /// claim is ever written, and this is always nil.
    func keyboardRecordingRefusal(_ message: String, from source: String, forRequest: UUID? = nil) -> String? {
        let claim = store.keyboardRecordingClaim
        switch KeyboardRecordingClaim.verdict(claim, now: Date(), forRequest: forRequest) {
        case .clear:
            return nil
        case .stale:
            guard let lease = appMicrophoneLease(from: source) else { return message }
            guard lease.holdsPeerLock else { return nil }
            withExtendedLifetime(lease) {
                if store.keyboardRecordingClaim == claim { store.keyboardRecordingClaim = nil }
            }
            Journal.log("keyboardClaimCleared", recording: claim?.requestID, ["from": source])
            return nil
        case .keyboardRecording(let id):
            Journal.log("startRefusedForKeyboard", recording: id, ["from": source])
            return message
        }
    }

    enum ModelState: Equatable {
        case missing
        case downloading(progress: Double, file: String)
        case loading
        case ready
        case failed(String)
    }

    enum Activity: Equatable {
        case idle
        case recording(requestID: UUID, startedAt: Date)
        case transcribing(requestID: UUID)
        case finished(DictationResult, origin: Origin)
        case failed(String)

        /// How many words a recording that just finished kept; nil for every other state and
        /// for one that heard nothing. The island's check and "Kept N words." follow this.
        var keptWords: Int? {
            guard case .finished(let result, _) = self else { return nil }
            let words = result.text.split(whereSeparator: \.isWhitespace).count
            return words > 0 ? words : nil
        }
    }

    enum Origin: Equatable {
        /// Request came from the keyboard; results are published to the shared store.
        case keyboard
        /// Request came from the app's own UI; results stay in-process.
        case app

        var historySource: TranscriptSource { self == .keyboard ? .keyboard : .app }
    }

    /// Transcript-history writes do file I/O, so they run off the main thread, and on one
    /// serial queue so begin, progress, finish and cancel land in the order they were made.
    private(set) var audioRecoveryRecords: [AudioRecoveryRecord] = []
    private(set) var audioRecoveryWarning: String?

    /// The banner's close button: hides the warning or failure line without touching any recording.
    func dismissNotice() {
        cardStopNotice.dismiss()
        recordingCardStopMessage = nil
        NoteStartFailureNotice.clear()
        holdNotice = nil
        audioRecoveryWarning = nil
        autoStopNotice = nil
        if case .failed = activity { activity = .idle }
    }
    private(set) var retryingAudioID: UUID?
    private var audioWriter: AudioRecoveryWriter?
    private var audioRecordID: UUID?
    private var audioRetryTask: Task<Void, Never>?
    private var consumedAudioReceiptID: UUID?
    private var audioRefreshGeneration = 0
    private var measuringAudio: Set<UUID> = []
    private let audioRecoveryStore: AudioRecoveryStore

    private static func standardAudioRecoveryStore() -> AudioRecoveryStore {
        #if DEBUG && targetEnvironment(simulator)
        if let fixture = ScriptedSpeech.blockedRecoveryStore() { return fixture }
        #endif
        let support = URL.applicationSupportDirectory
        let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)
        return AudioRecoveryStore(directory: support.appendingPathComponent("AudioRecovery", isDirectory: true),
                                  fallbackDirectory: group?.appendingPathComponent("Library/Application Support/AudioRecovery", isDirectory: true))
    }

    private static let historyQueue = DispatchQueue(label: "wtf.zayd.zone.history", qos: .utility)

    /// Nothing happens without the App Group.
    nonisolated static func history(_ body: @escaping @Sendable (TranscriptHistory) -> Void) {
        guard let history = TranscriptHistory.shared else { return }
        historyQueue.async { body(history) }
    }

    /// Completion must be persisted before publishing a result that the keyboard can mark.
    nonisolated static func historyAndWait(_ body: @escaping @Sendable (TranscriptHistory) -> Void) async {
        guard let history = TranscriptHistory.shared else { return }
        await withCheckedContinuation { continuation in
            historyQueue.async { body(history); continuation.resume() }
        }
    }

    nonisolated static func commitHistory(_ body: @escaping @Sendable (TranscriptHistory) -> Bool) async -> Bool {
        guard let history = TranscriptHistory.shared else { return false }
        return await withCheckedContinuation { continuation in
            historyQueue.async { continuation.resume(returning: body(history)) }
        }
    }

    enum SessionEndReason: Equatable {
        case user
        case timeout
        case interruption
        /// Release idle intent audio without disabling the user's auto-arm-on-open setting.
        case shortcutFinished
        /// CarPlay is the audio route and nobody turned standby on there: the microphone is
        /// released between recordings so the car keeps its stereo media (`CarAudioRoute`).
        case carPlay
        /// The person cleared Zone's card from the Lock Screen (`IslandUpkeep.Response.turnOff`).
        /// Unlike Turn off, opening Zone may turn it on again (Turn on when Zone opens).
        case clearedCard
    }

    private(set) var modelState: ModelState = .missing
    private(set) var activity: Activity = .idle {
        didSet {
            if activity.isRecording != oldValue.isRecording { publishSession() }
            updateLevelHistory()
            forgetNoteFailureIfReplaced()
            switch activity {
            case .recording: keepHeartbeatWhileClaimingMicrophone()
            case .transcribing: recordingLiveActivity.processing()
            default:
                if shortcutAudioPolicyPending {
                    shortcutAudioPolicyPending = false
                    // A no-op intent may return while this recording is still processing.
                    // Keep its indicator until audio is settled even if completion happens
                    // between perform returning and Apple's process-wide policy check.
                    if !shortcutHasAudioWork, keepStandbyAfterPress() {
                        pressHoldsReadyCard = false
                    } else {
                        let finishingSession = sessionGeneration
                        Task { [weak self] in
                            do { try await self?.settleRecordingShortcut(finishingSession: finishingSession) }
                            catch { Journal.log("shortcutTerminalCleanupFailed", ["error": JournalFormat.error(error)]) }
                        }
                    }
                } else {
                    settleIslandAfterRecording(kept: activity.keptWords)
                }
            }
        }
    }
    /// Recent microphone levels for the waveform, oldest first: one per level the capture
    /// engine posts (20 a second) while a dictation is recording and Zone is on screen.
    private(set) var recentLevels: [Float] = Array(repeating: 0, count: 36)
    /// A gentle hint after eight continuous seconds of low input; it never stops recording.
    private(set) var hearsNothing = false
    /// Whole seconds until Finish when quiet ends this recording (`SilenceFinish.countdown`: from
    /// when "Quiet" is said, at most the last five), here and on the keyboard (sent with each
    /// level on `LevelChannel`).
    private(set) var quietFinishIn: Int?
    /// When Finish when quiet ends this recording if the quiet holds. Set once the quiet has
    /// lasted long enough to say so (`SilenceFinish.saysQuiet`, two seconds), nil while a voice
    /// is heard. Dictation surfaces count down to it; notes never do.
    private(set) var quietUntil: Date?
    private var silenceFinish: SilenceFinish?
    private var silenceFinishRecording: UUID?
    /// True while the current recording is held by Pause (from the keyboard or Home).
    private(set) var isPaused = false
    private let pauseGate = PauseGate()
    private var pauseLimitTask: Task<Void, Never>?
    /// Set while a recording is in progress; nil otherwise.
    private var quietMonitor: QuietInputMonitor?
    private var levelRecordingID: UUID?
    /// False while Zone is in the background (the keyboard dictating over another app): nothing
    /// draws the waveform then, so the level history and quiet hint stop updating.
    private var levelHistoryIsVisible = true
    /// The keyboard's meter feed.
    private let levelChannel = LevelChannel.Publisher()
    private(set) var isArmed = false
    private(set) var armedUntil: Date?
    private(set) var lastResult: DictationResult?
    private(set) var liveTranscript = ""
    private(set) var lastSavedNote: Note?
    private(set) var lastResultWasNote = false
    private(set) var lastResultWasAudioRetry = false
    private var pressStartedRequestID: UUID?
    private var activeNoteRequestID: UUID?
    private var activeShortcutRequestID: UUID?
    private(set) var lastError: String?
    var level: Float { capture.level }
    /// The style the keyboard chose; in-app insertions use the same one.
    func composerInsertion(_ transcript: String, before: String) -> String {
        textStyle.insertion(of: transcript, contextBefore: before, fieldCapitalizesSentences: true,
                            personalWords: personalWords, mentions: settings.handleRecognition, handles: handles,
                            systemWords: systemWords, spokenCorrections: settings.spokenCorrections,
                            emoticons: settings.spokenEmoticons, smallOrdinals: settings.smallOrdinals,
                            numbers: settings.numbers, california: settings.californiaMode, misheard: settings.misheard,
                            autoCapitalization: settings.autoCapitalizationEnabled)
    }

    // Recovery keeps the original speech available. Format the copy only after a person
    // has picked a number format for this style.
    func textForRecoveryCopy(_ transcript: String) -> String {
        guard settings.numbers.mode != .style, settings.numbers.styles.contains(textStyle) else { return transcript }
        return composerInsertion(transcript, before: "")
    }

    var textStyle: TextStyle { store.effectiveTextStyle() }
    /// The words dictation writes in their saved spelling, read fresh (`AppSettings.appliedPersonalWords`).
    var personalWords: [String] {
        settings.refreshPersonalWords()
        return settings.appliedPersonalWords
    }
    /// The person's handles, read fresh like `personalWords`. "At sign" uses them with Smart @ off too.
    var handles: [String] { settings.refreshHandles() }

    /// Remembers a handle taught by "at sign cold" while Smart @ is on.
    func learnHandles(from transcript: String, renderedText: String) {
        guard settings.handleRecognition else { return }
        PersonalVocabulary.learnHandles(taughtIn: transcript, renderedText: renderedText, personalWords: settings.appliedPersonalWords, knownHandles: handles)
    }

    var systemWords: [String] { settings.systemSpeechWords }

    /// Snapshot once for the whole transcription, including a re-run with a different speech model.
    func meetingTextCorrection() async -> (String) -> String {
        await settings.refreshVocabularyCache()
        let words = settings.appliedPersonalWords
        let system = settings.cachedSystemSpeechWords
        let misheard = settings.misheard
        return { TextStyle.meetingTranscript($0, personalWords: words, systemWords: system, misheard: misheard) }
    }

    /// Reads the vocabulary from disk on the main thread. Dictation start uses the cache instead.
    func refreshSpeechVocabulary() { engine.setPersonalWords(settings.speechHintWords()) }

    /// Rereads the vocabulary off the main thread for the next dictation. One read at a time.
    private func refreshVocabularyCache() {
        let previous = vocabularyRefresh
        vocabularyRefresh = Task { [settings] in
            await previous?.value
            await settings.refreshVocabularyCache()
        }
    }

    /// Returns once every vocabulary reread started so far has finished.
    func vocabularyRefreshed() async { await vocabularyRefresh?.value }

    /// Formats with the cached vocabulary: no disk read on the way to the first sample.
    private func beginUserUtterance(mentions: Bool? = nil, recording: UUID? = nil, warmUp: Bool = true, using selected: SpeechEngine? = nil, writer: AudioRecoveryWriter? = nil, retrySubmission: AudioModelSubmission? = nil) throws -> UtteranceSession {
        let engine = selected ?? self.engine
        if settings.neverAppleSpeech, engine.kind == .appleSpeech || engine.kind == .appleDictation {
            throw SpeechEngineError.unavailable("Choose Fluid Speech Mini in Zone to transcribe this recording.")
        }
        let receipt = writer?.submission ?? retrySubmission
        let session: UtteranceSession
        var directFeed: (() -> Void)?
        if let mini = engine as? ParakeetEngine {
            session = try mini.beginUtterance(recording: recording, warmUp: warmUp && recordingPress == nil, submission: receipt)
        } else if #available(iOS 26, *), let apple = engine as? AppleSpeechEngine {
            session = try apple.beginUtterance(submission: receipt)
        } else {
            session = try engine.beginUtterance()
            directFeed = { try? receipt?.record() }
        }
        return LexiconRecognitionSession(base: session, systemWords: settings.cachedSystemSpeechWords,
            personalWords: settings.appliedPersonalWords, mentions: mentions ?? settings.handleRecognition,
            onAudioSubmitted: directFeed)
    }
    // MARK: Note card and Note saved page

    /// True from a note press until its recording begins or the start is given up. It is what
    /// makes the next recording a note, and nothing on screen changes it: closing or covering
    /// a screen must never turn a note into something else (before 2026-11-16 one flag meant
    /// both "the note screen is up" and "this recording is a note").
    private var noteRequested = false
    /// Set while an Action Button press gets the microphone and the speech engine ready for a
    /// note (`prepareRecordingShortcut`), before the note itself starts.
    private var preparingNote = false
    /// X on the note card during that preparation: the press ends without recording.
    private var noteStartWithdrawn = false
    /// How the last note ended when no page says so. Cleared by the next note, by X on the
    /// card, or after a few seconds (`noteOutcomeExpiry`).
    private(set) var noteOutcome: NoteOutcome?
    private var noteOutcomeExpiry: Task<Void, Never>?
    /// The Note saved page; nil while it is down. Set when a note is saved, wherever Zone is:
    /// coming back to Zone shows it only while it is fresh (`notePageFreshness`).
    private(set) var notePage: NotePage?
    /// Notes saved since the person last looked at a Note saved page or came back to Zone,
    /// oldest first. The next page carries them (`NotePage.earlier`).
    private var unseenNotes: [NotePage.Entry] = []
    /// The page now up has been on screen with Zone in front. A page that was seen and then
    /// gives way to the next note leaves nothing unseen; one saved away from Zone does.
    private var notePageSeen = false
    /// Reasons a page closes because something else needs the screen, not because the person
    /// was done with it. Its notes stay unseen.
    private static let pageSupersededReasons: Set<String> = ["newNote", "newDictation", "newRecording", "keyboardRequest", "keyboardNavigation", "meeting"]
    /// More than this many earlier notes is a list, and Notes on Home is the list.
    static let unseenNotesLimit = 12
    /// Development builds only: `-zoneNotesSavedAway` treats every note as saved away from
    /// Zone, so a UI test can fill a Note saved page with several notes without an Action Button.
    private static let savesNotesAsIfAway: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-zoneNotesSavedAway")
        #else
        false
        #endif
    }()
    /// A Note saved page older than this is dropped when Zone comes back to the front: the note
    /// is in Notes, and a stale page in the way of whatever the person came to do is not help.
    static let notePageFreshness: TimeInterval = 10 * 60
    /// "Added to Notes" on the page: Home opens Notes at the note and lights it up.
    private(set) var noteReveal: NoteReveal?
    /// The clock the note page's freshness reads. Tests move it.
    @ObservationIgnored var noteClock: () -> Date = { Date() }
    private(set) var noteSessionID = UUID()
    /// An in-app press or standby request is still getting the microphone ready.
    var isPreparingMicrophone: Bool { armingSessions > 0 || startingAppDictation }
    private var startingAppDictation = false
    private var startingNote = false
    private var startingNoteMode: Bool?
    private var startupStopWaiters: [CheckedContinuation<Void, Never>] = []
    /// Set by a second Action Button press while the first is still starting.
    private var stopAfterStart = false
    /// The notes file. Injectable so a test can make a note's write fail without touching the
    /// person's own notes.
    let notes: NotesStore
    /// Counts recordings that ended well and decides when Apple's rating prompt may appear.
    let reviews: ReviewPrompter

    /// True while the cold-path dictation screen should cover everything else.
    var showsDictationScreen = false
    /// Set when a dictate URL arrives before the model is ready; resumed after preparation.
    private(set) var needsFreshKeyboardTap = false
    private var pendingColdRequestID: UUID?

    private let store: SharedStore
    private let settings: AppSettings
    private let capture: AudioCaptureEngine
    private var openingPress: PressRecording?
    private var recordingPress: PressRecording?
    private var attachmentTask: Task<Void, Never>?
    @discardableResult
    private func abandonOpeningPress() -> Task<RecordingCardStopNotice.Outcome, Never>? {
        guard let press = openingPress else { return nil }
        openingPress = nil
        press.stop()
        capture.cancelRecordingOnArm()
        press.bridge.cancel()
        let lostCard = stoppedForMissingCardID == press.id
        publishSession()
        return Task {
            let outcome = await retainStoppedAudio(press.id, writer: press.writer)
            if lostCard { settleCardStopNotice(press.id, outcome: outcome) }
            await refreshAudioRecovery()
            return outcome
        }
    }

    private func retainStoppedAudio(_ id: UUID, writer: AudioRecoveryWriter) async -> RecordingCardStopNotice.Outcome {
        let storage = audioRecoveryStore
        do {
            try await writer.finish()
            return try await Task.detached(priority: .utility) {
                if writer.acceptedSamples == 0 {
                    try storage.discard(id)
                    return RecordingCardStopNotice.Outcome.noSamples
                }
                try storage.markFailed(id, text: "", message: "Recording stopped. Tap to transcribe it.", outcome: .interrupted)
                return storage.hasRetainedAudio(id) ? .saved : .unconfirmed
            }.value
        } catch {
            // Preserve even a partial file for Home, without promising a complete write.
            try? storage.markFailed(id, text: "", message: "Check this recording and try transcribing it.", outcome: .interrupted)
            return .unconfirmed
        }
    }

    private func checkPressOwner() throws {
        try Task.checkCancellation()
        if let refusal = keyboardRecordingRefusal(KeyboardRecordingClaim.pressRefusal, from: "recordingButton") {
            throw ShortcutFailure(message: refusal)
        }
        guard !activity.isBusy, !startingAppDictation, !startingNote, !meetingCaptureActive, clipRefusal == nil, retryingAudioID == nil else {
            throw ShortcutFailure(message: "Zone is busy with another recording. Press again when it finishes.")
        }
    }
    private let sounds = DictationSounds()
    var startCueWindow: ClosedRange<TimeInterval>? { sounds.startCueWindow }
    private var engine: SpeechEngine
    /// The engine Diagnostics selected (the default unless changed there).
    var engineKind: EngineKind { engine.kind }
    private var utterance: UtteranceSession?
    /// The current recording's utterance, as segments an interruption can close and reopen.
    private var segmented: SegmentedRecognition?
    /// Set while an interruption (an alarm, a call, Siri) holds the current recording: the
    /// microphone is off, everything heard so far is recognized and saved, and the same
    /// recording continues when the interruption ends. See `InterruptionPolicy`.
    private(set) var heldSince: Date?
    var isHeld: Bool { heldSince != nil }
    /// Paused by the person or held by an interruption: what the recording screens show.
    var showsPaused: Bool { isPaused || isHeld }

    func noteRecordingDuration(startedAt: Date, now: Date) -> TimeInterval {
        if let press = recordingPress {
            return Double(press.writer.acceptedSamples) / 16_000
        }
        let state = recordingLiveActivity.latestState
        if let paused = state?.userPausedAt { return paused }
        return max(0, (heldSince ?? now).timeIntervalSince(state?.startedAt ?? startedAt))
    }
    /// Why the current recording is held, or why it could not resume. Nil otherwise.
    private(set) var holdNotice: String?
    /// Interruptions the current recording went through, for History and the log.
    private var recordingInterruptions = 0
    private var holdLimitTask: Task<Void, Never>?
    private var holdBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var resumingHeld: Task<Bool, Never>?
    private var vocabularyRefresh: Task<Void, Never>?
    static let heldMessage = "Paused for a call or alarm. It picks up when that ends."
    private var currentRequest: DictationRequest? {
        didSet {
            if let press = recordingPress, press.id != currentRequest?.id {
                press.stop()
                attachmentTask?.cancel()
                attachmentTask = nil
                recordingPress = nil
                pressWaitingForSamples = false
            }
            if let previous = oldValue?.id, currentRequest?.id != previous {
                (engine as? ParakeetEngine)?.endRecording(previous)
            }
        }
    }
    private var currentOrigin: Origin = .app
    private var observations: [DarwinObservation] = []
    private var inactivityTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    /// The detached load inside `preparationTask`; cancelling it stops a download in progress.
    private var preparationLoad: Task<Void, Error>?
    private var preparationID: UUID?
    var modelIdleLimit: TimeInterval = 90
    var micStartLimit: TimeInterval = 30
    private var isSwitchingEngine = false
    private var armingSessions = 0
    /// True while CarPlay is the audio route. Tests swap it to put Zone in a car.
    @ObservationIgnored var carPlayRoute: () -> Bool = { CarAudioRoute.isCarPlay(AVAudioSession.sharedInstance().currentRoute) }
    /// The person turned Zone on (Home's Turn on, the Toggle Zone control) with CarPlay already
    /// connected, knowing the car's audio then takes its call channel: that standby stays. Zone's
    /// own arming (on open, after an interruption) never holds the microphone in CarPlay.
    @ObservationIgnored private var standbyChosenInCar = false
    @ObservationIgnored private var carReleaseTask: Task<Void, Never>?
    /// The wait after a recording before CarPlay gets its audio back: long enough for the
    /// island's check to show.
    @ObservationIgnored var carReleaseDelay: Duration = .seconds(2)
    /// The same wait after a dictation the keyboard asked for. The words are read, put in and
    /// the mic tapped again in a little over two seconds (three taps of five on 2026-11-22 came
    /// 2.1 to 2.4 s after the words, each one bounced to Zone), so the microphone waits here
    /// for the next sentence before the car gets its stereo audio back.
    @ObservationIgnored var carKeyboardReleaseDelay: Duration = .seconds(12)
    @ObservationIgnored private var routeObserver: NSObjectProtocol?
    private var sessionGeneration: UInt64 = 0
    @ObservationIgnored private let requestSessionPermission: () async -> Bool
    @ObservationIgnored private let armSessionCapture: (() async throws -> Void)?
    private var diagnosticOperations = 0

    func beginModelDiagnostics() -> Bool {
        guard !isDeletingModels else { return false }
        diagnosticOperations += 1
        return true
    }

    func endModelDiagnostics() { diagnosticOperations = max(0, diagnosticOperations - 1) }
    private var countdownTask: Task<Void, Never>?
    /// Mirrors `armedUntil` for the countdown label; updated every second while armed.
    private(set) var now = Date()
    /// Last presence record written by the keyboard, refreshed while the app is in the foreground.
    private(set) var keyboardPresence: KeyboardPresence?
    private var foregroundTask: Task<Void, Never>?
    private var requestPollTask: Task<Void, Never>?
    private var controlPollTask: Task<Void, Never>?
    private var utteranceLimitTask: Task<Void, Never>?
    private var recordingStartedAt: Date?
    /// Set by End session; opening the app again does not re-arm until the user starts one.
    private var userEndedSession = false
    /// The session now armed was turned on by an Action Button, Shortcut or control press, not by
    /// the person or by opening Zone. `StandbyAfterPress` reads it when the press has finished.
    private var sessionArmedByPress = false
    /// A press made the ready card for the recording it is about to start
    /// (`prepareRecordingShortcut`). With "Show Zone during standby" off, arming used to end
    /// that card as an unwanted standby card, and the recording then had to ask iOS for a
    /// second one, which a backgrounded press is not granted. Cleared when the press settles.
    private var pressHoldsReadyCard = false
    private var sawBackground = true
    /// The last control acted on, compared whole: the store keeps dates to the second, so two
    /// presses in one second differ only by their `id`.
    private var lastAppliedControl: DictationControl?
    /// How often a dictation in progress is saved to the transcript history, so a crash or a
    /// kill keeps what was said. History treats a file untouched for 30 s as cut off.
    static let historySaveInterval = 5
    /// When Zone ends a keyboard dictation with the keyboard out of sight and Zone off screen:
    /// after the person's "Keyboard hidden" time, or at two hours. "Until I stop" needs the
    /// Live Activity, the only control left when the keyboard is gone; without it (Live
    /// Activities turned off) it ends after five minutes. Words are kept either way. Read per
    /// check, so a Settings change applies to the recording already running.
    private var limits: DictationLimits {
        DictationLimits.hiddenKeyboard(grace: settings.hiddenKeyboardGrace, stoppableElsewhere: recordingLiveActivity.showsRecording)
    }
    /// The last moment Zone itself was on screen (where it shows any recording).
    private var appLastActive: Date?
    private var appIsActive = false
    /// Said once on Home after Zone stopped a dictation by itself.
    private(set) var autoStopNotice: String?
    /// Last keyboard request this process acted on, so a stale re-read is never treated as new.
    private var lastHandledRequestID: UUID?
    /// The keyboard tap this process was launched to serve (see `ColdStart`), journaled as
    /// `coldStart` once it records.
    private var launchRequestID: UUID?
    /// Set when an interruption ends an armed session, so a `shouldResume` can bring it back.
    private var wasArmedBeforeInterruption = false
    /// Clip recording state: a bakeoff clip or voice setup (`ClipPurpose`).
    private var clipSink: ClipSink?
    private var clipArmedCapture = false
    private var clipPurpose: ClipPurpose = .test
    /// Why a dictation cannot start while a clip records, or nil when none does.
    private var clipRefusal: String? { clipSink == nil ? nil : clipPurpose.refusal }
    /// True while a meeting owns the microphone. Meetings and dictation never overlap: each
    /// refuses to start while the other runs, with a message that says why.
    private(set) var meetingCaptureActive = false
    /// The meeting armed the microphone itself, so it releases it when it ends.
    private var meetingArmedCapture = false
    /// Delivers captured levels even while the meeting screen is in the background.
    var onMeetingLevel: ((Float) -> Void)?
    /// Tells the meeting recorder about audio interruptions (a call, Siri, another app).
    var onMeetingInterruption: ((AudioCaptureEngine.Interruption) -> Void)?
    /// Tells voice setup about audio interruptions, so a call pauses the step it is recording.
    var onVoiceSetupInterruption: ((AudioCaptureEngine.Interruption) -> Void)?
    private static let retryRefusal = RecordingRefusal.retry
    static let meetingRefusal = RecordingRefusal.meeting
    static let noteRefusal = RecordingRefusal.note
    /// Uptime when this process created its coordinator, for load timings in the log.
    static let processStart = ProcessInfo.processInfo.systemUptime

    init(settings: AppSettings,
         store: SharedStore = UserDefaultsSharedStore(),
         engine suppliedEngine: SpeechEngine? = nil,
         reviews: ReviewPrompter? = nil,
         noteFailureRecord: NoteStartFailureRecord = .standard,
         cardStopNotice: RecordingCardStopNotice = RecordingCardStopNotice(defaults: .standard),
         notes: NotesStore? = nil,
         recoveryStore: AudioRecoveryStore? = nil,
         modelEngineFactory: @escaping (SpeechModel) -> SpeechEngine = { $0.makeEngine() },
         requestSessionPermission: @escaping () async -> Bool = {
             if AVAudioApplication.shared.recordPermission == .granted { return true }
             return await AVAudioApplication.requestRecordPermission()
         },
         captureHardware: CaptureHardware = LiveCaptureHardware(),
         armSessionCapture: (() async throws -> Void)? = nil,
         recordingLiveActivity: RecordingLiveActivity? = nil,
         deactivateShortcutAudio: @escaping () throws -> Void = {
             // Synchronous, and behind any audio work already queued: inactive on return.
             try AudioHardwareQueue.sync {
                 try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
             }
         }) {
        audioRecoveryStore = recoveryStore ?? Self.standardAudioRecoveryStore()
        capture = AudioCaptureEngine(hardware: captureHardware)
        _ = Self.processStart // A static let is set on first read; read it at launch, not at model ready.
        let engine = suppliedEngine ?? EngineKind.selected.makeEngine()
        self.settings = settings
        self.store = store
        self.engine = engine
        self.modelEngineFactory = modelEngineFactory
        self.requestSessionPermission = requestSessionPermission
        self.armSessionCapture = armSessionCapture
        self.recordingLiveActivity = recordingLiveActivity ?? RecordingLiveActivity()
        self.recordingLiveActivity.look = { [settings] in settings.islandStyle.look }
        self.recordingLiveActivity.palette = { [settings] in settings.islandStyle.palette }
        self.recordingLiveActivity.controls = { [settings] in settings.islandStyle.controls }
        self.recordingLiveActivity.times = { [settings] in settings.islandTimes }
        self.recordingLiveActivity.galleryEnabled = { [settings] in AppSettings.showsIslandGallery && settings.islandWhileReady }
        self.recordingLiveActivity.garden = { [settings] in settings.islandGarden }
        self.recordingLiveActivity.petStage = { [settings] in
            #if DEBUG
            // `-ZoneIslandStage 3`: any stage of the pet, for simulator screenshots.
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-ZoneIslandStage"), i + 1 < args.count, let stage = UInt8(args[i + 1]) { return stage }
            #endif
            return UInt8(settings.islandGarden.stage(words: settings.wordsDictated).index)
        }
        self.recordingLiveActivity.accentChoice = { [settings] in settings.accent.rawValue }
        self.deactivateShortcutAudio = deactivateShortcutAudio
        self.reviews = reviews ?? ReviewPrompter()
        self.noteFailureRecord = noteFailureRecord
        self.cardStopNotice = cardStopNotice
        recordingCardStopMessage = cardStopNotice.message
        self.notes = notes ?? NotesStore()
        modelState = engine.assetsPresent() ? .loading : .missing
        Self.shortcutCoordinator = self
        // Zone is running again: any recording it lost now shows as a recovery card, so a
        // still-pending "Zone stopped" notice would only repeat it.
        RecordingSafetyNotice.disarm()
        // Nor can an "island ended" notice from before: the microphone it described went with
        // the process that posted it.
        IslandLostNotice.withdraw()
        wireCapture()
        self.recordingLiveActivity.session = { [weak self] in self?.islandSession }
        self.recordingLiveActivity.lost = { [weak self] ending, _, age in self?.islandLost(ending, age: age) }
        self.recordingLiveActivity.wantsRelay = { [weak self] in
            guard let self else { return false }
            return self.isArmed && self.settings.islandWhileReady
        }
        self.recordingLiveActivity.relayed = { [weak self] in self?.checkIsland(after: "relay") }
        observations = [
            DarwinNotifier.observe(.requestChanged) { [weak self] in self?.handleRequestChanged() },
            DarwinNotifier.observe(.controlChanged) { [weak self] in self?.handleControlChanged() },
            DarwinNotifier.observe(.payloadConsumed) { [weak self] in self?.consumeAudioReceiptFromLedger() },
            DarwinNotifier.observe(.keyboardShown) { [weak self] in self?.keyboardShown() },
            DarwinNotifier.observe(.statsChanged) { [weak self] in self?.refreshStats() },
        ]
        // CarPlay connecting while Zone waits: give the car its stereo audio back.
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isArmed, self.carPlayRoute() else { return }
                self.releaseMicrophoneInCarSoon()
            }
        }
        // A new app process has no in-memory capture/session for an old active status.
        // Terminalize it before a later arm publishes a fresh heartbeat over stale metadata.
        // The keyboard's fresh `requested` tap is not old: it is why this process was launched.
        let launchedAt = Date()
        if let prior = store.status {
            if ColdStart.launchTerminalizes(status: prior, request: store.request, ledger: store.ledger, now: launchedAt) {
                store.status = DictationStatus(requestID: prior.requestID, generation: prior.generation,
                                              phase: .interrupted, updatedAt: launchedAt, message: "The previous recording was interrupted. Check History for recovered text.")
                DarwinNotifier.post(.statusChanged)
            } else if prior.phase == .requested {
                launchRequestID = prior.requestID
            }
        }
        publishSession()
        refreshFromStore()
        let before = (try? audioRecoveryStore.records()) ?? []
        do { try audioRecoveryStore.recoverAbandoned() }
        catch { audioRecoveryWarning = "Some temporary recordings could not be checked. Existing files were kept." }
        let info = Bundle.main.infoDictionary
        Journal.log("appLaunch", ["version": info?["CFBundleShortVersionString"] as? String ?? "?",
                                  "build": info?["CFBundleVersion"] as? String ?? "?",
                                  "os": UIDevice.current.systemVersion, "engine": engine.kind.rawValue,
                                  "appState": Self.appStateName()])
        Journal.log("appGroupCheck", AppGroup.diagnostics())
        // Every launch: let the keyboard's helper delete anything it can never use. Nothing is
        // started when its cache is known to be clean.
        WorkerCacheClient.modelShared()
        for record in before where record.state == .recording || record.state == .retrying {
            // Left mid-recording by the previous process: it was killed, crashed or ran out of memory.
            Journal.log("recordingAbandoned", recording: record.id,
                        ["state": record.state.rawValue, "audio": JournalFormat.seconds(record.audioSeconds),
                         "words": JournalFormat.words(record.text), "lastWrite": ISO8601DateFormatter().string(from: record.updatedAt)])
        }
        Task {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("-zoneRecoveryPair") {
                let storage = audioRecoveryStore
                try? await Task.detached { try await NoteSeeds.recoveryPair(in: storage) }.value
            }
            #endif
            await refreshAudioRecovery()
        }
        refreshVocabularyCache()
        // iOS can build the graph before delivering the press. Leave the first decode
        // free for speech until someone actually requests idle standby.
        (engine as? ParakeetEngine)?.skipPendingLoadWarmUp(reason: "launch")
        if suppliedEngine == nil {
            // Retired models (Moonshine, Parakeet 110M) are deleted only where their folders are
            // still on disk: an iPhone updating from a build that used them, or one whose last
            // delete failed. Everywhere else launch does no cleanup at all, a few file checks.
            // It used to sweep on every launch and load the model only after, a median 0.77 s
            // (p90 1.6 s, worst 5.8 s, 80 launches on a phone, November 2026) for sweeps that
            // each freed nothing. The model in use is never a retired one (a retired choice
            // moves to its replacement, and their folders are separate), so a sweep that is
            // needed runs beside the load.
            let leftovers = SpeechModel.retiredLeftovers()
            launchCleanup = leftovers
            if leftovers.contains(selectedModel) {
                isDeletingModels = true
            } else if engine.assetsPresent() {
                prepareModel(allowDownload: false)
            }
            if !leftovers.isEmpty {
                Task {
                    await performModelDeletion(leftovers, automatic: true)
                    // A keyboard request that arrived during cleanup is waiting on this load.
                    if self.engine.assetsPresent() { prepareModel(allowDownload: false) }
                    if appIsActive { armOnOpenIfWanted() }
                }
            }
        } else if engine.assetsPresent() {
            prepareModel(allowDownload: false)
        }
    }

    // MARK: Level history

    /// Starts or ends the level history with the recording. Samples arrive in `appendLevel`,
    /// called from the capture engine's level callback, so there is no timer of its own.
    private func updateLevelHistory() {
        if case .recording(let id, _) = activity {
            guard quietMonitor == nil || levelRecordingID != id else { return }
            levelRecordingID = id
            hearsNothing = false
            quietMonitor = QuietInputMonitor(startedAt: ProcessInfo.processInfo.systemUptime)
            islandMeter.reset()
        } else {
            quietMonitor = nil
            levelRecordingID = nil
            hearsNothing = false
            silenceFinish = nil
            quietFinishIn = nil
            quietUntil = nil
            if case .transcribing = activity { return }
            recentLevels = Array(repeating: 0, count: 36)
        }
    }

    /// One posted level, about every 50 ms while recording.
    private func appendLevel(_ level: Float) {
        guard levelHistoryIsVisible, var quiet = quietMonitor else { return }
        var next = recentLevels
        next.removeFirst()
        next.append(isPaused ? 0 : min(max(level, 0), 1))
        recentLevels = next
        if isPaused {
            quiet = QuietInputMonitor(startedAt: ProcessInfo.processInfo.systemUptime)
            hearsNothing = false
        } else {
            hearsNothing = quiet.sample(level: level, at: ProcessInfo.processInfo.systemUptime)
        }
        quietMonitor = quiet
    }

    /// Finish when quiet (Settings, off by default): once a voice has been heard and the chosen
    /// wait passes without a sound, the recording ends the way a tap on stop ends it. Runs on
    /// every level, on screen or not, because a keyboard dictation records in the background.
    func watchForQuiet(_ level: Float, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard settings.finishWhenQuiet, !isHeld, case .recording(let id, _) = activity,
              activeNoteRequestID != id, currentRequest?.holdToTalk != true else {
            silenceFinish = nil
            if quietFinishIn != nil { quietFinishIn = nil }
            sayQuiet(until: nil)
            return
        }
        // The speaker can feed the start sound back into the mic. Exclude only those levels
        // from the quiet detector; the recognizer, recorder, and visible meter still receive them.
        guard startCueWindow?.contains(now) != true else { return }
        if silenceFinish == nil || silenceFinishRecording != id || silenceFinish?.wait != settings.finishWhenQuietWait {
            silenceFinish = SilenceFinish(wait: settings.finishWhenQuietWait)
            silenceFinishRecording = id
        }
        var countdown: Int?
        var quietEnds: Date?
        if isPaused {
            silenceFinish?.restartWait(at: now) // A pause is not quiet.
        } else {
            switch silenceFinish?.sample(level: level, at: now) {
            case .finish:
                var fields = silenceFinish?.journalFields ?? [:]
                fields["wait"] = JournalFormat.seconds(settings.finishWhenQuietWait)
                silenceFinish = nil
                Journal.log("quietFinish", recording: id, fields)
                ZoneLog.coordinator.info("quiet finish for \(id.uuidString.prefix(8), privacy: .public)")
                Task {
                    guard self.currentRequest?.id == id, !self.isPaused, !self.isHeld else { return }
                    await self.stopDictation(reason: "quiet")
                }
            case .quiet(let remaining):
                countdown = SilenceFinish.countdown(remaining: remaining, wait: settings.finishWhenQuietWait)
                if SilenceFinish.saysQuiet(remaining: remaining, wait: settings.finishWhenQuietWait) {
                    // The same end for as long as this quiet lasts, so the ring drains evenly.
                    quietEnds = quietUntil ?? Date().addingTimeInterval(remaining)
                }
            default:
                break
            }
        }
        if quietFinishIn != countdown { quietFinishIn = countdown }
        sayQuiet(until: quietEnds)
    }

    /// Dictation surfaces say "Quiet" from here: one island update each way.
    private func sayQuiet(until: Date?) {
        guard quietUntil != until else { return }
        quietUntil = until
        recordingLiveActivity.quiet(until: until)
    }

    /// Back on screen mid-recording: the quiet hint starts over rather than judging the gap.
    private func setLevelHistoryVisible(_ visible: Bool) {
        guard visible != levelHistoryIsVisible else { return }
        levelHistoryIsVisible = visible
        if visible, quietMonitor != nil {
            quietMonitor = QuietInputMonitor(startedAt: ProcessInfo.processInfo.systemUptime)
            hearsNothing = false
        }
    }

    /// The keyboard came on screen. On the phone a model idle for 15 s or more took about 3 s to
    /// wake, and the warm-up began only at the mic tap, so a short dictation waited behind it
    /// (dictations under 2 s after an idle phone: median 1.5 s from stop to text, against
    /// 0.24 s when warm). Warming here gives it the seconds between opening the keyboard and
    /// tapping the mic. Only while the microphone is ready: otherwise the tap opens Zone, which
    /// loads the model anyway.
    private func keyboardShown() {
        guard isArmed, modelIsReady, !activity.isBusy else { return }
        engine.prewarm()
    }

    // MARK: Foreground refresh

    func refreshFromStore() {
        keyboardPresence = store.keyboardPresence
        consumeAudioReceiptFromLedger()
        now = Date()
    }

    func updateMiniAcceleration(active: Bool) {
        (engine as? ParakeetEngine)?.configureAcceleration(enabled: settings.fasterDictation, foreground: active)
    }

    /// Only a real return from the background re-arms. Inactive also suspends accelerated prediction.
    func scenePhaseChanged(_ phase: ScenePhase) {
        updateMiniAcceleration(active: phase == .active)
        switch phase {
        case .background:
            Journal.log("appBackground", recording: currentRequest?.id, ["activity": activityName, "held": String(isHeld)])
            #if DEBUG
            runIslandProbeIfRequested()
            #endif
            sawBackground = true
            setLevelHistoryVisible(false)
            setForeground(false)
        case .active:
            setLevelHistoryVisible(true)
            setForeground(true)
            settings.publishKeyboardPreferences()
            settings.adoptKeyboardStyle()
            publishMicrophoneGrant()
            StandbyStoppedNotice.clearDelivered()
            if !meetingCaptureActive {
                restoreRecordingCard(after: "front")
                if recordingLiveActivity.isActive { reconcileIslandInFront() } else { showStandbyIsland(canCreate: true) }
            }
            Journal.log("appForeground", recording: currentRequest?.id, ["activity": activityName, "held": String(isHeld)])
            dropStaleNotePage()
            resumeHeldRecordingOnForeground()
            // Warm the model whenever Zone comes up, armed or not: the next tap from the
            // keyboard should not pay for a cold load.
            if !modelIsReady, preparationTask == nil, engine.assetsPresent() { prepareModel(allowDownload: false) }
            Task { await refreshAudioRecovery() }
            // The keyboard may have learned words while Zone was away.
            refreshVocabularyCache()
        default:
            break
        }
    }

    func setForeground(_ active: Bool) {
        foregroundTask?.cancel()
        foregroundTask = nil
        appIsActive = active
        appLastActive = Date()
        guard active else { return }
        refreshStats()
        restoreSavedNoteFailure()
        store.purgeStalePayloads()
        refreshFromStore()
        if sawBackground {
            sawBackground = false
            armOnOpenIfWanted()
        }
        foregroundTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.appIsActive else { return }
                self.refreshFromStore()
                self.keepIslandInFront()
            }
        }
    }

    /// One visit to the app is enough: if setup is complete and the user has not turned it off,
    /// coming to the foreground arms the session so the keyboard's mic key works in place.
    private func armOnOpenIfWanted() {
        guard settings.startsSessionOnOpen, settings.hasCompletedOnboarding, !isArmed, !userEndedSession,
              microphonePermission == .granted, engine.assetsPresent(), !isDeletingModels else { return }
        Task { [weak self] in
            guard let self else { return }
            if !modelIsReady {
                prepareModel(allowDownload: false)
                await preparationTask?.value
            }
            guard modelIsReady, !isArmed, !userEndedSession, !isDeletingModels else { return }
            // In CarPlay the model stays loaded but the microphone waits for a recording: holding
            // it would move the car's audio off its stereo channel (`CarAudioRoute`).
            if carPlayRoute() {
                Journal.log("standbySkipped", ["reason": "carPlay", "after": "open"])
                return
            }
            try? await armSession()
        }
    }

    // MARK: Model

    func prepareModelIfNeededForOnboarding() {
        if engine.assetsPresent() {
            prepareModel(allowDownload: false)
        }
    }

    func unloadEngine() {
        guard retryingAudioID == nil, !isDeletingModels else { return }
        engine.unload()
        modelState = engine.assetsPresent() ? .loading : .missing
        publishSession()
    }

    var modelIsReady: Bool { modelState == .ready }
    /// True while a load (or download) of the speech model is under way.
    var isPreparingModel: Bool { preparationTask != nil || preparationLoad != nil }
    private var modelExitNotice: String? {
        preparationTask == nil && preparationLoad != nil ? "The speech model is still closing. Close Zone and open it again." : nil
    }

    func prepareModel(allowDownload: Bool = true) {
        guard allowDownload || engine.assetsPresent() else {
            if preparationTask == nil { modelState = .missing }
            return
        }
        guard preparationTask == nil, preparationLoad == nil, modelState != .ready, !isDeletingModels, libraryDownloads[selectedModel] == nil else { return }
        let token = UUID()
        preparationID = token
        let pulse = Watchdog.Pulse()
        let requested = ProcessInfo.processInfo.systemUptime
        let engine = self.engine
        let kind = engine.kind.rawValue
        let progressGate = ModelProgressGate()
        modelState = engine.assetsPresent() ? .loading : .downloading(progress: 0, file: "")
        // The load starts now, off the main actor. As a main-actor task it waited for launch
        // work to finish first: 240 to 700 ms in the simulator before the load even began.
        let load = Task.detached(priority: .userInitiated) {
            ZoneLog.coordinator.info("model load start \(kind, privacy: .public) wait=\(Int((ProcessInfo.processInfo.systemUptime - requested) * 1000)) ms")
            #if DEBUG && targetEnvironment(simulator)
            let args = ProcessInfo.processInfo.arguments
            if let index = args.firstIndex(of: "-zoneSlowModelLoad"), args.indices.contains(index + 1),
               let delay = Double(args[index + 1]), (0...60).contains(delay) {
                try await Task.sleep(for: .seconds(delay))
            }
            #endif
            try await ModelDownloader.$allowsNewTransfers.withValue(allowDownload) {
                try await engine.prepare { fraction, file in
                    guard progressGate.accept(fraction, file: file) else { return }
                    pulse.beat()
                    Task { @MainActor [weak self] in
                        guard let self, self.preparationID == token, case .downloading = self.modelState else { return }
                        self.modelState = file == "loading" ? .loading : .downloading(progress: fraction, file: file)
                    }
                }
            }
        }
        preparationLoad = load
        preparationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if preparationID == token { preparationLoad = nil; preparationID = nil }
            }
            do {
                try await Watchdog.run(what: "The speech model", limit: modelIdleLimit, pulse: pulse) { try await load.value }
                // An unload can land while this task waits to resume (the bake-off unloads
                // between engines); only claim ready when the engine is.
                guard engine.isReady else {
                    modelState = engine.assetsPresent() ? .failed("The speech model did not start. Try again.") : .missing
                    failPendingColdRequest("The speech model was unloaded before dictation could start. Tap the mic again.")
                    preparationTask = nil
                    return
                }
                PressTiming.mark("modelReady")
                modelState = .ready
                Task { await refreshAudioRecovery() }
                updateMiniAcceleration(active: UIApplication.shared.applicationState == .active)
                ZoneLog.coordinator.notice("model ready \(kind, privacy: .public) in \(Int((ProcessInfo.processInfo.systemUptime - requested) * 1000)) ms (since app start \(Int(ProcessInfo.processInfo.systemUptime - Self.processStart)) s)")
                publishSession()
                // Core ML leaves a full compiled copy behind whenever the container path changes.
                Task { [weak self] in
                    await Task.detached(priority: .utility) { CompiledModelJanitor.sweep() }.value
                    self?.libraryRevision += 1
                }
                if let pending = pendingColdRequestID {
                    pendingColdRequestID = nil
                    await startColdDictation(requestID: pending)
                }
            } catch is Watchdog.Stalled {
                preparationID = nil
                load.cancel()
                let message = "The speech model stopped responding. Close Zone and open it again."
                modelState = .failed(message)
                failPendingColdRequest(message)
                Task { _ = await load.result; self.preparationLoad = nil }
            } catch is CancellationError {
                modelState = engine.assetsPresent() ? .failed("The speech model stopped loading. Try again.") : .missing
                failPendingColdRequest("The speech model download stopped. Tap Download to try again.")
            } catch {
                let message = RecordingProblem.load.message(for: error)
                modelState = .failed(message)
                lastError = message
                failPendingColdRequest(message)
            }
            preparationTask = nil
        }
    }

    /// A keyboard request waits for the model only while that load can still succeed. Left
    /// pending after a failure, a later load (a reopen, a queued meeting) started the
    /// microphone long after the tap, with nobody asking.
    private func failPendingColdRequest(_ message: String) {
        guard let pending = pendingColdRequestID else { return }
        pendingColdRequestID = nil
        guard currentRequest == nil, let request = store.request, request.id == pending else { return }
        lastError = message
        if !activity.isBusy { activity = .failed(message) }
        publishStatus(.failed, for: request, message: message)
    }

    // MARK: Microphone

    var microphonePermission: AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }

    func requestMicrophonePermission() async -> Bool {
        let granted = await AVAudioApplication.requestRecordPermission()
        publishMicrophoneGrant()
        return granted
    }

    /// Zone's microphone permission as the app reads it, for a keyboard process whose own
    /// reading is stale (`KeyboardCapture.microphoneAllowed`). Called at launch, whenever Zone
    /// comes to the front and after every permission prompt.
    func publishMicrophoneGrant() {
        store.appMicrophoneGranted = AVAudioApplication.shared.recordPermission == .granted
    }

    // MARK: Session

    /// Foreground only. Loads the model if needed, activates audio and arms the warm path.
    /// - Parameter chosenByPerson: true for Home's Turn on and the Toggle Zone control. With
    ///   CarPlay connected, only such a standby outlasts the next recording.
    func armSession(chosenByPerson: Bool = false, pressedAt: TimeInterval? = nil, stillRequested: () -> Bool = { true }) async throws {
        try Task.checkCancellation()
        guard !isDeletingModels else { throw SpeechEngineError.unavailable("Model storage is being cleaned. Try again when it finishes.") }
        guard pressedAt != nil || openingPress == nil else { throw CancellationError() }
        let generation = sessionGeneration
        armingSessions += 1
        defer { armingSessions -= 1; publishSession() }
        // The keyboard reads a fresh heartbeat as "the app is taking the microphone" and leaves
        // it alone. Arming takes about a second with nothing else stamping it.
        publishSession()
        keepHeartbeatWhileClaimingMicrophone()
        let coldPress = pressedAt != nil
        if !modelIsReady && !coldPress {
            guard engine.assetsPresent() else { throw SpeechEngineError.notReady }
            prepareModel(allowDownload: false)
            await preparationTask?.value
            try Task.checkCancellation()
            guard generation == sessionGeneration, stillRequested() else { throw CancellationError() }
            guard modelIsReady else {
                if case .failed(let reason) = modelState { throw SpeechEngineError.unavailable(reason) }
                throw SpeechEngineError.notReady
            }
        }
        PressTiming.mark("permission")
        let granted: Bool
        do {
            granted = try await Watchdog.run(what: "Microphone access", limit: micStartLimit) { @MainActor in
                await self.requestSessionPermission()
            }
        } catch is Watchdog.Stalled {
            throw SpeechEngineError.unavailable("Check microphone access in Settings, then try again.")
        }
        PressTiming.mark("permissionDone")
        publishMicrophoneGrant()
        try Task.checkCancellation()
        guard generation == sessionGeneration, stillRequested() else { throw CancellationError() }
        guard granted else { throw CaptureError.noInputAvailable }
        // Activation runs on the audio hardware queue; End session meanwhile disarms, which
        // cancels it and leaves the session inactive.
        guard coldPress || (openingPress == nil && recordingPress == nil) else { throw CancellationError() }
        if coldPress {
            try checkPressOwner()
            guard openingPress != nil, !noteStartWithdrawn || !preparingNote else { throw CancellationError() }
            guard recordingLiveActivity.isActive else { throw RecordingLiveActivity.Failure.foregroundRequired }
        }
        if let armSessionCapture {
            do {
                try await Watchdog.run(what: "The microphone", limit: micStartLimit) { @MainActor in try await armSessionCapture() }
            } catch is Watchdog.Stalled { throw CaptureError.startTimedOut }
        } else { try await armCapture() }
        guard generation == sessionGeneration else { throw CancellationError() }
        if coldPress {
            guard openingPress != nil else { throw CancellationError() }
            try checkPressOwner()
        }
        PressTiming.mark("armed")
        isArmed = true
        userEndedSession = false
        sessionArmedByPress = false
        standbyChosenInCar = chosenByPerson && carPlayRoute()
        StandbyStoppedNotice.keepAlive(force: true)
        if islandSession == nil { islandSession = IslandSession(since: Date()) }
        refreshStats()
        store.purgeStalePayloads()
        touchActivity()
        startCountdown()
        if !coldPress {
            if chosenByPerson { engine.prewarm() }
            showStandbyIsland(canCreate: UIApplication.shared.applicationState == .active)
        }
        publishSession()
        DarwinNotifier.post(.sessionChanged)
    }

    // MARK: Dynamic Island

    /// Live microphone history for the island, filled whether or not Zone is on screen.
    @ObservationIgnored private var islandMeter = IslandMeter()
    /// This standby session's numbers for the island, from turning Zone on to turning it off.
    /// An interruption holds the session, so it keeps counting after a call.
    @ObservationIgnored private(set) var islandSession: IslandSession?
    @ObservationIgnored private var statsGeneration = 0

    func refreshStats() {
        statsGeneration += 1
        let generation = statsGeneration, since = islandSession?.since
        let words = settings.legacyWords, seconds = settings.legacySeconds, transferred = settings.transferTotals
        Self.history { [weak self] history in
            guard let (lifetime, session, garden) = history.islandStats(legacyWords: words, legacySeconds: seconds, since: since, transferred: transferred) else { return }
            Task { @MainActor [weak self] in
                guard let self, generation == self.statsGeneration else { return }
                self.settings.applyGarden(garden)
                self.settings.applyStats(lifetime)
                guard let since, self.islandSession?.since == since else { return }
                let updated = IslandSession(since: since, dictations: session.count, words: session.words,
                                            seconds: Int(session.seconds.rounded()), recordedSeconds: session.seconds,
                                            measuredSeconds: session.measuredSeconds, keptWords: session.kept)
                guard self.islandSession != updated else { return }
                self.islandSession = updated
                if self.isArmed, self.recordingLiveActivity.showsStandby { self.showStandbyIsland(canCreate: false) }
            }
        }
    }

    func confirmKept(_ id: UUID, text: String) {
        let words = text.split(whereSeparator: \.isWhitespace).count
        Self.history { $0.confirmKept(id: id, words: words) }
    }

    func didResetStats() {
        statsGeneration += 1
        settings.didResetStats()
        refreshStats()
    }

    /// Owns the Dynamic Island while the microphone waits, so iOS shows Zone's small island
    /// instead of its own wide microphone pill. Off in Settings, or with no session, it ends.
    private func showStandbyIsland(canCreate: Bool) {
        guard isArmed, !activity.isBusy, openingPress == nil, !recordingLiveActivity.isPreviewing else { return }
        if settings.islandWhileReady {
            recordingLiveActivity.standby(until: armedUntil, canCreate: canCreate)
        } else if recordingLiveActivity.showsStandby, !pressHoldsReadyCard {
            recordingLiveActivity.end()
        }
        checkIsland(after: "standby")
    }

    // MARK: Keeping the island

    /// The person cleared the card from the Lock Screen and no card has been made since.
    @ObservationIgnored private var islandClearedByPerson = false
    /// "Zone's island ended" is posted for the card now missing.
    @ObservationIgnored private var islandLossNotified = false
    /// The last card iOS ended went at its eight-hour limit, so the notification says so.
    @ObservationIgnored private var islandLossAtLimit = false
    /// When Zone in front last asked iOS for a missing card, so a refusal is not retried every 2 s.
    @ObservationIgnored private var islandRestoreTriedAt = Date.distantPast
    /// Posts and withdraws "Zone's island ended". Tests count them instead.
    @ObservationIgnored var postIslandLostNotice: @MainActor (_ reachedLimit: Bool) -> Void = { IslandLostNotice.post(reachedLimit: $0) }
    @ObservationIgnored var withdrawIslandLostNotice: @MainActor () -> Void = { IslandLostNotice.withdraw() }
    /// "Zone is off", after the person cleared Zone's card and standby ended with it.
    @ObservationIgnored var postClearedCardNotice: @MainActor () -> Void = { StandbyStoppedNotice.postCleared() }
    /// The waits between a backgrounded press's tries at the microphone. Tests shorten them.
    @ObservationIgnored var pressArmPauses: [Duration] = PressArmRetry.pauses
    /// Whether a press finds Zone on screen, where the microphone needs no grant from iOS.
    @ObservationIgnored var pressFindsZoneInFront: @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }

    /// A card went without Zone ending it (`RecordingLiveActivity.lost`): iOS's limit, or the
    /// person clearing it. A press recording saves its audio if its required card cannot return.
    /// Standby is checked again when the recording settles.
    private func islandLost(_ ending: IslandUpkeep.Ending, age: TimeInterval) {
        if let press = openingPress, !recordingLiveActivity.isActive {
            if ending == .ended { noteMissingRecordingCard(press.id) }
            abandonOpeningPress()
        }
        if ending == .dismissed { islandClearedByPerson = true }
        islandLossAtLimit = ending == .ended && IslandUpkeep.reachedSystemLimit(age: age)
        checkIsland(after: ending.rawValue)
    }

    /// Wherever the microphone waits with Settings > Dynamic Island on, it waits under Zone's
    /// card. Checked whenever that can change: a card went, standby took the microphone back,
    /// a recording settled, Zone is in front. In front a missing card is made again; in the
    /// background, where iOS makes none, the person is told once (`IslandUpkeep`).
    private func checkIsland(after event: String) {
        // One ActivityKit snapshot decides both whether to wait and whether the card is up.
        let card = recordingLiveActivity.cardPresence
        guard card != .awaitingUpdate else { return }
        let situation = IslandUpkeep.Situation(
            showsIsland: settings.islandWhileReady,
            activitiesEnabled: recordingLiveActivity.activitiesEnabled,
            microphoneReady: isArmed && !activity.isBusy && !meetingCaptureActive,
            hasCard: card == .visible,
            inFront: appIsActive,
            clearedByPerson: islandClearedByPerson,
            notifies: settings.islandLostNotice,
            alreadyNotified: islandLossNotified)
        switch IslandUpkeep.response(to: situation) {
        case .nothing:
            // Up again, or no longer wanted: a notification would describe nothing.
            if situation.hasCard || !situation.showsIsland { islandIsBack() }
        case .restoreNow:
            guard Date().timeIntervalSince(islandRestoreTriedAt) >= 60 else { return }
            islandRestoreTriedAt = Date()
            recordingLiveActivity.standby(until: armedUntil, canCreate: true)
            Journal.log("islandRestored", ["after": event, "made": String(recordingLiveActivity.showsStandby)])
            if recordingLiveActivity.isActive { islandIsBack() }
        case .turnOff:
            // A note is on its way to the microphone: let it record. This is checked again
            // when that recording settles, with the card still cleared.
            guard !startingNote else { return }
            Journal.log("standbyEndedByClearedCard", ["after": event, "appState": Self.appStateName()])
            endSession(reason: .clearedCard)
            postClearedCardNotice()
        case .notify:
            islandLossNotified = true
            Journal.log("islandMissing", ["after": event, "limit": String(islandLossAtLimit),
                                          "appState": Self.appStateName()])
            postIslandLostNotice(islandLossAtLimit)
        }
    }

    /// A card is up again: the notification no longer describes anything.
    private func islandIsBack() {
        islandClearedByPerson = false
        islandLossAtLimit = false
        guard islandLossNotified else { return }
        islandLossNotified = false
        withdrawIslandLostNotice()
    }

    /// Standby ended: nothing is missing any more.
    private func forgetIslandLoss() {
        islandClearedByPerson = false
        islandLossAtLimit = false
        islandRestoreTriedAt = .distantPast
        guard islandLossNotified else { return }
        islandLossNotified = false
        withdrawIslandLostNotice()
    }

    /// While Zone stays in front (every 2 s): the card it leaves behind is never more than
    /// `IslandUpkeep.renewAfter` old, and a card that went meanwhile is made again.
    private func keepIslandInFront() {
        guard isArmed, !activity.isBusy, !meetingCaptureActive else { return }
        if recordingLiveActivity.showsStandby {
            recordingLiveActivity.renewStandbyIfAging()
            recordingLiveActivity.ensureRelay(retryAfter: 60)
        } else {
            checkIsland(after: "front")
        }
    }

    /// Inside a press (the Action Button, Control Center, a Shortcut or automation, the island's
    /// own buttons) iOS makes Zone a card even from the background. It is the one moment away
    /// from Zone when the eight-hour limit can start over, or a missing card come back.
    /// `restoreMissing` is false for presses that record: their recording makes its own card.
    func keepIslandDuringPress(_ source: String, restoreMissing: Bool) {
        guard isArmed, !activity.isBusy, !meetingCaptureActive, settings.islandWhileReady else { return }
        if recordingLiveActivity.showsStandby {
            recordingLiveActivity.renewStandbyIfAging(during: source)
            recordingLiveActivity.ensureRelay(retryAfter: 0)
        } else if restoreMissing, !recordingLiveActivity.isActive {
            recordingLiveActivity.standby(until: armedUntil, canCreate: true)
            Journal.log("islandRestored", ["after": source, "made": String(recordingLiveActivity.showsStandby)])
            if recordingLiveActivity.isActive { islandIsBack() }
        }
    }

    /// In front, the one place a card can be made again. An armed standby's card is renewed
    /// before iOS's eight-hour limit can take it in the background. A held card stays while its
    /// interruption may still end; once that standby cannot come back (no interruption pending,
    /// or held past the hold limit, as a held recording would be) it goes. A ready card with no
    /// standby is left alone: a press of the Action Button makes one before the microphone arms.
    private func reconcileIslandInFront() {
        guard !activity.isBusy, recordingLiveActivity.showsStandby else { return }
        if isArmed {
            recordingLiveActivity.renewStandbyIfAging()
            return
        }
        guard let since = recordingLiveActivity.standbyHeldSince else { return }
        if wasArmedBeforeInterruption, !InterruptionPolicy.holdExpired(heldSince: since, now: Date()) { return }
        wasArmedBeforeInterruption = false
        recordingLiveActivity.end()
    }

    /// Settings > Dynamic Island > Try it: twelve seconds of a pretend dictation in the real
    /// island, so a look can be judged where it lives. Nothing is recorded. A real dictation
    /// that starts meanwhile simply takes the island over; the preview then stops touching it.
    func previewIsland() async throws {
        guard !activity.isBusy, !meetingCaptureActive, !recordingLiveActivity.isPreviewing else { return }
        // Not control-owned: the Home Screen widget must never claim a pretend recording.
        let preview = UUID()
        let words = Self.islandPreviewScript.split(separator: " ")
        var meter = IslandMeter()
        func sample(through second: Int, from previous: Int) -> (levels: [UInt8], text: String) {
            for frame in (previous * 20 + 1)...(second * 20) {
                meter.append(Self.pretendVoice(Double(frame) / 20))
            }
            return (meter.snapshot, words.prefix(second * words.count / 10).joined(separator: " "))
        }
        let first = sample(through: 3, from: 0)
        try recordingLiveActivity.start(noteMode: false, controlOwned: false,
                                        preview: (preview, first.levels, first.text), onLost: { _ in })
        Journal.log("islandDemoBegan", ["id": preview.uuidString])
        defer {
            if recordingLiveActivity.finishPreview(preview) {
                if !activity.isBusy && !meetingCaptureActive { settleIslandAfterRecording() }
                Journal.log("islandDemoEnded", ["id": preview.uuidString])
            }
        }
        // SpringBoard can cancel a pending render when another ActivityKit update arrives.
        // Keep the first complete recording state on screen long enough to render.
        try await Task.sleep(for: .seconds(6))
        guard recordingLiveActivity.previewID == preview, !activity.isBusy, !meetingCaptureActive else { return }
        let last = sample(through: 10, from: 3)
        recordingLiveActivity.live(levels: last.levels, text: last.text)
        try await Task.sleep(for: .seconds(4))
        guard recordingLiveActivity.previewID == preview, !activity.isBusy, !meetingCaptureActive else { return }
        recordingLiveActivity.processing()
        try await Task.sleep(for: .seconds(2))
    }

    /// After a recording or the preview: the standby card when the person keeps one, otherwise
    /// none. `kept` is how many words the recording saved (the check), nil when it kept nothing.
    /// If an interruption has standby's microphone right now (the recording finished during a
    /// call), the card is held, as standby's own would be, so it is there to update when the
    /// microphone comes back.
    private func settleIslandAfterRecording(kept: Int? = nil) {
        let keep = settings.islandWhileReady && (isArmed || wasArmedBeforeInterruption)
        recordingLiveActivity.ready(keepStandby: keep, until: armedUntil, kept: kept)
        if keep, !isArmed {
            recordingLiveActivity.standbyHeld(until: Date().addingTimeInterval(InterruptionPolicy.holdLimit))
        }
        checkIsland(after: "recording")
    }

    #if DEBUG
    /// Simulator screenshots: the standby card as an interruption holds it. The interruption is
    /// marked pending, as a real one would be, or Zone in front drops the card as an orphan.
    /// Simulator research (docs/research/2026-11-20-island-background): `-zoneIslandProbe drop`
    /// ends the standby card 3 s after Zone goes to the background, then runs the same check a
    /// card iOS ended would (the "island ended" notification), so a Control Center press, a
    /// shortcut or Zone in front can be watched bringing it back. `-zoneIslandProbe request`
    /// then also asks iOS for a new card right there, outside any press, which says whether the
    /// simulator refuses background requests the way a phone does.
    private func runIslandProbeIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-zoneIslandProbe"), index + 1 < arguments.count else { return }
        let mode = arguments[index + 1]
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            guard !self.appIsActive, self.isArmed, self.recordingLiveActivity.showsStandby else {
                return Journal.log("islandProbe", ["mode": mode, "skipped": "true", "armed": String(self.isArmed),
                                                   "card": String(self.recordingLiveActivity.showsStandby)])
            }
            self.recordingLiveActivity.end()
            Journal.log("islandProbe", ["mode": mode, "dropped": "true", "appState": Self.appStateName()])
            if mode == "request" {
                self.recordingLiveActivity.standby(until: self.armedUntil, canCreate: true)
                Journal.log("islandProbe", ["mode": mode, "made": String(self.recordingLiveActivity.showsStandby),
                                            "appState": Self.appStateName()])
            }
            self.checkIsland(after: "probe")
        }
    }

    func holdIslandPreviewAsInterrupted() {
        wasArmedBeforeInterruption = true
        recordingLiveActivity.standbyHeld(until: Date().addingTimeInterval(InterruptionPolicy.holdLimit))
    }

    /// Simulator screenshots: holds one phase of the island indefinitely. The card is created
    /// at launch, in front, and only updated afterwards, as a real standby would be.
    func holdIslandPreview(phase: RecordingActivityAttributes.ContentState.Phase, userPaused: Bool = false,
                           justFinished: Bool = false) async {
        if phase == .ready {
            // A session with something in it, as after a morning of use.
            var session = IslandSession(since: Date().addingTimeInterval(-72 * 60))
            for (words, seconds) in [(48, 21.0), (112, 44.0), (9, 4.0), (143, 61.0)] {
                session.add(words: words, seconds: seconds, kept: words)
            }
            islandSession = session
            recordingLiveActivity.standby(until: Date().addingTimeInterval(300), lastWords: 42,
                                          justFinished: justFinished, canCreate: true)
            return
        }
        do { try recordingLiveActivity.start(noteMode: false, controlOwned: false, onLost: { _ in }) } catch { return }
        if phase == .processing { return recordingLiveActivity.processing() }
        let words = Self.islandPreviewScript.split(separator: " ")
        var meter = IslandMeter()
        var clock: TimeInterval = 0
        var second = 0
        while !Task.isCancelled {
            for _ in 0..<20 { clock += 0.05; meter.append(Self.pretendVoice(clock)) }
            second += 1
            let spoken = words.prefix(min(words.count, second * 2)).joined(separator: " ")
            recordingLiveActivity.live(levels: meter.snapshot, text: spoken)
            if phase == .paused, second == 2 { recordingLiveActivity.paused(until: Date().addingTimeInterval(600)); return }
            if userPaused, second == 3 { recordingLiveActivity.userPaused(true); return }
            try? await Task.sleep(for: .seconds(1))
        }
    }
    #endif

    static let islandPreviewScript = "This is Zone in your Dynamic Island. It hears every word as you speak, keeps up while you talk, and leaves nothing behind when you stop."

    /// A level that moves like speech: syllables, with gaps between words.
    nonisolated static func pretendVoice(_ t: TimeInterval) -> Float {
        let syllable = max(0, sin(t * 11)) * (0.55 + 0.45 * sin(t * 2.9 + 1.3))
        let word = max(0, sin(t * 2.1)) > 0.2 ? 1.0 : 0.15
        return Float(min(1, syllable * word * 0.8))
    }

    var meetingIslandColors: (accentChoice: String, palette: IslandPalette) {
        (settings.accent.rawValue, settings.islandStyle.palette)
    }

    /// Settings changed the island's look or standby: redraw now rather than at the next state.
    func refreshIsland() {
        if !recordingLiveActivity.isPreviewing && (recordingLiveActivity.showsStandby || (isArmed && !activity.isBusy)) {
            showStandbyIsland(canCreate: UIApplication.shared.applicationState == .active)
        } else {
            recordingLiveActivity.refreshAppearance()
        }
        recordingLiveActivity.refreshRelayAppearance()
        MeetingCoordinator.current?.refreshIslandAppearance()
    }

    /// Arms the microphone (the hardware work runs off the main thread), then readies the cues
    /// so the first one played does not set up its audio queue on the main thread.
    private var microphoneLease: MicrophoneLease?
    private var captureArmsInFlight = 0

    private func appMicrophoneLease(from source: String) -> MicrophoneLease? {
        microphoneLease ?? store.microphoneOwnership.reserveForApp { operation, code in
            Journal.log("microphoneLockUnavailable", ["from": source, "operation": operation, "errno": String(code)])
            ZoneLog.audio.error("Microphone lock unavailable: \(operation, privacy: .public) errno \(code). Continuing with iOS microphone arbitration.")
        }
    }

    private func armCapture() async throws {
        guard let lease = appMicrophoneLease(from: "armCapture") else {
            throw SpeechEngineError.unavailable(KeyboardRecordingClaim.appRefusal)
        }
        microphoneLease = lease
        captureArmsInFlight += 1
        publishSession()
        keepHeartbeatWhileClaimingMicrophone()
        defer {
            captureArmsInFlight -= 1
            if captureArmsInFlight == 0, capture.state == .stopped, microphoneLease === lease { microphoneLease = nil }
            publishSession()
        }
        try await capture.arm(startLimit: micStartLimit)
        guard microphoneLease === lease else { throw CancellationError() }
        sounds.sessionArmed(true)
    }

    /// Synchronous: the session is inactive when this returns. See `AudioCaptureEngine.disarm`.
    private func disarmCapture() {
        sounds.sessionArmed(false)
        capture.disarm()
        microphoneLease = nil
    }

    func endSession(reason: SessionEndReason, keepingRecordingIndicator: Bool = false) {
        abandonOpeningPress()
        sessionGeneration &+= 1 // Off invalidates starts suspended on model/permission work.
        wasArmedBeforeInterruption = false
        if let pending = pendingColdRequestID {
            pendingColdRequestID = nil
            if let request = store.request, request.id == pending {
                lastHandledRequestID = request.id
                publishStatus(.cancelled, for: request, message: nil)
            }
        }
        ZoneLog.coordinator.info("endSession reason=\(String(describing: reason), privacy: .public)")
        if reason == .user { userEndedSession = true }
        sessionArmedByPress = false
        standbyChosenInCar = false
        carReleaseTask?.cancel()
        carReleaseTask = nil
        StandbyStoppedNotice.withdraw()
        if case .recording = activity {
            cancelDictation()
        }
        inactivityTask?.cancel()
        inactivityTask = nil
        countdownTask?.cancel()
        countdownTask = nil
        // Said before the microphone is given back: closing the audio session takes up to
        // 0.4 s on a car's call channel, and a keyboard tap in that time read the old "ready",
        // waited for a recording that could not start and showed an error instead of acting
        // (2026-11-22, twice in two minutes). The final state is published again below.
        isArmed = false
        armedUntil = nil
        publishSession()
        DarwinNotifier.post(.sessionChanged)
        if meetingCaptureActive {
            // Turning dictation off (or its timeout) must never cut a meeting: the microphone
            // stays with the meeting and is released when the meeting stops.
            meetingArmedCapture = true
        } else if clipSink != nil, reason == .user {
            clipArmedCapture = true
        } else {
            disarmCapture()
        }
        if !keepingRecordingIndicator { recordingLiveActivity.end() }
        isArmed = false
        armedUntil = nil
        islandSession = nil
        forgetIslandLoss()
        publishSession()
        DarwinNotifier.post(.sessionChanged)
    }

    /// After a recording, or when CarPlay connects while Zone waits: gives the car its audio back
    /// once nothing is recording, starting or waiting for the microphone. Deferred by
    /// `carReleaseDelay`, so a dictation started right after the last keeps the microphone.
    /// - Parameter afterKeyboardDictation: the recording just ended was the keyboard's, whose
    ///   next sentence usually follows (`carKeyboardReleaseDelay`).
    func releaseMicrophoneInCarSoon(afterKeyboardDictation: Bool = false) {
        guard isArmed, !standbyChosenInCar else { return }
        carReleaseTask?.cancel()
        carReleaseTask = Task { [weak self] in
            guard let delay = self.map({ afterKeyboardDictation ? $0.carKeyboardReleaseDelay : $0.carReleaseDelay }) else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.carReleaseTask = nil
            self.releaseMicrophoneInCarIfIdle()
        }
    }

    /// Standby's heartbeat: keeps the stopped notice ahead while Zone waits. A recording or a
    /// meeting owns the microphone then, and a killed recording has its own notice.
    private func refreshStandbyStoppedNotice() {
        if activity.isBusy || meetingCaptureActive || isHeld {
            StandbyStoppedNotice.withdraw()
        } else if isArmed {
            StandbyStoppedNotice.keepAlive()
        }
    }

    private func releaseMicrophoneInCarIfIdle() {
        guard isArmed, !standbyChosenInCar, !shortcutHasAudioWork, !shortcutAudioPolicyPending,
              currentRequest == nil, !isHeld, carPlayRoute() else { return }
        Journal.log("standbyReleased", ["reason": "carPlay", "appState": Self.appStateName()])
        endSession(reason: .carPlay)
    }

    /// Extends the armed window after any activity.
    private func touchActivity() {
        guard isArmed else { return }
        let policy = settings.inactivityPolicy
        inactivityTask?.cancel()
        inactivityTask = nil
        if policy.isUnbounded {
            // A session that only the user ends: no deadline, and no Duration built from infinity.
            armedUntil = nil
            publishSession()
            return
        }
        let deadline = policy.deadline(after: Date())
        armedUntil = deadline
        // A waiting island's ring follows the new deadline. At most one update per touch.
        if recordingLiveActivity.showsStandby {
            recordingLiveActivity.standby(until: deadline, canCreate: false)
        }
        inactivityTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(policy.timeout))
            guard !Task.isCancelled, let self else { return }
            await self.standbyReachedDeadline(deadline)
        }
        publishSession()
    }

    func standbyReachedDeadline(_ deadline: Date) async {
        guard isArmed, armedUntil == deadline else { return }
        if !shortcutHasAudioWork {
            _ = await startPendingRequestIfAny(attempt: 0, through: deadline)
            guard isArmed, armedUntil == deadline else { return }
            if activity.isRecording { return }
        }
        if shortcutHasAudioWork {
            touchActivity()
        } else {
            endSession(reason: .timeout)
        }
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                self?.now = Date()
                // The privacy policy promises an unused result and the typed context around it
                // are gone after 15 minutes; the keyboard purges when it appears, the app once a
                // minute while armed, on arming and on returning to the foreground.
                if ticks % 60 == 0 { self?.store.purgeStalePayloads() }
                ticks += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func publishSession() {
        var session = SessionState(
            isArmed: isArmed,
            armedUntil: armedUntil,
            modelReady: modelIsReady,
            heartbeat: Date(), recording: openingPress != nil || activity.isRecording || meetingCaptureActive || clipSink != nil
                || startingNote || armingSessions > 0 || captureArmsInFlight > 0)
        if meetingCaptureActive { session.microphoneBusyMessage = Self.meetingRefusal }
        else if let clipRefusal { session.microphoneBusyMessage = clipRefusal }
        else if activity.isRecording { session.microphoneBusyMessage = noteIsLive ? Self.noteRefusal : RecordingRefusal.recording }
        else if startingNote { session.microphoneBusyMessage = RecordingRefusal.starting }
        else if !activity.isRecording, session.recording == true {
            session.microphoneBusyMessage = RecordingRefusal.starting
        }
        session.holdsMicrophoneLease = microphoneLease?.holdsPeerLock == true
        store.session = session
        // The Toggle Zone control redraws only when asked, so it is told on a real change,
        // not on every heartbeat.
        let now = Date()
        let standby = StandbyControlState(isOn: isArmed, until: isArmed && !shortcutHasAudioWork ? armedUntil : nil,
                                         refreshedAt: now)
        let changed = publishedStandby?.isOn != standby.isOn || publishedStandby?.until != standby.until
        if changed || (isArmed && now.timeIntervalSince(publishedStandby?.refreshedAt ?? .distantPast) >= 10) {
            publishedStandby = standby
            StandbyControlState.publish(standby, reload: changed)
        }
    }
    private var publishedStandby: StandbyControlState?

    /// While Zone holds or is about to hold the microphone (arming, a recording, a held one, a
    /// meeting, a note starting) the heartbeat stays fresh even when no audio buffer stamps it,
    /// so the keyboard never starts its own recording into Zone's. Ends by itself.
    private func keepHeartbeatWhileClaimingMicrophone() {
        guard heartbeatWhileClaimingTask == nil else { return }
        heartbeatWhileClaimingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                guard self.shortcutHasAudioWork || self.isHeld else {
                    self.heartbeatWhileClaimingTask = nil
                    return
                }
                self.publishSession()
            }
        }
    }
    @ObservationIgnored private var heartbeatWhileClaimingTask: Task<Void, Never>?

    /// How long the last piece of a recording may take to recognize. The slowest of 1,005
    /// stops in the phone's log took 21 seconds; this allows a minute, more for long audio.
    var recognitionLimitOverride: TimeInterval?
    private func recognitionLimit(audioSeconds: Double) -> TimeInterval {
        recognitionLimitOverride ?? min(max(60, audioSeconds / 2), 300)
    }

    /// Home's Turn on, from the Toggle Zone control once Zone is in front. The control's
    /// intent does not wait for this: the session is the app's own, started in the foreground
    /// like a tap on Turn on, and the control is redrawn when it is armed.
    func turnStandbyOnFromControl() {
        guard !isArmed else { return }
        Task {
            do {
                try await armSession(chosenByPerson: true)
            } catch is CancellationError {
                // Off superseded this startup; keep the person's requested state.
            } catch {
                Journal.log("standbyControlFailed", ["error": JournalFormat.error(error)])
                let message = RecordingProblem.microphone.message(for: error)
                lastError = message
                if !activity.isBusy { activity = .failed(message) }
            }
        }
    }

    /// Home's Turn off, from the Toggle Zone control. Turning a session off cancels a
    /// recording in progress, and a control must never throw one away.
    func turnStandbyOffFromControl() throws {
        guard !activity.isBusy, !startingNote, openingPress == nil else {
            throw ShortcutFailure(message: "Zone is recording. Finish the recording, then turn Zone off.")
        }
        guard isArmed || armingSessions > 0 else { return }
        endSession(reason: .user)
    }

    // MARK: URL (cold path)

    var keyboardDestination: ZoneContract.Destination?

    func handle(url: URL) {
        if let destination = ZoneContract.Destination(url: url) {
            guard !shortcutHasAudioWork, retryingAudioID == nil else { return }
            showsDictationScreen = false
            if destination != .home { closeNotePage(reason: "keyboardNavigation") }
            keyboardDestination = destination
            return
        }
        #if targetEnvironment(simulator)
        // Simulator only: `zone://debug-interrupt?type=began` and `?type=ended&resume=1` post
        // the same notification iOS posts for an alarm or a call, so the hold and resume path
        // can be driven end to end without a phone.
        // `delay=3` waits before posting (past the URL prompt's foreground bounce), and
        // `endAfter=3` posts the end that many seconds after the beginning, like a snoozed alarm.
        if url.host == "debug-interrupt" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            let began = value("type") != "ended"
            let resume = value("resume") == "1"
            let delay = Double(value("delay") ?? "") ?? 0
            let endAfter = Double(value("endAfter") ?? "")
            func post(began: Bool) {
                var info: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: began
                    ? AVAudioSession.InterruptionType.began.rawValue : AVAudioSession.InterruptionType.ended.rawValue]
                if began { info[AVAudioSessionInterruptionReasonKey] = AVAudioSession.InterruptionReason.default.rawValue }
                if !began, resume { info[AVAudioSessionInterruptionOptionKey] = AVAudioSession.InterruptionOptions.shouldResume.rawValue }
                NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
                                                object: AVAudioSession.sharedInstance(), userInfo: info)
            }
            Task { @MainActor in
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                post(began: began)
                if began, let endAfter {
                    try? await Task.sleep(for: .seconds(endAfter))
                    post(began: false)
                }
            }
            return
        }
        #endif
        if url.host == "recording" {
            // The Live Activity: a note's card is already on screen, a dictation's screen comes
            // back. With nothing recording, a finished dictation screen goes; a fresh Note
            // saved page stays, since opening Zone from the island is a way to reach it.
            // Journaled: on 2026-11-22 Zone came forward a second time, 0.7 s after the person
            // went back to Messages mid-recording, on this screen. Eight times in 107 keyboard
            // recordings since November 19, and nothing said which link did it.
            Journal.log("openedByLink", ["link": "recording", "busy": String(activity.isBusy),
                                         "origin": String(describing: currentOrigin)])
            if activity.isBusy {
                showRecordingScreen()
            } else {
                showsDictationScreen = false
            }
            return
        }
        guard let requestID = ZoneContract.requestID(from: url) else { return }
        guard let request = store.request else {
            reportMissingKeyboardRequest(requestID)
            return
        }
        guard request.id == requestID, request.schema == ZoneContract.schemaVersion else {
            Journal.log("coldURLIgnored", recording: requestID, ["reason": "request mismatch"])
            return
        }
        if currentRequest?.id == requestID {
            Journal.log("openedByLink", recording: requestID, ["link": "dictate", "busy": "true", "again": "true"])
            showRecordingScreen()
            return
        }
        guard let status = store.status, status.requestID == requestID, status.generation == request.generation,
              [.requested, .needsApp, .starting].contains(status.phase),
              request.generation > store.ledger.droppedGeneration,
              abs(request.createdAt.timeIntervalSinceNow) <= ColdStart.requestWindow else {
            Journal.log("coldURLIgnored", recording: requestID, ["reason": "inactive or expired"])
            return
        }
        if meetingCaptureActive || clipSink != nil {
            let reason = meetingCaptureActive ? Self.meetingRefusal : clipPurpose.refusal
            publishStatus(.failed, for: request, message: reason)
            lastHandledRequestID = requestID
            return
        }
        // The keyboard sent the person here to dictate: nothing about the last note may stand
        // in front of its screen.
        if !activity.isBusy { activity = .idle }
        needsFreshKeyboardTap = false
        closeNotePage(reason: "keyboardRequest")
        clearNoteOutcome()
        // The URL owns this request from here. A launch now keeps its `requested` status, so
        // a ping for it would otherwise reach `startPendingRequestIfAny` too, and answer
        // `needsApp` while the model loads, or race this path to start it.
        lastHandledRequestID = requestID
        showsDictationScreen = true
        lastError = nil
        if engine.kind == .appleSpeech || engine.kind == .appleDictation {
            // A keyboard sent here because local speech was unavailable must not select Apple
            // again. Keep the developer's persisted engine choice for the next normal launch.
            Task { [weak self] in
                guard let self else { return }
                await preparationTask?.value
                guard store.request?.id == requestID, let status = store.status,
                      status.requestID == requestID, [.requested, .needsApp, .starting].contains(status.phase),
                      request.generation > store.ledger.droppedGeneration, currentRequest == nil else { return }
                guard !activity.isBusy, !startingNote, !isSwitchingEngine, !isDeletingModels,
                      retryingAudioID == nil, !meetingCaptureActive, clipRefusal == nil else {
                    publishStatus(.needsApp, for: request, message: "Tap the mic again when Zone is ready.")
                    return
                }
                if engine.kind == .appleSpeech || engine.kind == .appleDictation {
                    engine.unload()
                    engine = modelEngineFactory(.fluidSpeechMini)
                    modelState = engine.assetsPresent() ? .loading : .missing
                    Journal.log("keyboardColdModel", recording: requestID, ["module": engine.kind.rawValue])
                }
                prepareColdKeyboardRequest(request)
            }
            return
        }
        prepareColdKeyboardRequest(request)
    }

    private func prepareColdKeyboardRequest(_ request: DictationRequest) {
        let requestID = request.id
        if modelIsReady || engine.assetsPresent() {
            limitColdWait(for: request)
        }
        if modelIsReady {
            pendingColdRequestID = requestID
            Task {
                guard pendingColdRequestID == requestID else { return }
                pendingColdRequestID = nil
                await startColdDictation(requestID: requestID)
            }
        } else {
            if engine.assetsPresent() {
                pendingColdRequestID = requestID
                prepareModel(allowDownload: false)
            } else {
                needsFreshKeyboardTap = true
                modelState = .missing
                publishStatus(.failed, for: request, message: "Download the speech model in Zone, then tap the mic again.")
            }
        }
    }

    private var coldDeadline: Task<Void, Never>?
    private static let coldTimeoutMessage = "Dictation didn’t start in time. Go back and tap the mic again."

    private func limitColdWait(for request: DictationRequest) {
        coldDeadline?.cancel()
        let remaining = max(0, ColdStart.requestWindow - abs(request.createdAt.timeIntervalSinceNow))
        coldDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            guard let self, showsDictationScreen, !activity.isBusy,
                  store.request?.id == request.id, store.status?.requestID == request.id,
                  let phase = store.status?.phase, [.requested, .needsApp, .starting].contains(phase) else { return }
            pendingColdRequestID = nil
            activity = .failed(Self.coldTimeoutMessage)
            publishStatus(.failed, for: request, message: Self.coldTimeoutMessage)
        }
    }

    private func reportMissingKeyboardRequest(_ id: UUID) {
        Journal.log("requestMissing", recording: id,
                    ["appGroup": String(AppGroup.isReachable), "presence": store.keyboardPresence == nil ? "never" : "seen"])
        guard !activity.isBusy, !startingNote, !meetingCaptureActive, clipSink == nil else { return }
        let message = AppGroup.isReachable
            ? "The keyboard’s request didn’t reach Zone. Check Allow Full Access, then go back and tap the mic."
            : "The keyboard can’t reach this copy of Zone. Install a copy with a matching App Group."
        lastError = message
        activity = .failed(message)
        showsDictationScreen = true
    }

    private var coldStartInFlight: UUID?

    private func startColdDictation(requestID: UUID) async {
        guard coldStartInFlight != requestID, showsDictationScreen else { return }
        coldStartInFlight = requestID
        defer { if coldStartInFlight == requestID { coldStartInFlight = nil } }
        ZoneLog.coordinator.info("dictate URL for \(requestID.uuidString.prefix(8), privacy: .public)")
        // The warm path may already have started this very request (the keyboard opened the app
        // because its wait ran out); the screen just needs to show it.
        if let current = currentRequest, current.id == requestID {
            return
        }
        lastHandledRequestID = requestID
        if let refusal = keyboardRecordingRefusal(KeyboardRecordingClaim.appRefusal, from: "dictateURL", forRequest: requestID) {
            lastError = refusal
            activity = .failed(refusal)
            if let request = store.request, request.id == requestID { publishStatus(.failed, for: request, message: refusal) }
            return
        }
        guard let request = store.request, request.id == requestID else {
            reportMissingKeyboardRequest(requestID)
            return
        }
        func withinWindow() -> Bool {
            guard showsDictationScreen, store.request?.id == requestID,
                  let phase = store.status?.phase, [.requested, .needsApp, .starting].contains(phase) else { return false }
            guard abs(request.createdAt.timeIntervalSinceNow) <= ColdStart.requestWindow else {
                let message = Self.coldTimeoutMessage
                if !activity.isBusy { activity = .failed(message) }
                publishStatus(.failed, for: request, message: message)
                return false
            }
            return true
        }
        do {
            await settings.drainBeforeRecording()
            guard withinWindow() else { return }
            if !isArmed { try await armSession(stillRequested: withinWindow) }
            guard withinWindow(), store.request?.id == request.id, store.request?.generation == request.generation,
                  request.generation > store.ledger.droppedGeneration,
                  currentRequest == nil, !activity.isBusy else { return }
            beginRecording(for: request, origin: .keyboard)
        } catch is CancellationError {
            guard currentRequest == nil, store.request?.id == request.id, store.status?.phase != .failed else { return }
            publishStatus(.cancelled, for: request, message: nil)
        } catch {
            guard currentRequest == nil, store.request?.id == request.id else { return }
            let message = RecordingProblem.microphone.message(for: error)
            lastError = message
            activity = .failed(message)
            publishStatus(.failed, for: request, message: message)
        }
    }

    // MARK: Notes (Action Button, Shortcuts)

    /// Starts a note at once, under the note card. Called from Home, the Note saved page's mic
    /// and a cold `DictateNoteIntent` launch.
    func beginNoteDictation() { Task { await dictateNote() } }
    func beginShortcutDictation() { Task { await beginShortcut(noteMode: false) } }

    /// One note press, awaited: starts a note, or stops the one recording. The Action Button's
    /// intent runs the same path through `runRecordingShortcut`.
    func dictateNote() async { await beginShortcut(noteMode: true) }

    private var shortcutState: NoteActionPolicy.State {
        if startingNote { return .starting }
        switch activity {
        case .recording:
            return activeNoteRequestID != nil ? .recordingNote
                : (activeShortcutRequestID == currentRequest?.id && activeShortcutRequestID != nil ? .recordingDictation : .recordingElsewhere)
        case .transcribing: return .transcribing
        default: return .idle
        }
    }

    /// A control's recording that ended some other way than that control's own press, until the
    /// next press of that control (`NoteActionPolicy.offPressStarts`).
    @ObservationIgnored private var endedWithoutItsControl: (noteMode: Bool, at: Date)?
    /// Every press of the Voice note or Dictate and copy control (the Action Button, Control
    /// Center, a Shortcut) comes through here before anything else, and says what the press
    /// asks for. An Off that finds nothing to stop, right after this control's recording ended
    /// by itself, is the Action Button still showing On: it becomes a start.
    func resolveControlPress(noteMode: Bool, desiredState: Bool?) -> Bool? {
        let ended = endedWithoutItsControl
        // Any press of this control uses it up: iOS flips the control's own state on a press.
        if ended?.noteMode == noteMode { endedWithoutItsControl = nil }
        guard desiredState == false else { return desiredState }
        let ago = ended.map { (noteMode: $0.noteMode, secondsAgo: Date().timeIntervalSince($0.at)) }
        guard NoteActionPolicy.offPressStarts(state: shortcutState, noteMode: noteMode, endedByItself: ago) else {
            return desiredState
        }
        Journal.log("controlPressWasStale", ["mode": noteMode ? "note" : "dictate",
                                             "endedSecondsAgo": JournalFormat.seconds(ago?.secondsAgo ?? 0)])
        return true
    }

    /// A recording is stopping and keeping its words. If a control was showing it (its card
    /// was up) and this is not that control's own Off press ("shortcut"), the control may go
    /// on showing On for a while. A discard is left out on purpose: the X is pressed inside
    /// Zone, and an Off after it stays the no-op it always was.
    private func noteRecordingEnding(_ id: UUID, reason: String) {
        guard recordingLiveActivity.showsRecording else { return }
        let noteMode: Bool
        if activeNoteRequestID == id { noteMode = true }
        else if activeShortcutRequestID == id { noteMode = false }
        else { return }
        if reason == "shortcut" {
            if endedWithoutItsControl?.noteMode == noteMode { endedWithoutItsControl = nil }
        } else {
            endedWithoutItsControl = (noteMode, Date())
        }
    }

    func shouldRunRecordingControl(noteMode: Bool, desiredState: Bool) -> Bool {
        if startingNote, startingNoteMode != noteMode { return false }
        return NoteActionPolicy.action(for: shortcutState, noteMode: noteMode, desiredState: desiredState) != .ignore
    }

    /// In-app starts do not use the intent queue. A matching Off must join that startup
    /// and return only after its deferred stop finishes, without touching another mode.
    func finishStartingShortcut(noteMode: Bool, desiredState: Bool?) async throws -> Bool {
        guard startingNote else { return false }
        guard startingNoteMode == noteMode, desiredState != true else { throw RecordingUnchanged(message: RecordingRefusal.starting) }
        stopAfterStart = true
        await withCheckedContinuation { startupStopWaiters.append($0) }
        return true
    }

    private func beginShortcut(noteMode: Bool, trigger: RecordingTrigger = .inApp) async {
        if startingNote, startingNoteMode != noteMode { return }
        // X on the card called off a note still waiting for the microphone, and the person
        // pressed again before the wait ended: the same start goes on, rather than this press
        // counting as a stop for a recording that will never begin.
        if noteMode, startingNote, !noteRequested, !activity.isBusy {
            noteRequested = true
            Journal.log("noteStartResumed")
            return
        }
        let state = shortcutState
        switch NoteActionPolicy.action(for: state, noteMode: noteMode) {
        case .ignore: return
        case .stop: await stopDictation(reason: "shortcut")
        case .stopWhenStarted: stopAfterStart = true
        case .start:
            stopAfterStart = false
            startingNote = true
            startingNoteMode = noteMode
            defer {
                startingNote = false
                startingNoteMode = nil
                let waiters = startupStopWaiters
                startupStopWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
            noteSessionID = UUID()
            let token = noteSessionID
            lastSavedNote = nil
            // A new press supersedes whatever the last note left on screen. Edits in progress on
            // the page are saved by the page as it goes (NoteSavedPage.onDisappear).
            closeNotePage(reason: noteMode ? "newNote" : "newDictation")
            clearNoteOutcome()
            noteRequested = noteMode
            showsDictationScreen = !noteMode
            if noteMode {
                Journal.log("noteStarting", ["armed": String(isArmed), "model": String(describing: modelState),
                    "appState": Self.appStateName()])
            }
            do {
                if noteMode {
                    await startAppDictation(contextBefore: nil, replaceActive: false, asNote: true, trigger: trigger)
                } else {
                    do {
                        if !isArmed { try await armSession() }
                        await settings.drainBeforeRecording()
                        guard noteSessionID == token, showsDictationScreen, !activity.isBusy else { return }
                        // There is no destination field when a standalone Shortcut starts. The
                        // next keyboard offers an explicit Insert instead of guessing a target.
                        let generation = max(store.request?.generation ?? 0, store.ledger.droppedGeneration) + 1
                        let request = DictationRequest(id: UUID(), generation: generation, createdAt: Date(),
                                                       inputSession: nil, contextBefore: nil)
                        store.control = nil
                        store.request = request
                        lastHandledRequestID = request.id
                        beginRecording(for: request, origin: .keyboard, shortcut: true, trigger: trigger)
                    } catch is CancellationError {
                        return
                    } catch {
                        let message = RecordingProblem.microphone.message(for: error)
                        lastError = message
                        activity = .failed(message)
                    }
                }
            }
            if stopAfterStart {
                stopAfterStart = false
                // Preparation can lose to a keyboard request. Only stop the recording
                // created by this startup, never independent work that won that race.
                if noteSessionID == token, shortcutRequestToFinish(noteMode: noteMode) != nil {
                    ZoneLog.coordinator.info("second shortcut press while starting: stopping")
                    await stopDictation(reason: "shortcut")
                }
            }
        }
    }

    /// A shortcut press that arrived while the previous press is still being handled.
    func shortcutPressedAgain(noteMode: Bool) {
        if startingNote {
            if startingNoteMode == noteMode { stopAfterStart = true }
            return
        }
        Task { await beginShortcut(noteMode: noteMode) }
    }

    // MARK: Note card and page

    /// What the note card shows, or nil for no card. A note's own recording and recognition
    /// come first; then its start; then how the last one ended.
    private(set) var lastSetupIntentNote: UUID?

    private(set) var pressWaitingForSamples = false
    private(set) var lastSilentNoteKept = false
    var noteCard: NoteCardPhase? {
        switch activity {
        case .recording(let id, let startedAt) where id == activeNoteRequestID:
            return .recording(startedAt: startedAt)
        case .transcribing(let id) where id == activeNoteRequestID:
            return .saving
        default:
            break
        }
        if (startingNote && startingNoteMode == true && noteRequested) || (preparingNote && !noteStartWithdrawn) {
            return .starting(detail: noteStartDetail)
        }
        switch noteOutcome {
        case .noWords: return .noWords
        case .failed(let message): return .failed(message)
        case nil: return nil
        }
    }

    /// A note is starting, recording or being saved. The Home composer stays out of the way.
    var noteIsLive: Bool { noteCard?.isLive == true }

    /// The note card's line while a press gets ready, naming the slow part when there is one.
    private var noteStartDetail: String {
        if openingPress != nil || preparingNote { return "Opening microphone" }
        switch modelState {
        case .downloading(let progress, _): return "Downloading the speech model, \(Int(progress * 100))%"
        case .loading, .missing: return "Turning on the speech engine"
        case .ready, .failed: return isArmed ? "Starting" : "Turning on the microphone"
        }
    }

    /// X on the card before the recording began: the note never starts. During an Action
    /// Button press's preparation the press ends without recording; in Zone the start stops
    /// waiting for the microphone. Nothing was heard yet, so there is nothing to keep.
    func cancelNoteStart() {
        guard noteRequested || preparingNote else { return }
        Journal.log("noteStartWithdrawn", ["step": preparingNote ? "preparation" : "start"])
        if preparingNote {
            noteStartWithdrawn = true
            abandonOpeningPress()
        }
        noteRequested = false
    }

    /// A control can discard a thrown intent error. Keep its reason on Home and announce it
    /// through the system when Zone is away, so the press never fails without a receipt.
    @discardableResult
    func notePressFailed(_ message: String) -> Bool {
        guard !message.isEmpty, !activity.isBusy else { return false }
        activity = .failed(message)
        keepNoteFailure(message, at: noteClock())
        endNote(.failed(message))
        return !pressFindsZoneInFront()
    }

    // MARK: A failed press survives the process (NoteStartFailureRecord)

    /// Where a failed press's reason waits for Home if iOS ends Zone first.
    @ObservationIgnored private let noteFailureRecord: NoteStartFailureRecord
    /// The refusal this process shows on Home and has saved, while it still shows.
    @ObservationIgnored private var savedNoteFailure: String?
    /// A record may be on disk. Unknown until this process has looked, so it starts true; false
    /// once restored, cleared or found empty, so later activity changes cost no preference write.
    @ObservationIgnored private var noteFailureMayBeSaved = true

    private func keepNoteFailure(_ message: String, at date: Date) {
        savedNoteFailure = message
        noteFailureMayBeSaved = true
        noteFailureRecord.save(message, at: date)
    }

    /// Home stopped showing the saved refusal: dismissed, acknowledged by the next press, a
    /// recording started, or a newer result or failure took its place. Called from `activity`'s
    /// didSet, so every path that replaces it forgets it, including ones before it was restored.
    private func forgetNoteFailureIfReplaced() {
        guard noteFailureMayBeSaved else { return }
        if let savedNoteFailure, activity == .failed(savedNoteFailure) { return }
        savedNoteFailure = nil
        noteFailureMayBeSaved = false
        noteFailureRecord.clear()
    }

    /// Zone came to the screen in a new process: a refusal saved before iOS ended the last one is
    /// put back on Home, as if that process had stayed. Only the Home notice comes back. The card
    /// was for the moment of the press, and the notification was posted then, so neither repeats.
    /// Nothing replaces a recording, a result or a newer failure.
    private func restoreSavedNoteFailure() {
        guard noteFailureMayBeSaved, savedNoteFailure == nil else { return }
        guard let saved = noteFailureRecord.current(now: noteClock()) else {
            noteFailureMayBeSaved = false
            return
        }
        guard activity == .idle else {
            noteFailureMayBeSaved = false
            return noteFailureRecord.clear()
        }
        // Set before `activity`, so its didSet sees the restored refusal as still showing.
        savedNoteFailure = saved.message
        activity = .failed(saved.message)
        Journal.log("noteFailureRestored", ["ageSeconds": String(Int(noteClock().timeIntervalSince(saved.at).rounded()))])
    }

    /// X on a card that says how the last note ended. A failure it showed is acknowledged too,
    /// so Home does not repeat it.
    func dismissNoteOutcome() {
        NoteStartFailureNotice.clear()
        guard let outcome = noteOutcome else { return }
        clearNoteOutcome()
        if case .failed = outcome { acknowledgeActivity() }
    }

    private func clearNoteOutcome() {
        noteOutcomeExpiry?.cancel()
        noteOutcomeExpiry = nil
        noteOutcome = nil
    }

    /// A note ended without a page: the card says how for a few seconds, then folds away. A
    /// failure stays on Home (HomeNotice) until it is dismissed.
    private func endNote(_ outcome: NoteOutcome) {
        noteRequested = false
        noteOutcome = outcome
        switch outcome {
        case .noWords: Journal.log("noteEnded", ["outcome": "noWords"])
        case .failed(let message): Journal.log("noteEnded", ["outcome": "failed", "message": message])
        }
        noteOutcomeExpiry?.cancel()
        let shown = outcome
        noteOutcomeExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(shown == .noWords ? 3 : 10))
            guard !Task.isCancelled, let self, self.noteOutcome == shown else { return }
            self.noteOutcome = nil
        }
    }

    /// The note was saved: the Note saved page comes up over Zone, or waits for Zone to come
    /// back if it was saved from the background.
    private func showNotePage(for note: Note, audioSeconds: Double) {
        clearNoteOutcome()
        let saved = Set(notes.notes.map(\.id))
        let earlier = Array(unseenNotes.filter { $0.noteID != note.id && saved.contains($0.noteID) }
            .suffix(Self.unseenNotesLimit))
        notePage = NotePage(noteID: note.id, savedAt: noteClock(), notesBefore: max(notes.notes.count - 1, 0),
                            audioSeconds: audioSeconds, earlier: earlier)
        notePageSeen = appIsActive && !Self.savesNotesAsIfAway
        unseenNotes = earlier + [NotePage.Entry(noteID: note.id, audioSeconds: audioSeconds)]
        Journal.log("notePageShown", ["appState": Self.appStateName(), "earlier": String(earlier.count)])
    }

    /// Done, a swipe down, Added to Notes, or something new starting. A finished note's result
    /// is acknowledged with it, so nothing else shows it again.
    func closeNotePage(reason: String = "done") {
        guard notePage != nil else { return }
        notePage = nil
        if notePageSeen || !Self.pageSupersededReasons.contains(reason) { unseenNotes = [] }
        notePageSeen = false
        Journal.log("notePageClosed", ["reason": reason])
        if case .finished = activity, lastResultWasNote { acknowledgeActivity() }
    }

    /// Coming back to Zone: a page from a while ago is no longer news.
    private func dropStaleNotePage() {
        // Back in Zone with no page up: Notes on Home shows everything, so nothing is unseen.
        guard let page = notePage else { return unseenNotes = [] }
        guard noteClock().timeIntervalSince(page.savedAt) > Self.notePageFreshness else { return notePageSeen = true }
        closeNotePage(reason: "stale")
    }

    /// The page's text, edited. Emptying it deletes the note, as in the Notes editor.
    /// - Returns: false when the notes file refused the edit.
    @discardableResult
    func updateNote(_ id: UUID, text: String, opening: Note? = nil) -> Bool {
        guard let note = opening ?? notes.notes.first(where: { $0.id == id }), note.id == id else { return false }
        let saved = notes.update(note, text: text)
        if !notes.notes.contains(where: { $0.id == id }) { dropFromNotePage(id, reason: "emptied") }
        return saved
    }

    private func noteWords(_ output: String, original: String) -> String {
        let styled = textStyle.apply(output, personalWords: personalWords, systemWords: systemWords,
                                     spokenCorrections: settings.spokenCorrections, emoticons: settings.spokenEmoticons,
                                     smallOrdinals: settings.smallOrdinals, numbers: settings.numbers, california: settings.californiaMode, misheard: settings.misheard,
                                     autoCapitalization: settings.autoCapitalizationEnabled)
        return styled.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? original : styled
    }

    var failedNoteEdits: [UUID: String] = [:]

    @discardableResult
    func saveNoteDraft(_ draft: NoteEditDraft) -> Bool {
        guard let opened = draft.opened else { return false }
        return saveNoteDraft(opened.id, text: draft.text, opening: opened)
    }

    @discardableResult
    func saveNoteDraft(_ id: UUID, text: String, opening: Note? = nil) -> Bool {
        let saved = updateNote(id, text: text, opening: opening)
        if !saved { UINotificationFeedbackGenerator().notificationOccurred(.error) }
        failedNoteEdits[id] = saved ? nil : text
        return saved
    }

    /// A note is gone. The page goes with its last note; with others left it stays on them.
    private func dropFromNotePage(_ id: UUID, reason: String) {
        unseenNotes.removeAll { $0.noteID == id }
        guard let page = notePage, page.entries.contains(where: { $0.noteID == id }) else { return }
        if let remaining = page.removing(id) { notePage = remaining } else { closeNotePage(reason: reason) }
    }

    /// Delete on the page, after its confirmation.
    @discardableResult
    func deleteNote(_ id: UUID) -> Bool {
        guard let note = notes.notes.first(where: { $0.id == id }) else { return true }
        guard notes.delete(note) else { return false }
        let onPage = notePage?.entries.contains { $0.noteID == id } == true
        Journal.log("noteDeleted", ["from": onPage ? "notePage" : "app"])
        dropFromNotePage(id, reason: "deleted")
        return true
    }

    /// Added to Notes: the page goes, and Home opens Notes at this note for a moment.
    func revealNoteInLibrary(_ id: UUID) {
        closeNotePage(reason: "openNotes")
        let reveal = NoteReveal(noteID: id)
        noteReveal = reveal
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            guard let self, self.noteReveal == reveal else { return }
            self.noteReveal = nil
        }
    }

    // MARK: In-app dictation (practice field)

    /// - Parameters:
    ///   - replaceActive: false for the note path, which never replaces a recording that
    ///     started while it waited for the microphone.
    ///   - asNote: the recording becomes a note, unless the person called it off meanwhile.
    func startAppDictation(contextBefore: String?, replaceActive: Bool = true, asNote: Bool = false, trigger: RecordingTrigger = .inApp) async {
        guard !startingAppDictation, openingPress == nil else {
            // The composer's own start is already getting the microphone; that recording wins,
            // and this press has nothing left to start.
            if asNote {
                Journal.log("noteStartAbandoned", ["reason": "appDictationStarting"])
                noteRequested = false
            }
            return
        }
        if let refusal = keyboardRecordingRefusal(KeyboardRecordingClaim.appRefusal, from: asNote ? "note" : "home") {
            lastError = refusal
            activity = .failed(refusal)
            if asNote {
                noteRequested = false
                endNote(.failed(refusal))
            }
            return
        }
        startingAppDictation = true
        defer { startingAppDictation = false }
        do {
            if !isArmed {
                try await armSession()
            }
            await settings.drainBeforeRecording()
            // A keyboard request can start while model preparation or microphone permission
            // is awaited. The Action Button must not cancel that newer recording.
            if asNote, !noteRequested || activity.isBusy {
                Journal.log("noteStartAbandoned", ["reason": noteRequested ? "recordingElsewhere" : "withdrawn"])
                noteRequested = false
                return
            }
            if !replaceActive, activity.isBusy { return }
            let request = DictationRequest(
                id: UUID(), generation: 0, createdAt: Date(), inputSession: "app", contextBefore: contextBefore)
            beginRecording(for: request, origin: .app, note: asNote, trigger: trigger)
            if asNote { noteRequested = false }
        } catch is CancellationError {
            if asNote { noteRequested = false }
            return
        } catch {
            let message = RecordingProblem.microphone.message(for: error)
            lastError = message
            activity = .failed(message)
            if asNote { endNote(.failed(message)) }
        }
    }

    // MARK: Recording lifecycle

    /// - Parameters:
    ///   - note: the recording is a note (the Action Button, a Shortcut, Home's Dictate a note).
    ///     Only `startAppDictation` passes true, and only for a press nobody called off.
    ///   - shortcut: a dictation with no text field behind it: one started by a press on the
    ///     Action Button, a control or the island's Dictate. Like a note, it belongs to its
    ///     control, so every control shows it as recording and can stop it.
    private func beginRecording(for request: DictationRequest, origin: Origin, note: Bool = false, shortcut: Bool = false, trigger: RecordingTrigger = .inApp) {
        guard !isDeletingModels else {
            if origin == .keyboard { publishStatus(.failed, for: request, message: "Model storage is being cleaned. Try again when it finishes.") }
            if note { endNote(.failed("Model storage is being cleaned. Try again when it finishes.")) }
            return
        }
        guard retryingAudioID == nil else {
            if origin == .keyboard { publishStatus(.failed, for: request, message: Self.retryRefusal) }
            if note { endNote(.failed("Zone is transcribing a saved recording again. Try when it finishes.")) }
            return
        }
        guard !meetingCaptureActive else {
            if origin == .keyboard { publishStatus(.failed, for: request, message: Self.meetingRefusal) }
            lastError = Self.meetingRefusal
            activity = .failed(Self.meetingRefusal)
            if note { endNote(.failed(Self.meetingRefusal)) }
            return
        }
        if let clipRefusal {
            // Voice setup (or a bakeoff clip) has the microphone; it ends in a minute or two.
            if origin == .keyboard { publishStatus(.failed, for: request, message: clipRefusal) }
            lastError = clipRefusal
            activity = .failed(clipRefusal)
            if note { endNote(.failed(clipRefusal)) }
            return
        }
        if origin == .keyboard, !shortcut {
            guard capture.state == .armed || activity.isBusy else {
                publishStatus(.needsApp, for: request, message: "Open Zone to start a session.")
                return
            }
            guard request.generation > store.ledger.droppedGeneration,
                  !(store.control?.requestID == request.id && store.control?.action == .cancel),
                  KeyboardTapOwner.take(request, store: store) else { return }
        }
        consumeAudioReceiptFromLedger()
        switch activity {
        case .idle:
            break
        case .finished:
            // Starting again does not mean the previous result was used or dismissed.
            activity = .idle
        case .failed:
            activity = .idle
        case .recording, .transcribing:
            // Saved, not discarded: it may be a long recording held by an interruption.
            retireCurrentRecording(reason: "newRecording")
        }
        guard capture.state == .armed else {
            if origin == .keyboard {
                publishStatus(.needsApp, for: request, message: "Open Zone to start a session.")
            } else {
                // Never a silent success: the note screen and the Action Button both say so.
                Journal.log("recordingStartRefused", ["reason": "microphoneNotArmed", "mic": String(describing: capture.state)])
                lastError = "Zone's microphone was not ready. Try again."
                activity = .failed("Zone's microphone was not ready. Try again.")
                if note { endNote(.failed("Zone's microphone was not ready. Try again.")) }
            }
            return
        }
        do {
            let press = openingPress.flatMap { $0.id == request.id ? $0 : nil }
            let activityRequired = shortcutNeedsLiveActivity
            requiredCardRequestID = activityRequired ? request.id : nil
            shortcutNeedsLiveActivity = false
            PressTiming.mark("begin")
            let noteMode = note
            let controlOwned = shortcut || noteMode
            pressStartedRequestID = trigger == .control ? request.id : nil
            // A shortcut or note recording owns its Live Activity: it must exist before the
            // intent returns, so it is requested here, synchronously, before any audio is
            // used. Any other recording only shows one, and `Activity.request` is a
            // synchronous XPC (part of a 384 ms start hang), so that request waits until the
            // recording runs. Updating an activity already showing costs nothing either way.
            let deferredIndicator = !controlOwned && !recordingLiveActivity.isActive
            if !deferredIndicator {
                do {
                    try startRecordingIndicator(for: request.id, noteMode: noteMode, controlOwned: controlOwned, startedAt: press?.bridge.firstSample ?? Date())
                } catch {
                    if activityRequired {
                        Journal.log("shortcutIndicatorUnavailable", ["error": JournalFormat.error(error), "step": "start"])
                        shortcutActivityRequestFailed = true
                        throw error
                    }
                }
            }
            // Words already in the field (names, product terms) are the best hint we have,
            // with the vocabulary as last read: no disk read on the way to the first sample.
            PressTiming.mark("indicatorDone")
            engine.setPersonalWords(settings.cachedSpeechHintWords())
            engine.setContextHints(settings.usesTypedTextAsHints ? (request.contextBefore ?? "") : "")
            let beganAt = ProcessInfo.processInfo.systemUptime
            let writer: AudioRecoveryWriter
            do {
                writer = try press?.writer ?? audioRecoveryStore.begin(id: request.id, engine: engine.kind.rawValue,
                                                                       source: note ? .note : origin.historySource)
            } catch {
                if controlOwned { settleIslandAfterRecording() }
                throw AudioRecoveryError.unavailable
            }
            let session: SegmentedRecognition
            do {
                session = try press?.session ?? SegmentedRecognition(first: beginUserUtterance(recording: request.id, warmUp: trigger == .inApp, writer: writer))
            } catch {
                try? audioRecoveryStore.discard(request.id)
                if controlOwned { settleIslandAfterRecording() }
                throw error
            }
            ZoneLog.coordinator.info("utterance opened in \(Int((ProcessInfo.processInfo.systemUptime - beganAt) * 1000)) ms")
            PressTiming.mark("utterance")
            audioWriter = writer
            utterance = session
            segmented = session
            heldSince = nil
            holdNotice = nil
            recordingInterruptions = 0
            currentRequest = request
            currentOrigin = origin
            activeNoteRequestID = note ? request.id : nil
            if note { NoteStartFailureNotice.clear() }
            activeShortcutRequestID = shortcut ? request.id : nil
            // Its control shows this recording from now on, whatever the last one left behind.
            if note || shortcut, endedWithoutItsControl?.noteMode == note { endedWithoutItsControl = nil }
            // Whatever the last note left on screen is over: a new recording has the microphone.
            clearNoteOutcome()
            closeNotePage(reason: note ? "newNote" : "newRecording")
            liveTranscript = ""
            // The quiet cue does not suppress any of the speaker’s opening words.
            let playsSounds = settings.soundsEnabled
            audioRecoveryWarning = nil
            setPaused(false)
            if let press {
                recordingPress = press
                openingPress = nil
            } else {
                let gate = pauseGate
                capture.onSamples = { samples in
                    guard !gate.isPaused else { return }
                    writer.append(samples)
                    session.feed(samples)
                }
            }
            audioRecordID = request.id
            PressTiming.mark("capture")
            capture.startRecording(pausingMusic: true)
            if playsSounds && press == nil { sounds.use(settings.soundSet); sounds.playStart() }
            ZoneLog.coordinator.info("recording \(request.id.uuidString.prefix(8), privacy: .public) origin=\(String(describing: origin), privacy: .public)")
            Journal.log("recordingStarted", recording: request.id,
                        ["origin": activeNoteRequestID == request.id ? "note" : String(describing: origin),
                         "engine": engine.kind.rawValue, "appState": Self.appStateName(),
                         "sounds": String(playsSounds), "quietWait": settings.finishWhenQuiet ? String(settings.finishWhenQuietWait) : "off",
                         "recoveryFile": String(audioWriter != nil)])
            if request.id == launchRequestID {
                launchRequestID = nil
                // The store keeps `createdAt` to the whole second, so `sinceTap` can read up to a
                // second long; the keyboard's own `keyboardRequest` entry has the exact tap time.
                Journal.log("coldStart", recording: request.id,
                            ["sinceTap": JournalFormat.seconds(Date().timeIntervalSince(request.createdAt)),
                             "sinceLaunch": JournalFormat.seconds(ProcessInfo.processInfo.systemUptime - Self.processStart),
                             "appState": Self.appStateName()])
            }
            let startedAt = press?.bridge.firstSample ?? Date()
            pressWaitingForSamples = press.map { $0.bridge.firstSample == nil } ?? false
            recordingStartedAt = startedAt
            activity = .recording(requestID: request.id, startedAt: startedAt)
            if let id = SetupFacts.setupRecordingID(request.id, isNote: note, fromIntent: trigger != .inApp) {
                lastSetupIntentNote = id
            }
            RecordingSafetyNotice.arm()
            if let press {
                recordingLiveActivity.loadingModel(!modelIsReady)
                let load = preparationTask
                attachmentTask = Task { [weak self, weak press] in
                    let loaded = try? await Watchdog.run(what: "Loading the speech model", limit: 60) { await load?.value; return true }
                    guard let self, let press, !Task.isCancelled, currentRequest?.id == press.id else { return }
                    recordingLiveActivity.loadingModel(false)
                    do {
                        guard loaded == true, modelIsReady else {
                            throw ShortcutFailure(message: "The speech model could not load. Check Home to retry the recording.")
                        }
                        Journal.log("pressColdStart", recording: press.id, press.receipt(processStart: Self.processStart))
                        press.bridge.attach(try beginUserUtterance(recording: press.id, writer: press.writer))
                        Journal.log("pressModelReady", recording: press.id, ["intentMs": String(Int((ProcessInfo.processInfo.systemUptime - press.pressedAt) * 1000))])
                    } catch {
                        press.bridge.fail(error)
                        if case .recording = activity, !isHeld {
                            failRecording(error, session: session, request: request, origin: origin)
                        }
                    }
                }
            }
            // There is no length cap: a dictation runs as long as the person talks. Engines keep
            // memory flat (the model decodes rolling segments) and the
            // history keeps everything said so far.
            let engineName = engine.kind.rawValue
            let source: TranscriptSource = note ? .note : origin.historySource
            if press == nil || press?.bridge.firstSample != nil {
                Self.history { $0.begin(id: request.id, engine: engineName, source: source, now: startedAt) }
            }
            utteranceLimitTask?.cancel()
            utteranceLimitTask = Task { [weak self] in
                var ticks = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, case .recording(let id, _) = self.activity, id == request.id else { return }
                    if let error = session.failure {
                        self.failRecording(error, session: session, request: request, origin: origin)
                        return
                    }
                    self.liveTranscript = session.textSoFar
                    self.recordingLiveActivity.live(levels: self.islandMeter.snapshot, text: session.textSoFar)
                    if let failure = self.audioWriter?.failure {
                        self.failRecording(failure, session: session, request: request, origin: origin)
                        return
                    }
                    ticks += 1
                    if ticks % 60 == 0 {
                        Journal.log("recordingProgress", recording: request.id,
                                    ["audio": JournalFormat.seconds(session.audioSeconds),
                                     "words": JournalFormat.words(session.textSoFar),
                                     "held": String(self.isHeld), "paused": String(self.isPaused),
                                     "appState": Self.appStateName()])
                    }
                    if ticks % Self.historySaveInterval == 0 {
                        RecordingSafetyNotice.arm()
                        let text = session.textSoFar, seconds = session.audioSeconds
                        Self.history { $0.saveProgress(id: request.id, text: text, audioSeconds: seconds) }
                    }
                    if origin == .keyboard, ticks % 2 == 0 {
                        let decision = self.limits.decision(
                            now: Date(), startedAt: self.recordingStartedAt ?? Date(),
                            keyboardLastSeen: self.store.keyboardPresence?.lastSeen,
                            appLastActive: self.appIsActive ? Date() : self.appLastActive,
                            watchesKeyboard: !self.isHeld && self.activeShortcutRequestID != request.id)
                        if decision != .keepRecording {
                            ZoneLog.coordinator.info("auto stop \(String(describing: decision), privacy: .public) for \(request.id.uuidString.prefix(8), privacy: .public)")
                            self.autoStopNotice = DictationLimits.notice(for: decision)
                            Task { await self.stopDictation(reason: "limit:\(decision)") }
                            return
                        }
                    }
                    if origin == .keyboard, let control = self.store.control, control.requestID == request.id {
                        // Backstop for a lost controlChanged ping. Pause and resume keep this
                        // loop running: it also saves progress and watches for engine failure.
                        // It ends only when it applied a stop or cancel itself; one already
                        // applied ends the recording, and this loop with it, on its own.
                        if self.applyControl(control), control.action == .stop || control.action == .cancel { return }
                    }

                }
            }
            lastError = nil
            inactivityTask?.cancel()
            if origin == .keyboard {
                publishStatus(.recording, for: request, message: nil)
            }
            haptic(.medium)
            if deferredIndicator {
                Task { [weak self] in
                    // Only if this recording still runs and nothing (a shortcut settling) has
                    // shown an indicator for it meanwhile.
                    guard let self, case .recording(let id, _) = self.activity, id == request.id,
                          !self.recordingLiveActivity.isActive else { return }
                    try? self.startRecordingIndicator(for: request.id, noteMode: false, controlOwned: false)
                }
            }
            refreshVocabularyCache()
        } catch {
            utterance = nil
            currentRequest = nil
            activeNoteRequestID = nil
            let message = RecordingProblem.microphone.message(for: error)
            lastError = message
            activity = .failed(message)
            if origin == .keyboard {
                publishStatus(.failed, for: request, message: message)
            }
            if note { endNote(.failed(message)) }
        }
    }

    private func startRecordingIndicator(for requestID: UUID, noteMode: Bool, controlOwned: Bool,
                                         startedAt: Date = Date()) throws {
        try recordingLiveActivity.start(noteMode: noteMode, controlOwned: controlOwned, startedByPress: pressStartedRequestID == requestID, startedAt: startedAt,
                                        waitingForSamples: openingPress.map { $0.id == requestID && $0.bridge.firstSample == nil } ?? false) { [weak self] ending in
            self?.recordingCardLost(ending, requestID: requestID)
        }
    }

    /// A cleared card stops its recording. For system expiry, try one replacement before
    /// stopping an intent that requires the indicator. A foreground app recording can continue.
    private func recordingCardLost(_ ending: IslandUpkeep.Ending, requestID: UUID) {
        guard case .recording(let currentID, _) = activity, currentID == requestID else { return }
        switch IslandUpkeep.recordingResponse(to: ending) {
        case .stop:
            break
        case .keepRecording:
            restoreRecordingCard(after: "ended")
            let restored = recordingLiveActivity.showsRecording
            let needsCard = requiredCardRequestID == requestID || shortcutAudioPolicyPending || recordingPress?.id == requestID
            Journal.log("recordingCardReplacement", recording: requestID,
                        ["restored": String(restored), "required": String(needsCard)])
            guard needsCard, !restored else { return }
            noteMissingRecordingCard(requestID)
        }
        Task {
            guard case .recording(let stillRecording, _) = activity, stillRecording == requestID else { return }
            await stopDictation(reason: "liveActivityEnded")
        }
    }

    private func noteMissingRecordingCard(_ id: UUID) {
        stoppedForMissingCardID = id
        cardStopNotice.begin(id)
        recordingCardStopMessage = cardStopNotice.message
    }

    private func settleCardStopNotice(_ id: UUID, outcome: RecordingCardStopNotice.Outcome) {
        cardStopNotice.settled(id, as: outcome)
        guard let message = cardStopNotice.message else { return }
        recordingCardStopMessage = message
        if UIApplication.shared.applicationState != .active {
            Task { await postRecordingCardStop(message) }
        }
    }

    /// Makes the card for the recording that is running, when it has none. iOS refuses from the
    /// background; Zone coming to the front tries again.
    private func restoreRecordingCard(after event: String) {
        guard case .recording(let id, _) = activity, !recordingLiveActivity.isActive, !meetingCaptureActive else { return }
        let note = activeNoteRequestID == id
        try? startRecordingIndicator(for: id, noteMode: note, controlOwned: note || activeShortcutRequestID == id,
                                     startedAt: recordingStartedAt ?? Date())
        if recordingLiveActivity.isActive, isPaused { recordingLiveActivity.userPaused(true) }
        if recordingLiveActivity.isActive { Journal.log("recordingIslandRestored", recording: id, ["after": event]) }
    }

    /// A recognizer failure must stop microphone capture promptly, not leave a listening UI
    /// silently discarding later speech. Keep the recognized prefix before cancelling native work.
    private func failRecording(_ error: Error, session: UtteranceSession, request: DictationRequest, origin: Origin) {
        guard currentRequest?.id == request.id, utterance === session else { return }
        Journal.log("recordingFailed", recording: request.id,
                    ["error": JournalFormat.error(error), "audio": JournalFormat.seconds(session.audioSeconds),
                     "words": JournalFormat.words(session.textSoFar), "appState": Self.appStateName()])
        clearHold()
        segmented = nil
        capture.stopRecording()
        capture.onSamples = nil
        recordingPress?.stop()
        RecordingSafetyNotice.disarm() // Zone is alive and shows this failure itself.
        setPaused(false)
        let text = session.textSoFar, seconds = session.audioSeconds
        liveTranscript = text
        let message = RecordingProblem.transcribe.message(for: error)
        retainAudioFailure(request.id, text: text, message: message)
        Self.history { $0.finish(id: request.id, text: text, audioSeconds: seconds, status: .cutOff) }
        session.cancel()
        let wasNote = activeNoteRequestID == request.id
        activeNoteRequestID = nil
        utterance = nil
        currentRequest = nil
        lastError = message
        activity = .failed(message)
        if origin == .keyboard {
            levelChannel.send(0)
            publishStatus(.failed, for: request, message: message)
        }
        if wasNote { endNote(.failed(message)) }
        touchActivity()
    }

    /// - Parameter reason: who or what stopped it, for the recording log ("user", "keyboard",
    ///   "shortcut", "holdExpired", "limit:…").
    func stopDictation(reason: String = "user") async {
        guard case .recording(let requestID, _) = activity,
              let request = currentRequest, request.id == requestID,
              let session = utterance else { return }
        // Notes can pause for thought indefinitely, including a queued quiet-stop task.
        guard reason != "quiet" || activeNoteRequestID != requestID else { return }
        let origin = currentOrigin
        let press = recordingPress
        if let press { press.markStopped(loading: !modelIsReady) }
        let startedSpeaking = press?.bridge.firstSample ?? request.createdAt
        let stoppedAt = ProcessInfo.processInfo.systemUptime
        let wasHeld = isHeld
        let interruptions = recordingInterruptions
        Journal.log("recordingStopping", recording: requestID,
                    ["reason": reason, "held": String(wasHeld), "paused": String(isPaused),
                     "audio": JournalFormat.seconds(session.audioSeconds), "words": JournalFormat.words(session.textSoFar),
                     "interruptions": String(interruptions), "appState": Self.appStateName()])
        noteRecordingEnding(requestID, reason: reason)
        utteranceLimitTask?.cancel()
        clearHold()
        capture.stopRecording()
        capture.onSamples = nil
        recordingPress?.stop()
        setPaused(false)
        // The safety notice stays armed through recognition, the likeliest time to be killed
        // for memory, and is withdrawn once the words are saved (below) or the attempt fails.
        RecordingSafetyNotice.arm()
        defer { RecordingSafetyNotice.disarm() }
        // Held, the audio session is not ours: a cue would fail or land in someone's call.
        if settings.soundsEnabled, !wasHeld { sounds.playStop() }
        activity = .transcribing(requestID: requestID)
        if press != nil, sessionArmedByPress, !wasHeld, standbyPolicyAfterPress() == .release {
            if settings.soundsEnabled { await sounds.finishStopCue() }
            guard currentRequest?.id == requestID, utterance === session else { return }
            disarmCapture()
            isArmed = false
            armedUntil = nil
            publishSession()
        }
        // Keep recovery's liveness stamp fresh while a slow final segment is decoding.
        utteranceLimitTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.historySaveInterval))
                guard !Task.isCancelled, let self,
                      case .transcribing(let id) = self.activity, id == requestID else { return }
                let text = session.textSoFar, seconds = session.audioSeconds
                Self.history { $0.saveProgress(id: requestID, text: text, audioSeconds: seconds) }
            }
        }
        if origin == .keyboard {
            levelChannel.send(0)
            publishStatus(.transcribing, for: request, message: nil)
        }
        haptic(.light)
        do {
            if let writer = audioWriter {
                do { try await writer.finish() }
                catch { audioRecoveryWarning = RecordingProblem.storage.message(for: error) }
            }
            guard currentRequest?.id == requestID, utterance === session else { return }
            let keepCardLossAudio = stoppedForMissingCardID == requestID
            if keepCardLossAudio, let writer = audioWriter {
                let outcome = await retainStoppedAudio(requestID, writer: writer)
                settleCardStopNotice(requestID, outcome: outcome)
                guard currentRequest?.id == requestID, utterance === session else { return }
            }
            let finishStarted = ProcessInfo.processInfo.systemUptime
            // Presses run one at a time, so a recognizer that never answers used to hold every
            // later press until Zone was closed. Past the limit the recording counts as cut
            // off: the words so far stay in History and the audio stays for Transcribe again.
            let text = try await Watchdog.run(what: "The speech model", limit: recognitionLimit(audioSeconds: session.audioSeconds)) {
                try await session.finish()
            }
            ZoneLog.coordinator.notice("stop to text \(Int((ProcessInfo.processInfo.systemUptime - finishStarted) * 1000)) ms (engine), \(Int((finishStarted - stoppedAt) * 1000)) ms before it, for \(String(format: "%.1f", session.audioSeconds), privacy: .public) s of audio")
            let segments = (session as? SegmentedRecognition)?.summary
            Journal.log("recordingTranscribed", recording: requestID,
                        ["ms": String(Int((ProcessInfo.processInfo.systemUptime - stoppedAt) * 1000)),
                         "audio": JournalFormat.seconds(session.audioSeconds), "words": JournalFormat.words(text),
                         "segments": String(segments?.segments ?? 1), "failedSegments": String(segments?.failedSegments ?? 0),
                         "droppedAudio": JournalFormat.seconds(segments?.droppedSeconds ?? 0)])
            // A cancel may have landed while the engine was flushing.
            guard currentRequest?.id == requestID, utterance === session else { return }
            let seconds = session.audioSeconds
            let wasNote = activeNoteRequestID == requestID
            let statsStart = recordingStartedAt ?? request.createdAt
            var historyDurable = await Self.commitHistory {
                $0.finish(id: requestID, text: text, audioSeconds: seconds,
                          status: NoteReceipt.historyStatus(isNote: wasNote, noteWriteFailed: false),
                          interruptions: interruptions > 0 ? interruptions : nil, statsStartedAt: statsStart)
            }
            guard currentRequest?.id == requestID, utterance === session else { return }
            if keepCardLossAudio, let writer = audioWriter, writer.acceptedSamples > 0 {
                retainAudioFailure(requestID, text: text, message: "Recording stopped. Check Home to try the audio.")
            } else if let lost = segments?.failedSegments, lost > 0 {
                // A stretch between interruptions could not be fully recognized: the words are
                // saved, and the audio stays for a retry that hears all of it.
                retainAudioFailure(requestID, text: text,
                                   message: "Part of this recording could not be recognized. Transcribe the saved audio to get every word.")
            } else {
                // A note's receipt stays until the notes file holds it (`NoteReceipt`): a failed
                // write, or iOS ending Zone before the note is added below, would otherwise leave a hidden
                // `.note` History record and nothing on Home. `useRecoveredText` releases it
                // once `notes.add` succeeds.
                await finalizeAudio(requestID, text: text, isNote: wasNote,
                                    historyDurable: NoteReceipt.mayRelease(historyDurable: historyDurable, isNote: wasNote, noteWritten: false))
            }
            Journal.log("recordingSaved", recording: requestID,
                        ["status": wasNote ? "note" : "finished", "historySaved": String(historyDurable)])
            guard currentRequest?.id == requestID, utterance === session else { return }
            if wasNote { lastSilentNoteKept = audioRecoveryRecords.contains { $0.id == requestID && $0.state == .noWords } }
            let doubts = DoubtfulWords.candidates(session.doubtfulWords)
            let result = DictationResult(
                requestID: request.id, generation: request.generation, text: text,
                audioSeconds: seconds, createdAt: Date(), inputSession: request.inputSession,
                doubts: doubts.isEmpty ? nil : doubts)
            // No suspension between final ownership validation and saving the note.
            let savedNote = wasNote ? notes.add(noteWords(text, original: text), recordingID: requestID, createdAt: press == nil ? Date() : startedSpeaking) : nil
            let noteSaveFailed = wasNote && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && savedNote == nil
            if noteSaveFailed {
                let retrySaved = await Self.commitHistory {
                    $0.finish(id: requestID, text: text, audioSeconds: seconds, status: .cutOff)
                }
                historyDurable = historyDurable || retrySaved
                guard currentRequest?.id == requestID, utterance === session else { return }
            }
            utterance = nil
            segmented = nil
            currentRequest = nil
            lastResult = result
            liveTranscript = result.text
            lastResultWasNote = wasNote
            lastResultWasAudioRetry = false
            lastSavedNote = savedNote
            activeNoteRequestID = nil
            if let savedNote {
                confirmKept(requestID, text: savedNote.text)
                useRecoveredText(requestID)
            }
            let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            if noteSaveFailed {
                lastError = historyDurable
                    ? "Could not save the note. The original transcript is kept in History."
                    : "Could not save the note or History. Copy the transcript now; saved audio may still be available for recovery."
                activity = .failed(lastError!)
                endNote(.failed(lastError!))
            } else {
                activity = .finished(result, origin: origin)
                // Words, nothing lost, nothing failed: a success for the rating prompt. Keyboard
                // dictations finish here with Zone in the background, so they count but never ask.
                if words > 0, (segments?.failedSegments ?? 0) == 0 {
                    reviews.recordSuccess(onScreen: UIApplication.shared.applicationState == .active)
                }
                if let savedNote {
                    showNotePage(for: savedNote, audioSeconds: seconds)
                } else if wasNote {
                    endNote(.noWords)
                }
            }
            if origin == .keyboard, store.publishFinal(result, for: request) {
                publishStatus(.ready, for: request, message: nil)
                DarwinNotifier.post(.resultReady)
            }
            ZoneLog.coordinator.notice("result published \(Int((ProcessInfo.processInfo.systemUptime - stoppedAt) * 1000)) ms after stop")
        } catch {
            guard currentRequest?.id == requestID else { return }
            // Keep whatever was recognized before the engine failed.
            let partial = session.textSoFar, seconds = session.audioSeconds
            Journal.log("recordingFailed", recording: requestID,
                        ["error": JournalFormat.error(error), "step": "finish", "audio": JournalFormat.seconds(seconds),
                         "words": JournalFormat.words(partial)])
            liveTranscript = partial
            let message = RecordingProblem.transcribe.message(for: error)
            let retained = retainAudioFailure(requestID, text: partial, message: message)
            let audioKept = await retained?.value ?? false
            guard currentRequest?.id == requestID, utterance === session else { return }
            Self.history { $0.finish(id: requestID, text: partial, audioSeconds: seconds, status: .cutOff) }
            let wasNote = activeNoteRequestID == requestID
            activeNoteRequestID = nil
            utterance = nil
            segmented = nil
            currentRequest = nil
            lastError = message
            activity = .failed(message)
            if origin == .keyboard {
                publishStatus(.failed, for: request, message: message)
            }
            // When its audio was being kept, Home's recovery card can transcribe it again.
            if wasNote {
                endNote(.failed(audioKept
                    ? "The note's words could not be written out. Its audio is kept on Home to transcribe again."
                    : message == RecordingProblem.transcribe.rawValue
                        ? "The note's words could not be written out. Check Home for audio to try again."
                        : message))
            }
        }
        utteranceLimitTask?.cancel()
        touchActivity()
        releaseMicrophoneInCarSoon(afterKeyboardDictation: origin == .keyboard)
    }

    /// - Parameter playsSound: false when a new dictation or an engine switch replaces this one,
    ///   so the stop cue does not collide with the next start cue.
    func cancelDictation(playsSound: Bool = true) {
        if retryingAudioID != nil { cancelAudioRetry(); return }
        guard let request = currentRequest else {
            activity = .idle
            return
        }
        utteranceLimitTask?.cancel()
        capture.stopRecording()
        capture.onSamples = nil
        recordingPress?.stop()
        setPaused(false)
        RecordingSafetyNotice.disarm()
        if playsSound, settings.soundsEnabled { sounds.playStop() }
        // A cancel is the person's choice, so the history keeps nothing of it.
        let cancelledID = request.id
        Journal.log("recordingCancelled", recording: cancelledID,
                    ["audio": JournalFormat.seconds(utterance?.audioSeconds ?? 0), "held": String(isHeld)])
        clearHold()
        discardActiveAudio(cancelledID)
        Self.history { $0.cancel(id: cancelledID) }
        liveTranscript = ""
        activeNoteRequestID = nil
        utterance?.cancel()
        utterance = nil
        segmented = nil
        currentRequest = nil
        activity = .idle
        if currentOrigin == .keyboard {
            publishStatus(.cancelled, for: request, message: nil)
        }
        touchActivity()
        releaseMicrophoneInCarSoon(afterKeyboardDictation: currentOrigin == .keyboard)
    }

    /// Clears a finished or failed activity so the UI returns to idle.
    func acknowledgeActivity(resultWasUsed: Bool = false) {
        switch activity {
        case .finished(let result, _):
            if resultWasUsed { useRecoveredText(result.requestID) }
            activity = .idle
        case .failed:
            activity = .idle
        default:
            break
        }
    }

    func dismissDictationScreen() {
        coldDeadline?.cancel()
        pendingColdRequestID = nil
        showsDictationScreen = false
        acknowledgeActivity()
    }

    /// True while a keyboard or Shortcut dictation is running. Those own a full-screen recording
    /// screen. A note has its card instead, and the Home composer's own recordings have its bar.
    var hasRecordingScreen: Bool {
        activity.isBusy && currentOrigin == .keyboard && activeNoteRequestID == nil
    }

    /// Hides the dictation screen and leaves the recording running, so the rest of the app can
    /// be used. The strip over every page (RecordingStrip) brings the screen back. Offered only
    /// once recording has begun: during startup the screen's presence still steers the request.
    func hideRecordingScreen() {
        guard activity.isBusy else { return }
        showsDictationScreen = false
    }

    /// Brings back the dictation screen for the recording in progress. A note needs nothing:
    /// its card is on screen whenever Zone is.
    func showRecordingScreen() {
        guard activity.isBusy, activeNoteRequestID == nil else { return }
        showsDictationScreen = true
    }

    // MARK: Keyboard pings

    /// A Darwin ping arrives before the keyboard's preference write has propagated to this
    /// process, so the store is re-read for up to a second until a fresh request shows up.
    private func handleRequestChanged() {
        ZoneLog.coordinator.info("requestChanged ping received")
        AppEntry.noteAutomation("keyboardRequest")
        requestPollTask?.cancel()
        requestPollTask = Task { [weak self] in
            for attempt in 0..<10 {
                guard let self, !Task.isCancelled else { return }
                // Opening Zone arms the microphone off the main thread (up to about a second).
                // A tap in that window waits for it rather than being sent back to the app.
                // Answered first, so the keyboard's 200 ms probe sees someone is home and does
                // not start recording by itself while the microphone here comes up.
                if self.capture.isArming { self.acknowledgeRequestWhileArming() }
                var waits = 0
                while self.capture.isArming, waits < 40 {
                    waits += 1
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if await self.startPendingRequestIfAny(attempt: attempt) { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            ZoneLog.coordinator.error("requestChanged: no fresh request seen within 1 s")
        }
    }

    /// A fresh request seen while the microphone arms gets `starting` at once; the start itself
    /// follows once arming ends (`startPendingRequestIfAny` accepts that answer as its own).
    private func acknowledgeRequestWhileArming() {
        guard let request = store.request, request.schema == ZoneContract.schemaVersion,
              request.id != lastHandledRequestID, currentRequest?.id != request.id,
              let status = store.status, status.requestID == request.id, status.phase == .requested,
              request.generation > store.ledger.droppedGeneration else { return }
        answeredWhileArming = request.id
        publishStatus(.starting, for: request, message: nil)
    }
    @ObservationIgnored private var answeredWhileArming: UUID?

    /// Returns true once the request was acted on (started, refused, or redirected to the app).
    private func startPendingRequestIfAny(attempt: Int, through deadline: Date? = nil) async -> Bool {
        guard let expected = store.request, expected.id != lastHandledRequestID,
              expected.id != currentRequest?.id else { return false }
        if let deadline, expected.tappedAt > deadline { return false }
        await settings.drainBeforeRecording()
        guard !Task.isCancelled else { return true }
        guard let request = store.request, request.id == expected.id, request.generation == expected.generation,
              request.schema == ZoneContract.schemaVersion else { return false }
        if let deadline, request.tappedAt > deadline { return false }
        if request.id == lastHandledRequestID { return false }
        if let current = currentRequest, current.id == request.id { return false }
        guard let status = store.status, status.requestID == request.id, status.generation == request.generation,
              status.phase == .requested || (status.phase == .starting && answeredWhileArming == request.id) else {
            return false
        }
        answeredWhileArming = nil
        // The keyboard gave up on it (`droppedGeneration`): a late start would record for nobody.
        guard request.generation > store.ledger.droppedGeneration else { return false }
        lastHandledRequestID = request.id
        ZoneLog.coordinator.info("request \(request.id.uuidString.prefix(8), privacy: .public) seen on attempt \(attempt)")
        if meetingCaptureActive {
            // Refused with a reason the keyboard shows; the meeting keeps recording.
            publishStatus(.failed, for: request, message: Self.meetingRefusal)
            return true
        }
        if let clipRefusal {
            publishStatus(.failed, for: request, message: clipRefusal)
            return true
        }
        if retryingAudioID != nil {
            publishStatus(.failed, for: request, message: Self.retryRefusal)
            return true
        }
        // A voice note being spoken or recognized is never ended by a keyboard tap: the note
        // would stop mid-sentence and skip its own save. A held note (all its words in) is
        // still retired and saved below.
        if openingPress != nil { publishStatus(.failed, for: request, message: Self.noteRefusal); return true }
        var noteUnderWay = false
        if case .recording = activity { noteUnderWay = true }
        if case .transcribing = activity { noteUnderWay = true }
        if noteUnderWay, let current = currentRequest,
           activeNoteRequestID == current.id, !(heldSince != nil && segmented?.isSettled == true) {
            publishStatus(.failed, for: request, message: startRefusal ?? Self.noteRefusal)
            return true
        }
        switch activity {
        case .recording, .transcribing:
            // A new tap always wins, never a refusal. The previous recording's words are kept:
            // until 2026-11-03 they were discarded, and a recording held by a call was lost.
            ZoneLog.coordinator.info("new request supersedes an in-flight dictation")
            retireCurrentRecording(reason: "newRequest")
        default:
            break
        }
        guard isArmed, capture.state == .armed, modelIsReady else {
            ZoneLog.coordinator.info("request needs app: armed=\(self.isArmed) capture=\(String(describing: self.capture.state), privacy: .public) model=\(self.modelIsReady)")
            publishStatus(.needsApp, for: request, message: isArmed ? "Zone is getting ready." : "Open Zone to start a session.")
            return true
        }
        // Acknowledge before creating the engine stream so the keyboard knows someone is home.
        publishStatus(.starting, for: request, message: nil)
        beginRecording(for: request, origin: .keyboard)
        return true
    }

    /// The keyboard's control write may land after its ping; re-read for up to a second.
    private func handleControlChanged() {
        AppEntry.noteAutomation("keyboardControl")
        controlPollTask?.cancel()
        controlPollTask = Task { [weak self] in
            for _ in 0..<10 {
                guard let self, !Task.isCancelled else { return }
                if let control = self.store.control, let request = self.currentRequest,
                   control.requestID == request.id, control.generation == request.generation,
                   control != self.lastAppliedControl {
                    self.applyControl(control)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Returns whether the control was new and acted on.
    @discardableResult
    private func applyControl(_ control: DictationControl) -> Bool {
        guard let request = currentRequest, control.requestID == request.id,
              control != lastAppliedControl else { return false }
        lastAppliedControl = control
        switch control.action {
        case .stop:
            Task { await stopDictation(reason: "keyboard") }
        case .cancel:
            cancelDictation()
        case .pause:
            setPaused(true)
        case .resume:
            if isHeld { Task { await resumeHeldRecording(trigger: "keyboard") } } else { setPaused(false) }
        }
        return true
    }

    /// Settings' sound picker: hear the start cue of a set.
    func previewSound(_ set: DictationSounds.Set) {
        sounds.use(set)
        sounds.playStart()
        Task {
            try? await Task.sleep(for: .milliseconds(650))
            sounds.playStop()
        }
    }

    /// Home's pause control; the keyboard sends the same thing as a control action.
    func togglePause() {
        guard case .recording = activity else { return }
        if isHeld {
            Task { await resumeHeldRecording(trigger: "app") }
            return
        }
        setPaused(!isPaused)
    }

    private func setPaused(_ paused: Bool) {
        guard pauseGate.isPaused != paused || isPaused != paused else { return }
        pauseGate.isPaused = paused
        isPaused = paused
        pauseLimitTask?.cancel()
        guard case .recording = activity, let request = currentRequest else { return }
        recordingLiveActivity.userPaused(paused)
        haptic(.light)
        if currentOrigin == .keyboard { publishStatus(.recording, for: request, message: nil) }
        // A forgotten pause must not hold the mic open forever: after the session's idle
        // timeout (never less than five minutes) the recording finishes and keeps its words.
        if paused, let limit = settings.inactivityPolicy.pauseLimit {
            pauseLimitTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(limit))
                guard !Task.isCancelled, let self, self.isPaused, case .recording(let id, _) = self.activity, id == request.id else { return }
                await self.stopDictation(reason: "pauseLimit")
            }
        }
    }

    private func publishStatus(_ phase: DictationPhase, for request: DictationRequest, message: String?) {
        ZoneLog.coordinator.notice("status \(phase.rawValue, privacy: .public) for \(request.id.uuidString.prefix(8), privacy: .public)")
        // A recording status keeps the recording's own start, so a keyboard that reopens later
        // (and reads this as its clock) is not reset by a pause update.
        var stamp = Date()
        if phase == .recording, case .recording(let id, let startedAt) = activity, id == request.id { stamp = startedAt }
        store.status = DictationStatus(
            requestID: request.id, generation: request.generation, phase: phase, updatedAt: stamp, message: message,
            paused: phase == .recording ? showsPaused : nil)
        DarwinNotifier.post(.statusChanged)
    }

    // MARK: Capture callbacks

    private func wireCapture() {
        capture.onHeartbeat = { [weak self] _ in
            self?.publishSession()
            if self?.meetingCaptureActive == false { self?.recordingLiveActivity.heartbeat() }
            self?.consumeAudioReceiptFromLedger()
            self?.refreshStandbyStoppedNotice()
        }
        capture.onInterruption = { [weak self] interruption in
            self?.handleInterruption(interruption)
        }
        capture.onLevel = { [weak self] level in
            guard let self else { return }
            if self.meetingCaptureActive {
                self.onMeetingLevel?(level)
                return
            }
            guard case .recording = self.activity else { return }
            // Quiet first, so the level the keyboard gets carries this sample's countdown.
            self.watchForQuiet(level)
            if self.currentOrigin == .keyboard {
                self.levelChannel.send(self.isPaused ? 0 : level, finishIn: self.quietFinishIn)
            }
            self.islandMeter.append(self.isPaused ? 0 : level)
            self.appendLevel(level)
        }
    }

    private func handleInterruption(_ interruption: AudioCaptureEngine.Interruption) {
        RecordingSafetyNotice.disarm() // Zone is alive and handles this itself.
        ZoneLog.audio.info("interruption \(String(describing: interruption), privacy: .public) armed=\(self.isArmed) busy=\(self.activity.isBusy)")
        if meetingCaptureActive {
            onMeetingInterruption?(interruption)
            return
        }
        // Voice setup pauses its step; standby below still gets its own handling.
        if voiceSetupCaptureActive { onVoiceSetupInterruption?(interruption) }
        let state = micStateForInterruption
        switch interruption {
        case .began, .mediaServicesReset:
            abandonOpeningPress()
            let cause: String
            if case .began(let reason) = interruption { cause = reason } else { cause = "mediaServicesReset" }
            switch InterruptionPolicy.began(state) {
            case .hold:
                holdRecording(cause: cause)
            case .standDown:
                if capture.state == .stopped { microphoneLease = nil }
                wasArmedBeforeInterruption = true
                isArmed = false
                armedUntil = nil
                inactivityTask?.cancel()
                countdownTask?.cancel()
                // The card stays, dimmed, until the microphone comes back or standby ends. These
                // interruptions end with Zone in the background, where iOS makes no new card:
                // ending it here left standby's microphone under iOS's orange pill, 213 times in
                // nine days on Zayd's phone, for a median of nine minutes each.
                recordingLiveActivity.standbyHeld(until: Date().addingTimeInterval(InterruptionPolicy.holdLimit))
                Journal.log("standbyInterrupted", ["cause": cause, "appState": Self.appStateName()])
                // Handed back by iOS, standby resumes and pushes this back; held past the island's
                // own limit, or a microphone that failed to restart (no end will come), it fires.
                StandbyStoppedNotice.schedule(after: cause == "restartFailed"
                    ? StandbyStoppedNotice.lead : InterruptionPolicy.holdLimit + StandbyStoppedNotice.lead)
                publishSession()
                DarwinNotifier.post(.sessionChanged)
            case .nothing:
                break
            }
            if case .mediaServicesReset = interruption, isHeld {
                // The media server restarted; nothing ends it but a fresh arm.
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    await self?.resumeHeldRecording(trigger: "mediaServicesReset")
                }
            }
        case .ended(let shouldResume):
            let decision = InterruptionPolicy.ended(state, wasStandingBy: wasArmedBeforeInterruption, shouldResume: shouldResume,
                                                    appActive: UIApplication.shared.applicationState == .active)
            Journal.log("interruptionDecision", recording: currentRequest?.id,
                        ["decision": String(describing: decision), "shouldResume": String(shouldResume)])
            switch decision {
            case .resume:
                Task { await resumeHeldRecording(trigger: "interruptionEnded") }
            case .rearm:
                wasArmedBeforeInterruption = false
                Task { await rearmStandby() }
            case .waitForApp:
                holdNotice = Self.heldMessage
            case .nothing:
                if wasArmedBeforeInterruption {
                    wasArmedBeforeInterruption = false
                    // That standby is over, and its held card with it. A standby turned on again
                    // meanwhile, or a recording started meanwhile, keeps its own card.
                    if !isArmed, recordingLiveActivity.showsStandby { recordingLiveActivity.end() }
                    if !isArmed { islandSession = nil }
                    // iOS did not hand the microphone back: say so soon, unless Zone is on screen.
                    if !isArmed {
                        if UIApplication.shared.applicationState == .active { StandbyStoppedNotice.withdraw() }
                        else { StandbyStoppedNotice.schedule(after: StandbyStoppedNotice.lead) }
                    }
                }
            }
        }
    }

    /// Brings the standby back after an interruption ended.
    private func rearmStandby() async {
        let generation = sessionGeneration
        // A call or Siri in the car ended: the car's stereo audio comes back, not Zone's standby.
        if carPlayRoute(), !standbyChosenInCar {
            if recordingLiveActivity.standbyHeldSince != nil { recordingLiveActivity.end() }
            islandSession = nil
            StandbyStoppedNotice.withdraw()
            Journal.log("standbySkipped", ["reason": "carPlay", "after": "interruption"])
            return
        }
        do {
            try await armCapture() // A no-op when the meeting recorder already re-armed it.
            // End session or a new interruption while the microphone came back.
            guard generation == sessionGeneration, !isArmed else { return }
            guard capture.state != .stopped else {
                // The microphone did not come back, so neither does standby: its held card goes.
                if recordingLiveActivity.standbyHeldSince != nil { recordingLiveActivity.end() }
                islandSession = nil
                return
            }
            isArmed = true
            StandbyStoppedNotice.keepAlive(force: true)
            touchActivity()
            // Updates the held card. Without one (none was up, or the person cleared it) this asks
            // iOS for a new one even from the background, which iOS is expected to refuse; the
            // log's islandRefused says whether it ever does not.
            showStandbyIsland(canCreate: true)
            startCountdown()
            publishSession()
            DarwinNotifier.post(.sessionChanged)
            Journal.log("standbyResumed", ["appState": Self.appStateName()])
        } catch is CancellationError {
            return
        } catch {
            lastError = RecordingProblem.microphone.message(for: error)
            recordingLiveActivity.end()
            islandSession = nil
            Journal.log("standbyResumeFailed", ["error": JournalFormat.error(error), "appState": Self.appStateName()])
        }
    }

    private var micStateForInterruption: InterruptionPolicy.MicState {
        if isHeld { return .held }
        if case .recording(let id, _) = activity, currentRequest?.id == id, segmented != nil { return .recording }
        if isArmed { return .standingBy }
        return .off
    }

    /// iOS took the microphone during a recording. The recording stays: what was heard is
    /// recognized to the end and saved (History, the recovery file's text), the microphone is
    /// off, and `resumeHeldRecording` continues it. Runs under a background task, because Zone
    /// may be in the background and iOS suspends an app whose audio just stopped.
    private func holdRecording(cause: String) {
        guard case .recording(let requestID, _) = activity, let request = currentRequest, request.id == requestID,
              let session = segmented, heldSince == nil else { return }
        let held = Date()
        heldSince = held
        keepHeartbeatWhileClaimingMicrophone()
        recordingInterruptions += 1
        // If the recording is stopped during the hold, the end of the interruption still
        // brings the keyboard's standby back.
        wasArmedBeforeInterruption = true
        isArmed = false
        armedUntil = nil
        holdNotice = Self.heldMessage
        beginHoldBackgroundTask()
        Journal.log("recordingHeld", recording: requestID,
                    ["cause": cause, "audio": JournalFormat.seconds(session.audioSeconds),
                     "words": JournalFormat.words(session.textSoFar), "count": String(recordingInterruptions),
                     "appState": Self.appStateName()])
        recordingLiveActivity.paused(until: held.addingTimeInterval(InterruptionPolicy.holdLimit))
        if currentOrigin == .keyboard {
            levelChannel.send(0)
            publishStatus(.recording, for: request, message: Self.heldMessage)
        }
        publishSession()
        DarwinNotifier.post(.sessionChanged)
        holdLimitTask?.cancel()
        holdLimitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(InterruptionPolicy.holdLimit))
            guard !Task.isCancelled, let self, self.heldSince == held, self.currentRequest?.id == requestID else { return }
            await self.stopDictation(reason: "holdExpired")
        }
        let interruptions = recordingInterruptions
        let storage = audioRecoveryStore
        Task { [weak self] in
            await session.closeSegment()
            let text = session.textSoFar, seconds = session.audioSeconds
            await Self.historyAndWait {
                $0.saveProgress(id: requestID, text: text, audioSeconds: seconds, status: .paused, interruptions: interruptions)
            }
            try? await Task.detached(priority: .utility) { try storage.checkpoint(requestID, text: text) }.value
            Journal.log("recordingHoldSaved", recording: requestID,
                        ["audio": JournalFormat.seconds(seconds), "words": JournalFormat.words(text),
                         "failedSegments": String(session.summary.failedSegments)])
            self?.endHoldBackgroundTask()
        }
    }

    /// Takes the microphone back and continues the held recording. Returns false when iOS
    /// refuses (another app or a call still has it, or Zone is in the background without
    /// iOS's go-ahead); the recording stays held and resumes when Zone is opened.
    ///
    /// Several triggers can fire together (the interruption's end and the app coming forward);
    /// they share one attempt.
    @discardableResult
    func resumeHeldRecording(trigger: String) async -> Bool {
        if let resumingHeld { return await resumingHeld.value }
        let attempt = Task { await performResumeHeldRecording(trigger: trigger) }
        resumingHeld = attempt
        defer { resumingHeld = nil }
        return await attempt.value
    }

    private func performResumeHeldRecording(trigger: String) async -> Bool {
        guard let since = heldSince, case .recording(let requestID, _) = activity, let request = currentRequest,
              request.id == requestID, let session = segmented else { return false }
        let armedHere = capture.state == .stopped
        do {
            if armedHere { try await armCapture() }
        } catch {
            guard heldSince == since, currentRequest?.id == requestID else { return false }
            Journal.log("recordingResumeFailed", recording: requestID,
                        ["trigger": trigger, "error": JournalFormat.error(error), "appState": Self.appStateName()])
            holdNotice = UIApplication.shared.applicationState == .active
                ? "Zone could not get the microphone back. Something else may still be using it. Tap Resume to try again."
                : Self.heldMessage
            return false
        }
        // The recording may have been stopped, cancelled or replaced while the microphone came
        // back. Then nothing wants the microphone this attempt took.
        guard heldSince == since, case .recording(let currentID, _) = activity, currentID == requestID,
              currentRequest?.id == requestID, segmented === session else {
            if armedHere, !isArmed, !meetingCaptureActive, clipSink == nil, capture.state == .armed { disarmCapture() }
            return false
        }
        heldSince = nil
        holdNotice = nil
        holdLimitTask?.cancel()
        holdLimitTask = nil
        wasArmedBeforeInterruption = false
        isArmed = true
        capture.startRecording(pausingMusic: true)
        RecordingSafetyNotice.arm()
        Journal.log("recordingResumed", recording: requestID,
                    ["trigger": trigger, "gap": JournalFormat.seconds(Date().timeIntervalSince(since)),
                     "appState": Self.appStateName()])
        appLastActive = Date() // Give the keyboard time to reappear after the interruption.
        recordingLiveActivity.resumeRecording()
        if currentOrigin == .keyboard { publishStatus(.recording, for: request, message: nil) }
        touchActivity()
        startCountdown()
        publishSession()
        DarwinNotifier.post(.sessionChanged)
        let origin = currentOrigin
        Task { [weak self] in
            do {
                try await session.openSegment { [weak self] in
                    guard let self else { throw SpeechEngineError.notReady }
                    return try self.beginUserUtterance(recording: requestID, writer: self.audioWriter)
                }
                guard let self, self.currentRequest?.id == requestID else { return }
                let text = session.textSoFar, seconds = session.audioSeconds
                Self.history { $0.saveProgress(id: requestID, text: text, audioSeconds: seconds, status: .recording) }
            } catch {
                guard let self, self.currentRequest?.id == requestID else { return }
                self.failRecording(error, session: session, request: request, origin: origin)
            }
        }
        return true
    }

    /// Zone came to the front with a recording still held: iOS may never have reported the
    /// interruption's end (no guarantee, per Apple), or refused the resume in the background.
    private func resumeHeldRecordingOnForeground() {
        guard let since = heldSince else { return }
        let requestID = currentRequest?.id
        // A dictate URL arriving with the same foregrounding retires the held recording first.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, self.heldSince == since, self.currentRequest?.id == requestID else { return }
            switch InterruptionPolicy.foreground(heldSince: since, now: Date()) {
            case .resume: await self.resumeHeldRecording(trigger: "foreground")
            case .finish: await self.stopDictation(reason: "holdExpired")
            case .nothing: break
            }
        }
    }

    private func clearHold() {
        heldSince = nil
        holdNotice = nil
        holdLimitTask?.cancel()
        holdLimitTask = nil
    }

    private func beginHoldBackgroundTask() {
        endHoldBackgroundTask()
        holdBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "wtf.zayd.zone.hold") { [weak self] in
            Journal.log("holdBackgroundTaskExpired")
            self?.endHoldBackgroundTask()
        }
    }

    private func endHoldBackgroundTask() {
        guard holdBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(holdBackgroundTask)
        holdBackgroundTask = .invalid
    }

    /// Ends the current recording because another one is starting, keeping its words. A held
    /// recording whose words are all recognized is saved as finished; one still listening or
    /// recognizing keeps what it has as cut off, and its audio stays for a retry.
    private func retireCurrentRecording(reason: String) {
        guard let request = currentRequest, let session = utterance else {
            activity = .idle
            return
        }
        let requestID = request.id
        let settled = heldSince != nil && segmented?.isSettled == true
        let text = session.textSoFar, seconds = session.audioSeconds
        let interruptions = recordingInterruptions
        Journal.log("recordingRetired", recording: requestID,
                    ["reason": reason, "complete": String(settled), "audio": JournalFormat.seconds(seconds),
                     "words": JournalFormat.words(text)])
        utteranceLimitTask?.cancel()
        clearHold()
        capture.stopRecording()
        capture.onSamples = nil
        setPaused(false)
        RecordingSafetyNotice.disarm()
        let writer = audioRecordID == requestID ? audioWriter : nil
        if audioRecordID == requestID { audioWriter = nil; audioRecordID = nil }
        let storage = audioRecoveryStore
        let wasNote = activeNoteRequestID == requestID
        // A held note whose words are all in is written to the notes file now, before anything
        // lets its audio go. If the write fails, History keeps it as cut off (visible, unlike a
        // `.note` record) and its text stays on Home as a recovery card.
        let writesNote = wasNote && settled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if writesNote {
            lastSavedNote = notes.add(noteWords(text, original: text), recordingID: requestID)
        }
        let noteWriteFailed = writesNote && lastSavedNote == nil
        if noteWriteFailed {
            Journal.log("noteSaveFailed", recording: requestID, ["step": "retire", "reason": reason])
        }
        if settled {
            let status = NoteReceipt.historyStatus(isNote: wasNote, noteWriteFailed: noteWriteFailed)
            let noteWritten = writesNote && !noteWriteFailed
            let statsStart = recordingStartedAt ?? request.createdAt
            let keptText = writesNote ? lastSavedNote?.text : nil
            Task {
                let durable = await Self.commitHistory {
                    $0.finish(id: requestID, text: text, audioSeconds: seconds, status: status, source: wasNote ? .note : nil,
                              interruptions: interruptions > 0 ? interruptions : nil, statsStartedAt: statsStart)
                }
                if let keptText { confirmKept(requestID, text: keptText) }
                try? await writer?.finish()
                try? await Task.detached(priority: .utility) {
                    try storage.complete(requestID, text: text, discardShortEmpty: true,
                                         shortUnder: wasNote ? AudioRecoveryStore.minimumNoteSeconds : AudioRecoveryStore.minimumRetainedSeconds)
                    if NoteReceipt.mayRelease(historyDurable: durable, isNote: wasNote, noteWritten: noteWritten) {
                        try storage.consumeTextReceipt(requestID, matching: text)
                    }
                }.value
                await self.refreshAudioRecovery()
            }
        } else {
            session.cancel()
            Self.history { $0.finish(id: requestID, text: text, audioSeconds: seconds, status: .cutOff) }
            Task {
                try? await writer?.finish()
                try? await Task.detached(priority: .utility) {
                    try storage.markFailed(requestID, text: text,
                                           message: "A new dictation started before this one finished. Transcribe the saved audio to get every word.", outcome: .interrupted)
                }.value
                await self.refreshAudioRecovery()
            }
        }
        activeNoteRequestID = nil
        utterance = nil
        segmented = nil
        currentRequest = nil
        liveTranscript = ""
        activity = .idle
    }

    // MARK: Diagnostics

    struct ClipOutcome {
        let text: String
        let processingSeconds: TimeInterval
    }

    /// Feeds the bundled clip through the exact utterance path and measures total processing time.
    func transcribeTestClip() async throws -> ClipOutcome {
        do { return try await runTestClip() }
        catch { throw ShortcutFailure(message: RecordingProblem.testClip.message(for: error)) }
    }

    private func runTestClip() async throws -> ClipOutcome {
        guard beginModelDiagnostics() else { throw SpeechEngineError.notReady }
        defer { endModelDiagnostics() }
        guard modelIsReady else { throw SpeechEngineError.notReady }
        let samples = try TestClip.samples()
        let session = try engine.beginUtterance()
        defer { session.cancel() }
        let started = Date()
        let chunk = 8_000
        var index = 0
        while index < samples.count {
            let end = min(index + chunk, samples.count)
            while session.availableAudioSamples < end - index {
                if let failure = session.failure { throw failure }
                try await Task.sleep(for: .milliseconds(5))
            }
            if let failure = session.failure { throw failure }
            session.feed(Array(samples[index..<end]))
            index = end
        }
        let text = try await session.finish()
        return ClipOutcome(text: text, processingSeconds: Date().timeIntervalSince(started))
    }

    /// Swaps the resident engine, unloading the old one first so two models are never in memory
    /// together, then loads the new one. `persist` makes it the person's choice for the next
    /// launch; the bakeoff passes false, because it loads every engine in turn and a run that ends
    /// early (a crash, a reinstall) used to leave whichever engine it was measuring as the
    /// person's model (Parakeet on Zayd's phone, 2026-11-04, though Settings never offered it).
    func switchEngine(to kind: EngineKind, persist: Bool = true) async {
        guard kind != engine.kind, !isDeletingModels, !isSwitchingEngine else { return }
        isSwitchingEngine = true
        defer { isSwitchingEngine = false }
        if retryingAudioID != nil {
            cancelAudioRetry()
            await audioRetryTask?.value
        }
        // A download offline can wait for hours; switching away cancels it (resume data is kept).
        if case .downloading = modelState { preparationLoad?.cancel() }
        await preparationTask?.value
        guard preparationLoad == nil else {
            libraryError = "The speech model is still closing. Reopen Zone to switch models."
            return
        }
        switch activity {
        case .recording, .transcribing: cancelDictation(playsSound: false)
        default: break
        }
        await engine.unloadAndWait()
        engine = kind == kind.model.productEngine ? modelEngineFactory(kind.model) : kind.makeEngine()
        if persist { EngineKind.selected = kind }
        modelState = engine.assetsPresent() ? .loading : .missing
        publishSession()
        prepareModel()
        await preparationTask?.value
    }

    /// Loads the current engine (downloading if needed) and returns when it is ready or failed.
    func prepareModelAndWait() async {
        // A task started before an unload can finish without a loaded engine; one more pass
        // then loads it for real.
        for _ in 0..<2 where !(modelIsReady && engine.isReady) {
            await preparationTask?.value
            prepareModel()
            await preparationTask?.value
        }
    }

    var engineBytesOnDisk: Int64 { engine.bytesOnDisk() }

    // MARK: Model library

    /// Download progress for models being fetched from the library, 0...1.
    private(set) var libraryDownloads: [SpeechModel: Double] = [:]
    @ObservationIgnored private var libraryDownloadTasks: [SpeechModel: Task<Void, Error>] = [:]
    private(set) var libraryError: String?
    private(set) var libraryNotice: String?
    func clearLibraryError() { libraryError = nil }
    private(set) var isDeletingModels = false
    /// The retired models this launch found on disk and is deleting; empty when launch deletes nothing.
    private(set) var launchCleanup: [SpeechModel] = []
    @ObservationIgnored private let modelEngineFactory: (SpeechModel) -> SpeechEngine
    /// Bumped after a download or delete so library rows re-read disk state.
    private(set) var libraryRevision = 0

    var selectedModel: SpeechModel { engine.kind.model }

    func modelIsDownloaded(_ model: SpeechModel) -> Bool {
        (model == selectedModel ? engine : modelEngineFactory(model)).assetsPresent()
    }

    func modelBytesOnDisk(_ model: SpeechModel) -> Int64 {
        (model == selectedModel ? engine : modelEngineFactory(model)).bytesOnDisk()
    }

    /// Fetches a model's files without loading it, so browsing the library never costs memory.
    func downloadModel(_ model: SpeechModel) async {
        if model == selectedModel, let modelExitNotice { libraryError = modelExitNotice; return }
        guard libraryDownloads[model] == nil, !isDeletingModels, !model.isRetired,
              !(isPreparingModel && model == selectedModel) else { return }
        libraryError = nil
        libraryNotice = nil
        libraryDownloads[model] = 0
        let progressGate = ModelProgressGate()
        let engine = modelEngineFactory(model)
        let download = Task.detached(priority: .userInitiated) {
            try await engine.downloadAssets { fraction, file in
                guard progressGate.accept(fraction, file: file) else { return }
                Task { @MainActor [weak self] in
                    guard self?.libraryDownloads[model] != nil else { return }
                    self?.libraryDownloads[model] = fraction
                }
            }
        }
        libraryDownloadTasks[model] = download
        do {
            try await download.value
        } catch is CancellationError {
            // The person cancelled; nothing to report.
        } catch {
            libraryError = "The download stopped. Check your connection and tap Download again."
        }
        libraryDownloadTasks[model] = nil
        libraryDownloads[model] = nil
        libraryRevision += 1
        // The model in use (or a waiting keyboard request) loads as soon as its files are here,
        // instead of staying "missing" until Zone next comes to the foreground.
        if model == selectedModel, !modelIsReady, engine.assetsPresent() {
            prepareModel()
        }
    }

    /// Stops a download from the library, or the model in use fetching its files. Finished
    /// files and resume data stay, so the next attempt continues where this one stopped.
    func cancelModelDownload(_ model: SpeechModel) {
        libraryDownloadTasks[model]?.cancel()
        if model == selectedModel, case .downloading = modelState { preparationLoad?.cancel() }
    }

    /// Standing by is not a blocker: the confirmation turns it off in the same action.
    /// Recording, processing and downloads are never silently cancelled to free storage.
    var modelDeletionBlocker: String? {
        if case .keyboardRecording = KeyboardRecordingClaim.verdict(store.keyboardRecordingClaim, now: Date()) {
            return "Finish the keyboard recording before deleting models."
        }
        if isDeletingModels { return "Removing model files…" }
        if diagnosticOperations > 0 { return "Finish or cancel the model test before deleting models." }
        if activity.isBusy || startingNote || openingPress != nil || clipSink != nil { return "Finish the current recording or transcription before deleting models." }
        if meetingCaptureActive || MeetingCoordinator.current?.isRecording == true || MeetingCoordinator.current?.isStartingRecording == true || MeetingCoordinator.current?.isFinishingRecording == true {
            return "Finish the meeting recording before deleting models."
        }
        if MeetingCoordinator.current?.transcribingID != nil { return "Finish or cancel the meeting transcription before deleting models." }
        if retryingAudioID != nil { return "Finish or cancel the audio retry before deleting models." }
        if let modelExitNotice { return modelExitNotice }
        if isPreparingModel || isSwitchingEngine || armingSessions > 0 { return "Wait for the speech model to finish getting ready before deleting models." }
        if !libraryDownloads.isEmpty { return "Wait for model downloads to finish before deleting models." }
        return nil
    }

    /// Switching unloads the engine: it would discard a dictation in progress and fail a
    /// meeting mid-transcription. The bake-off switches itself and is debug-only.
    var modelSwitchBlocker: String? {
        if activity.isBusy || startingNote || openingPress != nil || clipSink != nil { return "Finish the current recording or transcription before switching models." }
        if meetingCaptureActive || MeetingCoordinator.current?.isRecording == true || MeetingCoordinator.current?.isStartingRecording == true || MeetingCoordinator.current?.isFinishingRecording == true {
            return "Finish the meeting recording before switching models."
        }
        if MeetingCoordinator.current?.transcribingID != nil { return "Finish or cancel the meeting transcription before switching models." }
        return nil
    }

    var downloadedSpeechModels: [SpeechModel] {
        SpeechModel.allCases.filter { $0.needsDownload && modelBytesOnDisk($0) > 0 }
    }

    func deleteModel(_ model: SpeechModel) async { await deleteModels([model]) }

    func deleteModels(_ models: [SpeechModel]) async {
        guard !isDeletingModels else { return }
        guard let blocker = modelDeletionBlocker else {
            isDeletingModels = true // reserve before the first suspension
            endSession(reason: .user)
            pendingColdRequestID = nil
            await performModelDeletion(models, automatic: false)
            return
        }
        libraryError = blocker
    }

    private func performModelDeletion(_ requested: [SpeechModel], automatic: Bool) async {
        defer { isDeletingModels = false; libraryRevision += 1 }
        libraryError = nil
        libraryNotice = nil
        let models = Array(Set(requested.filter(\.needsDownload))).sorted { $0.rawValue < $1.rawValue }
        if automatic {
            // The launch sweep nearly always finds nothing. Measuring walks the compiled-model
            // cache and reads every descriptor in it, so look off the main thread first and stop
            // when there is nothing to remove: on the main actor that walk sat in front of the
            // first frame and of the dictate URL on every launch.
            let engines = models.map { $0 == selectedModel ? engine : modelEngineFactory($0) }
            let found = await Task.detached(priority: .utility) {
                engines.reduce(Int64(0)) { $0 + $1.bytesOnDisk() }
            }.value
            if found == 0 {
                Journal.log("modelStorageCleanup", ["automatic": "true", "models": models.map(\.rawValue).joined(separator: ","),
                                                   "freedBytes": "0", "failures": "0"])
                return
            }
        }
        let before = models.reduce(Int64(0)) { $0 + modelBytesOnDisk($1) }
        var directories = models.compactMap(\.assetDirectory)
        if models.contains(.fluidSpeechMini) {
            await ParakeetEngine.Model.initialMigration.value
            directories.append(contentsOf: [ParakeetEngine.Model.privateMini, SharedMiniModel.directory].compactMap { $0 })
            SharedMiniModel.publish(false)
            await WorkerCacheClient.clear()
        }
        await ModelDownloader.shared.preventWritesAndCancel(in: directories)
        if models.contains(selectedModel) {
            await engine.unloadAndWait()
            modelState = .missing
            publishSession()
        }
        var errors: [String] = []
        for model in models {
            let target = model == selectedModel ? engine : modelEngineFactory(model)
            do {
                try target.removeAssets()
                if target.bytesOnDisk() > 0 { throw SpeechEngineError.unavailable("Some model files remain. Try removing them again.") }
            } catch { errors.append("\(model.shortName): \(RecordingProblem.removeModel.message(for: error))") }
        }
        if models.contains(selectedModel) {
            modelState = engine.assetsPresent() ? .loading : .missing
            publishSession()
        }
        let remaining = models.reduce(Int64(0)) { $0 + modelBytesOnDisk($1) }
        let freed = max(0, before - remaining)
        if !errors.isEmpty { libraryError = "Some speech model files are still here. Open storage and try removing them again." }
        if !automatic || before > 0 {
            libraryNotice = "\(freed.byteCountLabel) freed. Your recordings and transcripts are kept."
        }
        Journal.log("modelStorageCleanup", ["automatic": String(automatic), "models": models.map(\.rawValue).joined(separator: ","),
                                           "freedBytes": String(freed), "failures": String(errors.count)])
    }

    /// Storage > "Clear" on the keyboard helper's line. Deletes everything the helper prepared
    /// (the helper does the deleting: its folder is out of the app's reach) and says how much.
    func clearKeyboardHelperFiles() async {
        let before = WorkerStorage.bytes
        await WorkerCacheClient.clear()
        let freed = max(0, before - WorkerStorage.bytes)
        libraryNotice = WorkerStorage.bytes == 0
            ? "\(freed.byteCountLabel) freed from the keyboard helper."
            : "Zone could not reach the keyboard helper. Try again."
        Journal.log("helperCacheCleared", ["by": "person", "freedBytes": String(freed), "bytesLeft": String(WorkerStorage.bytes)])
        libraryRevision += 1
    }

    /// Makes `model` the one the warm path uses, loading it now.
    func selectModel(_ model: SpeechModel) async {
        guard !isDeletingModels, !model.isRetired else { return }
        if let blocker = modelSwitchBlocker {
            libraryError = blocker
            return
        }
        await switchEngine(to: model.productEngine)
        libraryRevision += 1
    }

    /// A bare utterance for the bakeoff: no context hints, so every engine hears the same thing.
    /// The recognizer's text so far for the dictation in progress (long-dictation probe).
    var liveTextSoFar: String { utterance?.textSoFar ?? "" }

    func makeBenchmarkUtterance() throws -> UtteranceSession {
        guard modelIsReady, !isDeletingModels else { throw SpeechEngineError.notReady }
        engine.setPersonalWords([])
        engine.setContextHints("")
        return try engine.beginUtterance()
    }

    /// What a clip recording is for, which decides what a refused dictation or meeting says.
    enum ClipPurpose {
        case test, voiceSetup
        var refusal: String {
            switch self {
            case .test: return RecordingRefusal.clip
            case .voiceSetup: return RecordingRefusal.voiceSetup
            }
        }
    }

    /// Why voice setup cannot start now, or nil when it can.
    var voiceSetupRefusal: String? {
        if meetingCaptureActive || MeetingCoordinator.current?.isRecording == true { return "Stop the meeting to set up your voice." }
        if activity.isBusy || startingNote || openingPress != nil { return "Finish the dictation first." }
        return nil
    }

    /// True while voice setup holds the microphone.
    var voiceSetupCaptureActive: Bool { clipSink != nil && clipPurpose == .voiceSetup }

    /// Records a clip through the production capture path (same tap, same 16 kHz conversion):
    /// a bakeoff clip, or voice setup, which also wants each chunk as it arrives (`live`, called
    /// on the audio thread). Arms the microphone if no session is running and releases it
    /// afterwards. Dictations, notes and meetings refuse to start meanwhile.
    func startClipCapture(purpose: ClipPurpose = .test, live: (@Sendable ([Float]) -> Void)? = nil) async throws {
        try checkClipCaptureAllowed()
        guard clipSink == nil else { return }
        if capture.state == .stopped {
            try await armCapture()
            // Whatever started meanwhile (another tap, a dictation, a meeting) keeps the microphone.
            do { try checkClipCaptureAllowed() } catch {
                if !isArmed, !meetingCaptureActive, clipSink == nil, capture.state == .armed { disarmCapture() }
                throw error
            }
            guard clipSink == nil else { return }
            clipArmedCapture = true
        }
        let sink = ClipSink()
        clipSink = sink
        clipPurpose = purpose
        publishSession()
        keepHeartbeatWhileClaimingMicrophone()
        capture.onSamples = { chunk in
            sink.append(chunk)
            live?(chunk)
        }
        capture.startRecording()
    }

    private func checkClipCaptureAllowed() throws {
        if let refusal = keyboardRecordingRefusal(KeyboardRecordingClaim.appRefusal, from: "clip") { throw SpeechEngineError.unavailable(refusal) }
        guard !isDeletingModels else { throw SpeechEngineError.unavailable("Model storage is being cleaned.") }
        guard !meetingCaptureActive else { throw SpeechEngineError.unavailable(Self.meetingRefusal) }
        if MeetingCoordinator.current?.isStartingRecording == true || MeetingCoordinator.current?.isFinishingRecording == true {
            throw SpeechEngineError.unavailable("A meeting recording is starting or saving. Try again in a moment.")
        }
        if startingNote { throw SpeechEngineError.unavailable("A note is starting.") }
        switch activity {
        case .recording, .transcribing: throw SpeechEngineError.unavailable("A dictation is running.")
        default: break
        }
    }

    /// Voice setup's "go" cue after the far part's countdown, when the phone is out of reach.
    /// Played before the microphone opens, so the meter does not count it as speech.
    func playVoiceSetupStartCue() async {
        sounds.playStart()
        try? await Task.sleep(for: .milliseconds(350))
    }

    /// Voice setup's "that's enough" cue, played while its microphone is still open so a
    /// released audio session cannot cut it short.
    func playVoiceSetupCue() async {
        sounds.playStop()
        await sounds.finishStopCue()
    }

    func stopClipCapture() -> [Float] {
        guard let sink = clipSink else { return [] }
        capture.stopRecording()
        capture.onSamples = nil
        clipSink = nil
        publishSession()
        if clipArmedCapture, !isArmed {
            disarmCapture()
        }
        clipArmedCapture = false
        return sink.take()
    }

    // MARK: Meetings

    /// Why a meeting cannot start right now, or nil when it can.
    var meetingStartRefusal: String? {
        if let refusal = keyboardRecordingRefusal(KeyboardRecordingClaim.appRefusal, from: "meeting") { return refusal }
        if isDeletingModels { return "Wait for Zone to finish removing unused models before starting a meeting." }
        if activity.isBusy || startingNote || openingPress != nil { return "Finish the dictation first, then start the meeting." }
        if retryingAudioID != nil { return "Finish or cancel the audio retry first." }
        if let clipRefusal { return clipRefusal }
        return nil
    }

    /// Gives the microphone to a meeting: the same capture path, tap and 16 kHz conversion
    /// that dictation uses. Arms the microphone if dictation is off (foreground only, like any
    /// arm) and keeps it until `stopMeetingCapture`.
    func startMeetingCapture(sink: @escaping ([Float]) -> Void) async throws {
        if let refusal = meetingStartRefusal { throw SpeechEngineError.unavailable(refusal) }
        if capture.state == .stopped {
            try await armCapture()
            // A dictation or a test clip may have started while the microphone armed.
            if let refusal = meetingStartRefusal {
                if !isArmed, !meetingCaptureActive, clipSink == nil, capture.state == .armed { disarmCapture() }
                throw SpeechEngineError.unavailable(refusal)
            }
            meetingArmedCapture = !isArmed
        }
        recordingLiveActivity.end()
        meetingCaptureActive = true
        publishSession()
        keepHeartbeatWhileClaimingMicrophone()
        capture.onSamples = sink
        capture.startRecording()
        closeNotePage(reason: "meeting")
        clearNoteOutcome()
    }

    /// Re-arms after an interruption ended. Fails from the background, where iOS refuses to
    /// activate a recording session; the meeting then waits for the person to return.
    func resumeMeetingCapture(sink: @escaping ([Float]) -> Void) async throws {
        guard meetingCaptureActive else { return }
        if capture.state == .stopped {
            try await armCapture()
            // The meeting may have stopped while the microphone came back.
            guard meetingCaptureActive else {
                if !isArmed, clipSink == nil, capture.state == .armed { disarmCapture() }
                throw CancellationError()
            }
            if !isArmed { meetingArmedCapture = true }
        }
        capture.onSamples = sink
        capture.startRecording()
    }

    func stopMeetingCapture() {
        guard meetingCaptureActive else { return }
        capture.stopRecording()
        capture.onSamples = nil
        meetingCaptureActive = false
        publishSession()
        if shortcutAudioPolicyPending {
            shortcutAudioPolicyPending = false
            sounds.stopPlayback()
            endSession(reason: .shortcutFinished)
        }
        if isArmed, capture.state == .stopped {
            // The interrupted meeting ended before it could restore standby's microphone.
            endSession(reason: .interruption)
        } else if meetingArmedCapture, !isArmed {
            disarmCapture()
        }
        meetingArmedCapture = false
        // Standby outlived the meeting: it takes the island back from the meeting's card. From
        // the meeting card's Stop (an intent) iOS may allow the new card; otherwise the next
        // time Zone is in front makes it.
        if isArmed { showStandbyIsland(canCreate: true) }
    }

    /// True when the resident speech engine is free for a meeting chunk: nothing is being
    /// dictated, retried or loaded. Dictation always wins; meeting transcription waits.
    var engineIsFreeForMeetings: Bool {
        modelIsReady && !isDeletingModels && !isSwitchingEngine && !activity.isBusy && !startingNote && retryingAudioID == nil && preparationTask == nil
    }

    /// One utterance on the resident engine for a stretch of meeting audio. Same model as
    /// dictation, so a meeting never loads a second recognizer into memory.
    func makeMeetingUtterance() throws -> UtteranceSession {
        guard engineIsFreeForMeetings else { throw SpeechEngineError.notReady }
        refreshSpeechVocabulary()
        engine.setContextHints("")
        return try beginUserUtterance(mentions: false)
    }

    func sharedStateSummary() -> String {
        var lines: [String] = []
        lines.append("appGroup: \(ZoneContract.appGroup) reachable=\(AppGroup.isReachable)")
        lines.append("session: \(store.session.map { "armed=\($0.isArmed) modelReady=\($0.modelReady) heartbeat=\($0.heartbeat.formatted(date: .omitted, time: .standard))" } ?? "nil")")
        lines.append("presence: \(store.keyboardPresence.map { "fullAccess=\($0.hasFullAccess) seen=\($0.lastSeen.formatted(date: .omitted, time: .standard))" } ?? "nil")")
        lines.append("request: \(store.request.map { "\($0.id.uuidString.prefix(8)) gen=\($0.generation) session=\($0.inputSession ?? "nil")" } ?? "nil")")
        lines.append("status: \(store.status.map { "\($0.requestID.uuidString.prefix(8)) \($0.phase.rawValue) \($0.message ?? "")" } ?? "nil")")
        lines.append("result: \(store.result.map { "\($0.requestID.uuidString.prefix(8)) gen=\($0.generation) \"\($0.text.prefix(40))\"" } ?? "nil")")
        lines.append("control: \(store.control.map { "\($0.requestID.uuidString.prefix(8)) \($0.action.rawValue)" } ?? "nil")")
        let ledger = store.ledger
        lines.append("ledger: claimed=\(ledger.claimedResultID?.uuidString.prefix(8) ?? "nil") consumed=\(ledger.consumedResultID?.uuidString.prefix(8) ?? "nil") dropped=\(ledger.droppedGeneration)")
        return lines.joined(separator: "\n")
    }

    func clearSharedDictationRecords() {
        store.resetHandoff(at: Date())
    }

    static func appStateName() -> String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    private var activityName: String {
        switch activity {
        case .idle: return "idle"
        case .recording: return "recording"
        case .transcribing: return "transcribing"
        case .finished: return "finished"
        case .failed: return "failed"
        }
    }

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard settings.hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}


extension DictationCoordinator {
    func refreshAudioRecovery() async {
        audioRefreshGeneration += 1
        let generation = audioRefreshGeneration
        let storage = audioRecoveryStore
        let active = Set([audioRecordID, retryingAudioID].compactMap { $0 })
        do {
            let (records, importFailed) = try await Task.detached(priority: .utility) {
                var importFailed = false
                if let inbox = KeyboardAudioFile.inbox {
                    do { try storage.importKeyboardAudio(from: inbox) }
                    catch { importFailed = true }
                }
                if let history = TranscriptHistory.shared {
                    try storage.reconcileKeyboardHandoffs(with: history)
                }
                try storage.expire(activeIDs: active)
                return (try storage.records().filter { $0.state != .recording }, importFailed)
            }.value
            guard generation == audioRefreshGeneration else { return }
            let known = Dictionary(uniqueKeysWithValues: audioRecoveryRecords.compactMap { record in
                record.levels.map { (record.id, $0) }
            })
            audioRecoveryRecords = records.map { record in
                var current = record
                if current.levels == nil { current.levels = known[record.id] }
                return current
            }
            if appIsActive, !meetingCaptureActive, !startingNote, pendingColdRequestID == nil,
               let queued = records.last(where: { $0.keyboardHandoff == true && $0.state == .available }) {
                retryAudioRecovery(queued)
            }
            if importFailed { audioRecoveryWarning = "A keyboard recording could not be read. Its audio file was kept." }
        } catch {
            guard generation == audioRefreshGeneration else { return }
            audioRecoveryWarning = "Temporary recordings could not be refreshed. Existing files were kept."
        }
    }

    func shareableAudio(_ id: UUID) async throws -> URL {
        let storage = audioRecoveryStore
        return try await Task.detached(priority: .utility) { try storage.exportWave(id) }.value
    }

    func measureSavedAudio(_ record: AudioRecoveryRecord) async {
        guard [.failed, .noWords, .available].contains(record.state), record.audioBytes >= 2, record.levels == nil,
              measuringAudio.insert(record.id).inserted else { return }
        defer { measuringAudio.remove(record.id) }
        let storage = audioRecoveryStore
        do {
            let levels = try await Task.detached(priority: .utility) { try storage.fillLevels(record.id) }.value
            if let levels, let index = audioRecoveryRecords.firstIndex(where: { $0.id == record.id }) {
                audioRecoveryRecords[index].levels = levels
            }
        } catch {
            // A retry or deletion may have removed the PCM while its row was visible.
        }
    }

    private func consumeAudioReceiptFromLedger() {
        guard let id = store.ledger.consumedResultID, id != consumedAudioReceiptID else { return }
        consumedAudioReceiptID = id
        useRecoveredText(id)
    }

    func useRecoveredText(_ id: UUID) {
        let storage = audioRecoveryStore
        Task {
            do { try await Task.detached(priority: .utility) { try storage.consumeTextReceipt(id) }.value }
            catch {
                if consumedAudioReceiptID == id { consumedAudioReceiptID = nil }
                audioRecoveryWarning = "The temporary text could not be cleared. You can delete it from recovery."
            }
            await refreshAudioRecovery()
        }
    }

    func eraseAudioRecovery() -> Bool {
        guard audioRecordID == nil, retryingAudioID == nil else { return false }
        audioRefreshGeneration += 1
        do {
            try audioRecoveryStore.eraseRecordings()
            audioRecoveryRecords = try audioRecoveryStore.records()
            audioRecoveryWarning = nil
            return audioRecoveryRecords.isEmpty
        } catch {
            if let remaining = try? audioRecoveryStore.records() { audioRecoveryRecords = remaining }
            audioRecoveryWarning = "Some saved recordings could not be deleted."
            return false
        }
    }

    func deleteAudioRecovery(_ id: UUID) {
        guard id != audioRecordID, id != retryingAudioID else { return }
        let storage = audioRecoveryStore
        // A banner about this recording would otherwise outlive the card it described.
        if let message = audioRecoveryRecords.first(where: { $0.id == id })?.message {
            if audioRecoveryWarning == message { audioRecoveryWarning = nil }
            if case .failed(let failure) = activity, failure == message { activity = .idle }
        }
        Task {
            do { try await Task.detached(priority: .utility) { try storage.discard(id) }.value }
            catch { audioRecoveryWarning = "The temporary recording could not be deleted. Please try again." }
            await refreshAudioRecovery()
        }
    }

    private func discardActiveAudio(_ id: UUID) {
        let writer = audioRecordID == id ? audioWriter : nil
        if audioRecordID == id { audioWriter = nil; audioRecordID = nil }
        let storage = audioRecoveryStore
        Task {
            try? await writer?.finish()
            do { try await Task.detached(priority: .utility) { try storage.discard(id) }.value }
            catch { audioRecoveryWarning = "The cancelled temporary recording could not be deleted. Please retry from recovery." }
            await refreshAudioRecovery()
        }
    }

    @discardableResult
    private func retainAudioFailure(_ id: UUID, text: String, message: String) -> Task<Bool, Never>? {
        guard audioRecordID == id else { return nil }
        let writer = audioWriter
        audioWriter = nil; audioRecordID = nil
        let storage = audioRecoveryStore
        return Task {
            var sealed = false
            if let writer { do { try await writer.finish(); sealed = true } catch {} }
            let confirmed: Bool
            do {
                confirmed = try await Task.detached(priority: .utility) {
                    try storage.markFailed(id, text: text, message: message)
                    return storage.hasRetainedAudio(id)
                }.value
            } catch {
                audioRecoveryWarning = RecordingProblem.storage.message(for: error)
                confirmed = false
            }
            await refreshAudioRecovery()
            return sealed && confirmed
        }
    }

    private func finalizeAudio(_ id: UUID, text: String, isNote: Bool, historyDurable: Bool) async {
        guard audioRecordID == id else { return }
        let storage = audioRecoveryStore
        let shortUnder = isNote ? AudioRecoveryStore.minimumNoteSeconds : AudioRecoveryStore.minimumRetainedSeconds
        do {
            try await Task.detached(priority: .utility) {
                try storage.complete(id, text: text, discardShortEmpty: true, shortUnder: shortUnder)
                if historyDurable { try storage.consumeTextReceipt(id, matching: text) }
            }.value
        } catch AudioRecoveryError.emptyTranscript {
            // The recovery card already says so; a second banner with the same words is noise.
        } catch { audioRecoveryWarning = RecordingProblem.storage.message(for: error) }
        if audioRecordID == id { audioWriter = nil; audioRecordID = nil }
        await refreshAudioRecovery()
    }

    func retryAudioRecovery(_ record: AudioRecoveryRecord) {
        let needsMini = record.keyboardHandoff == true && engine.kind.model != .fluidSpeechMini
        guard !activity.isBusy, retryingAudioID == nil, modelIsReady || needsMini, !isDeletingModels else { return }
        retryingAudioID = record.id
        activity = .transcribing(requestID: record.id)
        audioRetryTask = Task {
            let storage = audioRecoveryStore
            var retrySession: UtteranceSession?
            do {
                let saved = try await Task.detached(priority: .utility) { try storage.prepareRetry(record.id) }.value
                try Task.checkCancellation()
                let speech = needsMini ? modelEngineFactory(.fluidSpeechMini) : engine
                defer { if needsMini { speech.unload() } }
                if needsMini {
                    guard speech.assetsPresent() else {
                        throw SpeechEngineError.unavailable("Download Fluid Speech Mini in Zone to finish your saved recording.")
                    }
                    try await ModelDownloader.$allowsNewTransfers.withValue(false) {
                        try await speech.prepare { _, _ in }
                    }
                    try Task.checkCancellation()
                }
                speech.setPersonalWords(settings.speechHintWords())
                speech.setContextHints("")
                let receipt = AudioModelSubmission { _ = try storage.beginRetry(saved.id) }
                let session = try beginUserUtterance(recording: saved.id, using: speech, retrySubmission: receipt)
                retrySession = session
                utterance = session
                let request = DictationRequest(id: saved.id, generation: 0, createdAt: saved.createdAt,
                                               inputSession: "audio-recovery", contextBefore: nil)
                currentRequest = request
                currentOrigin = .app
                activity = .transcribing(requestID: saved.id)
                let reader = try AudioRecoveryReader(url: storage.audioURL(saved.id))
                let feedProgress = Watchdog.Pulse()
                while true {
                    try Task.checkCancellation()
                    if let failure = session.failure { throw failure }
                    if session.availableAudioSamples < 4_096 {
                        if feedProgress.idle >= 60 { throw Watchdog.Stalled(what: "The speech model", seconds: 60) }
                        try await Task.sleep(for: .milliseconds(20))
                        continue
                    }
                    let samples = try await Task.detached(priority: .utility) { try reader.read() }.value
                    if samples.isEmpty { break }
                    try Task.checkCancellation()
                    session.feed(samples)
                    feedProgress.beat()
                    liveTranscript = session.textSoFar
                }
                let text = try await Watchdog.run(what: "The speech model", limit: recognitionLimit(audioSeconds: session.audioSeconds)) {
                    try await session.finish()
                }
                try Task.checkCancellation()
                let seconds = session.audioSeconds, engineName = speech.kind.rawValue
                let durable = await Self.commitHistory {
                    // Dated now, so it is the newest item, and marked with when it was recorded.
                    $0.finish(id: saved.id, text: text, audioSeconds: seconds,
                              status: saved.source == .note ? .note : .finished, engine: engineName, source: saved.source,
                              recoveredFrom: saved.createdAt, statsStartedAt: saved.createdAt)
                }
                try Task.checkCancellation()
                // Keep original PCM on cancellation/failure until final text has its receipt.
                // A short, atomic commit after the final cancellation check. No suspension
                // between commit and publishing success can turn a cancelled retry into deletion.
                var noteSaved = false
                if saved.source == .note {
                    lastSavedNote = notes.add(noteWords(text, original: text), recordingID: saved.id, createdAt: saved.createdAt)
                    noteSaved = lastSavedNote != nil
                    if let lastSavedNote { confirmKept(saved.id, text: lastSavedNote.text) }
                }
                // A note's receipt goes only once the notes file holds it (`NoteReceipt`): Home hides
                // a `.note` History record, so that record alone would leave the words nowhere in sight.
                if NoteReceipt.mayRelease(historyDurable: durable, isNote: saved.source == .note, noteWritten: noteSaved) {
                    try storage.complete(saved.id, text: text)
                    try storage.consumeTextReceipt(saved.id, matching: text)
                } else {
                    try storage.markFailed(saved.id, text: text, message: "The recording is kept. Try saving it again.")
                }
                let result = DictationResult(requestID: saved.id, generation: 0, text: text, audioSeconds: seconds,
                                             createdAt: Date(), inputSession: "audio-recovery")
                if saved.keyboardHandoff == true {
                    // A different field must explicitly accept recovered words. A newer tap wins.
                    let request = DictationRequest(id: saved.id, generation: 0, createdAt: saved.createdAt,
                                                   inputSession: "audio-recovery", contextBefore: nil)
                    if KeyboardCapture.mayPublish(local: request, storedRequest: store.request, storedResult: store.result) {
                        let generation = KeyboardCapture.publishedGeneration(of: request, ledger: store.ledger)
                        let offer = DictationResult(requestID: saved.id, generation: generation, text: text,
                                                    audioSeconds: seconds, createdAt: Date(), inputSession: "audio-recovery")
                        let original = DictationRequest(id: saved.id, generation: generation, createdAt: saved.createdAt,
                                                        inputSession: "audio-recovery", contextBefore: nil)
                        if store.publishFinal(offer, for: original) { DarwinNotifier.post(.resultReady) }
                    }
                    Journal.log("keyboardHandoffFinished", recording: saved.id, ["module": engineName])
                }
                lastResult = result
                lastResultWasNote = saved.source == .note
                lastResultWasAudioRetry = true
                liveTranscript = text
                if saved.source == .note && !noteSaved {
                    let message = storage.hasRetainedAudio(saved.id)
                        ? "Zone could not save the note. Open Home to try the saved audio again."
                        : "Zone could not save the note. Check Home and free up space before trying again."
                    audioRecoveryWarning = message
                    activity = .failed(message)
                } else {
                    activity = .finished(result, origin: .app)
                }
            } catch AudioRecoveryError.emptyTranscript {
                retrySession?.cancel()
                if retryingAudioID == record.id { activity = .idle }
            } catch {
                retrySession?.cancel()
                let partial = retrySession?.textSoFar ?? record.text
                let message = Task.isCancelled ? "Retry cancelled. Check Home to try again." : RecordingProblem.transcribe.message(for: error)
                let noWords = (error as? AudioRecoveryError) == .emptyTranscript
                let outcome: AudioAttempts.Outcome = Task.isCancelled ? .interrupted : (noWords ? .noWords : .modelFailed)
                try? await Task.detached(priority: .utility) { try storage.markFailed(record.id, text: partial, message: message, outcome: outcome) }.value
                if retryingAudioID == record.id { activity = Task.isCancelled || noWords ? .idle : .failed(message) }
                if !Task.isCancelled && !noWords { audioRecoveryWarning = message }
            }
            if currentRequest?.id == record.id { currentRequest = nil; utterance = nil }
            retryingAudioID = nil
            audioRetryTask = nil
            await refreshAudioRecovery()
        }
    }


    func cancelAudioRetry() {
        audioRetryTask?.cancel()
        if currentRequest?.id == retryingAudioID { utterance?.cancel() }
    }
}

/// Collects samples from the audio thread for a bakeoff clip.
final class ClipSink: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    func append(_ chunk: [Float]) {
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()
    }

    func take() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let taken = samples
        samples = []
        return taken
    }
}


/// Holds exactly one press from microphone admission through model attachment.
private final class PressRecording: @unchecked Sendable {
    let id: UUID
    let writer: AudioRecoveryWriter
    let bridge: ProgressiveAudioBridge
    let session: SegmentedRecognition
    let pressedAt: TimeInterval
    private let lock = NSLock()
    private var accepting = true
    private var stamped = false
    private var micArmed: TimeInterval?
    private var firstUptime: TimeInterval?
    private var stoppedDuringLoad = false

    func markArmed() { lock.withLock { micArmed = ProcessInfo.processInfo.systemUptime } }
    func markStopped(loading: Bool) { lock.withLock { stoppedDuringLoad = loading } }

    func receipt(processStart: TimeInterval) -> [String: String] {
        let ready = ProcessInfo.processInfo.systemUptime
        let count = writer.acceptedSamples
        return lock.withLock {
            var result = ["launchToIntentMs": String(Int((pressedAt - processStart) * 1000)),
                          "preRollAudioMs": String(count / 16),
                          "preRollMode": "disk",
                          "stoppedDuringLoad": String(stoppedDuringLoad)]
            if let micArmed { result["intentToMicArmMs"] = String(Int((micArmed - pressedAt) * 1000)) }
            if let firstUptime {
                result["intentToFirstSampleMs"] = String(Int((firstUptime - pressedAt) * 1000))
                result["firstSampleToModelReadyMs"] = String(Int((ready - firstUptime) * 1000))
            }
            return result
        }
    }

    init(id: UUID, writer: AudioRecoveryWriter, url: URL, pressedAt: TimeInterval) {
        self.id = id
        self.writer = writer
        self.pressedAt = pressedAt
        bridge = ProgressiveAudioBridge(writer: writer, url: url)
        session = SegmentedRecognition(first: bridge)
    }

    func append(_ samples: [Float], firstSample: (Date) -> Void) {
        lock.withLock {
            guard accepting, !samples.isEmpty else { return }
            if firstUptime == nil { firstUptime = ProcessInfo.processInfo.systemUptime }
            writer.append(samples)
            session.feed(samples)
            if !stamped, let first = bridge.firstSample {
                stamped = true
                firstSample(first)
            }
        }
    }

    // Wait out a callback that already has the old sink before sealing the writer.
    func stop() { lock.withLock { accepting = false } }
}
