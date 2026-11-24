// by zayd/cold @ zayd.wtf

import SwiftUI

/// The island's art looks: Pulse and Drift, and the clockwork that lets a drawing move while
/// Zone sends nothing at all (`IslandGate`). Stream, the third art look, is words and lives with
/// the island's text in `ZoneIsland.swift`.
///
/// Like the living looks in `IslandArt.swift`, everything is drawn in code from an `IslandMood`,
/// and the same views draw the gallery in Settings.

/// Pigments for the objects drawn on the black island. The app accent still colors
/// the flower petals, waveform and controls; leaves, shadows and highlights have their own hues.
enum IslandPigment {
    static let stem = Color(red: 0.31, green: 0.65, blue: 0.40)
    static let leaf = Color(red: 0.57, green: 0.83, blue: 0.51)
    static let flowerCenter = Color(red: 0.22, green: 0.14, blue: 0.13)
    static let rose = Color(red: 0.98, green: 0.42, blue: 0.56)
    static let roseShadow = Color(red: 0.57, green: 0.19, blue: 0.31)
    static let honey = Color(red: 1.0, green: 0.77, blue: 0.38)
    static let coral = Color(red: 1.0, green: 0.47, blue: 0.35)
}

// MARK: - Time without updates

/// How a figure keeps time between the app's updates.
enum IslandClock: Equatable {
    /// The real island: timer texts in the gate fonts switch parts of the drawing on and off.
    /// Works with no updates at all, so a heart can beat while Zone only waits.
    case gates
    /// Reduce Motion, or anywhere a moving drawing would be wrong.
    case still
    /// The gallery in Settings, where a timeline supplies the seconds.
    case timeline(TimeInterval)
}

/// A mask that is solid during one window of every period and empty otherwise, with no
/// updates from the app and no animation API.
///
/// A Live Activity cannot run a timeline, but `Text(date, style: .timer)` ticks by itself. In
/// the gate fonts (`scripts/make-island-gate-fonts.py`) a digit is a solid square or nothing,
/// so a timer's last digit is a mask that is on for whole seconds. Two of them a fraction of a
/// second apart overlap for exactly that fraction: a blink, a heartbeat. Public API only. The
/// technique is Bryce Bostwick's (github.com/brycebostwick/WidgetAnimation).
///
/// The fonts are registered only in the widget extension (`UIAppFonts`). Without them the
/// timer would draw as system digits, so nothing outside the extension may use `.gates`.
struct IslandGate: View {
    enum Period: String {
        /// On in even seconds: a window every 2 s.
        case two = "ZoneGateEven-Regular"
        /// On in seconds ending in 0: a window every 10 s.
        case ten = "ZoneGateOne-Regular"
    }

    let period: Period
    /// Seconds into the period at which the window opens, and how long it stays open (under 1 s).
    let start: Double
    let length: Double
    /// A coasting sprite freezes its clocks on its final pose.
    var endsAt: Date? = nil

    var body: some View {
        // One reference for both timers. A whole number of periods ago, and recent, so the
        // timer never grows past "h:mm:ss" while a card lives (8 hours at most).
        let now = Date().timeIntervalSinceReferenceDate
        let reference = Date(timeIntervalSinceReferenceDate: (now / 10).rounded(.down) * 10 - 60)
        // The first timer turns on at `start`; the second, already on, turns off `length` later.
        blinker(reference.addingTimeInterval(start))
            .mask(blinker(reference.addingTimeInterval(start + length - 1)))
            .accessibilityHidden(true)
    }

    private func blinker(_ date: Date) -> some View {
        GeometryReader { geometry in
            let side = max(geometry.size.width, geometry.size.height)
            // Room for nine characters, right-aligned, then shifted so the last one (the
            // seconds' final digit) fills this view. Every glyph is one em wide.
            let timer = endsAt.map {
                Text(timerInterval: date...max(date, $0), countsDown: false, showsHours: false)
            } ?? Text(date, style: .timer)
            timer
                .font(.custom(period.rawValue, fixedSize: side))
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .frame(width: side * 9, height: side, alignment: .trailing)
                .offset(x: -side * 8)
        }
        .clipped()
        // ASCII digits whatever the phone's numerals: the fonts have no others.
        .environment(\.locale, Locale(identifier: "en_US_POSIX"))
    }
}

extension View {
    /// Shows this view only inside the given windows, each `(start, length)` in seconds.
    func islandGated(_ period: IslandGate.Period, windows: [(Double, Double)]) -> some View {
        mask(ZStack {
            ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                IslandGate(period: period, start: window.0, length: window.1)
            }
        })
    }
}

// MARK: - Pulse: a heart and its trace

struct HeartShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + w * 0.5, y: rect.minY + h * 0.96))
        path.addCurve(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.32),
                      control1: CGPoint(x: rect.minX + w * 0.18, y: rect.minY + h * 0.74),
                      control2: CGPoint(x: rect.minX, y: rect.minY + h * 0.56))
        path.addArc(center: CGPoint(x: rect.minX + w * 0.25, y: rect.minY + h * 0.29), radius: w * 0.25,
                    startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        path.addArc(center: CGPoint(x: rect.minX + w * 0.75, y: rect.minY + h * 0.29), radius: w * 0.25,
                    startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        path.addCurve(to: CGPoint(x: rect.minX + w * 0.5, y: rect.minY + h * 0.96),
                      control1: CGPoint(x: rect.maxX, y: rect.minY + h * 0.56),
                      control2: CGPoint(x: rect.minX + w * 0.82, y: rect.minY + h * 0.74))
        path.closeSubpath()
        return path
    }
}

/// The heart. It beats by a clock, not by updates: once every two seconds at rest, and a
/// quicker lub-dub every second while Zone records.
struct BeatingHeart: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tint: Color
    var size: CGFloat = 12
    /// Recording: the quicker double beat.
    var quick = false
    /// Dimmed and still: an interruption has the microphone, or Zone stopped.
    var quiet = false
    var clock: IslandClock = .gates

    /// The heart at rest is a little smaller than the beat, so a beat is a swell.
    static let rest: CGFloat = 0.8
    /// Where in each second the two halves of a beat fall, and how long each lasts.
    static let lub = (0.0, 0.16), dub = (0.3, 0.13)

    var body: some View {
        ZStack {
            switch quiet || reduceMotion ? .still : clock {
            case .still:
                heart.scaleEffect(0.9)
            case .timeline(let t):
                heart.scaleEffect(Self.scale(at: t, quick: quick))
            case .gates:
                heart.scaleEffect(Self.rest)
                if quick {
                    // Every second: the same two windows in the even and the odd one.
                    heart.islandGated(.two, windows: [Self.lub, Self.dub, (1 + Self.lub.0, Self.lub.1), (1 + Self.dub.0, Self.dub.1)])
                } else {
                    heart.islandGated(.two, windows: [(0, 0.22)])
                }
            }
        }
        .frame(width: size, height: size)
        .opacity(quiet ? 0.45 : 1)
        .accessibilityHidden(true)
    }

    private var heart: some View { HeartShape().fill(IslandPigment.rose.mix(with: tint, by: 0.15)).frame(width: size, height: size) }

    /// The gallery's version of the same beat.
    static func scale(at t: TimeInterval, quick: Bool) -> CGFloat {
        if quick {
            let s = t - t.rounded(.down)
            return (s < lub.1) || (s >= dub.0 && s < dub.0 + dub.1) ? 1 : rest
        }
        let s = t.truncatingRemainder(dividingBy: 2)
        return s < 0.22 ? 1 : rest
    }
}

/// A heart monitor's trace: a flat line with one beat on it. The beat's height follows the
/// voice and its place moves along with each update.
struct PulseLine: Shape {
    /// Where the beat sits, 0 leading to 1 trailing.
    var position: Double
    /// The beat's height, 0 a flat line to 1.
    var amplitude: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(position, amplitude) }
        set { position = newValue.first; amplitude = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let amp = CGFloat(max(0, min(1, amplitude))) * rect.height / 2
        let beat = rect.width * 0.46
        let x0 = rect.minX + (rect.width - beat) * CGFloat(max(0, min(1, position)))
        let y = rect.midY
        func point(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { CGPoint(x: x0 + beat * fx, y: y - amp * fy) }
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: y))
        path.addLine(to: point(0, 0))
        // P, a small rise; then Q down, R up, S down; then T.
        path.addQuadCurve(to: point(0.2, 0), control: point(0.1, 0.28))
        path.addLine(to: point(0.3, 0))
        path.addLine(to: point(0.37, -0.3))
        path.addLine(to: point(0.46, 1))
        path.addLine(to: point(0.56, -0.62))
        path.addLine(to: point(0.63, 0))
        path.addLine(to: point(0.72, 0))
        path.addQuadCurve(to: point(0.94, 0), control: point(0.83, 0.42))
        path.addLine(to: CGPoint(x: rect.maxX, y: y))
        return path
    }
}

struct PulseFigure: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let mood: IslandMood
    let tint: Color
    var size = CGSize(width: 38, height: 16)
    var heart: CGFloat = 11
    var clock: IslandClock = .gates

    private var amplitude: Double {
        switch mood.kind {
        case .listening: 0.3 + 0.7 * mood.level
        case .thinking: 0.5
        case .happy: 0.8
        case .asleep: 0.22
        case .paused, .away, .lost: 0
        }
    }

    /// The beat walks along the line while recording, and rests in the middle otherwise.
    private var position: Double {
        mood.kind == .listening ? [0.1, 0.5, 0.9, 0.5][mood.beat % 4] : 0.5
    }

    var body: some View {
        HStack(spacing: size.height * 0.18) {
            BeatingHeart(tint: tint, size: heart, quick: mood.kind == .listening || mood.kind == .thinking,
                         quiet: mood.kind == .away || mood.kind == .lost || mood.kind == .paused, clock: clock)
            PulseLine(position: position, amplitude: amplitude)
                .stroke(tint, style: StrokeStyle(lineWidth: max(1.2, size.height * 0.085), lineCap: .round, lineJoin: .round))
                .frame(width: max(0, size.width - heart - size.height * 0.18), height: size.height)
                .opacity(mood.kind == .away || mood.kind == .lost ? 0.45 : 1)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.9), value: mood)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Drift: petals on the wind

/// A handful of petals in one shape, so the whole drift animates from three numbers. Each
/// petal's path across the field comes from `phase`; when it leaves one side it enters at the
/// other, and because the wrap happens inside the path, nothing ever flies back across.
struct PetalsShape: Shape {
    /// Advances by one with each update while Zone records.
    var phase: Double
    /// 0 still air to 1: faster, higher and wilder.
    var wind: Double
    /// 0 in the air to 1 fallen to the floor.
    var settle: Double
    var count = 4
    /// Which set of petals this is: a second layer drifts differently behind the first.
    var layer = 0
    var fold = false

    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { AnimatablePair(phase, AnimatablePair(wind, settle)) }
        set { phase = newValue.first; wind = newValue.second.first; settle = newValue.second.second }
    }

    /// A steady number in 0..<1 for petal `i`, different for each `salt`.
    static func seed(_ i: Int, _ salt: Int) -> Double {
        let x = sin(Double(i) * 12.9898 + Double(salt) * 78.233) * 43758.5453
        return x - x.rounded(.down)
    }

    /// Where petal `i` is: x and y in 0...1 of the field, its turn in radians and its size as a
    /// share of the field's height.
    func petal(_ i: Int) -> (x: Double, y: Double, turn: Double, size: Double) {
        let a = Self.seed(i, layer * 3), b = Self.seed(i, layer * 3 + 1), c = Self.seed(i, layer * 3 + 2)
        let wind = max(0, min(1, wind)), settle = max(0, min(1, settle))
        let travelled = a + phase * (0.018 + 0.012 * b)
        let x = travelled - travelled.rounded(.down)
        let air = 0.48 + (0.16 + 0.2 * wind) * sin(phase * (0.16 + 0.10 * c) + a * 6.283)
        let floor = 0.84 - 0.05 * b
        let flying = 0.15 + 0.19 * sin(phase * 0.18 + a * 6.283)
        let resting = (b - 0.5) * 0.7
        return (x, air + (floor - air) * settle, flying + (resting - flying) * settle, 0.3 + 0.16 * c)
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for i in 0..<count {
            let petal = petal(i)
            let length = rect.height * CGFloat(petal.size), width = length * 0.52
            // An almond with one pointed end, drawn around the origin, then turned and placed.
            var one = Path()
            one.move(to: CGPoint(x: -length / 2, y: 0))
            one.addQuadCurve(to: CGPoint(x: length / 2, y: 0), control: CGPoint(x: 0, y: -width))
            one.addQuadCurve(to: CGPoint(x: -length / 2, y: 0), control: CGPoint(x: length * 0.1, y: fold ? -width * 0.18 : width * 0.7))
            let place = CGAffineTransform(translationX: rect.minX + rect.width * CGFloat(petal.x),
                                          y: rect.minY + rect.height * CGFloat(petal.y))
                .rotated(by: CGFloat(petal.turn))
            path.addPath(one, transform: place)
        }
        return path
    }
}

/// A side view of a blossom. A dark outer cup holds two lit, folded petals.
private struct BlossomCup: View {
    let tint: Color
    let night: Bool

    var body: some View {
        ZStack {
            CupPetal(tip: CGPoint(x: night ? 0.49 : 0.67, y: 0.06),
                     back: CGPoint(x: 0.13, y: 0.43), front: CGPoint(x: 0.84, y: 0.49))
                .fill(LinearGradient(colors: [tint.mix(with: .white, by: 0.6), tint],
                                     startPoint: .top, endPoint: .bottom))
            CupPetal(tip: CGPoint(x: night ? 0.37 : 0.04, y: night ? 0.22 : 0.32),
                     back: CGPoint(x: 0.10, y: 0.80), front: CGPoint(x: 0.54, y: 0.35))
                .fill(tint.mix(with: IslandPigment.flowerCenter, by: 0.43))
            CupPetal(tip: CGPoint(x: night ? 0.65 : 0.98, y: 0.41),
                     back: CGPoint(x: 0.62, y: 0.48), front: CGPoint(x: 0.83, y: 0.99))
                .fill(LinearGradient(colors: [tint.mix(with: .white, by: 0.38), tint],
                                     startPoint: .topTrailing, endPoint: .bottomLeading))
            Ellipse().fill(IslandPigment.flowerCenter)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(x: 0.16, y: 0.11)
            CupPetal(tip: CGPoint(x: 0.03, y: 0.62),
                     back: CGPoint(x: 0.09, y: 1.0), front: CGPoint(x: 0.24, y: 0.64))
                .fill(IslandPigment.leaf)
        }
    }
}

private struct CupPetal: Shape {
    let tip: CGPoint
    let back: CGPoint
    let front: CGPoint

    func path(in rect: CGRect) -> Path {
        let base = CGPoint(x: 0.40, y: 0.94)
        var path = Path()
        path.move(to: base)
        path.addQuadCurve(to: tip, control: back)
        path.addQuadCurve(to: base, control: front)
        path.closeSubpath()
        return path.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width, y: rect.height))
    }
}

struct DriftFigure: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let mood: IslandMood
    let tint: Color
    var size = CGSize(width: 36, height: 18)
    /// Petals in the near layer; the far layer has one fewer.
    var count = 3

    private var settle: Double {
        switch mood.kind {
        case .listening, .happy: 0
        case .thinking: 0.45
        case .asleep, .paused, .away, .lost: 1
        }
    }
    private var wind: Double {
        switch mood.kind {
        case .listening: 0.25 + 0.75 * mood.energy
        case .happy: 0.9
        default: 0.15
        }
    }

    var body: some View {
        let phase = Double(mood.beat)
        HStack(alignment: .center, spacing: 0) {
            BlossomCup(tint: tint, night: mood.night)
                .frame(width: min(size.width * 0.38, size.height * 0.88), height: size.height * 0.88)
            ZStack {
                PetalsShape(phase: phase * 0.8, wind: wind, settle: settle, count: max(1, count - 1), layer: 1)
                    .fill(tint.opacity(0.38))
                PetalsShape(phase: phase, wind: wind, settle: settle, count: count, layer: 0)
                    .fill(tint.opacity(0.76))
                PetalsShape(phase: phase, wind: wind, settle: settle, count: count, layer: 0, fold: true)
                    .fill(tint.mix(with: .white, by: 0.32))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .opacity(mood.kind == .away || mood.kind == .lost ? 0.45 : 1)
        // Linear while it flies, so one update's glide joins the next into a steady drift. A
        // petal falling eases out, the way one lands.
        .animation(reduceMotion ? nil : (mood.kind == .listening ? .linear(duration: 1.05) : .easeOut(duration: 1.4)),
                   value: mood)
        .accessibilityHidden(true)
    }
}

// MARK: - The blink

/// A shut eye drawn over an open one for a fifth of a second in every ten: a slow blink while
/// Zone waits, with no update behind it. Between cats a slow blink means all is well.
struct IslandBlink<Lid: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder var lid: () -> Lid

    var body: some View {
        if !reduceMotion {
            lid().islandGated(.ten, windows: [(0, 0.2)])
        }
    }
}

/// A rose in side view. The stem stays anchored while the overlapping petals open.
struct RoseFigure: View {
    let mood: IslandMood
    let height: CGFloat

    var body: some View {
        let bloom = mood.kind == .happy ? 1.0 : 0.40 + 0.60 * mood.growth
        ZStack {
            Path { stem in
                stem.move(to: CGPoint(x: 0.45, y: 0.96))
                stem.addQuadCurve(to: CGPoint(x: 0.50, y: 0.43), control: CGPoint(x: 0.58, y: 0.75))
            }
            .transform(CGAffineTransform(scaleX: height, y: height))
            .stroke(IslandPigment.stem, style: StrokeStyle(lineWidth: height * 0.07, lineCap: .round))

            Path { leaf in
                leaf.move(to: CGPoint(x: 0.49, y: 0.81))
                leaf.addQuadCurve(to: CGPoint(x: 0.12, y: 0.62), control: CGPoint(x: 0.20, y: 0.87))
                leaf.addQuadCurve(to: CGPoint(x: 0.49, y: 0.81), control: CGPoint(x: 0.42, y: 0.61))
                leaf.closeSubpath()
            }
            .transform(CGAffineTransform(scaleX: height, y: height))
            .fill(IslandPigment.leaf)

            ZStack {
                ForEach(0..<3) { petal in
                    Ellipse()
                        .fill(IslandPigment.roseShadow.mix(with: IslandPigment.rose,
                                                           by: 0.28 + 0.31 * Double(petal)))
                        .frame(width: height * 0.31, height: height * 0.42)
                        .rotationEffect(.degrees(Double(petal - 1) * 35 * bloom), anchor: .bottom)
                }
                Path { fold in
                    fold.move(to: CGPoint(x: 0.33, y: 0.17))
                    fold.addQuadCurve(to: CGPoint(x: 0.59, y: 0.28), control: CGPoint(x: 0.47, y: 0.38))
                    fold.addQuadCurve(to: CGPoint(x: 0.48, y: 0.20), control: CGPoint(x: 0.63, y: 0.19))
                }
                .transform(CGAffineTransform(scaleX: height, y: height))
                .stroke(IslandPigment.flowerCenter, style: StrokeStyle(lineWidth: height * 0.07, lineCap: .round))
            }
            .frame(width: height, height: height * 0.53)
            .position(x: height / 2, y: height * 0.28)
        }
        .frame(width: height, height: height)
    }
}

/// A stepped level display. Each column is an actual microphone sample, oldest at left.
struct SynthFigure: View {
    static let columnCount = 7
    let mood: IslandMood
    let tint: Color
    let height: CGFloat

    var body: some View {
        HStack(alignment: .bottom, spacing: height * 0.052) {
            ForEach(0..<Self.columnCount, id: \.self) { index in
                let offset = index - (Self.columnCount - mood.synthLevels.count)
                let unit = mood.awake && mood.synthLevels.indices.contains(offset)
                    ? IslandLevels.unit(mood.synthLevels[offset]) : 0
                let illuminated = 1 + Int((unit * 4).rounded())
                VStack(spacing: height * 0.05) {
                    ForEach((0..<5).reversed(), id: \.self) { step in
                        RoundedRectangle(cornerRadius: height * 0.025)
                            .fill(step < illuminated ? segmentColor(step) : Color(white: 0.19))
                    }
                }
            }
        }
        .frame(width: height * 1.5, height: height * 0.76)
    }

    private func segmentColor(_ step: Int) -> Color {
        switch step {
        case 0...1: IslandPigment.leaf
        case 2: tint
        case 3: IslandPigment.honey
        default: IslandPigment.coral
        }
    }

}

// MARK: - Orbit Cube and Pixel Sword

struct IslandRelic: View {
    let look: IslandLook
    let mood: IslandMood
    let tint: Color
    let height: CGFloat
    let clock: IslandClock
    var activitySnapshotsOnly = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion || clock == .still {
                sprite(0.095)
            } else if case .timeline(let time) = clock {
                // A repeating audition: two seconds at rest, a burst, then the mic lets go.
                let t = time.truncatingRemainder(dividingBy: 9)
                let epoch = Date(timeIntervalSinceReferenceDate: 0)
                let start = IslandSpin.resting(at: epoch).retarget(0.57, at: epoch.addingTimeInterval(1.5))
                let spin = t < 5.7 ? start : start.retarget(0, at: epoch.addingTimeInterval(5.7))
                sprite(spin.sample(at: epoch.addingTimeInterval(t)).turns)
            } else if let spin = mood.spin {
                let now = Date()
                if activitySnapshotsOnly {
                    let date = spin.target == 0 ? max(now, spin.at.addingTimeInterval(2)) : now
                    sprite(spin.sample(at: date).turns)
                } else if spin.target == 0 && spin.sample(at: now).speed < 0.01 {
                    sprite(spin.sample(at: now.addingTimeInterval(2)).turns)
                } else {
                    let step = 2.0 / Double(frames)
                    let stamp = now.timeIntervalSinceReferenceDate
                    // Snap to the current slot. The system clocks change the visible drawing
                    // between activity updates, with no display link in the app or widget.
                    let first = Int(floor(stamp / step))
                    let last = Double(first + frames - 1)
                    let end = spin.target == 0 ? Date(timeIntervalSinceReferenceDate: (last + 0.5) * step) : nil
                    ZStack {
                        // A complete pose stays visible when SpringBoard pauses its timer masks.
                        widgetFrame(spin.sample(at: now).turns)
                        ForEach(0..<frames, id: \.self) { offset in
                            let slot = first + offset
                            let date = Date(timeIntervalSinceReferenceDate: Double(slot) * step)
                            widgetFrame(spin.sample(at: date).turns)
                                .background(Color.black)
                                .mask {
                                    IslandGate(period: .two, start: Double(slot % frames) * step,
                                               length: step, endsAt: end)
                                }
                        }
                    }
                }
            } else {
                sprite(0.095)
            }
        }
        .frame(width: height * 1.12, height: height)
        // The timer masks already turn the object. A second crossfade between
        // level updates would briefly show two different outlines.
        .contentTransition(.identity)
        .animation(nil, value: mood.spin)
        .accessibilityHidden(true)
    }

    private var frames: Int { height >= 28 ? 24 : 8 }

    /// WidgetKit archives every gated pose. Each pose is only a few dozen pixels;
    /// a single transparent image keeps the system from archiving each metal edge separately.
    @ViewBuilder private func widgetFrame(_ turns: Double) -> some View {
        if let image = frameImage(turns) {
            Image(decorative: image, scale: 3).interpolation(.none)
        } else {
            sprite(turns)
        }
    }

    private func frameImage(_ turns: Double) -> CGImage? {
        let rect = CGRect(x: 0, y: 0, width: height * 1.12, height: height)
        let scale: CGFloat = 3
        let pixelsHigh = Int(ceil(rect.height * scale))
        guard let cg = CGContext(data: nil, width: Int(ceil(rect.width * scale)), height: pixelsHigh,
                                 bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        cg.translateBy(x: 0, y: CGFloat(pixelsHigh))
        cg.scaleBy(x: scale, y: -scale)
        let angle = turns * 2 * .pi
        cg.translateBy(x: 0, y: sin(angle * 1.5) * height * 0.055)
        let colors = look == .cube ? (0..<3).map(cubeInk) : SwordPixels.colors
        let environment = EnvironmentValues()
        for (layer, color) in colors.enumerated() {
            let path = look == .cube ? CubeStencil(turn: angle, face: layer).path(in: rect)
                                     : SwordPixels(layer: layer, turn: angle).path(in: rect)
            cg.setFillColor(color.resolve(in: environment).cgColor)
            cg.addPath(path.cgPath)
            cg.drawPath(using: look == .cube ? .eoFill : .fill)
        }
        return cg.makeImage()
    }

    private func sprite(_ turns: Double) -> some View {
        let angle = turns * 2 * .pi
        return ZStack {
            if look == .cube {
                ForEach(0..<3, id: \.self) { face in
                    CubeStencil(turn: angle, face: face)
                        .fill(cubeInk(face), style: FillStyle(eoFill: true))
                }
            } else {
                ForEach(0..<SwordPixels.colors.count, id: \.self) { layer in
                    SwordPixels(layer: layer, turn: angle)
                        .fill(SwordPixels.colors[layer])
                }
            }
        }
        .offset(y: sin(angle * 1.5) * height * 0.055)
    }

    private func cubeInk(_ face: Int) -> Color {
        switch face {
        case 0: tint.mix(with: .white, by: 0.55)
        case 1: tint
        default: tint.mix(with: Color(white: 0.08), by: 0.45)
        }
    }
}

/// Project the lit top and the two camera-facing sides. Each face has a real hole;
/// the three folded rims read as a hollow object at the island's native size.
private struct CubeStencil: Shape {
    let turn: Double
    let face: Int

    func path(in rect: CGRect) -> Path {
        let c = cos(turn), s = sin(turn)
        let sx = s >= 0 ? -1.0 : 1.0
        let sz = c >= 0 ? 1.0 : -1.0
        func project(_ u: Double, _ v: Double) -> CGPoint {
            let x: Double, y: Double, z: Double
            switch face {
            case 0: (x, y, z) = (u, 1, v)
            case 1: (x, y, z) = (u, v, sz)
            default: (x, y, z) = (sx, v, u)
            }
            let across = x * c + z * s
            let depth = -x * s + z * c
            let unit = min(rect.width, rect.height) * 0.292
            return CGPoint(x: rect.midX + unit * across,
                           y: rect.midY - unit * (y * 0.88 - depth * 0.47))
        }
        var path = Path()
        for radius in [1.0, 0.63] {
            path.move(to: project(-radius, -radius))
            path.addLine(to: project(radius, -radius))
            path.addLine(to: project(radius, radius))
            path.addLine(to: project(-radius, radius))
            path.closeSubpath()
        }
        return path
    }
}

/// Hand-drawn sixteen-pixel blade. Steel planes, fuller, brass guard and leather grip
/// stay readable in profile; the bright edge changes sides as the blade banks.
private struct SwordPixels: Shape {
    static let colors = [Color(red: 0.23, green: 0.36, blue: 0.42),
                         Color(red: 0.47, green: 0.72, blue: 0.77),
                         Color(red: 0.89, green: 0.96, blue: 0.90),
                         IslandPigment.honey, Color(red: 0.60, green: 0.35, blue: 0.24)]
    private static let rows = [
        ".............cc.", "............bcc.", "...........bac..", "..........bac...",
        ".........bac....", "........bac.....", ".......bac......", "....d.bac.......",
        "....ddac........", ".....dd.........", "....eddd........", "...ee..dd.......",
        "..ee....d.......", ".de.............", ".dd.............", "................"
    ]
    let layer: Int
    let turn: Double

    func path(in rect: CGRect) -> Path {
        let marks: [Character] = ["a", "b", "c", "d", "e"]
        let edge = sin(turn) < -0.25
        let mark = marks[edge && layer == 1 ? 2 : edge && layer == 2 ? 1 : layer]
        let dot = min(rect.width, rect.height) / 17
        var pixels = Path()
        for (y, row) in Self.rows.enumerated() {
            for (x, cell) in row.enumerated() where cell == mark {
                pixels.addRect(CGRect(x: Double(x) - 7.5, y: Double(y) - 7.5, width: 1, height: 1))
            }
        }
        let bank = sin(turn) * 0.23
        let breadth = 0.82 + 0.18 * cos(turn)
        return pixels.applying(CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .rotated(by: bank).scaledBy(x: dot * breadth, y: dot))
    }
}
