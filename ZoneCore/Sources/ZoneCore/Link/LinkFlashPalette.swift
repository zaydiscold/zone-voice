// by zayd/cold @ zayd.wtf

import Foundation

/// The two levels each color channel of a Flash picture takes: one for a dark module, one for a
/// light one.
///
/// A color picture stacks three codes, one in each of red, green and blue, and a reader only has
/// to tell dark from light in each channel. The levels need not be 0 and 255: chosen with care,
/// the eight colors the three channels mix into (all dark, all light and the six between) form
/// a designed palette instead of the pure primaries.
///
/// What the computer's reader is promised (PROTOCOL.md, "Color Flash"):
/// - the levels are the same for every module of one picture;
/// - the quiet zone, at least four modules wide, is the all-light color;
/// - the finder patterns' dark is the all-dark color;
/// - in every channel, light minus dark is at least `span`;
/// - green's span is at least as large as red's and blue's: a camera's green also sees part of
///   the red and the blue light, so green is the channel that suffers first (the scene
///   palettes keep to this; `LinkFlashPaletteTests` checks them).
public struct LinkFlashPalette: Equatable, Sendable {
    /// The one number to tune: how far apart, out of 255, the dark and the light level of a
    /// channel must be. Every palette is widened to it when made, so raising it here makes all
    /// of them safer to read and lowering it lets them sit closer to the levels they ask for.
    /// The computer's reader asks for at least 120 and recommends 150 until Flash has been
    /// filmed with real cameras (PROTOCOL.md, "The palette").
    public static let span = 150

    /// The level of a dark module in red, green and blue.
    public let dark: [UInt8]
    /// The level of a light module in red, green and blue.
    public let light: [UInt8]

    /// A palette from the levels a design asks for. A channel whose two levels are closer than
    /// `span` is widened: the dark level is lowered first, and the light one raised only when
    /// the dark is already 0.
    public init(dark: (Int, Int, Int), light: (Int, Int, Int), span: Int = LinkFlashPalette.span) {
        let span = min(max(span, 1), 255)
        var low: [UInt8] = [], high: [UInt8] = []
        for (wantedDark, wantedLight) in [(dark.0, light.0), (dark.1, light.1), (dark.2, light.2)] {
            var top = min(max(wantedLight, 0), 255)
            var bottom = min(max(wantedDark, 0), top)
            if top - bottom < span {
                bottom = max(0, top - span)
                top = max(top, bottom + span)
            }
            low.append(UInt8(bottom))
            high.append(UInt8(top))
        }
        self.dark = low
        self.light = high
    }

    /// 0 and 255 in every channel: black, white and the six pure colors. What Color Flash
    /// showed first, and what the cross-test pictures use unless a palette is asked for.
    public static let pure = LinkFlashPalette(dark: (0, 0, 0), light: (255, 255, 255))

    public func level(channel: Int, light isLight: Bool) -> UInt8 {
        isLight ? light[channel] : dark[channel]
    }

    /// The smallest light minus dark of the three channels.
    public var narrowestSpan: Int {
        (0..<3).map { Int(light[$0]) - Int(dark[$0]) }.min() ?? 0
    }

    /// One of the eight colors: which channels are light.
    public func color(red: Bool, green: Bool, blue: Bool) -> [UInt8] {
        [level(channel: 0, light: red), level(channel: 1, light: green), level(channel: 2, light: blue)]
    }

    /// The eight colors, from all dark to all light. Index bit 0 is red, bit 1 green, bit 2 blue.
    public var colors: [[UInt8]] {
        (0..<8).map { color(red: $0 & 1 == 1, green: $0 & 2 == 2, blue: $0 & 4 == 4) }
    }

    /// Gives a picture drawn in `pure` (every byte 0 or 255, four bytes a pixel) this palette's
    /// levels, in place. The fourth byte of each pixel is left alone.
    public func recolor(_ rgbx: inout [UInt8]) {
        guard self != .pure else { return }
        rgbx.withUnsafeMutableBufferPointer { bytes in
            var index = 0
            while index + 3 < bytes.count {
                bytes[index] = bytes[index] < 128 ? dark[0] : light[0]
                bytes[index + 1] = bytes[index + 1] < 128 ? dark[1] : light[1]
                bytes[index + 2] = bytes[index + 2] < 128 ? dark[2] : light[2]
                index += 4
            }
        }
    }
}

/// The scene a color Flash plays in: a full-screen piece of generative art with the code as a
/// window in it, and the palette the code takes so the two belong together.
///
/// The scene itself is drawn by the app (`FlashArtShader`); this is what the rest needs to
/// know about it, and what the tests and the cross-test pictures can use without a screen.
public enum LinkFlashScene: Int, CaseIterable, Sendable {
    /// A synthwave dusk: a striped sun setting behind the code, over a grid running to the horizon.
    case dusk
    /// Northern lights: green and violet curtains over still water.
    case aurora
    /// Embers: slow plasma in reds and golds, with sparks rising past the code.
    case ember

    public var name: String {
        switch self {
        case .dusk: return "Dusk"
        case .aurora: return "Aurora"
        case .ember: return "Ember"
        }
    }

    /// The code's colors in this scene.
    ///
    /// - Dusk: deep purple, hot pink, emerald, orange, indigo, magenta, sky blue, pale pink.
    /// - Aurora: midnight blue, wine, spring green, lime, blue, violet, cyan, ice.
    /// - Ember: dark brown, scarlet, leaf green, yellow, plum, rose, mint, cream.
    public var palette: LinkFlashPalette {
        switch self {
        case .dusk: return LinkFlashPalette(dark: (60, 0, 90), light: (255, 200, 255))
        case .aurora: return LinkFlashPalette(dark: (0, 30, 70), light: (150, 255, 255))
        case .ember: return LinkFlashPalette(dark: (80, 20, 0), light: (255, 240, 165))
        }
    }

    /// The scene a flash opens in: chosen by its session number, so every flash looks different.
    public init(session: UInt32) {
        // The low bits of a random session are as good as any; the top bit is always set.
        self = Self.allCases[Int(session % UInt32(Self.allCases.count))]
    }

    /// The scene for act `act` (0 first) of a flash that opened in this one: a long transfer
    /// moves on to the next scene with each act and comes round again.
    public func act(_ act: Int) -> LinkFlashScene {
        let count = Self.allCases.count
        return Self.allCases[((rawValue + act) % count + count) % count]
    }

    /// `dusk`, `1`, `Aurora`: for the debug launch argument and the cross-test pictures.
    public init?(named text: String) {
        let wanted = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let number = Int(wanted), let scene = LinkFlashScene(rawValue: number) {
            self = scene
        } else if let scene = Self.allCases.first(where: { $0.name.lowercased() == wanted }) {
            self = scene
        } else {
            return nil
        }
    }
}
