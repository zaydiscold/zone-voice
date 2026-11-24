// by zayd/cold @ zayd.wtf

import ActivityKit
import Foundation
import UIKit
import ZoneCore

/// Zone's one Live Activity: the standby card while the microphone waits, the recording card
/// while it records.
///
/// iOS makes a card only for an app in front (`Activity.request` from the background throws),
/// but updates one from anywhere. So a card the standby still needs is never ended from the
/// background: it is held, dimmed, through an interruption and updated back. On Zayd's phone,
/// November 9 to 18, ending it there left the microphone with iOS's orange pill 213 times.
@MainActor
final class RecordingLiveActivity {
    private var current: Activity<RecordingActivityAttributes>?
    private var observation: Task<Void, Never>?
    /// The last state sent to the card. Read by tests; only this class writes it.
    private(set) var latestState: RecordingActivityAttributes.ContentState?
    private var updateTask: Task<Void, Never>?
    private var pressNoticeTask: Task<Void, Never>?
    private var onLost: (@MainActor (IslandUpkeep.Ending) -> Void)?
    private var lastRefresh = Date.distantPast
    private var createdAt = Date.distantPast
    /// When an interruption took standby's microphone; nil while the card is not held.
    private(set) var standbyHeldSince: Date?
    private let beforeRequest: (() throws -> Void)?
    /// Told when a card goes without Zone ending it: how it went, the phase it showed, and its
    /// age. The coordinator decides whether to make it again or say so (`IslandUpkeep`).
    var lost: @MainActor (_ ending: IslandUpkeep.Ending, _ phase: RecordingActivityAttributes.ContentState.Phase?,
                          _ age: TimeInterval) -> Void = { _, _, _ in }
    /// The Lock Screen shows the activity as stale this long after Zone's last word. Zone
    /// refreshes it every `refreshInterval` from the microphone heartbeat, so a live Zone never
    /// goes stale and a killed one stops claiming "Dictating" within half a minute (failure
    /// map L6). Before, `staleDate` was nil and a dead app looked like it was recording until
    /// it was opened again. One limit with the widget and the controls, so no surface still
    /// claims a recording that another has already given up on.
    static let staleAfter: TimeInterval = CarWidgetState.staleAfter
    static let refreshInterval: TimeInterval = 10
    /// Live island content (waveform, caption) is pushed at most this often. ActivityKit
    /// coalesces faster local updates anyway, and once a second already reads as live.
    static let liveInterval: TimeInterval = 1

    /// How the island draws Zone, and in what color. Read on every new state.
    var look: @MainActor () -> IslandLook = { .halo }
    var accentChoice: @MainActor () -> String = { AccentChoice.current.rawValue }
    var palette: @MainActor () -> IslandPalette = { .accent }
    /// The standby session's numbers, stamped on every update so the island never shows old ones.
    var session: @MainActor () -> IslandSession? = { nil }
    var controls: @MainActor () -> Bool = { true }
    var times: @MainActor () -> IslandTimes = { .clock }
    private var lastLive = Date.distantPast
    private static func staleDate(from now: Date = Date()) -> Date { now.addingTimeInterval(staleAfter) }
    init(beforeRequest: (() throws -> Void)? = nil) {
        self.beforeRequest = beforeRequest
        for previous in Activity<RecordingActivityAttributes>.activities {
            Task { await previous.end(nil, dismissalPolicy: .immediate) }
        }
        // A fresh app has no recording: the widget must not keep a dead one's timer.
        Self.publishWidget(nil)
    }

    /// The voice-note widget (Home Screen, StandBy, CarPlay) mirrors the activity's phase.
    /// Ready counts as idle there: the card is a control, and "ready" is not something to tap for.
    ///
    /// Every island update comes through here, once a second while recording and every 10 s in
    /// standby. The widget only needs a change of phase, and while recording a refresh inside
    /// `CarWidgetState.staleAfter`; writing the file and asking WidgetKit and both controls to
    /// redraw on every update was 3,600 writes and reloads an hour of recording, and one every
    /// 10 s for as long as standby lasted.
    private static func publishWidget(_ state: RecordingActivityAttributes.ContentState?, freshUntil: Date? = nil, now: Date = Date()) {
        var next = CarWidgetState.idle
        // A recording no control started (the keyboard's, one started in the app) is written too,
        // marked as not owned: the controls then say Zone is busy instead of Off, and still never
        // draw a stop that their press could not perform.
        if let state, state.phase != .ready, state.phase != .starting {
            next = CarWidgetState(phase: state.phase == .processing ? .processing : .recording,
                                  noteMode: state.noteMode, startedAt: state.waitingForSamples == true ? nil : state.startedAt, updatedAt: now, freshUntil: freshUntil,
                                  controlOwned: state.controlOwned == true ? nil : false)
        }
        guard widgetNeedsPublish(last: lastWidget, next: next) else { return }
        lastWidget = next
        CarWidgetState.publish(next)
    }
    /// A different phase, mode, start or hold always publishes. The same recording publishes again
    /// once `widgetRefresh` has passed, and the same idle never does.
    nonisolated static func widgetNeedsPublish(last: CarWidgetState?, next: CarWidgetState) -> Bool {
        guard let last, last.phase == next.phase, last.noteMode == next.noteMode, last.controlOwned == next.controlOwned,
              last.startedAt == next.startedAt, last.freshUntil == next.freshUntil else { return true }
        return next.phase != .idle && next.updatedAt.timeIntervalSince(last.updatedAt) >= widgetRefresh
    }
    /// What the widget file holds, as far as this process knows. Nil until the first publish, so a
    /// launch always writes once over whatever an earlier process left.
    private static var lastWidget: CarWidgetState?
    /// How often an unchanged recording is rewritten, well inside `CarWidgetState.staleAfter`.
    nonisolated static let widgetRefresh: TimeInterval = 10
    /// ActivityKit updates a card's state independently of our main-actor watcher.
    /// A still-owned terminal card waits for the watcher to report how it ended.
    enum CardPresence: Equatable {
        case missing, visible, awaitingUpdate

        init(_ state: ActivityState?) {
            switch state {
            case nil: self = .missing
            case .active, .stale: self = .visible
            default: self = .awaitingUpdate
            }
        }
    }

    var cardPresence: CardPresence { CardPresence(current?.activityState) }
    var isActive: Bool { cardPresence == .visible }

    /// Showing a recording, not the standby card. A standby card is an indicator for the
    /// microphone, but it never means a recording is still running.
    var showsRecording: Bool { isActive && latestState?.phase != .ready && latestState?.phase != .starting }
    /// The standby card, held by an interruption or not.
    var showsStandby: Bool { isActive && latestState?.phase == .ready }

    /// Stamps the person's look and accent on a state. The island reads nothing else.
    /// The pet's growth stage, from the words dictated in all. Read on every new state.
    var galleryEnabled: @MainActor () -> Bool = { false }
    var garden: @MainActor () -> IslandGardenProgress = { .init() }
    var petStage: @MainActor () -> UInt8 = { 1 }
    private var spriteSpin: IslandSpin?
    private func styled(_ state: RecordingActivityAttributes.ContentState) -> RecordingActivityAttributes.ContentState {
        var state = state
        state.look = look()
        if state.look?.spins == true {
            let now = Date()
            let peak = IslandLevels.unit(state.levels?.suffix(6).max() ?? 0)
            let turning = state.phase == .recording && state.userPausedAt == nil
            spriteSpin = (spriteSpin ?? .resting(at: now)).retarget(turning ? 0.15 + 0.58 * peak : 0, at: now)
        } else {
            spriteSpin = nil
        }
        state.spin = spriteSpin
        state.accentChoice = accentChoice()
        state.palette = palette()
        state.session = session()
        state.controls = controls()
        state.times = times()
        state.gallery = galleryEnabled() ? true : nil
        if state.gallery == true, state.look == .sprout || state.look == .drift {
            state.nightGarden = !((7..<19).contains(Calendar.current.component(.hour, from: Date())))
        }
        state.petStage = state.look?.isPet == true ? petStage() : nil
        if state.gallery == true {
            let progress = garden()
            state.dailyEnergy = progress.dailyEnergy()
            state.accessory = progress.accessory
        }
        return state
    }

    /// A user-triggered recording intent may create this briefly before microphone activation.
    func prepareStarting(noteMode: Bool) throws {
        previewID = nil
        let state = RecordingActivityAttributes.ContentState(phase: .starting, noteMode: noteMode, startedAt: Date(), controlOwned: true)
        if let current, isActive { enqueue(state: state, activity: current) }
        else { try create(state: state) }
    }

    func firstSample(at date: Date) {
        guard let current, var state = latestState, state.phase == .recording,
              state.userPausedAt == nil, (state.waitingForSamples == true || state.startedAt != date) else { return }
        state.startedAt = date
        state.waitingForSamples = nil
        enqueue(state: state, activity: current)
    }

    func loadingModel(_ loading: Bool) {
        guard let current, var state = latestState, (state.modelLoading == true) != loading else { return }
        state.modelLoading = loading ? true : nil
        enqueue(state: state, activity: current)
    }

    func prepareReady() throws {
        guard !isActive else { return }
        try create(state: .init(phase: .ready, noteMode: false, startedAt: Date()))
    }

    /// The standby card: Zone owns the Dynamic Island while the microphone waits, so iOS
    /// does not draw its own wide microphone pill. `until` is when the session ends (nil for
    /// a session only the person ends). Creating one needs Zone in front; from the
    /// background this updates an existing card and otherwise does nothing.
    func standby(until: Date?, lastWords: Int? = nil, justFinished: Bool = false, canCreate: Bool) {
        var state = RecordingActivityAttributes.ContentState(phase: .ready, noteMode: false, startedAt: Date())
        state.readySince = Date()
        state.readyUntil = until
        state.words = lastWords
        state.justFinished = justFinished ? true : nil
        if let current, isActive {
            if let latest = latestState, latest.phase == .ready, latest.standbyHeld != true {
                // Same standby, new deadline: keep the ring's start so it empties smoothly, and
                // a check still showing. After a hold the ring starts again: the deadline it
                // counted to was cancelled.
                state.readySince = latest.readySince ?? state.readySince
                if !justFinished, latest.justFinished == true {
                    state.justFinished = true
                    state.words = latest.words
                }
            }
            standbyHeldSince = nil
            enqueue(state: state, activity: current)
            ensureRelay()
        } else if canCreate {
            standbyHeldSince = nil
            try? create(state: state)
        }
    }

    /// An interruption (Siri, a call, an alarm, another app's audio) took standby's microphone.
    /// The card stays, dimmed and without a countdown, so the island is still Zone's when the
    /// microphone comes back: those interruptions end with Zone in the background, where no new
    /// card can be made. `until` is how long Zone waits for the microphone before the card may
    /// read as stale.
    func standbyHeld(until: Date) {
        guard let current, isActive, var state = latestState, state.phase == .ready else { return }
        if standbyHeldSince == nil { standbyHeldSince = Date() }
        state.standbyHeld = true
        state.readyUntil = nil
        state.justFinished = nil
        enqueue(state: state, activity: current, staleDate: until)
    }

    /// Wherever a card can be made (Zone in front, or inside a press), a standby card at least
    /// `IslandUpkeep.renewAfter` old is replaced by a fresh one, so iOS's eight-hour limit
    /// counts from the last time Zone could act, not from when standby began. Nothing shows: the
    /// island does not draw Zone's card while Zone is on screen, and a press replaces it with
    /// the same state. Returns whether a new card was made.
    @discardableResult
    func renewStandbyIfAging(during moment: String = "front") -> Bool {
        guard showsStandby, let state = latestState,
              IslandUpkeep.shouldRenew(age: age(), held: standbyHeldSince != nil) else { return false }
        let age = Int(age())
        do { try create(state: state) } catch { return false }
        Journal.log("islandRenewed", ["age": String(age), "during": moment])
        return true
    }

    /// Live Activities are allowed for Zone (iOS Settings > Zone). Off, no card can be made.
    var activitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// How long ago iOS made the card up now. iOS ends it at `IslandUpkeep.systemLimit`.
    func age() -> TimeInterval { clock().timeIntervalSince(createdAt) }
    /// Card ages are read from this. Tests move it forward instead of waiting hours.
    var clock: @MainActor () -> Date = { Date() }
    /// `startedAt` is passed when a recording already running gets a new card, so its clock
    /// goes on from the recording's start, not from zero.
    private(set) var previewID: UUID?
    var isPreviewing: Bool { previewID != nil }
    func finishPreview(_ id: UUID) -> Bool {
        guard previewID == id else { return false }
        previewID = nil
        return true
    }

    func start(noteMode: Bool, controlOwned: Bool, startedByPress: Bool = false, startedAt: Date = Date(), waitingForSamples: Bool = false,
               preview: (id: UUID, levels: [UInt8], text: String)? = nil, onLost: @escaping @MainActor (IslandUpkeep.Ending) -> Void) throws {
        var state = RecordingActivityAttributes.ContentState(phase: .recording, noteMode: noteMode, startedAt: startedAt, controlOwned: controlOwned, startedByPress: startedByPress)
        state.waitingForSamples = waitingForSamples ? true : nil
        if let preview {
            state.beat = 1
            state.levels = preview.levels
            state.words = preview.text.split(whereSeparator: \.isWhitespace).count
            if [.caption, .stream].contains(look()) { state.tail = IslandCaption.tail(of: preview.text) }
        }
        lastLive = .distantPast
        doneTask?.cancel()
        if isActive, let current {
            previewID = preview?.id
            enqueue(state: state, activity: current)
        } else {
            try create(state: state)
            previewID = preview?.id
        }
        self.onLost = onLost
    }
    private func create(state: RecordingActivityAttributes.ContentState) throws {
        try beforeRequest?()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw Failure.disabled }
        let state = styled(state)
        let activity: Activity<RecordingActivityAttributes>
        do {
            activity = try Activity.request(attributes: RecordingActivityAttributes(),
                content: ActivityContent(state: state, staleDate: Self.staleDate()), pushType: nil)
        } catch {
            // Expected from the background; the log says whether iOS ever grants one there.
            Journal.log("islandRefused", ["phase": state.phase.rawValue, "error": JournalFormat.error(error),
                                          "appState": Self.appStateName()])
            throw error
        }
        // Only now: a refused request leaves the card that is up, and its watcher, untouched.
        adopt(activity, state: state)
        // The relay waited for the card this one replaces; this one gets its own.
        cancelRelay()
        ensureRelay()
    }

    /// `activity` is Zone's card from now on: the one it updates, and the one whose end it
    /// watches. The card it replaces ends.
    private func adopt(_ activity: Activity<RecordingActivityAttributes>, state: RecordingActivityAttributes.ContentState) {
        observation?.cancel()
        let previous = current
        lastRefresh = Date()
        createdAt = clock()
        current = activity
        if let previous, previous.id != activity.id { Task { await previous.end(nil, dismissalPolicy: .immediate) } }
        latestState = state
        Self.publishWidget(state)
        observation = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled, let self, self.current?.id == activity.id else { return }
                if state == .ended || state == .dismissed {
                    // Not Zone: Zone's own ends stop this watcher first. Dismissed is a person
                    // clearing the card from the Lock Screen (or iOS removing it); ended is
                    // iOS's time limit. Either way the island is gone until Zone is in front.
                    Journal.log("islandGone", ["state": state == .dismissed ? "dismissed" : "ended",
                        "phase": self.latestState?.phase.rawValue ?? "none",
                        "held": String(self.standbyHeldSince != nil),
                        "age": String(Int(Date().timeIntervalSince(self.createdAt))),
                        "appState": Self.appStateName()])
                    let callback = self.onLost
                    let phase = self.latestState?.phase
                    let age = self.age()
                    self.onLost = nil
                    self.current = nil
                    self.standbyHeldSince = nil
                    // The person cleared it: no relay brings it back over their choice.
                    if state == .dismissed { self.cancelRelay() }
                    Self.publishWidget(nil)
                    let ending: IslandUpkeep.Ending = state == .dismissed ? .dismissed : .ended
                    callback?(ending)
                    self.lost(ending, phase, age)
                    return
                }
            }
        }
    }

    // MARK: Relay (iOS 26)

    /// Whether standby wants its card carried past iOS's eight hours (standby on, island on).
    var wantsRelay: @MainActor () -> Bool = { false }
    /// Told when a relay card has taken over the island.
    var relayed: @MainActor () -> Void = {}
    /// iOS 26 starts a Live Activity scheduled for a date even with Zone in the background: the
    /// one way past the eight-hour limit with no press and no server. While standby keeps a card,
    /// this relay waits (`pending`) to start `relayLead` before that card's limit; when it starts
    /// it becomes Zone's card and the old one ends. iOS shows a scheduled start by opening Zone's
    /// island for about four seconds (simulator, 2026-11-20), with the silent sound below. The
    /// next relay can only be asked for in front or in a press, so the island lasts 16 hours
    /// from the last time Zone was opened or pressed, not forever.
    private(set) var relay: Activity<RecordingActivityAttributes>?
    private var relayWatch: Task<Void, Never>?
    /// When iOS last refused a relay. iOS refuses one from the background, as it does any
    /// request (simulator, 2026-11-20: a relay that started could not schedule the next), so it is
    /// asked again only after half an hour, or at once when Zone is in front or a press runs.
    private var relayRefusedAt = Date.distantPast
    static let relayLead: TimeInterval = 120
    /// A scheduled start must play a sound; this one is silence, so the island opening is all
    /// that happens, even at night.
    static let relaySound = "island-relay-silence.caf"

    /// A card is up and standby wants it carried: makes sure a relay waits for it. Cheap when one
    /// already does.
    /// `retryAfter` is how long after a refusal to ask again: long in the background, where iOS
    /// refuses, short in front or inside a press, where it grants.
    func ensureRelay(retryAfter: TimeInterval = 1800) {
        guard relay == nil, isActive, wantsRelay(), let state = latestState,
              Date().timeIntervalSince(relayRefusedAt) >= retryAfter else { return }
        scheduleRelay(state: styled(state))
    }

    private func scheduleRelay(state: RecordingActivityAttributes.ContentState) {
        guard #available(iOS 26.0, *) else { return }
        var limit = IslandUpkeep.systemLimit
        #if DEBUG
        // Simulator research: `-zoneIslandRelayAfter 40` starts the relay 40 s after its card.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-zoneIslandRelayAfter"), index + 1 < arguments.count,
           let seconds = Double(arguments[index + 1]) { limit = seconds + Self.relayLead }
        #endif
        let start = Date().addingTimeInterval(limit - Self.relayLead - age())
        guard start.timeIntervalSinceNow > 10 else { return }
        let pending: Activity<RecordingActivityAttributes>
        do {
            pending = try Activity.request(attributes: RecordingActivityAttributes(),
                content: ActivityContent(state: state, staleDate: start.addingTimeInterval(Self.staleAfter)),
                pushType: nil, style: .standard,
                alertConfiguration: AlertConfiguration(title: "Zone", body: "Still ready for the keyboard.",
                                                       sound: .named(Self.relaySound)),
                start: start)
        } catch {
            relayRefusedAt = Date()
            Journal.log("islandRelayRefused", ["error": JournalFormat.error(error), "appState": Self.appStateName()])
            return
        }
        cancelRelay()
        relay = pending
        Journal.log("islandRelayScheduled", ["startsIn": String(Int(start.timeIntervalSinceNow)),
                                             "appState": Self.appStateName()])
        relayWatch = Task { [weak self] in
            for await update in pending.activityStateUpdates {
                guard !Task.isCancelled, let self, self.relay?.id == pending.id else { return }
                if update == .active { return self.relayStarted(pending) }
                if update == .ended || update == .dismissed {
                    self.relay = nil
                    return
                }
            }
        }
    }

    func refreshRelayAppearance() {
        guard let relay, let latestState else { return }
        let previous = relay.content.state
        let next = styled(latestState)
        guard previous.accentChoice != next.accentChoice || previous.palette != next.palette ||
              previous.look != next.look || previous.controls != next.controls || previous.times != next.times else { return }
        scheduleRelay(state: next)
    }

    func refreshAppearance() {
        guard let current, let latestState, isActive else { return }
        enqueue(state: latestState, activity: current, staleDate: current.content.staleDate)
    }

    /// The relay is up: it is Zone's card now, with the state Zone last showed, and the old card
    /// (minutes from its limit, or already gone) ends. Then the next relay is asked for, which
    /// iOS may refuse in the background; the next time Zone is in front or a press runs, it is.
    private func relayStarted(_ activity: Activity<RecordingActivityAttributes>) {
        relay = nil
        relayWatch = nil
        let hadCard = isActive
        let previousAge = Int(age())
        let state = styled(latestState ?? activity.content.state)
        let held = standbyHeldSince
        adopt(activity, state: state)
        standbyHeldSince = held
        enqueue(state: state, activity: activity, staleDate: held.map { _ in Date().addingTimeInterval(InterruptionPolicy.holdLimit) })
        Journal.log("islandRelayStarted", ["hadCard": String(hadCard), "previousAge": String(previousAge),
                                           "appState": Self.appStateName()])
        relayed()
        ensureRelay()
    }

    /// Asks for the relay again from the card's age now. Tests age the card with `clock` first.
    func restartRelay() {
        cancelRelay()
        relayRefusedAt = .distantPast
        ensureRelay()
    }

    /// The card's identity, for the log and tests: a relay that took over has a new one.
    var cardID: String? { current?.id }

    private func cancelRelay() {
        relayWatch?.cancel()
        relayWatch = nil
        guard let pending = relay else { return }
        relay = nil
        Task { await pending.end(nil, dismissalPolicy: .immediate) }
    }

    private static func appStateName() -> String {
        switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }
    func processing() {
        update(phase: .processing)
        keepProcessingFresh()
    }

    /// Recognition can run a minute or more after the microphone stops (`recognitionLimit`), and
    /// with standby off no heartbeat comes then. Without this, a long save went stale on the island
    /// at 30 s and turned the widget into "Zone stopped" while Zone was still writing. The refresh
    /// runs in the app, so a Zone killed mid-save stops refreshing and still goes stale.
    private func keepProcessingFresh() {
        processingRefresh?.cancel()
        processingRefresh = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.refreshInterval))
                guard !Task.isCancelled, let self, self.isActive, self.latestState?.phase == .processing else { return }
                self.heartbeat()
            }
        }
    }
    private var processingRefresh: Task<Void, Never>?

    /// The person paused or resumed the recording. Paused, the card shows the time recorded so
    /// far and a Resume button; resumed, its clock picks up from that time, not from the
    /// moment the recording began.
    func userPaused(_ paused: Bool, now: Date = Date()) {
        guard let current, isActive, var state = latestState, state.phase == .recording else { return }
        if paused {
            guard state.userPausedAt == nil else { return }
            state.userPausedAt = max(0, now.timeIntervalSince(state.startedAt))
            state.quiet = nil // A pause is not quiet.
        } else {
            guard let elapsed = state.userPausedAt else { return }
            state.userPausedAt = nil
            state.startedAt = now.addingTimeInterval(-elapsed)
        }
        // A paused card gets no microphone heartbeat changes worth showing, but the
        // heartbeat still refreshes its stale date.
        enqueue(state: state, activity: current)
    }

    /// The live island: the microphone's recent levels and the last words recognized. Called
    /// about once a second while recording; anything faster is dropped here.
    func live(levels: [UInt8], text: String, now: Date = Date()) {
        guard let current, isActive, var state = latestState, state.phase == .recording,
              now.timeIntervalSince(lastLive) >= Self.liveInterval else { return }
        lastLive = now
        let look = look()
        // The ghost draws neither: do not spend updates on it.
        guard look != .ghost || galleryEnabled() else { return }
        // The living looks pace their motion by the count of updates, not by the clock.
        state.beat = (look.isAlive || galleryEnabled()) ? (state.beat ?? 0) &+ 1 : nil
        state.levels = levels
        state.words = text.split(whereSeparator: \.isWhitespace).count
        state.tail = look == .caption || look == .stream ? IslandCaption.tail(of: text) : nil
        enqueue(state: state, activity: current)
    }
    /// Called on every microphone heartbeat (1 to 3 s); pushes the stale date forward every 10 s.
    func heartbeat(now: Date = Date()) {
        guard let current, current.activityState == .active || current.activityState == .stale,
              now.timeIntervalSince(lastRefresh) >= Self.refreshInterval else { return }
        enqueue(state: latestState ?? current.content.state, activity: current)
    }
    /// After a recording: back to the standby card when the person keeps one (Settings >
    /// Dynamic Island), otherwise the card ends. `until` is the session's end.
    ///
    /// `kept` is how many words the recording that just finished saved. Only that earns the
    /// check: a cancel, a failure, a recording with no words and the later clearing of a
    /// result all pass nil and return to the plain standby, because nothing was kept.
    func ready(keepStandby: Bool = false, until: Date? = nil, kept: Int? = nil) {
        guard keepStandby, isActive else { return end() }
        // A card already on standby keeps the count it shows; one leaving a recording that
        // kept nothing has no count to carry.
        let shown = latestState?.phase == .ready ? latestState?.words : nil
        standby(until: until, lastWords: kept ?? shown, justFinished: kept != nil, canCreate: false)
        guard kept != nil else { return }
        // The check is a moment, not a state: back to the plain standby after `doneFor`, unless
        // something else (a new recording, a new deadline) has replaced the card meanwhile.
        doneTask?.cancel()
        doneTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.doneFor))
            guard !Task.isCancelled, let self, let current = self.current, self.isActive,
                  var state = self.latestState, state.phase == .ready, state.justFinished == true else { return }
            state.justFinished = nil
            self.enqueue(state: state, activity: current)
        }
    }
    /// How long the island shows its check after a recording finishes.
    static let doneFor: TimeInterval = 3
    private var doneTask: Task<Void, Never>?
    /// Finish when quiet has heard nothing for a moment and will end the recording at `until`
    /// (`SilenceFinish.saysQuiet`); nil when a voice came back. One update each way: the card
    /// says "Quiet" and drains a ring to `until` by itself.
    func quiet(until: Date?, now: Date = Date()) {
        guard let current, isActive, var state = latestState, state.phase == .recording else { return }
        let until = state.noteMode ? nil : until
        let range = until.flatMap { $0 > now ? now...$0 : nil }
        guard (state.quiet == nil) != (range == nil) else { return }
        state.quiet = range
        enqueue(state: state, activity: current)
    }
    /// An interruption holds the recording (or the standby). No heartbeat refreshes the card
    /// while the microphone is off, so it stays fresh until `until`, the end of the hold.
    func paused(until: Date) { update(phase: .paused, staleDate: until) }
    func resumeRecording() { update(phase: .recording) }
    private func update(phase: RecordingActivityAttributes.ContentState.Phase, staleDate: Date? = nil) {
        guard let current, isActive else { return }
        var state = latestState ?? current.content.state
        state.phase = phase
        if phase != .recording { state.quiet = nil }
        enqueue(state: state, activity: current, staleDate: staleDate)
    }
    private func enqueue(state: RecordingActivityAttributes.ContentState, activity: Activity<RecordingActivityAttributes>,
                         staleDate: Date? = nil) {
        let state = styled(state)
        latestState = state
        lastRefresh = Date()
        Self.publishWidget(state, freshUntil: staleDate)
        let stale = staleDate ?? Self.staleDate()
        let previous = updateTask
        let demo = previewID
        updateTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await activity.update(ActivityContent(state: state, staleDate: stale))
            if let demo {
                Journal.log("islandDemoDelivered", ["id": demo.uuidString, "sent": state.phase.rawValue,
                                                     "current": activity.content.state.phase.rawValue])
            }
        }
    }
    func showPressNotice(_ message: String) async {
        guard let current, isActive, var state = latestState else { return }
        pressNoticeTask?.cancel()
        state.pressNotice = message
        enqueue(state: state, activity: current, staleDate: current.content.staleDate)
        pressNoticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, let card = self.current, card.id == current.id,
                  var state = self.latestState, state.pressNotice == message else { return }
            state.pressNotice = nil
            self.enqueue(state: state, activity: card, staleDate: card.content.staleDate)
        }
        await updateTask?.value
    }

    func end() {
        previewID = nil
        pressNoticeTask?.cancel(); pressNoticeTask = nil
        processingRefresh?.cancel(); processingRefresh = nil
        observation?.cancel(); observation = nil; onLost = nil
        standbyHeldSince = nil
        cancelRelay()
        guard let previous = current else { return }
        current = nil
        latestState = nil
        Self.publishWidget(nil)
        let pending = updateTask
        updateTask = nil
        Task { await pending?.value; await previous.end(nil, dismissalPolicy: .immediate) }
    }
    enum Failure: LocalizedError, CustomLocalizedStringResourceConvertible {
        case disabled, foregroundRequired
        var errorDescription: String? {
            switch self {
            case .disabled: "Live Activities are unavailable. Open Zone to record, or enable Live Activities for Zone in Settings."
            case .foregroundRequired: "Open Zone to start the recording Live Activity."
            }
        }
        var localizedStringResource: LocalizedStringResource { "\(errorDescription ?? "Recording unavailable")" }
    }
}
