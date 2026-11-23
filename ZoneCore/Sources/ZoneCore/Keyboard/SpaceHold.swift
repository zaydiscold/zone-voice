// by zayd/cold @ zayd.wtf

import Foundation

/// What holding the space bar does (Settings > Keyboard > Hold space).
public enum SpaceHold: String, Codable, CaseIterable, Sendable {
    /// The space bar becomes a trackpad (`SpacebarCursorGesture`). The default.
    case moveCursor
    /// Beta: hold space to talk, let go to insert (`SpaceTalk`). A sideways slide still moves
    /// the cursor, and a tap still types a space.
    case talk

    public var label: String {
        switch self {
        case .moveCursor: "Move cursor"
        case .talk: "Talk (Beta)"
        }
    }
}

/// Hold to talk on the space bar. The keyboard's mic flow is unchanged: a hold asks for a
/// dictation the way a tap on the mic does, and letting go stops it the way Stop does. These are
/// the decisions around that, kept here so they are tested without a keyboard.
///
/// A hold records only while it is held. It never opens Zone: the finger is still down, and a
/// trip to another app would leave nothing to let go of. When Zone is not keeping the microphone
/// ready, the hold says so in the strip instead.
public enum SpaceTalk {
    /// The hold waits this long before it asks for the microphone, the same wait as the cursor's
    /// hold, so a slow tap on space still types a space.
    public static let holdDuration = SpacebarCursorGesture.holdDuration

    /// Where the dictation a hold asked for stands, as far as the space bar shows it.
    public enum Phase: Equatable, Sendable {
        /// No hold owns a dictation.
        case none
        /// Asked; Zone has not started listening yet.
        case starting
        /// Zone is listening: letting go stops and inserts.
        case listening
    }

    /// What a hold on space does when it reaches `holdDuration` with Talk chosen.
    public enum Start: Equatable, Sendable {
        /// Ask for a dictation; the hold owns it until the finger lifts.
        case talk
        /// Say in the strip that Zone is not ready to listen. The hold types nothing.
        case explainNotReady
        /// Nothing to talk with right now (no Full Access, the App Group out of reach, or a
        /// dictation already under way): the hold moves the cursor as it always did.
        case moveCursor
    }

    public static func start(hasFullAccess: Bool, appGroupReachable: Bool, dictationUnderWay: Bool,
                             zoneListensInPlace: Bool) -> Start {
        guard hasFullAccess, appGroupReachable, !dictationUnderWay else { return .moveCursor }
        return zoneListensInPlace ? .talk : .explainNotReady
    }

    /// What letting go (or a cancelled touch) does to the dictation the hold owns.
    public enum Release: Equatable, Sendable {
        /// Stop and insert, as Stop does.
        case stop
        /// Zone had not started listening: nothing was recorded yet, so the request is
        /// withdrawn and the strip says to hold until it listens.
        case withdrawTooSoon
        /// The dictation already ended some other way (Stop or Cancel in the strip, an error).
        case nothing
    }

    public static func release(_ phase: Phase) -> Release {
        switch phase {
        case .listening: .stop
        case .starting: .withdrawTooSoon
        case .none: .nothing
        }
    }

    /// The strip's message when Zone is not keeping the microphone ready. The first sentence is
    /// the problem and the second what to do, one line each.
    public static let notReadyMessage = "Zone isn't ready to listen. Tap the mic to wake it."
    /// The strip's message when the finger lifted before Zone started listening.
    public static let tooSoonMessage = "Let go before Zone was listening. Keep holding space until it is."

    /// The space bar's label while a hold owns a dictation.
    public static func spaceLabel(_ phase: Phase) -> String? {
        switch phase {
        case .none: nil
        case .starting: "Starting…"
        case .listening: "Let go to insert"
        }
    }
}
