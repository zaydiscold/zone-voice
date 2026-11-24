// by zayd/cold @ zayd.wtf

import AVFAudio
import Foundation
import Observation
import ZoneCore
import UIKit

/// The mic button's state machine. It writes a request for the app, waits for the app's status,
/// and inserts the result exactly once when the field still matches. With Zone not keeping the
/// microphone ready it may record in the keyboard instead (`LocalDictationHost`), whose text
/// comes back through the same result path.
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

        var offeredResult: DictationResult? {
            switch self {
            case .pendingInsert(let result, _), .recovery(let result): return result
            default: return nil
            }
        }

        var ownsTypingStrip: Bool {
            switch self {
            case .idle, .inserted, .undone:
                return false
            case .needsFullAccess, .requesting, .recording, .transcribing, .inApp, .pendingInsert, .recovery, .error:
                return true
            }
        }

        var allowsPanel: Bool {
            switch self {
            case .idle, .inserted, .undone, .error, .needsFullAccess, .inApp: return true
            default: return false
            }
        }

        var allowsStyleChoice: Bool {
            switch self {
            case .idle, .inserted, .undone: return true
            default: return false
            }
        }
    }

    private(set) var pressMessage: String?
    private(set) var state: State = .idle {
        didSet {
            if oldValue != state { pressMessage = nil }
            if !state.allowsPanel { panelSection = nil }
            if state.ownsTypingStrip != oldValue.ownsTypingStrip {
                onTypingStripOwnershipChanged?(state.ownsTypingStrip)
            }
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
    /// Seconds until Finish when quiet ends the recording, from the app with each level; nil when
    /// it is off or not counting down. The strip shows it in place of the clock.
    private(set) var quietFinishIn: Int?
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
    /// The view a dictation recorded in the keyboard puts its hidden web view in (`LocalDictation`).
    var captureHost: () -> UIView? = { nil }
    /// Records in the keyboard when Zone is not keeping the microphone ready. Process-wide, so a
    /// dictation outlives the controller that started it (`LocalDictationHost`).
    private let localHost: LocalDictationHost
    /// The request the keyboard itself is recording or recognizing, and this controller shows.
    /// Nothing in the shared store describes it until its text is ready, so the app can never
    /// mistake it for its own. While it is set the local path is authoritative: no app status
    /// changes this controller's state.
    private var localRequest: DictationRequest?
    private var localProbe: Task<Void, Never>?
    /// The app's switches as the keyboard last read them (`LastKeyboardPreferences`), wired by
    /// the controller; an unreadable record must not read as defaults.
    let preferenceReader: KeyboardSettingReader
    func readPreferences() -> KeyboardPreferences { preferenceReader.current() }
    /// Whether this iPhone can record here at all: iOS 26 and Zone's microphone permission.
    private var microphoneObservation = KeyboardCapture.PermissionObservation()
    var localCapability: () -> (systemSupports: Bool, microphoneGranted: Bool?) = {
        let permission = AVAudioApplication.shared.recordPermission
        return (LocalDictation.systemSupports, permission == .undetermined ? nil : permission == .granted)
    }
    /// My words, learned fixes and handles, and the contact and app names iOS knows, as read at
    /// each insertion. The same for every dictation, whoever recorded it.
    var readVocabulary: () -> PersonalVocabulary.Document? = { try? PersonalVocabulary.shared?.document() }
    var readSystemWords: () -> [String] = { (try? SystemLexiconStore.shared?.snapshot().speechWords) ?? [] }
    /// Memory left below iOS's limit for this keyboard, nil where the system gives none.
    var memoryAvailable: () -> UInt64? = { MemoryFootprint.available() }
    private var preloadTask: Task<Void, Never>?
    static let preloadDelay: Duration = .milliseconds(450)
    /// The typing model's Shift, read at insertion; `.automatic` until the controller wires it.
    var dictationOpening: () -> DictationOpening = { .automatic }
    /// Tells the typing model a dictation used the cursor, so a one-shot Shift is spent.
    var onDictationInserted: ((String) -> Void)?
    var onTypingStripOwnershipChanged: ((Bool) -> Void)?
    /// A dictation was taken out of the field again (Undo, a spoken "Scratch that"), so Shift
    /// follows the text that is left. Without it an emptied field kept a lowercase Shift, and the
    /// next thing typed or dictated started without its capital (seen on the simulator, 2026-11-20).
    var onDictationRemoved: (() -> Void)?
    #if DEBUG && targetEnvironment(simulator)
    /// Locks the typing model's Shift (fixture `capslock`), wired by the controller.
    var lockShift: (() -> Void)?
    #endif

    func toggleMode() {
        setMode(mode.toggled, persist: true)
    }

    private func setMode(_ next: KeyboardMode, persist: Bool) {
        guard next != mode else { return }
        panelSection = nil
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

    enum PanelSection: Hashable { case home, styles }
    var panelSection: PanelSection? {
        didSet {
            if mode == .dictate, (panelSection == nil) != (oldValue == nil) {
                onModeChanged?(displayMode)
            }
        }
    }

    /// The menu borrows the tall face without changing the person's keyboard preference.
    var displayMode: KeyboardMode { panelSection == nil ? mode : .type }

    func showPanel(_ section: PanelSection) {
        guard state.allowsPanel else { return }
        hideHistory()
        panelSection = section
    }

    func choosePanelStyle(_ choice: TextStyle) {
        guard panelSection != nil, state.allowsStyleChoice else { return }
        chooseStyle(choice)
        panelSection = nil
    }

    /// Navigation can also be invoked by VoiceOver. Check at the tap, even if the strip has changed.
    func openDestination(_ destination: ZoneContract.Destination) {
        guard state.allowsPanel else { return }
        panelSection = nil
        proxy?.open(destination.url)
    }

    static let historyPanelLimit = 30

    private let store: SharedStore
    private weak var proxy: TextProxyActions?
    private let feedback: KeyFeedback
    private var ownedRequestID: UUID?
    private(set) var isVisible = false
    private var requiresExplicitInsert = false
    /// The last dictation this keyboard inserted, for a spoken "Scratch that" that arrives as its
    /// own dictation. Checked against the text before the cursor, like Undo, before anything goes.
    private var lastInsertedDictation: String?
    private var lastInsertionID: UUID?
    var deliveryHistory: @Sendable () -> TranscriptHistory? = { .shared }
    static let deliveryQueue = DispatchQueue(label: "wtf.zayd.zone.keyboard.delivery", qos: .utility)
    /// The same dictation with what was said and how it was written, so picking another style can
    /// write it again in place (`RestylePlan`). It counts only while `lastInsertedDictation` is
    /// still its text: a word fixed from the strip or a scratch makes it stale.
    private var lastDictation: InsertedDictation?
    /// The dictation as it read before the last style rewrite. Undo puts this back first, so a
    /// rewrite nobody wanted costs one tap and the dictation itself is never lost to it.
    private(set) var beforeRestyle: InsertedDictation?

    /// Undo would put back the previous style's wording instead of removing the dictation.
    var undoRevertsRestyle: Bool {
        guard case .inserted(let text) = state, beforeRestyle != nil else { return false }
        return lastDictation?.inserted == text
    }

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
    /// How long a Zone that looks alive may stay silent before the keyboard records by itself.
    static let silentAppGrace: Duration = .seconds(1)
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

    var quickSettingsReachable: () -> Bool = { AppGroup.isReachable }

    func submitQuickSetting(_ value: QuickSetting) async -> String? {
        guard proxy?.hasOpenAccess == true else { return "Open Settings > Apps > Zone > Keyboards and turn on Allow Full Access." }
        guard quickSettingsReachable(), let inbox = store.quickSettingInbox else { return Self.unreachableMessage }
        do {
            try await preferenceReader.submit(value, inbox: inbox)
            DarwinNotifier.post(.quickSettingChanged)
            return nil
        } catch {
            return "Could not save this setting. Try again."
        }
    }

    var alternateSpeechReady: () -> Bool = {
        let route = KeyboardVoiceRoute.load()
        switch route.mode {
        case .standard: return false
        case .webView: return FluidWebModel.ready
        case .computer: return route.providerURL != nil
        }
    }

    init(store: SharedStore, proxy: TextProxyActions?, feedback: KeyFeedback, localHost: LocalDictationHost? = nil) {
        if proxy != nil, #available(iOS 26, *) { Task { await ZoneModelSpeech.shared.discover() } }
        self.store = store
        self.proxy = proxy
        self.feedback = feedback
        self.localHost = localHost ?? .shared
        self.preferenceReader = localHost?.preferenceReader ?? (store is InMemorySharedStore ? KeyboardSettingReader(store: store) : .shared)
        self.savedMode = LocalKeyboardMode(store: store)
        // The saved face from the start, so the first height the system sees is the right one.
        mode = proxy == nil ? .type : savedMode.mode
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
        // Screenshot fixtures belong to the installed keyboard or its UI harness.
        // An isolated store must not consume commands left by another simulator session.
        if !(store is InMemorySharedStore) { startFixtureWatch() }
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
        if #available(iOS 26, *), !(store is InMemorySharedStore) {
            ZoneModelSpeech.shared.keyboardAppeared(prepares: readPreferences().dictatesInKeyboard && !alternateSpeechReady())
            OwnModelLabRunner.tidyKeyboardCache()
        }
        store.keyboardPresence = KeyboardPresence(lastSeen: Date(), hasFullAccess: true)
        // Whatever a crash or an abandoned request left in the shared store goes now.
        store.purgeStalePayloads()
        dictationsInserted = UserDefaults.standard.bool(forKey: Self.insertedBeforeKey)
            ? max(store.dictationsInserted, Self.trainingDictations)
            : store.dictationsInserted
        // The latest style choice, from the Z or the app's Settings.
        style = store.effectiveTextStyle()
        handleSessionChanged()
        adoptLocalDictation()
        preloadCapturePage()
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

    /// A pick from the style row. It is the style from now on, and a dictation still standing at
    /// the cursor is written again in it, so nobody has to say a message twice to see it another
    /// way.
    func chooseStyle(_ choice: TextStyle) {
        store.chooseTextStyle(choice)
        style = choice
        haptic(.light)
        restyleLastDictation(in: choice)
    }

    /// Writes the last dictation again in `choice` when the field still ends with exactly what was
    /// inserted. Typed-after or edited text, a field that was sent or left, and a dictation that
    /// was undone all leave the field alone.
    private func restyleLastDictation(in choice: TextStyle) {
        guard let proxy, var last = lastDictation, last.inserted == lastInsertedDictation, last.style != choice else { return }
        switch state {
        case .idle, .inserted: break
        default: return
        }
        let vocabulary = try? PersonalVocabulary.shared?.document()
        let systemWords = (try? SystemLexiconStore.shared?.snapshot().speechWords) ?? []
        guard let edit = RestylePlan.edit(contextBefore: proxy.contextBefore(), last: last, render: { before in
            render(last.transcript, in: choice, contextBefore: before, opening: last.opening, proxy: proxy,
                   vocabulary: vocabulary, systemWords: systemWords)
        }) else { return }
        cancelTimers()
        apply(edit, to: proxy)
        beforeRestyle = last
        KeyboardLog.journal?.log("dictationRestyled", ["from": last.style.rawValue, "to": choice.rawValue,
                                                       "retyped": String(edit.insertion.count)])
        last.inserted = edit.result
        last.style = choice
        settle(last)
    }

    private func apply(_ edit: RestylePlan.Edit, to proxy: TextProxyActions) {
        for _ in 0..<edit.deletions { proxy.deleteBackward() }
        if !edit.insertion.isEmpty { proxy.insert(edit.insertion) }
    }

    /// `dictation` is what the field now holds: the strip shows it as just inserted, with Undo.
    private func settle(_ dictation: InsertedDictation) {
        updateInsertionCredit(dictation.inserted)
        lastDictation = dictation
        lastInsertedDictation = dictation.inserted
        onDictationInserted?(dictation.inserted)
        doubts = []
        doubtReview = nil
        state = .inserted(text: dictation.inserted)
        flagDoubts(dictation.doubts, in: dictation.inserted)
        scheduleIdle(after: reviewWindow)
    }

    func tapRedo() {
        guard case .undone(let text) = state, let proxy else { return }
        cancelTimers()
        proxy.insert(text)
        lastInsertedDictation = text
        updateInsertionCredit(text)
        onDictationInserted?(text)
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
        case .requesting: pressMessage = RecordingRefusal.starting; return
        case .transcribing: pressMessage = RecordingRefusal.writing; return
        case .recording: return
        default:
            break
        }
        if localHost.isBusy, !localHost.isRecognizing {
            state = .error(RecordingRefusal.keyboard)
            opensAppOnNextTap = false
            scheduleIdle(after: .seconds(4))
            return
        }
        if let session = routingSession, session.recording == true,
           session.holdsMicrophoneLease == true || abs(session.heartbeat.timeIntervalSinceNow) <= KeyboardCapture.appHeartbeatTolerance {
            state = .error(session.microphoneBusyMessage ?? RecordingRefusal.recording)
            opensAppOnNextTap = false
            scheduleIdle(after: .seconds(4))
            return
        }
        // Only a tap on the error that said so opens Zone; once it fades, the warm path is tried again.
        var tapOpensApp = false
        if case .error = state, !fromHold { tapOpensApp = opensAppOnNextTap }
        if !fromHold, localHost.openAfterStuckMute {
            tapOpensApp = true
            localHost.openAfterStuckMute = false
        }
        opensAppOnNextTap = false
        cancelTimers()
        let generation = max(store.ledger.droppedGeneration, ownedGeneration) + 1
        let request = DictationRequest(
            id: UUID(),
            generation: generation,
            createdAt: Date(),
            inputSession: proxy.currentInputSession(),
            contextBefore: proxy.contextBefore().map { String($0.suffix(64)) }, holdToTalk: fromHold)
        // Publish the pair together. A delayed tap cannot clear another keyboard's result.
        store.keyboardPresence = KeyboardPresence(lastSeen: Date(), hasFullAccess: true)
        let requested = DictationStatus(requestID: request.id, generation: generation, phase: .requested,
                                        updatedAt: Date(), message: nil)
        guard store.admitRequest(request, initialStatus: requested) else {
            KeyboardLog.journal?.log("keyboardRequestNotAdmitted", recording: request.id)
            state = .error("This dictation didn't start. Tap the mic to try again.")
            scheduleIdle(after: .seconds(4))
            return
        }
        ownedRequestID = request.id
        stopIssuedAt = nil
        requiresExplicitInsert = false
        openedAppForRequest = nil
        ownedGeneration = generation
        DarwinNotifier.post(.requestChanged)
        state = .requesting
        haptic(.medium)

        let sessionAlive = routingSession?.isAlive(now: Date()) ?? false
        KeyboardLog.mic.info("request \(request.id.uuidString.prefix(8), privacy: .public) posted, sessionAlive=\(sessionAlive)")
        // The keyboard's own route is only looked at when the press could use it: the look
        // journals why it was passed over, which would be noise beside a warm session.
        let host = !sessionAlive && !tapOpensApp && localRoute(recording: request.id) == .keyboard ? captureHost() : nil
        let route = DictationRoute.resolve(.init(sessionAlive: sessionAlive, personAskedForZone: tapOpensApp,
                                                 fromHold: fromHold, keyboardCanRecord: host != nil))
        var fields = MemoryFootprint.journalFields()
        fields["route"] = route.journalName
        fields["sessionAlive"] = String(sessionAlive)
        fields["opensApp"] = String({ if case .opensZone = route { true } else { false } }())
        fields["fromHold"] = String(fromHold)
        fields["recordsHere"] = String(route == .inKeyboard)
        fields["pageLoaded"] = String(localHost.isPrepared)
        KeyboardLog.journal?.log("keyboardRequest", recording: request.id, fields)
        follow(route, for: request, host: host)
    }

    /// The one place a press is sent on its way (`DictationRoute`).
    /// - Parameter zoneAnswered: Zone already said it has to be open, so there is no half
    ///   second to wait for its answer before the keyboard records.
    private func follow(_ route: DictationRoute, for request: DictationRequest, host: UIView?, zoneAnswered: Bool = false) {
        switch route {
        case .setUp(.fullAccess):
            state = .needsFullAccess
        case .setUp(.sharedFolder):
            state = .error(Self.unreachableMessage)
        case .warm:
            waitForApp(request)
        case .inKeyboard:
            guard let host else { return follow(.opensZone(.keyboardCannotRecord), for: request, host: nil) }
            if zoneAnswered { recordHereNow(request, in: host) } else { probeThenRecordHere(request, in: host) }
        case .opensZone:
            if request.holdToTalk == true { failWarmRequest(message: SpaceTalk.notReadyMessage) } else { openApp(for: request.id) }
        case .notReady:
            // The session lapsed between the hold's check and this request.
            failWarmRequest(message: SpaceTalk.notReadyMessage)
        }
    }

    /// The session is alive (or the app answered the probe), so the user expects to stay in this
    /// app: a slow answer is retried once and then reported here. The keyboard never bounces to
    /// Zone on its own from the warm path; a later tap on the mic decides that.
    private func waitForApp(_ request: DictationRequest) {
        waitTask?.cancel()
        waitTask = Task { [weak self] in
            for attempt in 0..<2 {
                if attempt > 0 {
                    KeyboardLog.mic.info("warm wait expired for \(request.id.uuidString.prefix(8), privacy: .public); asking again")
                    DarwinNotifier.post(.requestChanged)
                }
                var deadline = ContinuousClock.now + Self.warmPathTimeout
                let silentSince = ContinuousClock.now
                var acknowledged = false
                while !Task.isCancelled, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(80))
                    guard let self else { return }
                    if self.applyStatus() { return }
                    // The session looked alive, yet nobody answered: iOS ended Zone in the last few
                    // seconds and its heartbeat has not gone stale yet. A running Zone answers in
                    // well under a second, so record here instead of waiting six seconds to fail.
                    if attempt == 0, !acknowledged, !self.appAcknowledged(request.id),
                       ContinuousClock.now - silentSince >= Self.silentAppGrace,
                       case .requesting = self.state, self.ownedRequestID == request.id,
                       self.holdRequestID == nil || self.holdRequestID == request.id,
                       self.localRoute(trustingHeartbeat: false, recording: request.id) == .keyboard, let host = self.captureHost() {
                        KeyboardLog.journal?.log("keyboardLocalTakesSilentTap", recording: request.id)
                        guard self.canStartLocal(request) else { return }
                        guard self.takeTap(request) else { continue }
                        self.recordHere(request, in: host)
                        return
                    }
                    if !acknowledged, self.appAcknowledged(request.id) {
                        acknowledged = true
                        deadline = ContinuousClock.now + Self.startingGrace
                    }
                }
                guard let self, !Task.isCancelled, case .requesting = self.state else { return }
                // Zone said it was starting and then went quiet for the whole starting wait
                // (a model that never finished loading, a process iOS froze). The keyboard
                // takes the press rather than ask a second time and end in "Zone didn't answer".
                if acknowledged, self.ownedRequestID == request.id,
                   self.holdRequestID == nil || self.holdRequestID == request.id,
                   self.localRoute(trustingHeartbeat: false, recording: request.id) == .keyboard, let host = self.captureHost() {
                    KeyboardLog.journal?.log("keyboardLocalTakesStalledStart", recording: request.id)
                    guard self.canStartLocal(request) else { return }
                    if self.takeTap(request) {
                        self.recordHere(request, in: host)
                        return
                    }
                }
            }
            guard let self, !Task.isCancelled, case .requesting = self.state else { return }
            KeyboardLog.mic.info("warm wait expired twice for \(request.id.uuidString.prefix(8), privacy: .public); staying here")
            self.failWarmRequest()
        }
    }

    static let needsAppMessage = "Zone has to be open to start the mic. Tap the mic to open it."
    /// How long after a tap Zone's "I have to be open" still gets the tap's own answer. A
    /// running Zone says it in 0.2 to 0.4 s (2026-11-22); later than this the person has moved
    /// on, and a jump to Zone would come out of nowhere.
    static let freshTapWindow: TimeInterval = 1.5
    /// The request whose "I have to be open" was already acted on, so it is acted on once.
    private var needsAppContinued: UUID?

    /// Zone answered a tap "I have to be open": its session ended between the keyboard's last
    /// read and the tap (the car's microphone release, a session that just ran out). The tap is
    /// still fresh, so it does what it would have done had the keyboard known: records here, or
    /// opens Zone. On 2026-11-22 this was a red line and a second tap, three times in a minute.
    /// A hold on space never opens Zone, and a late answer stays for the next tap to settle.
    private func continueAfterNeedsApp(_ id: UUID) {
        guard ownedRequestID == id, let request = store.request, request.id == id,
              abs(Date().timeIntervalSince(request.createdAt)) <= Self.freshTapWindow else {
            failWarmRequest(message: Self.needsAppMessage)
            return
        }
        needsAppContinued = id
        let host = localRoute(trustingHeartbeat: false, recording: id) == .keyboard ? captureHost() : nil
        let route = DictationRoute.resolve(.init(sessionAlive: false, fromHold: request.holdToTalk == true,
                                                 keyboardCanRecord: host != nil))
        KeyboardLog.journal?.log("keyboardTapOutlivedSession", recording: id, ["route": route.journalName])
        follow(route, for: request, host: host, zoneAnswered: true)
    }

    /// The keyboard takes a press Zone has already declined, without the wait for Zone's answer.
    private func recordHereNow(_ request: DictationRequest, in host: UIView) {
        localHost.prepare(in: host)
        waitTask = Task { [weak self] in
            guard let self, self.canStartLocal(request) else { return }
            guard self.takeTap(request) else {
                // Zone took the request after all; a second "open me" is the error it was.
                if !self.applyStatus() { self.waitForApp(request) }
                return
            }
            self.recordHere(request, in: host)
        }
    }

    /// Drops a request Zone never picked up, so a late start cannot record, and says so in the strip.
    private func failWarmRequest(message: String = "Zone didn't answer. Tap the mic to open it.") {
        guard let id = ownedRequestID else { return }
        store.updateLedger(for: id) {
            $0.droppedGeneration = max($0.droppedGeneration, ownedGeneration)
        }
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
    private var holdPhase: SpaceTalk.Phase {
        guard let id = holdRequestID, id == ownedRequestID else { return .none }
        switch state {
        case .requesting: return .starting
        case .recording: return .listening
        default: return .none
        }
    }

    #if DEBUG
    /// The grid's tests stand in for the hold here (`SpaceTalkGridTests`). Nil everywhere else.
    @ObservationIgnored var holdStandIn: SpaceHoldStandIn?
    var spaceTalkPhase: SpaceTalk.Phase {
        get { holdStandIn?.phase ?? holdPhase }
        set { holdStandIn?.phase = newValue }
    }
    #else
    var spaceTalkPhase: SpaceTalk.Phase { holdPhase }
    #endif

    /// A dictation can start without the keyboard opening Zone: Zone keeps the microphone
    /// ready, or the keyboard can record by itself.
    private var zoneListensInPlace: Bool {
        (store.session?.isAlive(now: Date()) ?? false) || localRoute() == .keyboard
    }

    /// The space bar was held still for `SpaceTalk.holdDuration` with Hold space set to Talk.
    /// True when the hold is talking's (it asked for a dictation or explained why it could not);
    /// false when there is nothing to talk with and the hold should move the cursor instead.
    func spaceHoldBegan() -> Bool {
        #if DEBUG
        if let holdStandIn { return holdStandIn.begin() }
        #endif
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
        #if DEBUG
        if let holdStandIn { return holdStandIn.end() }
        #endif
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

    private var historyGeneration = 0

    func showHistory() {
        historyGeneration &+= 1
        let generation = historyGeneration
        panelSection = nil
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
                let records = store.recentDictations(limit: Self.historyPanelLimit)
                panel = records.isEmpty && store.retention == .off ? .off : .loaded(records)
            } else {
                panel = .unreachable
            }
            DispatchQueue.main.async {
                guard let self, self.historyGeneration == generation, self.history == .loading else { return }
                self.history = panel
            }
        }
    }

    func hideHistory() {
        historyGeneration &+= 1
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
        lastInsertedDictation = text
        // Undo can only retract the insertion in this field.
        lastInsertionID = record.status == .inserted ? nil : record.id
        lastDictation = nil
        beforeRestyle = nil
        markHistory(record.id, .inserted, keptWords: text.split(whereSeparator: \.isWhitespace).count)
        onDictationInserted?(text)
        hideHistory()
        haptic(.light)
        state = .inserted(text: text)
        scheduleIdle(after: Self.undoWindow)
    }

    /// Notes where a dictation went, off the main thread; the history file is small but shared.
    private func markHistory(_ id: UUID, _ status: TranscriptStatus, keptWords: Int? = nil) {
        Self.deliveryQueue.async { [deliveryHistory] in
            deliveryHistory()?.mark(id: id, status: status, keptWords: keptWords)
        }
    }

    private func updateInsertionCredit(_ text: String) {
        guard let id = lastInsertionID else { return }
        let count = text.split(whereSeparator: \.isWhitespace).count
        markHistory(id, count > 0 ? .inserted : .dismissed, keptWords: count)
    }

    func tapStop() {
        guard case .recording = state, let id = ownedRequestID else { return }
        if localRequest?.id == id {
            // No watchdog on the app here: `LocalDictationHost` reports its own failure or its text.
            localHost.stop()
            KeyboardLog.journal?.log("keyboardStop", recording: id, ["where": "keyboard"])
            state = .transcribing
            haptic(.light)
            return
        }
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
        if localRequest?.id == id {
            let wasPaused = isPaused
            localHost.setPaused(!wasPaused)
            guard isPaused != wasPaused else { return }
            KeyboardLog.journal?.log(isPaused ? "keyboardPause" : "keyboardResume", recording: id, ["where": "keyboard"])
            haptic(.light)
            return
        }
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
            // A recording here whose owner was lost still ends: nothing else could stop it.
            if localRequest != nil || localProbe != nil { endLocal() }
            state = .idle
            return
        }
        store.updateLedger(for: id) {
            $0.droppedGeneration = max($0.droppedGeneration, ownedGeneration)
        }
        if localRequest?.id == id || localProbe != nil {
            // Recorded here, or about to be. An app that read the request in the probe's
            // window and is starting it drops it on this control.
            endLocal()
            postCancelControl(for: id)
            withdraw(id)
            ownedRequestID = nil
            state = .idle
            return
        }
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
            insert(result, explicitlyRequested: true)
        default:
            break
        }
    }

    /// Drops a pending result for good so it is not offered again.
    func tapDismissPending() {
        guard let result = state.offeredResult else { return }
        guard markConsumed(result) else {
            evaluateResult()
            return
        }
        // Gone from the handoff store, kept in history: a dismissed dictation can still be rescued.
        markHistory(result.requestID, .dismissed)
        state = .idle
    }

    func tapUndo() {
        guard case .inserted(let text) = state, let proxy else { return }
        cancelTimers()
        // Right after a style rewrite, Undo takes back the rewrite, not the dictation.
        if undoRevertsRestyle, let previous = beforeRestyle {
            beforeRestyle = nil
            guard let edit = RestylePlan.edit(contextBefore: proxy.contextBefore(), from: text, to: previous.inserted) else {
                state = .error("Text changed, so undo is off.")
                scheduleIdle(after: .seconds(3))
                return
            }
            apply(edit, to: proxy)
            haptic(.light)
            settle(previous)
            return
        }
        guard let count = UndoPlan.deletionCount(contextBefore: proxy.contextBefore(), lastInserted: text) else {
            state = .error("Text changed, so undo is off.")
            scheduleIdle(after: .seconds(3))
            return
        }
        for _ in 0..<count {
            proxy.deleteBackward()
        }
        onDictationRemoved?()
        updateInsertionCredit("")
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
        // A dictation recorded here is this keyboard's own; nothing in the store may replace it.
        guard localRequest == nil, localProbe == nil else { return }
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
        panelSection = nil
        // Hold space records only while held, and the keyboard going away ends the hold.
        if holdRequestID != nil { spaceHoldEnded() }
        isVisible = false
        #if DEBUG && targetEnvironment(simulator)
        fixtureTask?.cancel()
        #endif
        if ownedRequestID != nil { requiresExplicitInsert = true }
        cancelTimers()
        preloadTask?.cancel()
        preloadTask = nil
        abandonProbe()
        if localRequest != nil, case .requesting = state {
            // The microphone was still on its way (a cold web view takes up to 4 s): the start is
            // called off, which is the person leaving, not the route failing.
            abandonLocalStart()
        }
        // A recording held in the keyboard cannot outlive the keyboard. What was said so far is
        // recognized and, like any result that arrives while the keyboard is away, offered on return.
        if case .recording = state, localRequest != nil {
            localHost.stop()
            state = .transcribing
        }
        localHost.release()
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
        case .recording, .transcribing, .requesting, .inApp:
            guard statusPollTask == nil else { return }
            statusPollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled, let self, self.isVisible else { return }
                    self.presenceTick += 1
                    if self.presenceTick % 8 == 1 {
                        self.store.keyboardPresence = KeyboardPresence(lastSeen: Date(), hasFullAccess: true)
                    }
                    if !self.applyStatus() { self.evaluateResult() }
                    // After the status: `needsApp` settles a status read but leaves `.inApp` waiting.
                    self.giveUpIfZoneNeverAnswered()
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

    /// On screen in `.inApp` with a tap Zone never answered (see `ColdStart.keyboardGivesUp`):
    /// the launch never reached it, so drop it and give the mic back. Until 2026-11-10 a false
    /// "interrupted" from that launch cleared this state by accident.
    private func giveUpIfZoneNeverAnswered() {
        guard case .inApp = state, let id = ownedRequestID,
              ColdStart.keyboardGivesUp(ownedID: id, request: store.request, status: store.status, now: Date()) else { return }
        KeyboardLog.mic.info("Zone never answered \(id.uuidString.prefix(8), privacy: .public); giving up")
        let phase = store.status.flatMap { $0.requestID == id ? $0.phase.rawValue : nil } ?? "none"
        KeyboardLog.journal?.log("keyboardGaveUp", recording: id, ["phase": phase])
        failWarmRequest(message: "Zone didn't start recording. Tap the mic to try again.")
    }

    // MARK: Internals

    private func appAcknowledged(_ requestID: UUID) -> Bool {
        guard let status = store.status, status.requestID == requestID else { return false }
        return status.phase == .starting
    }

    /// Returns true when the status settled the requesting phase (recording started or failed).
    @discardableResult
    private func applyStatus() -> Bool {
        // Once the keyboard records by itself, only `LocalDictationHost` moves this state. An app
        // answer that lands late (it read the request in the probe's window) must not turn a
        // live recording into an error and orphan it.
        guard localRequest == nil else { return false }
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
            // While the keyboard waits to record by itself, "open me" is its cue, not an error.
            if localProbe != nil { return false }
            // A Darwin ping and the poller can read the same reply before the takeover runs.
            // Only the first reader may cancel the old wait and continue the press.
            if case .requesting = state, needsAppContinued != id {
                waitTask?.cancel()
                continueAfterNeedsApp(id)
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
        guard let result = store.result else {
            if state.offeredResult != nil { state = .idle }
            return
        }
        // While a dictation of ours is live, only its own result may surface.
        if let owned = ownedRequestID, result.requestID != owned {
            switch state {
            case .recording, .transcribing, .requesting: return
            default: break
            }
        }
        let ledger = store.ledger
        let previousOffer = state.offeredResult
        if let offered = previousOffer {
            // Keep a valid offer explicit, even if the user moves back to the original field.
            if offered == result, InsertionDecider.unavailableReason(for: result, ledger: ledger, now: Date()) == nil { return }
            state = .idle
        }
        let request = store.request.flatMap { $0.id == result.requestID ? $0 : nil }
        let owns = result.requestID == ownedRequestID
        var decision = InsertionDecider.decide(
            result: result,
            request: request,
            ledger: ledger,
            currentInputSession: proxy?.currentInputSession(),
            currentContextBefore: proxy?.contextBefore(),
            ownsRequest: owns)
        if decision == .insertNow, previousOffer != nil {
            decision = .offerInsert(reason: "Dictation changed")
        }
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
                markConsumed(result)
            } else if owns, reason == "no speech" {
                guard markConsumed(result) else { return }
                watchdogTask?.cancel()
                ownedRequestID = nil
                state = .error("No words heard. Tap the mic to try again.")
                scheduleIdle(after: .seconds(3))
            }
        }
    }

    /// What was said, written in `style` and joined to `contextBefore`: the one place a dictation
    /// becomes text, for the insert and for a rewrite in another style.
    private func render(_ transcript: String, in style: TextStyle, contextBefore: String?, opening: DictationOpening,
                        proxy: TextProxyActions, vocabulary: PersonalVocabulary.Document?, systemWords: [String]) -> String {
        let preferences = readPreferences()
        return proxy.capitalization.dictated(style.insertion(
            of: transcript,
            contextBefore: contextBefore,
            fieldCapitalizesSentences: proxy.autocapitalizesSentences, personalWords: vocabulary?.appliedWords ?? [],
            opening: opening, mentions: preferences.handleRecognition,
            handles: vocabulary?.handles ?? [],
            systemWords: systemWords,
            spokenCorrections: preferences.spokenCorrections,
            capsLockDropsPunctuation: preferences.capsLockDropsPunctuation, emoticons: preferences.spokenEmoticons,
            smallOrdinals: preferences.smallOrdinals, numbers: preferences.numbers, california: preferences.californiaMode,
            searchField: proxy.isSearchField, misheard: vocabulary?.misheard ?? [:],
            autoCapitalization: preferences.autoCapitalizationEnabled))
    }

    private func insert(_ result: DictationResult, explicitlyRequested: Bool = false) {
        guard let proxy else { return }
        style = store.effectiveTextStyle()
        // One read of the person's words, for a dictation Zone recognized and for one the
        // keyboard recorded by itself alike: every layer below is the same for both.
        let vocabulary = readVocabulary()
        let personalWords = vocabulary?.appliedWords ?? []
        let handleRecognition = readPreferences().handleRecognition
        let spokenCorrections = readPreferences().spokenCorrections
        let systemWords = readSystemWords()
        let now = Date()
        guard store.claimInsertion(result, explicitlyRequested: explicitlyRequested, now: now) else {
            let ledger = store.ledger
            let current = store.result
            if current != result, state.offeredResult != nil {
                evaluateResult()
            } else if current == result,
                      InsertionDecider.unavailableReason(for: result, ledger: ledger, now: now) == nil {
                state = .recovery(result)
            } else {
                state = .idle
            }
            return
        }

        // "Scratch that" said on its own takes back the dictation before it, with the Beta on.
        if spokenCorrections, SpokenRepair.isStandaloneCommand(result.text) {
            scratchPreviousDictation(for: result)
            return
        }
        // Read once: the rewrite of this dictation in another style opens the way this one did.
        let opening = dictationOpening()
        let text = render(result.text, in: style, contextBefore: proxy.contextBefore(), opening: opening, proxy: proxy,
                          vocabulary: vocabulary, systemWords: systemWords)
        guard !text.isEmpty else {
            markConsumed(result)
            state = .idle
            return
        }
        proxy.insert(text)
        lastInsertedDictation = text
        lastDictation = InsertedDictation(transcript: result.text, inserted: text, style: style, opening: opening,
                                          doubts: result.doubts)
        beforeRestyle = nil
        if handleRecognition { PersonalVocabulary.learnHandles(taughtIn: result.text, renderedText: text, personalWords: personalWords, knownHandles: vocabulary?.handles ?? []) }
        onDictationInserted?(text)

        store.acknowledgeInsertion(result.requestID)
        DarwinNotifier.post(.payloadConsumed)
        lastInsertionID = result.requestID
        updateInsertionCredit(text)

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
        return readPreferences().checksDoubtfulWords
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
        updateInsertionCredit(edit.text)
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
        guard readPreferences().checksDoubtfulWords, let dictated = lastInsertedDictation,
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
        guard markConsumed(result) else { return }
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
        updateInsertionCredit("")
        onDictationRemoved?()
        haptic(.light)
        state = .undone(text: previous)
        scheduleIdle(after: Self.undoWindow)
    }

    @discardableResult
    private func markConsumed(_ result: DictationResult) -> Bool {
        guard store.dismissResult(result) else { return false }
        DarwinNotifier.post(.payloadConsumed)
        return true
    }

    // MARK: Recording in the keyboard

    /// - Parameter trustingHeartbeat: false once a Zone that looked alive has stayed silent: its
    ///   heartbeat is then known to be left over from a process iOS ended.
    private var routingSession: SessionState? {
        guard let session = store.session else { return nil }
        // A killed app releases its descriptor immediately. Ignore the last pulse
        // even if it still says a meeting is recording or standby is armed.
        if session.holdsMicrophoneLease == true {
            let available = store.microphoneOwnership.reserveForApp { operation, code in
                KeyboardLog.journal?.log("microphoneLockUnavailable", ["from": "sessionProbe", "operation": operation,
                                                                          "errno": String(code)])
                KeyboardLog.mic.error("Microphone ownership probe failed during \(operation, privacy: .public) with errno \(code).")
            }
            if available != nil { return nil }
        }
        return session
    }

    private func localRoute(trustingHeartbeat: Bool = true, recording: UUID? = nil) -> KeyboardCapture.Route {
        let session = routingSession
        let capability = localCapability()
        let hasRoom = KeyboardCapture.hasMemory(available: memoryAvailable(), pageLoaded: localHost.isPrepared)
        if let recording, !hasRoom {
            var fields = MemoryFootprint.journalFields()
            fields["decision"] = "skipKeyboard"
            fields["workerReason"] = "memory"
            KeyboardLog.journal?.log("keyboardModelDecision", recording: recording, fields)
        }
        return KeyboardCapture.route(enabled: readPreferences().dictatesInKeyboard,
                                     systemSupports: capability.systemSupports,
                                     microphoneGranted: microphoneObservation.allowed(
                                        keyboard: capability.microphoneGranted, app: store.appMicrophoneReading),
                                     // Who hears the recording is decided when it stops. With no
                                     // speech model able to run here the audio is kept and Zone
                                     // writes it out, so the words are recorded first either way.
                                     speechAssetInstalled: true,
                                     hasMemory: hasRoom,
                                     appHeartbeat: trustingHeartbeat || session?.recording == true ? session?.heartbeat : nil, failures: localHost.failures, now: Date())
    }

    /// Loads the capture page a moment after the keyboard appears, for someone who dictates in
    /// the keyboard, so their tap has only the microphone left to open. Nothing here asks for
    /// the microphone: no orange dot shows until a dictation starts.
    private func preloadCapturePage() {
        preloadTask?.cancel()
        guard KeyboardCapture.preloads(route: localRoute(), lastDictatedHere: localHost.lastDictated, now: Date()) else { return }
        preloadTask = Task { [weak self] in
            // After the keyboard's first frames, which nothing may slow.
            try? await Task.sleep(for: Self.preloadDelay)
            guard let self, !Task.isCancelled, self.isVisible, !self.localHost.isBusy, !self.localHost.isPrepared,
                  self.localRoute() == .keyboard, let host = self.captureHost() else { return }
            self.localHost.prepare(in: host)
            KeyboardLog.journal?.log("keyboardLocalPreloaded", MemoryFootprint.journalFields())
        }
    }

    /// The request is already posted, as for any tap. An app that is running answers it within a
    /// moment (it refuses during a meeting, or says it must be opened); only when it stays silent
    /// or says it must be opened does the keyboard record. The web view loads meanwhile.
    private func probeThenRecordHere(_ request: DictationRequest, in host: UIView) {
        localHost.prepare(in: host)
        localProbe?.cancel()
        localProbe = Task { [weak self] in
            try? await Task.sleep(for: KeyboardCapture.probe)
            guard let self, !Task.isCancelled else { return }
            self.localProbe = nil
            // The tap was cancelled or replaced meanwhile.
            guard self.ownedRequestID == request.id, case .requesting = self.state else { return }
            let answer = self.store.status.flatMap { $0.requestID == request.id ? $0.phase : nil }
            guard KeyboardCapture.routeAfterProbe(phase: answer) == .keyboard,
                  self.localRoute(trustingHeartbeat: false, recording: request.id) == .keyboard else {
                // The app answered: it owns the tap now, exactly as on the warm path. A refusal or
                // a cancel shows here; an app that is starting gets the warm wait.
                KeyboardLog.journal?.log("keyboardLocalYields", recording: request.id, ["phase": answer?.rawValue ?? "none"])
                if self.applyStatus() { return }
                self.waitForApp(request)
                return
            }
            // Withdrawn from the store, so an app opened a minute from now finds nothing to start,
            // and told off, so an app that read it a moment ago and is starting drops it.
            guard self.canStartLocal(request) else { return }
            guard self.takeTap(request) else {
                if !self.applyStatus() { self.waitForApp(request) }
                return
            }
            self.recordHere(request, in: host)
        }
    }

    /// Capture needs ownership and a microphone. Speech assets are checked on the sealed file.
    private func canStartLocal(_ request: DictationRequest) -> Bool {
        guard !Task.isCancelled, isVisible, case .requesting = state, ownedRequestID == request.id else { return false }
        // Zone declining this press is the reason to record here. Honor any newer app status.
        if let status = store.status, status.requestID == request.id, status.generation == request.generation,
           status.phase == .needsApp { return true }
        return !applyStatus()
    }

    private func takeTap(_ request: DictationRequest) -> Bool {
        guard KeyboardTapOwner.take(request, store: store),
              store.transferRequestToKeyboard(request) else { return false }
        postCancelControl(for: request.id)
        return true
    }

    private func recordHere(_ request: DictationRequest, in host: UIView) {
        let hostStore = localHost.store
        let reserved = hostStore.microphoneOwnership.reserveForKeyboard(recordingID: request.id) { operation, code in
            KeyboardLog.journal?.log("keyboardMicrophoneLockError", recording: request.id,
                                     ["operation": operation, "errno": String(code)])
        }
        guard reserved else {
            failWarmRequest(message: "The mic is in use. Finish the recording, then tap again.")
            opensAppOnNextTap = false
            return
        }
        let now = Date()
        hostStore.keyboardRecordingClaim = KeyboardRecordingClaim(requestID: request.id, since: now, heartbeat: now)
        localRequest = request
        KeyboardLog.journal?.log("keyboardLocalStart", recording: request.id)
        // The host cancels anything of its own still in flight first: one recorder, the newest tap.
        localHost.start(request, in: host, observer: self)
    }

    /// A tap whose probe never finished (the keyboard left the screen first) is withdrawn whole,
    /// so no app started later takes it for a waiting request.
    private func abandonProbe() {
        guard localProbe != nil, let id = ownedRequestID else { return }
        store.updateLedger(for: id) {
            $0.droppedGeneration = max($0.droppedGeneration, ownedGeneration)
        }
        endLocal()
        postCancelControl(for: id)
        withdraw(id)
        ownedRequestID = nil
        state = .idle
    }

    /// The keyboard left before the microphone started. Nothing was recorded and nothing counts
    /// as a failure.
    private func abandonLocalStart() {
        let id = localRequest?.id
        KeyboardLog.journal?.log("keyboardLocalAbandoned", recording: id)
        endLocal()
        if let id { withdraw(id) }
        ownedRequestID = nil
        state = .idle
    }

    private func postCancelControl(for id: UUID) {
        store.control = DictationControl(requestID: id, generation: ownedGeneration, action: .cancel, issuedAt: Date())
        DarwinNotifier.post(.controlChanged)
    }

    private func withdraw(_ id: UUID) {
        store.withdraw(id)
    }

    /// `EngineKind.appleSpeech`'s raw value: the keyboard does not link the app's engine list.
    static let localEngineName = LocalDictationHost.engineName

    private func endLocal() {
        localProbe?.cancel()
        localProbe = nil
        if let id = localRequest?.id, localHost.request?.id == id { localHost.cancel() }
        localRequest = nil
    }

    /// On appearance: a dictation this process is still recognizing (its controller is gone, or
    /// this one went off screen) is shown here, and offered when its text arrives. With nothing
    /// in flight, a recording whose recognition failed earlier gets its one retry.
    private func adoptLocalDictation() {
        guard let request = localHost.request else {
            if let id = localRequest?.id, ownedRequestID == id {
                switch state {
                case .requesting, .recording, .transcribing:
                    ownedRequestID = nil
                    state = .idle
                default: break
                }
            }
            localRequest = nil
            localHost.retryKeptRecording(in: captureHost())
            return
        }
        // Starting or recording belongs to the controller that tapped (this one, when the
        // appearance is checked again); only a recognition is taken over.
        guard localHost.adopt(self, for: request.id) else { return }
        localRequest = request
        if ownedRequestID != request.id {
            ownedRequestID = request.id
            ownedGeneration = request.generation
            requiresExplicitInsert = true
        }
        if case .transcribing = state {} else { state = .transcribing }
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
            levelSubscription = LevelChannel.Subscription { [weak self] level, finishIn in
                guard let self, self.localRequest == nil else { return }
                self.appendLevel(level, finishIn: finishIn)
            }
        } else {
            stopLevelSampling()
            levelRecordingStart = nil
            hearsNothing = false
            quietFinishIn = nil
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

    private func appendLevel(_ sample: Float, finishIn: Int? = nil) {
        guard isVisible, case .recording = state else { return }
        let countdown = isPaused ? nil : finishIn
        if quietFinishIn != countdown { quietFinishIn = countdown }
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
    /// The `finishing` fixture's countdown, re-sent with each synthetic level as the app would.
    private var fixtureFinishIn: Int?
    private var fixtureLevelTask: Task<Void, Never>?

    /// A fixture stands in for the app: a constant level or a synthetic envelope at 20 Hz.
    private func startFixtureLevels() {
        fixtureLevelTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self else { return }
                tick += 1
                self.appendLevel(self.fixtureConstantLevel ?? Self.fixtureEnvelope(tick: tick), finishIn: self.fixtureFinishIn)
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
                    // The line is forgotten with the file, so the same one (a second `undo`) is
                    // delivered again when it is written again.
                    if fixture.say != nil || fixture.style != nil || fixture.undo {
                        KeyboardFixture.removeFile()
                        self.lastFixtureText = nil
                    }
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
            let request = DictationRequest(id: UUID(), generation: store.ledger.droppedGeneration + 1,
                                           createdAt: Date(), inputSession: nil, contextBefore: nil)
            store.request = request
            let result = DictationResult(requestID: request.id, generation: request.generation, text: marked.text,
                                         audioSeconds: 3, createdAt: Date(), inputSession: nil,
                                         doubts: marked.doubts.isEmpty ? nil : marked.doubts)
            if store.publishFinal(result, for: request) { insert(result) }
            fixtureForcesDoubts = false
            return
        }
        if let style = fixture.style {
            chooseStyle(style)
            return
        }
        if fixture.undo {
            tapUndo()
            return
        }
        if fixture.capsLock { lockShift?() }
        // Look tokens apply on their own too, so `accent-ice` alone recolors without a state.
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
        fixtureFinishIn = nil
        hearsNothing = false
        quietFinishIn = nil
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
        case .finishing:
            fixtureConstantLevel = 0
            levels = Array(repeating: 0, count: levels.count)
            fixtureFinishIn = 3
            state = .recording(startedAt: Date().addingTimeInterval(-9))
            quietFinishIn = 3
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

extension MicController: LocalDictationObserver {
    /// Everything about a dictation recorded here reaches this controller only through the host,
    /// which delivers the words itself; this only moves what the strip shows.
    func localDictation(_ request: DictationRequest, reported update: LocalDictationHost.Update) {
        guard localRequest?.id == request.id else { return }
        let owns = ownedRequestID == request.id
        switch update {
        case .started:
            guard owns, case .requesting = state else { return }
            state = .recording(startedAt: Date())
            if holdRequestID == request.id { haptic(.light) }
        case .paused(let value):
            isPaused = value
        case .level(let level, let countdown):
            appendLevel(level, finishIn: countdown)
        case .recognizing:
            // A limit, or iOS taking the microphone, ended it without a tap on Stop.
            guard owns, case .recording = state else { return }
            state = .transcribing
        case .delivered(let published):
            localRequest = nil
            guard owns else { return }
            if published {
                evaluateResult()
            } else {
                ownedRequestID = nil
                state = .error("Your words are in History.")
                scheduleIdle(after: .seconds(4))
                return
            }
            // Not on screen, or nothing to insert: the strip never stays on "Transcribing".
            switch state {
            case .requesting, .recording, .transcribing:
                ownedRequestID = nil
                state = .idle
            default:
                break
            }
        case .savedForZone:
            localRequest = nil
            guard owns else { return }
            ownedRequestID = nil
            state = .error("Finishing your recording in Zone.")
            if isVisible, openedAppForRequest != request.id {
                openedAppForRequest = request.id
                proxy?.open(ZoneContract.homeURL)
            }
            // A host can decline a URL. Keep a manual way forward without opening Zone twice.
            expiryTask?.cancel()
            expiryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, isVisible, openedAppForRequest == request.id,
                      state == .error("Finishing your recording in Zone.") else { return }
                state = .error("Open Zone to finish your saved recording.")
            }
        case .failed(let message):
            localRequest = nil
            guard owns else { return }
            ownedRequestID = nil
            // The next tap on the mic opens Zone, the way it always could.
            opensAppOnNextTap = true
            state = .error("\(message) Tap the mic to open Zone.")
            haptic(.light)
            scheduleIdle(after: .seconds(8))
        }
    }
}

#if DEBUG
/// A hold on space with no dictation behind it, for tests of the grid's side of hold space to
/// talk: what the hold answers, how often it began and ended, and the phase the space bar shows.
@MainActor @Observable final class SpaceHoldStandIn {
    var talkAvailable = false
    var phase = SpaceTalk.Phase.none
    private(set) var began = 0
    private(set) var ended = 0
    /// The strip explains (Zone not ready): the hold is talking's, with no dictation.
    var explainsInsteadOfTalking = false

    func begin() -> Bool {
        began += 1
        if talkAvailable, !explainsInsteadOfTalking { phase = .starting }
        return talkAvailable
    }

    func end() {
        ended += 1
        phase = .none
    }
}
#endif

/// Shared by the visible panel and both cue and quiet consumers in the recording host.
@MainActor
final class KeyboardSettingReader {
    static let shared = KeyboardSettingReader(store: UserDefaultsSharedStore())
    let store: SharedStore
    private let last: LastKeyboardPreferences
    private var pending: [QuickSettingRequest] = []
    private var revision: UInt = 0

    init(store: SharedStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.last = LastKeyboardPreferences(defaults: defaults)
    }

    func current() -> KeyboardPreferences {
        if let shared = store as? UserDefaultsSharedStore {
            return last.resolve(stored: shared.storedKeyboardPreferences, pending: pending)
        }
        return store.keyboardPreferences.overlaying(pending)
    }

    func refresh() async {
        guard let inbox = store.quickSettingInbox else { return }
        revision &+= 1
        let revisionAtRead = revision
        let requests = await Task.detached { try? inbox.read() }.value
        guard let requests, revisionAtRead == revision else { return }
        pending = requests
        _ = current()
    }

    func submit(_ value: QuickSetting, inbox: QuickSettingInbox) async throws {
        let known = current()
        let request = try await Task.detached { try inbox.submit(value, known: known) }.value
        revision &+= 1
        pending.removeAll { $0.value.key == value.key && $0.stamp < request.stamp }
        pending.append(request)
        _ = current()
    }
}
