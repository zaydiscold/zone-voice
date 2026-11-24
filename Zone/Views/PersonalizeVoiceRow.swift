// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// The envelope of Zone's bundled test-clip.wav, sampled every 50 ms.
enum VoicePreviewSpeech {
    static let samples: [UInt8] = [
        55, 91, 93, 82, 41, 71, 97, 99, 85, 42, 67, 95, 94, 92, 89, 86,
        74, 27, 0, 0, 0, 0, 52, 95, 100, 98, 98, 92, 92, 97, 99, 94,
        78, 80, 94, 59, 21, 80, 97, 97, 87, 25, 90, 95, 92, 82, 87, 80,
        64, 9, 0, 0, 0, 79, 97, 94, 92, 65, 0, 3, 89, 94, 92, 84,
        71, 38, 0, 0, 0, 0, 40, 83, 96, 95, 93, 78, 19, 80, 97, 97,
        94, 92, 92, 67, 92, 92, 88, 44, 80, 88, 35, 50, 91, 94, 92, 77,
        27, 0, 78, 98, 95, 92, 43, 0, 80, 94, 92, 92, 61, 0, 19, 89,
        86, 47, 77, 94, 93, 83, 76, 93, 92, 88, 81, 69, 27, 12, 0, 0
    ]

    static func history(at tick: Int, gain: Float = 1) -> [Float] {
        ((tick - 35)...tick).map { i in
            let index = (i % samples.count + samples.count) % samples.count
            return gain * Float(samples[index]) / 100
        }
    }
}

struct PersonalizeVoiceRow: View {
    @Environment(AppSettings.self) private var settings
    var body: some View {
        @Bindable var settings = settings
        VStack(spacing: 8) {
            Picker(selection: $settings.meterStyle) {
                ForEach(MeterStyle.allCases, id: \.self) { Text($0.label).tag($0) }
            } label: {
                Label("Voice graphic", systemImage: "waveform")
            }
            .accessibilityIdentifier("settings.voiceGraphic")
            VoiceGraphicSample(style: settings.meterStyle)
        }
    }
}

private struct VoicePreviewPageActive: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var voicePreviewPageActive: Bool {
        get { self[VoicePreviewPageActive.self] }
        set { self[VoicePreviewPageActive.self] = newValue }
    }
}

struct VoicePreviewPageVisibility: ViewModifier {
    @State private var active = false

    func body(content: Content) -> some View {
        content.environment(\.voicePreviewPageActive, active)
            .onAppear { active = true }
            .onDisappear { active = false }
    }
}

/// Only the sample redraws at the playback rate. Keep the native picker's menu stable.
private struct VoiceGraphicSample: View {
    let style: MeterStyle
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.voicePreviewPageActive) private var pageActive
    @State private var tick = 0
    @State private var visible = false

    var body: some View {
        let playing = visible && pageActive && phase == .active && !reduceMotion
        Group {
            if playing {
                RecorderVoiceGraphic(style: style, levels: VoicePreviewSpeech.history(at: tick))
            } else {
                stillFrame
            }
        }
        .frame(height: 48)
        .padding(.horizontal, 8)
        .overlay {
            if visible && pageActive && phase == .active {
                MicLight(surface: .composer(16), previewLevel: playing ? Float(VoicePreviewSpeech.samples[tick % VoicePreviewSpeech.samples.count]) / 100 : 0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Voice graphic preview")
        .accessibilityValue(style.label)
        .accessibilityIdentifier("settings.voicePreview")
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .task(id: playing) {
            guard playing else { return }
            let clock = ContinuousClock()
            let start = clock.now
            while !Task.isCancelled {
                let elapsed = start.duration(to: clock.now).components
                tick = Int(elapsed.seconds) * 20 + Int(elapsed.attoseconds / 50_000_000_000_000_000)
                do { try await clock.sleep(until: start.advanced(by: .milliseconds((tick + 1) * 50))) }
                catch { return }
            }
        }
    }

    @ViewBuilder private var stillFrame: some View {
        let accent = Zone.accentTone(scheme)
        if style == .scope {
            DotScopeView(phase: .recording, tuning: .bar(fade: 20, spacing: 3.25),
                         drawPlate: false, demoVoice: true, frozenPreview: true)
        } else if style.isDrawn {
            Canvas { context, size in
                guard let engine = VoiceArtEngine(style: style, seed: 17) else { return }
                for level in VoicePreviewSpeech.samples.prefix(85) {
                    engine.feed(level: Float(level) / 100)
                    engine.advance(by: 0.05, size: size)
                }
                func color(_ c: Color) -> ArtColor {
                    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
                    UIColor(c).getRed(&r, green: &g, blue: &b, alpha: nil)
                    return ArtColor(r, g, b)
                }
                context.withCGContext {
                    engine.draw(in: $0, size: size, palette: .init(ink: color(Zone.ink(scheme)),
                                accent: color(accent), isDark: scheme == .dark))
                }
            }
        } else {
            FlowingWave(levels: VoicePreviewSpeech.history(at: 35),
                        color: UIColor(Zone.accentTone(scheme == .dark ? .light : .dark)),
                        edgeColor: UIColor(accent), style: style, stillFrame: true)
        }
    }
}
