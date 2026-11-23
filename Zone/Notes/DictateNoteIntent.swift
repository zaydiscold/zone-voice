// by zayd/cold @ zayd.wtf

import AppIntents
import Foundation
import UIKit
import ActivityKit
import ZoneCore

/// One pending mode, so two cold-launch requests cannot leave an older mode to replay later.
@MainActor private enum PendingShortcut {
    static var noteMode: Bool?
    static let actions = ShortcutActionQueue()
}

/// The app's half of the intents declared in `Shared/ZoneIntents.swift`: the work itself, the
/// notification the root view listens for, and the cold-launch flag.
enum ZoneIntentHost {
    @MainActor
    static func perform(_ intent: some ForegroundContinuableIntent, noteMode: Bool, desiredState: Bool? = nil) async throws {
        try await intent.runZoneShortcut(noteMode: noteMode, desiredState: desiredState)
    }

    @MainActor
    static func setStandby(_ intent: some ForegroundContinuableIntent, on: Bool) async throws {
        try await intent.runZoneStandby(on: on)
    }

    /// A button on Zone's own card. Always in the background: it never opens Zone.
    @MainActor
    static func island(_ action: IslandAction) async throws {
        AppEntry.noteAutomation("island")
        AppLaunch.wake(trigger: "island")
        let coordinator = DictationCoordinator.shortcutCoordinator
        Journal.log("islandControl", ["action": action.rawValue,
            "armed": String(coordinator?.isArmed == true),
            "busy": String(coordinator?.activity.isBusy == true),
            "foreground": String(UIApplication.shared.applicationState == .active)])
        guard let coordinator else {
            throw DictationCoordinator.ShortcutFailure(message: AppLaunch.missingMessage(otherwise: "Open Zone once to finish setup, then try again."))
        }
        try await coordinator.performIslandAction(action)
    }
}

extension DictateNoteIntent {
    /// Posted on the main thread when the intent runs; the root view starts the note screen.
    static let requested = Notification.Name("wtf.zayd.zone.dictateNote")
    /// On a cold launch the post can beat the root view's subscription, so it also leaves a flag.
    @MainActor
    static func takePendingRequest() -> Bool {
        guard PendingShortcut.noteMode == true else { return false }
        PendingShortcut.noteMode = nil
        return true
    }
}

extension DictateIntent {
    static let requested = Notification.Name("wtf.zayd.zone.dictate")
    @MainActor static func takePendingRequest() -> Bool {
        guard PendingShortcut.noteMode == false else { return false }
        PendingShortcut.noteMode = nil
        return true
    }
}

@available(*, deprecated)
extension DictateNoteIntent: ForegroundContinuableIntent {}
@available(*, deprecated)
extension DictateIntent: ForegroundContinuableIntent {}
@available(*, deprecated)
extension SetZoneRecordingIntent: ForegroundContinuableIntent {}
@available(*, deprecated)
extension SetZoneStandbyIntent: ForegroundContinuableIntent {}

extension ForegroundContinuableIntent {
    @MainActor
    func runZoneShortcut(noteMode: Bool, desiredState: Bool? = nil) async throws {
        // Before anything else: What's New must never open on a visit a Shortcut began.
        AppEntry.noteAutomation("shortcut")
        AppLaunch.wake(trigger: "shortcut")
        let began = ProcessInfo.processInfo.systemUptime
        let requestToken = PendingShortcut.actions.acceptRequest()
        let invocation = requestToken.uuidString
        Journal.log("shortcutInvoked", ["invocation": invocation,
            "mode": noteMode ? "note" : "dictate",
            "requestedState": desiredState.map { $0 ? "on" : "off" } ?? "toggle",
            "warm": String(DictationCoordinator.shortcutCoordinator?.shortcutCanRunWarm == true),
            "foreground": String(UIApplication.shared.applicationState == .active)])
        defer {
            Journal.log("shortcutReturned", ["invocation": invocation,
                "elapsedMs": String(Int((ProcessInfo.processInfo.systemUptime - began) * 1000))])
        }
        do {
            try await PendingShortcut.actions.enqueue {
                do {
                    try await self.runZoneShortcutBody(noteMode: noteMode, desiredState: desiredState)
                } catch {
                    // Failed preparation can leave standby audio behind too. Preserve the
                    // original error if cleanup succeeds. If policy recovery needed to save
                    // another recording, return that more relevant explanation instead.
                    try await DictationCoordinator.shortcutCoordinator?.settleRecordingShortcut()
                    throw error
                }
                try await DictationCoordinator.shortcutCoordinator?.settleRecordingShortcut()
            }.value
        } catch let failure as DictationCoordinator.ShortcutFailure {
            Journal.log("shortcutRefused", ["invocation": invocation, "message": failure.message])
            if noteMode { DictationCoordinator.shortcutCoordinator?.notePressFailed(failure.message) }
            throw failure
        } catch let failure as RecordingLiveActivity.Failure where failure == .disabled {
            // Zone's own message already says what to do (turn on Live Activities); keep it.
            Journal.log("shortcutRefused", ["invocation": invocation, "message": "liveActivitiesDisabled"])
            if noteMode { DictationCoordinator.shortcutCoordinator?.notePressFailed(failure.errorDescription ?? "") }
            throw failure
        } catch {
            Journal.log("shortcutFailed", ["invocation": invocation, "error": JournalFormat.error(error)])
            let plain = Self.plainFailure(for: error)
            if noteMode { DictationCoordinator.shortcutCoordinator?.notePressFailed(plain.message) }
            throw plain
        }
    }

    /// The system's own errors read like "This current action is not allowed" or "denied by
    /// service delegate". Each press gets one sentence that says what to do instead.
    @MainActor
    private static func plainFailure(for error: Error) -> DictationCoordinator.ShortcutFailure {
        if !UIApplication.shared.isProtectedDataAvailable {
            return .init(message: "Unlock your iPhone, then press again.")
        }
        if error is ActivityAuthorizationError {
            return .init(message: "Zone could not show its recording in the Dynamic Island. Open Zone once, then press again.")
        }
        let text = String(describing: error).lowercased()
        if text.contains("denied") || text.contains("open") {
            return .init(message: "iOS did not let Zone open just now. Unlock your iPhone and press again.")
        }
        return .init(message: "Zone could not start recording. Open Zone, then press again.")
    }

    /// AVAudioSession's "insufficient priority" (!pri), "Siri is recording" (siri) and "busy"
    /// (!act), the three refusals the phone's log shows while a call or Siri is up.
    static func microphoneIsBusy(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSOSStatusErrorDomain && [561_017_449, 1_936_290_409, 561_015_905].contains(error.code)
    }

    @MainActor
    private func runZoneShortcutBody(noteMode: Bool, desiredState: Bool?) async throws {
        if let coordinator = DictationCoordinator.shortcutCoordinator,
           await coordinator.finishStartingShortcut(noteMode: noteMode, desiredState: desiredState) { return }
        let finishingID = DictationCoordinator.shortcutCoordinator?.shortcutRequestToFinish(noteMode: noteMode)
        // A press that would start must never be dropped silently because an earlier
        // recording is still finishing or holds the microphone.
        if finishingID == nil, desiredState != false, let coordinator = DictationCoordinator.shortcutCoordinator {
            try await coordinator.clearWayForShortcutStart(noteMode: noteMode)
        }
        // Resolve desired state after earlier accepted presses finish. A duplicate On is
        // idempotent; Off on an idle/mismatched mode never arms the microphone.
        if let desiredState {
            if let coordinator = DictationCoordinator.shortcutCoordinator {
                guard coordinator.shouldRunRecordingControl(noteMode: noteMode, desiredState: desiredState) else { return }
            } else if !desiredState { return }
        }
        guard let coordinator = DictationCoordinator.shortcutCoordinator else {
            throw DictationCoordinator.ShortcutFailure(message: AppLaunch.missingMessage(otherwise: "Open Zone once to finish setup, then run this shortcut again."))
        }
        guard finishingID != nil || ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw RecordingLiveActivity.Failure.disabled
        }
        if !coordinator.shortcutCanRunWarm {
            do {
                // LiveActivityIntent grants the activity creation context. Try that path
                // before a foreground handoff that Settings/Shortcuts may not allow.
                try await coordinator.prepareRecordingShortcut(noteMode: noteMode)
            } catch let failure as DictationCoordinator.ShortcutFailure {
                throw failure
            } catch let failure as RecordingLiveActivity.Failure where failure == .disabled {
                throw failure
            } catch {
                Journal.log("shortcutBackgroundPreparationFailed", ["error": JournalFormat.error(error)])
                // A call or Siri holds the microphone. Opening Zone would not change that, so
                // the press says so instead of asking for the passcode on a locked phone.
                if Self.microphoneIsBusy(error) {
                    throw DictationCoordinator.ShortcutFailure(message: "The microphone is in use by a call or Siri. Press again when it ends.")
                }
                guard UIApplication.shared.applicationState != .active else { throw error }
                Journal.log("shortcutForegroundRequested", ["reason": "preparation",
                    "locked": String(!UIApplication.shared.isProtectedDataAvailable)])
                try await continueZoneInForeground()
                try await coordinator.prepareRecordingShortcut(noteMode: noteMode)
            }
        }
        do {
            try await coordinator.runRecordingShortcut(noteMode: noteMode, finishing: finishingID)
        } catch RecordingLiveActivity.Failure.foregroundRequired {
            // ActivityKit can reject creation while backgrounded even for recording intents.
            // Retry once in the foreground; never activate hidden capture without its activity.
            guard UIApplication.shared.applicationState != .active else { throw RecordingLiveActivity.Failure.foregroundRequired }
            // On a locked phone this handoff is the passcode screen, so the log names it.
            Journal.log("shortcutForegroundRequested", ["reason": "liveActivity",
                "locked": String(!UIApplication.shared.isProtectedDataAvailable)])
            try await continueZoneInForeground()
            try await coordinator.runRecordingShortcut(noteMode: noteMode, finishing: nil)
        }
    }

    /// The Toggle Zone control. Off ends the session where it is. On brings Zone to the front
    /// first: a microphone held ready with no Live Activity has to be started in the foreground.
    @MainActor
    func runZoneStandby(on: Bool) async throws {
        AppEntry.noteAutomation("standbyControl")
        AppLaunch.wake(trigger: "standbyControl")
        let coordinator = DictationCoordinator.shortcutCoordinator
        Journal.log("standbyControl", ["requestedState": on ? "on" : "off",
            "armed": String(coordinator?.isArmed == true),
            "foreground": String(UIApplication.shared.applicationState == .active)])
        guard let coordinator else {
            if !on { return }
            throw DictationCoordinator.ShortcutFailure(message: AppLaunch.missingMessage(otherwise: "Open Zone once to finish setup, then press again."))
        }
        guard on else { return try coordinator.turnStandbyOffFromControl() }
        guard !coordinator.isArmed else { return }
        if UIApplication.shared.applicationState != .active { try await continueZoneInForeground() }
        coordinator.turnStandbyOnFromControl()
    }

    @MainActor
    private func continueZoneInForeground() async throws {
        if #available(iOS 26.0, *) {
            guard systemContext.currentMode.canContinueInForeground else {
                throw DictationCoordinator.ShortcutFailure(message: "Open Zone once to start its microphone session, then press again.")
            }
            try await continueInForeground(alwaysConfirm: false)
        } else {
            try await requestToContinueInForeground()
        }
    }
}

/// The newest finished dictation or note as text, for the next step of a shortcut: run Voice
/// note from the Action Button, then later "Get last dictation" into Messages, Mail, Notes or
/// a chat app. Read from the on-device history, so it follows History's retention setting.
struct LastDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Get last dictation"
    static let description = IntentDescription("The text of your most recent Zone dictation or voice note, to pass to the next action in a shortcut.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        AppEntry.noteAutomation("lastDictationShortcut")
        guard UIApplication.shared.isProtectedDataAvailable else {
            throw DictationCoordinator.ShortcutFailure(message: "Unlock your iPhone, then run this again.")
        }
        let latest = TranscriptHistory.shared?.recent(limit: 20).first {
            $0.status != .recording && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard let latest else {
            throw DictationCoordinator.ShortcutFailure(message: "No dictation in Zone's history yet.")
        }
        return .result(value: latest.text)
    }
}

struct ZoneShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DictateIntent(),
            phrases: ["Dictate with \(.applicationName)", "Start dictation in \(.applicationName)"],
            shortTitle: "Dictate and copy",
            systemImageName: "doc.on.clipboard")
        AppShortcut(
            intent: DictateNoteIntent(),
            phrases: ["Dictate a note in \(.applicationName)", "New \(.applicationName) note", "Voice note in \(.applicationName)"],
            shortTitle: "Voice note",
            systemImageName: "note.text")
        AppShortcut(
            intent: LastDictationIntent(),
            phrases: ["Get my last \(.applicationName) dictation", "Last \(.applicationName) dictation"],
            shortTitle: "Last dictation",
            systemImageName: "text.quote")
        AppShortcut(
            intent: SendToComputerIntent(),
            phrases: ["Send to my computer with \(.applicationName)", "Send text to my computer with \(.applicationName)"],
            shortTitle: "Send to Computer",
            systemImageName: "desktopcomputer")
    }
}
