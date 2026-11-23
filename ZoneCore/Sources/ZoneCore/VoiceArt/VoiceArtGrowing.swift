// by zayd/cold @ zayd.wtf

import CoreGraphics
import Foundation

/// Branch: a bough grows across the strip while the person talks. Every syllable puts out a
/// twig and a leaf. In a pause it is autumn: the leaves let go one at a time and drift down.
final class BranchPainter: VoicePainter {
    private struct Twig {
        var base: CGPoint
        var angle: CGFloat
        var length: CGFloat
        var grown: CGFloat = 0
    }

    private struct Leaf {
        var position: CGPoint
        var angle: CGFloat
        var size: CGFloat
        var tone: Int
        var grown: CGFloat = 0
        var falling = false
        var velocity = CGPoint.zero
        var spin: CGFloat = 0
        var sway: CGFloat = 0
    }

    private static let dark = [ArtColor(0.95, 0.66, 0.20), ArtColor(0.88, 0.40, 0.17), ArtColor(0.78, 0.24, 0.22),
                               ArtColor(0.97, 0.82, 0.36), ArtColor(0.62, 0.66, 0.30)]
    private static let light = [ArtColor(0.80, 0.50, 0.08), ArtColor(0.74, 0.30, 0.10), ArtColor(0.62, 0.15, 0.15),
                                ArtColor(0.76, 0.58, 0.10), ArtColor(0.40, 0.46, 0.16)]

    private var random: ArtRandom
    private var stem: [CGPoint] = []
    private var heading: CGFloat = 0
    private var twigs: [Twig] = []
    private var leaves: [Leaf] = []
    private var side: CGFloat = -1
    private var scroll: CGFloat = 0
    private var sinceDrop: CGFloat = 0
    private var sinceTwig: CGFloat = 0
    private var time: CGFloat = 0

    init(random: ArtRandom) { self.random = random }

    func step(_ voice: VoiceSignal, dt: CGFloat, size: CGSize) {
        let h = size.height
        time += dt
        if stem.isEmpty { stem = [CGPoint(x: -h * 0.2, y: h * 0.6), CGPoint(x: 0, y: h * 0.58)] }
        sinceTwig += dt
        if voice.quiet < 0.2, voice.level > 0.05, var tip = stem.last {
            let speed = h * (0.34 + 0.08 * CGFloat(min(voice.pace, 7)))
            heading += random.bell() * 2.4 * dt
            // The bough stays in the strip: it bends back toward the middle as it nears an edge.
            heading += ((h * 0.55 - tip.y) / h * 1.6 - heading) * min(1, dt * 2.2)
            heading = min(max(heading, -0.55), 0.55)
            tip.x += cos(heading) * speed * dt
            tip.y += sin(heading) * speed * dt
            if let last = stem.last, hypot(tip.x - last.x, tip.y - last.y) > 1.5 { stem.append(tip) } else { stem[stem.count - 1] = tip }
            if voice.onset > 0 || (voice.level > 0.2 && sinceTwig > 0.4) {
                sinceTwig = 0
                side = -side
                let strength = voice.onset > 0 ? CGFloat(voice.onset) : 0.45
                let angle = heading + side * random.range(0.65, 1.15)
                let length = h * random.range(0.14, 0.26) * (0.6 + 0.6 * strength)
                twigs.append(Twig(base: tip, angle: angle, length: length))
                let end = CGPoint(x: tip.x + cos(angle) * length, y: tip.y + sin(angle) * length)
                leaves.append(Leaf(position: end, angle: angle + random.range(-0.5, 0.5), size: h * random.range(0.16, 0.25), tone: random.index(5)))
                if random.chance(0.45) {
                    let mid = CGPoint(x: tip.x + cos(angle) * length * 0.55, y: tip.y + sin(angle) * length * 0.55)
                    leaves.append(Leaf(position: mid, angle: angle - side * random.range(0.7, 1.2), size: h * random.range(0.1, 0.15), tone: random.index(5)))
                }
            }
        }
        for index in twigs.indices { twigs[index].grown = min(1, twigs[index].grown + dt / 0.3) }
        sinceDrop += dt
        if voice.quiet > 0.7, sinceDrop > 0.22, let index = leaves.firstIndex(where: { !$0.falling && $0.grown >= 1 }) {
            sinceDrop = 0
            // Not always the oldest: the wind picks.
            let attached = leaves.indices.filter { !leaves[$0].falling && leaves[$0].grown >= 1 }
            let pick = random.chance(0.5) ? index : attached[random.index(attached.count)]
            leaves[pick].falling = true
            leaves[pick].spin = random.range(-3, 3)
            leaves[pick].sway = random.range(0, 6)
        }
        for index in leaves.indices {
            if leaves[index].falling {
                leaves[index].velocity.y = min(h * 0.55, leaves[index].velocity.y + h * 1.1 * dt)
                leaves[index].position.y += leaves[index].velocity.y * dt
                leaves[index].position.x += sin(time * 3.1 + leaves[index].sway) * h * 0.22 * dt - h * 0.06 * dt
                leaves[index].angle += leaves[index].spin * dt
            } else {
                leaves[index].grown = min(1, leaves[index].grown + dt / 0.45)
            }
        }
        leaves.removeAll { $0.position.y > h + $0.size || $0.position.x < scroll - h }
        twigs.removeAll { $0.base.x < scroll - h }
        let target = max(0, (stem.last?.x ?? 0) - size.width * 0.8)
        scroll += (target - scroll) * (1 - exp(-dt / 0.2))
        if stem.count > 3, let keep = stem.firstIndex(where: { $0.x >= scroll - h }), keep > 1 { stem.removeFirst(keep - 1) }
    }

    func draw(in context: CGContext, size: CGSize, palette: VoiceArtPalette) {
        let h = size.height
        let tones = palette.isDark ? Self.dark : Self.light
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.translateBy(x: -scroll, y: 0)
        context.setLineCap(.round)
        context.stroke(palette.ink, 0.82)
        if let tip = stem.last {
            for index in stem.indices.dropFirst() {
                // Thick where it is old, fine at the growing tip.
                context.setLineWidth(min(h * 0.075, h * 0.02 + (tip.x - stem[index].x) * 0.006))
                context.line(from: stem[index - 1], to: stem[index])
            }
        }
        context.setLineWidth(max(0.8, h * 0.02))
        for twig in twigs {
            let reach = twig.length * twig.grown
            context.line(from: twig.base, to: CGPoint(x: twig.base.x + cos(twig.angle) * reach, y: twig.base.y + sin(twig.angle) * reach))
        }
        for leaf in leaves where leaf.grown > 0.02 {
            let length = leaf.size * leaf.grown
            let fade = leaf.falling ? max(0, 1 - max(0, leaf.position.y - h * 0.72) / (h * 0.3)) : 1
            context.saveGState()
            context.translateBy(x: leaf.position.x, y: leaf.position.y)
            context.rotate(by: leaf.angle)
            context.move(to: .zero)
            context.addQuadCurve(to: CGPoint(x: length, y: 0), control: CGPoint(x: length * 0.5, y: -length * 0.42))
            context.addQuadCurve(to: .zero, control: CGPoint(x: length * 0.5, y: length * 0.42))
            context.fill(tones[leaf.tone], 0.95 * fade)
            context.fillPath()
            context.stroke(palette.isDark ? ArtColor(0, 0, 0) : ArtColor(1, 1, 1), 0.28 * fade)
            context.setLineWidth(0.5)
            context.line(from: .zero, to: CGPoint(x: length * 0.9, y: 0))
            context.restoreGState()
        }
        context.translateBy(x: scroll, y: 0)
        fadeLeftEdge(in: context, size: size)
        context.endTransparencyLayer()
    }
}

/// Inkblot: a card of wet ink, mirrored down the middle. Each syllable drops ink on one side
/// and its twin on the other; drops bleed into each other, then dry and fade, so the blot never
/// stops changing and is never the same blot twice.
final class InkblotPainter: VoicePainter {
    private struct Drop {
        var offset: CGFloat
        var y: CGFloat
        var radius: CGFloat = 0
        var target: CGFloat
        var age: CGFloat = 0
        var wobble: [CGFloat]
    }

    private var random: ArtRandom
    private var drops: [Drop] = []
    private var level: CGFloat = 0
    private var sinceDrop: CGFloat = 0
    private static let life: CGFloat = 3.2

    init(random: ArtRandom) { self.random = random }

    func step(_ voice: VoiceSignal, dt: CGFloat, size: CGSize) {
        let h = size.height
        level += (CGFloat(voice.level) - level) * (1 - exp(-dt / 0.08))
        sinceDrop += dt
        if voice.onset > 0 || (voice.level > 0.2 && sinceDrop > 0.45) {
            sinceDrop = 0
            let strength = voice.onset > 0 ? CGFloat(voice.onset) : 0.4
            // Ink spreads out from the fold the longer and louder the phrase runs.
            let spread = size.width * 0.5 * (0.45 + 0.5 * CGFloat(voice.energy))
            let offset = abs(random.bell()) * spread
            drops.append(Drop(offset: offset, y: h * (0.5 + random.bell() * 0.3), target: h * random.range(0.07, 0.17) * (0.55 + 0.7 * strength),
                              wobble: (0..<9).map { _ in random.range(0.78, 1.18) }))
            if random.chance(0.5) {
                // A spatter thrown clear of the drop.
                drops.append(Drop(offset: offset + random.range(-1, 1) * h * 0.5, y: h * random.range(0.15, 0.85),
                                  target: h * random.range(0.025, 0.06), wobble: (0..<9).map { _ in random.range(0.85, 1.12) }))
            }
        }
        for index in drops.indices {
            drops[index].age += dt
            let target = drops[index].target * (1 + drops[index].age * 0.07)
            drops[index].radius += (target - drops[index].radius) * (1 - exp(-dt / 0.12))
        }
        drops.removeAll { $0.age > Self.life }
    }

    func draw(in context: CGContext, size: CGSize, palette: VoiceArtPalette) {
        let h = size.height, middle = size.width / 2
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        for pass in 0..<2 {
            // First the pale bleed around each drop, then the dense ink.
            for drop in drops {
                let dry = min(1, max(0, (Self.life - drop.age) / 2.2))
                context.fill(palette.ink, (pass == 0 ? 0.2 : 0.88) * dry)
                for sign in [CGFloat(-1), 1] {
                    blob(in: context, center: CGPoint(x: middle + sign * drop.offset, y: drop.y),
                         radius: drop.radius * (pass == 0 ? 1.4 : 1) * (0.55 + 0.45 * dry), wobble: drop.wobble, mirrored: sign < 0)
                }
            }
            // The fold: a seam of ink that breathes with the voice.
            context.fill(palette.ink, pass == 0 ? 0.2 : 0.88)
            let half = h * (0.07 + 0.36 * level) * (pass == 0 ? 1.25 : 1)
            let wide = h * (0.035 + 0.1 * level) * (pass == 0 ? 1.5 : 1)
            context.fillEllipse(in: CGRect(x: middle - wide, y: h / 2 - half, width: wide * 2, height: half * 2))
        }
        context.endTransparencyLayer()
    }

    private func blob(in context: CGContext, center: CGPoint, radius: CGFloat, wobble: [CGFloat], mirrored: Bool) {
        guard radius > 0.2 else { return }
        let count = wobble.count
        func point(_ index: Int) -> CGPoint {
            let angle = CGFloat(index) / CGFloat(count) * 2 * .pi
            let reach = radius * wobble[(index % count + count) % count]
            return CGPoint(x: center.x + (mirrored ? -1 : 1) * cos(angle) * reach, y: center.y + sin(angle) * reach)
        }
        func between(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        context.move(to: between(point(count - 1), point(0)))
        for index in 0..<count { context.addQuadCurve(to: between(point(index), point(index + 1)), control: point(index)) }
        context.fillPath()
    }
}
