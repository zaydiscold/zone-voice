// by zayd/cold @ zayd.wtf

import Foundation
import UserNotifications

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
                authorized = (try? await center.requestAuthorization(options: [.provisional, .alert, .sound])) ?? false
            }
            guard authorized, token == generation else { return }
            let content = UNMutableNotificationContent()
            content.title = "Recording saved"
            content.body = "Zone closed mid-recording. Open Zone to recover your audio."
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
