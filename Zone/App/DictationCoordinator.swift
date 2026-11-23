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
    private var shortcutActivityRequestFailed = false
    private var shortcutAudioPolicyPending = false
    private let deactivateShortcutAudio: () throws -> Void
    var shortcutCanRunWarm: Bool { isArmed && modelIsReady && (capture.state == .armed || activity.isBusy) }

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
    func settleRecordingShortcut() async throws {
        if !shortcutHasAudioWork { await sounds.finishStopCue() }
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
                    try recordingLiveActivity.start(noteMode: activeNoteRequestID == id,
                        controlOwned: activeNoteRequestID == id || activeShortcutRequestID == id) { [weak self] in
                        Task { [weak self] in
                            guard let self, self.currentRequest?.id == id else { return }
                            await self.stopDictation(reason: "liveActivityEnded")
                        }
                    }
                    guard recordingLiveActivity.isActive else { throw RecordingLiveActivity.Failure.foregroundRequired }
                    continue
                } catch {
                    Journal.log("shortcutIndicatorUnavailable", ["error": JournalFormat.error(error)])
                    await stopDictation(reason: "shortcutPolicy")
                    notice = "Live Activities are unavailable. The recording was stopped and kept in Zone."
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

    /// Called only from a user-triggered LiveActivityIntent. Create the visible activity
    /// before activating audio; a cold Action Button press need not first open the app.
    /// For a note, the note card says "Starting" meanwhile when Zone is on screen: this is
    /// where a press turns on a speech engine that was off.
    func prepareRecordingShortcut(noteMode: Bool = false) async throws {
        guard !meetingCaptureActive else { throw ShortcutFailure(message: Self.meetingRefusal) }
        guard microphonePermission == .granted else {
            throw ShortcutFailure(message: "Open Zone and allow microphone access, then press again.")
        }
        guard !shortcutCanRunWarm else { return }
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
        let hadActivity = recordingLiveActivity.isActive
        try recordingLiveActivity.prepareReady()
        do { try await armSession() }
        catch {
            if !hadActivity { recordingLiveActivity.end() }
            throw error
        }
    }

    /// A start press that lands while the last recording is still being recognized (stopped
    /// from the app, the Dynamic Island or the keyboard, not through the intent queue) used to
    /// return success having done nothing. Wait for recognition, which usually ends in a few
    /// seconds, then start. If another recording still holds the microphone, say so.
    func clearWayForShortcutStart(noteMode: Bool, timeout: Duration = .seconds(12)) async throws {
        let deadline = ContinuousClock.now + timeout
        var waited = false
        while case .transcribing = activity, ContinuousClock.now < deadline {
            waited = true
            try await Task.sleep(for: .milliseconds(100))
        }
        if waited { Journal.log("shortcutWaitedForRecognition", ["finished": String(!activity.isBusy)]) }
        switch activity {
        case .transcribing:
            Journal.log("shortcutBlocked", ["reason": "transcribing", "mode": noteMode ? "note" : "dictate"])
            throw ShortcutFailure(message: "Zone is still writing out your last recording. Press again in a moment.")
        case .recording:
            Journal.log("shortcutBlocked", ["reason": "recordingElsewhere", "mode": noteMode ? "note" : "dictate"])
            throw ShortcutFailure(message: "Zone is already recording. Stop that recording first, then press again.")
        default:
            return
        }
    }

    func shortcutRequestToFinish(noteMode: Bool) -> UUID? {
        guard case .recording(let id, _) = activity else { return nil }
        return (noteMode ? activeNoteRequestID : activeShortcutRequestID) == id ? id : nil
    }

    func runRecordingShortcut(noteMode: Bool, finishing expectedID: UUID?) async throws {
        if let expectedID {
            guard shortcutRequestToFinish(noteMode: noteMode) == expectedID else { return }
        } else {
            // A start admitted before foreground/model preparation must never become a stop
            // of independent work that appeared during those awaits.
            guard !activity.isBusy, !startingNote, retryingAudioID == nil else { return }
            // X on the note card while this press was getting ready: the person called it off.
            if noteMode, noteStartWithdrawn {
                noteStartWithdrawn = false
                Journal.log("noteStartWithdrawn", ["step": "afterPreparation"])
                return
            }
        }
        guard shortcutCanRunWarm else { throw RecordingLiveActivity.Failure.disabled }
        shortcutActivityRequestFailed = false
        shortcutNeedsLiveActivity = !activity.isBusy
        defer { shortcutNeedsLiveActivity = false }
        let finishingID = currentRequest?.id
        let ownsDictation = !noteMode && activeShortcutRequestID == finishingID && finishingID != nil
        await beginShortcut(noteMode: noteMode)
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
                                     spokenCorrections: settings.spokenCorrections, emoticons: settings.spokenEmoticons, smallOrdinals: settings.smallOrdinals, california: settings.californiaMode, misheard: settings.misheard)
        guard !styled.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Clipboard.copy(styled, automatic: true)
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
    /// Dictate and Note need the microphone session already running, which is the only time
    /// their buttons are drawn. They never switch the microphone on from the background.
    func performIslandAction(_ action: IslandAction) async throws {
        switch action {
        case .stop:
            guard case .recording(let id, _) = activity else { return }
            let copies = activeShortcutRequestID == id
            await stopDictation(reason: "island")
            if copies { copyFinishedDictation(id) }
        case .pause:
            togglePause()
        case .dictate, .note:
            // A second tap while the first is still starting, or a tap that lost to the
            // keyboard, must not start a second recording or stop the first.
            guard !activity.isBusy, !startingNote, !meetingCaptureActive, retryingAudioID == nil else { return }
            guard shortcutCanRunWarm else {
                throw ShortcutFailure(message: "Zone is off. Open Zone to turn it on, then try again.")
            }
            await beginShortcut(noteMode: action == .note)
            if case .failed(let message) = activity { throw ShortcutFailure(message: message) }
        }
    }

    struct ShortcutFailure: LocalizedError, CustomLocalizedStringResourceConvertible {
        let message: String
        var errorDescription: String? { message }
        var localizedStringResource: LocalizedStringResource { "\(message)" }
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
    private let audioRecoveryStore: AudioRecoveryStore = {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return AudioRecoveryStore(directory: support.appendingPathComponent("AudioRecovery", isDirectory: true))
    }()

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
    }

    private(set) var modelState: ModelState = .missing
    private(set) var activity: Activity = .idle {
        didSet {
            updateLevelHistory()
            switch activity {
            case .recording: break
            case .transcribing: recordingLiveActivity.processing()
            default:
                if shortcutAudioPolicyPending {
                    shortcutAudioPolicyPending = false
                    // A no-op intent may return while this recording is still processing.
                    // Keep its indicator until audio is settled even if completion happens
                    // between perform returning and Apple's process-wide policy check.
                    Task { [weak self] in
                        do { try await self?.settleRecordingShortcut() }
                        catch { Journal.log("shortcutTerminalCleanupFailed", ["error": JournalFormat.error(error)]) }
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
    /// Whole seconds until Finish when quiet ends this recording, shown for the last five.
    private(set) var quietFinishIn: Int?
    private var silenceFinish: SilenceFinish?
    private var silenceFinishRecording: UUID?
    /// True while the current recording is held by Pause (from the keyboard or Home).
    private(set) var isPaused = false
    private let pauseGate = PauseGate()
    private var pauseLimitTask: Task<Void, Never>?
    /// Set while a recording is in progress; nil otherwise.
    private var quietMonitor: QuietInputMonitor?
    private var levelRecordingStart: Date?
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
    private var activeNoteRequestID: UUID?
    private var activeShortcutRequestID: UUID?
    private(set) var lastError: String?
    var level: Float { capture.level }
    /// The style the keyboard chose; in-app insertions use the same one.
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
    private func beginUserUtterance(mentions: Bool? = nil) throws -> UtteranceSession {
        LexiconRecognitionSession(base: try engine.beginUtterance(), systemWords: settings.cachedSystemSpeechWords,
            personalWords: settings.appliedPersonalWords, mentions: mentions ?? settings.handleRecognition)
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
    /// A Note saved page older than this is dropped when Zone comes back to the front: the note
    /// is in Notes, and a stale page in the way of whatever the person came to do is not help.
    static let notePageFreshness: TimeInterval = 10 * 60
    /// "Added to Notes" on the page: Home opens Notes at the note and lights it up.
    private(set) var noteReveal: NoteReveal?
    /// The clock the note page's freshness reads. Tests move it.
    @ObservationIgnored var noteClock: () -> Date = { Date() }
    private(set) var noteSessionID = UUID()
    private var startingAppDictation = false
    private var startingNote = false
    private var startingNoteMode: Bool?
    private var startupStopWaiters: [CheckedContinuation<Void, Never>] = []
    /// Set by a second Action Button press while the first is still starting.
    private var stopAfterStart = false
    let notes = NotesStore()
    /// Counts recordings that ended well and decides when Apple's rating prompt may appear.
    let reviews: ReviewPrompter

    /// True while the cold-path dictation screen should cover everything else.
    var showsDictationScreen = false
    /// Set when a dictate URL arrives before the model is ready; resumed after preparation.
    private var pendingColdRequestID: UUID?

    private let store: SharedStore
    private let settings: AppSettings
    private let capture = AudioCaptureEngine()
    private let sounds = DictationSounds()
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
    /// Why the current recording is held, or why it could not resume. Nil otherwise.
    private(set) var holdNotice: String?
    /// Interruptions the current recording went through, for History and the log.
    private var recordingInterruptions = 0
    private var holdLimitTask: Task<Void, Never>?
    private var holdBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var resumingHeld: Task<Bool, Never>?
    private var vocabularyRefresh: Task<Void, Never>?
    static let heldMessage = "Paused for a call or alarm. It picks up when that ends."
    private var currentRequest: DictationRequest?
    private var currentOrigin: Origin = .app
    private var observations: [DarwinObservation] = []
    private var inactivityTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    /// The detached load inside `preparationTask`; cancelling it stops a download in progress.
    private var preparationLoad: Task<Void, Error>?
    private var isSwitchingEngine = false
    private var armingSessions = 0
    /// True while CarPlay is the audio route. Tests swap it to put Zone in a car.
    @ObservationIgnored var carPlayRoute: () -> Bool = { CarAudioRoute.isCarPlay(AVAudioSession.sharedInstance().currentRoute) }
    /// The person turned Zone on (Home's Turn on, the Toggle Zone control) with CarPlay already
    /// connected, knowing the car's audio then takes its call channel: that standby stays. Zone's
    /// own arming (on open, after an interruption) never holds the microphone in CarPlay.
    @ObservationIgnored private var standbyChosenInCar = false
    @ObservationIgnored private var carReleaseTask: Task<Void, Never>?
    /// The wait after a recording before CarPlay gets its audio back: long enough for a second
    /// dictation right after the first, and for the island's check to show.
    @ObservationIgnored var carReleaseDelay: Duration = .seconds(2)
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
    /// Speech time of the live recording, for words per minute. Keyed by request so a finish can
    /// never read the next recording's clock.
    @ObservationIgnored private var speaking: (id: UUID, clock: SpeakingClock)?
    /// Set by End session; opening the app again does not re-arm until the user starts one.
    private var userEndedSession = false
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
    /// Set when an interruption ends an armed session, so a `shouldResume` can bring it back.
    private var wasArmedBeforeInterruption = false
    /// Bakeoff clip recording state.
    private var clipSink: ClipSink?
    private var clipArmedCapture = false
    /// True while a meeting owns the microphone. Meetings and dictation never overlap: each
    /// refuses to start while the other runs, with a message that says why.
    private(set) var meetingCaptureActive = false
    /// The meeting armed the microphone itself, so it releases it when it ends.
    private var meetingArmedCapture = false
    /// Tells the meeting recorder about audio interruptions (a call, Siri, another app).
    var onMeetingInterruption: ((AudioCaptureEngine.Interruption) -> Void)?
    private static let retryRefusal = "Finish or cancel the audio retry before starting a recording."
    static let meetingRefusal = "A meeting is recording in Zone. Stop it to dictate."
    /// Uptime when this process created its coordinator, for load timings in the log.
    static let processStart = ProcessInfo.processInfo.systemUptime

    init(settings: AppSettings,
         store: SharedStore = UserDefaultsSharedStore(),
         engine suppliedEngine: SpeechEngine? = nil,
         reviews: ReviewPrompter? = nil,
         modelEngineFactory: @escaping (SpeechModel) -> SpeechEngine = { $0.makeEngine() },
         requestSessionPermission: @escaping () async -> Bool = {
             if AVAudioApplication.shared.recordPermission == .granted { return true }
             return await AVAudioApplication.requestRecordPermission()
         },
         armSessionCapture: (() async throws -> Void)? = nil,
         recordingLiveActivity: RecordingLiveActivity? = nil,
         deactivateShortcutAudio: @escaping () throws -> Void = {
             // Synchronous, and behind any audio work already queued: inactive on return.
             try AudioHardwareQueue.sync {
                 try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
             }
         }) {
        let engine = suppliedEngine ?? EngineKind.selected.makeEngine()
        self.settings = settings
        self.store = store
        self.engine = engine
        self.modelEngineFactory = modelEngineFactory
        self.requestSessionPermission = requestSessionPermission
        self.armSessionCapture = armSessionCapture
        self.recordingLiveActivity = recordingLiveActivity ?? RecordingLiveActivity()
        self.recordingLiveActivity.look = { [settings] in settings.islandLook }
        self.recordingLiveActivity.controls = { [settings] in settings.islandControls }
        self.recordingLiveActivity.accentHex = { AccentChoice.current.hex }
        self.deactivateShortcutAudio = deactivateShortcutAudio
        self.reviews = reviews ?? ReviewPrompter()
        modelState = engine.assetsPresent() ? .loading : .missing
        Self.shortcutCoordinator = self
        // Zone is running again: any recording it lost now shows as a recovery card, so a
        // still-pending "Zone stopped" notice would only repeat it.
        RecordingSafetyNotice.disarm()
        wireCapture()
        self.recordingLiveActivity.session = { [weak self] in self?.islandSession }
        observations = [
            DarwinNotifier.observe(.requestChanged) { [weak self] in self?.handleRequestChanged() },
            DarwinNotifier.observe(.controlChanged) { [weak self] in self?.handleControlChanged() },
            DarwinNotifier.observe(.payloadConsumed) { [weak self] in self?.consumeAudioReceiptFromLedger() },
            DarwinNotifier.observe(.keyboardShown) { [weak self] in self?.keyboardShown() },
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
        // Not a `.requested` written seconds ago: on the cold path the keyboard writes it just
        // before opening Zone, for the request this launch is about to serve, and calling it
        // interrupted showed "The previous recording was interrupted" for a dictation that had
        // not started. The window is the one `RecordingRecovery` uses.
        if let prior = store.status, [.requested, .starting, .recording, .transcribing].contains(prior.phase),
           !(prior.phase == .requested && Date().timeIntervalSince(prior.updatedAt) <= RecordingRecovery.requestWindow) {
            store.status = DictationStatus(requestID: prior.requestID, generation: prior.generation,
                                          phase: .interrupted, updatedAt: Date(), message: "The previous recording was interrupted. Check History for recovered text.")
            DarwinNotifier.post(.statusChanged)
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
        for record in before where record.state == .recording || record.state == .retrying {
            // Left mid-recording by the previous process: it was killed, crashed or ran out of memory.
            Journal.log("recordingAbandoned", recording: record.id,
                        ["state": record.state.rawValue, "audio": JournalFormat.seconds(record.audioSeconds),
                         "words": JournalFormat.words(record.text), "lastWrite": ISO8601DateFormatter().string(from: record.updatedAt)])
        }
        Task { await refreshAudioRecovery() }
        refreshVocabularyCache()
        if suppliedEngine == nil {
            // Remove historical downloads on every launch. Retrying rather than recording a
            // one-shot migration also recovers partial failures. The model in use is never a
            // retired one (a retired choice moves to its replacement, and their folders are
            // separate), so the sweep runs beside its load. Loading after the sweep held every
            // launch's model back by a median 0.77 s (p90 1.6 s, worst 5.8 s, 80 launches on a
            // phone, November 2026), each sweep freeing nothing.
            let sweepTouchesModelInUse = SpeechModel.retired.contains(selectedModel)
            if sweepTouchesModelInUse {
                isDeletingModels = true
            } else if engine.assetsPresent() {
                prepareModel()
            }
            Task {
                await performModelDeletion(SpeechModel.retired, automatic: true)
                // A keyboard request that arrived during cleanup is waiting on this load.
                if self.engine.assetsPresent() || pendingColdRequestID != nil { prepareModel() }
                if appIsActive { armOnOpenIfWanted() }
            }
        } else if engine.assetsPresent() {
            prepareModel()
        }
    }

    // MARK: Level history

    /// Starts or ends the level history with the recording. Samples arrive in `appendLevel`,
    /// called from the capture engine's level callback, so there is no timer of its own.
    private func updateLevelHistory() {
        if case .recording(_, let startedAt) = activity {
            guard quietMonitor == nil || levelRecordingStart != startedAt else { return }
            levelRecordingStart = startedAt
            hearsNothing = false
            quietMonitor = QuietInputMonitor(startedAt: ProcessInfo.processInfo.systemUptime)
            islandMeter.reset()
        } else {
            quietMonitor = nil
            levelRecordingStart = nil
            hearsNothing = false
            silenceFinish = nil
            quietFinishIn = nil
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
    private func watchForQuiet(_ level: Float) {
        guard settings.finishWhenQuiet, !isHeld, case .recording(let id, _) = activity else {
            silenceFinish = nil
            if quietFinishIn != nil { quietFinishIn = nil }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if silenceFinish == nil || silenceFinishRecording != id || silenceFinish?.wait != settings.finishWhenQuietWait {
            silenceFinish = SilenceFinish(wait: settings.finishWhenQuietWait)
            silenceFinishRecording = id
        }
        var countdown: Int?
        if isPaused {
            silenceFinish?.restartWait(at: now) // A pause is not quiet.
        } else {
            switch silenceFinish?.sample(level: level, at: now) {
            case .finish:
                silenceFinish = nil
                Journal.log("quietFinish", recording: id, ["wait": JournalFormat.seconds(settings.finishWhenQuietWait)])
                ZoneLog.coordinator.info("quiet finish for \(id.uuidString.prefix(8), privacy: .public)")
                Task { await self.stopDictation(reason: "quiet") }
            case .quiet(let remaining) where remaining <= 5:
                countdown = max(1, Int(remaining.rounded(.up)))
            default:
                break
            }
        }
        if quietFinishIn != countdown { quietFinishIn = countdown }
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

    /// While active, re-read keyboard presence every two seconds so onboarding completes itself
    /// after the user enables the keyboard in Settings and comes back.
    /// Scene phase from the root view. Only a real return from the background re-arms, so a
    /// Control Center or notification bounce never undoes End session.
    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            Journal.log("appBackground", recording: currentRequest?.id, ["activity": activityName, "held": String(isHeld)])
            sawBackground = true
            setLevelHistoryVisible(false)
            setForeground(false)
        case .active:
            setLevelHistoryVisible(true)
            setForeground(true)
            settings.adoptKeyboardStyle()
            if !meetingCaptureActive {
                if recordingLiveActivity.isActive { reconcileIslandInFront() } else { showStandbyIsland(canCreate: true) }
            }
            Journal.log("appForeground", recording: currentRequest?.id, ["activity": activityName, "held": String(isHeld)])
            dropStaleNotePage()
            resumeHeldRecordingOnForeground()
            // Warm the model whenever Zone comes up, armed or not: the next tap from the
            // keyboard should not pay for a cold load.
            if !modelIsReady, preparationTask == nil, engine.assetsPresent() { prepareModel() }
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
                prepareModel()
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
            prepareModel()
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
    var isPreparingModel: Bool { preparationTask != nil }

    func prepareModel() {
        guard preparationTask == nil, modelState != .ready, !isDeletingModels, libraryDownloads[selectedModel] == nil else { return }
        let requested = ProcessInfo.processInfo.systemUptime
        let engine = self.engine
        let kind = engine.kind.rawValue
        let progressGate = ModelProgressGate()
        modelState = engine.assetsPresent() ? .loading : .downloading(progress: 0, file: "")
        // The load starts now, off the main actor. As a main-actor task it waited for launch
        // work to finish first: 240 to 700 ms in the simulator before the load even began.
        let load = Task.detached(priority: .userInitiated) {
            ZoneLog.coordinator.info("model load start \(kind, privacy: .public) wait=\(Int((ProcessInfo.processInfo.systemUptime - requested) * 1000)) ms")
            try await engine.prepare { fraction, file in
                guard progressGate.accept(fraction, file: file) else { return }
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.modelState else { return }
                    self.modelState = file == "loading" ? .loading : .downloading(progress: fraction, file: file)
                }
            }
        }
        preparationLoad = load
        preparationTask = Task { [weak self] in
            guard let self else { return }
            defer { preparationLoad = nil }
            do {
                try await load.value
                // An unload can land while this task waits to resume (the bake-off unloads
                // between engines); only claim ready when the engine is.
                guard engine.isReady else {
                    modelState = engine.assetsPresent() ? .loading : .missing
                    failPendingColdRequest("The speech model was unloaded before dictation could start. Tap the mic again.")
                    preparationTask = nil
                    return
                }
                modelState = .ready
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
            } catch is CancellationError {
                modelState = engine.assetsPresent() ? .loading : .missing
                failPendingColdRequest("The speech model download was cancelled.")
            } catch {
                modelState = .failed(error.localizedDescription)
                lastError = error.localizedDescription
                failPendingColdRequest(error.localizedDescription)
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
        await AVAudioApplication.requestRecordPermission()
    }

    // MARK: Session

    /// Foreground only. Loads the model if needed, activates audio and arms the warm path.
    /// - Parameter chosenByPerson: true for Home's Turn on and the Toggle Zone control. With
    ///   CarPlay connected, only such a standby outlasts the next recording.
    func armSession(chosenByPerson: Bool = false) async throws {
        try Task.checkCancellation()
        guard !isDeletingModels else { throw SpeechEngineError.unavailable("Model storage is being cleaned. Try again when it finishes.") }
        let generation = sessionGeneration
        armingSessions += 1
        defer { armingSessions -= 1 }
        if !modelIsReady {
            prepareModel()
            await preparationTask?.value
            try Task.checkCancellation()
            guard generation == sessionGeneration else { throw CancellationError() }
            guard modelIsReady else {
                throw SpeechEngineError.notReady
            }
        }
        let granted = await requestSessionPermission()
        try Task.checkCancellation()
        guard generation == sessionGeneration else { throw CancellationError() }
        guard granted else { throw CaptureError.noInputAvailable }
        // Activation runs on the audio hardware queue; End session meanwhile disarms, which
        // cancels it and leaves the session inactive.
        if let armSessionCapture { try await armSessionCapture() } else { try await armCapture() }
        guard generation == sessionGeneration else { throw CancellationError() }
        isArmed = true
        userEndedSession = false
        standbyChosenInCar = chosenByPerson && carPlayRoute()
        if islandSession == nil { islandSession = IslandSession(since: Date()) }
        store.purgeStalePayloads()
        touchActivity()
        startCountdown()
        showStandbyIsland(canCreate: UIApplication.shared.applicationState == .active)
        publishSession()
        DarwinNotifier.post(.sessionChanged)
    }

    // MARK: Dynamic Island

    /// Live microphone history for the island, filled whether or not Zone is on screen.
    @ObservationIgnored private var islandMeter = IslandMeter()
    /// This standby session's numbers for the island, from turning Zone on to turning it off.
    /// An interruption holds the session, so it keeps counting after a call.
    @ObservationIgnored private(set) var islandSession: IslandSession?

    /// Owns the Dynamic Island while the microphone waits, so iOS shows Zone's small island
    /// instead of its own wide microphone pill. Off in Settings, or with no session, it ends.
    private func showStandbyIsland(canCreate: Bool) {
        guard isArmed, !activity.isBusy else { return }
        if settings.islandWhileReady {
            recordingLiveActivity.standby(until: armedUntil, canCreate: canCreate)
        } else if recordingLiveActivity.showsStandby {
            recordingLiveActivity.end()
        }
    }

    /// In front, the one place a card can be made again. An armed standby's card is renewed
    /// before iOS's eight-hour limit can take it in the background. A held card stays while its
    /// interruption may still end; once that standby cannot come back (no interruption pending,
    /// or held past the hold limit, as a held recording would be) it goes. A ready card with no
    /// standby is left alone: a press of the Action Button makes one before the microphone arms.
    private func reconcileIslandInFront() {
        guard !activity.isBusy, recordingLiveActivity.showsStandby else { return }
        if isArmed { return recordingLiveActivity.renewStandbyIfAging() }
        guard let since = recordingLiveActivity.standbyHeldSince else { return }
        if wasArmedBeforeInterruption, !InterruptionPolicy.holdExpired(heldSince: since, now: Date()) { return }
        wasArmedBeforeInterruption = false
        recordingLiveActivity.end()
    }

    /// Settings > Dynamic Island > Try it: twelve seconds of a pretend dictation in the real
    /// island, so a look can be judged where it lives. Nothing is recorded. A real dictation
    /// that starts meanwhile simply takes the island over; the preview then stops touching it.
    func previewIsland() async {
        guard !activity.isBusy else { return }
        // Not control-owned: the Home Screen widget must never claim a pretend recording.
        do { try recordingLiveActivity.start(noteMode: false, controlOwned: false, onLost: {}) } catch { return }
        let words = Self.islandPreviewScript.split(separator: " ")
        var meter = IslandMeter()
        var clock: TimeInterval = 0
        for second in 1...10 {
            for _ in 0..<20 {
                clock += 0.05
                meter.append(Self.pretendVoice(clock))
            }
            let spoken = words.prefix(second * words.count / 10).joined(separator: " ")
            recordingLiveActivity.live(levels: meter.snapshot, text: spoken)
            try? await Task.sleep(for: .seconds(1))
            guard !activity.isBusy, recordingLiveActivity.showsRecording else { return }
        }
        recordingLiveActivity.processing()
        try? await Task.sleep(for: .seconds(2))
        guard !activity.isBusy else { return }
        settleIslandAfterRecording(kept: words.count)
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
    }

    #if DEBUG
    /// Simulator screenshots: the standby card as an interruption holds it. The interruption is
    /// marked pending, as a real one would be, or Zone in front drops the card as an orphan.
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
                session.add(words: words, seconds: seconds, speakingSeconds: seconds * 0.82)
            }
            islandSession = session
            recordingLiveActivity.standby(until: Date().addingTimeInterval(300), lastWords: 42,
                                          justFinished: justFinished, canCreate: true)
            return
        }
        do { try recordingLiveActivity.start(noteMode: false, controlOwned: false, onLost: {}) } catch { return }
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

    /// Settings changed the island's look or standby: redraw now rather than at the next state.
    func refreshIsland() {
        if recordingLiveActivity.showsStandby || (isArmed && !activity.isBusy) {
            showStandbyIsland(canCreate: UIApplication.shared.applicationState == .active)
        }
    }

    /// Arms the microphone (the hardware work runs off the main thread), then readies the cues
    /// so the first one played does not set up its audio queue on the main thread.
    private func armCapture() async throws {
        try await capture.arm()
        sounds.sessionArmed(true)
    }

    /// Synchronous: the session is inactive when this returns. See `AudioCaptureEngine.disarm`.
    private func disarmCapture() {
        sounds.sessionArmed(false)
        capture.disarm()
    }

    func endSession(reason: SessionEndReason, keepingRecordingIndicator: Bool = false) {
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
        standbyChosenInCar = false
        carReleaseTask?.cancel()
        carReleaseTask = nil
        if case .recording = activity {
            cancelDictation()
        }
        inactivityTask?.cancel()
        inactivityTask = nil
        countdownTask?.cancel()
        countdownTask = nil
        if meetingCaptureActive {
            // Turning dictation off (or its timeout) must never cut a meeting: the microphone
            // stays with the meeting and is released when the meeting stops.
            meetingArmedCapture = true
        } else {
            disarmCapture()
        }
        if !keepingRecordingIndicator { recordingLiveActivity.end() }
        isArmed = false
        armedUntil = nil
        islandSession = nil
        publishSession()
        DarwinNotifier.post(.sessionChanged)
    }

    /// After a recording, or when CarPlay connects while Zone waits: gives the car its audio back
    /// once nothing is recording, starting or waiting for the microphone. Deferred by
    /// `carReleaseDelay`, so a dictation started right after the last keeps the microphone.
    func releaseMicrophoneInCarSoon() {
        guard isArmed, !standbyChosenInCar else { return }
        carReleaseTask?.cancel()
        carReleaseTask = Task { [weak self] in
            guard let delay = self?.carReleaseDelay else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.carReleaseTask = nil
            self.releaseMicrophoneInCarIfIdle()
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
            if self.activity.isBusy {
                // Standby can expire after the final recognition result is delivered.
                self.touchActivity()
                return
            }
            self.endSession(reason: .timeout)
        }
        publishSession()
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
        store.session = SessionState(
            isArmed: isArmed,
            armedUntil: armedUntil,
            modelReady: modelIsReady,
            heartbeat: Date())
        // The Toggle Zone control redraws only when asked, so it is told on a real change,
        // not on every heartbeat.
        let standby = StandbyControlState(isOn: isArmed, until: isArmed ? armedUntil : nil)
        if standby != publishedStandby {
            publishedStandby = standby
            StandbyControlState.publish(standby)
        }
    }
    private var publishedStandby: StandbyControlState?

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
                lastError = error.localizedDescription
                if !activity.isBusy { activity = .failed(error.localizedDescription) }
            }
        }
    }

    /// Home's Turn off, from the Toggle Zone control. Turning a session off cancels a
    /// recording in progress, and a control must never throw one away.
    func turnStandbyOffFromControl() throws {
        guard !activity.isBusy, !startingNote else {
            throw ShortcutFailure(message: "Zone is recording. Finish the recording, then turn Zone off.")
        }
        guard isArmed || armingSessions > 0 else { return }
        endSession(reason: .user)
    }

    // MARK: URL (cold path)

    func handle(url: URL) {
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
            if activity.isBusy {
                showRecordingScreen()
            } else {
                showsDictationScreen = false
            }
            return
        }
        guard let requestID = ZoneContract.requestID(from: url) else { return }
        // The keyboard sent the person here to dictate: nothing about the last note may stand
        // in front of its screen.
        closeNotePage(reason: "keyboardRequest")
        clearNoteOutcome()
        showsDictationScreen = true
        lastError = nil
        if modelIsReady {
            Task { await startColdDictation(requestID: requestID) }
        } else {
            pendingColdRequestID = requestID
            prepareModel()
        }
    }

    private func startColdDictation(requestID: UUID) async {
        ZoneLog.coordinator.info("dictate URL for \(requestID.uuidString.prefix(8), privacy: .public)")
        // The warm path may already have started this very request (the keyboard opened the app
        // because its wait ran out); the screen just needs to show it.
        if let current = currentRequest, current.id == requestID {
            return
        }
        lastHandledRequestID = requestID
        guard let request = store.request, request.id == requestID else {
            // The keyboard's request record is missing: the keyboard wrote it somewhere this app
            // can't see. Either this build has no App Group, or iOS had not yet given the keyboard
            // Full Access when it wrote.
            Journal.log("requestMissing", recording: requestID,
                        ["appGroup": String(AppGroup.isReachable), "presence": store.keyboardPresence == nil ? "never" : "seen"])
            lastError = AppGroup.isReachable
                ? "The keyboard's request didn't reach Zone. Close the app you were typing in, open it again and tap the mic."
                : "This copy of Zone was built without its shared App Group, so the keyboard can't reach it."
            activity = .failed(lastError!)
            return
        }
        do {
            if !isArmed {
                try await armSession()
            }
            guard store.request?.id == request.id, store.request?.generation == request.generation,
                  request.generation > store.ledger.droppedGeneration,
                  currentRequest == nil, !activity.isBusy else { return }
            beginRecording(for: request, origin: .keyboard)
        } catch is CancellationError {
            guard currentRequest == nil, store.request?.id == request.id else { return }
            publishStatus(.cancelled, for: request, message: nil)
        } catch {
            guard currentRequest == nil, store.request?.id == request.id else { return }
            lastError = error.localizedDescription
            activity = .failed(error.localizedDescription)
            publishStatus(.failed, for: request, message: error.localizedDescription)
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

    func shouldRunRecordingControl(noteMode: Bool, desiredState: Bool) -> Bool {
        if startingNote, startingNoteMode != noteMode { return false }
        return NoteActionPolicy.action(for: shortcutState, noteMode: noteMode, desiredState: desiredState) != .ignore
    }

    /// In-app starts do not use the intent queue. A matching Off must join that startup
    /// and return only after its deferred stop finishes, without touching another mode.
    func finishStartingShortcut(noteMode: Bool, desiredState: Bool?) async -> Bool {
        guard startingNote else { return false }
        guard startingNoteMode == noteMode, desiredState != true else { return true }
        stopAfterStart = true
        await withCheckedContinuation { startupStopWaiters.append($0) }
        return true
    }

    private func beginShortcut(noteMode: Bool) async {
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
                    await startAppDictation(contextBefore: nil, replaceActive: false, asNote: true)
                } else {
                    do {
                        if !isArmed { try await armSession() }
                        guard noteSessionID == token, showsDictationScreen, !activity.isBusy else { return }
                        // There is no destination field when a standalone Shortcut starts. The
                        // next keyboard offers an explicit Insert instead of guessing a target.
                        let generation = max(store.request?.generation ?? 0, store.ledger.droppedGeneration) + 1
                        let request = DictationRequest(id: UUID(), generation: generation, createdAt: Date(),
                                                       inputSession: nil, contextBefore: nil)
                        store.control = nil
                        store.request = request
                        lastHandledRequestID = request.id
                        beginRecording(for: request, origin: .keyboard, shortcut: true)
                    } catch is CancellationError {
                        return
                    } catch {
                        lastError = error.localizedDescription
                        activity = .failed(error.localizedDescription)
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
        if preparingNote { noteStartWithdrawn = true }
        noteRequested = false
    }

    /// An Action Button press for a note was refused before any note began (a call holds the
    /// microphone, Live Activities are off). iOS says so for a press made outside Zone; with
    /// Zone on screen the note card says it, rather than a starting card vanishing unexplained.
    func notePressFailed(_ message: String) {
        guard !message.isEmpty, UIApplication.shared.applicationState == .active, noteOutcome == nil,
              !activity.isBusy else { return }
        endNote(.failed(message))
    }

    /// X on a card that says how the last note ended. A failure it showed is acknowledged too,
    /// so Home does not repeat it.
    func dismissNoteOutcome() {
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
        notePage = NotePage(noteID: note.id, savedAt: noteClock(), notesBefore: max(notes.notes.count - 1, 0),
                            audioSeconds: audioSeconds)
        Journal.log("notePageShown", ["appState": Self.appStateName()])
    }

    /// Done, a swipe down, Added to Notes, or something new starting. A finished note's result
    /// is acknowledged with it, so nothing else shows it again.
    func closeNotePage(reason: String = "done") {
        guard notePage != nil else { return }
        notePage = nil
        Journal.log("notePageClosed", ["reason": reason])
        if case .finished = activity, lastResultWasNote { acknowledgeActivity() }
    }

    /// Coming back to Zone: a page from a while ago is no longer news.
    private func dropStaleNotePage() {
        guard let page = notePage, noteClock().timeIntervalSince(page.savedAt) > Self.notePageFreshness else { return }
        closeNotePage(reason: "stale")
    }

    /// The page's text, edited. Emptying it deletes the note, as in the Notes editor.
    func updateNote(_ id: UUID, text: String) {
        guard let note = notes.notes.first(where: { $0.id == id }) else { return }
        notes.update(note, text: text)
        if notePage?.noteID == id, !notes.notes.contains(where: { $0.id == id }) {
            closeNotePage(reason: "emptied")
        }
    }

    /// Delete on the page, after its confirmation.
    func deleteNote(_ id: UUID) {
        guard let note = notes.notes.first(where: { $0.id == id }) else { return }
        notes.delete(note)
        Journal.log("noteDeleted", ["from": notePage?.noteID == id ? "notePage" : "app"])
        if notePage?.noteID == id { closeNotePage(reason: "deleted") }
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
    func startAppDictation(contextBefore: String?, replaceActive: Bool = true, asNote: Bool = false) async {
        guard !startingAppDictation else {
            // The composer's own start is already getting the microphone; that recording wins,
            // and this press has nothing left to start.
            if asNote {
                Journal.log("noteStartAbandoned", ["reason": "appDictationStarting"])
                noteRequested = false
            }
            return
        }
        startingAppDictation = true
        defer { startingAppDictation = false }
        do {
            if !isArmed {
                try await armSession()
            }
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
            beginRecording(for: request, origin: .app, note: asNote)
            if asNote { noteRequested = false }
        } catch is CancellationError {
            if asNote { noteRequested = false }
            return
        } catch {
            lastError = error.localizedDescription
            activity = .failed(error.localizedDescription)
            if asNote { endNote(.failed(error.localizedDescription)) }
        }
    }

    // MARK: Recording lifecycle

    /// - Parameters:
    ///   - note: the recording is a note (the Action Button, a Shortcut, Home's Dictate a note).
    ///     Only `startAppDictation` passes true, and only for a press nobody called off.
    ///   - shortcut: a dictation with no text field behind it: one started by a press on the
    ///     Action Button, a control or the island's Dictate. Like a note, it belongs to its
    ///     control, so every control shows it as recording and can stop it.
    private func beginRecording(for request: DictationRequest, origin: Origin, note: Bool = false, shortcut: Bool = false) {
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
            let activityRequired = shortcutNeedsLiveActivity
            shortcutNeedsLiveActivity = false
            let noteMode = note
            let controlOwned = shortcut || noteMode
            // A shortcut or note recording owns its Live Activity: it must exist before the
            // intent returns, so it is requested here, synchronously, before any audio is
            // used. Any other recording only shows one, and `Activity.request` is a
            // synchronous XPC (part of a 384 ms start hang), so that request waits until the
            // recording runs. Updating an activity already showing costs nothing either way.
            let deferredIndicator = !controlOwned && !recordingLiveActivity.isActive
            if !deferredIndicator {
                do {
                    try startRecordingIndicator(for: request.id, noteMode: noteMode, controlOwned: controlOwned)
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
            engine.setPersonalWords(settings.cachedSpeechHintWords())
            engine.setContextHints(settings.usesTypedTextAsHints ? (request.contextBefore ?? "") : "")
            let beganAt = ProcessInfo.processInfo.systemUptime
            let session = SegmentedRecognition(first: try beginUserUtterance())
            ZoneLog.coordinator.info("utterance opened in \(Int((ProcessInfo.processInfo.systemUptime - beganAt) * 1000)) ms")
            utterance = session
            segmented = session
            heldSince = nil
            holdNotice = nil
            recordingInterruptions = 0
            currentRequest = request
            currentOrigin = origin
            activeNoteRequestID = note ? request.id : nil
            activeShortcutRequestID = shortcut ? request.id : nil
            // Whatever the last note left on screen is over: a new recording has the microphone.
            clearNoteOutcome()
            closeNotePage(reason: note ? "newNote" : "newRecording")
            liveTranscript = ""
            // The quiet cue does not suppress any of the speaker’s opening words.
            let playsSounds = settings.soundsEnabled
            audioRecoveryWarning = nil
            do {
                audioWriter = try audioRecoveryStore.begin(id: request.id, engine: engine.kind.rawValue,
                                                           source: activeNoteRequestID == request.id ? .note : origin.historySource)
                audioRecordID = request.id
            } catch {
                audioWriter = nil
                audioRecordID = nil
                audioRecoveryWarning = AudioRecoveryError.unavailable.localizedDescription
            }
            let writer = audioWriter
            let gate = pauseGate
            let clock = SpeakingClock()
            speaking = (request.id, clock)
            setPaused(false)
            capture.onSamples = { samples in
                guard !gate.isPaused else { return } // Paused audio is never heard or kept.
                writer?.append(samples) // Original audio, before any recognition or formatting.
                session.feed(samples)
                clock.add(samples)
            }
            capture.startRecording()
            if playsSounds { sounds.use(settings.soundSet); sounds.playStart() }
            ZoneLog.coordinator.info("recording \(request.id.uuidString.prefix(8), privacy: .public) origin=\(String(describing: origin), privacy: .public)")
            Journal.log("recordingStarted", recording: request.id,
                        ["origin": activeNoteRequestID == request.id ? "note" : String(describing: origin),
                         "engine": engine.kind.rawValue, "appState": Self.appStateName(),
                         "recoveryFile": String(audioWriter != nil)])
            activity = .recording(requestID: request.id, startedAt: Date())
            recordingStartedAt = Date()
            RecordingSafetyNotice.arm()
            // There is no length cap: a dictation runs as long as the person talks. Engines keep
            // memory flat (the model decodes rolling segments) and the
            // history keeps everything said so far.
            let engineName = engine.kind.rawValue
            let source: TranscriptSource = note ? .note : origin.historySource
            Self.history { $0.begin(id: request.id, engine: engineName, source: source) }
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
                    if let failure = self.audioWriter?.failure, self.audioRecoveryWarning == nil {
                        self.audioRecoveryWarning = "Temporary audio recovery is incomplete: \(failure.localizedDescription)"
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
            lastError = error.localizedDescription
            activity = .failed(error.localizedDescription)
            if origin == .keyboard {
                publishStatus(.failed, for: request, message: error.localizedDescription)
            }
            if note { endNote(.failed(error.localizedDescription)) }
        }
    }

    private func startRecordingIndicator(for requestID: UUID, noteMode: Bool, controlOwned: Bool) throws {
        try recordingLiveActivity.start(noteMode: noteMode, controlOwned: controlOwned) { [weak self] in
            Task { [weak self] in
                guard let self, case .recording(let currentID, _) = self.activity,
                      currentID == requestID else { return }
                await self.stopDictation(reason: "liveActivityEnded")
            }
        }
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
        RecordingSafetyNotice.disarm() // Zone is alive and shows this failure itself.
        setPaused(false)
        let text = session.textSoFar, seconds = session.audioSeconds
        liveTranscript = text
        retainAudioFailure(request.id, text: text, message: error.localizedDescription)
        Self.history { $0.finish(id: request.id, text: text, audioSeconds: seconds, status: .cutOff) }
        session.cancel()
        let wasNote = activeNoteRequestID == request.id
        activeNoteRequestID = nil
        utterance = nil
        currentRequest = nil
        lastError = error.localizedDescription
        activity = .failed(error.localizedDescription)
        if origin == .keyboard {
            levelChannel.send(0)
            publishStatus(.failed, for: request, message: error.localizedDescription)
        }
        if wasNote { endNote(.failed(error.localizedDescription)) }
        touchActivity()
    }

    /// - Parameter reason: who or what stopped it, for the recording log ("user", "keyboard",
    ///   "shortcut", "holdExpired", "limit:…").
    func stopDictation(reason: String = "user") async {
        guard case .recording(let requestID, _) = activity,
              let request = currentRequest, request.id == requestID,
              let session = utterance else { return }
        let origin = currentOrigin
        let stoppedAt = ProcessInfo.processInfo.systemUptime
        let wasHeld = isHeld
        let interruptions = recordingInterruptions
        Journal.log("recordingStopping", recording: requestID,
                    ["reason": reason, "held": String(wasHeld), "paused": String(isPaused),
                     "audio": JournalFormat.seconds(session.audioSeconds), "words": JournalFormat.words(session.textSoFar),
                     "interruptions": String(interruptions), "appState": Self.appStateName()])
        utteranceLimitTask?.cancel()
        clearHold()
        capture.stopRecording()
        capture.onSamples = nil
        setPaused(false)
        // The safety notice stays armed through recognition, the likeliest time to be killed
        // for memory, and is withdrawn once the words are saved (below) or the attempt fails.
        RecordingSafetyNotice.arm()
        defer { RecordingSafetyNotice.disarm() }
        // Held, the audio session is not ours: a cue would fail or land in someone's call.
        if settings.soundsEnabled, !wasHeld { sounds.playStop() }
        activity = .transcribing(requestID: requestID)
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
                catch { audioRecoveryWarning = "Temporary audio recovery is incomplete: \(error.localizedDescription)" }
            }
            guard currentRequest?.id == requestID, utterance === session else { return }
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
            var historyDurable = await Self.commitHistory {
                $0.finish(id: requestID, text: text, audioSeconds: seconds, status: wasNote ? .note : .finished,
                          interruptions: interruptions > 0 ? interruptions : nil)
            }
            guard currentRequest?.id == requestID, utterance === session else { return }
            if let lost = segments?.failedSegments, lost > 0 {
                // A stretch between interruptions could not be fully recognized: the words are
                // saved, and the audio stays for a retry that hears all of it.
                retainAudioFailure(requestID, text: text,
                                   message: "Part of this recording could not be recognized. Transcribe the saved audio to get every word.")
            } else {
                await finalizeAudio(requestID, text: text, historyDurable: historyDurable)
            }
            Journal.log("recordingSaved", recording: requestID,
                        ["status": wasNote ? "note" : "finished", "historySaved": String(historyDurable)])
            guard currentRequest?.id == requestID, utterance === session else { return }
            var output = text
            if UserDefaults.standard.bool(forKey: CleanupEngine.automaticKey), CleanupEngine.unavailableReason == nil {
                do {
                    output = try await Watchdog.run(what: "Cleanup", limit: 8) {
                        try await CleanupEngine.cleanAndSave(text, id: requestID)
                    }
                } catch {
                    // Recognition and its raw history are already complete. Cleanup cannot fail them.
                    Journal.log("cleanupKeptOriginal", recording: requestID,
                                ["error": JournalFormat.error(error)])
                }
                guard currentRequest?.id == requestID, utterance === session else { return }
            }
            // Doubtful words describe the engine's own words; after Cleanup rewrote the text they
            // could point at the wrong word, so none are sent.
            let doubts = output == text ? DoubtfulWords.candidates(session.doubtfulWords) : []
            let result = DictationResult(
                requestID: request.id, generation: request.generation, text: output,
                audioSeconds: seconds, createdAt: Date(), inputSession: request.inputSession,
                doubts: doubts.isEmpty ? nil : doubts)
            // No suspension between final ownership validation and saving the note.
            let savedNote = wasNote ? notes.add(textStyle.apply(output, personalWords: personalWords, systemWords: systemWords,
                                                                spokenCorrections: settings.spokenCorrections, emoticons: settings.spokenEmoticons, smallOrdinals: settings.smallOrdinals, california: settings.californiaMode, misheard: settings.misheard)) : nil
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
            if savedNote != nil { useRecoveredText(requestID) }
            let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            let spoke = speaking?.id == requestID ? speaking?.clock.seconds : nil
            speaking = nil
            if words > 0 {
                settings.record(words: words, seconds: session.audioSeconds, speakingSeconds: spoke)
                islandSession?.add(words: words, seconds: session.audioSeconds, speakingSeconds: spoke)
            }
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
            if origin == .keyboard {
                store.result = result
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
            let audioKept = audioRecordID == requestID
            retainAudioFailure(requestID, text: partial, message: error.localizedDescription)
            Self.history { $0.finish(id: requestID, text: partial, audioSeconds: seconds, status: .cutOff) }
            let wasNote = activeNoteRequestID == requestID
            activeNoteRequestID = nil
            utterance = nil
            segmented = nil
            currentRequest = nil
            lastError = error.localizedDescription
            activity = .failed(error.localizedDescription)
            if origin == .keyboard {
                publishStatus(.failed, for: request, message: error.localizedDescription)
            }
            // When its audio was being kept, Home's recovery card can transcribe it again.
            if wasNote {
                endNote(.failed(audioKept
                    ? "The note's words could not be written out. Its audio is kept on Home to transcribe again."
                    : "The note's words could not be written out. \(error.localizedDescription)"))
            }
        }
        utteranceLimitTask?.cancel()
        touchActivity()
        releaseMicrophoneInCarSoon()
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
        releaseMicrophoneInCarSoon()
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
                var waits = 0
                while self.capture.isArming, waits < 40 {
                    waits += 1
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if self.startPendingRequestIfAny(attempt: attempt) { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            ZoneLog.coordinator.error("requestChanged: no fresh request seen within 1 s")
        }
    }

    /// Returns true once the request was acted on (started, refused, or redirected to the app).
    private func startPendingRequestIfAny(attempt: Int) -> Bool {
        guard let request = store.request, request.schema == ZoneContract.schemaVersion else { return false }
        if request.id == lastHandledRequestID { return false }
        if let current = currentRequest, current.id == request.id { return false }
        guard let status = store.status, status.requestID == request.id, status.phase == .requested else {
            return false
        }
        lastHandledRequestID = request.id
        ZoneLog.coordinator.info("request \(request.id.uuidString.prefix(8), privacy: .public) seen on attempt \(attempt)")
        if meetingCaptureActive {
            // Refused with a reason the keyboard shows; the meeting keeps recording.
            publishStatus(.failed, for: request, message: Self.meetingRefusal)
            return true
        }
        if retryingAudioID != nil {
            publishStatus(.failed, for: request, message: Self.retryRefusal)
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
        }
        capture.onInterruption = { [weak self] interruption in
            self?.handleInterruption(interruption)
        }
        capture.onLevel = { [weak self] level in
            guard let self, case .recording = self.activity else { return }
            if self.currentOrigin == .keyboard { self.levelChannel.send(self.isPaused ? 0 : level) }
            self.islandMeter.append(self.isPaused ? 0 : level)
            self.appendLevel(level)
            self.watchForQuiet(level)
        }
    }

    private func handleInterruption(_ interruption: AudioCaptureEngine.Interruption) {
        RecordingSafetyNotice.disarm() // Zone is alive and handles this itself.
        ZoneLog.audio.info("interruption \(String(describing: interruption), privacy: .public) armed=\(self.isArmed) busy=\(self.activity.isBusy)")
        if meetingCaptureActive {
            onMeetingInterruption?(interruption)
            return
        }
        let state = micStateForInterruption
        switch interruption {
        case .began, .mediaServicesReset:
            let cause: String
            if case .began(let reason) = interruption { cause = reason } else { cause = "mediaServicesReset" }
            switch InterruptionPolicy.began(state) {
            case .hold:
                holdRecording(cause: cause)
            case .standDown:
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
            lastError = error.localizedDescription
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
        capture.startRecording()
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
                    return try self.beginUserUtterance()
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
        if settled {
            Task {
                let durable = await Self.commitHistory {
                    $0.finish(id: requestID, text: text, audioSeconds: seconds, status: wasNote ? .note : .finished,
                              interruptions: interruptions > 0 ? interruptions : nil)
                }
                try? await writer?.finish()
                try? await Task.detached(priority: .utility) {
                    try storage.complete(requestID, text: text, discardShortEmpty: true)
                    if durable { try storage.consumeTextReceipt(requestID) }
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
                                           message: "A new dictation started before this one finished. Transcribe the saved audio to get every word.")
                }.value
                await self.refreshAudioRecovery()
            }
        }
        if wasNote, settled, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastSavedNote = notes.add(textStyle.apply(text, personalWords: personalWords, systemWords: systemWords,
                                                            spokenCorrections: settings.spokenCorrections, emoticons: settings.spokenEmoticons, smallOrdinals: settings.smallOrdinals, california: settings.californiaMode, misheard: settings.misheard))
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
            libraryError = "\(model.shortName): \(error.localizedDescription)"
        }
        libraryDownloadTasks[model] = nil
        libraryDownloads[model] = nil
        libraryRevision += 1
        // The model in use (or a waiting keyboard request) loads as soon as its files are here,
        // instead of staying "missing" until Zone next comes to the foreground.
        if model == selectedModel, !modelIsReady, engine.assetsPresent() || pendingColdRequestID != nil {
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
        if isDeletingModels { return "Removing model files…" }
        if diagnosticOperations > 0 { return "Finish or cancel the model test before deleting models." }
        if activity.isBusy || startingNote || clipSink != nil { return "Finish the current recording or transcription before deleting models." }
        if meetingCaptureActive || MeetingCoordinator.current?.isRecording == true || MeetingCoordinator.current?.isStartingRecording == true || MeetingCoordinator.current?.isFinishingRecording == true {
            return "Finish the meeting recording before deleting models."
        }
        if MeetingCoordinator.current?.transcribingID != nil { return "Finish or cancel the meeting transcription before deleting models." }
        if retryingAudioID != nil { return "Finish or cancel the audio retry before deleting models." }
        if preparationTask != nil || isSwitchingEngine || armingSessions > 0 { return "Wait for the speech model to finish getting ready before deleting models." }
        if !libraryDownloads.isEmpty { return "Wait for model downloads to finish before deleting models." }
        return nil
    }

    /// Switching unloads the engine: it would discard a dictation in progress and fail a
    /// meeting mid-transcription. The bake-off switches itself and is debug-only.
    var modelSwitchBlocker: String? {
        if activity.isBusy || startingNote || clipSink != nil { return "Finish the current recording or transcription before switching models." }
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
        let before = models.reduce(Int64(0)) { $0 + modelBytesOnDisk($1) }
        await ModelDownloader.shared.preventWritesAndCancel(in: models.compactMap(\.assetDirectory))
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
            } catch { errors.append("\(model.shortName): \(error.localizedDescription)") }
        }
        if models.contains(selectedModel) {
            modelState = engine.assetsPresent() ? .loading : .missing
            publishSession()
        }
        let remaining = models.reduce(Int64(0)) { $0 + modelBytesOnDisk($1) }
        let freed = max(0, before - remaining)
        if !errors.isEmpty { libraryError = "Could not remove all files. " + errors.joined(separator: " ") }
        if !automatic || before > 0 {
            libraryNotice = "\(freed.byteCountLabel) freed. Your recordings and transcripts are kept."
        }
        Journal.log("modelStorageCleanup", ["automatic": String(automatic), "models": models.map(\.rawValue).joined(separator: ","),
                                           "freedBytes": String(freed), "failures": String(errors.count)])
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

    /// Records a bakeoff clip through the production capture path (same tap, same 16 kHz
    /// conversion). Arms the microphone if no session is running and releases it afterwards.
    func startClipCapture() async throws {
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
        capture.onSamples = { sink.append($0) }
        capture.startRecording()
    }

    private func checkClipCaptureAllowed() throws {
        guard !isDeletingModels else { throw SpeechEngineError.unavailable("Model storage is being cleaned.") }
        guard !meetingCaptureActive else { throw SpeechEngineError.unavailable(Self.meetingRefusal) }
        switch activity {
        case .recording, .transcribing: throw SpeechEngineError.unavailable("A dictation is running.")
        default: break
        }
    }

    func stopClipCapture() -> [Float] {
        guard let sink = clipSink else { return [] }
        capture.stopRecording()
        capture.onSamples = nil
        clipSink = nil
        if clipArmedCapture, !isArmed {
            disarmCapture()
        }
        clipArmedCapture = false
        return sink.take()
    }

    // MARK: Meetings

    /// Why a meeting cannot start right now, or nil when it can.
    var meetingStartRefusal: String? {
        if isDeletingModels { return "Wait for model cleanup to finish before starting a meeting." }
        if activity.isBusy || startingNote { return "Finish the dictation first, then start the meeting." }
        if retryingAudioID != nil { return "Finish or cancel the audio retry first." }
        if clipSink != nil { return "A test clip is recording." }
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
        store.request = nil
        store.status = nil
        store.result = nil
        store.control = nil
        store.ledger = InsertionLedger()
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
            let records = try await Task.detached(priority: .utility) {
                try storage.expire(activeIDs: active)
                return try storage.records().filter { $0.state == .failed || $0.state == .textReady || $0.state == .retrying }
            }.value
            guard generation == audioRefreshGeneration else { return }
            audioRecoveryRecords = records
        } catch {
            guard generation == audioRefreshGeneration else { return }
            audioRecoveryWarning = "Temporary recordings could not be refreshed. Existing files were kept."
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

    func deleteAudioRecovery(_ id: UUID) {
        guard id != audioRecordID, id != retryingAudioID else { return }
        let storage = audioRecoveryStore
        // A banner about this recording would otherwise outlive the card it described.
        if let message = audioRecoveryRecords.first(where: { $0.id == id })?.message {
            if audioRecoveryWarning == message { audioRecoveryWarning = nil }
            if case .failed(let failure) = activity, failure == message { activity = .idle }
        }
        audioRecoveryRecords.removeAll { $0.id == id }
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

    private func retainAudioFailure(_ id: UUID, text: String, message: String) {
        guard audioRecordID == id else { return }
        let writer = audioWriter
        audioWriter = nil; audioRecordID = nil
        let storage = audioRecoveryStore
        Task {
            try? await writer?.finish()
            do { try await Task.detached(priority: .utility) { try storage.markFailed(id, text: text, message: message) }.value }
            catch { audioRecoveryWarning = "Audio recovery may be incomplete. Storage could not save its status." }
            await refreshAudioRecovery()
        }
    }

    private func finalizeAudio(_ id: UUID, text: String, historyDurable: Bool) async {
        guard audioRecordID == id else { return }
        let storage = audioRecoveryStore
        do {
            try await Task.detached(priority: .utility) {
                try storage.complete(id, text: text, discardShortEmpty: true)
                if historyDurable { try storage.consumeTextReceipt(id) }
            }.value
        } catch AudioRecoveryError.emptyTranscript {
            // The recovery card already says so; a second banner with the same words is noise.
        } catch { audioRecoveryWarning = error.localizedDescription }
        if audioRecordID == id { audioWriter = nil; audioRecordID = nil }
        await refreshAudioRecovery()
    }

    func retryAudioRecovery(_ record: AudioRecoveryRecord) {
        guard !activity.isBusy, retryingAudioID == nil, modelIsReady, !isDeletingModels else { return }
        retryingAudioID = record.id
        activity = .transcribing(requestID: record.id)
        audioRetryTask = Task {
            let storage = audioRecoveryStore
            var retrySession: UtteranceSession?
            do {
                let saved = try await Task.detached(priority: .utility) { try storage.beginRetry(record.id) }.value
                try Task.checkCancellation()
                refreshSpeechVocabulary()
                engine.setContextHints("")
                let session = try beginUserUtterance()
                retrySession = session
                utterance = session
                let request = DictationRequest(id: saved.id, generation: 0, createdAt: saved.createdAt,
                                               inputSession: "audio-recovery", contextBefore: nil)
                currentRequest = request
                currentOrigin = .app
                activity = .transcribing(requestID: saved.id)
                let reader = try AudioRecoveryReader(url: storage.audioURL(saved.id))
                while true {
                    try Task.checkCancellation()
                    if let failure = session.failure { throw failure }
                    if session.availableAudioSamples < 4_096 {
                        try await Task.sleep(for: .milliseconds(20))
                        continue
                    }
                    let samples = try await Task.detached(priority: .utility) { try reader.read() }.value
                    if samples.isEmpty { break }
                    try Task.checkCancellation()
                    session.feed(samples)
                    liveTranscript = session.textSoFar
                }
                let text = try await session.finish()
                try Task.checkCancellation()
                let seconds = session.audioSeconds, engineName = engine.kind.rawValue
                let durable = await Self.commitHistory {
                    // Dated now, so it is the newest item, and marked with when it was recorded.
                    $0.finish(id: saved.id, text: text, audioSeconds: seconds,
                              status: saved.source == .note ? .note : .finished, engine: engineName, source: saved.source,
                              recoveredFrom: saved.createdAt)
                }
                try Task.checkCancellation()
                // Keep original PCM on cancellation/failure until final text has its receipt.
                // A short, atomic commit after the final cancellation check. No suspension
                // between commit and publishing success can turn a cancelled retry into deletion.
                try storage.complete(saved.id, text: text)
                var noteSaved = false
                if saved.source == .note {
                    lastSavedNote = notes.add(textStyle.apply(text, personalWords: personalWords, systemWords: systemWords,
                                                            spokenCorrections: settings.spokenCorrections, emoticons: settings.spokenEmoticons, smallOrdinals: settings.smallOrdinals, california: settings.californiaMode, misheard: settings.misheard))
                    noteSaved = lastSavedNote != nil
                }
                if durable || noteSaved { try? storage.consumeTextReceipt(saved.id) }
                let result = DictationResult(requestID: saved.id, generation: 0, text: text, audioSeconds: seconds,
                                             createdAt: Date(), inputSession: "audio-recovery")
                lastResult = result
                lastResultWasNote = saved.source == .note
                lastResultWasAudioRetry = true
                liveTranscript = text
                if saved.source == .note && !noteSaved {
                    let message = "The audio was transcribed, but the note could not be saved. The transcript is kept in recovery or History."
                    audioRecoveryWarning = message
                    activity = .failed(message)
                } else {
                    activity = .finished(result, origin: .app)
                }
            } catch {
                retrySession?.cancel()
                let partial = retrySession?.textSoFar ?? record.text
                let message = Task.isCancelled ? "Retry cancelled. The original recording is still available." : error.localizedDescription
                try? await Task.detached(priority: .utility) { try storage.markFailed(record.id, text: partial, message: message) }.value
                if retryingAudioID == record.id { activity = Task.isCancelled ? .idle : .failed(message) }
                if !Task.isCancelled { audioRecoveryWarning = message }
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
