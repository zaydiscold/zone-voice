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
    @AppStorage("meetingWaveformStyle") private var waveform = EdgeEqualizer.Style.flow.rawValue
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
                    ForEach(EdgeEqualizer.Style.allCases) { Text($0.title).tag($0.rawValue) }
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
        .tint(Zone.accentText(scheme))
        .navigationTitle("Meeting appearance")
        .zoneBackButton()
        .navigationBarTitleDisplayMode(.inline)
        .zoneScreen()
    }

    private var waveformDescription: String {
        switch EdgeEqualizer.Style(rawValue: waveform) ?? .flow {
        case .flow: "Audio ripples around the screen edge."
        case .breath: "The border expands and contracts with your voice."
        case .glow: "Static border that brightens with sound."
        }
    }
}

private struct MeetingMotionPreview: View {
    @AppStorage("meetingWaveformStyle") private var waveform = EdgeEqualizer.Style.flow.rawValue
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var seconds = 3598.0
    @State private var samples: [Float] = Array(repeating: 0, count: 48)
    @State private var playing = true

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Zone.paper(scheme)
                EdgeEqualizer(levels: samples, color: UIColor(Zone.accentGraphic(scheme)),
                              active: playing && scenePhase == .active,
                              style: EdgeEqualizer.Style(rawValue: waveform) ?? .flow)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                VStack(spacing: 4) {
                    MeetingTimerText(seconds: seconds, fontSize: 52)
                    Text("Preview").font(.caption).foregroundStyle(Zone.muted(scheme))
                }
                .padding(24)
            }
            .frame(height: 200)
            .clipShape(Zone.cardShape)
            HStack {
                Button(playing ? "Pause preview" : "Play preview") { playing.toggle() }
                Spacer()
                Button("Hour rollover") { seconds = 3598; playing = true }
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
                guard playing else { continue }
                tick += 1
                let t = Double(tick) * 0.05
                samples.removeFirst()
                samples.append(Float(max(0, sin(t * 2.3)) * (0.25 + 0.15 * sin(t * 11))))
                if tick % 20 == 0 { seconds += 1 }
            }
        }
    }
}
