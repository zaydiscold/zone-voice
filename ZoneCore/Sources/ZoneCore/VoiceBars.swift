// by zayd/cold @ zayd.wtf

import Foundation

/// Frame-rate independent attack and release for the moving meter.
public enum VoiceEnvelope {
    public static func response(seconds: Double, rising: Bool) -> Double {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return -expm1(-seconds / (rising ? 0.032 : 0.135))
    }
}

/// The Bars voice graphic: a dense row of thin upright bars, tallest in the middle and tapering
/// to both ends, the look of a dictation pill. Only sampled levels are drawn. The newest sound
/// is at the right end and moves left as it ages, so a word swells as it reaches the middle and
/// sinks as it leaves; silence leaves every bar a short stub.
///
/// Pure numbers, so the shape is tested here and the view only draws rectangles.
public enum VoiceBars {
    /// Bar plus gap, in points: a 2 pt bar and a slightly narrower gap.
    public static let pitch: Double = 3.6
    /// The share of a bar's reach the outermost bars keep, so the row never pinches to nothing.
    public static let edgeReach: Float = 0.28
    /// The same lift the Wave gives a level, so a voice stands as tall in either graphic.
    static let lift: Float = 0.62

    /// How many bars fit `width` points at `pitch`, kept odd so one bar sits on the center line.
    public static func count(fitting width: Double, pitch: Double = VoiceBars.pitch) -> Int {
        guard width.isFinite, pitch > 0 else { return 0 }
        let fit = max(0, Int(width / pitch))
        guard fit > 0 else { return 0 }
        return min(fit % 2 == 0 ? fit - 1 : fit, 121)
    }

    /// Bar heights as 0...1 of the available height, left to right, for `levels` (0...1, oldest
    /// first). The history is stretched over the bars, so the row is filled whatever its width,
    /// and each bar is scaled by where it sits: full reach in the middle, `edgeReach` at the ends.
    public static func heights(levels: [Float], count: Int) -> [Float] {
        guard count > 0 else { return [] }
        let clean = levels.map { $0.isFinite ? min(max($0, 0), 1) : 0 }
        guard !clean.isEmpty else { return [Float](repeating: 0, count: count) }
        return (0..<count).map { index in
            let level = sample(clean, at: count == 1 ? 1 : Float(index) / Float(count - 1))
            return pow(level, lift) * reach(at: index, of: count)
        }
    }

    /// 1 at the center bar, falling to `edgeReach` at the first and last.
    static func reach(at index: Int, of count: Int) -> Float {
        guard count > 1 else { return 1 }
        let x = Float(index) / Float(count - 1)
        // Clamped: sin(pi) lands a hair below zero in Float, and a negative base has no 1.4 power.
        return edgeReach + (1 - edgeReach) * pow(max(0, sin(.pi * x)), 1.4)
    }

    /// The history read at `position` (0 oldest, 1 newest), blending the two nearest samples.
    private static func sample(_ levels: [Float], at position: Float) -> Float {
        guard levels.count > 1 else { return levels[0] }
        let exact = position * Float(levels.count - 1)
        let lower = min(Int(exact), levels.count - 2)
        let blend = exact - Float(lower)
        return levels[lower] * (1 - blend) + levels[lower + 1] * blend
    }
}
