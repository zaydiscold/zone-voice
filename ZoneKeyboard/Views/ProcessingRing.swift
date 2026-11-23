// by zayd/cold @ zayd.wtf

import SwiftUI
import UIKit

/// "Recognizing": a hairline accent ring with one bright arc sweeping around it, and optional
/// shimmer lines that run outward from the center. All Core Animation on the render server
/// (no SwiftUI timers), so it costs nothing on the main thread while the person types. Reduce
/// Motion shows the ring and a still arc.
struct ProcessingRing: UIViewRepresentable {
    var color: UIColor
    var lineWidth: CGFloat = 2.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIView(context: Context) -> RingView { RingView() }
    func updateUIView(_ view: RingView, context: Context) {
        view.configure(color: color, lineWidth: lineWidth, animated: !reduceMotion)
    }

    final class RingView: UIView {
        private let track = CAShapeLayer()
        private let arc = CAShapeLayer()
        private var last: (UIColor, CGFloat, Bool)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            for layer in [track, arc] {
                layer.fillColor = nil
                layer.lineCap = .round
                self.layer.addSublayer(layer)
            }
            arc.strokeStart = 0
            arc.strokeEnd = 0.28
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(color: UIColor, lineWidth: CGFloat, animated: Bool) {
            last = (color, lineWidth, animated)
            track.strokeColor = color.withAlphaComponent(0.22).cgColor
            arc.strokeColor = color.cgColor
            track.lineWidth = lineWidth
            arc.lineWidth = lineWidth
            if animated, arc.animation(forKey: "spin") == nil {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = 2 * Double.pi
                spin.duration = 1.1
                spin.repeatCount = .infinity
                spin.isRemovedOnCompletion = false
                arc.add(spin, forKey: "spin")
                // The arc breathes in length so the motion reads as work, not a stock spinner.
                let breathe = CABasicAnimation(keyPath: "strokeEnd")
                breathe.fromValue = 0.12
                breathe.toValue = 0.42
                breathe.duration = 0.9
                breathe.autoreverses = true
                breathe.repeatCount = .infinity
                breathe.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                breathe.isRemovedOnCompletion = false
                arc.add(breathe, forKey: "breathe")
            } else if !animated {
                arc.removeAllAnimations()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let inset = max(track.lineWidth, 2) / 2
            let rect = bounds.insetBy(dx: inset, dy: inset)
            let path = UIBezierPath(ovalIn: CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height)).cgPath
            for layer in [track, arc] {
                layer.bounds = CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height)
                layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
                layer.path = path
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // Core Animation drops infinite animations when a view leaves the window.
            if window != nil, let last {
                arc.removeAllAnimations()
                configure(color: last.0, lineWidth: last.1, animated: last.2)
                setNeedsLayout()
            }
        }
    }
}

/// A hairline that a soft highlight travels along, in the direction given.
struct ShimmerLine: UIViewRepresentable {
    var color: UIColor
    var leftToRight = true
    /// Seconds per pass: 1.3 while recognizing, slower and calmer at rest.
    var period: CFTimeInterval = 1.3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIView(context: Context) -> LineView { LineView() }
    func updateUIView(_ view: LineView, context: Context) {
        view.configure(color: color, leftToRight: leftToRight, period: period, animated: !reduceMotion)
    }

    final class LineView: UIView {
        private let base = CALayer()
        private let glow = CAGradientLayer()
        private var last: (UIColor, Bool, CFTimeInterval, Bool)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            layer.addSublayer(base)
            layer.addSublayer(glow)
            glow.startPoint = CGPoint(x: 0, y: 0.5)
            glow.endPoint = CGPoint(x: 1, y: 0.5)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(color: UIColor, leftToRight: Bool, period: CFTimeInterval, animated: Bool) {
            last = (color, leftToRight, period, animated)
            base.backgroundColor = color.withAlphaComponent(0.25).cgColor
            glow.colors = [color.withAlphaComponent(0).cgColor, color.cgColor, color.withAlphaComponent(0).cgColor]
            glow.locations = [0, 0.1, 0.2]
            guard animated else { glow.removeAllAnimations(); return }
            if glow.animation(forKey: "travel") == nil {
                let travel = CABasicAnimation(keyPath: "locations")
                travel.fromValue = leftToRight ? [-0.2, -0.1, 0] : [1, 1.1, 1.2]
                travel.toValue = leftToRight ? [1, 1.1, 1.2] : [-0.2, -0.1, 0]
                travel.duration = period
                travel.repeatCount = .infinity
                travel.isRemovedOnCompletion = false
                travel.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                glow.add(travel, forKey: "travel")
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let line = CGRect(x: 0, y: bounds.midY - 1, width: bounds.width, height: 2)
            base.frame = line
            glow.frame = line
            base.cornerRadius = 1
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil, let last {
                glow.removeAllAnimations()
                configure(color: last.0, leftToRight: last.1, period: last.2, animated: last.3)
                setNeedsLayout()
            }
        }
    }
}

/// The "zone" wordmark: the letters mask a left-to-right gradient, a hint of ink on the "z"
/// fading into the accent by the "n". One gradient and a text mask, no animation.
struct LivingWordmark: UIViewRepresentable {
    var color: UIColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIView(context: Context) -> InkView { InkView() }
    func updateUIView(_ view: InkView, context: Context) { view.configure(color: color, animated: !reduceMotion) }

    final class InkView: UIView {
        private let gradient = CAGradientLayer()
        private let text = CATextLayer()
        private var font = UIFont.systemFont(ofSize: 18)
        private var last: (UIColor, Bool)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            layer.addSublayer(gradient)
            gradient.startPoint = CGPoint(x: 0, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
            text.string = "zone"
            let base = UIFont.systemFont(ofSize: 18, weight: .semibold)
            font = base.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: 18) } ?? base
            text.font = font
            text.fontSize = 18
            text.contentsScale = UIScreen.main.scale
            text.alignmentMode = .left
            gradient.mask = text
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(color: UIColor, animated: Bool) {
            if let last, last.0 == color, last.1 == animated { return }
            last = (color, animated)
            // Mostly accent, with a hint of ink on the left that fades into it. Still, not moving:
            // a traveling dark band read as one blacked-out letter.
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            let inked = UIColor(red: r * 0.45, green: g * 0.45, blue: b * 0.5, alpha: 1)
            gradient.removeAllAnimations()
            gradient.colors = [inked.cgColor, color.cgColor, color.cgColor]
            gradient.locations = [0, 0.55, 1]
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            gradient.frame = bounds
            // A text layer sets glyphs from the ascender down; "zone" is all lowercase, so center
            // its x-height (what the eye reads as the word's middle) on the view's middle.
            let top = (bounds.height - font.xHeight) / 2 - (font.ascender - font.xHeight)
            text.frame = CGRect(x: 0, y: top, width: bounds.width, height: font.lineHeight)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil, let last { self.last = nil; configure(color: last.0, animated: last.1) }
        }
    }
}
