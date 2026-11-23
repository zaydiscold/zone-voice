// by zayd/cold @ zayd.wtf

import ActivityKit
import Foundation
import ZoneCore

/// Uses the installed recording widget, with the meeting's title and the recorded duration.
/// A timer anchor based on recorded samples excludes voluntary pauses and interruption gaps.
@MainActor
final class MeetingLiveActivity {
    enum State { case recording, paused, interrupted }
    private var current: Activity<RecordingActivityAttributes>?
    private var title = "Meeting"
    private var lastState: State = .recording
    private var lastSeconds: Double = 0
    private var updatedAt = Date.distantPast
    private var pending: Task<Void, Never>?
    var isActive: Bool { current?.activityState == .active }

    func start(title: String) {
        self.title = title
        lastSeconds = 0
        lastState = .recording
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            let activity = try Activity.request(attributes: RecordingActivityAttributes(),
                content: ActivityContent(state: content(), staleDate: Date().addingTimeInterval(Self.staleAfter)), pushType: nil)
            let previous = current
            current = activity
            if let previous { Task { await previous.end(nil, dismissalPolicy: .immediate) } }
            updatedAt = Date()
        } catch {
            Journal.log("meetingLiveActivityFailed", ["error": JournalFormat.error(error)])
        }
    }

    func update(title: String) {
        self.title = title
        publish()
    }

    func update(state: State, recordedSeconds: Double) {
        lastState = state
        lastSeconds = recordedSeconds
        publish()
    }

    /// The timer counts by itself; this only keeps the activity from going stale and moves
    /// the anchor if capture drifted. 30 s, not every tick: about 720 renders in six hours.
    func heartbeat(recordedSeconds: Double) {
        lastSeconds = recordedSeconds
        if Date().timeIntervalSince(updatedAt) >= Self.heartbeat { publish() }
    }

    private static let heartbeat: TimeInterval = 30
    /// Three missed heartbeats: Zone was killed, and the Lock Screen says so.
    private static let staleAfter: TimeInterval = 90

    private func content() -> RecordingActivityAttributes.ContentState {
        .init(phase: lastState == .recording ? .recording : .paused, noteMode: true,
              startedAt: Date().addingTimeInterval(-lastSeconds), meetingTitle: title,
              meetingNote: note(), meetingHeld: lastState == .interrupted ? true : nil)
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
        updatedAt = Date()
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
        let saved = RecordingActivityAttributes.ContentState(
            phase: .processing, noteMode: true, startedAt: Date().addingTimeInterval(-lastSeconds),
            meetingTitle: title, meetingNote: notice)
        Task { await previous?.value; await current.end(ActivityContent(state: saved, staleDate: nil), dismissalPolicy: .default) }
    }
}
