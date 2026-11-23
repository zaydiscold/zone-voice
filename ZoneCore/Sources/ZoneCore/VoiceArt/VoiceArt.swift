// by zayd/cold @ zayd.wtf

import CoreGraphics
import Foundation

/// What a voice graphic is told about the voice, once a frame. Everything is derived from the
/// one number the microphone publishes (a 0...1 level, about 20 a second): how loud, when a
/// syllable starts, how fast the person is talking, how long they have been quiet.
public struct VoiceSignal: Sendable, Equatable {
    /// The level, smoothed: quick to rise, slower to fall. 0...1.
    public var level: Float = 0
    /// Above zero on the one step a syllable starts; how hard it landed, 0...1.
    public var onset: Float = 0
    /// Syllables a second over the last second or two.
    public var pace: Float = 0
    /// Builds over a phrase and drains in a pause. 0...1.
    public var energy: Float = 0
    /// Seconds since the voice was last heard.
    public var quiet: Float = 0
    /// Where the level sits in its own recent range, 0 low to 1 high: the rise and fall of a phrase.
    public var contour: Float = 0.5
    /// Seconds since the tracker started.
    public var time: Double = 0

    public var isVoiced: Bool { quiet < 0.12 }

    public init() {}
}

/// Turns the level stream into a `VoiceSignal`. Pure numbers; stepped at a fixed rate.
public struct VoiceTracker: Sendable {
    public static let voicedLevel: Float = 0.08

    private var fast: Float = 0
    private var slow: Float = 0
    private var armed = true
    private var sinceOnset: Float = 1
    private var beats: Float = 0
    private var reservoir: Float = 0
    private var low: Float = 0
    private var high: Float = 0.3
    public private(set) var signal = VoiceSignal()

    public init() {}

    public mutating func step(level raw: Float, dt: Float) -> VoiceSignal {
        guard dt > 0, dt.isFinite else { return signal }
        let target = raw.isFinite ? min(max(raw, 0), 1) : 0
        func follow(_ value: inout Float, _ target: Float, _ seconds: Float) {
            value += (target - value) * (1 - exp(-dt / seconds))
        }
        follow(&fast, target, target > fast ? 0.03 : 0.09)
        follow(&slow, target, 0.28)
        follow(&signal.level, target, target > signal.level ? 0.04 : 0.14)

        sinceOnset += dt
        signal.onset = 0
        let lift = fast - slow
        if armed, lift > 0.07, fast > 0.12, sinceOnset > 0.13 {
            armed = false
            sinceOnset = 0
            beats += 1
            signal.onset = min(1, 0.35 + lift * 2.4)
        } else if !armed, lift < 0.025 {
            armed = true
        }
        // A leaky count of syllables: at a steady rate r it settles at r * 0.9, so pace reads r.
        beats *= exp(-dt / 0.9)
        signal.pace = beats / 0.9

        reservoir += (1.75 * signal.level * signal.level - reservoir / 1.8) * dt
        signal.energy = 1 - exp(-max(0, reservoir) * 1.45)

        if target > Self.voicedLevel { signal.quiet = 0 } else { signal.quiet += dt }

        follow(&low, target, target < low ? 0.2 : 4)
        follow(&high, max(target, low + 0.12), target > high ? 0.08 : 3)
        signal.contour = min(1, max(0, (signal.level - low) / max(0.12, high - low)))
        signal.time += Double(dt)
        return signal
    }
}

/// A small seeded generator, so a graphic never repeats itself in use and always repeats in a test.
public struct ArtRandom: Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0 ..< 1
    public mutating func unit() -> CGFloat { CGFloat(next() >> 11) / CGFloat(1 << 53) }
    public mutating func range(_ low: CGFloat, _ high: CGFloat) -> CGFloat { low + (high - low) * unit() }
    public mutating func chance(_ probability: CGFloat) -> Bool { unit() < probability }
    public mutating func index(_ count: Int) -> Int { count <= 1 ? 0 : Int(next() % UInt64(count)) }
    /// Roughly bell shaped around zero, about -1...1.
    public mutating func bell() -> CGFloat { (unit() + unit() + unit()) / 1.5 - 1 }
}

public struct ArtColor: Sendable, Equatable {
    public var red: CGFloat
    public var green: CGFloat
    public var blue: CGFloat

    public init(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public func mixed(with other: ArtColor, _ amount: CGFloat) -> ArtColor {
        let t = min(max(amount, 0), 1)
        return ArtColor(red + (other.red - red) * t, green + (other.green - green) * t, blue + (other.blue - blue) * t)
    }
}

/// The two colors a graphic is handed: the text color of the surface it sits on, and the accent.
/// Graphics that bring their own colors (leaves, lanes) pick the set for a dark or light surface.
public struct VoiceArtPalette: Sendable, Equatable {
    public var ink: ArtColor
    public var accent: ArtColor
    public var isDark: Bool

    public init(ink: ArtColor, accent: ArtColor, isDark: Bool) {
        self.ink = ink
        self.accent = accent
        self.isDark = isDark
    }
}

extension CGContext {
    func fill(_ color: ArtColor, _ alpha: CGFloat = 1) {
        setFillColor(red: color.red, green: color.green, blue: color.blue, alpha: min(max(alpha, 0), 1))
    }

    func stroke(_ color: ArtColor, _ alpha: CGFloat = 1) {
        setStrokeColor(red: color.red, green: color.green, blue: color.blue, alpha: min(max(alpha, 0), 1))
    }

    func line(from start: CGPoint, to end: CGPoint) {
        move(to: start)
        addLine(to: end)
        strokePath()
    }

    func dot(at center: CGPoint, radius: CGFloat) {
        fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }
}

/// One voice graphic: a small simulation fed the voice, and how to draw it. The origin is the
/// top left corner, x to the right and y down, in points.
protocol VoicePainter: AnyObject {
    func step(_ voice: VoiceSignal, dt: CGFloat, size: CGSize)
    func draw(in context: CGContext, size: CGSize, palette: VoiceArtPalette)
}

/// Runs one drawn voice graphic: feed it levels as they arrive, advance it by the frame time,
/// and draw. The simulation steps at a fixed 60 a second whatever the screen does.
public final class VoiceArtEngine {
    public let style: MeterStyle
    private let painter: VoicePainter
    private var tracker = VoiceTracker()
    private var level: Float = 0
    private var owed: Double = 0
    private static let tick: Double = 1.0 / 60.0

    /// Nil for the styles that are not drawn here (Wave, Mirrored, Bars, Scope).
    public init?(style: MeterStyle, seed: UInt64) {
        let random = ArtRandom(seed: seed)
        switch style {
        case .ink: painter = InkPainter(random: random)
        case .glyphs: painter = GlyphPainter(random: random)
        case .branch: painter = BranchPainter(random: random)
        case .inkblot: painter = InkblotPainter(random: random)
        case .lanes: painter = LanesPainter(random: random)
        case .stars: painter = StarsPainter(random: random)
        case .wave, .mirrored, .bars, .scope: return nil
        }
        self.style = style
    }

    /// The newest microphone level, 0...1. Held until the next one.
    public func feed(level: Float) { self.level = level.isFinite ? min(max(level, 0), 1) : 0 }

    public func advance(by seconds: Double, size: CGSize) {
        guard seconds > 0, seconds.isFinite, size.width > 1, size.height > 1 else { return }
        // A stalled screen owes at most a quarter second, so a graphic never lurches to catch up.
        owed = min(owed + seconds, 0.25)
        while owed >= Self.tick {
            owed -= Self.tick
            let voice = tracker.step(level: level, dt: Float(Self.tick))
            painter.step(voice, dt: CGFloat(Self.tick), size: size)
        }
    }

    public func draw(in context: CGContext, size: CGSize, palette: VoiceArtPalette) {
        guard size.width > 1, size.height > 1 else { return }
        context.saveGState()
        context.clip(to: CGRect(origin: .zero, size: size))
        painter.draw(in: context, size: size, palette: palette)
        context.restoreGState()
    }
}
