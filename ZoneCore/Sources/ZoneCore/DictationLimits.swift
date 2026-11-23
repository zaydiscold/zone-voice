// by zayd/cold @ zayd.wtf

import Foundation

/// When Zone ends a keyboard dictation by itself. Dictation is unlimited in normal use; these
/// only catch a recording nobody is attending to (failure map L2 and S4): the person switched
/// apps or put the phone away with the microphone still on, which used to record until the
/// battery or the disk gave out.
public struct DictationLimits: Equatable, Sendable {
    /// The keyboard stamps its presence every 2 s while it shows a dictation. This long without
    /// a stamp, with Zone itself not on screen, means nobody can see or stop the recording.
    public var keyboardGoneAfter: TimeInterval
    /// A single keyboard dictation never runs longer than this. Long enough for any dictation a
    /// person means to make; short enough that a forgotten one ends the same day.
    public var maximumLength: TimeInterval

    public static let standard = DictationLimits(keyboardGoneAfter: 30, maximumLength: 2 * 3_600)

    /// Choices for Settings > Microphone and timing > "Keyboard hidden". Dictating while the
    /// keyboard is out of sight (an image full screen, another app) is a feature, so this is the
    /// person's call. 0 means until they stop it.
    public static let hiddenKeyboardChoices: [TimeInterval] = [30, 120, 300, 900, 0]
    public static let defaultHiddenKeyboardGrace: TimeInterval = 300
    /// Without a Dynamic Island / Lock Screen control nobody can stop a hidden recording, so
    /// "until I stop" falls back to this.
    public static let uncontrolledCeiling: TimeInterval = 300

    /// - Parameters:
    ///   - grace: the chosen time, 0 for until stopped.
    ///   - stoppableElsewhere: a Live Activity is showing, so the recording can be seen and
    ///     stopped without the keyboard.
    public static func hiddenKeyboard(grace: TimeInterval, stoppableElsewhere: Bool) -> DictationLimits {
        let after: TimeInterval
        if grace <= 0 || !grace.isFinite {
            after = stoppableElsewhere ? .infinity : uncontrolledCeiling
        } else {
            after = max(grace, 30)
        }
        return DictationLimits(keyboardGoneAfter: after, maximumLength: standard.maximumLength)
    }

    /// "30 seconds", "2 minutes", "Until I stop".
    public static func hiddenKeyboardLabel(_ grace: TimeInterval) -> String {
        if grace <= 0 { return "Until I stop" }
        if grace < 60 { return "\(Int(grace)) seconds" }
        let minutes = Int(grace / 60)
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    public init(keyboardGoneAfter: TimeInterval, maximumLength: TimeInterval) {
        self.keyboardGoneAfter = keyboardGoneAfter
        self.maximumLength = maximumLength
    }

    public enum Decision: Equatable, Sendable {
        case keepRecording
        /// The keyboard has been gone too long; stop and keep the words.
        case keyboardGone
        /// The recording reached `maximumLength`; stop and keep the words.
        case reachedMaximum
    }

    /// - Parameters:
    ///   - startedAt: when this recording started.
    ///   - keyboardLastSeen: the keyboard's latest presence stamp, if any.
    ///   - appLastActive: the last time Zone itself was on screen (it shows the recording then).
    ///   - watchesKeyboard: false for dictations with no keyboard behind them (a Shortcut or the
    ///     Action Button), which only the length limit applies to.
    public func decision(now: Date, startedAt: Date, keyboardLastSeen: Date?, appLastActive: Date?,
                         watchesKeyboard: Bool) -> Decision {
        if now.timeIntervalSince(startedAt) >= maximumLength { return .reachedMaximum }
        guard watchesKeyboard else { return .keepRecording }
        // The latest sign that someone could see this recording. A stamp from the future (a
        // clock change) counts as now, never as a reason to stop.
        let seen = [startedAt, keyboardLastSeen, appLastActive].compactMap { $0 }.max() ?? startedAt
        return now.timeIntervalSince(seen) >= keyboardGoneAfter ? .keyboardGone : .keepRecording
    }

    /// What Home says after an automatic stop.
    public static func notice(for decision: Decision) -> String? {
        switch decision {
        case .keepRecording: return nil
        case .keyboardGone:
            return "Dictation stopped after the keyboard closed. Saved in History."
        case .reachedMaximum:
            return "Dictation stopped at the 2-hour limit. Saved in History."
        }
    }
}
