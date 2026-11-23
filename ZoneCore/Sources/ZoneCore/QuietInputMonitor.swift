// by zayd/cold @ zayd.wtf

import Foundation

/// A gentle level hint, never an endpoint detector. Silence does not stop recording.
/// Feed monotonic seconds and the latest sample, not the waveform's sliding maximum.
public struct QuietInputMonitor: Sendable {
    public var quietInterval: TimeInterval
    public var levelThreshold: Float
    private var quietSince: TimeInterval

    public init(startedAt: TimeInterval, quietInterval: TimeInterval = 8, levelThreshold: Float = 0.04) {
        self.quietSince = startedAt
        self.quietInterval = quietInterval
        self.levelThreshold = levelThreshold
    }

    /// Returns true only after a continuous quiet interval. Signal immediately clears the hint.
    public mutating func sample(level: Float, at now: TimeInterval) -> Bool {
        guard level.isFinite, now >= quietSince, level < levelThreshold else {
            quietSince = now
            return false
        }
        return now - quietSince >= quietInterval
    }
}
