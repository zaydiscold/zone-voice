// by zayd/cold @ zayd.wtf

import SwiftUI
import XCTest
@testable import Zone

@MainActor
final class MeetingWaveTests: XCTestCase {
    private let phone = CGRect(x: 0, y: 0, width: 393, height: 852)

    private func meter(_ levels: [Float], style: MeetingWaveStyle = .weave, still: Bool = false) -> EdgeEqualizer.EdgeView {
        let view = EdgeEqualizer.EdgeView(frame: phone)
        view.update(levels: levels, color: .systemPurple, active: true, style: style, reduceMotion: still)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        view.drawFrame(phase: 1, fraction: 1)
        return view
    }

    private func lines(_ view: UIView) -> [CAShapeLayer] {
        (view.layer.sublayers?.first?.mask?.sublayers ?? []).compactMap { $0 as? CAShapeLayer }.filter { !$0.isHidden }
    }

    func testSilenceCollapsesTheStrandsAndSpeechSeparatesThem() throws {
        let idle = lines(meter([]))
        let loud = lines(meter(Array(repeating: 0.8, count: 48)))
        XCTAssertEqual(idle.count, 3)
        XCTAssertEqual(idle[0].path, idle[1].path)
        XCTAssertNotEqual(loud[0].path, loud[1].path)
        XCTAssertGreaterThan(loud[2].opacity, idle[2].opacity)
        func outline(_ layer: CAShapeLayer) throws -> [CGPoint] {
            let path = try XCTUnwrap(layer.path)
            var points: [CGPoint] = []
            path.applyWithBlock { element in
                if element.pointee.type == .moveToPoint || element.pointee.type == .addLineToPoint {
                    points.append(element.pointee.points[0])
                }
            }
            return points
        }
        let quiet = try outline(idle[0]), voiced = try outline(loud[0])
        XCTAssertEqual(quiet.count, voiced.count)
        // A weave crosses its resting line. At a crest it still moves at least three points.
        let displacements = zip(quiet, voiced).map { hypot($0.x - $1.x, $0.y - $1.y) }
        XCTAssertGreaterThan(try XCTUnwrap(displacements.max()), 3)
    }

    func testLoudSyllablesAreWiderAtTheirPlaceOnTheRibbon() throws {
        let samples = Array(repeating: Float(0.01), count: 24) + Array(repeating: Float(0.9), count: 24)
        let path = try XCTUnwrap(lines(meter(samples)).first?.path)
        var starts = [CGPoint]()
        path.applyWithBlock { element in
            if element.pointee.type == .moveToPoint || element.pointee.type == .addLineToPoint {
                starts.append(element.pointee.points[0])
            }
        }
        let count = starts.count / 2
        guard count > 0 else { return XCTFail("No ribbon geometry") }
        func width(at index: Int) -> Double {
            hypot(starts[index].x - starts[index + count].x, starts[index].y - starts[index + count].y)
        }
        XCTAssertGreaterThan(width(at: 0), width(at: count / 2) + 1)
    }

    func testReduceMotionKeepsPathsStillAndShowsLevelWithInk() throws {
        let quiet = meter([], still: true)
        let loud = meter(Array(repeating: 1, count: 48), still: true)
        loud.drawFrame(phase: 9, fraction: 0)
        XCTAssertEqual(lines(quiet).map(\.path), lines(loud).map(\.path))
        XCTAssertGreaterThan(lines(loud)[0].opacity, lines(quiet)[0].opacity)
    }

    func testBorderAndInnerTonesReverseWithTheSurface() throws {
        let meter = EdgeEqualizer.EdgeView(frame: phone)
        func channels(border: UIColor, inner: UIColor) throws -> (edgeRed: UInt8, innerRed: UInt8) {
            meter.update(levels: [1], color: border, innerColor: inner, active: true, style: .weave, reduceMotion: true)
            meter.setNeedsLayout()
            meter.layoutIfNeeded()
            let layer = try XCTUnwrap(meter.layer.sublayers?.first)
            let contents = try XCTUnwrap(layer.contents)
            XCTAssertEqual(CFGetTypeID(contents as CFTypeRef), CGImage.typeID)
            let image = contents as! CGImage
            let width = image.width, height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            try bytes.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return (bytes[(width / 2) * 4], bytes[((height / 2) * width + width / 2) * 4])
        }
        let light = try channels(border: .red, inner: .blue)
        let dark = try channels(border: .blue, inner: .red)
        XCTAssertGreaterThan(Int(light.edgeRed) - Int(light.innerRed), 180)
        XCTAssertGreaterThan(Int(dark.innerRed) - Int(dark.edgeRed), 180)
    }

    func testFrameWorkAtPhoneSize() {
        let view = meter((0..<48).map(MeetingDemoSpeech.sample), style: .braid)
        var times = [Double]()
        for frame in 0..<240 {
            let start = CACurrentMediaTime()
            view.drawFrame(phase: Double(frame) / 60, fraction: 0.5)
            times.append((CACurrentMediaTime() - start) * 1000)
        }
        let sorted = times.sorted()
        print("Meeting wave CPU frame ms median=\(sorted[120]) p95=\(sorted[228])")
        XCTAssertLessThan(sorted[228], 8)
    }

    func testBackgroundMeterKeepsSyllablesBetweenCardUpdatesAndSettlesInSilence() throws {
        var levels = MeetingActivityLevels()
        for sample: Float in [0, 0.9, 0, 0, 0, 0] { levels.append(sample) }
        XCTAssertFalse(levels.takeSnapshot(after: 0.5))
        XCTAssertTrue(levels.takeSnapshot(after: 1))
        let first = try XCTUnwrap(levels.snapshot)
        XCTAssertGreaterThan(first[first.count - 2], 0)
        XCTAssertEqual(first.last, 0)
        XCTAssertFalse(levels.takeSnapshot(after: 1))

        for _ in 0..<(MeetingWaveSignal.count * 3) { levels.append(0) }
        XCTAssertTrue(levels.takeSnapshot(after: 1))
        XCTAssertTrue(try XCTUnwrap(levels.snapshot).allSatisfy { $0 == 0 })
        XCTAssertFalse(levels.takeSnapshot(after: 29))
        levels.reset()
        XCTAssertNil(levels.snapshot)
    }

    func testCompactStylesKeepDifferentContours() {
        let points = (0...32).map { Double($0) / 32 }
        func line(_ style: MeetingWaveStyle, level: Double = 0.8) -> [Double] {
            points.map { style.compactHeight(at: $0, strand: 0, level: level, still: false) }
        }
        XCTAssertNotEqual(line(.weave), line(.flow))
        XCTAssertNotEqual(line(.weave), line(.tide))
        XCTAssertGreaterThan(Set(line(.glow)).count, 1)
        XCTAssertEqual(line(.glow, level: 0), line(.glow, level: 1))
    }

    func testSquareScreenUsesTheSmallCornerAndQuietHasNoFrameClock() {
        let size = CGSize(width: 375, height: 667)
        XCTAssertEqual(EdgeEqualizer.EdgeView.borderRadius(for: size, bottomInset: 0), 16 * 375 / 393.0, accuracy: 0.01)
        XCTAssertGreaterThan(EdgeEqualizer.EdgeView.borderRadius(for: size, bottomInset: 34), 50)
        XCTAssertGreaterThan(MeetingEdge.roomFloor, 0.02)
        XCTAssertEqual(MeetingEdge.frameInterval, 1.0 / 30)
    }

    func testCompactBlackoutWaveIsVisibleWithoutWhite() throws {
        var state = RecordingActivityAttributes.ContentState(phase: .recording, noteMode: true, startedAt: Date())
        state.gallery = true
        state.look = .blackout
        state.meetingTitle = "Test meeting"
        state.meetingWaveStyle = MeetingWaveStyle.weave.rawValue
        state.levels = Array(repeating: 12, count: 48)
        let island = IslandKit(state: state)
        XCTAssertEqual(island.look, .blackout)
        let compact = try XCTUnwrap(island.meetingWave)
        for size in [CGSize(width: 17, height: 16), CGSize(width: 46, height: 22)] {
            let wave = compact.frame(width: size.width, height: size.height).background(Color.black)
            let renderer = ImageRenderer(content: wave)
            let image = try XCTUnwrap(renderer.cgImage)
            let width = image.width, height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            try bytes.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(origin: .zero, size: size))
            }
            var colored = 0
            var white = 0
            for index in stride(from: 0, to: bytes.count, by: 4) {
                let r = bytes[index], g = bytes[index + 1], b = bytes[index + 2]
                let low = min(r, g, b), high = max(r, g, b)
                if high > 20 && high - low > 10 { colored += 1 }
                if low > 200 && high - low < 12 { white += 1 }
            }
            XCTAssertGreaterThan(colored, width)
            XCTAssertEqual(white, 0)
        }
    }

    private func edge(in view: UIView) -> EdgeEqualizer.EdgeView? {
        if let view = view as? EdgeEqualizer.EdgeView { return view }
        return view.subviews.lazy.compactMap { self.edge(in: $0) }.first
    }

    func testMovingRecorderFollowsTheDisplayClock() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let suite = "meeting-wave-clock-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(MeetingWaveStyle.weave.rawValue, forKey: MeetingWaveStyle.preferenceKey)
        let root = MeetingEdge(levels: Array(repeating: 0.7, count: 48), active: true)
            .defaultAppStorage(defaults)
            .environment(\.scenePhase, .active)
        let host = UIHostingController(rootView: root)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        let meter = try XCTUnwrap(edge(in: host.view))
        var stamps: [TimeInterval] = []
        let start = CACurrentMediaTime()
        while CACurrentMediaTime() - start < 1.5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
            if meter.time != stamps.last { stamps.append(meter.time) }
        }
        let intervals = zip(stamps.dropFirst(), stamps).map { ($0 - $1) * 1000 }.sorted()
        if UIAccessibility.isReduceMotionEnabled {
            XCTAssertLessThan(intervals.count, 3)
            return
        }
        XCTAssertGreaterThan(intervals.count, 15)
        // Allow a boundary tick and scheduling jitter during the 1.5 s observation.
        XCTAssertLessThanOrEqual(intervals.count, 48)
        if !intervals.isEmpty {
            print("Meeting display interval ms median=\(intervals[intervals.count / 2]) frames=\(intervals.count)")
        }
    }

    func testSettingsMiniatureDrawsTheRecorderPathsForTheSameSound() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let levels = (75..<123).map(MeetingDemoSpeech.sample)
        func paths<V: View>(_ root: V) throws -> [CGPath?] {
            let host = UIHostingController(rootView: root)
            window.rootViewController = host
            window.isHidden = false
            window.layoutIfNeeded()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let meter = try XCTUnwrap(edge(in: host.view))
            meter.drawFrame(phase: 1, fraction: 0.5)
            return lines(meter).map(\.path)
        }
        let preview = MeetingRecorderMiniature(frame: .init(levels: levels, seconds: 23, playing: true))
        let previewPaths = try paths(preview.frame(width: 220, height: 286))
        let recorderPaths = try paths(MeetingEdge(levels: levels, active: true).frame(width: window.bounds.width, height: window.bounds.height))
        XCTAssertEqual(previewPaths, recorderPaths)
        XCTAssertFalse(previewPaths.isEmpty)
    }

    /// Set TEST_RUNNER_ZONE_MEETING_SHOTS=1 to capture the candidate gallery. The simulator
    /// writes its native recorder face in Documents/MeetingWaveShots. A host running simctl
    /// recordVideo can watch its "playing" file for the start of each eight second loop.
    func testCandidateFaces() throws {
        guard ProcessInfo.processInfo.environment["ZONE_MEETING_SHOTS"] == "1" else { return }
        let folder = URL.documentsDirectory.appendingPathComponent("MeetingWaveShots")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        let defaults = UserDefaults.standard
        let oldStyle = defaults.object(forKey: "meetingWaveformStyle")
        defer { defaults.set(oldStyle, forKey: "meetingWaveformStyle"); window.isHidden = true }
        for style in [MeetingWaveStyle.weave, .tide, .braid] {
            defaults.set(style.rawValue, forKey: "meetingWaveformStyle")
            let model = DemoModel()
            let host = UIHostingController(rootView: DemoFace(model: model))
            window.rootViewController = host
            window.makeKeyAndVisible()
            for scheme in ["light", "dark"] {
                window.overrideUserInterfaceStyle = scheme == "light" ? .light : .dark
                for (label, tick, gain) in [("idle", 0, 0.0), ("quiet", 41, 0.24), ("loud", 86, 1.45), ("two-voices", 135, 1.0)] {
                    model.play(tick: tick, gain: Float(gain), keepClock: true)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.10))
                    let meter = try XCTUnwrap(edge(in: host.view))
                    meter.drawFrame(phase: 1, fraction: 1)
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { ctx in
                        window.layer.render(in: ctx.cgContext)
                    }
                    try XCTUnwrap(image.pngData()).write(to: folder.appendingPathComponent("\(style.rawValue)-\(scheme)-\(label).png"))
                }
            }
            try style.rawValue.write(to: folder.appendingPathComponent("playing"), atomically: true, encoding: .utf8)
            let start = CACurrentMediaTime()
            while CACurrentMediaTime() - start < 9 {
                model.play(tick: Int((CACurrentMediaTime() - start) * 20))
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            try FileManager.default.removeItem(at: folder.appendingPathComponent("playing"))
        }
    }
}

@MainActor private final class DemoModel: ObservableObject {
    @Published var frame = MeetingPreviewFrame(levels: [], seconds: 23, playing: true)
    func play(tick: Int, gain: Float = 1, keepClock: Bool = false) {
        let levels = ((tick - 47)...tick).map { min(1, MeetingDemoSpeech.sample(at: $0) * gain) }
        frame = .init(levels: levels, seconds: keepClock ? 23 : 23 + Double(tick / 20), playing: true)
    }
}

private struct DemoFace: View {
    @ObservedObject var model: DemoModel
    var body: some View { model.frame.recorder() }
}
