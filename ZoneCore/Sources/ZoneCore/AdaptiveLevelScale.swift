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
