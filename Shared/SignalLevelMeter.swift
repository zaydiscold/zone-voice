// by zayd/cold @ zayd.wtf

import SwiftUI
import UIKit
import ZoneCore

/// Draws actual sampled levels. Core Animation interpolates between received values without
/// an animation timer, synthetic energy, or extra audio/shared-store sampling. The one bar meter
/// for the app and the keyboard: a fixed `barCount`, or with `barPitch` as many bars as fit the
/// width at that pitch (12 to 48). The `swell` shape is the Bars voice graphic (`VoiceBars`): the
/// width alone decides its count.
struct SignalLevelMeter: UIViewRepresentable {
    /// `trail`: one bar per sample, newest on the right, older bars fading out to the left.
    /// `swell`: thin solid bars across the whole width, tallest in the middle (`VoiceBars`).
    enum Shape { case trail, swell }

    let levels: [Float]
    var barCount = 32
    var color: UIColor
    /// Bar plus gap, in points. When set, the width decides the bar count instead of `barCount`.
    var barPitch: CGFloat? = nil
    var shape = Shape.trail
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIView(context: Context) -> LevelBarsView { LevelBarsView() }
    func updateUIView(_ view: LevelBarsView, context: Context) {
        view.update(levels: levels, count: barCount, pitch: barPitch, shape: shape, color: color, animated: !reduceMotion)
    }

    final class LevelBarsView: UIView {
        private var bars: [CAShapeLayer] = []
        private var samples: [Float] = []
        private var lastBounds = CGRect.null
        private var fixedCount = 32
        private var pitch: CGFloat?
        private var shape = Shape.trail
        private var color: UIColor = .clear

        /// The fixed count, or what fits the current width at the requested pitch.
        private var resolvedCount: Int {
            if shape == .swell { return VoiceBars.count(fitting: bounds.width) }
            guard let pitch else { return fixedCount }
            return max(12, min(48, Int(bounds.width / max(1, pitch))))
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func update(levels: [Float], count: Int, pitch: CGFloat?, shape: Shape = .trail, color: UIColor, animated: Bool) {
            let finiteLevels = levels.map(VoiceDisplayLevel.map)
            fixedCount = count
            self.pitch = pitch
            let reshaped = shape != self.shape
            self.shape = shape
            let rebuilt = rebuildBarsIfNeeded()
            let changed = samples != finiteLevels || rebuilt || reshaped
            samples = finiteLevels
            if !color.isEqual(self.color) || rebuilt {
                self.color = color
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                bars.forEach { $0.fillColor = color.cgColor }
                CATransaction.commit()
            }
            if changed { drawBars(animate: animated) }
            if !animated { bars.forEach { $0.removeAllAnimations() } }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds != lastBounds else { return }
            lastBounds = bounds
            if rebuildBarsIfNeeded() {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                bars.forEach { $0.fillColor = color.cgColor }
                CATransaction.commit()
            }
            drawBars(animate: false)
        }

        /// Returns true when the bar layers were replaced.
        private func rebuildBarsIfNeeded() -> Bool {
            let count = resolvedCount
            guard bars.count != count else { return false }
            bars.forEach { $0.removeFromSuperlayer() }
            bars = (0..<max(0, count)).map { _ in
                let bar = CAShapeLayer()
                layer.addSublayer(bar)
                return bar
            }
            return true
        }

        /// One bar per received sample, newest on the right, older bars fading toward the left.
        /// Bars are never interpolated between samples: blended ramps read as three levels.
        /// Rising bars snap up fast and fall back slower, the way a VU needle moves.
        private func drawBars(animate: Bool) {
            guard !bars.isEmpty, bounds.width > 0, bounds.height > 0 else { return }
            let swell = shape == .swell
            let visible = samples.isEmpty ? [] : Array(samples.suffix(bars.count))
            // The swell keeps its own pitch and centers the row; the trail spreads over the width.
            let pitch = swell ? CGFloat(VoiceBars.pitch) : bounds.width / CGFloat(bars.count)
            let inset = swell ? (bounds.width - pitch * CGFloat(bars.count)) / 2 : 0
            let width = swell ? 2 : max(1, min(pitch * 0.55, 3))
            let offset = bars.count - visible.count
            let reaches = swell ? VoiceBars.heights(levels: samples, count: bars.count) : []
            for (index, bar) in bars.enumerated() {
                let level = swell ? reaches[index] : (index >= offset ? visible[index - offset] : 0)
                // At rest a swell bar is a short stub, a little taller than it is wide.
                let height = max(swell ? 3.5 : 3, CGFloat(min(max(level, 0), 1)) * bounds.height)
                let rect = CGRect(x: inset + CGFloat(index) * pitch + (pitch - width) / 2,
                                  y: (bounds.height - height) / 2, width: width, height: height)
                let next = UIBezierPath(roundedRect: rect, cornerRadius: width / 2).cgPath
                let previous = bar.presentation()?.path ?? bar.path
                let rising = (previous?.boundingBox.height ?? 0) < height
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                bar.path = next
                bar.opacity = swell ? 1 : Float(0.35 + 0.65 * Double(index) / Double(max(1, bars.count - 1)))
                CATransaction.commit()
                if animate, let previous {
                    let transition = CABasicAnimation(keyPath: "path")
                    transition.fromValue = previous
                    transition.toValue = next
                    transition.duration = rising ? 0.045 : 0.16
                    transition.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                    bar.add(transition, forKey: "sample")
                } else {
                    bar.removeAnimation(forKey: "sample")
                }
            }
        }
    }
}
