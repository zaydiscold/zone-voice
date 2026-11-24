// by zayd/cold @ zayd.wtf

import QuartzCore

final class MicRim {
    enum State { case ready, starting, listening, paused, writing }

    let layer = CALayer()
    private let orbit = CALayer()
    private let stencil = CALayer()
    private let rail = CALayer()
    private let lamps = (0..<3).map { _ in CAGradientLayer() }
    private let offsets = [0.13, 0.0, 0.025]
    private var state: State = .ready
    private var radius: CGFloat = 0
    private var glow = true
    private var still = true
    private var accents: [CGColor] = []
    private var needsStencil = true
    private var needsOrbit = true
    private var scale: CGFloat = 0
    private var maximumFPS = 0
    var needsLayout: Bool { needsStencil || needsOrbit }

    init() {
        orbit.beginTime = CACurrentMediaTime()
        orbit.allowsGroupOpacity = false
        layer.mask = stencil
        layer.addSublayer(rail)
        layer.addSublayer(orbit)
        for lamp in lamps {
            lamp.type = .radial
            lamp.startPoint = CGPoint(x: 0.5, y: 0.5)
            lamp.endPoint = CGPoint(x: 1, y: 1)
            lamp.locations = [0, 0.34, 1]
            orbit.addSublayer(lamp)
        }
    }

    func configure(state: State, level: Float, radius: CGFloat, glow: Bool, still: Bool, subtle: Bool,
                   accent: CGColor, companion: CGColor, peak: CGColor) {
        needsStencil = needsStencil || self.glow != glow || self.radius != radius
        needsOrbit = needsOrbit || self.radius != radius || self.still != still || (self.state == .listening) != (state == .listening)
        self.state = state
        self.radius = radius
        self.glow = glow
        self.still = still
        // Lift conversational levels above the noise floor so softer syllables have room to move.
        let signal = min(1, max(0, (level - 0.045) / 0.955))
        let energy = state == .listening && !still ? CGFloat(sqrt(signal)) : 0
        let strength: Float
        let speed: Float
        switch state {
        case .ready: (strength, speed) = (subtle ? 0.42 : 0.72, 0.63)
        case .starting: (strength, speed) = (0.89, 1.42)
        case .listening: (strength, speed) = (0.46 + 0.54 * Float(energy), 0.76 + 2.35 * Float(energy))
        case .paused: (strength, speed) = (0.31, 0)
        case .writing: (strength, speed) = (0.58, 0.47)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if accents != [accent, companion, peak] {
            accents = [accent, companion, peak]
            rail.backgroundColor = accent
            for (lamp, color) in zip(lamps, [companion, accent, peak]) {
                lamp.colors = [color, color.copy(alpha: 0.63)!, color.copy(alpha: 0)!]
            }
        }
        rail.opacity = state == .paused ? 0.30 : 0.12
        if still {
            orbit.removeAnimation(forKey: "opacity")
            for lamp in lamps { lamp.removeAnimation(forKey: "transform") }
        }
        let rate: Float = still ? 0 : speed
        if orbit.speed != rate {
            let now = layer.convertTime(CACurrentMediaTime(), from: nil)
            let local = orbit.convertTime(now, from: layer)
            orbit.beginTime = now
            orbit.timeOffset = local
            orbit.speed = rate
        }
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setDisableActions(still || layer.superlayer == nil)
        CATransaction.setAnimationDuration(state == .listening && strength < orbit.opacity ? 0.24 : 0.055)
        if orbit.opacity != strength { orbit.opacity = strength }
        // The trailing color opens more slowly than the bright tip and lingers between syllables.
        let wake = 0.85 + 1.30 * energy
        CATransaction.setAnimationDuration(wake < lamps[0].transform.m11 ? 0.34 : 0.12)
        if lamps[0].transform.m11 != wake { lamps[0].transform = CATransform3DMakeScale(wake, wake, 1) }
        let spread = 0.66 + 1.10 * energy
        CATransaction.setAnimationDuration(spread < lamps[2].transform.m11 ? 0.16 : 0.045)
        if lamps[2].transform.m11 != spread { lamps[2].transform = CATransform3DMakeScale(spread, spread, 1) }
        CATransaction.commit()
    }

    func layout(bounds: CGRect, scale: CGFloat, maximumFPS: Int) {
        guard bounds.width > 4, bounds.height > 4, scale > 0 else { return }
        let resized = layer.frame != bounds
        guard resized || needsOrbit || needsStencil || self.scale != scale || self.maximumFPS != maximumFPS else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = bounds
        let box = layer.bounds
        rail.frame = box
        orbit.frame = box
        stencil.frame = box
        let corner = min(radius, min(box.width, box.height) / 2)
        if needsStencil || self.scale != scale || resized {
            setStencil(radius: corner, scale: scale)
        }
        if needsOrbit || resized || self.maximumFPS != maximumFPS {
            let inset: CGFloat = 1.75
            let track = CGPath(roundedRect: box.insetBy(dx: inset, dy: inset), cornerWidth: max(0, corner - inset), cornerHeight: max(0, corner - inset), transform: nil)
            let span = min(240, max(96, box.width * 0.54))
            let diameters = [span * 0.96, span, span * 0.40]
            let rests = [CGPoint(x: box.width * 0.72, y: box.maxY - inset), CGPoint(x: box.width * 0.23, y: inset), CGPoint(x: box.width * 0.32, y: inset)]
            for (index, lamp) in lamps.enumerated() {
                lamp.bounds.size = CGSize(width: diameters[index], height: diameters[index])
                lamp.position = rests[index]
                if still {
                    lamp.removeAnimation(forKey: "orbit")
                } else {
                    let lap = CAKeyframeAnimation(keyPath: "position")
                    lap.path = track
                    lap.calculationMode = .paced
                    lap.duration = 6
                    lap.timeOffset = (offsets[index] + 0.18) * lap.duration
                    lap.beginTime = 1e-9
                    lap.repeatCount = .infinity
                    let fps = Float(state == .listening ? maximumFPS : min(30, maximumFPS))
                    lap.preferredFrameRateRange = CAFrameRateRange(minimum: min(30, fps), maximum: fps, preferred: fps)
                    lamp.add(lap, forKey: "orbit")
                }
            }
        }
        self.scale = scale
        self.maximumFPS = maximumFPS
        needsOrbit = false
        needsStencil = false
        CATransaction.commit()
    }

    private func setStencil(radius: CGFloat, scale: CGFloat) {
        let cap = Int(ceil((radius + 2) * scale))
        let pixels = 2 * cap + 1
        guard let bitmap = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        bitmap.scaleBy(x: scale, y: scale)
        let box = CGRect(x: 0, y: 0, width: CGFloat(pixels)/scale, height: CGFloat(pixels)/scale)
        func ring(_ inset: CGFloat, _ width: CGFloat, _ alpha: CGFloat) {
            let inner = max(0, radius - inset)
            bitmap.addPath(CGPath(roundedRect: box.insetBy(dx: inset, dy: inset), cornerWidth: inner, cornerHeight: inner, transform: nil))
            bitmap.setLineWidth(width)
            bitmap.setStrokeColor(red: 1, green: 1, blue: 1, alpha: alpha)
            bitmap.strokePath()
        }
        if glow {
            bitmap.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
            bitmap.clip()
            bitmap.saveGState()
            bitmap.setShadow(offset: .zero, blur: 4.5 * scale, color: CGColor(gray: 1, alpha: 0.95))
            ring(2.4, 2.4, 0.66)
            bitmap.restoreGState()
        }
        ring(1.45, glow ? 1.65 : 1.25, 1)
        guard let image = bitmap.makeImage() else { return }
        stencil.contents = image
        stencil.contentsScale = scale
        stencil.contentsCenter = CGRect(x: CGFloat(cap)/CGFloat(pixels), y: CGFloat(cap)/CGFloat(pixels), width: 1/CGFloat(pixels), height: 1/CGFloat(pixels))
    }
}
