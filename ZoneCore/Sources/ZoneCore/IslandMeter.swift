// by zayd/cold @ zayd.wtf

import Foundation

/// The microphone history the Dynamic Island draws. The capture engine posts a level about
/// every 50 ms; the island is redrawn about once a second. Each bar is the loudest level in
/// one bin of samples, so a short syllable between two updates still shows as a peak instead
/// of being averaged away.
///
/// Values are 0...`scale`, oldest first, so a full history fits an ActivityKit update in a
/// few dozen bytes.
public struct IslandMeter: Sendable, Equatable {
    /// Samples per bar: 3 at 20 a second is 150 ms, close to a syllable.
    public let samplesPerBar: Int
    /// Bars kept: enough for the widest island waveform.
    public let capacity: Int
    public static let scale: UInt8 = 15

    public private(set) var bars: [UInt8]
    private var binPeak: Float = 0
    private var binCount = 0

    public init(samplesPerBar: Int = 3, capacity: Int = 40) {
        precondition(samplesPerBar > 0 && capacity > 0)
        self.samplesPerBar = samplesPerBar
        self.capacity = capacity
        bars = Array(repeating: 0, count: capacity)
    }

    /// One 0...1 level from the capture engine (already on Zone's perceptual curve).
    public mutating func append(_ level: Float) {
        binPeak = max(binPeak, level.isFinite ? level : 0)
        binCount += 1
        guard binCount >= samplesPerBar else { return }
        bars.removeFirst()
        bars.append(Self.quantize(binPeak))
        binPeak = 0
        binCount = 0
    }

    /// The history including the bin still filling, so the newest bar is never a beat late.
    public var snapshot: [UInt8] {
        guard binCount > 0 else { return bars }
        return Array(bars.dropFirst()) + [Self.quantize(binPeak)]
    }

    public mutating func reset() {
        bars = Array(repeating: 0, count: capacity)
        binPeak = 0
        binCount = 0
    }

    /// Maps a 0...1 level to a bar height step.
    ///
    /// Levels arrive already shaped by `AdaptiveLevelScale` (a 1.6 power curve over
    /// -50...-2 dBFS), which suits the full-width meter in the app. The island's bars are
    /// tiny (22 pt compact), so quiet speech flattens into the floor there.
    static func quantize(_ level: Float) -> UInt8 {
        let x = min(max(level, 0), 1)
        // A square root lifts conversational speech into the middle of a 22 pt bar while
        // silence stays at zero and a shout still tops out. Tune here, not in the views.
        let shaped = x.squareRoot()
        return UInt8((shaped * Float(scale)).rounded())
    }
}
