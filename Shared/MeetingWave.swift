// by zayd/cold @ zayd.wtf

import SwiftUI

enum MeetingWaveStyle: String, CaseIterable, Identifiable {
    case weave, tide, braid, flow, breath, glow
    static let preferenceKey = "meetingWaveformStyle"
    static let defaultStyle = Self.weave

    init(preference: String?) {
        self = preference.flatMap(Self.init(rawValue:)) ?? .defaultStyle
    }
    var id: Self { self }
    var title: String {
        switch self {
        case .weave: "Weave"
        case .tide: "Tide"
        case .braid: "Braid"
        case .flow: "Flow"
        case .breath: "Breathe"
        case .glow: "Still glow"
        }
    }
    var detail: String {
        switch self {
        case .weave: "Three lines cross as voices rise and fall."
        case .tide: "Long, slow arcs open around each phrase."
        case .braid: "Four close strands twist around one another."
        case .flow: "Sound travels from the bottom edge to the top."
        case .breath: "The whole border rises with your voice."
        case .glow: "A still border brightens as you speak."
        }
    }
    var strands: Int { self == .braid ? 4 : self == .glow ? 1 : 3 }
    var cycles: Double {
        switch self {
        case .tide: 3
        case .braid: 8
        default: 5
        }
    }
    /// Preserve the character of the full border in a narrow horizontal slice.
    func compactHeight(at x: Double, strand: Int, level: Double, still: Bool) -> Double {
        let taper = sin(.pi * x)
        if self == .glow { return 0.5 - 0.14 * taper }
        if still { return 0.5 + (Double(strand) - Double(strands - 1) / 2) * 0.15 }
        let arc = reach(turn: x * 0.4, strand: strand, phase: 0) - 0.5
        let travelling = self == .flow ? 0.35 + 0.65 * x : 1
        return 0.5 + arc * level * taper * travelling
    }

    /// A closed periodic curve. Different phase and reach bring each strand to the front in turn.
    func reach(turn: Double, strand: Int, phase: Double) -> Double {
        let angle = turn * 2 * Double.pi
        let offset = Double(strand) * 2 * Double.pi / Double(strands)
        let wave = sin(cycles * angle + offset + phase + 0.8 * sin(2 * angle - phase))
        return 0.51 + (0.40 - 0.035 * Double(strand)) * wave
    }
}

/// A bounded envelope, shared by the screen and the smaller frozen ActivityKit picture.
struct MeetingWaveSignal {
    static let count = 48
    let envelope: [Double]
    let loudness: Double

    init(_ samples: [Float]) {
        let tail = samples.suffix(Self.count)
        var history = Array(repeating: 0.0, count: Self.count - tail.count)
        var follower = 0.0
        for value in tail {
            let target = sqrt(Double(value.isFinite ? min(1, max(0, value)) : 0))
            follower += (target - follower) * (target > follower ? 0.53 : 0.28)
            history.append(follower)
        }
        envelope = history
        loudness = follower
    }

    func level(age: Double, fraction: Double) -> Double {
        let last = Self.count - 1
        let position = min(Double(last), max(0, (1 - age) * Double(last - 1) + fraction))
        let i = Int(position)
        let t = position - Double(i)
        return envelope[i] + (envelope[min(last, i + 1)] - envelope[i]) * t
    }
}

struct CompactMeetingWave: View {
    let style: MeetingWaveStyle
    let levels: [UInt8]?
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let signal = MeetingWaveSignal((levels ?? []).map { Float(IslandLevels.unit($0)) })
        Canvas { context, size in
            for strand in 0..<style.strands {
                var path = Path()
                for i in 0...48 {
                    let x = Double(i) / 48
                    let level = style == .breath ? signal.loudness : signal.level(age: 1 - x, fraction: 1)
                    let y = style.compactHeight(at: x, strand: strand, level: level, still: reduceMotion)
                    let point = CGPoint(x: x * size.width, y: y * size.height)
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                let alpha = 0.45 + 0.15 * Double(strand) + 0.15 * signal.loudness
                context.stroke(path, with: .color(tint.opacity(alpha)), lineWidth: reduceMotion ? 1.2 : 1 + 0.65 * signal.loudness)
            }
        }.accessibilityHidden(true)
    }
}
