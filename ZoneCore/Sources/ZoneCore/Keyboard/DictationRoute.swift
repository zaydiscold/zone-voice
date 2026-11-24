// by zayd/cold @ zayd.wtf

import Foundation

/// Where a press on the keyboard's mic goes. One table, read top to bottom, first match wins.
///
/// Before this the answer was spread over the mic controller: a session reading, a flag for
/// "the next tap opens Zone", a second flag for a stuck mute, the keyboard's own route and
/// whether the press was a hold, combined differently at each place a press could end up.
/// On 2026-11-22 a press that met a session ending under it fell between those places and
/// showed an error instead of acting. Every press, and every second look at a press, now
/// asks this table. (The shape follows anomalyco/hex's `DictationRoute`, MIT.)
///
/// Which speech model hears a recording made in the keyboard is a second decision, taken when
/// the recording stops (`LocalSpeech.preferred`: Zone's model, then Apple's, then the audio is
/// kept for Zone), so a model that is still loading never delays the microphone.
public enum DictationRoute: Equatable, Sendable {
    /// The keyboard cannot dictate yet: Full Access is off, or Zone's shared folder is out of reach.
    case setUp(SetUp)
    /// Zone keeps the microphone ready: ask it and stay in this app.
    case warm
    /// The keyboard records by itself. Zone stays closed.
    case inKeyboard
    /// Zone has to come forward to record.
    case opensZone(Reason)
    /// A hold on space with nothing to talk with. A hold never opens Zone: the finger is still down.
    case notReady

    public enum SetUp: Equatable, Sendable {
        case fullAccess
        case sharedFolder
    }

    public enum Reason: String, Equatable, Sendable {
        /// The press was on a line that said "Tap the mic to open it".
        case personAsked
        /// No session, and the keyboard cannot record by itself right now.
        case keyboardCannotRecord
    }

    /// What a press knows when it happens. Nothing here waits on anything.
    public struct Press: Equatable, Sendable {
        public var hasFullAccess: Bool
        public var sharedFolderReachable: Bool
        /// Zone's session is armed and its heartbeat is fresh (`SessionState.isAlive`). False
        /// for a second look after Zone answered that it has to be open.
        public var sessionAlive: Bool
        /// The press was on an error that said the next press opens Zone.
        public var personAskedForZone: Bool
        /// A hold on space rather than a tap on the mic.
        public var fromHold: Bool
        /// The keyboard may record by itself (`KeyboardCapture.route` said `.keyboard`).
        public var keyboardCanRecord: Bool

        public init(hasFullAccess: Bool = true, sharedFolderReachable: Bool = true, sessionAlive: Bool,
                    personAskedForZone: Bool = false, fromHold: Bool = false, keyboardCanRecord: Bool) {
            self.hasFullAccess = hasFullAccess
            self.sharedFolderReachable = sharedFolderReachable
            self.sessionAlive = sessionAlive
            self.personAskedForZone = personAskedForZone
            self.fromHold = fromHold
            self.keyboardCanRecord = keyboardCanRecord
        }
    }

    public static func resolve(_ press: Press) -> DictationRoute {
        guard press.hasFullAccess else { return .setUp(.fullAccess) }
        guard press.sharedFolderReachable else { return .setUp(.sharedFolder) }
        // Asking for Zone by name beats everything else a tap could do. A hold cannot ask.
        if press.personAskedForZone, !press.fromHold { return .opensZone(.personAsked) }
        if press.sessionAlive { return .warm }
        if press.keyboardCanRecord { return .inKeyboard }
        return press.fromHold ? .notReady : .opensZone(.keyboardCannotRecord)
    }

    /// Short name for the recording log.
    public var journalName: String {
        switch self {
        case .setUp(let what): "setUp.\(what)"
        case .warm: "warm"
        case .inKeyboard: "inKeyboard"
        case .opensZone(let reason): "opensZone.\(reason.rawValue)"
        case .notReady: "notReady"
        }
    }
}
