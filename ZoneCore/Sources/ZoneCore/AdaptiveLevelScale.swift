// by zayd/cold @ zayd.wtf

import Foundation

/// Turns microphone loudness into a 0...1 meter value. Fixed, not adaptive: the same loudness
/// always draws the same height, so a held note holds steady (an adaptive floor and ceiling
/// behaved like auto-gain and drew a constant voice gradually lower, which read as wrong).
/// The range is -50...-2 dBFS on a power curve: steady room noise (an air conditioner, about -50
/// to -45) leaves the line flat instead of reading as a whisper, conversational speech at phone
/// distance (-35 to -15) moves through the middle, close or emphatic speech reaches the top. The name is kept for its call sites.
public struct AdaptiveLevelScale: Sendable {
    public static let floorDecibels: Float = -50
    public static let ceilingDecibels: Float = -2
    public static let curve: Float = 1.6

    public init() {}

    public mutating func map(decibels: Float, elapsed: TimeInterval) -> Float {
        let span = Self.ceilingDecibels - Self.floorDecibels
        let x = min(max((decibels - Self.floorDecibels) / span, 0), 1)
        return pow(x, Self.curve)
    }
}

/// App and keyboard post the loudest microphone block since the previous meter update.
/// A short syllable still reaches the strip when several input blocks arrive between posts.
public struct RecordingLevelWindow: Sendable {
    private var peak: Float = 0
    private var lastPost: TimeInterval?

    public init() {}

    public mutating func sample(rms: Float, at time: TimeInterval) -> Float? {
        if rms.isFinite { peak = max(peak, rms) }
        if let lastPost, time >= lastPost, time - lastPost < 0.05 { return nil }
        lastPost = time
        let level = KeyboardCapture.level(rootMeanSquare: peak)
        peak = 0
        return level
    }

    public mutating func sample(_ samples: [Float], at time: TimeInterval) -> Float? {
        let energy = samples.reduce(Float.zero) { $0 + $1 * $1 }
        return sample(rms: (energy / Float(max(1, samples.count))).squareRoot(), at: time)
    }
}

/// Rescues syllables on a quiet input without amplifying the saved audio. A changing
/// envelope above the room floor can lift the display; a steady fan cannot hold the lift.
public struct QuietVoiceMeter: Sendable {
    private var floorDB: Float?
    private var recentDB: Float?
    private var lastTime: TimeInterval?
    private var lastChange = -Double.infinity

    private var lastRise: TimeInterval?
    private var voiceUntil = -Double.infinity

    public init() {}

    public mutating func level(rms: Float, at time: TimeInterval) -> Float {
        reading(rms: rms, at: time).display
    }

    /// The drawing can react to one change. Faint input only gets extra sensitivity for the
    /// quiet detector after two separate rises from near the room floor, as in successive
    /// syllables. A single change in the room must not arm a quiet countdown.
    public mutating func reading(rms: Float, at time: TimeInterval) -> (display: Float, detection: Float) {
        guard time.isFinite, rms.isFinite, rms >= 0 else { return (0, 0) }
        let db = 20 * log10(max(0.0001, min(1, rms)))
        let elapsed = time - (lastTime ?? time)
        if elapsed < 0 || elapsed > 0.6 { self = Self() }
        let floor = min(db, (floorDB ?? db) + Float(min(0.1, max(0, elapsed))) * 0.8)
        if let previous = recentDB {
            if abs(db - previous) >= 2.5 { lastChange = time }
            if db - previous >= 3, previous - floor <= 8, db - floor >= 7 {
                if let lastRise, (0.09...0.65).contains(time - lastRise) { voiceUntil = time + 0.25 }
                lastRise = time
            }
        }
        floorDB = floor
        recentDB = db
        lastTime = time
        let fixed = KeyboardCapture.level(rootMeanSquare: rms)
        let detection = time <= voiceUntil && db - floor >= 6 && db > -60 && db < SilenceFinish.fixedBar
            ? KeyboardCapture.level(rootMeanSquare: rms * 4) : fixed
        guard db > -65, time - lastChange < 0.48 else { return (fixed, detection) }
        let aboveRoom = max(0, min(1, (db - floor - 3) / 17))
        let lowVoice = max(0, min(0.68, (db + 67) / 37))
        return (max(fixed, aboveRoom * lowVoice), detection)
    }
}
