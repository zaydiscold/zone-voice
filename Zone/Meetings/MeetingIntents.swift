// by zayd/cold @ zayd.wtf

import AppIntents
import Foundation

/// Put Set Focus (Do Not Disturb, On) before this action in a Shortcut to start a protected
/// meeting in one tap. Foreground execution lets iOS grant microphone access explicitly.
struct StartMeetingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start meeting"
    static var description = IntentDescription("Record a meeting in Zone. Add Set Focus before this action to turn on Do Not Disturb.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppEntry.noteAutomation("meetingShortcut")
        AppLaunch.wake(trigger: "meetingShortcut")
        guard let meetings = MeetingCoordinator.current else { throw MeetingIntentError.notReady() }
        await meetings.startRecording()
        guard meetings.isRecording else { throw MeetingIntentError.failed(meetings.lastError ?? "The meeting could not start.") }
        return .result(dialog: "Meeting recording in Zone.")
    }
}

struct StopMeetingIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop meeting"
    static var description = IntentDescription("Save the meeting audio and start its transcript on this device.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppEntry.noteAutomation("meetingShortcut")
        AppLaunch.wake(trigger: "meetingShortcut")
        guard let meetings = MeetingCoordinator.current else { throw MeetingIntentError.notReady() }
        if meetings.isStartingRecording, !meetings.isRecording {
            await meetings.stopRecording()
            return .result(dialog: "Meeting start cancelled.")
        }
        guard meetings.isRecording else { return .result(dialog: "No meeting is recording.") }
        await meetings.stopRecording()
        return .result(dialog: "Meeting saved. Zone will transcribe it on this device.")
    }
}

/// A Focus filter configures the recorder's presentation. It never silently starts or stops
/// a microphone, and it does not change the user's system Focus settings.
struct MeetingFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "Meeting controls"
    static var description = IntentDescription("Show the active meeting recorder when you return to Zone during this Focus.")
    @Parameter(title: "Show recording controls", default: true) var showsRecorder: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Meeting controls", subtitle: showsRecorder ? "Show the active recorder" : "Keep the current screen")
    }

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            AppEntry.noteAutomation("meetingFocusFilter")
            if showsRecorder, let meetings = MeetingCoordinator.current, meetings.isRecording {
                meetings.showsRecorder = true
            }
        }
        return .result()
    }
}

@MainActor
enum MeetingFocus {
    static func applyOnForeground(_ meetings: MeetingCoordinator) {
        Task { [weak meetings] in
            guard let filter = try? await MeetingFocusFilter.current, filter.showsRecorder,
                  let meetings, meetings.isRecording else { return }
            meetings.showsRecorder = true
        }
    }
}

private enum MeetingIntentError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        }
    }

    @MainActor static func notReady() -> MeetingIntentError {
        .failed(AppLaunch.missingMessage(otherwise: "Open Zone once, then try starting the meeting again."))
    }
}
