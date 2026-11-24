// by zayd/cold @ zayd.wtf

import Foundation
import UIKit
import ZoneCore

/// Whoever shows a dictation the keyboard records by itself: the `MicController` on screen.
@MainActor
protocol LocalDictationObserver: AnyObject {
    func localDictation(_ request: DictationRequest, reported update: LocalDictationHost.Update)
}

/// The process-wide owner of a dictation the keyboard records by itself (`LocalDictation`).
///
/// iOS makes a new keyboard controller for nearly every appearance and can release the old one
/// while its dictation is still being recognized. So the dictation, its recognition and its
/// delivery belong here, not to a controller: the words reach History and the shared store and
/// the result-ready ping goes out whether or not any controller is left to show them. A
/// controller only observes (`observer`, weak) and asks for start, stop, pause and cancel.
///
/// While the microphone is live it also holds the `KeyboardRecordingClaim` in the shared
/// store, refreshed every second, so an Action Button press or the island's Dictate never arms
/// Zone's own microphone over it. Recognition, after the microphone is off, does not hold it.
@MainActor
final class LocalDictationHost {
    enum Update: Equatable {
        case started
        case level(Float, finishIn: Int?)
        case paused(Bool)
        /// The microphone is off and recognition began.
        case recognizing
        /// The text is in History. `published`: it is also this request's result in the shared
        /// store; false when a newer request or result was there first.
        case delivered(published: Bool)
        case savedForZone
        case failed(String)
    }

    static let shared = LocalDictationHost(store: UserDefaultsSharedStore(), dictation: LocalDictation(), preferenceReader: .shared)

    /// `EngineKind.appleSpeech`'s raw value: the keyboard does not link the app's engine list.
    static let engineName = KeyboardCapture.historyEngine
    private static let failuresKey = "zone.keyboard.localCaptureFailures"
    private static let lastDictatedKey = "zone.keyboard.localLastDictated"

    let store: SharedStore
    let preferenceReader: KeyboardSettingReader
    let dictation: LocalDictating
    weak var observer: LocalDictationObserver?
    /// The dictation in flight: starting, recording, or being recognized.
    private(set) var request: DictationRequest?
    /// The microphone is live (recording or paused): the claim is held.
    private(set) var isRecording = false
    /// The microphone is off and the words are being recognized.
    private(set) var isRecognizing = false
    /// How often the claim's heartbeat is refreshed and the limits are checked.
    var claimRefresh: Duration = .seconds(KeyboardRecordingClaim.refresh)

    private let defaults: UserDefaults
    private var epoch: Data?
    private let writeHistory: (DictationResult, String, Data?, Date?, Date?, @escaping @MainActor (Bool) -> Void) -> Void
    private let now: () -> Date
    private var quietSamplesFrom: TimeInterval = 0
    private var microphoneMeter = QuietVoiceMeter()
    private var quietFinish: SilenceFinish?
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var startedAt: Date?
    private var userPaused = false
    private var mutedCapture: UUID?
    var openAfterStuckMute = false
    private var held = false
    private var pausedSince: Date?
    private var tick: Task<Void, Never>?
    /// A kept recording being recognized once more; its outcome never counts toward the hold-off.
    private var retrying: UUID?
    private var retryStatsStart: Date?
    private var retried: Set<UUID> = []
    /// Requests whose recognition failed, so a retry in the same process keeps their field.
    private var keptRequests: [UUID: DictationRequest] = [:]

    /// - Parameter writeHistory: writes the record off the main thread, then calls back on it,
    ///   so the result reaches the store only once History holds it (the insert marks it).
    init(store: SharedStore, dictation: LocalDictating, defaults: UserDefaults = .standard, preferenceReader: KeyboardSettingReader? = nil,
         writeHistory: ((DictationResult, String, Data?, Date?, Date?, @escaping @MainActor (Bool) -> Void) -> Void)? = nil,
         now: @escaping () -> Date = Date.init) {
        self.preferenceReader = preferenceReader ?? KeyboardSettingReader(store: store, defaults: defaults)
        self.store = store
        let last = LastKeyboardPreferences()
        (dictation as? LocalDictation)?.allowsAppleSpeech = { [store] in
            if let group = store as? UserDefaultsSharedStore {
                return !last.resolve(stored: group.storedKeyboardPreferences).neverAppleSpeech
            }
            return !store.keyboardPreferences.neverAppleSpeech
        }
        self.dictation = dictation
        self.defaults = defaults
        self.now = now
        self.writeHistory = writeHistory ?? { result, engine, epoch, start, recoveredFrom, done in
            DispatchQueue.global(qos: .userInitiated).async {
                let committed = KeyboardCapture.whileLibraryCurrent(in: KeyboardCapture.group, epoch: epoch) {
                    let history = TranscriptHistory.shared
                    let outcome = history?.finishOutcome(id: result.requestID, text: result.text, audioSeconds: result.audioSeconds,
                                            engine: engine, source: .keyboard, recoveredFrom: recoveredFrom, statsStartedAt: start)
                    return outcome == .stored || outcome == .retentionOff
                }
                Task { @MainActor in done(committed) }
            }
        }
        dictation.onEvent = { [weak self] id, event in self?.handle(event, id: id) }
    }

    var isBusy: Bool { request != nil }
    /// The capture page is loaded: a start has only the microphone left to open.
    var isPrepared: Bool { dictation.isPrepared }

    /// When the keyboard's own microphone last started, kept in the keyboard's defaults
    /// (`KeyboardCapture.preloads`).
    private(set) var lastDictated: Date? {
        get { defaults.object(forKey: Self.lastDictatedKey) as? Date }
        set { defaults.set(newValue, forKey: Self.lastDictatedKey) }
    }

    /// Dictations that failed here in a row, kept in the keyboard's own defaults.
    var failures: KeyboardCapture.Failures {
        get {
            defaults.data(forKey: Self.failuresKey)
                .flatMap { try? JSONDecoder().decode(KeyboardCapture.Failures.self, from: $0) } ?? .init()
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.failuresKey) }
    }

    func prepare(in host: UIView) {
        dictation.prepare(in: host)
    }

    /// Starts `request`. A dictation still in flight (a recording nobody could stop, a retry)
    /// is cancelled first: the newest tap wins and only one recorder ever runs.
    func start(_ request: DictationRequest, in host: UIView, observer: LocalDictationObserver) {
        if isBusy {
            KeyboardLog.journal?.log("keyboardLocalSuperseded", recording: self.request?.id)
            cancel(discardAudio: false)
        }
        epoch = KeyboardCapture.eraseEpoch(in: KeyboardCapture.group)
        self.request = request
        self.observer = observer
        isRecognizing = false
        dictation.start(id: request.id, in: host)
    }

    func stop() {
        guard request != nil else { return }
        dictation.stop()
    }

    func setPaused(_ paused: Bool) {
        guard isRecording else { return }
        userPaused = paused
        if !paused, held { dictation.recoverInput() }
        applyPause()
    }

    private func applyPause() {
        guard let request, isRecording else { return }
        let paused = userPaused || held
        guard paused != (pausedSince != nil) else { return }
        quietFinish?.restartWait(at: uptime())
        dictation.setPaused(paused)
        pausedSince = paused ? now() : nil
        observer?.localDictation(request, reported: .paused(paused))
        if paused { observer?.localDictation(request, reported: .level(0, finishIn: nil)) }
    }

    /// Drops the dictation in flight. No update follows and nothing counts as a failure.
    func cancel(discardAudio: Bool = true) {
        guard request != nil else { return }
        dictation.cancel(discardAudio: discardAudio)
        endMicrophone()
        if let request { keptRequests[request.id] = nil }
        request = nil
        retrying = nil
        retryStatsStart = nil
        isRecognizing = false
        observer = nil
    }

    /// The web view goes with the keyboard; a recognition in flight does not need it.
    func release() {
        dictation.release()
    }

    /// A new controller takes over showing the recognition in flight. False when there is none
    /// with this id.
    @discardableResult
    func adopt(_ observer: LocalDictationObserver, for id: UUID) -> Bool {
        guard request?.id == id, isRecognizing else { return false }
        self.observer = observer
        return true
    }

    /// Recognizes a recording kept after a failed recognition, once, when nothing else runs.
    /// Its text is offered like a late result.
    func retryKeptRecording(in host: UIView? = nil) {
        guard !isBusy, let id = dictation.keptRecording(excluding: retried) else { return }
        // Once per process: a retry a new tap interrupted waits for the next keyboard process.
        epoch = KeyboardCapture.eraseEpoch(in: KeyboardCapture.group)
        retried.insert(id)
        retryStatsStart = keptRequests[id]?.createdAt ?? dictation.keptStart(id: id)
        request = keptRequests.removeValue(forKey: id)
            ?? DictationRequest(id: id, generation: 0, createdAt: now(), inputSession: nil, contextBefore: nil)
        retrying = id
        observer = nil
        isRecognizing = true
        if let host { dictation.prepare(in: host) }
        if !dictation.retryKept(id: id) {
            // An unreadable file: nothing will report back, so nothing may stay "recognizing".
            request = nil
            retrying = nil
            retryStatsStart = nil
            isRecognizing = false
        }
    }

    // MARK: Events

    private func handle(_ event: LocalDictationEvent, id: UUID) {
        guard let request, request.id == id else { return }
        switch event {
        case .started:
            microphoneMeter = QuietVoiceMeter()
            beginMicrophone(for: request)
            lastDictated = now()
            observer?.localDictation(request, reported: .started)
            applyPause()
        case .stuckMuted:
            mutedCapture = id
            openAfterStuckMute = true
            failures.recordFailure(now: now())
        case .held(let value):
            held = value
            applyPause()
        case .samples(let rms):
            let time = uptime()
            let reading = pausedSince == nil ? microphoneMeter.reading(rms: rms, at: time) : (display: 0, detection: 0)
            var countdown: Int?
            if isRecording, pausedSince == nil, time >= quietSamplesFrom, let wait = quietFinish?.wait {
                switch quietFinish?.sample(level: reading.detection, at: time) {
                case .finish:
                    quietFinish = nil
                    KeyboardLog.journal?.log("keyboardQuietFinish", recording: id, ["wait": JournalFormat.seconds(wait)])
                    dictation.stop()
                    return
                case .quiet(let remaining):
                    countdown = SilenceFinish.countdown(remaining: remaining, wait: wait)
                default: break
                }
            }
            observer?.localDictation(request, reported: .level(reading.display, finishIn: countdown))
        case .recognizing:
            endMicrophone()
            isRecognizing = true
            observer?.localDictation(request, reported: .recognizing)
        case .finished(let text, let audioSeconds, let module, let doubts):
            if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ZoneContract.appGroup),
               KeyboardCapture.hasEraseRequest(in: group) {
                dictation.saved(id, durable: true)
                cancel()
                return
            }
            endMicrophone()
            isRecognizing = false
            let wasRetry = retrying == id
            let statsStart = wasRetry ? retryStatsStart : request.createdAt
            self.request = nil
            retrying = nil
            retryStatsStart = nil
            let observer = self.observer
            self.observer = nil
            if failures.count > 0, mutedCapture != id { failures = .init() }
            let result = DictationResult(requestID: id, generation: KeyboardCapture.publishedGeneration(of: request, ledger: store.ledger),
                                         text: text, audioSeconds: audioSeconds, createdAt: now(), inputSession: request.inputSession, doubts: doubts)
            // History first, whatever happens next: the words are never only in memory.
            let recordingEpoch = epoch
            writeHistory(result, KeyboardCapture.historyEngine(for: module), recordingEpoch, statsStart,
                         wasRetry ? statsStart : nil) { [self] historySaved in
                var published = false
                let commit = {
                    published = self.publish(result, for: request)
                    return published && self.store.synchronizeResult(result)
                }
                let resultSaved = store is InMemorySharedStore ? commit()
                    : KeyboardCapture.whileLibraryCurrent(in: KeyboardCapture.group, epoch: recordingEpoch, commit)
                dictation.saved(id, durable: historySaved && resultSaved && !text.isEmpty)
                observer?.localDictation(request, reported: .delivered(published: published))
            }
        case .savedForZone:
            endMicrophone()
            isRecognizing = false
            self.request = nil
            retrying = nil
            let observer = self.observer
            self.observer = nil
            observer?.localDictation(request, reported: .savedForZone)
        case .failed(let message, _):
            endMicrophone()
            isRecognizing = false
            let wasRetry = retrying == id
            self.request = nil
            retrying = nil
            retryStatsStart = nil
            let observer = self.observer
            self.observer = nil
            if !wasRetry {
                // Only a real capture or speech-model error reaches this event.
                if mutedCapture != id { failures.recordFailure(now: now()) }
                if dictation.keptRecording(excluding: []) == id { keptRequests[id] = request }
            }
            observer?.localDictation(request, reported: .failed(message))
        }
    }

    /// Puts the result in the shared store as an ordinary one, unless a newer request or result
    /// is already there, and pings every keyboard and the app.
    private func publish(_ result: DictationResult, for request: DictationRequest) -> Bool {
        let original = DictationRequest(id: request.id, generation: result.generation, createdAt: request.tappedAt,
                                        inputSession: request.inputSession, contextBefore: request.contextBefore,
                                        holdToTalk: request.holdToTalk, schema: request.schema)
        guard store.publishFinal(result, for: original) else {
            KeyboardLog.journal?.log("keyboardLocalKeptInHistory", recording: request.id)
            return false
        }
        DarwinNotifier.post(.resultReady)
        return true
    }

    // MARK: The claim

    private func beginMicrophone(for request: DictationRequest) {
        let start = now()
        quietSamplesFrom = uptime() + dictation.startCueDuration
        quietFinish = request.holdToTalk == true ? nil : preferenceReader.current().finishWhenQuietWait.map { SilenceFinish(wait: $0) }
        isRecording = true
        startedAt = start
        pausedSince = nil
        store.keyboardRecordingClaim = KeyboardRecordingClaim(requestID: request.id, since: start, heartbeat: start)
        tick?.cancel()
        tick = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.claimRefresh ?? .seconds(1))
                guard !Task.isCancelled, let self, self.isRecording else { return }
                self.refresh(request.id)
            }
        }
    }

    /// One tick while the microphone is live: the claim's heartbeat, then the limits.
    func refresh(_ id: UUID) {
        guard isRecording, request?.id == id, let startedAt else { return }
        let moment = now()
        if var claim = store.keyboardRecordingClaim, claim.requestID == id {
            claim.heartbeat = moment
            store.keyboardRecordingClaim = claim
        } else {
            store.keyboardRecordingClaim = KeyboardRecordingClaim(requestID: id, since: startedAt, heartbeat: moment)
        }
        let decision = KeyboardCapture.limitDecision(now: moment, startedAt: startedAt, pausedSince: pausedSince)
        guard decision != .keepRecording else { return }
        KeyboardLog.journal?.log("keyboardLocalLimit", recording: id, ["limit": String(describing: decision)])
        dictation.stop()
    }

    private func endMicrophone() {
        userPaused = false
        held = false
        quietFinish = nil
        isRecording = false
        startedAt = nil
        pausedSince = nil
        tick?.cancel()
        tick = nil
        guard let id = request?.id else { return }
        if store.keyboardRecordingClaim?.requestID == id { store.keyboardRecordingClaim = nil }
        store.microphoneOwnership.keyboardStopped(recordingID: id)
    }
}
