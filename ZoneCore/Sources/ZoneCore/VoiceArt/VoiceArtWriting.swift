// by zayd/cold @ zayd.wtf

import CoreGraphics
import Foundation

/// Fades whatever was drawn in the current transparency layer out toward the left edge, so a
/// scrolling graphic leaves the strip instead of being cut off by it.
func fadeLeftEdge(in context: CGContext, size: CGSize, over share: CGFloat = 0.16) {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let gradient = CGGradient(colorSpace: space, colorComponents: [0, 0, 0, 1, 0, 0, 0, 0], locations: [0, 1], count: 2) else { return }
    context.saveGState()
    context.setBlendMode(.destinationOut)
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width * share, y: 0), options: [])
    context.restoreGState()
}

/// Ink: a pen writing a line of script that is not any language. Each syllable is a letter's
/// loop, some with a tall stroke and some with a tail; a pause lifts the pen and leaves a word
/// gap; louder presses harder. The page feeds to the left as the line fills.
final class InkPainter: VoicePainter {
    private struct Point {
        var x: CGFloat
        var y: CGFloat
        var width: CGFloat
        var down: Bool
    }

    private var random: ArtRandom
    private var points: [Point] = []
    var pointCount: Int { points.count }
    private var pen: CGFloat = 0
    private var phase: CGFloat = 0
    private var reachUp: CGFloat = 1
    private var reachDown: CGFloat = 1
    private var up: CGFloat = 1
    private var down: CGFloat = 1
    private var writing = false
    private var scroll: CGFloat = 0
    private var level: CGFloat = 0
    private var tip = CGPoint.zero

    init(random: ArtRandom) { self.random = random }

    func step(_ voice: VoiceSignal, dt: CGFloat, size: CGSize) {
        let h = size.height
        let unit = h * 0.27
        level = CGFloat(voice.level)
        let voiced = voice.quiet == 0
        if voiced {
            if !writing {
                writing = true
                if !points.isEmpty { pen += h * 0.26 }
                phase = random.range(2.6, 3.6)
            }
            if voice.onset > 0 {
                let pick = random.unit()
                if pick < 0.24 {
                    reachUp = random.range(1.9, 2.3)
                    reachDown = random.range(0.7, 1)
                } else if pick < 0.38 {
                    reachUp = random.range(0.8, 1.1)
                    reachDown = random.range(1.7, 2.1)
                } else {
                    reachUp = random.range(0.75, 1.2)
                    reachDown = random.range(0.75, 1.1)
                }
            }
            let pace = CGFloat(min(voice.pace, 7))
            pen += h * (0.52 + 0.1 * pace) * dt
            phase += 2 * .pi * (1.5 + 0.34 * pace) * dt
            up += (reachUp - up) * (1 - exp(-dt / 0.07))
            down += (reachDown - down) * (1 - exp(-dt / 0.07))
            let swing = sin(phase)
            let press = 0.7 + 0.5 * level
            let middle = h * 0.62 - unit * 0.5
            let y = middle - swing * unit * 0.5 * (swing > 0 ? up : down) * press
            let x = pen + cos(phase) * unit * 0.42 + (middle - y) * 0.22
            // A nib: the stroke thins on the way up and swells on the way down.
            let nib = 0.6 + 0.55 * max(0, -cos(phase))
            let width = max(0.7, h / 48 * (1.0 + 2.6 * level) * nib)
            if startsWord || points.last.map({ hypot(x - $0.x, y - $0.y) >= 0.65 }) ?? true {
                points.append(Point(x: x, y: y, width: width, down: points.last.map { _ in !startsWord } ?? false))
            }
            startsWord = false
            tip = CGPoint(x: x, y: y)
        } else if writing, voice.quiet > 0.2 {
            writing = false
            startsWord = true
        }
        let target = max(0, pen + h * 0.3 - size.width * 0.84)
        scroll += (target - scroll) * (1 - exp(-dt / 0.18))
        if let first = points.first, first.x < scroll - 24, points.count > 2 {
            points.removeFirst(min(points.count - 2, points.firstIndex { $0.x >= scroll - 24 } ?? 0))
        }
    }

    private var startsWord = true

    func draw(in context: CGContext, size: CGSize, palette: VoiceArtPalette) {
        let h = size.height
        let left = h * 0.2
        // The ruled line the script sits on.
        context.stroke(palette.ink, 0.12)
        context.setLineWidth(0.5)
        context.line(from: CGPoint(x: 0, y: h * 0.62), to: CGPoint(x: size.width, y: h * 0.62))

        context.setAlpha(0.94)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setLineCap(.round)
        context.stroke(palette.ink)
        for index in points.indices.dropFirst() where points[index].down {
            let a = points[index - 1], b = points[index]
            context.setLineWidth((a.width + b.width) / 2)
            context.line(from: CGPoint(x: a.x - scroll + left, y: a.y), to: CGPoint(x: b.x - scroll + left, y: b.y))
        }
        context.fill(palette.ink)
        if points.isEmpty {
            context.dot(at: CGPoint(x: left, y: h * 0.62 - h * 0.13), radius: h * 0.04)
        } else if writing {
            // The wet edge catches the accent just before it dries into the ink stroke.
            context.fill(palette.ink.mixed(with: palette.accent, 0.55))
            context.dot(at: CGPoint(x: tip.x - scroll + left, y: tip.y), radius: h / 48 * (1.1 + 1.6 * level))
        }
        fadeLeftEdge(in: context, size: size)
        context.endTransparencyLayer()
        context.setAlpha(1)
    }
}

/// Glyphs: every syllable stamps a new character of an alphabet that does not exist, drawn
/// stroke by stroke on a small lattice. Pauses leave spaces, louder syllables are bolder, and a
/// block cursor waits at the end of the line.
final class GlyphPainter: VoicePainter {
    private struct Glyph {
        var x: CGFloat
        var strokes: [[CGPoint]]
        var length: CGFloat
        var born: Double
        var weight: CGFloat
    }

    private var random: ArtRandom
    private var glyphs: [Glyph] = []
    var glyphCount: Int { glyphs.count }
    private var cursor: CGFloat = 0
    private var scroll: CGFloat = 0
    private var time: Double = 0
    private var sinceGlyph: CGFloat = 1
    private var owesSpace = false
    private var level: CGFloat = 0
    private var voiced = false

    init(random: ArtRandom) { self.random = random }

    func step(_ voice: VoiceSignal, dt: CGFloat, size: CGSize) {
        let h = size.height
        time = voice.time
        level = CGFloat(voice.level)
        voiced = voice.isVoiced
        sinceGlyph += dt
        let advance = h * 0.44
        if voice.quiet > 0.32, !glyphs.isEmpty, !owesSpace {
            owesSpace = true
        }
        // A held vowel keeps writing: a syllable detector alone would stall on one long sound.
        let sustained = voice.quiet == 0 && voice.level > 0.2 && sinceGlyph > 0.34
        if voice.onset > 0 || sustained {
            if owesSpace {
                cursor += advance * 0.55
                owesSpace = false
            }
            let strength = voice.onset > 0 ? CGFloat(voice.onset) : 0.4
            glyphs.append(makeGlyph(at: cursor, weight: h / 48 * (1.05 + 1.25 * strength)))
            cursor += advance
            sinceGlyph = 0
        }
        let target = max(0, cursor + h * 0.5 - size.width * 0.88)
        scroll += (target - scroll) * (1 - exp(-dt / 0.14))
        if let first = glyphs.first, first.x < scroll - h, glyphs.count > 1 { glyphs.removeFirst() }
    }

    /// Strokes on a lattice 3 wide and 4 tall, as points in a unit square.
    private func makeGlyph(at x: CGFloat, weight: CGFloat) -> Glyph {
        var strokes: [[CGPoint]] = []
        var column = random.index(3), row = random.index(4)
        var used = Set<Int>()
        for _ in 0..<(2 + random.index(2)) {
            if random.chance(0.4) {
                column = random.index(3)
                row = random.index(4)
            }
            var stroke = [CGPoint(x: CGFloat(column) / 2, y: CGFloat(row) / 3)]
            var last = (0, 0)
            for _ in 0..<(1 + random.index(3)) {
                var step = (0, 0)
                for _ in 0..<8 {
                    let diagonal = random.chance(0.3)
                    let dx = random.index(3) - 1, dy = random.index(3) - 1
                    let candidate = diagonal ? (dx, dy) : (random.chance(0.5) ? (dx, 0) : (0, dy))
                    let nextColumn = column + candidate.0, nextRow = row + candidate.1
                    let edge = min(column, nextColumn) * 1000 + min(row, nextRow) * 100 + max(column, nextColumn) * 10 + max(row, nextRow)
                    if candidate != (0, 0), candidate != (-last.0, -last.1), (0...2).contains(nextColumn), (0...3).contains(nextRow), !used.contains(edge) {
                        step = candidate
                        used.insert(edge)
                        break
                    }
                }
                guard step != (0, 0) else { break }
                column += step.0
                row += step.1
                last = step
                stroke.append(CGPoint(x: CGFloat(column) / 2, y: CGFloat(row) / 3))
            }
            if stroke.count > 1 { strokes.append(stroke) }
        }
        if strokes.isEmpty { strokes = [[CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1)]] }
        if random.chance(0.28) {
            // A mark beside the character, like an accent.
            let y = random.chance(0.5) ? -0.2 : 1.2
            let x = random.range(0.2, 0.8)
            strokes.append([CGPoint(x: x - 0.14, y: y), CGPoint(x: x + 0.14, y: y)])
        }
        let length = strokes.reduce(CGFloat(0)) { total, stroke in
            total + zip(stroke, stroke.dropFirst()).reduce(CGFloat(0)) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        }
        return Glyph(x: x, strokes: strokes, length: max(length, 0.01), born: time, weight: weight)
    }

    func draw(in context: CGContext, size: CGSize, palette: VoiceArtPalette) {
        let h = size.height
        let cellWidth = h * 0.27, cellHeight = h * 0.46, top = h * 0.27, left = h * 0.2
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setLineCap(.square)
        context.setLineJoin(.miter)
        for glyph in glyphs {
            let age = time - glyph.born
            let shown = glyph.length * CGFloat(min(1, age / 0.2))
            let fresh = CGFloat(max(0, 1 - age / 0.9))
            let origin = CGPoint(x: glyph.x - scroll + left, y: top)
            for pass in 0..<2 {
                // The newest character glows while its ink is fresh.
                if pass == 0, fresh <= 0 { continue }
                context.stroke(palette.accent, pass == 0 ? 0.22 * fresh : 0.66 + 0.34 * fresh)
                context.setLineWidth(pass == 0 ? glyph.weight * 3.2 : glyph.weight)
                var left = shown
                for stroke in glyph.strokes {
                    guard left > 0 else { break }
                    context.move(to: CGPoint(x: origin.x + stroke[0].x * cellWidth, y: origin.y + stroke[0].y * cellHeight))
                    for (a, b) in zip(stroke, stroke.dropFirst()) {
                        let span = hypot(b.x - a.x, b.y - a.y)
                        let part = min(1, left / max(span, 0.001))
                        context.addLine(to: CGPoint(x: origin.x + (a.x + (b.x - a.x) * part) * cellWidth,
                                                    y: origin.y + (a.y + (b.y - a.y) * part) * cellHeight))
                        left -= span
                        if left <= 0 { break }
                    }
                    context.strokePath()
                }
            }
        }
        // The cursor: solid and as tall as the voice while it is heard, blinking while it is not.
        let blink = voiced ? 1 : (time.truncatingRemainder(dividingBy: 1) < 0.5 ? 0.85 : 0.15)
        let tall = cellHeight * (voiced ? 0.35 + 0.65 * min(1, level * 1.4) : 1)
        context.fill(palette.accent, blink)
        context.fill(CGRect(x: cursor - scroll + left, y: top + cellHeight - tall, width: cellWidth * 0.5, height: tall))
        fadeLeftEdge(in: context, size: size)
        context.endTransparencyLayer()
    }
}
