// by zayd/cold @ zayd.wtf

import ActivityKit
import Foundation
import ZoneCore

/// Uses the installed recording widget, with the meeting's title and the recorded duration.
/// A timer anchor based on recorded samples excludes voluntary pauses and interruption gaps.
@MainActor
final class MeetingLiveActivity {
    enum State { case recording, paused, interrupted }
    private let colors: @MainActor () -> (accentChoice: String, palette: IslandPalette)
    private var current: Activity<RecordingActivityAttributes>?
    private var title = "Meeting"
    private var lastState: State = .recording
    private var lastSeconds: Double = 0
    private var levels = MeetingActivityLevels()
    private var updatedAt = -Double.infinity
    private var pending: Task<Void, Never>?
    var isActive: Bool {
        current?.activityState == .active || current?.activityState == .stale
    }

    init(colors: @escaping @MainActor () -> (accentChoice: String, palette: IslandPalette)) {
        self.colors = colors
    }

    func start(title: String, state: State = .recording, recordedSeconds: Double = 0) {
        levels.reset()
        self.title = title
        lastSeconds = recordedSeconds
        lastState = state
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            let activity = try Activity.request(attributes: RecordingActivityAttributes(),
                content: ActivityContent(state: content(), staleDate: Date().addingTimeInterval(Self.staleAfter)), pushType: nil)
            let previous = current
            current = activity
            if let previous { Task { await previous.end(nil, dismissalPolicy: .immediate) } }
            updatedAt = ProcessInfo.processInfo.systemUptime
        } catch {
            Journal.log("meetingLiveActivityFailed", ["error": JournalFormat.error(error)])
        }
    }

    func update(title: String) {
        self.title = title
        publish()
    }

    func update(state: State, recordedSeconds: Double) {
        if lastState != state {
            levels.reset()
        }
        lastState = state
        lastSeconds = recordedSeconds
        publish()
    }

    /// Keep the real audio envelope even while the recorder screen is asleep.
    func appendLevel(_ level: Float) {
        if lastState == .recording { levels.append(level) }
    }

    func heartbeat(recordedSeconds: Double) {
        lastSeconds = recordedSeconds
        guard current != nil else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - updatedAt
        // Speech can change the picture once a second. A quiet or paused meeting needs
        // only the occasional timer and freshness update.
        let changed = lastState == .recording && levels.takeSnapshot(after: elapsed)
        if changed || elapsed >= Self.heartbeat { publish() }
    }

    private static let heartbeat: TimeInterval = 30
    /// Three missed heartbeats: Zone was killed, and the Lock Screen says so.
    private static let staleAfter: TimeInterval = 90

    private func content(notice: String? = nil) -> RecordingActivityAttributes.ContentState {
        let appearance = colors()
        let phase: RecordingActivityAttributes.ContentState.Phase = lastState == .recording ? .recording : .paused
        return .init(phase: notice == nil ? phase : .processing, noteMode: true,
                     startedAt: Date().addingTimeInterval(-lastSeconds), meetingTitle: title,
                     meetingNote: notice ?? note(),
                     meetingWaveStyle: UserDefaults.standard.string(forKey: MeetingWaveStyle.preferenceKey) ?? MeetingWaveStyle.defaultStyle.rawValue,
                     meetingHeld: notice == nil && lastState == .interrupted ? true : nil,
                     accentChoice: appearance.accentChoice, palette: appearance.palette, levels: lastState == .recording ? levels.snapshot : nil)
    }

    func refreshAppearance() {
        if isActive { publish() }
    }

    /// Held: when it continues. Near the ceiling: the clock time it saves, which stays right
    /// between heartbeats while recording.
    private func note() -> String? {
        switch lastState {
        case .interrupted: return "Continues after the call. Tap to open Zone."
        case .paused: return nil
        case .recording:
            let remaining = MeetingRecordingSafety.maximumSeconds - lastSeconds
            guard remaining <= MeetingRecordingSafety.countdownSeconds else { return nil }
            return "Saves and stops at \(Date().addingTimeInterval(max(0, remaining)).formatted(date: .omitted, time: .shortened))"
        }
    }

    private func publish() {
        guard let current else { return }
        let next = content()
        let stale = Date().addingTimeInterval(Self.staleAfter)
        updatedAt = ProcessInfo.processInfo.systemUptime
        let previous = pending
        pending = Task {
            await previous?.value
            await current.update(ActivityContent(state: next, staleDate: stale))
        }
    }

    /// `notice`: Zone stopped the meeting itself, likely with the phone locked. The Lock Screen
    /// keeps saying why (iOS removes it within four hours) instead of the activity vanishing.
    func end(notice: String? = nil) {
        guard let current else { return }
        self.current = nil
        let previous = pending
        pending = nil
        guard let notice else {
            Task { await previous?.value; await current.end(nil, dismissalPolicy: .immediate) }
            return
        }
        let saved = content(notice: notice)
        Task { await previous?.value; await current.end(ActivityContent(state: saved, staleDate: nil), dismissalPolicy: .default) }
    }
}

/// Capture supplies levels whether or not the recorder view is visible. Each system
/// update contains the latest syllables and can be skipped if the picture is unchanged.
struct MeetingActivityLevels {
    private var meter = IslandMeter(capacity: MeetingWaveSignal.count)
    private(set) var snapshot: [UInt8]?

    mutating func append(_ level: Float) { meter.append(level) }

    mutating func reset() {
        meter.reset()
        snapshot = nil
    }

    mutating func takeSnapshot(after elapsed: TimeInterval) -> Bool {
        guard elapsed >= 1 else { return false }
        let next = meter.snapshot
        guard next != snapshot else { return false }
        snapshot = next
        return true
    }
}
