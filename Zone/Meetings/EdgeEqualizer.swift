// by zayd/cold @ zayd.wtf

import SwiftUI
import UIKit

/// The edges of the screen as the meeting's level meter. A soft band of the accent lies along
/// the screen's border; its inner edge rises and falls with the voice.
///
/// `.flow`: sound enters at the bottom center, where the iPhone's microphone is, and flows up
/// both sides to meet at the top as it ages, so the border carries the last couple of seconds
/// of the room. `.breath`: the whole border swells evenly with the current level.
///
/// Built for a screen that may sit on a table for six hours: one pre-rendered glow image (drawn
/// once per size and color), masked by one shape layer whose path is rebuilt on a display link
/// only while samples arrive (about 600 points a frame, no blur at run time). Paused, it settles
/// to a thin muted line and the link stops. Reduce Motion: the band holds a fixed depth and only
/// its brightness follows the level, without movement.
struct EdgeEqualizer: UIViewRepresentable {
    enum Style: String, CaseIterable, Identifiable {
        case flow, breath, glow
        var id: String { rawValue }
        var title: String {
            switch self {
            case .flow: "Flow"
            case .breath: "Breathe"
            case .glow: "Still glow"
            }
        }
    }

    let levels: [Float]
    var color: UIColor
    var active: Bool
    var style: Style = .flow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIView(context: Context) -> EdgeView { EdgeView() }
    func updateUIView(_ view: EdgeView, context: Context) {
        view.update(levels: levels, color: color, active: active, style: style, reduceMotion: reduceMotion)
    }

    final class EdgeView: UIView {
        static let sampleInterval: CFTimeInterval = 0.05
        /// Deepest reach of the band into the screen, in points.
        static let depth: CGFloat = 52
        /// The band at rest.
        static let rest: CGFloat = 3

        private let glow = CALayer()
        private let band = CAShapeLayer()
        private let crest = CAShapeLayer()
        private var samples: [Float] = []
        private var smoothed: CGFloat = 0
        /// The loudest recent sample, decaying, so a quiet room or steady white noise still
        /// moves the band instead of sitting near the rest line. Never below `gainFloor`, so
        /// true silence stays calm and a cough is not stretched to the full depth.
        private var peak: CGFloat = 0.5
        private var displayedPeak: CGFloat = 0.5
        private var lastDraw: CFTimeInterval = 0
        private static let gainFloor: CGFloat = 0.12
        private static let peakDecay: CGFloat = 0.985
        private var lastArrival: CFTimeInterval = 0
        private var color: UIColor = .systemPurple
        private var renderedFor: (CGSize, UIColor)?
        private var active = true
        private var style: Style = .flow
        private var reduceMotion = false
        private var link: CADisplayLink?
        private var perimeterFor: (CGRect, CGFloat)?
        private var perimeterPoints: [(point: CGPoint, normal: CGVector, distance: CGFloat)] = []

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            backgroundColor = .clear
            band.fillRule = .evenOdd
            band.fillColor = UIColor.black.cgColor
            glow.mask = band
            layer.addSublayer(glow)
            crest.fillColor = nil
            crest.lineWidth = 1
            layer.addSublayer(crest)
            for target in [band, crest] as [CALayer] { target.actions = ["path": NSNull(), "opacity": NSNull()] }
            glow.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
            NotificationCenter.default.addObserver(self, selector: #selector(suspendAnimation),
                name: UIApplication.willResignActiveNotification, object: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit {
            link?.invalidate()
            NotificationCenter.default.removeObserver(self)
        }

        func update(levels: [Float], color: UIColor, active: Bool, style: Style, reduceMotion: Bool) {
            let changedLook = color != self.color || active != self.active || style != self.style || reduceMotion != self.reduceMotion
            self.color = color
            self.active = active
            self.style = style
            self.reduceMotion = reduceMotion
            let next = levels.map { $0.isFinite ? min(max($0, 0), 1) : 0 }
            let changedSamples = next != samples
            if changedSamples {
                samples = next
                lastArrival = CACurrentMediaTime()
                let newest = CGFloat(next.last ?? 0)
                peak = max(newest, peak * Self.peakDecay, Self.gainFloor)
            }
            if changedLook { renderGlowIfNeeded(); crest.strokeColor = color.withAlphaComponent(0.45).cgColor }
            // The link runs only while new samples arrive; tick() stops it once they settle, and
            // an unchanged update (paused, silent) must not start it again.
            let live = active && !reduceMotion && style != .glow && samples.count > 3 && window != nil
                && UIApplication.shared.applicationState == .active && (changedSamples || link != nil)
            setLink(running: live)
            if !live, changedLook || changedSamples { redraw(phase: 1) }
        }

        private func setLink(running: Bool) {
            if running, link == nil {
                let link = CADisplayLink(target: EdgeWeakTarget(self), selector: #selector(EdgeWeakTarget.tick))
                // Interpolate the 20 Hz meter at 30 fps: smooth enough for a 20 Hz source, half
                // the frames of 60 on a screen that may stay on for hours. Perimeter geometry is
                // cached; each frame only displaces those points and updates the mask.
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 30)
                link.add(to: .main, forMode: .common)
                self.link = link
            } else if !running {
                link?.invalidate()
                link = nil
            }
        }

        @objc private func suspendAnimation() { setLink(running: false) }

        fileprivate func tick() {
            let phase = min((CACurrentMediaTime() - lastArrival) / Self.sampleInterval, 1)
            redraw(phase: CGFloat(phase))
            // Samples stop arriving while paused or silent; the ripple needs a few more frames
            // to settle, then the link rests.
            if CACurrentMediaTime() - lastArrival > 1.5 { setLink(running: false) }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { setLink(running: false) }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glow.frame = bounds
            band.frame = bounds
            crest.frame = bounds
            CATransaction.commit()
            renderGlowIfNeeded()
            redraw(phase: 1)
        }

        /// The display's corner radius is not public; modern iPhones sit between 47 and 62 pt,
        /// and the soft band hides the difference. Home-button phones have square corners, but
        /// the band still turns them on a small radius: a square turn folds the wavy inner edge
        /// into spikes.
        private var cornerRadius: CGFloat {
            (window?.safeAreaInsets.bottom ?? 0) > 0 ? 56 : 20
        }

        /// The accent fading inward from the border, drawn once per size and color.
        private func renderGlowIfNeeded() {
            let size = bounds.size
            guard size.width > 0, size.height > 0 else { return }
            let tint = active ? color : color.withAlphaComponent(0.6)
            if let rendered = renderedFor, rendered.0 == size, rendered.1 == tint { return }
            renderedFor = (size, tint)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1 // A glow has no detail to lose; a quarter of the memory.
            let radius = cornerRadius
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                let cg = context.cgContext
                let steps = Int(Self.depth)
                // Two tones: the accent at the border melting into a paler, brighter tint toward
                // the inner edge, so the band reads as light rather than a flat stripe.
                var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, baseAlpha: CGFloat = 1
                tint.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &baseAlpha)
                let inner = UIColor(hue: hue, saturation: saturation * 0.45, brightness: min(brightness * 1.15, 1), alpha: baseAlpha)
                for step in 0..<steps {
                    let t = CGFloat(step) / CGFloat(steps)
                    let alpha = pow(1 - t, 2.2) * 0.62
                    let inset = CGFloat(step) + 0.5
                    let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
                    let path = UIBezierPath(roundedRect: rect, cornerRadius: max(radius - inset, 0))
                    let blend = t * t
                    let stroke = UIColor(cgColor: tint.cgColor).mixed(with: inner, fraction: blend)
                    cg.setStrokeColor(stroke.withAlphaComponent(alpha).cgColor)
                    cg.setLineWidth(1.5)
                    cg.addPath(path.cgPath)
                    cg.strokePath()
                }
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glow.contents = image.cgImage
            CATransaction.commit()
        }

        private func redraw(phase: CGFloat) {
            guard bounds.width > 0, bounds.height > 0 else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let now = CACurrentMediaTime()
            let elapsed = lastDraw == 0 ? Self.sampleInterval : min(max(now - lastDraw, 0), 0.1)
            lastDraw = now
            displayedPeak += (peak - displayedPeak) * CGFloat(1 - exp(-elapsed / 0.12))
            let level = CGFloat(samples.last ?? 0)
            smoothed += (level - smoothed) * CGFloat(1 - exp(-elapsed / 0.16))
            let (band, edge) = paths(phase: phase)
            self.band.path = band
            crest.path = edge
            if !active {
                glow.opacity = 0.35
                crest.opacity = 0.4
            } else if reduceMotion || style == .glow {
                // Brightness only: no movement.
                glow.opacity = Float(0.35 + 0.65 * pow(smoothed, 0.6))
                crest.opacity = 0
            } else {
                glow.opacity = 1
                crest.opacity = 1
            }
            CATransaction.commit()
        }

        /// The level, 0...1, at a place on the border: `distance` 0 is the bottom center (now),
        /// 1 the top center (the oldest sample), scrolled by `phase` between arrivals.
        private func level(at distance: CGFloat, phase: CGFloat, gains: [CGFloat]? = nil) -> CGFloat {
            guard active, samples.count > 3 else { return 0 }
            if reduceMotion || style == .glow { return 0.55 }
            if style == .breath { return gained(smoothed) }
            let span = CGFloat(samples.count - 4)
            // Keep one sample of look-ahead for the spline; the 50 ms delay avoids a pop
            // at the microphone when a new sample arrives.
            let position = CGFloat(samples.count - 2) - (distance * span) - (1 - phase)
            let lower = Int(floor(position))
            let t = position - CGFloat(lower)
            func sample(_ index: Int) -> CGFloat {
                let clamped = min(max(index, 0), samples.count - 1)
                return gains?[clamped] ?? gained(CGFloat(samples[clamped]))
            }
            // A cubic B-spline joins the samples with continuous velocity and curvature. Its
            // positive weights cannot overshoot (a sharp sound must not fold the corner inward).
            // Apply gain BEFORE weighting: gained(sample * weight) inflated the old interpolation
            // and made the band pulse between sample boundaries.
            let t2 = t * t, t3 = t2 * t, inverse = 1 - t
            let value = (sample(lower - 1) * inverse * inverse * inverse
                + sample(lower) * (3 * t3 - 6 * t2 + 4)
                + sample(lower + 1) * (-3 * t3 + 3 * t2 + 3 * t + 1)
                + sample(lower + 2) * t3) / 6
            // Older sound fades as it nears the top. A slow ripple keeps the band alive between
            // words so it never reads as a dead line.
            let ripple = 0.035 * (1 + sin(distance * 9.4 + CGFloat(CACurrentMediaTime()) * 1.7))
            return value * (1 - 0.55 * distance) + ripple
        }

        /// The sample against the recent peak, eased so small sounds show and loud ones do not clip.
        private func gained(_ value: CGFloat) -> CGFloat {
            let scaled = min(value / max(displayedPeak, Self.gainFloor), 1)
            return pow(scaled, 0.8)
        }

        private func paths(phase: CGFloat) -> (CGPath, CGPath) {
            let radius = cornerRadius
            if perimeterFor?.0 != bounds || perimeterFor?.1 != radius {
                let perimeter = Perimeter(rect: bounds, radius: radius)
                let count = max(Int(perimeter.length / 4), 64)
                perimeterPoints = (0...count).map { index in
                    let s = CGFloat(index) / CGFloat(count)
                    let (point, normal) = perimeter.point(at: s)
                    let distance = min(s, 1 - s) * 2
                    // Both halves meet at the top and bottom. Flatten the age gradient at
                    // those joins so a rising sample does not make a pointed seam.
                    let join: CGFloat = 0.08
                    func easeJoin(_ value: CGFloat) -> CGFloat {
                        value * value * (2 * join - value) / (join * join)
                    }
                    let age = distance < join ? easeJoin(distance)
                        : distance > 1 - join ? 1 - easeJoin(1 - distance) : distance
                    return (point, normal, age)
                }
                perimeterFor = (bounds, radius)
            }
            let inner = CGMutablePath()
            // On square/home-button screens, the inset must stay within the smaller arc.
            let maxDepth = min(Self.depth, max(Self.rest, radius - 2))
            // Gain is identical at every location this frame; evaluate its power once per sample.
            let gains = samples.map { gained(CGFloat($0)) }
            for (index, entry) in perimeterPoints.enumerated() {
                let raw = min(max(level(at: entry.distance, phase: phase, gains: gains), 0), 1)
                let depth = Self.rest + pow(raw, 0.7) * (maxDepth - Self.rest)
                let p = CGPoint(x: entry.point.x + entry.normal.dx * depth,
                                y: entry.point.y + entry.normal.dy * depth)
                if index == 0 { inner.move(to: p) } else { inner.addLine(to: p) }
            }
            inner.closeSubpath()
            let band = CGMutablePath()
            band.addRect(bounds.insetBy(dx: -2, dy: -2))
            band.addPath(inner)
            return (band, inner)
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

/// A display link retains its target; this breaks the cycle with the view.
private final class EdgeWeakTarget: NSObject {
    weak var view: EdgeEqualizer.EdgeView?
    init(_ view: EdgeEqualizer.EdgeView) { self.view = view }
    @objc func tick() { view?.tick() }
}

private extension UIColor {
    /// A straight RGB blend; `fraction` 0 is self, 1 is `other`.
    func mixed(with other: UIColor, fraction: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let f = min(max(fraction, 0), 1)
        return UIColor(red: r1 + (r2 - r1) * f, green: g1 + (g2 - g1) * f, blue: b1 + (b2 - b1) * f, alpha: a1 + (a2 - a1) * f)
    }
}
