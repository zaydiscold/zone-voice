// by zayd/cold @ zayd.wtf

import SwiftUI
import UIKit
import ZoneCore

struct MeetingEdge: View {
    static let frameInterval = 1.0 / 30
    // The capture engine maps dBFS to a display value before it sends meter levels.
    static let roomFloor: Float = {
        var scale = AdaptiveLevelScale()
        return scale.map(decibels: -45, elapsed: 0.05)
    }()

    let levels: [Float]
    let active: Bool
    @AppStorage(MeetingWaveStyle.preferenceKey) private var choice = MeetingWaveStyle.defaultStyle.rawValue
    @Environment(\.colorScheme) private var scheme

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let style = MeetingWaveStyle(preference: choice)
        let muted = UIColor(Zone.muted(scheme))
        let border = active ? UIColor(Zone.accentTone(scheme == .dark ? .light : .dark)) : muted
        let inside = active ? UIColor(Zone.accentTone(scheme)) : muted
        let moves = active && !reduceMotion && scenePhase == .active && style != .glow
            && levels.suffix(MeetingWaveSignal.count).contains { $0 > Self.roomFloor }
        TimelineView(.animation(minimumInterval: Self.frameInterval, paused: !moves)) { clock in
            EdgeEqualizer(levels: levels, color: border, innerColor: inside, active: active, style: style,
                          reduceMotion: reduceMotion, time: clock.date.timeIntervalSinceReferenceDate)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct EdgeEqualizer: UIViewRepresentable {
    let levels: [Float]
    let color: UIColor
    let innerColor: UIColor
    let active: Bool
    let style: MeetingWaveStyle
    let reduceMotion: Bool
    let time: TimeInterval

    func makeUIView(context: Context) -> EdgeView { EdgeView() }
    func updateUIView(_ view: EdgeView, context: Context) {
        view.update(levels: levels, color: color, innerColor: innerColor, active: active, style: style, reduceMotion: reduceMotion, time: time)
    }

    final class EdgeView: UIView {
        private struct Stop {
            let point: CGPoint
            let normal: CGVector
            let turn: Double
            let age: Double
        }

        private var stops: [Stop] = []
        private var inner = [CGPoint](repeating: .zero, count: 320)
        private var outer = [CGPoint](repeating: .zero, count: 320)
        private let lines = (0..<4).map { _ in CAShapeLayer() }
        private var signal = MeetingWaveSignal([])
        private var levels: [Float] = []
        private var lastArrival = 0.0
        private var color = UIColor.clear
        private var innerColor = UIColor.clear
        private let tones = CALayer()
        private let strands = CALayer()
        private var paletteRadius: CGFloat?
        private var active = false
        private var reduceMotion = false
        private var style = MeetingWaveStyle.weave
        private(set) var time = 0.0
        private var reach = 48.0
        private var scale = 1.0
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            layer.addSublayer(tones)
            tones.mask = strands
            for line in lines {
                line.fillRule = .evenOdd
                line.lineJoin = .round
                line.actions = ["path": NSNull(), "lineWidth": NSNull(), "opacity": NSNull(),
                                "fillColor": NSNull(), "hidden": NSNull()]
                strands.addSublayer(line)
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func update(levels: [Float], color: UIColor, innerColor: UIColor? = nil, active: Bool, style: MeetingWaveStyle, reduceMotion: Bool,
                    time: TimeInterval = 0) {
            let tail = levels.suffix(MeetingWaveSignal.count)
            let changed = !self.levels.elementsEqual(tail)
            let innerColor = innerColor ?? color
            let newPalette = color != self.color || innerColor != self.innerColor
            let newStyle = self.style != style
            self.time = time
            if changed {
                self.levels = Array(tail)
                signal = MeetingWaveSignal(self.levels)
                lastArrival = time
            }
            self.active = active
            self.style = style
            self.reduceMotion = reduceMotion
            self.color = color
            self.innerColor = innerColor
            if newPalette { paletteRadius = nil; setNeedsLayout() }
            if newStyle || newPalette {
                for (index, line) in lines.enumerated() { line.isHidden = index >= style.strands }
            }
            tick()
        }

        /// Stretch the straight edges of this small rounded swatch. Only layout and an
        /// accent change rebuild it. The live strands supply the glow through their opacity.
        private func applyPalette(radius: CGFloat) {
            guard paletteRadius != radius, radius > 0 else { return }
            paletteRadius = radius
            let cap = ceil(radius)
            let side = cap * 2 + 1
            let bounds = CGRect(x: 0, y: 0, width: side, height: side)
            let renderer = UIGraphicsImageRenderer(size: bounds.size)
            let image = renderer.image { renderer in
                let ctx = renderer.cgContext
                let space = CGColorSpace(name: CGColorSpace.sRGB)!
                guard let gradient = CGGradient(colorsSpace: space, colors: [color.cgColor, innerColor.cgColor] as CFArray,
                                                locations: [0, 1]) else { return }
                ctx.setFillColor(innerColor.cgColor)
                ctx.fill(bounds)
                // Each edge and quarter circle measures depth inward from the same perimeter.
                for (x, y) in [(CGFloat.zero, CGFloat.zero), (side, 0), (0, side), (side, side)] {
                    let sx: CGFloat = x == 0 ? 1 : -1, sy: CGFloat = y == 0 ? 1 : -1
                    ctx.saveGState()
                    ctx.translateBy(x: x, y: y)
                    ctx.scaleBy(x: sx, y: sy)
                    let center = CGPoint(x: radius, y: radius)
                    ctx.saveGState()
                    ctx.clip(to: CGRect(x: 0, y: 0, width: radius, height: radius))
                    ctx.drawRadialGradient(gradient, startCenter: center, startRadius: radius, endCenter: center,
                                           endRadius: max(0, radius - reach), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                    ctx.restoreGState()
                    ctx.saveGState()
                    ctx.clip(to: CGRect(x: radius, y: 0, width: side / 2 - radius, height: radius))
                    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: reach), options: [.drawsAfterEndLocation])
                    ctx.restoreGState()
                    ctx.clip(to: CGRect(x: 0, y: radius, width: radius, height: side / 2 - radius))
                    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: reach, y: 0), options: [.drawsAfterEndLocation])
                    ctx.restoreGState()
                }
            }
            tones.contents = image.cgImage
            tones.contentsScale = image.scale
            tones.contentsCenter = CGRect(x: cap / side, y: cap / side, width: 1 / side, height: 1 / side)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            setNeedsLayout()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            setNeedsLayout()
        }

        static func borderRadius(for size: CGSize, bottomInset: CGFloat) -> CGFloat {
            let width = min(size.width, size.height)
            let base: CGFloat = bottomInset > 0 ? 56 : 16
            return min(base * width / 393, width / 2)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard !bounds.isEmpty else { stops = []; return }
            scale = min(bounds.width, bounds.height) / 393
            let radius = Self.borderRadius(for: bounds.size, bottomInset: window?.safeAreaInsets.bottom ?? 0)
            reach = 0.87 * radius
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            tones.frame = bounds
            strands.frame = tones.bounds
            applyPalette(radius: radius)
            CATransaction.commit()
            let perimeter = Perimeter(rect: bounds, radius: radius)
            let count = inner.count
            stops = (0..<count).map { index in
                let turn = Double(index) / Double(count)
                let (point, normal) = perimeter.point(at: turn)
                let age = min(turn, 1 - turn) * 2
                return Stop(point: point, normal: normal, turn: turn, age: age * age * (3 - 2 * age))
            }
            tick()
        }

        private func tick() {
            drawFrame(phase: time.truncatingRemainder(dividingBy: 2 * .pi / 1.3) * 1.3,
                      fraction: min(1, max(0, (time - lastArrival) * 20)))
        }

        /// One fixed perimeter for each strand. The only history read per point is one
        /// interpolation between two neighbors. Static modes change ink density alone.
        func drawFrame(phase: Double, fraction: Double) {
            guard !stops.isEmpty else { return }
            let still = reduceMotion || style == .glow
            let energy = active ? signal.loudness : 0
            for i in 0..<style.strands {
                let path = CGMutablePath()
                let weight: Double = style == .tide && i == 0 ? 3.2 : style == .braid ? 1.4 : 2.0
                for (index, stop) in stops.enumerated() {
                    let local = signal.level(age: stop.age, fraction: fraction)
                    let level = style == .breath ? energy : 0.82 * local + 0.18 * energy
                    var inset = 2.6 * scale
                    if active && still {
                        inset += scale * Double(i) * 2
                    } else if active {
                        let arc = style.reach(turn: stop.turn, strand: i, phase: phase)
                        let profile = style == .flow ? 0.48 + 0.52 * arc : arc
                        inset += reach * level * profile
                    }
                    // A syllable widens its own part of the ribbon as it travels.
                    let width = still ? 1.5 : 1.1 + weight * level + 0.65 * energy
                    let half = active ? width * scale / 2 : 0.55 * scale
                    let dx = stop.normal.dx, dy = stop.normal.dy
                    inner[index] = CGPoint(x: stop.point.x + dx * (inset + half), y: stop.point.y + dy * (inset + half))
                    outer[index] = CGPoint(x: stop.point.x + dx * (inset - half), y: stop.point.y + dy * (inset - half))
                }
                path.addLines(between: inner)
                path.closeSubpath()
                path.addLines(between: outer)
                path.closeSubpath()
                lines[i].path = path
                lines[i].opacity = Float((active ? 0.43 : 0.17) + 0.41 * energy + 0.055 * Double(i))
            }
        }
    }
}

/// A rounded rectangle walked from its bottom center, counterclockwise on screen (right, up,
/// left, down), with the inward normal at each point.
private struct Perimeter {
    let rect: CGRect
    let radius: CGFloat
    let length: CGFloat
    private let straightX: CGFloat
    private let straightY: CGFloat
    private let arc: CGFloat

    init(rect: CGRect, radius: CGFloat) {
        self.rect = rect
        let r = min(radius, rect.width / 2, rect.height / 2)
        self.radius = r
        straightX = rect.width - 2 * r
        straightY = rect.height - 2 * r
        arc = .pi * r / 2
        length = 2 * straightX + 2 * straightY + 4 * arc
    }

    func point(at fraction: CGFloat) -> (CGPoint, CGVector) {
        var d = (fraction.truncatingRemainder(dividingBy: 1)) * length
        let r = radius
        let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        // Bottom edge, center to the right corner.
        if d <= straightX / 2 { return (CGPoint(x: rect.midX + d, y: maxY), CGVector(dx: 0, dy: -1)) }
        d -= straightX / 2
        if d <= arc { return corner(center: CGPoint(x: maxX - r, y: maxY - r), from: .pi / 2, by: -d / max(r, 0.001)) }
        d -= arc
        if d <= straightY { return (CGPoint(x: maxX, y: maxY - r - d), CGVector(dx: -1, dy: 0)) }
        d -= straightY
        if d <= arc { return corner(center: CGPoint(x: maxX - r, y: minY + r), from: 0, by: -d / max(r, 0.001)) }
        d -= arc
        if d <= straightX { return (CGPoint(x: maxX - r - d, y: minY), CGVector(dx: 0, dy: 1)) }
        d -= straightX
        if d <= arc { return corner(center: CGPoint(x: minX + r, y: minY + r), from: -.pi / 2, by: -d / max(r, 0.001)) }
        d -= arc
        if d <= straightY { return (CGPoint(x: minX, y: minY + r + d), CGVector(dx: 1, dy: 0)) }
        d -= straightY
        if d <= arc { return corner(center: CGPoint(x: minX + r, y: maxY - r), from: -.pi, by: -d / max(r, 0.001)) }
        d -= arc
        return (CGPoint(x: minX + r + d, y: maxY), CGVector(dx: 0, dy: -1))
    }

    /// A point on a corner arc, `from` an angle (screen coordinates, y down) turning by `by`.
    private func corner(center: CGPoint, from: CGFloat, by: CGFloat) -> (CGPoint, CGVector) {
        let angle = from + by
        let outward = CGVector(dx: cos(angle), dy: sin(angle))
        let point = CGPoint(x: center.x + outward.dx * radius, y: center.y + outward.dy * radius)
        return (point, CGVector(dx: -outward.dx, dy: -outward.dy))
    }
}
