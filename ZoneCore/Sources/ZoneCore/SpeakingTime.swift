// by zayd/cold @ zayd.wtf

import Foundation

/// Estimates voiced time for offline comparisons. Home and the standby session use recorded
/// minutes instead, including time spent thinking. This gate is not Wispr Flow's detector.
///
/// The audio is cut into 100 ms frames, and a frame is speech when it clears the bars
/// `TrailingSilenceGate` uses: an absolute floor, 5% of a decaying peak, and three times the
/// room's noise floor (capped at half the loudest frame, so speech that starts with no gap still
/// counts). Quiet between two speech frames counts up to `maxGap`, because the gaps between words
/// are part of talking; a longer pause is thinking and stops counting there. Quiet after the last
/// word never counts.
public struct SpeakingTime {
    public static let sampleRate = 16_000
    public static let frameSamples = 1_600
    /// The longest quiet stretch inside speech that still counts as talking: 0.5 s.
    public var maxGapFrames = 5

    private var pending: [Float] = []
    private var loudest: Float = 0
    private var loudestEver: Float = 0
    private var recentLevels: [Float] = []
    private var heardSpeech = false
    private var quietSinceSpeech = 0
    private var countedFrames = 0

    public init() {}

    /// Seconds of speech so far.
    public var seconds: Double { Double(countedFrames * Self.frameSamples) / Double(Self.sampleRate) }

    public mutating func add(_ samples: [Float]) {
        pending.append(contentsOf: samples)
        var start = 0
        while pending.count - start >= Self.frameSamples {
            measure(pending[start..<(start + Self.frameSamples)])
            start += Self.frameSamples
        }
        pending.removeFirst(start)
    }

    private mutating func measure(_ frame: ArraySlice<Float>) {
        var sum: Float = 0
        for value in frame { sum += value * value }
        let level = (sum / Float(frame.count)).squareRoot()
        // 0.97 per 100 ms halves the peak in about 2.3 s, close to the gate's 0.95 per 80 ms.
        loudest = max(loudest * 0.97, level)
        loudestEver = max(loudestEver, level)
        recentLevels.append(level)
        if recentLevels.count > 16 { recentLevels.removeFirst() }
        let floor = recentLevels.min() ?? 0
        if level >= max(loudest * 0.05, min(floor * 3, loudestEver * 0.5), 0.003) {
            if heardSpeech { countedFrames += min(quietSinceSpeech, maxGapFrames) }
            heardSpeech = true
            quietSinceSpeech = 0
            countedFrames += 1
        } else if heardSpeech {
            quietSinceSpeech += 1
        }
    }
}

/// `SpeakingTime` for the microphone thread: capture adds samples, the coordinator reads the
/// total when the dictation finishes.
public final class SpeakingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = SpeakingTime()
    public init() {}
    public func add(_ samples: [Float]) { lock.lock(); time.add(samples); lock.unlock() }
    public var seconds: Double { lock.lock(); defer { lock.unlock() }; return time.seconds }
}
