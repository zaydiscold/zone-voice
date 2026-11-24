// by zayd/cold @ zayd.wtf

import Foundation
import UserNotifications

/// A dead man's switch for standby, as `RecordingSafetyNotice` is for recordings. While Zone waits
/// with the microphone ready, a "Zone is off" notice stays scheduled `lead` seconds ahead and is
/// pushed back by standby's heartbeat. Turning Zone off on purpose (Turn off, its timeout, the
/// Toggle Zone control, CarPlay giving the car its audio back) withdraws it. If Zone is killed
/// (an update, the system reclaiming memory, a force quit) or its microphone cannot come back, it
/// fires, so the person learns the keyboard's mic will open Zone again instead of finding out on
/// the next tap. One notice at a time (one identifier), cleared when Zone is in front.
///
/// Clearing Zone's card from the Lock Screen turns Zone off too, and says so here at once
/// (`postCleared`).
///
/// The phone's journal over nine days: 224 standby interruptions, 216 handed back by iOS (no
/// notice), and 80 relaunches of a Zone that had died. Provisional authorization, as for the
/// recording notice: delivered quietly to Notification Center with no permission prompt, unless
/// the person lets Zone's notices show prominently.
@MainActor
enum StandbyStoppedNotice {
    static let identifier = "wtf.zayd.zone.standby-stopped"
    /// How long standby can go without a heartbeat before the notice fires.
    static let lead: TimeInterval = 90
    /// How often the heartbeat pushes it back: two notification calls a minute while waiting.
    static let refresh: TimeInterval = 30

    private static var authorized = false
    /// Bumped by every schedule and withdraw: only the newest schedule still awaiting
    /// authorization is added, and a withdraw wins over an add in flight.
    private static var generation = 0
    private static var lastScheduled: Date?
    private(set) static var isScheduled = false

    /// Standby is on: keeps the notice `lead` seconds ahead, rescheduling at most every `refresh`.
    /// `force` reschedules now: standby just armed or came back, replacing a longer hold.
    static func keepAlive(force: Bool = false, now: Date = Date()) {
        if !force, isScheduled, let lastScheduled, now.timeIntervalSince(lastScheduled) < refresh { return }
        schedule(after: lead, now: now)
    }

    /// Standby is held by a call or Siri, or its microphone failed: fires after `delay` unless
    /// standby comes back first.
    static func schedule(after delay: TimeInterval, now: Date = Date()) {
        lastScheduled = now
        isScheduled = true
        generation += 1
        let token = generation
        let center = UNUserNotificationCenter.current()
        Task {
            if !authorized {
                authorized = await ZoneNoticePermission.quiet(center)
            }
            guard authorized, token == generation else { return }
            let content = UNMutableNotificationContent()
            content.title = "Zone is off"
            content.body = "Open Zone to turn it back on, so the keyboard's mic works without leaving your app."
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
            // A withdraw that landed while add was in flight wins. A newer schedule replaces this
            // one by its later add under the same identifier.
            if token != generation, !isScheduled { center.removePendingNotificationRequests(withIdentifiers: [identifier]) }
        }
    }

    /// The person cleared Zone's card from the Lock Screen, and Zone turned off with it
    /// (`IslandUpkeep.Response.turnOff`): says so now, under the same identifier, so there is
    /// only ever one "Zone is off" and Zone in front clears it. Seen, not heard.
    static func postCleared() {
        generation += 1
        isScheduled = false
        lastScheduled = nil
        let token = generation
        let center = UNUserNotificationCenter.current()
        Task {
            if !authorized {
                authorized = await ZoneNoticePermission.quiet(center)
            }
            // A standby armed meanwhile has scheduled its own; that one stands.
            guard authorized, token == generation else {
                Journal.log("clearedCardNotice", ["posted": "false"])
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Zone is off"
            content.body = "You cleared Zone from the Lock Screen, so its microphone is off. Open Zone to turn it back on."
            try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            Journal.log("clearedCardNotice", ["posted": "true"])
        }
    }

    /// Standby ended on purpose, or a recording now owns the microphone (its own notice covers it).
    static func withdraw() {
        guard isScheduled else { return }
        generation += 1
        isScheduled = false
        lastScheduled = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    /// Zone is in front again: a notice that already fired is stale.
    static func clearDelivered() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
