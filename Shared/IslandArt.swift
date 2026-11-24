// by zayd/cold @ zayd.wtf

import SwiftUI

/// The island's living looks: creatures and ornaments drawn in code, with no image files.
///
/// Each one is drawn from a handful of numbers (`IslandMood`). The island redraws only when Zone
/// sends an update, about once a second while recording, and iOS lets a Live Activity animate
/// for up to two seconds on each one. So every update is a new pose and the drawing glides to
/// it: an eye widening, a wing lifting, a comet moving along its loop. The motion is continuous
/// while Zone records and still when it does not, which is also the honest thing to show.
///
/// The same views draw the gallery in Settings, where a timeline drives the mood instead.
struct IslandMood: Equatable {
    enum Kind: Equatable {
        /// Standby: the microphone waits, nothing is recorded.
        case asleep
        /// Recording.
        case listening
        /// Recording, paused by the person.
        case paused
        /// Recognizing after Stop.
        case thinking
        /// A recording was just kept.
        case happy
        /// An interruption (a call, an alarm) has the microphone.
        case away
        /// Zone stopped refreshing the card.
        case lost
    }

    var kind: Kind
    /// The newest loudness, 0...1.
    var level: Double = 0
    /// Loudness over the last second or so, 0...1: calmer than `level`.
    var energy: Double = 0
    /// Counts updates while recording. Blinks, glances, wingbeats and the comet's place follow it.
    var beat: Int = 0
    /// The pet's growth stage (`IslandPetGrowth`), 0 an egg.
    var stage: Int = 1
    /// How far this recording has come, 0...1: a sprout grows with the words spoken.
    var growth: Double = 0
    /// Recordings kept this session: one flower each.
    var garden: Int = 0
    var night = false
    var dailyEnergy: Int = 0
    var accessory: Int = 0
    var hasPortrait = false
    var wink = false
    var confetti = false
    var synthLevels: [UInt8] = []
    var spin: IslandSpin? = nil

    var awake: Bool { kind == .listening }
}

extension IslandMood {
    /// Pick at most one short window per event per recording. Every rendering surface agrees.
    private static func surprise(_ state: RecordingActivityAttributes.ContentState, salt: UInt64, odds: UInt64) -> Bool {
        let stamp = UInt64(bitPattern: Int64(state.startedAt.timeIntervalSince1970 * 1000))
        let seed = (stamp ^ salt) &* 11_400_714_819_323_198_485
        let beat = UInt16(3 + (seed >> 32) % 13)
        return (seed >> 16) % odds == 0 && state.beat == beat
    }

    init(state: RecordingActivityAttributes.ContentState, stale: Bool) {
        let kind: Kind
        if state.phase == .ready, state.standbyHeld == true {
            kind = .away
        } else if stale {
            kind = .lost
        } else {
            switch state.phase {
            case .starting: kind = .thinking
            case .ready: kind = state.justFinished == true ? .happy : .asleep
            case .recording: kind = state.userPausedAt != nil ? .paused : .listening
            case .paused: kind = .away
            case .processing: kind = .thinking
            }
        }
        let levels = state.levels ?? []
        let recent = levels.suffix(6)
        self.init(kind: kind,
                  level: kind == .listening ? IslandLevels.unit(levels.last ?? 0) : 0,
                  energy: kind == .listening && !recent.isEmpty
                      ? recent.reduce(0) { $0 + IslandLevels.unit($1) } / Double(recent.count) : 0,
                  beat: Int(state.beat ?? 0),
                  stage: Int(state.petStage ?? 1),
                  growth: min(1, Double(state.words ?? 0) / 65 + Double(state.beat ?? 0) / 55 + Double(state.dailyEnergy ?? 0) / 12),
                  garden: state.session?.dictations ?? 0, night: state.nightGarden == true,
                  dailyEnergy: Int(state.dailyEnergy ?? 0), accessory: Int(state.accessory ?? 0),
                  hasPortrait: state.gallery == true,
                  wink: kind == .listening && Self.surprise(state, salt: 13, odds: 9),
                  confetti: kind == .listening && Self.surprise(state, salt: 37, odds: 23),
                  synthLevels: state.look == .synth ? Array(levels.suffix(SynthFigure.columnCount)) : [], spin: state.spin)
    }
}

/// How an art view moves between two moods. Linear over about one update, so consecutive
/// updates join into one continuous motion; none with Reduce Motion.
struct IslandMotion: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let mood: IslandMood
    var duration: Double = 1.0

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : .easeInOut(duration: duration), value: mood)
    }
}

extension View {
    func islandMotion(_ mood: IslandMood, duration: Double = 1.0) -> some View {
        modifier(IslandMotion(mood: mood, duration: duration))
    }
}

// MARK: - Void: the island is the cat

/// One eye of the creature whose body is the island itself. The island is black and so is the
/// cat, so two eyes are the whole drawing, and the camera between them is its nose.
struct EyeShape: Shape {
    /// 0 shut, 1 wide.
    var open: Double
    /// Bends the shut lid: -1 droops (asleep), +1 arches (pleased).
    var curve: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(open, curve) }
        set { open = newValue.first; curve = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let half = rect.height * CGFloat(max(0, min(1, open)))
        let bend = CGFloat(curve) * rect.height * 0.55 * CGFloat(1 - min(1, open))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY),
                          control: CGPoint(x: rect.midX, y: rect.midY - half - bend))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.midY),
                          control: CGPoint(x: rect.midX, y: rect.midY + half - bend))
        return path
    }
}

/// A cat's pupil: a slit in the quiet, round when it hears something loud.
struct PupilShape: Shape {
    /// 0 a slit, 1 round.
    var width: Double
    var gazeX: Double
    var gazeY: Double

    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { AnimatablePair(width, AnimatablePair(gazeX, gazeY)) }
        set { width = newValue.first; gazeX = newValue.second.first; gazeY = newValue.second.second }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.height * CGFloat(0.16 + 0.62 * max(0, min(1, width)))
        let h = rect.height * 0.98
        let center = CGPoint(x: rect.midX + CGFloat(gazeX) * rect.width * 0.2,
                             y: rect.midY + CGFloat(gazeY) * rect.height * 0.16)
        return Path(ellipseIn: CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h))
    }
}

struct VoidEye: View {
    let mood: IslandMood
    let tint: Color
    var right = false
    var size = CGSize(width: 17, height: 12)
    /// The real island only: a slow blink every ten seconds while Zone waits (`IslandBlink`).
    var blinks = false
    /// The catchlight. White, except where the palette allows no white.
    var glint: Color = .white.opacity(0.9)

    private struct Pose {
        var open = 0.0, curve = 0.0, pupil = 0.3, gazeX = 0.0, gazeY = 0.0, glow = 1.0
    }

    private var pose: Pose {
        switch mood.kind {
        // Waiting is resting, not sleeping: half-lidded, no pupil to follow anything. Wide eyes
        // with pupils mean Zone is listening.
        case .asleep: return Pose(open: 0.56, curve: -0.5, pupil: 0, glow: 0.85)
        case .happy: return Pose(open: 0, curve: 1)
        case .away: return Pose(open: 0, curve: -0.35, glow: 0.45)
        case .lost: return Pose(open: 0, curve: 0, glow: 0.35)
        case .paused: return Pose(open: 0.36, curve: -0.4, pupil: 0.35, glow: 0.8)
        case .thinking: return Pose(open: 0.9, pupil: 0.18, gazeX: 0.7, gazeY: -0.9)
        case .listening:
            // A slow blink now and then: between cats it means all is well.
            if mood.beat % 9 == 8 { return Pose(open: 0.16, curve: -0.7, pupil: 0.4) }
            let glance = [0.0, 0.55, 0.0, -0.55][mood.beat % 4] * (1 - mood.level)
            return Pose(open: 0.66 + 0.34 * mood.level, pupil: 0.22 + 0.78 * mood.level, gazeX: glance)
        }
    }

    var body: some View {
        let pose = pose
        ZStack {
            EyeShape(open: pose.open, curve: pose.curve).fill(tint)
            // The lid's line stays when the eye is shut, so a sleeping eye is a curve, not nothing.
            EyeShape(open: pose.open, curve: pose.curve)
                .stroke(tint, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
            PupilShape(width: pose.pupil, gazeX: pose.gazeX, gazeY: pose.gazeY)
                .fill(.black)
                .mask(EyeShape(open: pose.open, curve: pose.curve))
                .opacity(pose.pupil > 0 ? 1 : 0)
            Circle().fill(glint)
                .frame(width: size.height * 0.2, height: size.height * 0.2)
                .offset(x: -size.width * 0.14, y: -size.height * 0.2)
                .opacity(pose.open > 0.5 ? 1 : 0)
            if blinks, mood.kind == .asleep {
                IslandBlink {
                    ZStack {
                        Rectangle().fill(.black)
                        EyeShape(open: 0, curve: -0.8)
                            .stroke(tint, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        // The outer corner lifts, as a cat's does.
        .rotationEffect(.degrees(right ? -9 : 9))
        .opacity(pose.glow)
        .islandMotion(mood, duration: mood.kind == .listening ? 0.9 : 0.45)
        .accessibilityHidden(true)
    }
}

// MARK: - Nocturne: a bat whose body is the camera

/// One wing. The root is at the trailing edge, toward the camera; the tip reaches outward.
struct WingShape: Shape {
    /// 0 folded, 1 spread.
    var spread: Double
    /// -1 the tip hangs, +1 the tip is raised: one wingbeat goes from one to the other.
    var lift: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(spread, lift) }
        set { spread = newValue.first; lift = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * CGFloat(x), y: rect.minY + rect.height * CGFloat(y))
        }
        let reach = 0.18 + 0.82 * max(0, min(1, spread))
        let tipX = 1 - reach
        let tipY = 0.34 - lift * 0.26
        let shoulder = point(1, 0.3), hip = point(1, 0.72)
        let tip = point(tipX, tipY)
        var path = Path()
        path.move(to: shoulder)
        // The arm: an arch from the shoulder out to the tip.
        path.addQuadCurve(to: tip, control: point(1 - reach * 0.45, tipY - 0.3 - lift * 0.1))
        // The membrane: three scallops back to the hip, each a point with a hollow between.
        let hem = [(tipX + reach * 0.34, 0.86 - lift * 0.1), (tipX + reach * 0.68, 0.92), (1.0, 0.72)]
        var from = (tipX, tipY)
        for to in hem {
            path.addQuadCurve(to: point(to.0, to.1),
                              control: point((from.0 + to.0) / 2, min(from.1, to.1) - 0.16))
            from = to
        }
        path.addLine(to: hip)
        path.closeSubpath()
        return path
    }
}

struct BatWing: View {
    let mood: IslandMood
    let tint: Color
    var right = false
    var size = CGSize(width: 24, height: 17)

    private var pose: (spread: Double, lift: Double, glow: Double) {
        let up = mood.beat % 2 == 0 ? 1.0 : -1.0
        switch mood.kind {
        case .asleep: return (0.22, -0.8, 0.7)
        case .away: return (0.2, -1, 0.45)
        case .lost: return (0.2, -1, 0.35)
        case .paused: return (0.4, -0.3, 0.8)
        case .thinking: return (0.62, up * 0.25, 1)
        case .happy: return (1, 1, 1)
        case .listening: return (0.5 + 0.5 * mood.level, up * (0.3 + 0.6 * mood.energy), 1)
        }
    }

    var body: some View {
        let pose = pose
        WingShape(spread: pose.spread, lift: pose.lift)
            .fill(tint)
            .frame(width: size.width, height: size.height)
            .scaleEffect(x: right ? -1 : 1)
            .opacity(pose.glow)
            .islandMotion(mood)
            .accessibilityHidden(true)
    }
}

/// The whole bat, for places with no camera to be its body.
struct BatFigure: View {
    let mood: IslandMood
    let tint: Color
    var height: CGFloat = 20

    var body: some View {
        let wing = CGSize(width: height * 1.35, height: height * 0.92)
        HStack(alignment: .center, spacing: -1) {
            BatWing(mood: mood, tint: tint, size: wing)
            ZStack {
                BatBody().fill(tint)
                BatEars().fill(tint)
                HStack(spacing: height * 0.11) {
                    Circle().fill(.black).frame(width: height * 0.1, height: height * 0.1)
                    Circle().fill(.black).frame(width: height * 0.1, height: height * 0.1)
                }
                .offset(y: -height * 0.06)
                .opacity(mood.kind == .asleep || mood.kind == .away ? 0 : 1)
            }
            .frame(width: height * 0.46, height: height * 0.9)
            BatWing(mood: mood, tint: tint, right: true, size: wing)
        }
        .accessibilityHidden(true)
    }
}

struct BatBody: Shape {
    func path(in rect: CGRect) -> Path {
        Path(ellipseIn: CGRect(x: rect.minX, y: rect.minY + rect.height * 0.22,
                               width: rect.width, height: rect.height * 0.78))
    }
}

/// Drawn apart from the body: two shapes in one path cut a hole where they overlap.
struct BatEars: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for side in [0.0, 1.0] {
            let x = rect.minX + rect.width * CGFloat(side == 0 ? 0.06 : 0.94)
            let inner = rect.minX + rect.width * CGFloat(side == 0 ? 0.46 : 0.54)
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: inner, y: rect.minY + rect.height * 0.4))
            path.addLine(to: CGPoint(x: x, y: rect.minY + rect.height * 0.55))
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - Ember

/// One closed silhouette. The tip bends and the belly swells with the voice.
struct CoalFlame: Shape {
    var breath: Double
    var animatableData: Double {
        get { breath }
        set { breath = newValue }
    }

    func path(in rect: CGRect) -> Path {
        func pt(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: pt(0.5, 0.99))
        path.addCurve(to: pt(0.34, 0.32), control1: pt(0.02, 0.94), control2: pt(0.16, 0.63))
        path.addQuadCurve(to: pt(0.42, 0.51), control: pt(0.32, 0.48))
        path.addQuadCurve(to: pt(0.50 + 0.19 * breath, 0.22 - 0.20 * breath), control: pt(0.58, 0.30))
        path.addCurve(to: pt(0.50, 0.99), control1: pt(0.60, 0.51), control2: pt(1.06, 0.86))
        path.closeSubpath()
        return path
    }
}

struct LoopFigure: View {
    let mood: IslandMood
    let tint: Color
    var size = CGSize(width: 34, height: 16)
    var body: some View {
        CoalFlame(breath: mood.awake ? mood.energy : 0)
            .fill(LinearGradient(colors: [IslandPigment.honey, IslandPigment.coral, IslandPigment.coral.mix(with: tint, by: 0.32)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: min(size.width, size.height * 1.14), height: size.height)
            .frame(width: size.width, height: size.height)
            .islandMotion(mood)
            .accessibilityHidden(true)
    }
}

// MARK: - Sprout: what you say grows

struct StemShape: Shape {
    /// 0 a seedling, 1 full height.
    var height: Double
    /// -1 leans left, +1 right.
    var lean: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(height, lean) }
        set { height = newValue.first; lean = newValue.second }
    }

    static func top(height: Double, lean: Double, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX + CGFloat(lean) * rect.width * 0.26,
                y: rect.maxY - rect.height * CGFloat(0.2 + 0.62 * height))
    }

    static func along(_ t: CGFloat, height: Double, lean: Double, in rect: CGRect) -> CGPoint {
        let base = CGPoint(x: rect.midX, y: rect.maxY)
        let top = top(height: height, lean: lean, in: rect)
        let control = CGPoint(x: rect.midX - CGFloat(lean) * rect.width * 0.1, y: (base.y + top.y) / 2)
        let a = (1 - t) * (1 - t), b = 2 * (1 - t) * t, c = t * t
        return CGPoint(x: a * base.x + b * control.x + c * top.x, y: a * base.y + b * control.y + c * top.y)
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        for i in 1...12 {
            path.addLine(to: Self.along(CGFloat(i) / 12, height: height, lean: lean, in: rect))
        }
        return path
    }
}

struct LeavesShape: Shape {
    var height: Double
    var lean: Double
    /// 0 none, 1 full leaves.
    var leaf: Double

    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { AnimatablePair(height, AnimatablePair(lean, leaf)) }
        set { height = newValue.first; lean = newValue.second.first; leaf = newValue.second.second }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let length = rect.width * 0.36 * CGFloat(leaf)
        guard length > 0.3 else { return path }
        for (t, side) in [(CGFloat(0.42), CGFloat(-1)), (0.66, 1)] {
            let root = StemShape.along(t, height: height, lean: lean, in: rect)
            let tip = CGPoint(x: root.x + side * length, y: root.y - length * 0.55)
            let belly = length * 0.42
            path.move(to: root)
            path.addQuadCurve(to: tip, control: CGPoint(x: root.x + side * length * 0.35, y: root.y - length * 0.55 - belly))
            path.addQuadCurve(to: root, control: CGPoint(x: root.x + side * length * 0.75, y: root.y + belly * 0.25))
        }
        return path
    }
}

struct BloomShape: Shape {
    var height: Double
    var lean: Double
    /// 0 a bud, 1 open.
    var bloom: Double

    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { AnimatablePair(height, AnimatablePair(lean, bloom)) }
        set { height = newValue.first; lean = newValue.second.first; bloom = newValue.second.second }
    }

    func path(in rect: CGRect) -> Path {
        let center = StemShape.top(height: height, lean: lean, in: rect)
        let bud = rect.width * 0.1
        var path = Path()
        guard bloom > 0.04 else {
            path.addEllipse(in: CGRect(x: center.x - bud, y: center.y - bud * 1.3, width: bud * 2, height: bud * 2.6))
            return path
        }
        let petal = rect.width * (0.1 + 0.2 * CGFloat(bloom))
        for k in 0..<5 {
            let angle = CGFloat(k) / 5 * 2 * .pi - .pi / 2
            let c = CGPoint(x: center.x + cos(angle) * petal * 0.72, y: center.y + sin(angle) * petal * 0.72)
            path.addEllipse(in: CGRect(x: c.x - petal * 0.55, y: c.y - petal * 0.55, width: petal * 1.1, height: petal * 1.1))
        }
        return path
    }
}

struct SproutFigure: View {
    let mood: IslandMood
    let tint: Color
    var size = CGSize(width: 18, height: 22)
    /// A finished flower in the garden: full height, open, still.
    var grown = false

    private var pose: (height: Double, lean: Double, leaf: Double, bloom: Double, glow: Double) {
        if grown { return (1, 0, 1, 1, 0.8) }
        let sway = (mood.beat % 2 == 0 ? 1.0 : -1.0) * (0.12 + 0.5 * mood.level)
        switch mood.kind {
        case .asleep: return (0.3, 0, 0.7, 0, 0.75)
        case .away: return (0.3, -0.5, 0.6, 0, 0.45)
        case .lost: return (0.3, -0.7, 0.5, 0, 0.35)
        case .paused: return (0.3 + 0.7 * mood.growth, 0, 0.6 + 0.4 * mood.growth, 0, 0.8)
        case .listening: return (0.3 + 0.7 * mood.growth, sway, 0.6 + 0.4 * mood.growth, 0, 1)
        case .thinking: return (0.3 + 0.7 * mood.growth, 0, 1, 0.4, 1)
        case .happy: return (1, 0, 1, 1, 1)
        }
    }

    var body: some View {
        let pose = pose
        ZStack {
            StemShape(height: pose.height, lean: pose.lean)
                .stroke(IslandPigment.stem.opacity(mood.night ? 0.78 : 1), style: StrokeStyle(lineWidth: max(1.4, size.width * 0.09), lineCap: .round))
            LeavesShape(height: pose.height, lean: pose.lean, leaf: pose.leaf).fill(IslandPigment.leaf.opacity(mood.night ? 0.78 : 1))
            if mood.night {
                // A closed bud at dusk, even in the garden of saved recordings.
                Capsule().fill(tint.mix(with: .white, by: 0.55))
                    .frame(width: size.width * 0.27, height: size.height * 0.28)
                    .position(StemShape.top(height: pose.height, lean: pose.lean, in: CGRect(origin: .zero, size: size)))
            } else {
                BloomShape(height: pose.height, lean: pose.lean, bloom: pose.bloom).fill(tint)
            }
            Circle().fill(IslandPigment.flowerCenter)
                .frame(width: size.width * 0.18, height: size.width * 0.18)
                .position(StemShape.top(height: pose.height, lean: pose.lean, in: CGRect(origin: .zero, size: size)))
                .opacity(!mood.night && pose.bloom > 0.5 ? 1 : 0)
        }
        .frame(width: size.width, height: size.height)
        .opacity(pose.glow)
        .islandMotion(mood)
        .accessibilityHidden(true)
    }
}

/// The session as a garden: one open flower for each recording kept, and the one growing now.
struct GardenRow: View {
    let mood: IslandMood
    let tint: Color
    var height: CGFloat = 30
    var most = 9

    var body: some View {
        let kept = min(mood.garden, most)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<kept, id: \.self) { index in
                // No two flowers the same height: a garden, not a bar chart.
                let scale = 0.62 + 0.3 * abs(sin(Double(index) * 2.4 + 0.7))
                SproutFigure(mood: mood, tint: tint, size: CGSize(width: height * 0.5, height: height * scale), grown: true)
            }
            if mood.kind != .asleep || kept == 0 {
                SproutFigure(mood: mood, tint: tint, size: CGSize(width: height * 0.6, height: height))
            }
        }
        .frame(height: height, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

// MARK: - Mote: a pet that grows with your words

/// The pet's pixels. Each stage is a grid; `#` is body, `o` a shade, `w` white, `.` empty.
enum MoteSprite {
    static let columns = 15
    static let rows = 11

    static let bodies: [[String]] = [
        // 0: an egg
        ["..............",
         ".....####.....",
         "....######....",
         "...###oo###...",
         "...########...",
         "..##########..",
         "..#oo#######..",
         "..##########..",
         "..######oo##..",
         "...########...",
         "....######...."],
        // 1: hatched
        ["..............",
         "..............",
         "....######....",
         "...########...",
         "..##########..",
         "..##########..",
         "..##########..",
         "..##########..",
         "..##########..",
         "...########...",
         "...##....##..."],
        // 2: ears
        ["..##......##..",
         "..###....###..",
         "..##########..",
         ".############.",
         ".############.",
         ".############.",
         ".#b########b#.",
         ".############.",
         "..##########..",
         "...########...",
         "...##....##..."],
        // 3: a tail
        ["..##......##..",
         "..###....###..",
         "..##########..",
         ".############.",
         ".############.",
         ".############.",
         ".#b########b##",
         ".############.#",
         "..##########.#",
         "...########...",
         "...##....##..."],
        // 4: a crown
        ["..w..w..w..w..",
         "..wwwwwwwwww..",
         "..##########..",
         ".############.",
         ".############.",
         ".############.",
         ".#b########b##",
         ".############.#",
         "..##########.#",
         "...########...",
         "...##....##..."],
    ]

    /// Where the face goes: the left eye's column, the right eye's, their top row, the mouth's row.
    /// The eyes sit wide and the mouth low, with a clear row between: at two points a pixel,
    /// features that touch stop being a face.
    static let faces: [(left: Int, right: Int, eyeRow: Int, mouthRow: Int)?] = [
        nil, (3, 9, 4, 7), (3, 9, 4, 7), (3, 9, 4, 7), (3, 9, 4, 7),
    ]

    static func cells(_ glyph: Character, stage: Int) -> [(Int, Int)] {
        let grid = bodies[max(0, min(bodies.count - 1, stage))]
        var cells: [(Int, Int)] = []
        for (row, line) in grid.enumerated() {
            for (column, character) in line.enumerated() where character == glyph {
                cells.append((column, row))
            }
        }
        return cells
    }

    enum Eyes { case open, shut, pleased, wide }
    enum Mouth { case shut, small, big, smile }

    static func face(stage: Int, eyes: Eyes, mouth: Mouth) -> (ink: [(Int, Int)], glint: [(Int, Int)]) {
        guard let face = faces[max(0, min(faces.count - 1, stage))] else { return ([], []) }
        var ink: [(Int, Int)] = [], glint: [(Int, Int)] = []
        let row = face.eyeRow
        for x in [face.left, face.right] {
            switch eyes {
            case .open:
                ink += [(x, row), (x + 1, row), (x, row + 1), (x + 1, row + 1)]
                glint.append((x, row))
            case .wide:
                ink += [(x, row - 1), (x + 1, row - 1), (x, row), (x + 1, row), (x, row + 1), (x + 1, row + 1)]
                glint.append((x, row - 1))
            case .shut:
                ink += [(x, row + 1), (x + 1, row + 1)]
            case .pleased:
                // An arch: the eye of something smiling.
                let left = x == face.left ? x : x - 1
                ink += [(left, row + 1), (left + 1, row), (left + 2, row + 1)]
            }
        }
        let m = 6, mouthRow = face.mouthRow
        switch mouth {
        case .shut: break
        case .small: ink += [(m, mouthRow), (m + 1, mouthRow)]
        case .big: ink += [(m, mouthRow), (m + 1, mouthRow), (m, mouthRow + 1), (m + 1, mouthRow + 1)]
        case .smile: ink += [(m - 1, mouthRow), (m, mouthRow + 1), (m + 1, mouthRow + 1), (m + 2, mouthRow)]
        }
        return (ink, glint)
    }
}

struct PixelShape: Shape {
    let cells: [(Int, Int)]

    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width / CGFloat(MoteSprite.columns), rect.height / CGFloat(MoteSprite.rows))
        let x0 = rect.midX - unit * CGFloat(MoteSprite.columns) / 2
        let y0 = rect.midY - unit * CGFloat(MoteSprite.rows) / 2
        var path = Path()
        for (column, row) in cells {
            // A hair of overlap, so neighbors never show a seam between them.
            path.addRect(CGRect(x: x0 + CGFloat(column) * unit, y: y0 + CGFloat(row) * unit,
                                width: unit + 0.3, height: unit + 0.3))
        }
        return path
    }
}

struct MoteFigure: View {
    let mood: IslandMood
    let tint: Color
    var height: CGFloat = 22

    private var eyes: MoteSprite.Eyes {
        switch mood.kind {
        case .asleep, .away, .lost: .shut
        case .happy: .pleased
        case .thinking: .wide
        case .paused: .shut
        case .listening: mood.beat % 5 == 4 ? .shut : (mood.level > 0.75 ? .wide : .open)
        }
    }
    private var mouth: MoteSprite.Mouth {
        switch mood.kind {
        case .happy: .smile
        case .listening: mood.level > 0.6 ? .big : (mood.level > 0.18 ? .small : .shut)
        default: .shut
        }
    }
    /// Pixel art steps; only where the whole creature sits glides. A hop on the loud beats.
    private var hop: CGFloat {
        switch mood.kind {
        case .listening: mood.beat % 2 == 1 ? -height * CGFloat(0.05 + 0.12 * mood.energy) : 0
        case .happy: -height * 0.14
        default: 0
        }
    }
    private var tilt: Double {
        guard mood.stage == 0 else { return 0 }
        // An egg cannot hop, so it rocks.
        return mood.kind == .listening ? (mood.beat % 2 == 0 ? 7 : -7) * (0.4 + mood.energy) : 0
    }

    var body: some View {
        let stage = max(0, min(MoteSprite.bodies.count - 1, mood.stage))
        let face = MoteSprite.face(stage: stage, eyes: eyes, mouth: mouth)
        let dim = mood.kind == .away ? 0.45 : (mood.kind == .lost ? 0.35 : (mood.kind == .asleep ? 0.8 : 1.0))
        ZStack {
            PixelShape(cells: MoteSprite.cells("#", stage: stage) + MoteSprite.cells("o", stage: stage)
                + MoteSprite.cells("b", stage: stage)).fill(tint)
            PixelShape(cells: MoteSprite.cells("o", stage: stage)).fill(.black.opacity(0.26))
            PixelShape(cells: MoteSprite.cells("b", stage: stage)).fill(tint.mix(with: .black, by: 0.22))
            PixelShape(cells: MoteSprite.cells("w", stage: stage)).fill(tint.mix(with: .white, by: 0.42))
            PixelShape(cells: face.ink).fill(.black)
            PixelShape(cells: face.glint).fill(.white)
        }
        .frame(width: height * CGFloat(MoteSprite.columns) / CGFloat(MoteSprite.rows), height: height)
        .overlay(alignment: .topTrailing) {
            if mood.stage >= 5 { PetStar(tint: tint, height: height) }
        }
        .rotationEffect(.degrees(tilt), anchor: .bottom)
        .offset(y: hop)
        .opacity(dim)
        .islandMotion(mood, duration: 0.5)
        .accessibilityHidden(true)
    }
}

private struct PetStar: View {
    let tint: Color
    let height: CGFloat

    var body: some View {
        Path { path in
            let size = height * 0.28
            for i in 0..<8 {
                let angle = Double(i) * .pi / 4
                let radius = size * (i.isMultiple(of: 2) ? 0.5 : 0.17)
                let point = CGPoint(x: size / 2 + cos(angle) * radius, y: size / 2 + sin(angle) * radius)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
        }
        .fill(tint.mix(with: .white, by: 0.5))
        .frame(width: height * 0.28, height: height * 0.28)
    }
}

/// Pip reads by its long ears and tail. Wren reads by its bill and swept tail.
struct CompanionFigure: View {
    let look: IslandLook
    let mood: IslandMood
    let tint: Color
    let height: CGFloat

    var body: some View {
        ZStack {
            CompanionShape(look: look, mood: mood, layer: .coat).fill(tint)
            CompanionShape(look: look, mood: mood, layer: .light).fill(tint.mix(with: .white, by: 0.35))
            CompanionShape(look: look, mood: mood, layer: .eye).fill(.black)
        }
        .frame(width: height * 1.25, height: height)
        .overlay(alignment: .topTrailing) {
            if mood.stage >= 5 { PetStar(tint: tint, height: height) }
        }
        .scaleEffect(0.76 + 0.06 * Double(min(4, mood.stage)), anchor: .bottom)
        .offset(y: mood.awake && mood.beat % 4 == 2 ? -height * 0.06 : 0)
        .islandMotion(mood)
        .accessibilityHidden(true)
    }
}

private struct CompanionShape: Shape {
    enum Layer { case coat, light, eye }
    let look: IslandLook
    let mood: IslandMood
    let layer: Layer

    func path(in rect: CGRect) -> Path {
        let grown = CGFloat(min(4, max(0, mood.stage)))
        let resting = mood.kind == .asleep || mood.kind == .away
        var path = Path()
        func oval(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
            path.addEllipse(in: CGRect(x: x, y: y, width: w, height: h))
        }
        func triangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) {
            path.move(to: a)
            path.addLine(to: b)
            path.addLine(to: c)
            path.closeSubpath()
        }
        switch (look, layer) {
        case (.hare, .coat):
            oval(5, 11, 13 + grown, 10)
            oval(13, 9, 10, 10)
            for x in [14, 18] { oval(CGFloat(x), 7 - grown, 3, 6 + grown) }
        case (.hare, .light):
            oval(3, 15, 5, 5)
            oval(8, 19, 9, 3)
        case (.hare, .eye):
            oval(19, 12, 2, resting ? 1 : 2.5)
        case (_, .coat):
            triangle(.init(x: 3, y: 9 - grown), .init(x: 12, y: 14), .init(x: 9, y: 19))
            oval(7, 11, 15, 10)
            oval(15, 7, 9, 10)
        case (_, .light):
            triangle(.init(x: 23, y: 11), .init(x: 28, y: 13), .init(x: 23, y: 14))
            oval(9, 13, 6 + grown, 4)
        case (_, .eye):
            oval(20, 10, 2, resting ? 1 : 2)
        }
        if layer == .light && grown >= 4 {
            triangle(.init(x: 10, y: 8), .init(x: 12, y: 4), .init(x: 14, y: 8))
        }
        return path.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width / 30, y: rect.height / 24))
    }
}

// MARK: - One figure for any look

/// A look's whole figure in one frame: the minimal island, the expanded island's badge, the
/// Lock Screen card and the gallery.
struct IslandFigure: View {
    let look: IslandLook
    let mood: IslandMood
    let tint: Color
    var height: CGFloat = 20
    /// `.gates` only inside the widget extension, where the gate fonts are.
    var clock: IslandClock = .still
    var glint: Color = .white.opacity(0.9)

    var body: some View {
        if mood.hasPortrait && !look.spins {
            IslandSprite(look: look, mood: mood, tint: tint, height: height)
        } else {
            legacyFigure
        }
    }

    @ViewBuilder private var legacyFigure: some View {
        switch look {
        case .void:
            HStack(spacing: height * 0.42) {
                VoidEye(mood: mood, tint: tint, size: CGSize(width: height * 0.8, height: height * 0.56),
                        blinks: clock == .gates, glint: glint)
                VoidEye(mood: mood, tint: tint, right: true, size: CGSize(width: height * 0.8, height: height * 0.56),
                        blinks: clock == .gates, glint: glint)
            }
        case .pulse:
            PulseFigure(mood: mood, tint: tint, size: CGSize(width: height * 2.3, height: height * 0.8),
                        heart: height * 0.62, clock: clock)
        case .drift:
            DriftFigure(mood: mood, tint: tint, size: CGSize(width: height * 1.9, height: height * 0.95))
        case .nocturne:
            BatFigure(mood: mood, tint: tint, height: height * 0.9)
        case .loop:
            LoopFigure(mood: mood, tint: tint, size: CGSize(width: height * 1.9, height: height * 0.82))
        case .rose:
            RoseFigure(mood: mood, height: height)
        case .cube, .sword:
            IslandRelic(look: look, mood: mood, tint: tint, height: height, clock: clock)
        case .synth:
            SynthFigure(mood: mood, tint: tint, height: height)
        case .sprout:
            SproutFigure(mood: mood, tint: tint, size: CGSize(width: height * 0.8, height: height))
        case .hare, .wren:
            CompanionFigure(look: look, mood: mood, tint: tint, height: height)
        case .mote:
            MoteFigure(mood: mood, tint: tint, height: height)
        case .blackout, .halo, .recorder, .caption, .ghost, .stream:
            EmptyView()
        }
    }
}
