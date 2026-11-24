// by zayd/cold @ zayd.wtf

import SwiftUI
import UIKit
import ZoneCore

/// A small, display-linked strip. Its targets are a history of measured syllables.
struct FlowingWave: UIViewRepresentable {
    let levels: [Float]
    var color: UIColor
    var edgeColor: UIColor? = nil
    var style: MeterStyle = .wave
    var live = true
    var detail: CGFloat = 1
    var stillFrame = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    func makeUIView(context: Context) -> WaveView { WaveView() }

    func updateUIView(_ view: WaveView, context: Context) {
        view.update(levels: levels.map(VoiceDisplayLevel.map), live: live, color: color, edgeColor: edgeColor, style: style, detail: detail,
                    animated: !stillFrame && (live || style == .wave) && !reduceMotion && (scenePhase == .active || VoiceGraphicVisibility.inKeyboard),
                    reduceMotion: reduceMotion || stillFrame)
    }

    static func dismantleUIView(_ view: WaveView, coordinator: ()) { view.dismantle() }

    final class WaveView: UIView {
        private var detail: CGFloat = 1
        private var style = MeterStyle.wave
        private var color = UIColor.clear
        private var edgeColor = UIColor.clear
        private var targets: [CGFloat] = []
        private(set) var shown: [CGFloat] = []
        private var history: [Float] = []
        private(set) var phase = 0.0
        private(set) var opening: CGFloat = 0
        private var voiced = false
        private var silenceTask: Task<Void, Never>?
        // AdaptiveLevelScale puts normal room noise below 0.03. Open at QuietInputMonitor's threshold.
        private static let openLevel: Float = 0.04
        private static let keepOpenLevel: Float = 0.03
        private var reducedMotion = false
        private var animate = false
        private var link: CADisplayLink?
        private var previous: CFTimeInterval?
        #if DEBUG
        private(set) var probeFrames = 0
        var isAnimating: Bool { link != nil }
        #endif

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
            backgroundColor = .clear
            isUserInteractionEnabled = false
            contentMode = .redraw
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        deinit {
            silenceTask?.cancel()
            link?.invalidate()
        }

        func update(levels: [Float], live: Bool = true, color: UIColor, edgeColor: UIColor? = nil, style: MeterStyle, detail: CGFloat, animated: Bool, reduceMotion: Bool = false) {
            let levels = live ? levels : []
            let edgeColor = edgeColor ?? color
            let sample = levels.last ?? 0
            reducedMotion = reduceMotion
            let wasVoiced = voiced
            if style != .wave || !live {
                cancelSilence()
                setVoiced(false)
            } else if sample.isFinite && sample >= (voiced ? Self.keepOpenLevel : Self.openLevel) {
                cancelSilence()
                setVoiced(true)
            } else if voiced, silenceTask == nil {
                // SwiftUI may coalesce identical quiet samples. Finish even if no more arrive.
                silenceTask = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(240)) } catch { return }
                    guard !Task.isCancelled, let self else { return }
                    silenceTask = nil
                    setVoiced(false)
                    refresh()
                }
            }
            if style != .wave { opening = 0 }
            // Keep the last audible contour through consonant and word gaps.
            if style == .wave, self.style == .wave, wasVoiced == voiced,
               silenceTask != nil || (!voiced && opening == 0 && link == nil),
               !targets.isEmpty, self.color == color, self.edgeColor == edgeColor, self.detail == detail,
               animate == animated { return }
            self.color = color
            self.edgeColor = edgeColor
            let changed = self.style != style || history != levels || self.detail != detail
            self.detail = detail
            self.style = style
            animate = animated
            if changed || targets.isEmpty {
                history = Array(levels.suffix(48))
                rebuildTargets()
            }
            refresh()
        }

        private func cancelSilence() {
            silenceTask?.cancel()
            silenceTask = nil
        }

        private func setVoiced(_ value: Bool) {
            guard value != voiced else { return }
            voiced = value
            if reducedMotion, VoiceGraphicVisibility.onScreen(self) {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.12
                layer.add(fade, forKey: kCATransition)
            }
        }

        private func resetContour() {
            opening = 0
            phase = 0
            for i in shown.indices { shown[i] = 0 }
        }

        private func rebuildTargets() {
            if style == .bars {
                targets = VoiceBars.heights(levels: history, count: VoiceBars.count(fitting: bounds.width, pitch: VoiceBars.pitch * detail)).map { CGFloat($0) }
            } else {
                let count = style == .mirrored ? min(31, max(3, Int(bounds.width / (8 * detail)))) : 32
                targets = (0..<count).map { index in
                    guard !history.isEmpty else { return 0 }
                    let x = CGFloat(index) / CGFloat(count - 1)
                    // Mirrored reads outwards from the freshest sound in the center.
                    let position = style == .mirrored ? 1 - abs(x * 2 - 1) : x
                    let read = position * CGFloat(history.count - 1)
                    let i = Int(read)
                    let a = CGFloat(history[i]), b = CGFloat(history[min(i + 1, history.count - 1)])
                    let value = a + (b - a) * (read - CGFloat(i))
                    return value.isFinite ? pow(min(1, max(0, value)), 0.62) : 0
                }
            }
            if shown.count != targets.count { shown = Array(repeating: 0, count: targets.count) }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            rebuildTargets()
            refresh()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            refresh()
        }

        private func refresh() {
            guard animate, VoiceGraphicVisibility.onScreen(self) else {
                stop()
                if style == .wave && (animate || !voiced) {
                    resetContour()
                } else {
                    opening = voiced ? 1 : 0
                    phase = 0
                    shown = targets
                }
                setNeedsDisplay()
                return
            }
            let settling = style != .wave && shown != targets
            let rolling = style == .wave && (voiced || opening > 0)
            guard settling || rolling else {
                if style == .wave { resetContour() }
                stop()
                setNeedsDisplay()
                return
            }
            guard link == nil else { return }
            let clock = CADisplayLink(target: WaveClockTarget(self), selector: #selector(WaveClockTarget.tick(_:)))
            clock.preferredFrameRateRange = .init(minimum: 60, maximum: 120, preferred: 120)
            clock.add(to: .main, forMode: .common)
            link = clock
        }

        fileprivate func dismantle() {
            cancelSilence()
            stop()
        }

        private func stop() {
            link?.invalidate()
            link = nil
            previous = nil
        }

        fileprivate func tick(_ clock: CADisplayLink) {
            guard VoiceGraphicVisibility.onScreen(self) else {
                stop()
                resetContour()
                setNeedsDisplay()
                return
            }
            let dt = min(0.1, clock.targetTimestamp - (previous ?? clock.timestamp))
            previous = clock.targetTimestamp
            let attack = VoiceEnvelope.response(seconds: dt, rising: true)
            let release = VoiceEnvelope.response(seconds: dt, rising: false)
            var settling = false
            if style == .wave {
                opening = voiced ? min(1, opening + dt / 0.18) : max(0, opening - dt / 0.32)
            }
            // Preserve the last contour while both ends close over it.
            if style != .wave || voiced {
                for i in shown.indices {
                    let delta = targets[i] - shown[i]
                    if abs(delta) < 0.0005 { shown[i] = targets[i] }
                    else {
                        shown[i] += delta * (delta > 0 ? attack : release)
                        settling = true
                    }
                }
            }
            if voiced {
                phase = (phase + dt * (1.4 + 2.3 * (shown.last ?? 0))).truncatingRemainder(dividingBy: 8 * .pi)
            }
            setNeedsDisplay()
            let finished = style == .wave ? !voiced && opening == 0 : !settling
            if finished {
                if style == .wave { resetContour() }
                stop()
            }
        }

        override func draw(_ rect: CGRect) {
            guard let ctx = UIGraphicsGetCurrentContext(), !shown.isEmpty else { return }
            #if DEBUG
            probeFrames &+= 1
            #endif
            let mid = bounds.midY
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(edgeColor.cgColor)
            if style != .wave {
                let pitch = bounds.width / CGFloat(shown.count)
                let width = min(style == .bars ? 2.2 : 3.2, pitch * 0.57)
                ctx.setLineWidth(width)
                for i in shown.indices {
                    let x = (CGFloat(i) + 0.5) * pitch
                    let edge = sin(.pi * x / bounds.width)
                    let half = max(0.4, (mid - width / 2) * shown[i])
                    ctx.setAlpha(0.54 + 0.46 * edge)
                    ctx.move(to: CGPoint(x: x, y: mid - half))
                    ctx.addLine(to: CGPoint(x: x, y: mid + half))
                    ctx.strokePath()
                }
                return
            }
            let inset = min(bounds.width / 2, WaveBraid.strands[0].width / 2)
            if opening == 0 {
                let main = WaveBraid.strands[0]
                ctx.setLineWidth(main.width)
                ctx.setAlpha(main.alpha)
                let start = CGPoint(x: inset, y: mid)
                let end = CGPoint(x: bounds.width - inset, y: mid)
                ctx.strokeLineSegments(between: [start, end])
                if color != edgeColor {
                    ctx.setStrokeColor(color.cgColor)
                    ctx.setLineWidth(1)
                    ctx.strokeLineSegments(between: [start, end])
                }
                return
            }
            let steps = min(100, max(28, Int(bounds.width / 3)))
            for (index, strand) in WaveBraid.strands.enumerated() {
                ctx.setStrokeColor(index == 0 ? edgeColor.cgColor : color.cgColor)
                ctx.setLineWidth(strand.width)
                ctx.setAlpha(strand.alpha)
                for i in 0...steps {
                    let x = CGFloat(i) / CGFloat(steps)
                    let read = x * CGFloat(shown.count - 1)
                    let lo = Int(read)
                    let level = shown[lo] + (shown[min(lo + 1, shown.count - 1)] - shown[lo]) * (read - CGFloat(lo))
                    let gain = 0.72 * level + 0.28 * (shown.last ?? 0)
                    let displacement = strand.offset(x: x, opening: opening, phase: phase, detail: detail)
                    let point = CGPoint(x: inset + x * (bounds.width - 2 * inset), y: mid + displacement * gain * max(0, mid - 1.3))
                    if i == 0 { ctx.move(to: point) } else { ctx.addLine(to: point) }
                }
                ctx.strokePath()
            }
        }
    }
}

struct WaveBraid {
    let width: CGFloat
    let alpha: CGFloat
    let cycles: CGFloat
    let speed: CGFloat
    let phaseOffset: CGFloat

    // Quarter-integer speeds all wrap continuously at the clock's 8 pi period.
    static let strands = [
        WaveBraid(width: 2.6, alpha: 0.95, cycles: 1.4, speed: 1, phaseOffset: 0),
        WaveBraid(width: 0.95, alpha: 0.74, cycles: 1.9, speed: -0.75, phaseOffset: 1.9),
        WaveBraid(width: 0.75, alpha: 0.56, cycles: 2.25, speed: 1.25, phaseOffset: 3.7)
    ]

    func offset(x: CGFloat, opening: CGFloat, phase: CGFloat, detail: CGFloat) -> CGFloat {
        let distance = abs(2 * x - 1)
        guard distance < opening else { return 0 }
        // A smooth shoulder keeps the accent visible almost to each lip.
        let t = min(1, (opening - distance) / 0.34)
        let shoulder = t * t * (3 - 2 * t)
        return opening * shoulder * sin(2 * .pi * x * cycles / detail + phase * speed + phaseOffset)
    }
}

private final class WaveClockTarget {
    weak var view: FlowingWave.WaveView?
    init(_ view: FlowingWave.WaveView) { self.view = view }
    @objc func tick(_ link: CADisplayLink) {
        guard let view else { link.invalidate(); return }
        view.tick(link)
    }
}

enum VoiceGraphicVisibility {
    // A keyboard hosting controller can be on screen without a SwiftUI app scene.
    static let inKeyboard = Bundle.main.bundleURL.pathExtension == "appex"

    static func onScreen(_ view: UIView) -> Bool {
        guard let window = view.window, !view.bounds.isEmpty,
              window.bounds.intersects(view.convert(view.bounds, to: window)) else { return false }
        var ancestor: UIView? = view
        while let current = ancestor {
            if current.isHidden || current.alpha < 0.001 { return false }
            ancestor = current.superview
        }
        return true
    }
}
