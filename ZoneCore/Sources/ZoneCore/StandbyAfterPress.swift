// by zayd/cold @ zayd.wtf

import Foundation

/// What happens to the ready microphone when an Action Button, Shortcut or control press has
/// finished (`DictationCoordinator.settleRecordingShortcut`).
///
/// iOS ends an app whose recording intent returns with the audio session active and no Live
/// Activity ("AudioRecordingIntent was performed with an active audio session but without a
/// Live Activity"). Before Zone had a standby card, the only safe answer was to turn the
/// microphone off after every press, so a note from the Action Button also ended a standby the
/// person had turned on: the island went back to the system's, and the keyboard's next mic tap
/// had to open Zone. The standby card is a Live Activity, so with it up the microphone can stay.
public enum StandbyAfterPress {
    public enum Outcome: Equatable, Sendable {
        /// The microphone stays ready for the person's "Keep microphone ready" time.
        case keep
        /// The microphone is turned off, as after every press before the standby card existed.
        case release
    }

    public struct Situation: Equatable, Sendable {
        /// The session is armed right now, with the microphone itself running.
        public var isArmed: Bool
        /// This press turned the microphone on; false when standby was already on.
        public var armedByPress: Bool
        /// Settings > Dynamic Island > Show Zone during standby. Off, there is no card to keep
        /// the microphone under, so every press releases it.
        public var showsStandbyCard: Bool
        /// Settings > Turn on when Zone opens: the person wants Zone ready without asking.
        public var turnsOnWhenZoneOpens: Bool
        /// The person turned Zone off themselves and has not turned it on since.
        public var turnedOffByPerson: Bool
        /// CarPlay is the audio route and nobody turned standby on there: the car keeps its
        /// stereo media, so the microphone is held only while recording (`CarAudioRoute`).
        public var carKeepsItsAudio: Bool

        public init(isArmed: Bool, armedByPress: Bool, showsStandbyCard: Bool, turnsOnWhenZoneOpens: Bool,
                    turnedOffByPerson: Bool, carKeepsItsAudio: Bool) {
            self.isArmed = isArmed
            self.armedByPress = armedByPress
            self.showsStandbyCard = showsStandbyCard
            self.turnsOnWhenZoneOpens = turnsOnWhenZoneOpens
            self.turnedOffByPerson = turnedOffByPerson
            self.carKeepsItsAudio = carKeepsItsAudio
        }
    }

    /// - A standby that was on before the press stays on: a note must never turn Zone off.
    /// - A press that had to turn the microphone on leaves it ready the way opening Zone
    ///   would, so the next press inside "Keep microphone ready" starts at once and the
    ///   keyboard's mic works in place. Not for someone who turned Zone off themselves or who
    ///   does not let Zone turn itself on: for them the press borrows the microphone and
    ///   gives it back.
    public static func outcome(_ situation: Situation) -> Outcome {
        guard situation.isArmed, situation.showsStandbyCard, !situation.carKeepsItsAudio else { return .release }
        guard situation.armedByPress else { return .keep }
        return situation.turnsOnWhenZoneOpens && !situation.turnedOffByPerson ? .keep : .release
    }
}
