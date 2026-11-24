// by zayd/cold @ zayd.wtf

import Foundation
import UIKit
import UserNotifications
import ZoneCore

/// Quiet notices work in the background. Only the banner request in Settings can
/// show the system prompt. Home explains the first quiet request when the person returns.
enum ZoneNoticePermission {
    static let message = "Zone can tell you when a recording stops, standby ends, or the Dynamic Island goes away."
    static let requestedKey = "zone.quietNotificationsRequested"
    static let explainedKey = "zone.notificationExplanationSeen"

    static func needsExplanation(requested: Bool, status: UNAuthorizationStatus, explained: Bool) -> Bool {
        !explained && (requested || status == .provisional)
    }

    @MainActor static func quiet(_ center: UNUserNotificationCenter) async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        guard status == .notDetermined else { return status != .denied }
        if UIApplication.shared.isProtectedDataAvailable {
            UserDefaults.standard.set(true, forKey: requestedKey)
        }
        return (try? await center.requestAuthorization(options: [.provisional, .alert, .sound])) ?? false
    }
}

/// A dead man's switch for recordings. A killed app runs no code, so it cannot announce that its
/// recording survived. While recording, a "your recording is saved" notification stays scheduled
/// 30 s ahead and is pushed back on every save tick; a clean stop or cancel withdraws it. If Zone
/// is killed (an install, jetsam, a dead battery that comes back), the notification fires on its
/// own and points at the recovery card. Provisional authorization delivers it quietly with no
/// permission prompt.
@MainActor
enum RecordingSafetyNotice {
    private static let identifier = "wtf.zayd.zone.recording-safety"
    private static var authorized = false
    /// Bumped by `disarm`, so an `arm` still awaiting authorization cannot schedule afterwards.
    private static var generation = 0

    static func arm() {
        let center = UNUserNotificationCenter.current()
        let token = generation
        Task {
            if !authorized {
                authorized = await ZoneNoticePermission.quiet(center)
            }
            guard authorized, token == generation else { return }
            let content = UNMutableNotificationContent()
            content.title = "Recording interrupted"
            content.body = "Open Home in Zone to check for saved audio."
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 30, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
            // A disarm that landed while add was in flight wins.
            if token != generation { center.removePendingNotificationRequests(withIdentifiers: [identifier]) }
        }
    }

    static func disarm() {
        generation += 1
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}

/// Controls do not reliably display thrown intent errors. This receipt names the refusal even
/// if there is no app graph yet (before first unlock). It never reads preferences or note data.
@MainActor
enum NoteStartFailureNotice {
    private static let identifier = "wtf.zayd.zone.note-start-failed"
    private static var generation = 0

    static func post(_ message: String) async {
        generation += 1
        let token = generation
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            _ = await ZoneNoticePermission.quiet(center)
        }
        guard token == generation else { return }
        let content = UNMutableNotificationContent()
        content.title = "Voice note did not start"
        content.body = message
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        if token != generation { center.removeDeliveredNotifications(withIdentifiers: [identifier]) }
    }

    static func clear() {
        generation += 1
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}

/// The reason the last voice-note press failed, kept so Home can still say it after iOS ends
/// Zone's process. With notifications denied or hidden by a Focus, Home is the only receipt,
/// and a process evicted between the press and the next open used to lose it.
///
/// Only Zone's own one-sentence refusal and the time are kept: no words, audio or note data.
/// Only a running `DictationCoordinator` touches it, and that exists only after the first
/// unlock, so a press before then still keeps its reason in memory alone (`ZoneIntentHost`).
/// A saved reason older than `lifetime` is dropped instead of shown.
struct NoteStartFailureRecord {
    static let key = "zone.noteStartFailure"
    /// Long enough for a press in the morning to explain itself that evening, short enough that
    /// a refusal is never shown the next day as if it had just happened.
    static let lifetime: TimeInterval = 12 * 60 * 60
    /// Refusals are one short sentence. Anything longer is not one of them and is not kept.
    static let maxLength = 300
    private static let fallback = "Zone could not start recording. Open Zone, then press again."
    private static let reasons: Set<String> = [
        KeyboardRecordingClaim.pressRefusal, AudioRecoveryError.unavailable.localizedDescription, fallback, "Unlock your iPhone, then press again.", "Zone's microphone did not start. Press again.",
        "Open Zone, then press again.", "Open Zone and allow microphone access, then press again.",
        "Open Zone once to finish setup, then run this shortcut again.",
        "The microphone is in use by a call or Siri. Press again when it ends.",
        "With CarPlay, Zone cannot start the microphone in the background. Open Zone, then press again.",
        "iOS did not let Zone open just now. Unlock your iPhone and press again.",
        "Zone could not show its recording in the Dynamic Island. Open Zone once, then press again.",
        "Live Activities are unavailable. Open Zone to record, or enable Live Activities for Zone in Settings.",
        "Zone is off. Open Zone to turn it on, then try again.",
        RecordingRefusal.starting, RecordingRefusal.writing, RecordingRefusal.recording,
        RecordingRefusal.note, RecordingRefusal.meeting, RecordingRefusal.clip,
        RecordingRefusal.voiceSetup, RecordingRefusal.retry
    ]
    /// A clock set back a little can put a fresh press slightly in the future.
    static let clockSkew: TimeInterval = 5 * 60

    struct Saved: Equatable {
        let message: String
        let at: Date
    }

    let defaults: UserDefaults

    static var standard: NoteStartFailureRecord { NoteStartFailureRecord(defaults: .standard) }

    func save(_ message: String, at date: Date) {
        guard Self.keeps(message) else { return clear() }
        let reason = Self.reasons.contains(message) ? message : Self.fallback
        defaults.set(["message": reason, "at": date.timeIntervalSince1970], forKey: Self.key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }

    /// The saved reason while it is current. An expired or unreadable one is removed.
    func current(now: Date) -> Saved? {
        guard let stored = defaults.object(forKey: Self.key) else { return nil }
        guard let fields = stored as? [String: Any],
              let message = fields["message"] as? String,
              let seconds = (fields["at"] as? NSNumber)?.doubleValue,
              Self.reasons.contains(message) else {
            clear()
            return nil
        }
        let at = Date(timeIntervalSince1970: seconds)
        let age = now.timeIntervalSince(at)
        guard age >= -Self.clockSkew, age < Self.lifetime else {
            clear()
            return nil
        }
        return Saved(message: message, at: at)
    }

    private static func keeps(_ message: String) -> Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && message.count <= maxLength
    }
}

/// Only the action and known Zone errors cross onto a recording screen.
enum RecordingProblem: String {
    case microphone = "Open Zone and try the microphone again."
    case load = "Zone could not load the speech model. Open Models in Settings and try again."
    case transcribe = "Zone could not write out the words. Check Home to retry the recording."
    case testClip = "Zone could not write out the test clip. Check the speech model in Settings and try again."
    case storage = "Zone could not finish saving the recording. Check Home and free up space before trying again."
    case removeModel = "Some model files remain. Try removing them again."

    func message(for error: Error) -> String {
        if error is Watchdog.Stalled, self == .transcribe {
            return "The speech model did not respond. Check Home to try the recording again."
        }
        if let failure = error as? DictationCoordinator.ShortcutFailure { return failure.message }
        if let capture = error as? CaptureError, let reason = capture.errorDescription { return reason }
        if let card = error as? RecordingLiveActivity.Failure, let reason = card.errorDescription { return reason }
        if let recovery = error as? AudioRecoveryError {
            switch recovery {
            case .emptyTranscript: return "No words were found. Check Home for audio to try again."
            case .missingAudio: return "This recording has no audio. Start a new recording."
            case .unavailable, .writerOverloaded: return recovery.errorDescription ?? Self.storage.rawValue
            }
        }
        let failure = error as NSError
        if failure.domain == NSOSStatusErrorDomain && [561_017_449, 1_936_290_409].contains(failure.code) {
            return "The microphone is in use by a call or Siri. Try again when it ends."
        }
        if failure.domain == NSCocoaErrorDomain && failure.code == NSFileWriteOutOfSpaceError {
            return AudioRecoveryError.unavailable.localizedDescription
        }
        if failure.domain == NSURLErrorDomain {
            return "Check your connection and try the speech model download again."
        }
        if let speech = error as? SpeechEngineError, case .unavailable(let reason) = speech,
           [KeyboardRecordingClaim.appRefusal, RecordingRefusal.meeting, RecordingRefusal.note, RecordingRefusal.retry,
            "Model storage is being cleaned. Try again when it finishes.",
            "Check microphone access in Settings, then try again.",
            "Choose Fluid Speech Mini in Zone to transcribe this recording.",
            "Download Fluid Speech Mini in Zone to finish your saved recording."].contains(reason) { return reason }
        return rawValue
    }
}

/// A stop required by an intent's missing recording indicator survives process exit.
struct RecordingCardStopNotice {
    enum Outcome: String {
        case unconfirmed, saved, noSamples

        var message: String {
            switch self {
            case .unconfirmed: "The recording card closed. Open Home to check for audio."
            case .saved: "The recording card closed. Open Home to try the saved audio."
            case .noSamples: "The recording card closed before audio arrived. Start a new recording."
            }
        }
    }

    private let key = "zone.recordingCardStop"
    let defaults: UserDefaults

    var message: String? {
        guard let raw = defaults.dictionary(forKey: key)?["outcome"] as? String else { return nil }
        return Outcome(rawValue: raw)?.message
    }

    func begin(_ id: UUID) {
        defaults.set(["id": id.uuidString, "outcome": Outcome.unconfirmed.rawValue], forKey: key)
    }

    func settled(_ id: UUID, as outcome: Outcome) {
        guard defaults.dictionary(forKey: key)?["id"] as? String == id.uuidString else { return }
        defaults.set(["id": id.uuidString, "outcome": outcome.rawValue], forKey: key)
    }

    @MainActor static func notify(_ message: String) async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional || status == .ephemeral else { return }
        let content = UNMutableNotificationContent()
        content.title = "Recording stopped"
        content.body = message
        try? await center.add(UNNotificationRequest(identifier: "wtf.zayd.zone.card-stop", content: content, trigger: nil))
    }

    func dismiss() { defaults.removeObject(forKey: key) }
}
