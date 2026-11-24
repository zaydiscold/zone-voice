// by zayd/cold @ zayd.wtf

import AVFoundation
import SwiftUI
import ZoneCore

/// Records the ten bakeoff clips, holds their corrected references, and runs the accuracy
/// pass and the matched energy runs. Reached only from Diagnostics.
struct BakeoffView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(DictationCoordinator.self) private var coordinator
    @State private var runner = BakeoffRunner()
    @State private var references: [Int: String] = [:]
    @State private var recordingID: Int?
    @State private var recordStarted: Date?
    @State private var clipSeconds: [Int: Double] = [:]
    @State private var selected: Set<EngineKind> = Set(EngineKind.allCases.filter(\.isAvailableOnThisOS))
    @State private var energyMode: BakeoffRunner.EnergyMode = .foreground
    @State private var player: AVAudioPlayer?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                ForEach(BakeoffPrompt.all) { prompt in
                    clipRow(prompt)
                }
            } header: {
                Text("1. Record ten clips")
            } footer: {
                Text("Read each line in your own words at normal distance, then fix the text below it to exactly what you said. Every engine hears these same files.")
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                ForEach(EngineKind.allCases.filter(\.isAvailableOnThisOS)) { kind in
                    Toggle(kind.displayName, isOn: Binding(
                        get: { selected.contains(kind) },
                        set: { if $0 { selected.insert(kind) } else { selected.remove(kind) } }))
                }
                Button(runner.isRunning ? "Running…" : "Run accuracy pass") {
                    BakeoffFiles.saveReferences(references)
                    let engines = EngineKind.allCases.filter { selected.contains($0) }
                    Task { await runner.runAccuracy(engines: engines, references: references, coordinator: coordinator) }
                }
                .disabled(runner.isRunning || recordedCount == 0 || selected.isEmpty)
                if runner.isRunning {
                    Button("Cancel", role: .destructive) { runner.cancel() }
                }
                if !runner.status.isEmpty {
                    Text(runner.status).font(.footnote)
                }
            } header: {
                Text("2. Accuracy, latency, memory")
            } footer: {
                Text("Plug in and keep the screen on. Each engine loads alone, gets one untimed warm-up, then hears all clips at real-time pace. Models download on first use.")
            }
            .listRowBackground(Zone.card(scheme))

            if let report = runner.lastAccuracy {
                Section("Results") {
                    ForEach(report.engines, id: \.engine) { result in
                        resultRow(result)
                    }
                }
                .listRowBackground(Zone.card(scheme))
            }

            Section {
                LabeledContent("Engine", value: coordinator.engineKind.shortName)
                Picker("Where Zone is", selection: $energyMode) {
                    Text("On screen").tag(BakeoffRunner.EnergyMode.foreground)
                    Text("In background (Messages)").tag(BakeoffRunner.EnergyMode.background)
                }
                Button(runner.isRunning ? "Running…" : "Start five-minute energy run") {
                    Task { await runner.runEnergy(mode: energyMode, coordinator: coordinator) }
                }
                .disabled(runner.isRunning || recordedCount == 0 || !coordinator.modelIsReady)
                ForEach(Array(runner.energyLog.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced())
                }
            } header: {
                Text("3. Energy (unplugged, Power Profiler)")
            } footer: {
                Text("Choose the engine in Diagnostics first. Unplug, start Power Profiler (Settings > Developer > Performance Trace), then start the run. It arms a session and replays one clip every 30 seconds for five minutes. For the background run, switch to Messages during the countdown and leave the keyboard up.")
            }
            .listRowBackground(Zone.card(scheme))

            Section("Reports") {
                ForEach(BakeoffFiles.reports(), id: \.self) { url in
                    ShareLink(item: url) {
                        Text(url.lastPathComponent).font(.caption.monospaced())
                    }
                }
            }
            .listRowBackground(Zone.card(scheme))

            if let error {
                Text(error).foregroundStyle(.red)
                    .listRowBackground(Zone.card(scheme))
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Engine bakeoff")
        .zoneBackButton()
        .zoneScreen()
        .onAppear(perform: load)
        .onDisappear {
            BakeoffFiles.saveReferences(references)
            if recordingID != nil { _ = coordinator.stopClipCapture() }
        }
    }

    private var recordedCount: Int { BakeoffPrompt.all.filter { BakeoffFiles.hasClip($0.id) }.count }

    @ViewBuilder
    private func clipRow(_ prompt: BakeoffPrompt) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(prompt.id). \(prompt.category)").font(.subheadline.weight(.semibold))
                Spacer()
                if let seconds = clipSeconds[prompt.id] {
                    Text(String(format: "%.1f s", seconds)).font(.caption.monospacedDigit())
                }
                if BakeoffFiles.hasClip(prompt.id), recordingID == nil {
                    Button { play(prompt.id) } label: { Image(systemName: "play.circle") }
                        .buttonStyle(.borderless)
                }
                Button {
                    toggleRecording(prompt.id)
                } label: {
                    Image(systemName: recordingID == prompt.id ? "stop.circle.fill" : "record.circle")
                        .foregroundStyle(recordingID == prompt.id ? .red : .primary)
                }
                .buttonStyle(.borderless)
                .disabled(runner.isRunning || (recordingID != nil && recordingID != prompt.id))
            }
            Text(prompt.instruction).font(.caption).foregroundStyle(.secondary)
            TextField("What you said", text: Binding(
                get: { references[prompt.id] ?? prompt.script },
                set: { references[prompt.id] = $0 }), axis: .vertical)
                .font(.callout)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func resultRow(_ result: EngineResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.engine.shortName).font(.subheadline.weight(.semibold))
            if let failure = result.error {
                Text(failure).font(.caption).foregroundStyle(.red)
            } else {
                Text(String(format: "WER %.1f%%   stop-to-text p50 %.0f ms, p90 %.0f ms",
                            result.pooledWER.rate * 100, result.medianStopToTextMs ?? 0, result.p90StopToTextMs ?? 0))
                    .font(.caption.monospacedDigit())
                Text("peak \(Int64(result.peakFootprint).byteCountLabel), loaded \(Int64(result.footprintAfterLoad).byteCountLabel), load \(String(format: "%.1f", result.loadSeconds)) s, CPU \(String(format: "%.3f", result.cpuPerAudioSecond ?? 0)) s per audio s")
                    .font(.caption.monospacedDigit())
            }
        }
    }

    private func load() {
        references = BakeoffFiles.loadReferences()
        for prompt in BakeoffPrompt.all where BakeoffFiles.hasClip(prompt.id) {
            if let samples = try? BakeoffFiles.readClip(prompt.id) {
                clipSeconds[prompt.id] = Double(samples.count) / 16_000
            }
        }
    }

    private func toggleRecording(_ id: Int) {
        error = nil
        if recordingID == id {
            let samples = coordinator.stopClipCapture()
            recordingID = nil
            do {
                try BakeoffFiles.writeClip(samples, id: id)
                clipSeconds[id] = Double(samples.count) / 16_000
            } catch {
                self.error = RecordingProblem.storage.message(for: error)
            }
            return
        }
        player?.stop()
        Task {
            do {
                try await coordinator.startClipCapture()
                recordingID = id
                recordStarted = Date()
            } catch {
                self.error = RecordingProblem.microphone.message(for: error)
            }
        }
    }

    private func play(_ id: Int) {
        player = try? AVAudioPlayer(contentsOf: BakeoffFiles.clipURL(id))
        player?.play()
    }
}
