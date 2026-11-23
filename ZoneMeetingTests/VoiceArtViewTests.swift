// by zayd/cold @ zayd.wtf

import SwiftUI
import XCTest
import ZoneCore
@testable import Zone

@MainActor
final class VoiceArtViewTests: XCTestCase {
    /// Hex's shader is compiled from source on the device; a typo in it would leave Scope blank.
    func testScopeShaderCompilesOnTheDevice() {
        XCTAssertNotNil(DotScopeMetalPipeline.shared)
    }

    func testScopeMapsZoneLevelsOntoItsLoudnessRange() {
        XCTAssertEqual(DotScopeSimulation.loudness(fromNormalized: 0), -90)
        XCTAssertEqual(DotScopeSimulation.loudness(fromNormalized: 1), -20)
        XCTAssertLessThan(DotScopeSimulation.loudness(fromNormalized: 0.3), DotScopeSimulation.loudness(fromNormalized: 0.6))
    }

    /// Each graphic, hosted the way the keyboard and Home host it, paints while it is fed a voice
    /// and stops its frame timer at rest. ZONE_VOICE_ART_SHOTS saves what it painted.
    func testEveryStylePaintsInAWindowAndRestsWithoutATimer() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 280, height: 56)
        window.isHidden = false
        defer { window.isHidden = true }
        for style in MeterStyle.allCases where style.isDrawn {
            let view = VoiceArtCanvasView(frame: window.bounds)
            window.addSubview(view)
            let started = Date()
            while Date().timeIntervalSince(started) < 1.3 {
                let t = Date().timeIntervalSince(started)
                let level = Float(0.15 + 0.75 * pow(0.5 + 0.5 * sin(t * 26), 1.6))
                view.update(style: style, level: level, live: true, ink: .white, accent: .systemPurple, isDark: true)
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            XCTAssertTrue(view.isAnimating, style.rawValue)
            let image = UIGraphicsImageRenderer(bounds: view.bounds).image { context in view.layer.render(in: context.cgContext) }
            XCTAssertGreaterThan(Self.paintedPixels(image), 150, "\(style.rawValue) painted almost nothing")
            if let folder = ProcessInfo.processInfo.environment["ZONE_VOICE_ART_SHOTS"] {
                try image.pngData()?.write(to: URL(fileURLWithPath: folder).appendingPathComponent("view-\(style.rawValue).png"))
            }
            view.update(style: style, level: 0, live: false, ink: .white, accent: .systemPurple, isDark: true)
            XCTAssertFalse(view.isAnimating, "\(style.rawValue) keeps a timer at rest")
            view.removeFromSuperview()
        }
    }

    private static func paintedPixels(_ image: UIImage) -> Int {
        guard let cg = image.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
        let alphaFirst = [CGImageAlphaInfo.premultipliedFirst, .first, .noneSkipFirst].contains(cg.alphaInfo)
        var count = 0
        for row in 0..<cg.height {
            for column in 0..<cg.width where bytes[row * cg.bytesPerRow + column * 4 + (alphaFirst ? 0 : 3)] > 24 { count += 1 }
        }
        return count
    }
}
