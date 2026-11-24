// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// The same clock is used in the recorder and the Settings preview. Stable columns let the
/// hour slide into place without replacing the minute/second views at 59:59.
struct MeetingTimerText: View {
    let seconds: TimeInterval
    @ScaledMetric(relativeTo: .largeTitle) var fontSize: CGFloat = 88
    @AppStorage("meetingTimerAnimated") private var animated = true
    @AppStorage("meetingTimerPace") private var pace = 0.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var whole: Int { Int(max(0, min(seconds.isFinite ? seconds : 0, 3_599_999))) }
    private var hours: Int { whole / 3600 }

    var body: some View {
        let cell = fontSize * 0.62
        let separator = fontSize * 0.28
        let hourWidth = hours > 0 ? cell * CGFloat(String(hours).count) : 0
        let width = cell * 4 + separator + hourWidth + (hours > 0 ? separator : 0)
        let motion: Animation? = animated && !reduceMotion
            ? .smooth(duration: pace == 0.3 ? 0.3 : 0.5, extraBounce: 0) : nil
        GeometryReader { geometry in
            HStack(spacing: 0) {
                Text(String(hours))
                    .contentTransition(animated && !reduceMotion ? .numericText() : .identity)
                    .frame(width: hourWidth)
                    .opacity(hours > 0 ? 1 : 0)
                    .clipped()
                colon(width: hours > 0 ? separator : 0).opacity(hours > 0 ? 1 : 0)
                digit((whole / 60 % 60) / 10, width: cell)
                digit(whole / 60 % 10, width: cell)
                colon(width: separator)
                digit(whole % 60 / 10, width: cell)
                digit(whole % 10, width: cell)
            }
            .font(.system(size: fontSize, weight: .semibold, design: .serif).monospacedDigit())
            .fixedSize(horizontal: true, vertical: false)
            .scaleEffect(min(1, geometry.size.width / max(width, 1)))
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(motion, value: whole)
        }
        .frame(height: min(fontSize * 1.25, 110))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recorded \(MeetingExport.durationLabel(seconds))")
    }

    private func digit(_ value: Int, width: CGFloat) -> some View {
        Text(String(value))
            .contentTransition(animated && !reduceMotion ? .numericText() : .identity)
            .frame(width: width)
    }

    private func colon(width: CGFloat) -> some View {
        Text(":").opacity(0.55).frame(width: width).clipped()
    }
}

struct MeetingAppearanceView: View {
    @Environment(MeetingCoordinator.self) private var meetings
    @AppStorage(MeetingWaveStyle.preferenceKey) private var waveform = MeetingWaveStyle.defaultStyle.rawValue
    @AppStorage("meetingTimerAnimated") private var animated = true
    @AppStorage("meetingTimerPace") private var pace = 0.5
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Form {
            Section {
                MeetingMotionPreview()
                    .listRowInsets(EdgeInsets())
            } footer: {
                Text("Simulated audio preview. Nothing is recorded.")
            }
            .listRowBackground(Zone.card(scheme))

            Section("Timer") {
                Toggle("Animate numbers", isOn: $animated)
                if animated {
                    Picker("Pace", selection: $pace) {
                        Text("Gentle").tag(0.5)
                        Text("Brisk").tag(0.3)
                    }
                    .disabled(reduceMotion)
                }
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                Picker("Style", selection: $waveform) {
                    ForEach(MeetingWaveStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } header: {
                Text("Waveform")
            } footer: {
                Text(waveformDescription)
                if reduceMotion {
                    Text("Reduce Motion is enabled. Digits update statically and the border responds by brightness.")
                }
            }
            .listRowBackground(Zone.card(scheme))
        }
        .scrollContentBackground(.hidden)
        .tint(Zone.inlineInk(scheme))
        .onChange(of: waveform) { _, _ in meetings.refreshIslandAppearance() }
        .navigationTitle("Meeting appearance")
        .zoneBackButton()
        .navigationBarTitleDisplayMode(.inline)
        .zoneScreen()
    }

    private var waveformDescription: String {
        MeetingWaveStyle(preference: waveform).detail
    }
}

struct MeetingPreviewFrame {
    let levels: [Float]
    let seconds: Double
    let playing: Bool

    func recorder(insets: EdgeInsets = EdgeInsets()) -> some View {
        MeetingRecorderFace(edge: MeetingEdge(levels: levels, active: playing), seconds: { seconds },
                            title: "Meeting", isPaused: !playing, previewInsets: insets)
    }
}

/// A short exchange. The second voice answers early on the last phrase. The meter sees
/// one mixed envelope, just as it does with one microphone in a room.
enum MeetingDemoSpeech {
    private static let syllables: [(start: Int, length: Int, stress: Float)] = [
        (8, 5, 0.37), (14, 4, 0.19), (20, 9, 0.50), (33, 5, 0.25), (39, 7, 0.42),
        (62, 8, 0.72), (72, 4, 0.29), (78, 7, 0.56), (89, 5, 0.36),
        (103, 9, 0.55), (114, 6, 0.32), (123, 8, 0.49),
        (109, 7, 0.41), (118, 8, 0.65), (130, 5, 0.34), (138, 8, 0.46)
    ]
    static func sample(at tick: Int) -> Float {
        let t = tick % 168
        var power: Float = 0
        for beat in syllables where (beat.start..<beat.start + beat.length).contains(t) {
            let age = Float(t - beat.start) / Float(beat.length)
            let amplitude = beat.stress * min(1, (age + 0.08) * 4) * (1 - age * age)
            power += amplitude * amplitude
        }
        return min(1, sqrt(power))
    }
}

/// Render the recorder at phone dimensions, then scale the complete face. The Settings
/// row never supplies its own timer color, border weight, corner radius or status label.
struct MeetingRecorderMiniature: View {
    let frame: MeetingPreviewFrame
    @State private var display = PreviewDisplay()
    var body: some View {
        GeometryReader { geometry in
            let size = display.size
            let scale = min(geometry.size.width / size.width, geometry.size.height / size.height)
            let radius = display.insets.bottom > 0 ? min(size.width, size.height) * 56 / 393 : 0
            frame.recorder(insets: display.insets)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: radius))
                .scaleEffect(scale)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .background(PreviewWindow { display = $0 })
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct PreviewDisplay: Equatable {
    var size = CGSize(width: 393, height: 852)
    var insets = EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
}

/// Use the very window containing the Settings row, including when the phone rotates.
private struct PreviewWindow: UIViewRepresentable {
    let measured: (PreviewDisplay) -> Void
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) { view.measured = measured }

    final class Probe: UIView {
        var measured: ((PreviewDisplay) -> Void)?
        private var previous: PreviewDisplay?
        override func didMoveToWindow() { super.didMoveToWindow(); measure() }
        override func layoutSubviews() { super.layoutSubviews(); measure() }
        override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); measure() }

        private func measure() {
            guard let window, !window.bounds.isEmpty else { return }
            let i = window.safeAreaInsets
            let display = PreviewDisplay(size: window.bounds.size,
                insets: EdgeInsets(top: i.top, leading: i.left, bottom: i.bottom, trailing: i.right))
            guard display != previous else { return }
            previous = display
            DispatchQueue.main.async { [weak self] in self?.measured?(display) }
        }
    }
}

private struct MeetingMotionPreview: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var seconds = 0.0
    @State private var samples: [Float] = Array(repeating: 0, count: MeetingWaveSignal.count)
    @State private var playing = true

    var body: some View {
        VStack(spacing: 12) {
            MeetingRecorderMiniature(frame: .init(levels: samples, seconds: seconds, playing: playing))
                .frame(height: 286)
            HStack {
                Button(playing ? "Pause preview" : "Play preview") { playing.toggle() }
                #if DEBUG
                Spacer()
                Button("Hour rollover") { seconds = 3598; playing = true }
                #endif
            }
            .font(.footnote)
            .buttonStyle(.borderless)
            .frame(minHeight: 44)
        }
        .padding(16)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            var tick = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                if playing { tick += 1 }
                if playing || samples.contains(where: { $0 != 0 }) {
                    samples.removeFirst()
                    samples.append(playing ? MeetingDemoSpeech.sample(at: tick) : 0)
                }
                if playing && tick % 20 == 0 { seconds += 1 }
            }
        }
    }
}
