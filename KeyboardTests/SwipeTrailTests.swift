// by zayd/cold @ zayd.wtf

import XCTest
import UIKit
import SwiftUI
import ZoneCore

@MainActor
final class SwipeTrailTests: XCTestCase {
    func testLightIceAndEmberMicUseOriginalPastelsWithDarkInk() {
        for (choice, hex) in [(AccentChoice.ice, UInt32(0x8EE8FF)), (.ember, 0xFF9A6B)] {
            let light = KeyboardTheme(isDark: false, accentStamp: choice)
            XCTAssertEqual(light.controlFill, Color(hex: hex))
            XCTAssertEqual(light.controlInk, Color(hex: choice.foregroundHex))
            let dark = KeyboardTheme(isDark: true, accentStamp: choice)
            XCTAssertEqual(dark.controlFill, Color(hex: choice.controlFillHex(isDark: true)))
            XCTAssertEqual(dark.controlInk, Color(hex: choice.foregroundHex))
        }
    }

    func testRoundedTurnKeepsTheHeadAndCutsInsideTheCorner() throws {
        var trace = SwipeTrailGeometry()
        for (i, point) in [CGPoint.zero, CGPoint(x: 40, y: 0), CGPoint(x: 40, y: 40)].enumerated() {
            trace.append(point, at: 1 + Double(i) / 60, lifetime: 0.24)
        }
        let now = try XCTUnwrap(trace.samples.last).time
        let path = try XCTUnwrap(trace.outline(at: now, lifetime: 0.24, width: 8))
        XCTAssertTrue(path.contains(CGPoint(x: 35, y: 5)))
        XCTAssertFalse(path.contains(CGPoint(x: 40, y: 0)))
        XCTAssertTrue(path.contains(CGPoint(x: 40, y: 43.9)))
        XCTAssertEqual(path.boundingBoxOfPath.maxY, 44, accuracy: 0.02)
        let older = try XCTUnwrap(trace.outline(at: now + 0.12, lifetime: 0.24, width: 8))
        XCTAssertEqual(older.boundingBoxOfPath.maxY, 42, accuracy: 0.02)
        XCTAssertNil(trace.outline(at: now + 0.25, lifetime: 0.24, width: 8))
    }

    func testShortReversalPreservesItsTip() throws {
        var trace = SwipeTrailGeometry()
        for x in [0, 15, 23, 16, 8] {
            trace.append(CGPoint(x: x, y: 0), at: 1, lifetime: 0.24)
        }
        let path = try XCTUnwrap(trace.outline(at: 1, lifetime: 0.24, width: 8))
        XCTAssertTrue(trace.samples.contains { $0.point.x == 23 })
        XCTAssertEqual(path.boundingBoxOfPath.maxX, 27, accuracy: 0.05)
    }

    func testSparseTurnStaysWithinOneScreenPixelOfTheCurve() throws {
        var trace = SwipeTrailGeometry()
        for point in [CGPoint.zero, CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)] {
            trace.append(point, at: 1, lifetime: 0.24)
        }
        let path = try XCTUnwrap(trace.outline(at: 1, lifetime: 0.24, width: 8))
        // Sample the outside edge between the old four chords' endpoints.
        let t: CGFloat = 0.375
        let center = CGPoint(x: 100 - 50 * (1 - t) * (1 - t), y: 50 * t * t)
        let length = hypot(t, 1 - t)
        let edge = CGPoint(x: center.x + 3.85 * t / length, y: center.y - 3.85 * (1 - t) / length)
        XCTAssertTrue(path.contains(edge))
    }

    /// Zayd, 2026-11-18: a bit more see-through and a shorter tail, closer to the system
    /// keyboard's. The comet was 0.36 s long at 0.85 opacity.
    func testTrailIsShortAndSeeThrough() {
        XCTAssertLessThanOrEqual(SwipeTrailLayer.lifetime, 0.25, "the tail fades in a quarter second")
        XCTAssertGreaterThanOrEqual(SwipeTrailLayer.lifetime, 0.15, "long enough to show the path just drawn")
        XCTAssertLessThanOrEqual(SwipeTrailLayer.groupOpacity, 0.65)
        XCTAssertGreaterThanOrEqual(SwipeTrailLayer.groupOpacity, 0.5, "still reads on both keyboard backdrops")
    }
    func testSamplesAreBoundedAndAGapStartsAtTheFinger() {
        var trace = SwipeTrailGeometry()
        for i in 0..<500 {
            trace.append(CGPoint(x: i * 11, y: i % 20), at: Double(i) / 10_000, lifetime: 0.24)
        }
        XCTAssertLessThanOrEqual(trace.samples.count, SwipeTrailGeometry.capacity)
        trace.append(.zero, at: 1, lifetime: 0.24)
        XCTAssertEqual(trace.samples.count, 1)
        XCTAssertNil(trace.outline(at: 1, lifetime: 0.24, width: 8))
        trace.append(CGPoint(x: CGFloat.nan, y: 0), at: 1, lifetime: 0.24)
        trace.append(CGPoint(x: 10, y: 0), at: 0, lifetime: 0.24)
        XCTAssertEqual(trace.samples.count, 1)
    }

    func testTrailUsesChosenColorAndAgesWithoutNewTouches() async throws {
        let trail = SwipeTrailLayer()
        let ribbon = try XCTUnwrap(trail.sublayers?.first as? CAShapeLayer)
        trail.append(.zero, color: .magenta)
        trail.append(CGPoint(x: 24, y: 0), color: .magenta)
        // Allow a busy simulator up to a second to present the first ribbon.
        let deadline = ContinuousClock.now + .seconds(1)
        while ribbon.path == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(ribbon.path)
        XCTAssertEqual(ribbon.fillColor, UIColor.magenta.cgColor)
        XCTAssertEqual(trail.opacity, SwipeTrailLayer.groupOpacity)
        let held = try XCTUnwrap(ribbon.path)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(ribbon.path?.boundingBoxOfPath, held.boundingBoxOfPath)
        trail.endStroke()
        let fadeDeadline = ContinuousClock.now + .seconds(1)
        while ribbon.path != nil, ContinuousClock.now < fadeDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(ribbon.path)
        trail.clear()
        trail.append(CGPoint(x: 100, y: 100), color: .orange)
        XCTAssertNil(ribbon.path)
    }
}

extension SwipeTrailTests {
    private func hue(_ color: CGColor) -> CGFloat {
        var h: CGFloat = 0
        UIColor(cgColor: color).getHue(&h, saturation: nil, brightness: nil, alpha: nil)
        return h
    }

    /// Draws a wave through the trail and returns the image of what shows, Rainbow Road included.
    private func render(_ style: SwipeTrailStyle, accent: UIColor = .systemTeal) -> (SwipeTrailLayer, UIImage) {
        let trail = SwipeTrailLayer()
        trail.frame = CGRect(x: 0, y: 0, width: 360, height: 140)
        let start = CACurrentMediaTime()
        for step in 0...40 {
            let x = 20 + CGFloat(step) * 8
            trail.append(CGPoint(x: x, y: 70 + 40 * sin(x / 40)), color: accent, style: style,
                         now: start + Double(step) * 0.004)
        }
        trail.sublayers?.forEach { $0.displayIfNeeded() }
        let image = UIGraphicsImageRenderer(bounds: trail.bounds).image { context in
            UIColor(white: 0.1, alpha: 1).setFill()
            context.fill(trail.bounds)
            for layer in trail.sublayers ?? [] where !layer.isHidden {
                context.cgContext.saveGState()
                context.cgContext.translateBy(x: layer.frame.minX, y: layer.frame.minY)
                layer.render(in: context.cgContext)
                context.cgContext.restoreGState()
            }
        }
        return (trail, image)
    }

    func testRainbowRoadTurnsTheHueWithTravelAndCarriesItAcrossSwipes() {
        let a = SwipeTrailLayer.rainbowColor(travel: 0).cgColor
        let b = SwipeTrailLayer.rainbowColor(travel: SwipeTrailLayer.rainbowWavelength / 4).cgColor
        let c = SwipeTrailLayer.rainbowColor(travel: SwipeTrailLayer.rainbowWavelength).cgColor
        XCTAssertEqual(hue(b), 0.25, accuracy: 0.01)
        XCTAssertEqual(hue(a), hue(c), accuracy: 0.01, "one wavelength is one full turn")

        let trail = SwipeTrailLayer()
        trail.append(.zero, color: .red, style: .rainbowRoad)
        trail.append(CGPoint(x: 50, y: 0), color: .red, style: .rainbowRoad)
        trail.clear()
        XCTAssertEqual(trail.travel, 50, accuracy: 0.001, "a new swipe starts where the last one stopped")
        trail.append(CGPoint(x: 300, y: 300), color: .red, style: .rainbowRoad)
        XCTAssertEqual(trail.travel, 50, accuracy: 0.001, "the jump to a new swipe's first point is not travel")
    }

    func testRainbowRoadShowsSeveralColorsAndAccentShowsOne() throws {
        let (rainbowTrail, rainbowImage) = render(.rainbowRoad)
        let (accentTrail, _) = render(.accent)
        let ribbon = try XCTUnwrap(rainbowTrail.sublayers?.first as? CAShapeLayer)
        let rainbow = try XCTUnwrap(rainbowTrail.sublayers?.last as? RainbowRibbonLayer)
        XCTAssertTrue(ribbon.isHidden)
        XCTAssertFalse(rainbow.isHidden)
        XCTAssertNotNil(ribbon.path, "the outline is still computed; it clips the colors")
        XCTAssertTrue(try XCTUnwrap(accentTrail.sublayers?.last).isHidden)
        XCTAssertFalse(try XCTUnwrap(accentTrail.sublayers?.first).isHidden)

        // Sample the drawn pixels along the wave: the hues must span a wide part of the wheel.
        let image = try XCTUnwrap(rainbowImage.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var hues: [CGFloat] = []
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = CGFloat(pixels[i]) / 255, g = CGFloat(pixels[i + 1]) / 255, b = CGFloat(pixels[i + 2]) / 255
            guard max(r, g, b) - min(r, g, b) > 0.35 else { continue }
            var h: CGFloat = 0
            UIColor(red: r, green: g, blue: b, alpha: 1).getHue(&h, saturation: nil, brightness: nil, alpha: nil)
            hues.append(h)
        }
        XCTAssertGreaterThan(hues.count, 200, "the trail draws colored pixels")
        let buckets = Set(hues.map { Int($0 * 6) % 6 })
        XCTAssertGreaterThanOrEqual(buckets.count, 4, "a 320 pt swipe covers more than a full turn of hue")

        if let path = ProcessInfo.processInfo.environment["ZONE_TRAIL_PNG"] {
            let (_, accentImage) = render(.accent)
            let both = UIGraphicsImageRenderer(size: CGSize(width: 360, height: 280)).image { _ in
                accentImage.draw(at: .zero)
                rainbowImage.draw(at: CGPoint(x: 0, y: 140))
            }
            try both.pngData()?.write(to: URL(fileURLWithPath: path))
        }
    }

    func testTrailStylePreferenceFallsBackToAccent() throws {
        XCTAssertEqual(KeyboardPreferences().swipeTrailStyle, .accent)
        let unknown = #"{"swipeTrailStyle":"glitter","autocorrectEnabled":false}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(KeyboardPreferences.self, from: unknown)
        XCTAssertEqual(decoded.swipeTrailStyle, .accent)
        XCTAssertFalse(decoded.autocorrectEnabled, "one unreadable value does not reset the others")
        var chosen = KeyboardPreferences()
        chosen.swipeTrailStyle = .rainbowRoad
        let roundTrip = try JSONDecoder().decode(KeyboardPreferences.self, from: JSONEncoder().encode(chosen))
        XCTAssertEqual(roundTrip.swipeTrailStyle, .rainbowRoad)
    }
}

extension SwipeTrailTests {
    func testHomeMarkOnLightAndDarkKeyboardKeys() throws {
        let assets = Bundle(for: SwipeTrailTests.self)
        XCTAssertNotNil(UIImage(named: "ZoneHomeMark", in: assets, compatibleWith: nil))
        for choice in AccentChoice.allCases {
            for dark in [false, true] {
                let theme = KeyboardTheme(isDark: dark, accentStamp: choice)
                let expected = Color(hex: dark ? choice.darkHex : choice.lightHex)
                XCTAssertEqual(theme.accentTone, expected)
                XCTAssertEqual(theme.accentToneUIColor, UIColor(expected))
                XCTAssertEqual(theme.controlInk, Color(hex: choice.controlInkHex(isDark: dark)))
                let renderer = ImageRenderer(content:
                    ZoneHomeMark(theme: theme)
                        .frame(width: 36, height: 36).background(theme.key))
                renderer.scale = 3
                let image = try XCTUnwrap(renderer.uiImage)
                let cg = try XCTUnwrap(image.cgImage)
                let w = cg.width
                let h = cg.height
                var pixels = [UInt8](repeating: 0, count: w * h * 4)
                try pixels.withUnsafeMutableBytes { storage in
                    let bitmap = try XCTUnwrap(CGContext(data: storage.baseAddress, width: w, height: h,
                        bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                    bitmap.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                }
                func matches(_ index: Int, _ hex: UInt32) -> Bool {
                    [16, 8, 0].enumerated().allSatisfy { channel, shift in
                        abs(Int(pixels[index * 4 + channel]) - Int(hex >> shift & 255)) <= 3
                    }
                }
                // Cross the mark a row at a time. The light rim must occur on both sides
                // of a dark face on the same row. A blank, reversed or offset mark fails.
                let outlinedRows = (0..<h).filter { row in
                    let range = (row * w)..<((row + 1) * w)
                    let face = range.filter { matches($0, theme.markFaceHex) }
                    guard let first = face.first, let last = face.last else { return false }
                    return range.contains { $0 < first && matches($0, theme.markRimHex) }
                        && range.contains { $0 > last && matches($0, theme.markRimHex) }
                }
                XCTAssertGreaterThan(outlinedRows.count, 3, "\(choice) / dark: \(dark)")
                let attachment = XCTAttachment(image: image)
                attachment.name = "\(choice.label) on \(dark ? "dark" : "light") key"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}
