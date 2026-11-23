// by zayd/cold @ zayd.wtf

import Foundation

/// Decides when a dictation has gone quiet for long enough to finish by itself. Off unless the
/// person turns it on (Settings > Finish when quiet), because a pause to think is part of
/// dictating: in 1,085 real dictations 28% held a 2 second pause between words, 6.5% a 10 second
/// one and 1.4% a 30 second one.
///
/// Feed it the meter level (`AdaptiveLevelScale`, 0...1) about 20 times a second with monotonic
/// seconds. It never finishes before it has heard a voice, so a slow start is safe, and a sound
/// of any kind starts the wait over.
///
/// What counts as sound: louder than -43.6 dBFS (the level `QuietInputMonitor` uses), or, in a
/// room that is louder than that when nobody talks, louder than the room. The room is the 5th
/// percentile of the last minute and the voice the 95th; the bar sits 6 dB above the room but
/// never closer than 10 dB under the voice, so a voice that barely clears the noise is still
/// heard. When the two cannot be told apart nothing ever reads as quiet and the dictation runs
/// until it is stopped by hand, which is the safe way to be wrong.
///
/// Measured on those 1,085 dictations against the recognizer's word times: at 30 seconds it
/// never ended one while words were still coming, at 20 seconds once, at 10 seconds 7 times
/// (0.6%). It declined to fire in about half of the long pauses, all in steady loud noise.
public struct SilenceFinish: Sendable {
    /// Choices for Settings. Nothing under 10 seconds: shorter waits cut real dictations.
    public static let waitChoices: [TimeInterval] = [10, 20, 30, 60, 120]
    public static let defaultWait: TimeInterval = 30

    /// "10 seconds", "1 minute".
    public static func waitLabel(_ wait: TimeInterval) -> String {
        if wait < 60 { return "\(Int(wait)) seconds" }
        let minutes = Int(wait / 60)
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    public enum Reading: Equatable, Sendable {
        /// No voice yet. Quiet before the first word never ends a dictation.
        case waitingForVoice
        /// Sound within the last moment.
        case hearing
        /// Quiet since the last sound; this long until it finishes.
        case quiet(remaining: TimeInterval)
        /// Quiet for the whole wait: finish now. Reported once, then the wait starts over.
        case finish
    }

    public let wait: TimeInterval

    static let fixedBar: Float = -43.6
    static let aboveRoom: Float = 6
    static let underVoice: Float = 10
    static let memory: TimeInterval = 60
    /// A sound is two loud samples among the last six (about 0.3 s), so one click is not a voice.
    static let loudNeeded = 2, loudWindow = 6
    /// Samples further apart than this mean the microphone was away (a call, a pause). The
    /// time in between is not judged.
    static let longestStep: TimeInterval = 1

    private var bins = [Int](repeating: 0, count: 51)   // -50...0 dBFS, 1 dB each
    private var history: [(at: TimeInterval, bin: Int)] = []
    private var historyStart = 0
    private var recentLoud: [Bool] = []
    private var heardVoice = false
    private var lastSound: TimeInterval = 0
    private var lastSample: TimeInterval?

    public init(wait: TimeInterval = SilenceFinish.defaultWait) {
        self.wait = max(wait, 1)
    }

    /// The meter level as dBFS, the inverse of `AdaptiveLevelScale.map`.
    public static func decibels(forLevel level: Float) -> Float {
        let span = AdaptiveLevelScale.ceilingDecibels - AdaptiveLevelScale.floorDecibels
        return AdaptiveLevelScale.floorDecibels + span * pow(min(max(level, 0), 1), 1 / AdaptiveLevelScale.curve)
    }

    /// Starts the wait over without forgetting the room: after a pause or an interruption.
    public mutating func restartWait(at now: TimeInterval) {
        lastSound = now
        lastSample = now
        recentLoud.removeAll()
    }

    public mutating func sample(level: Float, at now: TimeInterval) -> Reading {
        guard level.isFinite else { return heardVoice ? .hearing : .waitingForVoice }
        if let last = lastSample, now - last > Self.longestStep || now < last { restartWait(at: now) }
        lastSample = now

        let decibels = Self.decibels(forLevel: level)
        let bin = Int(decibels.rounded()) - Int(AdaptiveLevelScale.floorDecibels)
        bins[min(max(bin, 0), 50)] += 1
        history.append((now, min(max(bin, 0), 50)))
        while historyStart < history.count, now - history[historyStart].at > Self.memory {
            bins[history[historyStart].bin] -= 1
            historyStart += 1
        }
        if historyStart > 4_096 {
            history.removeFirst(historyStart)
            historyStart = 0
        }

        recentLoud.append(decibels > bar)
        if recentLoud.count > Self.loudWindow { recentLoud.removeFirst() }
        if recentLoud.lazy.filter({ $0 }).count >= Self.loudNeeded {
            heardVoice = true
            lastSound = now
            return .hearing
        }
        guard heardVoice else { return .waitingForVoice }
        let remaining = wait - (now - lastSound)
        guard remaining <= 0 else { return .quiet(remaining: remaining) }
        lastSound = now
        return .finish
    }

    /// The level a sample must pass to count as sound, in dBFS.
    var bar: Float {
        let room = percentile(5), voice = percentile(95)
        return max(Self.fixedBar, min(room + Self.aboveRoom, voice - Self.underVoice))
    }

    private func percentile(_ percent: Int) -> Float {
        let total = history.count - historyStart
        guard total > 0 else { return 0 }
        let needed = Double(total) * Double(percent) / 100
        var seen = 0
        for (index, count) in bins.enumerated() {
            seen += count
            if seen > 0, Double(seen) >= needed { return Float(index) + AdaptiveLevelScale.floorDecibels }
        }
        return 0
    }
}
