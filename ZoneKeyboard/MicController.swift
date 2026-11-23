// by zayd/cold @ zayd.wtf

import Foundation
import Observation
import ZoneCore
import UIKit

/// The mic button's state machine. It never records: it writes a request for the app, waits
/// for the app's status, and inserts the result exactly once when the field still matches.
@MainActor
@Observable
final class MicController {
    enum State: Equatable {
        case needsFullAccess
        case idle
        case requesting
        case recording(startedAt: Date)
        case transcribing
        /// The app had to be opened; the user finishes there and comes back.
        case inApp
        case pendingInsert(DictationResult, reason: String)
        case recovery(DictationResult)
        case inserted(text: String)
        /// The last insertion was undone; Redo puts it back.
        case undone(text: String)
        case error(String)

        /// The states that show the style pill, so the style row may open over them.
        var allowsStyleChoice: Bool {
            switch self {
            case .idle, .inserted, .undone, .error: return true
            default: return false
            }
        }
    }

    private(set) var state: State = .idle {
        didSet {
            if case .recording = state {} else { isPaused = false }
            // Unsure words belong to the insert on screen; anything else ends them.
            if case .inserted = state {} else if !doubts.isEmpty || doubtReview != nil {
                doubts = []
                doubtReview = nil
            }
            updateLevelSampling()
            updateStatusPolling()
        }
    }
    private(set) var sessionIsArmed = false
    /// Set when the warm path could not start the mic. The keyboard never opens Zone by itself from
    /// the warm path; the user's next tap on the mic does, because they asked.
    private var opensAppOnNextTap = false
    private var lastDecisionLog: String?
    /// Dictations inserted so far, read from the shared store when the keyboard appears.
    /// Existing onboarding state remains available, but it no longer hides style or mode controls.
    private(set) var dictationsInserted = 0
    static let trainingDictations = 3
    /// The keyboard's own record from before the count was shared: someone who has dictated is past training.
    private static let insertedBeforeKey = "hasInsertedDictation"

    var isLearning: Bool { dictationsInserted < Self.trainingDictations }
    /// Recent microphone levels, newest last, for the listening surface.
    private(set) var levels: [Float] = Array(repeating: 0, count: 32)
    /// A gentle hint after eight continuous seconds of low input; it never stops recording.
    private(set) var hearsNothing = false
    /// The current recording is held: the app drops audio until Resume.
    private(set) var isPaused = false
    /// The app's level posts while a recording is on screen (see `LevelChannel`).
    private var levelSubscription: LevelChannel.Subscription?
    private var quietMonitor = QuietInputMonitor(startedAt: 0)
    private var levelRecordingStart: Date?
    private var statusPollTask: Task<Void, Never>?
    private var pingRereadTask: Task<Void, Never>?
    private var presenceTick = 0

    /// Style applied at insertion, chosen in the strip and shared through the store.
    private(set) var style: TextStyle = .casual

    /// Type (the key rows) or dictate (the compact surface). Read from the store when the
    /// keyboard appears, toggled with the keyboard key on either face, written back on a toggle.
    private(set) var mode: KeyboardMode = .type
    /// The controller animates its height constraint here.
    var onModeChanged: ((KeyboardMode) -> Void)?
    /// The typing model's Shift, read at insertion; `.automatic` until the controller wires it.
    var dictationOpening: () -> DictationOpening = { .automatic }
    /// Tells the typing model a dictation used the cursor, so a one-shot Shift is spent.
    var onDictationInserted: ((String) -> Void)?
    #if DEBUG && targetEnvironment(simulator)
    /// Locks the typing model's Shift (fixture `capslock`), wired by the controller.
    var lockShift: (() -> Void)?
    #endif

    func toggleMode() {
        setMode(mode.toggled, persist: true)
    }

    private func setMode(_ next: KeyboardMode, persist: Bool) {
        guard next != mode else { return }
        history = nil
        mode = next
        if persist { savedMode.mode = next }
        haptic(.light)
        onModeChanged?(next)
    }

    /// States whose controls take priority in the strip. They never replace the key rows.
    var showsSurface: Bool {
        switch state {
        case .recording, .transcribing, .pendingInsert, .recovery: return true
        default: return false
        }
    }

    /// The recent-dictations panel. Nil while closed.
    enum HistoryPanel: Equatable {
        case loading
        case needsFullAccess
        /// Full Access is on but the shared container is not (`unreachableMessage`).
        case unreachable
        /// Retention is off and nothing (not even a cut-off rescue) is kept.
        case off
        case loaded([TranscriptRecord])
    }

    private(set) var history: HistoryPanel?

    /// The panel takes the keys' place unless a dictation's own surface needs it.
    var showsHistory: Bool { history != nil && !showsSurface }

    static let historyPanelLimit = 30

    private let store: SharedStore
    private weak var proxy: TextProxyActions?
    private let feedback: KeyFeedback
    private var ownedRequestID: UUID?
    private var isVisible = false
    private var requiresExplicitInsert = false
    /// The last dictation this keyboard inserted, for a spoken "Scratch that" that arrives as its
    /// own dictation. Checked against the text before the cursor, like Undo, before anything goes.
    private var lastInsertedDictation: String?

    /// Up to three words of the last insert the engine was least sure of, shown beside Undo
    /// (`DoubtfulWords`, Beta). Each is one tap from its alternatives.
    private(set) var doubts: [DoubtfulWords.Placement] = []

    /// A flagged word whose alternatives are open in the strip.
    struct DoubtReview: Equatable {
        let placement: DoubtfulWords.Placement
        let options: [String]
    }
    private(set) var doubtReview: DoubtReview?
    private var ownedGeneration = 0
    /// When this keyboard sent Stop for the owned request. Until the app reports
    /// `transcribing`, its status still says `recording`; within `stopGrace` that is the app
    /// catching up, not a reason to show the recording (and the Stop key) again.
    private var stopIssuedAt: Date?
    static let stopGrace: TimeInterval = 3
    private var waitTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var returnRereadTask: Task<Void, Never>?
    /// The request that had to open Zone (the cold path). Its result is always offered, never
    /// inserted on its own: this keyboard instance can survive the trip, and an insert made before
    /// the field is live again goes nowhere yet still marks the result consumed.
    /// Process-wide: iOS can create a second keyboard controller after the return while the first
    /// is still around, and the new one must know this request went through Zone too.
    private static var openedAppForRequest: UUID?
    private var openedAppForRequest: UUID? {
        get { Self.openedAppForRequest }
        set { Self.openedAppForRequest = newValue }
    }

    /// How long the warm path waits for a live app to report `recording` before opening it.
    /// The heartbeat already proved the process is alive, so this only bounds a stuck app.
    static let warmPathTimeout: Duration = .seconds(3)
    /// Extra time granted once the app acknowledges with `starting`.
    static let startingGrace: Duration = .seconds(5)
    static let transcriptionWatchdog: Duration = .seconds(20)
    /// Typing a key ends the window early, so it can stay long enough to be found.
    static let undoWindow: Duration = .seconds(20)

    /// Full Access reads on but the shared container is out of reach, so a request written now would
    /// never reach Zone, which would find no request ("That didn't work"). Two causes: iOS has not applied Full Access to this running
    /// keyboard yet, or the app and keyboard were signed with different App Groups.
    static let unreachableMessage = "Can't reach the Zone app yet. Close this app and reopen it."

    /// Checked on each appearance and each tap, not cached: access can arrive while the keyboard lives.
    private var appGroupReachable: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return AppGroup.isReachable
        #endif
    }

    init(store: SharedStore, proxy: TextProxyActions, feedback: KeyFeedback) {
        self.store = store
        self.proxy = proxy
        self.feedback = feedback
        self.savedMode = LocalKeyboardMode(store: store)
        // The saved face from the start, so the first height the system sees is the right one.
        mode = savedMode.mode
    }

    /// The face is the keyboard's own setting, kept in its own container (`LocalKeyboardMode`).
    private let savedMode: LocalKeyboardMode

    // MARK: Lifecycle hooks from the controller

    /// The saved face, from `viewWillAppear`, so the appearance sets one height. Reads only the
    /// shared store; everything that reads the host waits for `keyboardDidAppear`.
    func restoreStoredMode() {
        setMode(savedMode.mode, persist: false)
    }

    /// The host's document is live (see `TextProxyGate`): from the controller's
    /// first proof of it in each appearance, which can be after `viewWillAppear` by a slide-in.
    func keyboardDidAppear() {
        guard let proxy else { return }
        isVisible = true
        history = nil
        setMode(savedMode.mode, persist: false)
        #if DEBUG && targetEnvironment(simulator)
        startFixtureWatch() // Screenshot fixtures only; never polls storage on a phone.
        #endif
        if !proxy.hasOpenAccess {
            // The real value, every time, so onboarding never checks off on a stale "on". On a
            // device without Full Access the App Group is out of reach and this write is lost, so
            // the app must also treat an old lastSeen as unknown.
            store.keyboardPresence = KeyboardPresence(lastSeen: Date(), hasFullAccess: false)
            state = .needsFullAccess
            return
        }
        if case .needsFullAccess = state { state = .idle }
        #if !targetEnvironment(simulator)
        KeyboardLog.journal?.log("appGroupCheck", AppGroup.diagnostics())
        #endif
        guard appGroupReachable else {
            KeyboardLog.mic.error("full access on, App Group \(ZoneContract.appGroup, privacy: .public) unreachable")
            state = .error(Self.unreachableMessage)
            return
        }
        if case .error(Self.unreachableMessage) = state { state = .idle }
        store.keyboardPresence = KeyboardPresence(lastSeen: Date(), hasFullAccess: true)
        // Whatever a crash or an abandoned request left in the shared store goes now.
        store.purgeStalePayloads()
        dictationsInserted = UserDefaults.standard.bool(forKey: Self.insertedBeforeKey)
            ? max(store.dictationsInserted, Self.trainingDictations)
            : store.dictationsInserted
        // The latest style choice, from the Z or the app's Settings.
        style = store.effectiveTextStyle()
        handleSessionChanged()
        restoreActiveRequest()
        updateStatusPolling()
        updateLevelSampling()
        evaluateResult()
        rereadAfterReturn()
    }

    /// The host's text changed. If a dictation is out in Zone, this is often the first sign the user
    /// came back without the keyboard reappearing, so look for the result again.
    func hostTextChanged() {
        switch state {
        case .inApp:
            evaluateResult()
            rereadAfterReturn()
        case .requesting, .recording, .transcribing:
            // These states already receive result notifications and poll every 250 ms.
            // Host callbacks can arrive for every typed key; restarting the cold-return
            // loop here adds synchronous shared-store reads and duplicate polling to typing.
            break
        default:
            break
        }
    }

    /// From `viewDidAppear`, once the document is live, when Full Access and the App Group read
    /// reliably. `keyboardDidAppear` runs at the first proof the document is live, which can come
    /// before access settles; if it concluded "no Full Access" or "can't reach the app" then,
    /// nothing else rechecked for the whole appearance (the mic key is hidden in that state), so
    /// the strip asked for a permission already granted.
    func accessSettled() {
        guard isVisible, let proxy, proxy.hasOpenAccess else { return }
        switch state {
        case .needsFullAccess, .error(Self.unreachableMessage):
            KeyboardLog.mic.info("access settled after an early refusal; checking again")
            keyboardDidAppear()
        default:
            break
        }
    }

    /// Coming back from Zone (the cold path), the app's result can reach this process a moment after
    /// the keyboard reappears, and the resultReady ping was posted while the keyboard was suspended,
    /// so it never arrived. Re-read the store for a few seconds until the result is offered.
    private func rereadAfterReturn() {
        returnRereadTask?.cancel()
        guard store.request?.id == ownedRequestID || store.result != nil else { return }
        returnRereadTask = Task { [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, !Task.isCancelled else { return }
                switch self.state {
                case .pendingInsert, .recovery, .inserted, .error, .needsFullAccess:
                    return
                default:
                    _ = self.applyStatus()
                    self.evaluateResult()
                }
            }
        }
    }

    func userTypedKey() {
        // Typing while recording/recognizing must not cancel capture. The existing result
        // destination/context guard offers a deliberate Insert if these edits changed the field.
        switch state {
        case .inserted, .undone, .error:
            state = .idle
        default:
            break
        }
    }

    func chooseStyle(_ choice: TextStyle) {
        store.chooseTextStyle(choice)
        style = choice
        haptic(.light)
    }

    func tapRedo() {
        guard case .undone(let text) = state, let proxy else { return }
        cancelTimers()
        proxy.insert(text)
        lastInsertedDictation = text
        haptic(.light)
        state = .inserted(text: text)
        if isLearning {
            dictationsInserted += 1
            store.dictationsInserted = dictationsInserted
        }
        scheduleIdle(after: Self.undoWindow)
    }

    // MARK: Taps

    func tapMic() {
        requestDictation(fromHold: false)
    }

    /// A tap on the mic, or a hold on space with Hold space set to Talk. A hold never opens Zone:
    /// the finger is still down, so a request Zone cannot take in place is dropped and explained.
    private func requestDictation(fromHold: Bool) {
        guard let proxy else { return }
        proxy.userTouchedKeyboard()
        history = nil
        guard proxy.hasOpenAccess else {
            state = .needsFullAccess
            return
        }
        guard appGroupReachable else {
            KeyboardLog.mic.error("mic tap with App Group \(ZoneContract.appGroup, privacy: .public) unreachable")
            state = .error(Self.unreachableMessage)
            haptic(.light)
            return
        }
        switch state {
        case .requesting, .recording, .transcribing:
            return
        default:
            break
        }
        // Only a tap on the error that said so opens Zone; once it fades, the warm path is tried again.
        var tapOpensApp = false
        if case .error = state, !fromHold { tapOpensApp = opensAppOnNextTap }
        opensAppOnNextTap = false
        cancelTimers()
        let generation = max(store.ledger.droppedGeneration, ownedGeneration) + 1
        let request = DictationRequest(
            id: UUID(),
            generation: generation,
            createdAt: Date(),
            inputSession: proxy.currentInputSession(),
            contextBefore: proxy.contextBefore().map { String($0.suffix(64)) })
        ownedRequestID = request.id
        stopIssuedAt = nil
        requiresExplicitInsert = false
        openedAppForRequest = nil
        ownedGeneration = generation
        // A new dictation supersedes any older result, used or not. One left behind (an
        // interrupted take, an offer that was never answered) was offered again when the
        // keyboard was rebuilt mid-recording and pasted the previous dictation. History keeps it.
        if let stale = store.result, stale.requestID != request.id {
            store.result = nil
        }
        store.control = nil
        // Stamp presence before the app can start recording. The app's keyboard-gone check
        // runs one second in, before the first poll stamp, and would otherwise see the stamp
        // from when this keyboard appeared and stop any dictation started 12 s later.
        store.keyboardPresence = KeyboardPresence(lastSeen: Date(), hasFullAccess: true)
        store.request = request
        store.status = DictationStatus(requestID: request.id, generation: generation, phase: .requested, updatedAt: Date(), message: nil)
        DarwinNotifier.post(.requestChanged)
        state = .requesting
        haptic(.medium)

        let sessionAlive = store.session?.isAlive(now: Date()) ?? false
        KeyboardLog.mic.info("request \(request.id.uuidString.prefix(8), privacy: .public) posted, sessionAlive=\(sessionAlive)")
        KeyboardLog.journal?.log("keyboardRequest", recording: request.id,
                                 ["sessionAlive": String(sessionAlive), "opensApp": String((!sessionAlive || tapOpensApp) && !fromHold),
                                  "fromHold": String(fromHold)])
        guard sessionAlive, !tapOpensApp else {
            if fromHold {
                // The session lapsed between the hold's check and this request.
                failWarmRequest(message: SpaceTalk.notReadyMessage)
            } else {
                openApp(for: request.id)
            }
            return
        }
        // The session is alive, so the user expects to stay in this app: a slow answer is retried
        // once and then reported here. The keyboard never bounces to Zone on its own from the warm
        // path; a later tap on the mic decides that.
        waitTask = Task { [weak self] in
            for attempt in 0..<2 {
                if attempt > 0 {
                    KeyboardLog.mic.info("warm wait expired for \(request.id.uuidString.prefix(8), privacy: .public); asking again")
                    DarwinNotifier.post(.requestChanged)
                }
                var deadline = ContinuousClock.now + Self.warmPathTimeout
                var acknowledged = false
                while !Task.isCancelled, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(80))
                    guard let self else { return }
                    if self.applyStatus() { return }
                    if !acknowledged, self.appAcknowledged(request.id) {
                        acknowledged = true
                        deadline = ContinuousClock.now + Self.startingGrace
                    }
                }
                guard let self, !Task.isCancelled, case .requesting = self.state else { return }
            }
            guard let self, !Task.isCancelled, case .requesting = self.state else { return }
            KeyboardLog.mic.info("warm wait expired twice for \(request.id.uuidString.prefix(8), privacy: .public); staying here")
            self.failWarmRequest()
        }
    }

    /// Drops a request Zone never picked up, so a late start cannot record, and says so in the strip.
    private func failWarmRequest(message: String = "Zone didn't answer. Tap the mic to open it.") {
        guard let id = ownedRequestID else { return }
        var ledger = store.ledger
        ledger.droppedGeneration = max(ledger.droppedGeneration, ownedGeneration)
        store.ledger = ledger
        store.control = DictationControl(requestID: id, generation: ownedGeneration, action: .cancel, issuedAt: Date())
        DarwinNotifier.post(.controlChanged)
        store.clearPayloads(for: id)
        ownedRequestID = nil
        opensAppOnNextTap = true
        state = .error(message)
        haptic(.light)
        scheduleIdle(after: .seconds(8))
    }

    // MARK: Hold space to talk (Beta)

    /// The request a hold on space asked for. Letting go stops it; nil when no hold owns one.
    private var holdRequestID: UUID?

    /// What the space bar shows while a hold owns a dictation.
    var spaceTalkPhase: SpaceTalk.Phase {
        guard let id = holdRequestID, id == ownedRequestID else { return .none }
        switch state {
        case .requesting: return .starting
        case .recording: return .listening
        default: return .none
        }
    }

    /// Zone can start listening without the keyboard opening it.
    private var zoneListensInPlace: Bool {
        store.session?.isAlive(now: Date()) ?? false
    }

    /// The space bar was held still for `SpaceTalk.holdDuration` with Hold space set to Talk.
    /// True when the hold is talking's (it asked for a dictation or explained why it could not);
    /// false when there is nothing to talk with and the hold should move the cursor instead.
    func spaceHoldBegan() -> Bool {
        guard let proxy else { return false }
        let underWay: Bool
        switch state {
        case .requesting, .recording, .transcribing, .inApp: underWay = true
        default: underWay = false
        }
        let decision = SpaceTalk.start(hasFullAccess: proxy.hasOpenAccess, appGroupReachable: appGroupReachable,
                                       dictationUnderWay: underWay, zoneListensInPlace: zoneListensInPlace)
        KeyboardLog.journal?.log("spaceHold", ["decision": String(describing: decision)])
        switch decision {
        case .moveCursor:
            return false
        case .explainNotReady:
            proxy.userTouchedKeyboard()
            history = nil
            cancelTimers()
            // The mic's next tap opens Zone, which is what the message asks for.
            opensAppOnNextTap = true
            state = .error(SpaceTalk.notReadyMessage)
            haptic(.light)
            scheduleIdle(after: .seconds(6))
            return true
        case .talk:
            requestDictation(fromHold: true)
            if case .requesting = state, let id = ownedRequestID { holdRequestID = id }
            return true
        }
    }

    /// The finger that held space lifted, or its touch was cancelled.
    func spaceHoldEnded() {
        let phase = spaceTalkPhase
        holdRequestID = nil
        switch SpaceTalk.release(phase) {
        case .stop:
            tapStop()
        case .withdrawTooSoon:
            tapCancel()
            state = .error(SpaceTalk.tooSoonMessage)
            haptic(.light)
            scheduleIdle(after: .seconds(5))
        case .nothing:
            break
        }
        KeyboardLog.journal?.log("spaceHoldEnded", ["phase": String(describing: phase)])
    }

    // MARK: History

    func showHistory() {
        guard let proxy, proxy.hasOpenAccess else {
            history = .needsFullAccess
            return
        }
        history = .loading
        // A file read and JSON decode: off the main thread so the keyboard never stalls on it.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let panel: HistoryPanel
            if let store = TranscriptHistory.shared {
                // An app killed mid-dictation and not reopened since: rescue its text here too.
                store.recoverCutOff()
                let records = store.recent(limit: Self.historyPanelLimit)
                panel = records.isEmpty && store.retention == .off ? .off : .loaded(records)
            } else {
                panel = .unreachable
            }
            DispatchQueue.main.async {
                guard let self, self.history == .loading else { return }
                self.history = panel
            }
        }
    }

    func hideHistory() {
        history = nil
    }

    /// Puts a past dictation at the cursor as it was recognized, with the usual spacing, and offers
    /// Undo like any insertion.
    func reinsert(_ record: TranscriptRecord) {
        guard let proxy else { return }
        let text = TextJoiner.join(contextBefore: proxy.contextBefore(), transcript: record.text, capitalizeSentences: false)
        guard !text.isEmpty else { return }
        cancelTimers()
        proxy.insert(text)
        history = nil
        haptic(.light)
        state = .inserted(text: text)
        scheduleIdle(after: Self.undoWindow)
    }

    /// Notes where a dictation went, off the main thread; the history file is small but shared.
    private func markHistory(_ id: UUID, _ status: TranscriptStatus) {
        DispatchQueue.global(qos: .utility).async {
            TranscriptHistory.shared?.mark(id: id, status: status)
        }
    }

    func tapStop() {
        guard case .recording = state, let id = ownedRequestID else { return }
        store.control = DictationControl(requestID: id, generation: ownedGeneration, action: .stop, issuedAt: Date())
        DarwinNotifier.post(.controlChanged)
        KeyboardLog.journal?.log("keyboardStop", recording: id)
        stopIssuedAt = Date()
        state = .transcribing
        haptic(.light)
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(for: Self.transcriptionWatchdog)
            guard let self, !Task.isCancelled, case .transcribing = self.state else { return }
            self.evaluateResult()
            if self.applyStatus() { return }
            guard case .transcribing = self.state else { return }
            self.state = .error("Zone did not answer. Open the app to check.")
            self.scheduleIdle(after: .seconds(4))
        }
    }

    /// Holds or resumes the recording. The app gates audio on its side; here the meter rests
    /// and the clock gives way to "Paused" so the state is visible at a glance.
    func tapPause() {
        guard case .recording = state, let id = ownedRequestID else { return }
        isPaused.toggle()
        store.control = DictationControl(requestID: id, generation: ownedGeneration,
                                         action: isPaused ? .pause : .resume, issuedAt: Date())
        DarwinNotifier.post(.controlChanged)
        KeyboardLog.journal?.log(isPaused ? "keyboardPause" : "keyboardResume", recording: id)
        haptic(.light)
    }

    func tapCancel() {
        cancelTimers()
        guard let id = ownedRequestID else {
            state = .idle
            return
        }
        var ledger = store.ledger
        ledger.droppedGeneration = max(ledger.droppedGeneration, ownedGeneration)
        store.ledger = ledger
        store.control = DictationControl(requestID: id, generation: ownedGeneration, action: .cancel, issuedAt: Date())
        DarwinNotifier.post(.controlChanged)
        // A cancelled request's typed context has no further use.
        store.clearPayloads(for: id)
        ownedRequestID = nil
        state = .idle
    }

    func tapInsert() {
        switch state {
        case .pendingInsert(let result, _), .recovery(let result):
            insert(result)
        default:
            break
        }
    }

    /// Drops a pending result for good so it is not offered again.
    func tapDismissPending() {
        switch state {
        case .pendingInsert(let result, _), .recovery(let result):
            var ledger = store.ledger
            ledger.consumedResultID = result.requestID
            ledger.claimedResultID = nil
            ledger.claimedAt = nil
            store.ledger = ledger
            store.clearPayloads(for: result.requestID)
            DarwinNotifier.post(.payloadConsumed)
            // Gone from the handoff store, kept in history: a dismissed dictation can still be rescued.
            markHistory(result.requestID, .dismissed)
            state = .idle
        default:
            break
        }
    }

    func tapUndo() {
        guard case .inserted(let text) = state, let proxy else { return }
        cancelTimers()
        guard let count = UndoPlan.deletionCount(contextBefore: proxy.contextBefore(), lastInserted: text) else {
            state = .error("Text changed, so undo is off.")
            scheduleIdle(after: .seconds(3))
            return
        }
        for _ in 0..<count {
            proxy.deleteBackward()
        }
        state = .undone(text: text)
        scheduleIdle(after: Self.undoWindow)
    }

    // MARK: Darwin pings

    /// The app's write may land after its ping; re-read for up to a second.
    func handleStatusChanged() {
        rereadAfterPing {
            self.restoreActiveRequest()
            return self.applyStatus()
        }
    }

    private func restoreActiveRequest() {
        guard isVisible,
              let request = RecordingRecovery.activeRequest(request: store.request, status: store.status,
                                                             ledger: store.ledger, session: store.session, now: Date()) else { return }
        if ownedRequestID != request.id {
            requiresExplicitInsert = true
            ownedRequestID = request.id
            ownedGeneration = request.generation
            if store.status?.phase == .requested || store.status?.phase == .starting { state = .requesting }
        }
        _ = applyStatus()
    }

    func handleResultReady() {
        rereadAfterPing {
            let before = self.state
            self.evaluateResult()
            return self.state != before
        }
    }

    /// Called by the controller when iOS takes the keyboard off screen mid-dictation.
    func keyboardWillDisappear() {
        // Hold space records only while held, and the keyboard going away ends the hold.
        if holdRequestID != nil { spaceHoldEnded() }
        isVisible = false
        #if DEBUG && targetEnvironment(simulator)
        fixtureTask?.cancel()
        #endif
        if ownedRequestID != nil { requiresExplicitInsert = true }
        cancelTimers()
        returnRereadTask?.cancel()
        returnRereadTask = nil
        updateStatusPolling()
        updateLevelSampling()
    }

    private func rereadAfterPing(_ settle: @escaping @MainActor () -> Bool) {
        guard isVisible else { return }
        pingRereadTask?.cancel()
        pingRereadTask = Task { [weak self] in
            for _ in 0..<10 {
                guard self != nil, !Task.isCancelled else { return }
                if settle() { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// While a dictation is in flight, poll the store as a backstop to the pings, and stamp
    /// presence so the app knows this keyboard is still on screen.
    private func updateStatusPolling() {
        guard isVisible else {
            statusPollTask?.cancel()
            statusPollTask = nil
            return
        }
        switch state {
        case .recording, .transcribing, .requesting:
            guard statusPollTask == nil else { return }
            statusPollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled, let self, self.isVisible else { return }
                    self.presenceTick += 1
                    if self.presenceTick % 8 == 1 {
                        self.store.keyboardPresence = KeyboardPresence(lastSeen: Date(), hasFullAccess: true)
                    }
                    if self.applyStatus() { continue }
                    self.evaluateResult()
                }
            }
        default:
            statusPollTask?.cancel()
            statusPollTask = nil
        }
    }

    func handleSessionChanged() {
        guard isVisible else { return }
        sessionIsArmed = store.session?.isAlive(now: Date()) ?? false
    }

    // MARK: Internals

    private func appAcknowledged(_ requestID: UUID) -> Bool {
        guard let status = store.status, status.requestID == requestID else { return false }
        return status.phase == .starting
    }

    /// Returns true when the status settled the requesting phase (recording started or failed).
    @discardableResult
    private func applyStatus() -> Bool {
        guard let status = store.status, let id = ownedRequestID, status.requestID == id,
              status.generation == ownedGeneration,
              status.generation > store.ledger.droppedGeneration else { return false }
        let seen = "\(id.uuidString.prefix(8)) \(status.phase.rawValue) \(status.paused ?? false)"
        if seen != lastStatusLog {
            lastStatusLog = seen
            KeyboardLog.journal?.log("keyboardSawStatus", recording: id,
                                     ["phase": status.phase.rawValue, "paused": String(status.paused ?? false)])
        }
        if RecordingRecovery.lostContact(status: status, session: store.session, now: Date()) {
            // Release local controls. A slow or suspended app can still finish and offer its result.
            requiresExplicitInsert = true
            cancelTimers()
            ownedRequestID = nil
            opensAppOnNextTap = true
            state = .error("Zone stopped responding. Tap the mic to try again.")
            scheduleIdle(after: .seconds(8))
            if store.result?.requestID == id { evaluateResult() }
            return true
        }
        switch status.phase {
        case .requested, .starting:
            return false
        case .recording:
            waitTask?.cancel()
            // The app owns pause; a keyboard opened mid-recording learns it here.
            if let paused = status.paused, paused != isPaused { isPaused = paused }
            if case .recording = state { return true }
            if case .transcribing = state, let stopped = stopIssuedAt,
               Date().timeIntervalSince(stopped) < Self.stopGrace { return true }
            KeyboardLog.mic.info("recording confirmed for \(id.uuidString.prefix(8), privacy: .public)")
            state = .recording(startedAt: status.updatedAt)
            // A held space bar has no wave under the finger: this tap says talk now.
            if holdRequestID == id { haptic(.light) }
            return true
        case .transcribing:
            waitTask?.cancel()
            if case .transcribing = state { return true }
            state = .transcribing
            return true
        case .interrupted:
            cancelTimers()
            if store.result?.requestID == id {
                evaluateResult()
            } else {
                // A restarted app can terminalize an old request without a completed result.
                // Do not leave this still-mounted keyboard displaying a live recording.
                state = .error(status.message ?? "Recording was interrupted. Check History for recovered text.")
                scheduleIdle(after: .seconds(4))
            }
            return true
        case .ready:
            waitTask?.cancel()
            evaluateResult()
            return true
        case .needsApp:
            waitTask?.cancel()
            if case .requesting = state {
                failWarmRequest(message: "Zone has to be open to start the mic. Tap the mic to open it.")
            }
            return true
        case .failed:
            cancelTimers()
            state = .error(status.message ?? "Dictation failed.")
            scheduleIdle(after: .seconds(4))
            return true
        case .cancelled:
            cancelTimers()
            state = .idle
            return true
        }
    }

    /// The last status written to the recording log, so a 150 ms re-read logs a change once.
    private var lastStatusLog = ""

    private func evaluateResult() {
        guard isVisible else { return }
        guard let result = store.result else { return }
        // While a dictation of ours is live, only its own result may surface.
        if let owned = ownedRequestID, result.requestID != owned {
            switch state {
            case .recording, .transcribing, .requesting: return
            default: break
            }
        }
        // Already on offer: later re-reads must not change the caption or the state.
        switch state {
        case .pendingInsert(let offered, _) where offered.requestID == result.requestID: return
        case .recovery(let offered) where offered.requestID == result.requestID: return
        default: break
        }
        let request = store.request.flatMap { $0.id == result.requestID ? $0 : nil }
        let owns = result.requestID == ownedRequestID
        var decision = InsertionDecider.decide(
            result: result,
            request: request,
            ledger: store.ledger,
            currentInputSession: proxy?.currentInputSession(),
            currentContextBefore: proxy?.contextBefore(),
            ownsRequest: owns)
        if decision == .insertNow, store.status?.phase == .interrupted, store.status?.requestID == result.requestID {
            decision = .offerInsert(reason: "Recording was interrupted")
        }
        if requiresExplicitInsert, result.requestID == ownedRequestID, decision == .insertNow {
            decision = .offerInsert(reason: "Keyboard was reopened")
        }
        if openedAppForRequest == result.requestID {
            switch decision {
            case .insertNow, .offerInsert:
                decision = .offerInsert(reason: "Dictated in Zone")
            default:
                break
            }
        }
        // The store is re-read every 150 ms after a return; log a result's decision once, not 20 times.
        let logLine = "\(result.requestID.uuidString.prefix(8)) owns=\(owns) decision=\(String(describing: decision))"
        if logLine != lastDecisionLog {
            lastDecisionLog = logLine
            KeyboardLog.mic.info("result \(logLine, privacy: .public)")
            KeyboardLog.journal?.log("keyboardResult", recording: result.requestID,
                                     ["owns": String(owns), "decision": String(describing: decision),
                                      "audio": JournalFormat.seconds(result.audioSeconds)])
        }
        switch decision {
        case .insertNow:
            watchdogTask?.cancel()
            insert(result)
        case .offerInsert(let reason):
            watchdogTask?.cancel()
            state = .pendingInsert(result, reason: reason)
            markHistory(result.requestID, .offered)
        case .offerRecovery:
            watchdogTask?.cancel()
            state = .recovery(result)
            markHistory(result.requestID, .offered)
        case .ignore(let reason):
            if reason == "stale" {
                markConsumed(result.requestID)
            } else if owns, reason == "no speech" {
                watchdogTask?.cancel()
                markConsumed(result.requestID)
                state = .error("No speech detected.")
                scheduleIdle(after: .seconds(3))
            }
        }
    }

    private func insert(_ result: DictationResult) {
        guard let proxy else { return }
        style = store.effectiveTextStyle()
        let vocabulary = try? PersonalVocabulary.shared?.document()
        let personalWords = vocabulary?.appliedWords ?? []
        let handleRecognition = store.keyboardPreferences.handleRecognition
        let spokenCorrections = store.keyboardPreferences.spokenCorrections
        let emoticons = store.keyboardPreferences.spokenEmoticons
        let smallOrdinals = store.keyboardPreferences.smallOrdinals
        let california = store.keyboardPreferences.californiaMode
        let systemWords = (try? SystemLexiconStore.shared?.snapshot().speechWords) ?? []
        // "Scratch that" said on its own takes back the dictation before it, with the Beta on.
        if spokenCorrections, SpokenRepair.isStandaloneCommand(result.text) {
            scratchPreviousDictation(for: result)
            return
        }
        let misheard = vocabulary?.misheard ?? [:]
        let text = proxy.capitalization.dictated(style.insertion(
            of: result.text,
            contextBefore: proxy.contextBefore(),
            fieldCapitalizesSentences: proxy.autocapitalizesSentences, personalWords: personalWords,
            opening: dictationOpening(), mentions: handleRecognition,
            handles: vocabulary?.handles ?? [], systemWords: systemWords,
            spokenCorrections: spokenCorrections,
            capsLockDropsPunctuation: store.keyboardPreferences.capsLockDropsPunctuation, emoticons: emoticons,
            smallOrdinals: smallOrdinals, california: california, searchField: proxy.isSearchField, misheard: misheard))
        guard !text.isEmpty else {
            markConsumed(result.requestID)
            state = .idle
            return
        }
        var ledger = store.ledger
        ledger.claimedResultID = result.requestID
        ledger.claimedAt = Date()
        store.ledger = ledger

        proxy.insert(text)
        lastInsertedDictation = text
        if handleRecognition { PersonalVocabulary.learnHandles(taughtIn: result.text, renderedText: text, personalWords: personalWords, knownHandles: vocabulary?.handles ?? []) }
        onDictationInserted?(text)

        ledger.consumedResultID = result.requestID
        ledger.claimedResultID = nil
        ledger.claimedAt = nil
        store.ledger = ledger
        // Undo and Redo work from the inserted text held here, not from the store.
        store.clearPayloads(for: result.requestID)
        DarwinNotifier.post(.payloadConsumed)
        markHistory(result.requestID, .inserted)

        haptic(.light)
        state = .inserted(text: text)
        flagDoubts(result.doubts, in: text)
        scheduleIdle(after: reviewWindow)
    }

    // MARK: Unsure words

    #if DEBUG && targetEnvironment(simulator)
    /// A fixture's `[word:0.4]` marks stand in for the engine's confidence, and turn the check on.
    private var fixtureForcesDoubts = false
    #endif

    /// Reading a message back to find a misheard word takes longer than deciding to undo it, so
    /// while unsure words show the strip keeps them a minute. Any key still ends them at once.
    static let doubtWindow: Duration = .seconds(60)
    private var reviewWindow: Duration { doubts.isEmpty ? Self.undoWindow : Self.doubtWindow }

    private var checksDoubts: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if fixtureForcesDoubts { return true }
        #endif
        return store.keyboardPreferences.checksDoubtfulWords
    }

    /// The words flagged in the dictation last inserted that no tap in the strip has settled.
    /// They outlive the strip (any key closes it) so a fix made by hand still counts.
    private var unsettledDoubts: [DoubtfulWords.Placement] = []

    private func flagDoubts(_ heard: [DoubtfulWord]?, in text: String) {
        unsettledDoubts = []
        guard checksDoubts, let heard, !heard.isEmpty else { return }
        doubts = DoubtfulWords.place(DoubtStore.calibration.select(heard), in: text)
        unsettledDoubts = doubts
        guard !doubts.isEmpty else { return }
        KeyboardLog.journal?.log("doubtsFlagged", ["count": String(doubts.count),
                                                   "confidence": doubts.map { String(format: "%.2f", $0.confidence) }.joined(separator: ",")])
    }

    /// Opens a flagged word's alternatives. The Undo window waits while they are open.
    func openDoubt(_ placement: DoubtfulWords.Placement) {
        guard case .inserted(let text) = state, doubts.contains(placement) else { return }
        expiryTask?.cancel()
        let personal = (try? PersonalVocabulary.shared?.document().appliedWords) ?? []
        let options = DoubtfulWords.alternatives(for: placement.word, previous: Self.word(before: placement, in: text),
                                                 corrector: SpellingStore.current, personalWords: personal,
                                                 memory: DoubtStore.memory)
        doubtReview = DoubtReview(placement: placement, options: options)
    }

    func closeDoubt() {
        guard doubtReview != nil else { return }
        doubtReview = nil
        scheduleIdle(after: reviewWindow)
    }

    /// The flagged word was right: it leaves the strip, and its confidence band counts one keep.
    func keepDoubt() {
        guard let review = doubtReview else { return }
        DoubtStore.calibration.record(confidence: review.placement.confidence, fixed: false)
        KeyboardLog.journal?.log("doubtKept", ["confidence": String(format: "%.2f", review.placement.confidence)])
        doubts.removeAll { $0 == review.placement }
        unsettledDoubts.removeAll { $0.word == review.placement.word }
        doubtReview = nil
        haptic(.light)
        scheduleIdle(after: reviewWindow)
    }

    /// Writes `replacement` over the flagged word. The keyboard deletes back to the word and types
    /// the rest of the dictation again, the way Undo deletes it, so no host has to move its cursor.
    /// Refused when the field no longer ends with the dictation's tail.
    func fixDoubt(with replacement: String) {
        guard case .inserted(let text) = state, let review = doubtReview, let proxy else { return }
        let placement = review.placement
        let tail = DoubtfulWords.tail(of: placement, in: text)
        guard let edit = DoubtfulWords.replacing(placement, with: replacement, in: text, placements: doubts),
              UndoPlan.deletionCount(contextBefore: proxy.contextBefore(), lastInserted: text) != nil else {
            state = .error("Text changed, so the fix is off.")
            scheduleIdle(after: .seconds(3))
            return
        }
        for _ in 0..<tail.count { proxy.deleteBackward() }
        proxy.insert(String(edit.text.suffix(tail.count - placement.word.count + replacement.count)))
        lastInsertedDictation = edit.text
        DoubtStore.calibration.record(confidence: placement.confidence, fixed: true)
        // Remembered the way the dictionary writes it: "Here" chosen at a sentence start is
        // offered as "here" mid-sentence, while a name keeps its capital.
        let display = SpellingStore.current?.words.lookup(replacement)?.display
        DoubtStore.memory.record(heard: placement.word,
                                 chosen: display.map { $0.lowercased() == replacement.lowercased() ? $0 : replacement } ?? replacement)
        KeyboardLog.journal?.log("doubtFixed", ["confidence": String(format: "%.2f", placement.confidence),
                                                "option": String((review.options.firstIndex(of: replacement) ?? -1) + 1)])
        haptic(.light)
        state = .inserted(text: edit.text)
        doubtReview = nil
        doubts = edit.placements
        unsettledDoubts.removeAll { $0.word == placement.word }
        scheduleIdle(after: reviewWindow)
    }

    /// A dictated word was replaced by hand with Zone's keys (selected and retyped, or backspaced
    /// and retyped) instead of through the strip. The check counts it all the same: the chosen
    /// word is offered first the next time this one is heard, and a word that was underlined
    /// counts as a fix for its confidence band. Without this only strip taps were counted, so
    /// every hand fix of an underlined word went missing and the bands read as more right than
    /// they are. Words from anything but the dictation last inserted are ignored, and nothing is
    /// stored but the two words and a count.
    func wordCorrectedByHand(original: String, replacement: String) {
        guard store.keyboardPreferences.checksDoubtfulWords, let dictated = lastInsertedDictation,
              DoubtfulWords.contains(original, in: dictated) else { return }
        DoubtStore.memory.record(heard: original, chosen: replacement)
        let flagged = unsettledDoubts.firstIndex { DoubtfulWords.sameWord($0.word, original) }
        if let flagged {
            DoubtStore.calibration.record(confidence: unsettledDoubts[flagged].confidence, fixed: true)
            unsettledDoubts.remove(at: flagged)
        }
        KeyboardLog.journal?.log("doubtFixedByHand", ["flagged": flagged == nil ? "no" : "yes"])
    }

    /// The word before a flagged one in the same sentence, for the word-pair table.
    static func word(before placement: DoubtfulWords.Placement, in text: String) -> String? {
        let start = text.count - placement.charactersAfter - placement.word.count
        guard start > 0 else { return nil }
        return SwipeSpacing.previousWord(before: String(text.prefix(start)))
    }

    /// Removes the previous dictation when the text before the cursor still ends with it, the
    /// same check Undo makes. Edited text, or nothing inserted yet, leaves the field alone.
    private func scratchPreviousDictation(for result: DictationResult) {
        markConsumed(result.requestID)
        markHistory(result.requestID, .dismissed)
        guard let proxy, let previous = lastInsertedDictation else {
            state = .error("Nothing to scratch.")
            scheduleIdle(after: .seconds(3))
            return
        }
        guard let count = UndoPlan.deletionCount(contextBefore: proxy.contextBefore(), lastInserted: previous) else {
            state = .error("Edited, so kept.")
            scheduleIdle(after: .seconds(3))
            return
        }
        for _ in 0..<count { proxy.deleteBackward() }
        lastInsertedDictation = nil
        haptic(.light)
        state = .undone(text: previous)
        scheduleIdle(after: Self.undoWindow)
    }

    private func markConsumed(_ id: UUID) {
        var ledger = store.ledger
        ledger.consumedResultID = id
        store.ledger = ledger
        store.clearPayloads(for: id)
        DarwinNotifier.post(.payloadConsumed)
    }

    private func openApp(for requestID: UUID) {
        waitTask?.cancel()
        openedAppForRequest = requestID
        state = .inApp
        proxy?.open(ZoneContract.dictateURL(requestID: requestID))
    }

    private func scheduleIdle(after delay: Duration) {
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            switch self.state {
            case .inserted, .undone, .error:
                self.state = .idle
            default:
                break
            }
        }
    }

    /// While a recording is on screen, each level the app posts advances the meter by one
    /// sample (about 20 a second). Nothing polls: no post, no work.
    private func updateLevelSampling() {
        guard isVisible else {
            stopLevelSampling()
            levelRecordingStart = nil
            return
        }
        if case .recording(let startedAt) = state {
            guard !isSamplingLevels || levelRecordingStart != startedAt else { return }
            stopLevelSampling()
            levelRecordingStart = startedAt
            hearsNothing = false
            quietMonitor = QuietInputMonitor(startedAt: ProcessInfo.processInfo.systemUptime)
            #if DEBUG && targetEnvironment(simulator)
            if fixtureDrivesLevels || fixtureConstantLevel != nil {
                startFixtureLevels()
                return
            }
            #endif
            levelSubscription = LevelChannel.Subscription { [weak self] level in
                self?.appendLevel(level)
            }
        } else {
            stopLevelSampling()
            levelRecordingStart = nil
            hearsNothing = false
            if case .transcribing = state { return }
            levels = Array(repeating: 0, count: 32)
        }
    }

    private var isSamplingLevels: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if fixtureLevelTask != nil { return true }
        #endif
        return levelSubscription != nil
    }

    private func stopLevelSampling() {
        levelSubscription?.cancel()
        levelSubscription = nil
        #if DEBUG && targetEnvironment(simulator)
        fixtureLevelTask?.cancel()
        fixtureLevelTask = nil
        #endif
    }

    private func appendLevel(_ sample: Float) {
        guard isVisible, case .recording = state else { return }
        let latest = isPaused ? 0 : sample
        var next = levels
        next.removeFirst()
        next.append(min(max(latest, 0), 1))
        levels = next
        if isPaused {
            quietMonitor = QuietInputMonitor(startedAt: ProcessInfo.processInfo.systemUptime)
            hearsNothing = false
        } else {
            hearsNothing = quietMonitor.sample(level: latest, at: ProcessInfo.processInfo.systemUptime)
        }
    }

    private func cancelTimers() {
        waitTask?.cancel()
        watchdogTask?.cancel()
        expiryTask?.cancel()
        pingRereadTask?.cancel()
        waitTask = nil
        watchdogTask = nil
        expiryTask = nil
        pingRereadTask = nil
    }

    #if DEBUG && targetEnvironment(simulator)
    private var fixtureDrivesLevels = false
    private var fixtureConstantLevel: Float?
    private var fixtureLevelTask: Task<Void, Never>?

    /// A fixture stands in for the app: a constant level or a synthetic envelope at 20 Hz.
    private func startFixtureLevels() {
        fixtureLevelTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self else { return }
                tick += 1
                self.appendLevel(self.fixtureConstantLevel ?? Self.fixtureEnvelope(tick: tick))
            }
        }
    }

    private static func fixtureEnvelope(tick: Int) -> Float {
        let t = Double(tick) * 0.05
        return Float(0.3 + 0.5 * (0.5 + 0.5 * sin(t * 6.1)) * (0.6 + 0.4 * sin(t * 1.7)))
    }

    private var fixtureTask: Task<Void, Never>?
    private var lastFixtureText: String?

    /// Polls the fixture file while the keyboard is up (screenshots only; see KeyboardFixture).
    private func startFixtureWatch() {
        fixtureTask?.cancel()
        fixtureTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self, let text = KeyboardFixture.readFile(), text != self.lastFixtureText {
                    self.lastFixtureText = text
                    let fixture = KeyboardFixture.parse(text)
                    // A dictation is delivered once. Left in place, a keyboard that relaunches would
                    // read the same file as new and insert the text a second time.
                    if fixture.say != nil { KeyboardFixture.removeFile() }
                    self.apply(fixture)
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    func apply(_ fixture: KeyboardFixture) {
        if let said = fixture.say {
            cancelTimers()
            let marked = KeyboardFixture.doubtMarks(in: said)
            fixtureForcesDoubts = !marked.doubts.isEmpty
            insert(DictationResult(requestID: UUID(), generation: 1, text: marked.text, audioSeconds: 3,
                                   createdAt: Date(), inputSession: nil, doubts: marked.doubts.isEmpty ? nil : marked.doubts))
            fixtureForcesDoubts = false
            return
        }
        if fixture.capsLock { lockShift?() }
        // Look tokens apply on their own too, so `accent-ice` alone recolors without a state.
        FlowingWave.debugShading = fixture.waveShading.flatMap(FlowingWave.Shading.init(rawValue:))
        if let accent = fixture.accent, accent != AccentChoice.current {
            AccentChoice.current = accent
            KeyboardTheme.refreshAccent()
        }
        guard fixture.state != nil || fixture.mode != nil else { return }
        cancelTimers()
        store.result = nil
        ownedRequestID = nil
        if let mode = fixture.mode { setMode(mode, persist: false) }
        guard let fixed = fixture.state else { return }
        sessionIsArmed = true
        dictationsInserted = Self.trainingDictations
        fixtureDrivesLevels = false
        fixtureConstantLevel = nil
        hearsNothing = false
        switch fixed {
        case .idle:
            state = .idle
        case .starting:
            state = .requesting
        case .live:
            state = .recording(startedAt: Date().addingTimeInterval(-3))
        case .listening:
            fixtureDrivesLevels = true
            levels = KeyboardFixture.sampleLevels(count: levels.count)
            state = .recording(startedAt: Date().addingTimeInterval(-4))
        case .quiet, .low, .mid, .high:
            let level: Float = switch fixed { case .low: 0.15; case .mid: 0.5; case .high: 1; default: 0 }
            fixtureConstantLevel = level
            levels = Array(repeating: level, count: levels.count)
            state = .recording(startedAt: Date().addingTimeInterval(-12))
            hearsNothing = fixed == .quiet
        case .transcribing:
            levels = KeyboardFixture.sampleLevels(count: levels.count)
            state = .transcribing
        case .inserted:
            state = .inserted(text: KeyboardFixture.sampleText)
        case .noFullAccess:
            state = .needsFullAccess
        case .micDenied:
            state = .error("Zone can't use the microphone. Open Zone to allow it.")
        case .pending:
            let result = DictationResult(requestID: UUID(), generation: 1, text: KeyboardFixture.sampleText,
                                         audioSeconds: 6, createdAt: Date(), inputSession: nil)
            state = .pendingInsert(result, reason: "Dictated in Zone")
        }
    }
    #endif

    /// Full Access is needed for the Taptic Engine in a keyboard, and the app's Haptics switch
    /// wins; both are the flags KeyFeedback caches on each appearance.
    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        feedback.impact(style)
    }
}
