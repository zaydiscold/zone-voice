// by zayd/cold @ zayd.wtf

import Foundation

/// How long an armed session waits for the next dictation before releasing the microphone.
public struct InactivityPolicy: Equatable, Sendable {
    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 300) {
        self.timeout = timeout
    }

    /// The choices offered in Settings; 5 minutes is the default from the brief.
    public static let presets: [InactivityPolicy] = [
        InactivityPolicy(timeout: 30),
        InactivityPolicy(timeout: 60),
        InactivityPolicy(timeout: 300),
        InactivityPolicy(timeout: 900),
        InactivityPolicy(timeout: 3600),
        InactivityPolicy(timeout: 6 * 3600),
        InactivityPolicy(timeout: .infinity),
    ]

    /// A session that only ends when the user ends it.
    public var isUnbounded: Bool { timeout.isInfinite }

    public func deadline(after lastActivity: Date) -> Date {
        isUnbounded ? .distantFuture : lastActivity.addingTimeInterval(timeout)
    }

    public func shouldEnd(now: Date, lastActivity: Date) -> Bool {
        !isUnbounded && now >= deadline(after: lastActivity)
    }

    /// The shortest a paused dictation is held before it saves. The short presets release an
    /// idle microphone quickly; they must not end a recording someone paused to think.
    public static let minimumPauseLimit: TimeInterval = 300

    /// How long a paused dictation is held before it finishes and keeps its words; nil when
    /// only the user ends it.
    public var pauseLimit: TimeInterval? {
        isUnbounded ? nil : max(timeout, Self.minimumPauseLimit)
    }

    public var micReadySummary: String {
        isUnbounded ? "The mic stays ready until you turn it off."
            : "When you stop using the mic, it turns off after \(label)."
    }

    public var label: String {
        if isUnbounded { return "until I turn it off" }
        if timeout < 60 { return "\(Int(timeout)) seconds" }
        let minutes = Int(timeout / 60)
        if minutes >= 60 { return minutes == 60 ? "1 hour" : "\(minutes / 60) hours" }
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}
