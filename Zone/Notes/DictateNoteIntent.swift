// by zayd/cold @ zayd.wtf

import AppIntents
import AVFoundation
import Foundation
import UIKit
import ActivityKit
import ZoneCore

/// One pending mode, so two cold-launch requests cannot leave an older mode to replay later.
@MainActor private enum PendingShortcut {
    static var noteMode: Bool?
    static var noteFailure: String?
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

    /// Before first unlock there is no graph to own the error. Keep it in memory until the
    /// graph arrives, without reading or writing protected preferences in the meantime. Once a
    /// coordinator holds it, `notePressFailed` also saves the reason (`NoteStartFailureRecord`),
    /// so Home can still say it if iOS ends Zone before the next open.
    @MainActor
    static func noteFailed(_ message: String, notify: @MainActor (String) async -> Void = NoteStartFailureNotice.post) async {
        guard !message.isEmpty else { return }
        if let coordinator = DictationCoordinator.shortcutCoordinator {
            PendingShortcut.noteFailure = nil
            if coordinator.notePressFailed(message) { await notify(message) }
        } else {
            PendingShortcut.noteFailure = message
            await notify(message)
        }
    }

    @MainActor
    static func restoreNoteFailure() {
        guard let coordinator = DictationCoordinator.shortcutCoordinator,
              let message = PendingShortcut.noteFailure else { return }
        PendingShortcut.noteFailure = nil
        coordinator.notePressFailed(message)
    }

    /// A button on Zone's own card. Always in the background: it never opens Zone.
    @MainActor
    static func island(_ action: IslandAction) async throws {
        AppEntry.noteAutomation("island")
        try AppLaunch.wakeForRecording(trigger: "island")
        let coordinator = DictationCoordinator.shortcutCoordinator
        Journal.log("islandControl", ["action": action.rawValue,
            "armed": String(coordinator?.isArmed == true),
            "busy": String(coordinator?.activity.isBusy == true),
            "foreground": String(UIApplication.shared.applicationState == .active)])
        guard let coordinator else {
            throw DictationCoordinator.ShortcutFailure(message: AppLaunch.missingMessage(otherwise: "Open Zone once to finish setup, then try again."))
        }
        // A press: an aging card starts its eight hours over before the button acts on it.
        coordinator.keepIslandDuringPress("island", restoreMissing: false)
        try await coordinator.performIslandAction(action)
    }

    /// Bring back Zone's island (Control Center, the Action Button, a Shortcuts automation).
    /// Always in the background, and never turns the microphone on.
    @MainActor
    static func showIsland() async throws {
        AppEntry.noteAutomation("showIsland")
        try AppLaunch.wakeForRecording(trigger: "showIsland")
        let coordinator = DictationCoordinator.shortcutCoordinator
        Journal.log("showIslandPressed", ["armed": String(coordinator?.isArmed == true),
            "busy": String(coordinator?.activity.isBusy == true),
            "foreground": String(UIApplication.shared.applicationState == .active)])
        if let meeting = MeetingCoordinator.current, meeting.isRecording {
            _ = meeting.restoreRecordingLiveActivity()
        } else {
            coordinator?.keepIslandDuringPress("showIsland", restoreMissing: true)
        }
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
        PressTiming.mark("intent")
        let began = ProcessInfo.processInfo.systemUptime
        // What's New must never open on a visit a Shortcut began.
        AppEntry.noteAutomation("shortcut")
        try AppLaunch.wakeForRecording(trigger: "shortcut")
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
                    try await self.runZoneShortcutBody(noteMode: noteMode, desiredState: desiredState, pressedAt: began)
                } catch {
                    // Failed preparation can leave standby audio behind too. Preserve the
                    // original error if cleanup succeeds. If policy recovery needed to save
                    // another recording, return that more relevant explanation instead.
                    try await DictationCoordinator.shortcutCoordinator?.settleRecordingShortcut()
                    throw error
                }
                try await DictationCoordinator.shortcutCoordinator?.settleRecordingShortcut()
            }.value
        } catch let unchanged as RecordingUnchanged {
            throw unchanged
        } catch let failure as DictationCoordinator.ShortcutFailure {
            Journal.log("shortcutRefused", ["invocation": invocation, "message": failure.message])
            if noteMode { await ZoneIntentHost.noteFailed(failure.message) }
            throw failure
        } catch let failure as RecordingLiveActivity.Failure where failure == .disabled {
            // Zone's own message already says what to do (turn on Live Activities); keep it.
            Journal.log("shortcutRefused", ["invocation": invocation, "message": "liveActivitiesDisabled"])
            if noteMode { await ZoneIntentHost.noteFailed(failure.errorDescription ?? "") }
            throw failure
        } catch {
            Journal.log("shortcutFailed", ["invocation": invocation, "error": JournalFormat.error(error)])
            let plain = Self.plainFailure(for: error)
            if noteMode { await ZoneIntentHost.noteFailed(plain.message) }
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

    /// AVAudioSession's "insufficient priority" (!pri) and "Siri is recording" (siri): the
    /// microphone belongs to a call or Siri. "Busy" (!act, 561015905) is not one of them: on
    /// Zayd's phone it came with no call or Siri running and a second press worked, so it gets
    /// `PressArmRetry` and then "press again", not an answer that sends the person to wait.
    static func microphoneIsBusy(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSOSStatusErrorDomain && [561_017_449, 1_936_290_409].contains(error.code)
    }

    @MainActor
    private func runZoneShortcutBody(noteMode: Bool, desiredState requestedState: Bool?, pressedAt: TimeInterval) async throws {
        // An Off right after this control's recording ended by itself is a press of a button
        // that still shows On: it starts (`NoteActionPolicy.offPressStarts`).
        PressTiming.mark("fifo")
        let desiredState = DictationCoordinator.shortcutCoordinator?
            .resolveControlPress(noteMode: noteMode, desiredState: requestedState) ?? requestedState
        // Inside a press iOS makes Zone a card even from the background: an aging standby card
        // starts its eight hours over here, before this press records into it.
        DictationCoordinator.shortcutCoordinator?.keepIslandDuringPress("shortcut", restoreMissing: false)
        if let coordinator = DictationCoordinator.shortcutCoordinator,
           try await coordinator.finishStartingShortcut(noteMode: noteMode, desiredState: desiredState) { return }
        let finishingID = DictationCoordinator.shortcutCoordinator?.shortcutRequestToFinish(noteMode: noteMode)
        // A press that would start must never be dropped silently because an earlier
        // recording is still finishing or holds the microphone.
        if finishingID == nil, desiredState != false, let coordinator = DictationCoordinator.shortcutCoordinator {
            PressTiming.mark("clear")
            try await coordinator.clearWayForShortcutStart(noteMode: noteMode)
        }
        // Resolve desired state after earlier accepted presses finish. A duplicate On is
        // idempotent; Off on an idle/mismatched mode never arms the microphone.
        PressTiming.mark("cleared")
        if let desiredState {
            if let coordinator = DictationCoordinator.shortcutCoordinator {
                guard coordinator.shouldRunRecordingControl(noteMode: noteMode, desiredState: desiredState) else {
                    throw RecordingUnchanged(message: coordinator.startRefusal ?? RecordingRefusal.idle)
                }
            } else if !desiredState { throw RecordingUnchanged(message: RecordingRefusal.idle) }
        }
        guard let coordinator = DictationCoordinator.shortcutCoordinator else {
            throw DictationCoordinator.ShortcutFailure(message: AppLaunch.missingMessage(otherwise: "Open Zone once to finish setup, then run this shortcut again."))
        }
        guard finishingID != nil || ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw RecordingLiveActivity.Failure.disabled
        }
        if finishingID == nil, !coordinator.shortcutCanRunWarm {
            do {
                // LiveActivityIntent grants the activity creation context. Try that path
                // before a foreground handoff that Settings/Shortcuts may not allow.
                try await coordinator.prepareRecordingShortcut(noteMode: noteMode, pressedAt: pressedAt)
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
                // A control cannot bring Zone forward, so say what worked on the phone (1.0.3 to
                // 1.0.5): away from the car a second press recorded every time; with CarPlay four
                // presses in nine seconds all failed, and opening Zone first was what recorded.
                try await continueZoneInForeground(otherwise: Self.pressRefusal(
                    carPlay: CarAudioRoute.isCarPlay(AVAudioSession.sharedInstance().currentRoute)))
                try await coordinator.prepareRecordingShortcut(noteMode: noteMode, pressedAt: pressedAt)
            }
        }
        // Only a system control supplies a desired state. Siri and automations can run the same shortcut.
        let trigger: DictationCoordinator.RecordingTrigger = requestedState == nil ? .shortcut : .control
        do {
            try await coordinator.runRecordingShortcut(noteMode: noteMode, finishing: finishingID, trigger: trigger)
        } catch RecordingLiveActivity.Failure.foregroundRequired {
            // ActivityKit can reject creation while backgrounded even for recording intents.
            // Retry once in the foreground; never activate hidden capture without its activity.
            guard UIApplication.shared.applicationState != .active else { throw RecordingLiveActivity.Failure.foregroundRequired }
            // On a locked phone this handoff is the passcode screen, so the log names it.
            Journal.log("shortcutForegroundRequested", ["reason": "liveActivity",
                "locked": String(!UIApplication.shared.isProtectedDataAvailable)])
            try await continueZoneInForeground()
            try await coordinator.clearWayForShortcutStart(noteMode: noteMode)
            try await coordinator.prepareRecordingShortcut(noteMode: noteMode, pressedAt: pressedAt)
            try await coordinator.runRecordingShortcut(noteMode: noteMode, finishing: nil, trigger: trigger)
        }
    }

    /// The Toggle Zone control. Off ends the session where it is. On brings Zone to the front
    /// first: a microphone held ready with no Live Activity has to be started in the foreground.
    @MainActor
    func runZoneStandby(on: Bool) async throws {
        AppEntry.noteAutomation("standbyControl")
        try AppLaunch.wakeForRecording(trigger: "standbyControl")
        let coordinator = DictationCoordinator.shortcutCoordinator
        Journal.log("standbyControl", ["requestedState": on ? "on" : "off",
            "armed": String(coordinator?.isArmed == true),
            "foreground": String(UIApplication.shared.applicationState == .active)])
        guard let coordinator else {
            if !on { return }
            throw DictationCoordinator.ShortcutFailure(message: AppLaunch.missingMessage(otherwise: "Open Zone once to finish setup, then press again."))
        }
        guard on else { return try coordinator.turnStandbyOffFromControl() }
        // Already on (a Shortcut set it On, or the control's state was behind): the press still
        // brings back a missing card, which iOS allows only inside a press like this one.
        guard !coordinator.isArmed else { return coordinator.keepIslandDuringPress("standbyControl", restoreMissing: true) }
        if UIApplication.shared.applicationState != .active {
            try await continueZoneInForeground(otherwise: "Open Zone, then turn it on.")
        }
        coordinator.turnStandbyOnFromControl()
    }

    /// What a press says when the microphone would not start and iOS will not bring Zone forward.
    /// "Open Zone once to start its microphone session" sent people to the wrong fix.
    static func pressRefusal(carPlay: Bool) -> String {
        carPlay ? "With CarPlay, Zone cannot start the microphone in the background. Open Zone, then press again."
            : "Zone's microphone did not start. Press again."
    }

    /// `otherwise` is what the press says when iOS will not bring Zone forward from here.
    @MainActor
    private func continueZoneInForeground(otherwise: String = "Open Zone, then press again.") async throws {
        if #available(iOS 26.0, *) {
            guard systemContext.currentMode.canContinueInForeground else {
                throw DictationCoordinator.ShortcutFailure(message: otherwise)
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
    static let description = IntentDescription("The words of the last dictation or voice note finished in the past five minutes.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        AppEntry.noteAutomation("lastDictationShortcut")
        guard UIApplication.shared.isProtectedDataAvailable else {
            throw DictationCoordinator.ShortcutFailure(message: "Unlock your iPhone, then run this again.")
        }
        let result = try Self.recentForShortcut()?.words
        guard let result else {
            throw DictationCoordinator.ShortcutFailure(message: "No words from a recording finished in the past five minutes.")
        }
        return .result(value: result, dialog: "Last finished recording.")
    }

    static func recentResult(history: TranscriptHistory?, notesURL: URL, now: Date = Date()) throws -> String? {
        try recent(history: history, notesURL: notesURL, now: now)?.words
    }

    @MainActor fileprivate static func recentForShortcut() throws -> (words: String, finishedAt: Date?)? {
        do { return try recent(history: TranscriptHistory.shared, notesURL: NotesStore.fileURL) }
        catch { throw DictationCoordinator.ShortcutFailure(message: "Zone could not read your last recording. Unlock your iPhone and open Home to try again.") }
    }

    /// The words and the finish time of the latest recording, when it finished in the past five
    /// minutes (a clock set back by up to a minute still counts). Never an earlier recording.
    static func recent(history: TranscriptHistory?, notesURL: URL, now: Date = Date()) throws -> (words: String, finishedAt: Date?)? {
        guard let last = history?.lastRecordingEvent(now: now), (-60...300).contains(now.timeIntervalSince(last.at)) else { return nil }
        if last.isNote != false {
            // Old receipts had only an ID. A matching saved note is authoritative even
            // after an edit removed the raw History row. Never return an older recording.
            guard let note = try LibraryNotesFile.read(at: notesURL).first(where: { $0.recordingID == last.id }),
                  !note.text.isEmpty else { return nil }
            // An edit can remove the raw History row; the receipt still has the time.
            if let record = last.record { return (note.text, record.finishedAt) }
            return (note.text, last.at)
        }
        guard let words = recentResult(last.record, now: now) else { return nil }
        return (words, last.record?.finishedAt)
    }

    static func recentResult(_ latest: TranscriptRecord?, now: Date = Date()) -> String? {
        let finished: [TranscriptStatus] = [.finished, .inserted, .offered, .dismissed, .note, .sentRemote, .heldOnComputer, .notDelivered]
        guard let latest, finished.contains(latest.status),
              !latest.text.isEmpty else { return nil }
        let date = latest.finishedAt ?? latest.createdAt
        guard (-60...300).contains(now.timeIntervalSince(date)) else { return nil }
        return latest.text
    }
}

struct LastDictationFinishTimeIntent: AppIntent {
    static let title: LocalizedStringResource = "Get last dictation finish time"
    static let description = IntentDescription("The time the last recent dictation or voice note finished.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Date> {
        guard UIApplication.shared.isProtectedDataAvailable else {
            throw DictationCoordinator.ShortcutFailure(message: "Unlock your iPhone, then run this again.")
        }
        guard let date = try LastDictationIntent.recentForShortcut()?.finishedAt else {
            throw DictationCoordinator.ShortcutFailure(message: "No recent recording has a finish time.")
        }
        return .result(value: date)
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
        AppShortcut(
            intent: SaveToClipboardIntent(),
            phrases: ["Save my clipboard to \(.applicationName)", "Keep this copy in \(.applicationName)"],
            shortTitle: "Save to Zone Clipboard",
            systemImageName: "clipboard")
    }
}
