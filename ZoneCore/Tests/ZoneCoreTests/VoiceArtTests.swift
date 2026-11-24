// by zayd/cold @ zayd.wtf

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ZoneCore

final class VoiceArtTests: XCTestCase {
    /// A made-up talker: phrases of syllables at about four a second, with pauses between.
    static func speech(at time: Double) -> Float {
        let phrase = floor(time / 2.6)
        let t = time - phrase * 2.6
        guard t < 1.8 else { return 0.01 }
        let shape = pow(max(0, sin(.pi * t / 1.8)), 0.4)
        let syllable = 0.5 + 0.5 * sin(2 * .pi * (4.1 + 0.5 * sin(phrase * 1.7)) * t + phrase)
        let stress = 0.7 + 0.3 * sin(2 * .pi * 1.1 * t + 2 * phrase)
        return Float(min(1, max(0, 0.04 + 0.86 * shape * pow(syllable, 1.6) * stress)))
    }

    static let drawn = MeterStyle.allCases.filter(\.isDrawn)

    static func context(width: Int, height: Int, scale: Int) -> CGContext {
        let context = CGContext(data: nil, width: width * scale, height: height * scale, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: CGFloat(height * scale))
        context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        return context
    }

    static func run(_ engine: VoiceArtEngine, from: Double, to: Double, size: CGSize) {
        var time = from
        while time < to {
            engine.feed(level: speech(at: time))
            engine.advance(by: 1.0 / 60.0, size: size)
            time += 1.0 / 60.0
        }
    }

    static func inkedPixels(_ context: CGContext) -> Int {
        guard let data = context.data else { return 0 }
        let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * context.height)
        var count = 0
        for row in 0..<context.height {
            for column in 0..<context.width where bytes[row * context.bytesPerRow + column * 4 + 3] > 24 { count += 1 }
        }
        return count
    }

    static let palette = VoiceArtPalette(ink: ArtColor(1, 1, 1), accent: ArtColor(0.72, 0.6, 1), isDark: true)

    func testTrackerHearsSyllablesPaceAndPauses() {
        var tracker = VoiceTracker()
        var onsets = 0
        var time = 0.0
        while time < 1.8 {
            if tracker.step(level: Self.speech(at: time), dt: 1 / 60).onset > 0 { onsets += 1 }
            time += 1 / 60.0
        }
        XCTAssertTrue((5...9).contains(onsets), "about four syllables a second for 1.8 s, got \(onsets)")
        XCTAssertTrue((1...7).contains(tracker.signal.pace), "a few a second, got \(tracker.signal.pace)")
        XCTAssertGreaterThan(tracker.signal.energy, 0.2)
        while time < 2.6 {
            _ = tracker.step(level: Self.speech(at: time), dt: 1 / 60)
            time += 1 / 60.0
        }
        XCTAssertGreaterThan(tracker.signal.quiet, 0.6)
        XCTAssertFalse(tracker.signal.isVoiced)
        XCTAssertLessThan(tracker.signal.level, 0.05)
    }

    func testTrackerSurvivesBrokenInput() {
        var tracker = VoiceTracker()
        for level in [Float.nan, .infinity, -4, 9, 0.5] {
            let signal = tracker.step(level: level, dt: 1 / 60)
            XCTAssertTrue(signal.level.isFinite && (0...1).contains(signal.level))
            XCTAssertTrue(signal.contour.isFinite && signal.energy.isFinite && signal.pace.isFinite)
        }
        XCTAssertEqual(tracker.step(level: 0.5, dt: 0), tracker.signal)
        XCTAssertEqual(tracker.step(level: 0.5, dt: .nan), tracker.signal)
    }

    func testSilenceMakesNoSyllables() {
        var tracker = VoiceTracker()
        for _ in 0..<600 { XCTAssertEqual(tracker.step(level: 0.02, dt: 1 / 60).onset, 0) }
        XCTAssertEqual(tracker.signal.pace, 0, accuracy: 0.001)
    }

    func testOnlyTheDrawnStylesHaveAnEngine() {
        for style in MeterStyle.allCases {
            XCTAssertEqual(VoiceArtEngine(style: style, seed: 1) != nil, style.isDrawn, style.rawValue)
        }
        XCTAssertEqual(Self.drawn.count, 6)
    }

    func testEveryGraphicDrawsWhenSpokenTo() {
        let size = CGSize(width: 240, height: 48)
        for style in Self.drawn {
            let engine = VoiceArtEngine(style: style, seed: 7)!
            Self.run(engine, from: 0, to: 1.6, size: size)
            let context = Self.context(width: 240, height: 48, scale: 1)
            engine.draw(in: context, size: size, palette: Self.palette)
            XCTAssertGreaterThan(Self.inkedPixels(context), 120, "\(style.rawValue) drew almost nothing")
        }
    }

    func testTheSameSeedDrawsTheSamePictureAndAnotherSeedDoesNot() {
        let size = CGSize(width: 240, height: 48)
        func picture(_ style: MeterStyle, seed: UInt64) -> Data {
            let engine = VoiceArtEngine(style: style, seed: seed)!
            Self.run(engine, from: 0, to: 1.6, size: size)
            let context = Self.context(width: 240, height: 48, scale: 1)
            engine.draw(in: context, size: size, palette: Self.palette)
            return Data(bytes: context.data!, count: context.bytesPerRow * context.height)
        }
        for style in Self.drawn {
            XCTAssertEqual(picture(style, seed: 3), picture(style, seed: 3), style.rawValue)
            // Lanes is a score: the same voice plays the same notes.
            if style == .lanes {
                XCTAssertEqual(picture(style, seed: 3), picture(style, seed: 4))
                continue
            }
            XCTAssertNotEqual(picture(style, seed: 3), picture(style, seed: 4), "\(style.rawValue) repeats itself")
        }
    }

    /// Ten minutes of talking must not grow without bound: every graphic forgets what scrolled away.
    func testALongDictationStaysCheap() {
        let size = CGSize(width: 240, height: 48)
        for style in Self.drawn {
            let engine = VoiceArtEngine(style: style, seed: 11)!
            Self.run(engine, from: 0, to: 600, size: size)
            let context = Self.context(width: 240, height: 48, scale: 1)
            let started = Date()
            for _ in 0..<30 {
                context.clear(CGRect(x: 0, y: 0, width: 240, height: 48))
                engine.draw(in: context, size: size, palette: Self.palette)
            }
            XCTAssertLessThan(Date().timeIntervalSince(started) / 30, 0.004, "\(style.rawValue): a frame after ten minutes")
        }
    }

    func testOddSizesAndTimesAreIgnored() {
        for style in Self.drawn {
            let engine = VoiceArtEngine(style: style, seed: 5)!
            engine.feed(level: .nan)
            engine.advance(by: .infinity, size: CGSize(width: 240, height: 48))
            engine.advance(by: -1, size: CGSize(width: 240, height: 48))
            engine.advance(by: 1, size: .zero)
            engine.advance(by: 30, size: CGSize(width: 3, height: 3))
            let context = Self.context(width: 8, height: 8, scale: 1)
            engine.draw(in: context, size: .zero, palette: Self.palette)
            engine.draw(in: context, size: CGSize(width: 8, height: 8), palette: Self.palette)
        }
    }

    /// With ZONE_VOICE_ART_SHEET set to a folder, writes a sheet of every graphic at several
    /// moments on a dark and a light surface, for looking at.
    func testContactSheet() throws {
        guard let folder = ProcessInfo.processInfo.environment["ZONE_VOICE_ART_SHEET"] else { return }
        let width = 300, height = 56, scale = 3, gap = 10
        let moments = [1.2, 2.5, 4.3, 9.6]
        for dark in [true, false] {
            let sheetWidth = (width + gap) * moments.count + gap, sheetHeight = (height + gap) * Self.drawn.count + gap
            let sheet = Self.context(width: sheetWidth, height: sheetHeight, scale: scale)
            let background: CGFloat = dark ? 0.09 : 0.886
            sheet.setFillColor(red: background, green: background, blue: background + (dark ? 0 : 0.02), alpha: 1)
            sheet.fill(CGRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight))
            let palette = dark ? Self.palette : VoiceArtPalette(ink: ArtColor(0, 0, 0), accent: ArtColor(0.42, 0.27, 0.86), isDark: false)
            for (row, style) in Self.drawn.enumerated() {
                let engine = VoiceArtEngine(style: style, seed: 2026)!
                var time = 0.0
                for (column, moment) in moments.enumerated() {
                    Self.run(engine, from: time, to: moment, size: CGSize(width: width, height: height))
                    time = moment
                    sheet.saveGState()
                    sheet.translateBy(x: CGFloat(gap + column * (width + gap)), y: CGFloat(gap + row * (height + gap)))
                    engine.draw(in: sheet, size: CGSize(width: width, height: height), palette: palette)
                    sheet.restoreGState()
                }
            }
            let url = URL(fileURLWithPath: folder).appendingPathComponent(dark ? "voice-art-dark.png" : "voice-art-light.png")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(sheet.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
    }
}
