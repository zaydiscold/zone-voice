// by zayd/cold @ zayd.wtf

import CoreText
import Metal
import QuartzCore
import SwiftUI
import UIKit
import ZoneCore

/// The numbers the shader draws one refresh from. Eight groups of four floats, in the order
/// `FlashUniforms` in `FlashArtShader` declares them.
struct FlashArtUniforms {
    /// The window's top left, its side and one module, in pixels.
    var portal = SIMD4<Float>(repeating: 0)
    /// Modules across the picture, pixels from the window's edge to the picture, the bezel
    /// around the window and its corner radius.
    var code = SIMD4<Float>(repeating: 0)
    /// Scene seconds, the flash's seed, how far through an interlude, pixels per point.
    var clock = SIMD4<Float>(repeating: 0)
    /// Presence, reveal, frame, fade (see the shader).
    var state = SIMD4<Float>(1, 1, 1, 1)
    /// Scene, next scene, the wipe between them, and 1 in a data slot.
    var scenes = SIMD4<Float>(repeating: 0)
    /// Width, height, where the top text ends and where the bottom text begins, in pixels.
    var screen = SIMD4<Float>(repeating: 0)
    var dark = SIMD4<Float>(0, 0, 0, 1)
    var light = SIMD4<Float>(1, 1, 1, 1)
}

/// Compiles the Flash shader and draws with it. One for the app, made the first time a color
/// Flash is opened; nil when this device cannot (the Flash screen then shows its plain look).
final class FlashArtRenderer: @unchecked Sendable {
    /// Made once, on whichever thread asks first. The guide asks from the background, so the
    /// compile (a few tenths of a second) is over before Start is tapped.
    static let shared: FlashArtRenderer? = FlashArtRenderer()

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let mark: MTLTexture
    /// The picture's textures, taken in turn. A refresh already handed to the GPU may still be
    /// reading the last one, and writing a texture the GPU is reading can show it half old and
    /// half new. The layer keeps at most three refreshes in flight and a picture is written at
    /// most once a refresh, so the texture written now was last read four refreshes ago, and
    /// that refresh has finished.
    private var codes: [MTLTexture] = []
    private var current = 0
    private static let codeTextures = 4

    private var code: MTLTexture? { codes.isEmpty ? nil : codes[current] }

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: FlashArtShader.source, options: nil),
              let vertex = library.makeFunction(name: "flashVertex"),
              let fragment = library.makeFunction(name: "flashFragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor),
              let mark = Self.wordmark(device) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.mark = mark
    }

    /// "zone" in the app's serif, white on black, for the opening and the ending.
    private static func wordmark(_ device: MTLDevice) -> MTLTexture? {
        let side = 512
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            let base = UIFont.systemFont(ofSize: 150, weight: .semibold)
            let font = base.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: 150) } ?? base
            let text = NSAttributedString(string: "zone", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): UIColor.white.cgColor,
                NSAttributedString.Key(kCTKernAttributeName as String): -2,
            ])
            let line = CTLineCreateWithAttributedString(text)
            let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            context.textPosition = CGPoint(x: (CGFloat(side) - bounds.width) / 2 - bounds.minX,
                                           y: (CGFloat(side) - bounds.height) / 2 - bounds.minY)
            CTLineDraw(line, context)
            return true
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: side, height: side, mipmapped: false)
        descriptor.usage = .shaderRead
        guard drawn, let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0, withBytes: pixels, bytesPerRow: side)
        return texture
    }

    /// The picture in the window: `side` by `side` modules, four bytes each, already in the
    /// palette's colors. The shader reads these bytes and never smooths them.
    func setCode(_ pixels: [UInt8], side: Int) {
        guard side > 0, pixels.count == side * side * 4 else { return }
        if codes.first?.width != side {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: side, height: side, mipmapped: false)
            descriptor.usage = .shaderRead
            codes = (0..<Self.codeTextures).compactMap { _ in device.makeTexture(descriptor: descriptor) }
            current = 0
            guard codes.count == Self.codeTextures else {
                codes = []
                return
            }
        } else {
            current = (current + 1) % codes.count
        }
        codes[current].replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0, withBytes: pixels, bytesPerRow: side * 4)
    }

    /// Draws one refresh and hands it to the screen.
    func draw(_ uniforms: FlashArtUniforms, to drawable: CAMetalDrawable) {
        guard let code else { return }
        var uniforms = uniforms
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FlashArtUniforms>.stride, index: 0)
        encoder.setFragmentTexture(code, index: 0)
        encoder.setFragmentTexture(mark, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

/// Full brightness and no sleep while the codes show; both go back to what they were when the
/// screen leaves, or when Zone leaves the foreground.
@MainActor
final class FlashScreenHold {
    private var raised = false
    private var brightnessBefore: CGFloat = 0.5
    private var idleTimerBefore = false
    private var observers: [NSObjectProtocol] = []
    /// The screen the view was last on, for restoring after it has left its window.
    private weak var screen: UIScreen?

    /// Starts following Zone in and out of the foreground. `current` gives the view's screen.
    func begin(_ current: @escaping @MainActor () -> UIScreen?) {
        if observers.isEmpty {
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.lower() }
                },
                center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.raise(current()) }
                },
            ]
        }
        if UIApplication.shared.applicationState == .active { raise(current()) }
    }

    func end() {
        lower()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    private func raise(_ screen: UIScreen?) {
        guard !raised, let screen else { return }
        raised = true
        self.screen = screen
        brightnessBefore = screen.brightness
        idleTimerBefore = UIApplication.shared.isIdleTimerDisabled
        screen.brightness = 1
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func lower() {
        guard raised else { return }
        raised = false
        screen?.brightness = brightnessBefore
        UIApplication.shared.isIdleTimerDisabled = idleTimerBefore
    }
}

struct FlashArtStage: UIViewRepresentable {
    let renderer: FlashArtRenderer
    let frames: FlashFrames
    let progress: FlashProgress
    /// Reduce Motion: the scene holds still, with no opening, interludes or ending.
    let calm: Bool
    /// The person tapped Done: the code resolves into the wordmark and waits there.
    let ending: Bool
    /// Screen points from the top that the text uses, and where the text at the bottom begins.
    let clearTop: CGFloat
    let clearBottom: CGFloat

    func makeUIView(context: Context) -> FlashArtStageUIView {
        let view = FlashArtStageUIView(renderer: renderer)
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: FlashArtStageUIView, context: Context) {
        view.configure(calm: calm, clearTop: clearTop, clearBottom: clearBottom)
        view.show(frames, progress: progress)
        view.setEnding(ending)
    }

    static func dismantleUIView(_ view: FlashArtStageUIView, coordinator: ()) {
        view.stop()
    }
}

/// The Flash screen in color: one generative scene over the whole screen, running at the
/// display's refresh rate, with the code as a pale window in it.
///
/// `LinkFlashSchedule.color` says what each twentieth of a second is. In a data slot the window
/// holds one picture, whole, for the full slot: three codes, one in each channel, in the
/// scene's palette. In an interlude the code dissolves into the scene, the scene shows through
/// the window, and the next code forms out of it. The flash opens on the wordmark, which turns
/// into the first code, and Done turns the code back into the wordmark. The scene's clock runs
/// through all of it. With Reduce Motion the scene is a still picture and only the code changes.
///
/// Which picture shows comes from the clock at the coming refresh, so a picture changes in one
/// refresh and a dropped refresh never slows the flash down.
final class FlashArtStageUIView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metal: CAMetalLayer { layer as! CAMetalLayer }

    private let renderer: FlashArtRenderer
    private let track = CALayer()
    private let fill = CALayer()
    private let hold = FlashScreenHold()
    private var frames: FlashFrames?
    private weak var progress: FlashProgress?
    private var link: CADisplayLink?
    private var schedule = LinkFlashSchedule.dataOnly
    private var rate = LinkFlashFormat.framesPerSecond
    /// When slot 0 of the schedule began, and whether that has been set.
    private var started: CFTimeInterval = 0
    private var clockSet = false
    /// When the scene's own clock began. It is never set back.
    private var sceneStarted: CFTimeInterval = 0
    private var sceneSet = false
    private var opening = LinkFlashScene.dusk
    /// The codes on screen replaced others: they begin with data, not the opening.
    private var skipsOpening = false
    private var seed: Float = 0
    private var calm = false
    private var clearTop: CGFloat = 0
    private var clearBottom: CGFloat = 0
    private var modules = 103
    private var geometry = FlashArtUniforms()
    /// The data picture in the window (counting on through every pass) and the scene it is colored for.
    private var shownData = 0
    private var uploaded: (picture: Int, scene: LinkFlashScene)?
    private var finish = Finish.none
    /// What the last refresh drew, so an ending can start from wherever the screen was.
    private var last = FlashArtUniforms()

    private enum Finish {
        case none
        /// Done was tapped at this time, with the window in this state (presence, reveal, frame, fade).
        case ending(at: CFTimeInterval, from: SIMD4<Float>)
        /// "Keep showing": the wordmark is turning back into the code.
        case resuming(at: CFTimeInterval)
    }

    /// Seconds for the wordmark to turn back into the code after "Keep showing".
    private static let resumeSeconds = 0.45
    /// The moment of the scene a still picture shows (Reduce Motion).
    private static let calmTime = 6.0

    init(renderer: FlashArtRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        isOpaque = true
        backgroundColor = .black
        metal.device = renderer.device
        metal.pixelFormat = .bgra8Unorm
        metal.framebufferOnly = true
        // The display's own space: a level written to one channel lights that subpixel and no other.
        metal.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        metal.isOpaque = true
        track.backgroundColor = UIColor(white: 1, alpha: 0.16).cgColor
        fill.backgroundColor = UIColor(white: 1, alpha: 0.92).cgColor
        for line in [track, fill] {
            line.cornerRadius = 1.5
            line.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "backgroundColor": NSNull()]
            layer.addSublayer(line)
        }
        isAccessibilityElement = true
        accessibilityTraits = .image
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(calm: Bool, clearTop: CGFloat, clearBottom: CGFloat) {
        if calm != self.calm {
            self.calm = calm
            updateSchedule()
        }
        if clearTop != self.clearTop || clearBottom != self.clearBottom {
            self.clearTop = clearTop
            self.clearBottom = clearBottom
            setNeedsLayout()
        }
    }

    func show(_ next: FlashFrames, progress: FlashProgress) {
        self.progress = progress
        guard frames !== next else { return }
        // Codes made again while showing (the library changed) carry on in the scene on screen,
        // straight into data, with no second opening: the screen does not start over.
        let continuing = frames != nil
        if continuing {
            opening = scene(forData: shownData)
        } else {
            opening = Self.forcedScene ?? LinkFlashScene(session: next.plan.encoder.session)
            // A number from the session that the scenes vary themselves by.
            seed = Float((next.plan.encoder.session >> 8) & 0xFFFF) / 65_535
        }
        skipsOpening = continuing
        frames = next
        rate = max(1, next.plan.framesPerSecond)
        clockSet = false
        uploaded = nil
        shownData = 0
        finish = .none
        updateSchedule()
        upload(data: 0, scene: scene(forData: 0))
        progress.playhead = LinkFlashPlayhead(elapsed: 0, cycleLength: next.cycleLength, framesPerSecond: rate)
        setNeedsLayout()
        if window != nil { run() }
    }

    /// Done plays the ending; "Keep showing" turns the wordmark back into the code. With
    /// Reduce Motion neither happens and the codes simply keep showing.
    func setEnding(_ ending: Bool) {
        guard !calm else { return }
        switch (finish, ending) {
        case (.none, true), (.resuming, true):
            finish = .ending(at: CACurrentMediaTime(), from: last.state)
        case (.ending, false):
            finish = .resuming(at: CACurrentMediaTime())
        default:
            break
        }
    }

    private func updateSchedule() {
        let next: LinkFlashSchedule = calm ? .dataOnly : .color
        guard next != schedule else { return }
        schedule = next
        // The clock counts slots of this schedule: start it again so nothing is skipped.
        clockSet = false
        finish = .none
    }

    #if DEBUG
    /// `-zoneLinkFlashScene dusk` (or `aurora`, `ember`): that scene throughout, for recordings.
    private static var forcedScene: LinkFlashScene? {
        UserDefaults.standard.string(forKey: "zoneLinkFlashScene").flatMap { LinkFlashScene(named: $0) }
    }
    #else
    private static var forcedScene: LinkFlashScene? { nil }
    #endif

    /// The scene data picture `index` plays in: the opening scene, then the next with each act.
    private func scene(forData index: Int) -> LinkFlashScene {
        if let forced = Self.forcedScene { return forced }
        return opening.act(schedule.act(ofData: index))
    }

    func stop() {
        link?.invalidate()
        link = nil
        hold.end()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stop()
        } else {
            run()
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        // Leaving: restore while the window is still known.
        if newWindow == nil { hold.lower() }
    }

    private func run() {
        guard frames != nil else { return }
        hold.begin { [weak self] in self?.window?.windowScene?.screen }
        guard link == nil else { return }
        let link = CADisplayLink(target: FlashArtTick(self), selector: #selector(FlashArtTick.tick(_:)))
        // Every refresh the display has: the scene moves on each one, and a picture changes on one.
        let fastest = Float(window?.windowScene?.screen.maximumFramesPerSecond ?? 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: max(60, fastest), preferred: max(60, fastest))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Puts data picture `index`, in `scene`'s palette, in the window's texture.
    private func upload(data index: Int, scene: LinkFlashScene) {
        guard let frames else { return }
        let picture = index % max(1, frames.cycleLength)
        shownData = index
        guard uploaded?.picture != picture || uploaded?.scene != scene else { return }
        guard let image = frames.picture(picture)?.image, var pixels = LinkFlashColor.pixels(image) else { return }
        scene.palette.recolor(&pixels)
        renderer.setCode(pixels, side: image.width)
        uploaded = (picture, scene)
        if image.width != modules {
            modules = image.width
            setNeedsLayout()
            layoutIfNeeded()
        }
        frames.prepare(after: picture)
    }

    /// `shownAt` is when the coming screen refresh appears (the display link's target time).
    fileprivate func tick(shownAt: CFTimeInterval) {
        guard let frames, bounds.width > 0, bounds.height > 0 else { return }
        if !sceneSet {
            sceneStarted = shownAt
            sceneSet = true
        }
        if !clockSet {
            // Codes made again start at their first data slot, not with the opening.
            started = shownAt - (skipsOpening ? Double(schedule.slotIndex(ofData: 0)) / Double(rate) : 0)
            clockSet = true
        }
        var uniforms = geometry
        var scene = scene(forData: shownData)
        var next = scene
        var wipe = 0.0, beat = 0.0, exact = false
        var presence = 1.0, reveal = 1.0, frame = 1.0, fade = 1.0

        if case .resuming(let at) = finish, (shownAt - at) / Self.resumeSeconds >= 1 {
            // Data picks up at the picture it stopped on, in a slot that starts with this refresh.
            finish = .none
            started = shownAt - Double(schedule.slotIndex(ofData: shownData)) / Double(rate)
        }
        switch finish {
        case .ending(let at, let from):
            let through = min(max((shownAt - at) / LinkFlashSchedule.endingSeconds, 0), 1)
            // Whatever the window was doing settles first, then the code turns into the wordmark.
            let settle = LinkFlashSchedule.ease(through / 0.3)
            func settled(_ value: Float) -> Double { Double(value) + (1 - Double(value)) * settle }
            presence = settled(from.x)
            frame = settled(from.z)
            fade = settled(from.w)
            reveal = Double(from.y) * (1 - LinkFlashSchedule.ease((through - 0.2) / 0.8))
        case .resuming(let at):
            reveal = LinkFlashSchedule.ease((shownAt - at) / Self.resumeSeconds)
        case .none:
            // Slots of the schedule, `rate` a second. A thousandth of a slot of slack, so a boundary
            // that lands exactly on a refresh is not lost to rounding.
            let slots = (shownAt - started) * Double(rate) + 0.001
            let slotIndex = Int(min(max(0, slots), 1e15))
            let within = slots - Double(slotIndex)
            switch schedule.slot(slotIndex) {
            case .opening(let step):
                let through = (Double(step) + within) / Double(max(1, schedule.openingPictures))
                fade = LinkFlashSchedule.ease(through / 0.22)
                frame = LinkFlashSchedule.ease((through - 0.04) / 0.26)
                reveal = LinkFlashSchedule.openingReveal(through: through)
                scene = self.scene(forData: 0)
                next = scene
                upload(data: 0, scene: scene)
            case .data(let index):
                scene = self.scene(forData: index)
                next = scene
                exact = true
                let playhead = LinkFlashPlayhead(elapsed: (Double(index) + 0.5) / Double(rate), cycleLength: frames.cycleLength,
                                                 framesPerSecond: rate)
                upload(data: index, scene: scene)
                if progress?.playhead != playhead {
                    progress?.playhead = playhead
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    fill.frame.size.width = track.frame.width * CGFloat(playhead.frame + 1) / CGFloat(max(1, playhead.cycleLength))
                    CATransaction.commit()
                }
            case .art(let interlude, let step):
                let through = (Double(step) + within) / Double(max(1, schedule.artPictures))
                let before = (interlude + 1) * schedule.dataPictures - 1
                scene = self.scene(forData: before)
                next = self.scene(forData: before + 1)
                presence = LinkFlashSchedule.codePresence(through: through)
                // The pale frame goes first and comes back last, so the window never turns into a
                // bright empty panel between the code and the scene: its brightness moves one way,
                // from the code's to the scene's, instead of popping up on the way.
                frame = LinkFlashSchedule.ease((presence - 0.5) / 0.5)
                beat = max(through, 0.0001)
                if next != scene { wipe = LinkFlashSchedule.ease((through - 0.15) / 0.7) }
                // The first half is the last picture leaving; the second, the next one arriving.
                if LinkFlashSchedule.showsNextPicture(through: through) {
                    upload(data: before + 1, scene: next)
                } else {
                    upload(data: before, scene: scene)
                }
            }
        }

        // The window's own colors follow the picture in it; the scene behind may be mid-change.
        let palette = (uploaded?.scene ?? scene).palette
        uniforms.dark = SIMD4(Float(palette.dark[0]) / 255, Float(palette.dark[1]) / 255, Float(palette.dark[2]) / 255, 1)
        uniforms.light = SIMD4(Float(palette.light[0]) / 255, Float(palette.light[1]) / 255, Float(palette.light[2]) / 255, 1)
        uniforms.clock = SIMD4(Float(calm ? Self.calmTime : shownAt - sceneStarted), seed, Float(beat), geometry.clock.w)
        uniforms.state = SIMD4(Float(presence), Float(reveal), Float(frame), Float(fade))
        uniforms.scenes = SIMD4(Float(scene.rawValue), Float(next.rawValue), Float(wipe), exact ? 1 : 0)
        last = uniforms
        guard let drawable = metal.nextDrawable() else { return }
        renderer.draw(uniforms, to: drawable)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let pixels = { (points: CGFloat) in Int((points * scale).rounded()) }
        let width = pixels(bounds.width), height = pixels(bounds.height)
        guard width > 0, height > 0 else { return }
        let layout = LinkFlashLayout(width: width, height: height, top: pixels(clearTop),
                                     bottom: max(0, pixels(bounds.height - clearBottom)), modules: modules, minimumArt: pixels(12))
        metal.contentsScale = scale
        metal.drawableSize = CGSize(width: width, height: height)

        // A pale bezel around the quiet zone, as wide as the side margins allow, with rounded
        // corners that stay outside the quiet zone's square.
        let module = Float(layout.module)
        let bezel = min(Float(layout.portalMargin(width: width)) * 0.6, 0.9 * module)
        let corner = min(2.2 * module, bezel * 3.4)
        geometry.portal = SIMD4(Float(layout.portalX), Float(layout.bandY), Float(layout.portalSide), module)
        geometry.code = SIMD4(Float(modules), Float(layout.codeX - layout.portalX), bezel, corner)
        geometry.clock.w = Float(scale)
        geometry.screen = SIMD4(Float(width), Float(height), Float(pixels(clearTop)), Float(pixels(clearBottom)))

        let point = { (pixels: Int) in CGFloat(pixels) / scale }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let lineY = point(layout.bandY + layout.portalSide) + CGFloat(bezel) / scale + 12
        track.frame = CGRect(x: point(layout.portalX), y: lineY, width: point(layout.portalSide), height: 3)
        let done = progress?.playhead.map { CGFloat($0.frame + 1) / CGFloat(max(1, $0.cycleLength)) } ?? 0
        fill.frame = CGRect(x: track.frame.minX, y: lineY, width: track.frame.width * done, height: 3)
        CATransaction.commit()
    }
}

/// A display link keeps its target alive. This holds the view weakly so the view can go.
@MainActor
private final class FlashArtTick: NSObject {
    private weak var view: FlashArtStageUIView?
    init(_ view: FlashArtStageUIView) { self.view = view }
    @objc func tick(_ link: CADisplayLink) { view?.tick(shownAt: link.targetTimestamp) }
}
