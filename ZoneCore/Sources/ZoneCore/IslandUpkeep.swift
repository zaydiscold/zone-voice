// by zayd/cold @ zayd.wtf

import Foundation

/// When Zone replaces its Dynamic Island card, and what it does when the card is gone.
///
/// iOS ends a Live Activity eight hours after it starts, and makes a new one only for an app in
/// front or inside one of the app's own intents (an Action Button, Control Center or Shortcuts
/// press). Standby can outlast both. Zayd's phone, November 9 to 18: Zone sat in the background
/// with the microphone ready for more than eight hours five times, through days of keyboard
/// dictation without opening Zone (the longest 13 hours, with 26 dictations).
///
/// Replaying those nine days of app switches, renewing whenever Zone could and the card was at
/// least 30 minutes old left the same five cards to the limit as renewing at every chance, and
/// the old rule (four hours, half the limit) left seven. The threshold only stops Zone from
/// replacing a card it has just made: about ten invisible replacements a day instead of 48.
/// The long days are reached by a relay card iOS 26 starts on schedule before the limit, even in
/// the background (`RecordingLiveActivity.relay`, 16 hours from the last visit or press), by
/// renewing during presses, by "Bring back Zone's island" (which a Shortcuts automation can run
/// with no tap), and by a notification when a card ends anyway.
public enum IslandUpkeep {
    /// iOS's limit on one Live Activity.
    public static let systemLimit: TimeInterval = 8 * 3600
    /// A card at least this old is replaced whenever Zone may make a new one: in front, or
    /// inside a press. Leaving Zone, the card always has at least 7.5 hours left.
    public static let renewAfter: TimeInterval = 30 * 60

    /// A held card (an interruption has the microphone) is never replaced: its state belongs to
    /// the interruption, and a new card would read as ready while the microphone is away.
    public static func shouldRenew(age: TimeInterval, held: Bool) -> Bool {
        !held && age >= renewAfter
    }

    /// How iOS reported a card gone that Zone did not end.
    public enum Ending: String, Sendable {
        /// iOS ended it: its time limit, or any other end Zone did not ask for.
        case ended
        /// It was removed: the person cleared it from the Lock Screen or Notification Center.
        case dismissed
    }

    /// Standby, as it stands whenever the card might have changed: a card went, standby took
    /// the microphone back, a recording settled, Zone came to the front.
    public struct Situation: Equatable, Sendable {
        /// Settings > Dynamic Island > Show Zone during standby.
        public var showsIsland: Bool
        /// Live Activities are allowed for Zone (iOS Settings). Off, no card can ever be made.
        public var activitiesEnabled: Bool
        /// The microphone is on and waiting: armed, not recording, no meeting.
        public var microphoneReady: Bool
        /// Zone's card is up.
        public var hasCard: Bool
        /// Zone is on screen, where a card can be made at once.
        public var inFront: Bool
        /// The person cleared the card from the Lock Screen or Notification Center, and no
        /// card has been made since.
        public var clearedByPerson: Bool
        /// Settings > Dynamic Island > Tell me if it ends.
        public var notifies: Bool
        /// This loss has been told about already.
        public var alreadyNotified: Bool

        public init(showsIsland: Bool, activitiesEnabled: Bool = true, microphoneReady: Bool, hasCard: Bool,
                    inFront: Bool, clearedByPerson: Bool = false, notifies: Bool = true, alreadyNotified: Bool = false) {
            self.showsIsland = showsIsland
            self.activitiesEnabled = activitiesEnabled
            self.microphoneReady = microphoneReady
            self.hasCard = hasCard
            self.inFront = inFront
            self.clearedByPerson = clearedByPerson
            self.notifies = notifies
            self.alreadyNotified = alreadyNotified
        }
    }

    public enum Response: Equatable, Sendable {
        /// The card is up, or nothing needs one, or there is nothing more to say.
        case nothing
        /// Zone is in front: make the card again now.
        case restoreNow
        /// The microphone is on with no card of Zone's, so iOS draws its orange indicator and
        /// only a press or opening Zone can bring the card back: say so, once.
        case notify
        /// The person cleared Zone's card while Zone was not in front. Clearing it is turning
        /// Zone off: the microphone is released, so iOS draws no orange indicator, and a
        /// "Zone is off" notification says how to turn it back on (Zayd, 2026-11-20).
        case turnOff
    }

    public static func response(to situation: Situation) -> Response {
        guard situation.showsIsland, situation.activitiesEnabled, situation.microphoneReady,
              !situation.hasCard else { return .nothing }
        if situation.inFront { return .restoreNow }
        // The person cleared the card. Keeping the microphone on behind iOS's orange indicator
        // would argue with them: Zone turns off. Checked here, after `microphoneReady`, so a
        // card cleared during a recording or a call turns Zone off once that has settled.
        if situation.clearedByPerson { return .turnOff }
        guard situation.notifies, !situation.alreadyNotified else { return .nothing }
        return .notify
    }

    /// What a recording does when its own card goes without Zone ending it.
    public enum RecordingResponse: Equatable, Sendable {
        /// The person cleared the card, the control they were given: stop and keep the words.
        case stop
        /// iOS took the card (its eight-hour limit counts from when the card was made, which
        /// can be hours of standby before the recording began). Nobody asked for the recording
        /// to end, so it goes on, and the card is made again as soon as iOS allows one.
        case keepRecording
    }

    public static func recordingResponse(to ending: Ending) -> RecordingResponse {
        ending == .dismissed ? .stop : .keepRecording
    }

    /// The card went at iOS's limit, not for another reason, so the notification can say so.
    public static func reachedSystemLimit(age: TimeInterval) -> Bool {
        age >= systemLimit - 60
    }
}
