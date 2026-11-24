// by zayd/cold @ zayd.wtf

import AVFAudio
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

#if DEBUG
private enum VoiceTestSurface: String, CaseIterable {
    case home, note, recorder, keyboard
    var size: CGSize {
        switch self {
        case .home: CGSize(width: 148, height: 36)
        case .note: CGSize(width: 205, height: 40)
        case .recorder: CGSize(width: 225, height: 64)
        case .keyboard: CGSize(width: 188, height: 32)
        }
    }
}

private func voiceTaskEnergy() -> UInt64 {
    #if arch(arm64)
    var info = task_power_info_v2_data_t()
    var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.stride)
    let capacity = Int(count)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
            task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO_V2), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.task_energy : 0
    #else
    return 0
    #endif
}

@MainActor
private struct VoiceProbeFace: View {
    let style: MeterStyle
    let levels: [Float]
    let surface: VoiceTestSurface
    var body: some View {
        RecorderVoiceGraphic(style: style, levels: levels).frame(width: surface.size.width, height: surface.size.height)
            .environment(\.scenePhase, .active)
    }
}

@MainActor
private final class VoiceFrameSampler: NSObject {
    var capture: () -> Void = {}
    @objc func tick() { capture() }
}

extension VoiceArtViewTests {
    func testMountedRendererCadence() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        defer { window.isHidden = true }
        for surface in VoiceTestSurface.allCases {
            for style in MeterStyle.allCases {
                var levels = (0..<36).map { Float(0.55 + 0.42 * sin(Double($0))) }
                let host = UIHostingController(rootView: VoiceProbeFace(style: style, levels: levels, surface: surface))
                window.rootViewController = host
                window.makeKeyAndVisible()
                host.view.layoutIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                func find<T: UIView>(_ type: T.Type, in parent: UIView) -> T? {
                    if let view = parent as? T { return view }
                    for child in parent.subviews { if let view = find(type, in: child) { return view } }
                    return nil
                }
                let wave = find(FlowingWave.WaveView.self, in: host.view)
                let art = find(VoiceArtCanvasView.self, in: host.view)
                let scope = find(DotScopeHostView.self, in: host.view)
                let bars = find(SignalLevelMeter.LevelBarsView.self, in: host.view)
                XCTAssertTrue(wave != nil || art != nil || scope != nil || bars != nil)
                var deliveries: [Double] = []
                var changes = 0, displayTicks = 0, lastStamp = -1, lastHeight = -1.0
                let sampler = VoiceFrameSampler()
                sampler.capture = {
                    let before = changes
                    defer { if before != changes { deliveries.append(CACurrentMediaTime()) } }
                    displayTicks += 1
                    if let bars, let bar = bars.layer.sublayers?.last as? CAShapeLayer,
                       let height = bar.presentation()?.path?.boundingBox.height {
                        if height != lastHeight { changes += 1; lastHeight = height }
                    } else if let stamp = wave?.probeFrames ?? art?.probeFrames ?? scope?.probeFrames {
                        if stamp != lastStamp { changes += 1; lastStamp = stamp }
                    }
                }
                let clock = CADisplayLink(target: sampler, selector: #selector(VoiceFrameSampler.tick))
                clock.preferredFrameRateRange = .init(minimum: 60, maximum: 120, preferred: 120)
                clock.add(to: .main, forMode: .common)
                let initialEnergy = voiceTaskEnergy()
                let cpuStart = Darwin.clock()
                let start = CACurrentMediaTime()
                var sample = -1
                while CACurrentMediaTime() - start < 1.5 {
                    let t = CACurrentMediaTime() - start
                    if Int(t * 12) != sample {
                        sample = Int(t * 12)
                        levels.removeFirst()
                        levels.append(Float(0.55 + 0.42 * sin(Double(sample))))
                        host.rootView = VoiceProbeFace(style: style, levels: levels, surface: surface)
                    }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.002))
                }
                clock.invalidate()
                let seconds = CACurrentMediaTime() - start
                let cpu = 100 * Double(Darwin.clock() - cpuStart) / Double(CLOCKS_PER_SEC) / seconds
                let gaps = zip(deliveries.dropFirst(), deliveries).map { ($0 - $1) * 1000 }.sorted()
                let p95 = gaps.isEmpty ? 0 : gaps[Int(Double(gaps.count - 1) * 0.95)]
                let endEnergy = voiceTaskEnergy()
                let energy = endEnergy > initialEnergy ? endEnergy - initialEnergy : 0
                print("VOICE_CADENCE surface=\(surface.rawValue) p95ms=\(p95) taskEnergy=\(energy) \(style.rawValue) changes=\(changes) ticks=\(displayTicks) seconds=\(seconds) cpu=\(cpu) max=\(scene.screen.maximumFramesPerSecond)")
            }
        }
    }
}

#endif

@MainActor
private final class VoiceGalleryModel: ObservableObject {
    @Published var levels = [Float](repeating: 0, count: 36)
    @Published var label = "Silence"
    @Published var dark = false
}

private struct VoiceGallery: View {
    let style: MeterStyle
    @ObservedObject var model: VoiceGalleryModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(style.label).font(.largeTitle.bold())
            Text(model.label).font(.headline)
            ForEach(Array(zip(["Fine", "Balanced", "Broad"], [0.75, 1.0, 1.4])), id: \.0) { name, detail in
                VStack(alignment: .leading, spacing: 10) {
                    Text(name).font(.caption)
                    RecorderVoiceGraphic(style: style, levels: model.levels, detail: detail)
                        .frame(height: 52)
                }.padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }.padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(model.dark ? Color(white: 0.08) : Color(white: 0.95))
            .environment(\.colorScheme, model.dark ? .dark : .light)
            .environment(\.scenePhase, .active)
    }
}

extension VoiceArtViewTests {
    func testVoiceTreatmentGallery() throws {
        guard ProcessInfo.processInfo.environment["ZONE_VOICE_GALLERY"] == "1" else { return }
        let folder = URL.documentsDirectory.appendingPathComponent("VoiceGraphicGallery")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let marker = folder.appendingPathComponent("playing")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        defer { window.isHidden = true; try? FileManager.default.removeItem(at: marker) }
        for style in MeterStyle.allCases {
            let model = VoiceGalleryModel()
            let host = UIHostingController(rootView: VoiceGallery(style: style, model: model))
            window.rootViewController = host
            window.makeKeyAndVisible()
            for (scheme, dark) in [("light", false), ("dark", true)] {
                model.dark = dark
                for (label, gain) in [("Silence", Float(0)), ("Quiet", 0.23), ("Loud", 1)] {
                    model.label = label
                    let start = CACurrentMediaTime()
                    try "\(style.rawValue)-\(scheme)-\(label.lowercased())".write(to: marker, atomically: true, encoding: .utf8)
                    while CACurrentMediaTime() - start < 3 {
                        let tick = Int((CACurrentMediaTime() - start) * 20)
                        model.levels = VoicePreviewSpeech.history(at: tick + 45, gain: gain)
                        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    }
                }
            }
        }
    }
}

extension VoiceArtViewTests {
    func testPersonalizeAndLiveWaveUseTheSameRendererForEachChoice() throws {
        let suite = "voice-graphic-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsSharedStore(suiteName: suite)
        let settings = AppSettings(defaults: defaults, store: store)
        let coordinator = DictationCoordinator(settings: settings, store: store)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        func renderer(in view: UIView) -> String? {
            if view is FlowingWave.WaveView || view is VoiceArtCanvasView || view is DotScopeHostView {
                return NSStringFromClass(type(of: view))
            }
            return view.subviews.lazy.compactMap { renderer(in: $0) }.first
        }
        // Both sides animate: an active scene and Reduce Motion off, whatever the simulator's own
        // setting. Settings plays the sample only on a page that applies VoicePreviewPageVisibility
        // (6c111874); without it the row shows its still meter, so the row is mounted the same way.
        func mounted<V: View>(_ view: V) throws -> String {
            let host = UIHostingController(rootView: view.environment(settings).environment(coordinator)
                .environment(\.scenePhase, .active)
                .environment(\._accessibilityReduceMotion, false))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            // The page and the sample turn on in onAppear, a pass after the first layout.
            let deadline = Date().addingTimeInterval(1)
            var found = renderer(in: host.view)
            while found == nil, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                host.view.layoutIfNeeded()
                found = renderer(in: host.view)
            }
            return try XCTUnwrap(found, "No voice renderer mounted for \(V.self)")
        }
        for style in MeterStyle.allCases {
            settings.meterStyle = style
            let preview = try mounted(PersonalizeVoiceRow().modifier(VoicePreviewPageVisibility()))
            let recorder = try mounted(LiveWave())
            XCTAssertEqual(preview, recorder, style.label)
        }
    }
}

#if targetEnvironment(simulator)
extension VoiceArtViewTests {
    func testMeasureSimulatorLevelArrival() async throws {
        let capture = AudioCaptureEngine()
        var arrivals: [CFTimeInterval] = []
        capture.onSamples = { _ in }
        capture.onLevel = { _ in arrivals.append(CACurrentMediaTime()) }
        try await capture.arm()
        defer { capture.stopRecording(); capture.disarm() }
        capture.startRecording()
        try await Task.sleep(for: .seconds(3))
        let intervals = zip(arrivals.dropFirst(), arrivals).map { $0 - $1 }.sorted()
        XCTAssertFalse(intervals.isEmpty)
        if !intervals.isEmpty {
            print("VOICE_INPUT rate=\(AVAudioSession.sharedInstance().sampleRate) requestedFrames=2048 levels=\(arrivals.count) medianInterval=\(intervals[intervals.count / 2])")
        }
    }
}
#endif
