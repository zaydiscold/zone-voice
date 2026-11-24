// by zayd/cold @ zayd.wtf

import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import ZoneCore
import UIKit
import XCTest
@testable import Zone

@MainActor
final class WaveLipsTests: XCTestCase {
    func testClosingPinsTheOuterEndsBeforeTheMiddle() {
        for strand in WaveBraid.strands {
            for x: CGFloat in [0, 0.2, 0.8, 1] {
                XCTAssertEqual(strand.offset(x: x, opening: 0.5, phase: 1, detail: 1), 0)
            }
            XCTAssertNotEqual(strand.offset(x: 0.5, opening: 0.5, phase: 1, detail: 1), 0)
            for i in 0...100 {
                XCTAssertEqual(strand.offset(x: CGFloat(i) / 100, opening: 0, phase: 1, detail: 1), 0)
            }
        }
    }

    func testStrandsCrossAndRepeatWithoutAPhaseJump() {
        let main = WaveBraid.strands[0]
        for strand in WaveBraid.strands.dropFirst() {
            var differences: [CGFloat] = []
            for i in 1..<100 {
                let x = CGFloat(i) / 100
                let y = strand.offset(x: x, opening: 1, phase: 0.75, detail: 1)
                XCTAssertEqual(y, strand.offset(x: x, opening: 1, phase: 0.75 + 8 * .pi, detail: 1), accuracy: 1e-12)
                differences.append(y - main.offset(x: x, opening: 1, phase: 0.75, detail: 1))
            }
            XCTAssertTrue(differences.contains { $0 > 0.25 })
            XCTAssertTrue(differences.contains { $0 < -0.25 })
            XCTAssertNotEqual(main.speed, strand.speed)
        }
    }

    func testClosedWaveRedrawsWhenEitherToneChanges() throws {
        let window = try makeWindow()
        defer { window.isHidden = true }
        let wave = mount(in: window)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let renderer = UIGraphicsImageRenderer(size: wave.bounds.size, format: format)
        func rendered(center: UIColor, edge: UIColor) throws -> Data {
            wave.update(levels: [0], color: center, edgeColor: edge, style: .wave, detail: 1, animated: false)
            XCTAssertEqual(wave.opening, 0)
            return try XCTUnwrap(renderer.image { _ in wave.draw(wave.bounds) }.pngData())
        }
        let original = try rendered(center: .orange, edge: .blue)
        XCTAssertNotEqual(try rendered(center: .orange, edge: .red), original)
        XCTAssertNotEqual(try rendered(center: .green, edge: .blue), original)
        XCTAssertEqual(try rendered(center: .orange, edge: .blue), original)
    }

    private func makeWindow() throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        return window
    }

    private func mount(in window: UIWindow) -> FlowingWave.WaveView {
        let wave = FlowingWave.WaveView(frame: CGRect(x: 10, y: 80, width: 188, height: 32))
        window.rootViewController!.view.addSubview(wave)
        return wave
    }

    private func run(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func findWave(in view: UIView) -> FlowingWave.WaveView? {
        if let wave = view as? FlowingWave.WaveView { return wave }
        return view.subviews.lazy.compactMap { self.findWave(in: $0) }.first
    }

    // Draw into a known 8-bit alpha buffer so the assertion covers the real raster path.
    private func inkHeight(_ wave: FlowingWave.WaveView, columns: Range<Int>) throws -> Int {
        let width = Int(wave.bounds.width), height = Int(wave.bounds.height)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue))
        UIGraphicsPushContext(ctx)
        wave.draw(wave.bounds)
        UIGraphicsPopContext()
        let pixels = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
        let rows = (0..<height).filter { y in columns.contains { x in pixels[y * width + x] > 10 } }
        return rows.last.map { $0 - rows.first! + 1 } ?? 0
    }

    func testSwiftUIStopPreservesRendererAndPinchesToFlat() throws {
        struct Face: View {
            var live: Bool
            var body: some View {
                FlowingWave(levels: Array(repeating: 0.85, count: 32), color: UIColor(Zone.accentTone(.dark)), live: live)
                    .frame(width: 188, height: 32)
                    .environment(\.scenePhase, .active)
            }
        }
        let window = try makeWindow()
        defer { window.isHidden = true }
        let host = UIHostingController(rootView: Face(live: true))
        window.rootViewController = host
        host.view.layoutIfNeeded()
        run(0.35)
        let wave = try XCTUnwrap(findWave(in: host.view))
        XCTAssertEqual(wave.opening, 1)
        XCTAssertGreaterThan(try inkHeight(wave, columns: 8..<35), 5)
        host.rootView = Face(live: false)
        run(0.16)
        XCTAssertTrue(findWave(in: host.view) === wave)
        XCTAssertEqual(wave.opening, 0.5, accuracy: 0.18)
        XCTAssertEqual(try inkHeight(wave, columns: 8..<30), 4)
        XCTAssertGreaterThan(try inkHeight(wave, columns: 76..<112), 4)
        run(0.12)
        XCTAssertTrue(wave.isAnimating)
        run(0.10)
        XCTAssertFalse(wave.isAnimating)
        XCTAssertEqual(try inkHeight(wave, columns: 0..<188), 4)
        XCTAssertTrue(wave.shown.allSatisfy { $0 == 0 })
        XCTAssertEqual(wave.phase, 0)
        wave.update(levels: [0.045], color: UIColor(Zone.accentTone(.dark)), style: .wave, detail: 1, animated: true)
        run(0.09)
        XCTAssertGreaterThan(wave.opening, 0)
        XCTAssertLessThanOrEqual(try XCTUnwrap(wave.shown.max()), pow(CGFloat(0.045), 0.62))
    }

    func testRoomNoiseHysteresisAndReducedMotion() throws {
        let window = try makeWindow()
        defer { window.isHidden = true }
        let wave = mount(in: window)
        let color = UIColor(Zone.accentTone(.dark))
        for reduced in [false, true] {
            func feed(_ level: Float) {
                wave.update(levels: [level], color: color, style: .wave, detail: 1, animated: !reduced, reduceMotion: reduced)
            }
            feed(0.025)
            XCTAssertFalse(wave.isAnimating)
            XCTAssertEqual(wave.opening, 0)
            feed(0.04)
            run(0.22)
            feed(0.035)
            run(0.27)
            XCTAssertEqual(wave.opening, 1)
            feed(0)
            run(0.05)
            XCTAssertEqual(wave.opening, 1)
            XCTAssertNil(wave.layer.animation(forKey: kCATransition))
            feed(0.6)
            run(0.25)
            feed(0.025)
            run(0.17)
            XCTAssertEqual(wave.opening, 1)
            run(0.13)
            XCTAssertLessThan(wave.opening, 1)
            if reduced {
                XCTAssertFalse(wave.isAnimating)
                XCTAssertEqual((wave.layer.animation(forKey: kCATransition) as? CATransition)?.type, .fade)
                XCTAssertEqual(try inkHeight(wave, columns: 0..<188), 4)
            }
            run(0.39)
            XCTAssertFalse(wave.isAnimating)
            XCTAssertTrue(wave.shown.allSatisfy { $0 == 0 })
        }
    }

    func testHiddenRendererStopsAndOtherMetersSettle() throws {
        let window = try makeWindow()
        defer { window.isHidden = true }
        let wave = mount(in: window)
        let parent = try XCTUnwrap(wave.superview)
        func feed(_ level: Float, _ style: MeterStyle) {
            wave.update(levels: [level], color: UIColor(Zone.accentTone(.dark)), style: style, detail: 1, animated: true)
        }
        for hide in [{ wave.isHidden = true }, { parent.alpha = 0 }, { window.isHidden = true }] {
            feed(0.7, .wave)
            run(0.22)
            XCTAssertTrue(wave.isAnimating)
            hide()
            run(0.035)
            XCTAssertFalse(wave.isAnimating)
            wave.isHidden = false
            parent.alpha = 1
            window.isHidden = false
        }
        for style in [MeterStyle.bars, .mirrored] {
            feed(0.8, .wave)
            run(0.22)
            feed(0.45, style)
            XCTAssertEqual(wave.opening, 0)
            run(1.4)
            XCTAssertFalse(wave.isAnimating)
            feed(0.025, .wave)
            XCTAssertFalse(wave.isAnimating)
            XCTAssertTrue(wave.shown.allSatisfy { $0 == 0 })
        }
    }

    func testHeldSoundCadenceAndRasterBudget() throws {
        let window = try makeWindow()
        defer { window.isHidden = true }
        let wave = mount(in: window)
        wave.update(levels: [0.7], color: UIColor(Zone.accentTone(.dark)), style: .wave, detail: 1, animated: true)
        run(0.3)
        let before = wave.probeFrames
        run(1)
        let frames = wave.probeFrames - before
        XCTAssertGreaterThanOrEqual(frames, 30)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        _ = UIGraphicsImageRenderer(size: wave.bounds.size, format: format).image { _ in
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            for _ in 0..<256 { wave.draw(wave.bounds) }
            let elapsed = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start
            let ms = Double(elapsed) / 256e6
            XCTAssertLessThan(ms, 1)
            print("WAVE_LIPS frames=\(frames) rasterCPUmsPerDraw=\(ms)")
        }
    }

    func testBundledSpeechQuietAndStopFrames() throws {
        let window = try makeWindow()
        defer { window.isHidden = true }
        let wave = mount(in: window)
        for scheme in [ColorScheme.light, .dark] {
            let color = UIColor(Zone.accentTone(scheme))
            let paper = UIColor(Zone.paper(scheme))
            let frames = NSMutableData()
            let speechCount = VoicePreviewSpeech.samples.count
            let gif = try XCTUnwrap(CGImageDestinationCreateWithData(frames, UTType.gif.identifier as CFString,
                                                                      speechCount + 24, nil))
            CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            let renderer = UIGraphicsImageRenderer(size: wave.bounds.size, format: format)
            for tick in 0..<(speechCount + 24) {
                // 6.4 s of recorded speech, explicit stop, then a live quiet room.
                let levels = tick < speechCount ? VoicePreviewSpeech.history(at: tick) : [0.025]
                let live = tick < speechCount || tick >= speechCount + 10
                wave.update(levels: levels, live: live, color: color, style: .wave, detail: 1, animated: true)
                run(0.05)
                if (5..<speechCount).contains(tick) { XCTAssertEqual(wave.opening, 1, "speech sample \(tick)") }
                if tick >= speechCount + 9 {
                    XCTAssertFalse(wave.isAnimating)
                    XCTAssertEqual(wave.opening, 0)
                }
                let frame = renderer.image { ctx in
                    paper.setFill()
                    ctx.fill(wave.bounds)
                    wave.draw(wave.bounds)
                }
                CGImageDestinationAddImage(gif, try XCTUnwrap(frame.cgImage),
                                           [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]] as CFDictionary)
            }
            XCTAssertTrue(CGImageDestinationFinalize(gif))
            let attachment = XCTAttachment(data: frames as Data, uniformTypeIdentifier: UTType.gif.identifier)
            attachment.name = scheme == .dark ? "wave-dark.gif" : "wave-light.gif"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
