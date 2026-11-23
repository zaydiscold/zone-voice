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
    private var onLost: (@MainActor () -> Void)?
    private var lastRefresh = Date.distantPast
    private var createdAt = Date.distantPast
    /// When an interruption took standby's microphone; nil while the card is not held.
    private(set) var standbyHeldSince: Date?
    private let beforeRequest: (() throws -> Void)?
    /// iOS ends a Live Activity eight hours after it starts. A standby only the person ends
    /// outlives that, and its card cannot be replaced from the background, so Zone renews it
    /// whenever it is in front and the card is past half its life.
    static let renewAfter: TimeInterval = 4 * 3600
    /// The Lock Screen shows the activity as stale this long after Zone's last word. Zone
    /// refreshes it every `refreshInterval` from the microphone heartbeat, so a live Zone never
    /// goes stale and a killed one stops claiming "Dictating" within half a minute (failure
    /// map L6). Before, `staleDate` was nil and a dead app looked like it was recording until
    /// it was opened again.
    static let staleAfter: TimeInterval = 30
    static let refreshInterval: TimeInterval = 10
    /// Live island content (waveform, caption) is pushed at most this often. ActivityKit
    /// coalesces faster local updates anyway, and once a second already reads as live.
    static let liveInterval: TimeInterval = 1

    /// How the island draws Zone, and in what color. Read on every new state.
    var look: @MainActor () -> IslandLook = { .halo }
    var accentHex: @MainActor () -> UInt32 = { 0x9B7DFF }
    /// The standby session's numbers, stamped on every update so the island never shows old ones.
    var session: @MainActor () -> IslandSession? = { nil }
    var controls: @MainActor () -> Bool = { true }
    private var lastLive = Date.distantPast
    private static func staleDate(from now: Date = Date()) -> Date { now.addingTimeInterval(staleAfter) }
    init(beforeRequest: (() throws -> Void)? = nil) {
        self.beforeRequest = beforeRequest
        for previous in Activity<RecordingActivityAttributes>.activities {
            Task { await previous.end(nil, dismissalPolicy: .immediate) }
        }
        // A fresh app has no recording: the widget must not keep a dead one's timer.
        CarWidgetState.publish(.idle)
    }

    /// The voice-note widget (Home Screen, StandBy, CarPlay) mirrors the activity's phase.
    /// Ready counts as idle there: the card is a control, and "ready" is not something to tap for.
    private static func publishWidget(_ state: RecordingActivityAttributes.ContentState?, freshUntil: Date? = nil) {
        guard let state, state.phase != .ready, state.controlOwned == true else { return CarWidgetState.publish(.idle) }
        CarWidgetState.publish(CarWidgetState(
            phase: state.phase == .processing ? .processing : .recording,
            noteMode: state.noteMode, startedAt: state.startedAt, updatedAt: Date(), freshUntil: freshUntil))
    }
    /// The card is up. Stale counts: it is iOS's word for a card past its `staleDate`, and an
    /// update brings it back. Only an ended or dismissed card is gone, and from the background
    /// a gone card cannot be replaced. Before, a stale card counted as gone, so the next
    /// recording ended it instead of updating it.
    var isActive: Bool {
        guard let state = current?.activityState else { return false }
        return state == .active || state == .stale
    }
    /// Showing a recording, not the standby card. A standby card is an indicator for the
    /// microphone, but it never means a recording is still running.
    var showsRecording: Bool { isActive && latestState?.phase != .ready }
    /// The standby card, held by an interruption or not.
    var showsStandby: Bool { isActive && latestState?.phase == .ready }

    /// Stamps the person's look and accent on a state. The island reads nothing else.
    private func styled(_ state: RecordingActivityAttributes.ContentState) -> RecordingActivityAttributes.ContentState {
        var state = state
        state.look = look()
        state.accentHex = accentHex()
        state.session = session()
        state.controls = controls()
        return state
    }

    /// A user-triggered recording intent may create this briefly before microphone activation.
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

    /// In front, where a card can be made: a standby card past half of iOS's eight hours is
    /// replaced by a fresh one, so the limit never takes it while Zone is in the background.
    /// Nothing shows: Zone's own card is not drawn in the island while Zone is on screen.
    func renewStandbyIfAging(now: Date = Date()) {
        guard showsStandby, standbyHeldSince == nil, let state = latestState,
              now.timeIntervalSince(createdAt) >= Self.renewAfter else { return }
        Journal.log("islandRenewed", ["age": String(Int(now.timeIntervalSince(createdAt)))])
        try? create(state: state)
    }
    func start(noteMode: Bool, controlOwned: Bool, onLost: @escaping @MainActor () -> Void) throws {
        let state = RecordingActivityAttributes.ContentState(phase: .recording, noteMode: noteMode, startedAt: Date(), controlOwned: controlOwned)
        lastLive = .distantPast
        doneTask?.cancel()
        if isActive, let current {
            enqueue(state: state, activity: current)
        } else { try create(state: state) }
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
        observation?.cancel()
        let previous = current
        lastRefresh = Date()
        createdAt = Date()
        current = activity
        if let previous { Task { await previous.end(nil, dismissalPolicy: .immediate) } }
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
                    self.onLost = nil
                    self.current = nil
                    self.standbyHeldSince = nil
                    Self.publishWidget(nil)
                    callback?()
                    return
                }
            }
        }
    }

    private static func appStateName() -> String {
        switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }
    func processing() { update(phase: .processing) }

    /// The person paused or resumed the recording. Paused, the card shows the time recorded so
    /// far and a Resume button; resumed, its clock picks up from that time, not from the
    /// moment the recording began.
    func userPaused(_ paused: Bool, now: Date = Date()) {
        guard let current, isActive, var state = latestState, state.phase == .recording else { return }
        if paused {
            guard state.userPausedAt == nil else { return }
            state.userPausedAt = max(0, now.timeIntervalSince(state.startedAt))
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
        guard look != .ghost else { return }
        state.levels = levels
        state.words = text.split(whereSeparator: \.isWhitespace).count
        state.tail = look == .caption ? IslandCaption.tail(of: text) : nil
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
    /// An interruption holds the recording (or the standby). No heartbeat refreshes the card
    /// while the microphone is off, so it stays fresh until `until`, the end of the hold.
    func paused(until: Date) { update(phase: .paused, staleDate: until) }
    func resumeRecording() { update(phase: .recording) }
    private func update(phase: RecordingActivityAttributes.ContentState.Phase, staleDate: Date? = nil) {
        guard let current, isActive else { return }
        var state = latestState ?? current.content.state
        state.phase = phase
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
        updateTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await activity.update(ActivityContent(state: state, staleDate: stale))
        }
    }
    func end() {
        observation?.cancel(); observation = nil; onLost = nil
        standbyHeldSince = nil
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
