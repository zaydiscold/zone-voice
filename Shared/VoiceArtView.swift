// by zayd/cold @ zayd.wtf

import SwiftUI
import UIKit
import ZoneCore

struct VoiceGraphic: View {
    let style: MeterStyle
    let levels: [Float]
    let live: Bool
    let ink: UIColor
    let accent: UIColor
    var edgeColor: UIColor? = nil
    var isDark: Bool? = nil
    var detail: CGFloat = 1

    var body: some View {
        if style.isDrawn || style == .scope {
            VoiceArt(style: style, level: live ? levels.last ?? 0 : 0, live: live,
                     ink: ink, accent: edgeColor ?? accent, isDark: isDark, detail: detail)
        } else {
            FlowingWave(levels: levels, color: accent, edgeColor: edgeColor, style: style, live: live, detail: detail)
        }
    }
}

/// The drawn voice graphics (Ink, Glyphs, Branch, Inkblot, Lanes, Stars) and Hex's Scope, for
/// the keyboard strip and Home's composer. `level` is the newest microphone level; `live` is
/// false at rest, where the graphic holds still and no frame timer runs.
struct VoiceArt: View {
    let style: MeterStyle
    let level: Float
    var live = true
    let ink: UIColor
    let accent: UIColor
    var isDark: Bool? = nil
    var detail: CGFloat = 1
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if style == .scope && !reduceMotion {
            HexScope(level: VoiceDisplayLevel.map(level), live: live && (scenePhase == .active || VoiceGraphicVisibility.inKeyboard), detail: detail)
        } else if reduceMotion {
            // Reduce Motion: the plain meter instead of a moving picture.
            SignalLevelMeter(levels: live ? [level] : [], color: accent, shape: .swell)
        } else {
            VoiceArtCanvas(style: style, level: VoiceDisplayLevel.map(level), live: live && (scenePhase == .active || VoiceGraphicVisibility.inKeyboard), ink: ink, accent: accent, isDark: isDark ?? (scheme == .dark), detail: detail)
        }
    }
}

/// Hex's oscilloscope, fed Zone's level. Credit: Hex by Christopher Langton (MIT).
private struct HexScope: View {
    let level: Float
    let live: Bool
    let detail: CGFloat
    @State private var box = LevelBox()

    var body: some View {
        let box = box
        box.level = level
        return DotScopeView(phase: live ? .recording : .idle, tuning: .bar(fade: 20, spacing: Float(3.25 * detail)), drawPlate: false, demoVoice: false,
                            loudnessProvider: { DotScopeSimulation.loudness(fromNormalized: box.level) })
    }

    final class LevelBox { var level: Float = 0 }
}

private struct VoiceArtCanvas: UIViewRepresentable {
    let style: MeterStyle
    let level: Float
    let live: Bool
    let ink: UIColor
    let accent: UIColor
    let isDark: Bool
    let detail: CGFloat

    func makeUIView(context: Context) -> VoiceArtCanvasView { VoiceArtCanvasView() }
    func updateUIView(_ view: VoiceArtCanvasView, context: Context) {
        view.update(style: style, level: level, live: live, ink: ink, accent: accent, isDark: isDark, detail: detail)
    }
    static func dismantleUIView(_ view: VoiceArtCanvasView, coordinator: ()) { view.stop() }
}

final class VoiceArtCanvasView: UIView {
    private var detail: CGFloat = 1
    private var drawingSize: CGSize { CGSize(width: bounds.width / detail, height: bounds.height) }
    private var engine: VoiceArtEngine?
    private var style: MeterStyle?
    private var palette = VoiceArtPalette(ink: ArtColor(1, 1, 1), accent: ArtColor(0.7, 0.6, 1), isDark: true)
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private var live = false
    /// True while the frame timer runs.
    var isAnimating: Bool { link != nil }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(style: MeterStyle, level: Float, live: Bool, ink: UIColor, accent: UIColor, isDark: Bool, detail: CGFloat = 1) {
        self.detail = detail
        if style != self.style {
            self.style = style
            // Seeded by the clock, so no two dictations draw the same picture.
            engine = VoiceArtEngine(style: style, seed: UInt64(Date().timeIntervalSince1970 * 1000))
        }
        palette = VoiceArtPalette(ink: Self.color(ink), accent: Self.color(accent), isDark: isDark)
        engine?.feed(level: live ? level : 0)
        self.live = live
        live && VoiceGraphicVisibility.onScreen(self) ? start() : stop()
        setNeedsDisplay()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stop() } else if live { start() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if live && VoiceGraphicVisibility.onScreen(self) { start() } else { stop() }
    }

    private func start() {
        guard link == nil, VoiceGraphicVisibility.onScreen(self) else { return }
        let link = CADisplayLink(target: LinkTarget(self), selector: #selector(LinkTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        last = nil
    }

    func stop() {
        link?.invalidate()
        link = nil
        last = nil
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let elapsed = last.map { link.timestamp - $0 } ?? 1.0 / 60.0
        last = link.timestamp
        engine?.advance(by: elapsed, size: drawingSize)
        setNeedsDisplay()
    }

    #if DEBUG
    private(set) var probeFrames = 0
    #endif
    override func draw(_ rect: CGRect) {
        #if DEBUG
        probeFrames &+= 1
        #endif
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        context.scaleBy(x: detail, y: 1)
        engine?.draw(in: context, size: drawingSize, palette: palette)
        context.restoreGState()
    }

    private static func color(_ color: UIColor) -> ArtColor {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return ArtColor(red, green, blue)
    }

    /// A display link retains its target; this keeps the view free to go.
    private final class LinkTarget {
        weak var view: VoiceArtCanvasView?
        init(_ view: VoiceArtCanvasView) { self.view = view }
        @objc func tick(_ link: CADisplayLink) { view?.tick(link) }
    }
}
