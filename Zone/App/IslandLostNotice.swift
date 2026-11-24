// by zayd/cold @ zayd.wtf

import Foundation
import UserNotifications
import ZoneCore

/// "Zone's island ended": posted when Zone's card is gone while the microphone is still on in
/// the background, so iOS draws its orange indicator and nothing of Zone's says why. iOS makes a
/// new card only for Zone in front or inside a press, so the notification is the way back: a tap
/// opens Zone, which makes the card again. Turn Zone off ends standby without opening it.
///
/// Delivered with whatever permission Zone has. Without a choice yet, Zone asks for provisional
/// permission, which needs no prompt and delivers quietly to Notification Center, where iOS
/// offers to keep Zone's notifications. Settings > Dynamic Island asks for banners.
@MainActor
enum IslandLostNotice {
    nonisolated static let identifier = "wtf.zayd.zone.island-lost"
    nonisolated static let category = "wtf.zayd.zone.island-lost"
    nonisolated static let turnOffAction = "wtf.zayd.zone.island-lost.turn-off"
    /// Bumped by `withdraw`, so a post still awaiting permission cannot land afterwards.
    private static var generation = 0

    /// Registered at launch, so the notification's Turn Zone off button exists before one is
    /// posted. Zone's only category: the recording-safety notice has no buttons.
    static func registerCategory() {
        let turnOff = UNNotificationAction(identifier: turnOffAction, title: "Turn Zone off", options: [.destructive])
        UNUserNotificationCenter.current().setNotificationCategories(
            [UNNotificationCategory(identifier: category, actions: [turnOff], intentIdentifiers: [])])
    }

    static func post(reachedLimit: Bool) {
        let center = UNUserNotificationCenter.current()
        let token = generation
        Task {
            let settings = await center.notificationSettings()
            var status = settings.authorizationStatus
            if status == .notDetermined {
                let granted = await ZoneNoticePermission.quiet(center)
                status = granted ? .provisional : .denied
            }
            guard status != .denied, token == generation else {
                Journal.log("islandLostNotice", ["posted": "false", "permission": Self.name(status)])
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Zone's island ended"
            content.body = (reachedLimit ? "iOS ends it after 8 hours. " : "")
                + "The microphone is still on, so iOS shows its orange dot instead. Tap to bring Zone back."
            content.categoryIdentifier = category
            content.threadIdentifier = category
            content.interruptionLevel = .active
            // Seen, not heard: it lands while the person is in another app, often mid-sentence.
            content.sound = nil
            try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            if token != generation { return Self.remove(from: center) }
            Journal.log("islandLostNotice", ["posted": "true", "permission": Self.name(status),
                                             "limit": String(reachedLimit)])
        }
    }

    /// The card is back, or standby ended: the notification no longer describes anything.
    static func withdraw() {
        generation += 1
        remove(from: UNUserNotificationCenter.current())
    }

    private static func remove(from center: UNUserNotificationCenter) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    private static func name(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: "authorized"
        case .provisional: "provisional"
        case .ephemeral: "ephemeral"
        case .denied: "denied"
        case .notDetermined: "notDetermined"
        @unknown default: "unknown"
        }
    }
}

/// Zone's answers to its own notifications. Set as the center's delegate at launch, before the
/// app finishes launching, so a tap that launched Zone still arrives.
///
/// Both methods are the completion-handler forms, and both call the handler on the main thread.
/// The `async` forms let Swift call UIKit's completion from a concurrency thread: after a tap on
/// the notice, UIKit then updated its snapshot off the main thread and ended Zone with an
/// assertion in `-[UIApplication _performBlockAfterCATransactionCommitSynchronizes:]`
/// (build 2026112251, November 22, 2026, 11:09).
final class ZoneNotificationResponder: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ZoneNotificationResponder()

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        answer(identifier: response.notification.request.identifier, action: response.actionIdentifier,
               completion: completionHandler)
    }

    /// Nothing of Zone's shows over Zone itself, as before Zone had a delegate: in front the
    /// card is made again, and the recording-safety notice only fires once Zone is gone.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Self.onMain { completionHandler([]) }
    }

    /// The answer to a tap, from whichever thread iOS delivers it on. `turnOff` and `completion`
    /// both run on the main thread, and `completion` runs exactly once, last.
    func answer(identifier: String, action: String,
                turnOff: @escaping @MainActor () throws -> Void = { try DictationCoordinator.shortcutCoordinator?.turnStandbyOffFromControl() },
                completion: @escaping () -> Void) {
        Self.onMain {
            defer { completion() }
            guard identifier == IslandLostNotice.identifier else { return }
            Journal.log("islandLostNoticeAnswered", ["action": action == IslandLostNotice.turnOffAction ? "turnOff" : "open"])
            // A tap opens Zone, and Zone in front makes the card again (`scenePhaseChanged`).
            guard action == IslandLostNotice.turnOffAction else { return }
            do { try turnOff() }
            catch { Journal.log("islandLostNoticeTurnOffRefused", ["error": JournalFormat.error(error)]) }
        }
    }

    /// Now when already on the main thread, otherwise queued to it.
    static func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated(work) } else { DispatchQueue.main.async { work() } }
    }
}
