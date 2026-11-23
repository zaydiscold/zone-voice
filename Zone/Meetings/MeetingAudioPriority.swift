// by zayd/cold @ zayd.wtf

import AVFoundation
import ZoneCore

/// Suppresses ringtones and system alerts when iOS permits it. An answered call and a full
/// screen incoming-call presentation can still take the microphone; interruption recovery
/// handles those without claiming that an app can turn on Do Not Disturb.
@MainActor
enum MeetingAudioPriority {
    private static var previousPreference: Bool?

    static func apply() {
        let session = AVAudioSession.sharedInstance()
        if previousPreference == nil { previousPreference = session.prefersNoInterruptionsFromSystemAlerts }
        do { try session.setPrefersNoInterruptionsFromSystemAlerts(true) }
        catch { Journal.log("meetingAlertPreferenceFailed", ["error": JournalFormat.error(error)]) }
    }

    static func restore() {
        guard let previousPreference else { return }
        Self.previousPreference = nil
        try? AVAudioSession.sharedInstance().setPrefersNoInterruptionsFromSystemAlerts(previousPreference)
    }
}
