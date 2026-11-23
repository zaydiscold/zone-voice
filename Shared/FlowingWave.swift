// by zayd/cold @ zayd.wtf

import SwiftUI
import UIKit

/// The voice as one wave flowing right to left: the newest sound enters at the right edge and
/// glides left as it ages, fading out. Samples arrive 20 times a second, but the wave scrolls
/// continuously on a display link (60 to 120 fps), so each sample keeps its height while it
/// slides; nothing jumps or wobbles between ticks. A smooth closed curve (Catmull-Rom through the
/// samples, mirrored about a center line) filled with a vertical depth gradient: pale at the
/// center line, deepening toward the top and bottom, so a louder moment reaches deeper color and
/// the wave reads as fading in and out as someone talks. One shape layer and a mask; the display
/// link runs only while live samples arrive. At rest it lies as a hairline. Reduce Motion stops
/// the scroll and redraws per sample.
struct FlowingWave: UIViewRepresentable {
    let levels: [Float]
    var color: UIColor = .systemPurple
    /// The accent's text tone for the host appearance, used only by the `edges` and `core`
    /// treatments. Callers pass `color` already suited to the surface: the accent on dark, its
    /// vivid graphic tone on light (the pale accent washes into a light backdrop).
    var ink: UIColor? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How the wave borrows darkness. `edges`: the depth gradient runs from the pale accent at
    /// the center line to the ink at the top and bottom. `core`: inverted, ink at the center line
    /// and the pale accent at the reaches. `halo`: the original pale gradient over a soft dark
    /// shadow of the same shape. `plain` is the original pale gradient alone.
    enum Shading: String, CaseIterable { case plain, edges, core, halo }
    #if DEBUG
    /// Screenshot fixtures switch this to compare treatments in one build.
    nonisolated(unsafe) static var debugShading: Shading?
    #endif
    /// `plain`: the same gradient on light and dark, in the tone the caller chose for the surface.
    /// Compared on a light keyboard in all five accents (2026-11-14): `edges` turned Ember brown
    /// and Mint grey; `plain` in the graphic tone kept every accent its own color.
    static let shading = Shading.plain

    func makeUIView(context: Context) -> WaveView { WaveView() }
    func updateUIView(_ view: WaveView, context: Context) {
        var shading = Self.shading
        #if DEBUG
        if let debug = Self.debugShading { shading = debug }
        #endif
        view.update(levels: levels, color: color, ink: ink ?? color, shading: shading, animated: !reduceMotion)
    }

    final class WaveView: UIView {
        /// Seconds between samples from the level channel.
        static let sampleInterval: CFTimeInterval = 0.05

        private let fill = CAShapeLayer()
        private let depth = CAGradientLayer()
        private let crest = CAShapeLayer()
        private let shade = CAShapeLayer()
        private let fade = CAGradientLayer()
        private let container = CALayer()
        private var samples: [Float] = []
        private var lastArrival: CFTimeInterval = 0
        private var lastColor: (UIColor, UIColor, Shading)?
        private var animated = true
        private var link: CADisplayLink?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            depth.startPoint = CGPoint(x: 0.5, y: 0)
            depth.endPoint = CGPoint(x: 0.5, y: 1)
            depth.locations = [0, 0.32, 0.5, 0.68, 1]
            fill.fillColor = UIColor.black.cgColor
            depth.mask = fill
            // The halo: the body's own shape, blurred and dark, under the color.
            shade.fillColor = UIColor.black.cgColor
            shade.shadowColor = UIColor.black.cgColor
            shade.shadowOffset = .zero
            shade.shadowRadius = 2.5
            shade.shadowOpacity = 0
            shade.opacity = 0
            container.addSublayer(shade)
            container.addSublayer(depth)
            container.addSublayer(crest)
            layer.addSublayer(container)
            crest.fillColor = nil
            crest.lineWidth = 1.25
            crest.lineCap = .round
            crest.lineJoin = .round
            // Older sound fades out completely toward the left edge.
            fade.startPoint = CGPoint(x: 0, y: 0.5)
            fade.endPoint = CGPoint(x: 1, y: 0.5)
            // ...and the newest edge softens over the last few percent instead of ending square.
            fade.colors = [UIColor.black.withAlphaComponent(0).cgColor,
                           UIColor.black.withAlphaComponent(0.55).cgColor,
                           UIColor.black.cgColor,
                           UIColor.black.cgColor,
                           UIColor.black.withAlphaComponent(0).cgColor]
            fade.locations = [0, 0.3, 0.6, 0.93, 1]
            container.mask = fade
            for shape in [fill, crest, shade] { shape.actions = ["path": NSNull()] }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        deinit { link?.invalidate() }

        func update(levels: [Float], color: UIColor, ink: UIColor, shading: Shading, animated: Bool) {
            self.animated = animated
            if lastColor.map({ $0.0 != color || $0.1 != ink || $0.2 != shading }) ?? true {
                lastColor = (color, ink, shading)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                let deep = Self.deepened(color)
                // On a dark surface the ink is the accent itself, and the wave is the original
                // gradient whatever the treatment: only light surfaces borrow darkness.
                switch ink == color ? .plain : shading {
                case .plain, .halo:
                    depth.colors = [deep.cgColor,
                                    color.withAlphaComponent(0.85).cgColor,
                                    color.withAlphaComponent(0.18).cgColor,
                                    color.withAlphaComponent(0.85).cgColor,
                                    deep.cgColor]
                    crest.strokeColor = color.withAlphaComponent(0.9).cgColor
                case .edges:
                    // Pale at the center line, the ink at the reaches: the louder the sound, the
                    // more ink it carries. On dark keyboards ink is the accent, so this is the
                    // original gradient; on light ones the reaches turn to the deep tone.
                    depth.colors = [ink.cgColor,
                                    ink.withAlphaComponent(0.85).cgColor,
                                    color.withAlphaComponent(0.35).cgColor,
                                    ink.withAlphaComponent(0.85).cgColor,
                                    ink.cgColor]
                    crest.strokeColor = ink.withAlphaComponent(0.9).cgColor
                case .core:
                    depth.colors = [color.withAlphaComponent(0.55).cgColor,
                                    ink.withAlphaComponent(0.6).cgColor,
                                    ink.cgColor,
                                    ink.withAlphaComponent(0.6).cgColor,
                                    color.withAlphaComponent(0.55).cgColor]
                    crest.strokeColor = color.withAlphaComponent(0.9).cgColor
                }
                let halo = shading == .halo
                shade.opacity = halo ? 1 : 0
                shade.shadowOpacity = halo ? 0.45 : 0
                shade.fillColor = UIColor.black.withAlphaComponent(halo ? 0.22 : 0).cgColor
                CATransaction.commit()
            }
            let next = levels.map { $0.isFinite ? min(max($0, 0), 1) : 0 }
            guard next != samples else { return }
            samples = next
            lastArrival = CACurrentMediaTime()
            let live = animated && samples.count > 2 && window != nil
            setLink(running: live)
            if !live { redraw(phase: 0) }
        }

        private func setLink(running: Bool) {
            if running, link == nil {
                let link = CADisplayLink(target: WeakTarget(self), selector: #selector(WeakTarget.tick))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
                link.add(to: .main, forMode: .common)
                self.link = link
            } else if !running {
                link?.invalidate()
                link = nil
            }
        }

        fileprivate func tick() {
            let phase = min((CACurrentMediaTime() - lastArrival) / Self.sampleInterval, 1)
            redraw(phase: CGFloat(phase))
            // A stalled stream (pause, stop) settles and stops the link.
            if CACurrentMediaTime() - lastArrival > 0.4 { setLink(running: false) }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { setLink(running: false) }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            container.frame = bounds
            fade.frame = bounds
            depth.frame = bounds
            fill.frame = bounds
            crest.frame = bounds
            shade.frame = bounds
            CATransaction.commit()
            redraw(phase: 0)
        }

        /// `phase` is how far (0 to 1 of one sample step) the wave has scrolled since the newest
        /// sample arrived.
        private func redraw(phase: CGFloat) {
            guard bounds.width > 0, bounds.height > 0 else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let (body, line) = paths(phase: phase)
            fill.path = body
            crest.path = line
            shade.path = body
            shade.shadowPath = body
            CATransaction.commit()
        }

        private func paths(phase: CGFloat) -> (CGPath, CGPath) {
            let mid = bounds.height / 2
            let amplitude = bounds.height / 2 - 1
            let values = samples.count > 2 ? samples : [Float](repeating: 0, count: 3)
            // One step hidden past each edge so the scroll never exposes an end.
            let step = bounds.width / CGFloat(values.count - 2)
            let points: [CGPoint] = values.enumerated().map { index, value in
                let x = (CGFloat(index) - 0.5 - phase) * step
                // The newest sample eases in over the last step instead of popping up.
                let entry = index == values.count - 1 ? phase : 1
                let height = max(0.75, CGFloat(pow(Double(value), 0.62)) * amplitude * max(entry, 0.15))
                return CGPoint(x: x, y: mid - height)
            }
            let mirrored = points.reversed().map { CGPoint(x: $0.x, y: 2 * mid - $0.y) }
            let line = CGMutablePath()
            Self.append(points, to: line, moving: true)
            Self.append(mirrored, to: line, moving: true)
            let body = CGMutablePath()
            Self.append(points, to: body, moving: true)
            Self.append(mirrored, to: body, moving: false)
            body.closeSubpath()
            return (body, line)
        }

        /// The accent, richer and a touch darker: the color at the wave's loudest reach.
        private static func deepened(_ color: UIColor) -> UIColor {
            var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard color.getHue(&h, saturation: &sat, brightness: &b, alpha: &a) else { return color }
            return UIColor(hue: h, saturation: min(sat * 1.3 + 0.1, 1), brightness: b * 0.78, alpha: 1)
        }

        /// Catmull-Rom through the points as cubic Béziers, so the curve passes through every
        /// sample. With `moving` false the run continues the current subpath with a line first.
        private static func append(_ points: [CGPoint], to path: CGMutablePath, moving: Bool) {
            guard let first = points.first else { return }
            if moving { path.move(to: first) } else { path.addLine(to: first) }
            guard points.count > 2 else {
                points.dropFirst().forEach { path.addLine(to: $0) }
                return
            }
            for i in 0..<(points.count - 1) {
                let p0 = points[max(i - 1, 0)], p1 = points[i]
                let p2 = points[i + 1], p3 = points[min(i + 2, points.count - 1)]
                let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
                let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
                path.addCurve(to: p2, control1: c1, control2: c2)
            }
        }
    }
}

/// A display link retains its target; this breaks the cycle with the wave view.
private final class WeakTarget: NSObject {
    weak var view: FlowingWave.WaveView?
    init(_ view: FlowingWave.WaveView) { self.view = view }
    @objc func tick() { view?.tick() }
}
