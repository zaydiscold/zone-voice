// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// Developer-facing checks, kept out of the normal flow. The test clip run is the
/// "offline ASR validated" evidence: a known 16 kHz recording through the exact dictation path.
struct DiagnosticsView: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @State private var clipText = ""
    @State private var clipLatency: TimeInterval?
    @State private var clipRunning = false
    @State private var clipError: String?
    @State private var sharedSummary = ""
    @State private var switchingEngine = false

    var body: some View {
        List {
            Section {
                Picker("Engine", selection: Binding(
                    get: { coordinator.engineKind },
                    set: { kind in
                        switchingEngine = true
                        Task {
                            await coordinator.switchEngine(to: kind)
                            switchingEngine = false
                        }
                    })) {
                    ForEach(EngineKind.allCases.filter(\.isAvailableOnThisOS)) { kind in
                        Text(kind.shortName).tag(kind)
                    }
                }
                .disabled(switchingEngine || coordinator.modelSwitchBlocker != nil)
                LabeledContent("State", value: modelLabel)
                LabeledContent("On disk", value: coordinator.engineBytesOnDisk.byteCountLabel)
                NavigationLink("Manage model storage") { ModelLibraryView() }
                NavigationLink("Engine bakeoff") { BakeoffView() }
            } header: {
                Text("Engine")
            } footer: {
                Text("For measurement only. Choose your everyday model and manage its downloads in Model size.")
            }

            Section {
                Button(clipRunning ? "Running…" : "Transcribe test clip") {
                    runClip()
                }
                .disabled(clipRunning || !coordinator.modelIsReady)
                if let clipLatency {
                    LabeledContent("Processing time, whole clip", value: String(format: "%.0f ms", clipLatency * 1000))
                }
                if !clipText.isEmpty {
                    Text(clipText).font(.body).textSelection(.enabled)
                    let hits = TestClip.expectedPhrases.filter { clipText.lowercased().contains($0) }
                    LabeledContent("Expected phrases found", value: "\(hits.count) of \(TestClip.expectedPhrases.count)")
                }
                if let clipError {
                    Text(clipError).foregroundStyle(.red)
                }
            } header: {
                Text("Engine check")
            } footer: {
                Text("Runs a bundled 6-second clip (\"The meeting is at three thirty, not four…\") through the same streaming path the keyboard uses. Works in airplane mode once the model is downloaded.")
            }

            Section {
                NavigationLink("Recording log") { RecordingLogView() }
            } footer: {
                Text("Every recording's starts, pauses for calls or alarms, resumes, stops and saves, from the app and the keyboard. Kept on this iPhone for two weeks; no words are in it.")
            }

            Section {
                LabeledContent("Stored MetricKit reports", value: "\(MetricsRecorder.shared.storedReportCount)")
            } header: {
                Text("MetricKit")
            } footer: {
                Text("iOS 27 reports keyboard memory terminations here. Reports land in Application Support/Diagnostics.")
            }

            Section("Shared state") {
                Button("Read App Group state") { sharedSummary = coordinator.sharedStateSummary() }
                if !sharedSummary.isEmpty {
                    Text(sharedSummary).font(.caption.monospaced()).textSelection(.enabled)
                }
                Button("Clear dictation records", role: .destructive) {
                    coordinator.clearSharedDictationRecords()
                    sharedSummary = coordinator.sharedStateSummary()
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Diagnostics")
        .zoneBackButton()
        .zoneScreen()
    }

    private var modelLabel: String {
        switch coordinator.modelState {
        case .missing: return "Missing"
        case .downloading(let p, _): return "Downloading \(Int(p * 100))%"
        case .loading: return "Loading"
        case .ready: return "Ready"
        case .failed(let m): return "Failed: \(m)"
        }
    }

    private func runClip() {
        clipRunning = true
        clipError = nil
        clipText = ""
        clipLatency = nil
        Task {
            do {
                let outcome = try await coordinator.transcribeTestClip()
                clipText = outcome.text
                clipLatency = outcome.processingSeconds
            } catch {
                clipError = error.localizedDescription
            }
            clipRunning = false
        }
    }
}
