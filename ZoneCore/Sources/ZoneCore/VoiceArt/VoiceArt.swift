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
    /// Where the level ranks among recent voiced levels, from 0 (low) to 1 (high).
    public var contour: Float = 0.5
    /// Seconds since the tracker started.
    public var time: Double = 0
    /// Unsmoothed meter dB for measuring an excursion from the start of a note.
    var decibels = AdaptiveLevelScale.floorDecibels

    public var isVoiced: Bool { quiet < 0.12 }

    public init() {}
}

/// Duration of the current run of meter readings within a fixed dB span.
private struct LevelHold: Sendable {
    private var low: Float = 0
    private var high: Float = 0
    private var time: Float = 0

    mutating func duration(db: Float, span: Float, dt: Float) -> Float {
        if time == 0 || db < high - span || db > low + span {
            low = db
            high = db
            time = 0
        }
        low = min(low, db)
        high = max(high, db)
        time += dt
        return time
    }
}

/// A soft percentile of levels heard during speech. A sustained sound keeps its reference.
private struct VoicedRanks: Sendable {
    private var bins = [Float](repeating: 0, count: 49)
    private var total: Float = 0
    private var steady = LevelHold()
    private var sustained = LevelHold()

    mutating func endHold() {
        steady = LevelHold()
        sustained = LevelHold()
    }

    mutating func contour(db: Float, linear: Float, dt: Float) -> Float {
        let position = db - AdaptiveLevelScale.floorDecibels
        let bin = Int(position.rounded())
        if total == 0 {
            let seed = max(0, bin - 8)...min(bins.count - 1, bin + 13)
            for i in seed { bins[i] = 0.5 / Float(seed.count) }
            total = 0.5
        }
        // Rank the actual posts. An alternating pair of syllables can have a
        // nearly constant 0.28 s average while covering several loudness bins.
        let steadyTime = steady.duration(db: db, span: 2.5, dt: dt)
        let heldTime = sustained.duration(db: db, span: 5, dt: dt)

        var below: Float = 0
        for i in bins.indices {
            below += bins[i] * min(1, max(0, (position - Float(i)) / 4 + 0.5))
        }
        let weight = min(1, total / 1.5)
        let result = linear + weight * (below / total - linear)
        if steadyTime < 0.25 && heldTime < 0.3 {
            let decay = exp(-dt / 8)
            for i in bins.indices { bins[i] *= decay }
            bins[bin] += dt
            total = total * decay + dt
        }
        return min(1, max(0, result))
    }
}

/// Keeps a second of 20 Hz meter readings. Smoothing can hide a rhythmic
/// syllable or tremolo. Before learning a background, check for a recurring
/// excursion larger than the 2.5 dB room tolerance.
private struct ModulationWindow: Sendable {
    private var samples = [Float](repeating: 0, count: 20)
    private var next = 0
    private var elapsed: Float = 0

    mutating func append(_ db: Float, dt: Float) {
        elapsed += dt
        if elapsed >= 0.05 {
            elapsed.formTruncatingRemainder(dividingBy: 0.05)
            samples[next] = db
            next = (next + 1) % samples.count
        }
    }

    var isRhythmic: Bool {
        guard samples.max()! - samples.min()! > 2.5 else { return false }
        let mean = samples.reduce(0, +) / Float(samples.count)
        let variance = samples.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(samples.count)
        // Compare the newest half-second with earlier readings 0.1 to 0.5 s away.
        for lag in 2...10 {
            var error: Float = 0
            for i in 10..<20 {
                let delta = samples[(next + i) % 20] - samples[(next + i - lag) % 20]
                error += delta * delta
            }
            if error < 10 * variance * 0.2 { return true }
        }
        return false
    }
}

/// Turns the level stream into a `VoiceSignal`. Pure numbers; stepped at a fixed rate.
public struct VoiceTracker: Sendable {
    private var floor: Float = 0.012
    private var floorAtGateOpen: Float = 0
    private var aboveFloor: Float = 0
    private var voiced = false
    private var lowestDB: Float = 0
    private var highestDB: Float = 0
    private var steadyTime: Float = 0

    private var steadyAverage: Float = 0
    private var modulation = ModulationWindow()
    private var rippleDB: Float = 0
    private var steadyRipple: Float = 0
    private var attackTrough = AdaptiveLevelScale.floorDecibels
    private var learnedMargin: Float = 0
    private var ranks = VoicedRanks()
    private var ripple: Float = 0.005
    private var windowMin: Float = 1
    private var windowMax: Float = 0
    private var windowTime: Float = 0
    private var valley: Float = 0

    private var fast: Float = 0
    private var slow: Float = 0
    private var armed = true
    private var sinceOnset: Float = 1
    private var beats: Float = 0
    private var reservoir: Float = 0
    private var high: Float = 0.08
    private var phraseRange: Float = 0
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

        // Undo the meter curve so the same fan ripple has the same tolerance at any volume.
        let dbSpan = AdaptiveLevelScale.ceilingDecibels - AdaptiveLevelScale.floorDecibels
        let db = AdaptiveLevelScale.floorDecibels + dbSpan * pow(target, 1 / AdaptiveLevelScale.curve)
        signal.decibels = db
        // Start the background average at the sound itself. The onset detector's
        // slow envelope intentionally starts low so it can see the attack.
        if !voiced { steadyAverage = target }
        follow(&steadyAverage, target, 0.28)
        let slowDB = AdaptiveLevelScale.floorDecibels + dbSpan * pow(steadyAverage, 1 / AdaptiveLevelScale.curve)
        modulation.append(db, dt: dt)
        follow(&steadyRipple, abs(target - steadyAverage), 0.5)
        follow(&rippleDB, abs(db - slowDB), 0.5)
        lowestDB = min(lowestDB, slowDB)
        highestDB = max(highestDB, slowDB)
        let drift = max(slowDB - lowestDB, highestDB - slowDB)
        let tolerance = 2.5 + min(2.5, 1.2 * rippleDB)
        if voiced, drift <= tolerance {
            steadyTime += dt
            if steadyTime >= 4.45 && abs(db - slowDB) < 2.5 && !modulation.isRhythmic {
                floor = steadyAverage
                ripple = steadyRipple
                learnedMargin = max(3 * steadyRipple, floor * 0.4)
                phraseRange = 0
            }
        } else {
            lowestDB = slowDB
            highestDB = slowDB
            steadyTime = 0
        }

        // Sample the bottom of varying speech. A quiet interval can sit well above
        // digital silence, especially when a recording begins with the microphone muted.
        windowMin = min(windowMin, target)
        windowMax = max(windowMax, target)
        windowTime += dt
        if windowTime >= 0.8 {
            valley = min(valley, windowMin)
            if windowMax > 2 * windowMin {
                valley = min(0.065, windowMin * 0.625)
            }
            windowMin = target
            windowMax = target
            windowTime = 0
        }
        let background = max(floor, valley)
        let margin = max(0.014, floor * 0.4)
        // Clamp the ripple contribution so one quiet outlier cannot mask soft speech.
        let closeMargin = max(0.008, 0.22 * background, min(ripple * 1.5, background * 0.5))
        let openMargin = max(learnedMargin, 0.014, 0.4 * background, min(ripple * 3, background * 0.9))
        let headroom = min(Float(1).nextDown, floor + (1 - floor) * 0.6)
        let threshold = min(headroom, voiced ? max(0.016, background + closeMargin) : max(0.022, background + openMargin))
        if target > threshold {
            aboveFloor += dt
            let debounce: Float = target < threshold + min(background * 1.25, 3 * ripple) ? 0.12 : 0.025
            if !voiced, aboveFloor >= debounce {
                voiced = true
                floorAtGateOpen = floor
            }
        } else {
            aboveFloor = 0
            voiced = false
            learnedMargin = min(learnedMargin, floor * 0.9)
            follow(&ripple, abs(target - floor), 0.3)
            follow(&floor, target, target < floor ? 0.12 : 3)
        }
        // A new phrase inherits the last one's measured range, not its inherited ceiling.
        if voiced {
            if signal.quiet >= 0.4 {
                let excursion = max(0.045, target - floorAtGateOpen)
                high = min(1, floorAtGateOpen + max(0.055, min(phraseRange, 3 * excursion)))
                // The long release of a loud word can outlast the pause between phrases.
                slow = min(slow, floorAtGateOpen + 0.15 * excursion)
                phraseRange = 0
            }
            high = max(high, target)
            if high > target {
                // Keep a held note in its lane as its peak reference settles.
                follow(&high, target, steadyTime < 0.25 ? 4 : 60)
            }
            phraseRange = max(phraseRange, target - floorAtGateOpen)
        } else {
            follow(&phraseRange, 0, 5)
            follow(&high, floor + 0.055, 1.4)
        }
        signal.quiet = voiced ? 0 : signal.quiet + dt
        let contourFloor = voiced ? floorAtGateOpen : floor
        let range = max(0.045, high - contourFloor)
        signal.contour = min(1, max(0, (target - contourFloor) / range))

        if voiced {
            signal.contour = ranks.contour(db: db, linear: signal.contour, dt: dt)
        } else {
            ranks.endHold()
        }

        sinceOnset += dt
        signal.onset = 0
        let lift = fast - slow
        let rangeRise = range * 0.15
        let rise = max(min(margin * 0.85, 0.08), min(rangeRise, max(0.016, slow * 0.18)))
        // Keep the trough between syllables reachable when the attack threshold is capped.
        let rearm = min(rise * 0.85, max(rise, rangeRise) * 0.35)
        attackTrough = voiced ? min(attackTrough, db) : AdaptiveLevelScale.floorDecibels
        if voiced, armed, db - attackTrough >= 3, lift > rise, sinceOnset > 0.13 {
            attackTrough = db
            armed = false
            sinceOnset = 0
            beats += 1
            signal.onset = min(1, 0.35 + lift / range)
        } else if !armed, lift < rearm {
            armed = true
        }
        // A leaky count of syllables: at a steady rate r it settles at r * 0.9, so pace reads r.
        beats *= exp(-dt / 0.9)
        signal.pace = beats / 0.9

        reservoir += (1.75 * signal.level * signal.level - reservoir / 1.8) * dt
        signal.energy = 1 - exp(-max(0, reservoir) * 1.45)

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
/// and draw. The simulation steps at a fixed 120 a second whatever the screen does.
public final class VoiceArtEngine {
    public let style: MeterStyle
    let painter: VoicePainter
    private var tracker = VoiceTracker()
    private var level: Float = 0
    private var owed: Double = 0
    private let tick: Double

    /// Nil for the styles that are not drawn here (Wave, Mirrored, Bars, Scope).
    public convenience init?(style: MeterStyle, seed: UInt64) {
        self.init(style: style, seed: seed, tick: 1.0 / 120)
    }

    init?(style: MeterStyle, seed: UInt64, tick: Double) {
        guard tick.isFinite, tick > 0 else { return nil }
        self.tick = tick
        let random = ArtRandom(seed: seed)
        switch style {
        case .ink: painter = InkPainter(random: random)
        case .glyphs: painter = GlyphPainter(random: random)
        case .branch: painter = BranchPainter(random: random)
        case .inkblot: painter = InkblotPainter(random: random)
        case .lanes: painter = LanesPainter()
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
        while owed >= tick {
            owed -= tick
            let voice = tracker.step(level: level, dt: Float(tick))
            painter.step(voice, dt: CGFloat(tick), size: size)
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
