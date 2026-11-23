// by zayd/cold @ zayd.wtf

import CoreGraphics
import Foundation

/// Lanes: the voice played as notes. Four lanes run toward a strike line on the right; each
/// syllable is a note in the lane its loudness earned (quiet at the bottom, loud at the top),
/// as long as the sound was held. The strike line flashes when a note lands.
final class LanesPainter: VoicePainter {
    private struct Note {
        var lane: Int
        var start: CGFloat
        var end: CGFloat?
        var strength: CGFloat
    }

    private static let dark = [ArtColor(0.33, 0.90, 0.52), ArtColor(0.24, 0.84, 0.94), ArtColor(0.99, 0.82, 0.26), ArtColor(0.98, 0.36, 0.70)]
    private static let light = [ArtColor(0.10, 0.60, 0.28), ArtColor(0.04, 0.50, 0.68), ArtColor(0.78, 0.54, 0.02), ArtColor(0.82, 0.14, 0.48)]

    private var random: ArtRandom
    private var notes: [Note] = []
    private var time: CGFloat = 0
    private var flash: [CGFloat] = [0, 0, 0, 0]
    private var lastLane = 1

    init(random: ArtRandom) { self.random = random }

    func step(_ voice: VoiceSignal, dt: CGFloat, size: CGSize) {
        time += dt
        for lane in 0..<4 { flash[lane] = max(0, flash[lane] - dt / 0.28) }
        let open = notes.indices.last.flatMap { notes[$0].end == nil ? $0 : nil }
        let held = open.map { time - notes[$0].start } ?? 0
        if voice.onset > 0 || (open == nil && voice.level > 0.22) || held > 0.55 && voice.level > 0.2 {
            if let open { notes[open].end = time - 0.035 }
            var lane = min(3, Int(voice.contour * 4))
            // The same lane four times running reads as a stuck meter, so a repeat may step aside.
            if lane == lastLane, random.chance(0.35) { lane = min(3, max(0, lane + (random.chance(0.5) ? 1 : -1))) }
            lastLane = lane
            notes.append(Note(lane: lane, start: time, end: nil, strength: voice.onset > 0 ? CGFloat(voice.onset) : 0.4))
            flash[lane] = 1
        } else if let open, voice.level < 0.1 || voice.quiet > 0.08 {
            notes[open].end = time
        }
        let speed = size.height * 1.5
        notes.removeAll { note in (note.end.map { (time - $0) * speed > size.width + 20 }) ?? false }
    }

    func draw(in context: CGContext, size: CGSize, palette: VoiceArtPalette) {
        let h = size.height, speed = h * 1.5
        let tones = palette.isDark ? Self.dark : Self.light
        let strike = size.width - h * 0.3
        let laneHeight = h / 4
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setLineWidth(0.5)
        for lane in 0..<4 {
            let y = h - (CGFloat(lane) + 0.5) * laneHeight
            context.stroke(tones[lane], 0.16)
            context.line(from: CGPoint(x: 0, y: y), to: CGPoint(x: strike, y: y))
        }
        for note in notes {
            let y = h - (CGFloat(note.lane) + 0.5) * laneHeight
            let thick = laneHeight * (0.46 + 0.22 * note.strength)
            let left = strike - (time - note.start) * speed
            let right = strike - (time - (note.end ?? time)) * speed
            let rect = CGRect(x: left - thick / 2, y: y - thick / 2, width: max(thick, right - left + thick), height: thick)
            context.fill(tones[note.lane], 0.92)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: thick / 2, cornerHeight: thick / 2, transform: nil))
            context.fillPath()
            // The head of the note: a lighter gem at the end that was struck first.
            context.fill(ArtColor(1, 1, 1), palette.isDark ? 0.55 : 0.7)
            context.dot(at: CGPoint(x: left, y: y), radius: thick * 0.22)
        }
        fadeLeftEdge(in: context, size: size, over: 0.2)
        for lane in 0..<4 {
            let y = h - (CGFloat(lane) + 0.5) * laneHeight
            let hit = flash[lane]
            context.stroke(tones[lane], 0.5 + 0.5 * hit)
            context.setLineWidth(1.2 + 1.4 * hit)
            let radius = laneHeight * (0.3 + 0.16 * hit)
            context.strokeEllipse(in: CGRect(x: strike - radius, y: y - radius, width: radius * 2, height: radius * 2))
            if hit > 0 {
                context.fill(tones[lane], 0.5 * hit)
                context.dot(at: CGPoint(x: strike, y: y), radius: radius * 0.8)
            }
        }
        context.endTransparencyLayer()
    }
}

/// Stars: a phrase becomes a constellation. Each syllable is a star, higher when the voice
/// rises and bigger when it lands harder, joined to the one before it. A pause finishes the
/// figure and the next phrase starts another further along the sky.
final class StarsPainter: VoicePainter {
    private struct Star {
        var position: CGPoint
        var size: CGFloat
        var joined: Bool
        var born: CGFloat
        var twinkle: CGFloat
    }

    private var random: ArtRandom
    private var stars: [Star] = []
    private var dust: [CGPoint] = []
    private var x: CGFloat = 0
    private var scroll: CGFloat = 0
    private var time: CGFloat = 0
    private var phraseOpen = false
    private var sinceStar: CGFloat = 0

    init(random: ArtRandom) { self.random = random }

    func step(_ voice: VoiceSignal, dt: CGFloat, size: CGSize) {
        let h = size.height
        time += dt
        sinceStar += dt
        if dust.isEmpty { dust = (0..<26).map { _ in CGPoint(x: random.unit(), y: random.unit()) } }
        if voice.quiet < 0.2, voice.level > 0.05 { x += h * (0.42 + 0.1 * CGFloat(min(voice.pace, 7))) * dt }
        if voice.quiet > 0.4, phraseOpen {
            phraseOpen = false
            x += h * 0.5
        }
        if voice.onset > 0 || (voice.level > 0.2 && sinceStar > 0.42) {
            sinceStar = 0
            let strength = voice.onset > 0 ? CGFloat(voice.onset) : 0.35
            let y = h * (0.82 - 0.64 * CGFloat(voice.contour)) + random.bell() * h * 0.07
            stars.append(Star(position: CGPoint(x: x, y: min(h * 0.9, max(h * 0.1, y))), size: h / 48 * (1.3 + 2.4 * strength),
                              joined: phraseOpen, born: time, twinkle: random.range(0, 6)))
            phraseOpen = true
        }
        let target = max(0, x - size.width * 0.8)
        scroll += (target - scroll) * (1 - exp(-dt / 0.25))
        if stars.count > 2, let keep = stars.firstIndex(where: { $0.position.x >= scroll - h }), keep > 1 { stars.removeFirst(keep - 1) }
    }

    func draw(in context: CGContext, size: CGSize, palette: VoiceArtPalette) {
        let h = size.height, left = h * 0.25
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        // Far dust drifts at a fifth of the sky's speed.
        context.fill(palette.ink, 0.22)
        for speck in dust {
            let span = size.width + 20
            var sx = (speck.x * span - scroll * 0.2).truncatingRemainder(dividingBy: span)
            if sx < 0 { sx += span }
            context.dot(at: CGPoint(x: sx - 10, y: speck.y * h), radius: 0.5 + speck.y * 0.4)
        }
        context.setLineCap(.round)
        for index in stars.indices.dropFirst() where stars[index].joined {
            let a = stars[index - 1], b = stars[index]
            let drawn = min(1, (time - b.born) / 0.22)
            context.stroke(palette.accent, 0.5)
            context.setLineWidth(max(0.6, h / 48 * 0.8))
            context.line(from: CGPoint(x: a.position.x - scroll + left, y: a.position.y),
                         to: CGPoint(x: a.position.x + (b.position.x - a.position.x) * drawn - scroll + left,
                                     y: a.position.y + (b.position.y - a.position.y) * drawn))
        }
        for star in stars {
            let center = CGPoint(x: star.position.x - scroll + left, y: star.position.y)
            let pop = 1 + 0.9 * max(0, 1 - (time - star.born) / 0.35)
            let shine = 0.82 + 0.18 * sin(time * 2.3 + star.twinkle)
            context.fill(palette.accent, 0.2 * shine)
            context.dot(at: center, radius: star.size * 2.6 * pop)
            context.fill(palette.ink, shine)
            context.dot(at: center, radius: star.size * pop)
            if star.size > h / 48 * 2.6 {
                // The brightest get a four-point glint.
                context.stroke(palette.ink, 0.7 * shine)
                context.setLineWidth(0.6)
                let ray = star.size * 3.2 * pop
                context.line(from: CGPoint(x: center.x - ray, y: center.y), to: CGPoint(x: center.x + ray, y: center.y))
                context.line(from: CGPoint(x: center.x, y: center.y - ray), to: CGPoint(x: center.x, y: center.y + ray))
            }
        }
        fadeLeftEdge(in: context, size: size)
        context.endTransparencyLayer()
    }
}
