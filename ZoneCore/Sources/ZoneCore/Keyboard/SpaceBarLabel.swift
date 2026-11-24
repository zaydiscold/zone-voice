// by zayd/cold @ zayd.wtf

import Foundation

/// What the space bar shows. The bar is the widest key and the
/// one most often hit without looking, so its face can be quiet: a mark, not a word.
public enum SpaceBarLabel: String, Codable, CaseIterable, Sendable {
    /// A slim rounded bar in the middle of the key, like a grip: the bar you slide to move the cursor.
    case line
    /// Five short bars, tallest in the middle: Zone's voice at rest, the Bars meter standing still.
    case voice
    /// The word "space", as Apple's keyboard writes it.
    case word
    /// Nothing at all.
    case blank

    public static let `default` = SpaceBarLabel.line

    public var label: String {
        switch self {
        case .line: "Line"
        case .voice: "Voice"
        case .word: "Word"
        case .blank: "Blank"
        }
    }

    /// The `voice` mark's bar heights in points, left to right.
    public static let voiceBars: [Double] = [4, 8, 11, 8, 4]
}
