// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// Settings > Speech model. Since 2026-11-18 Zone has one speech model, so this screen
/// explains it instead of offering a choice: what it is, its download and storage, and a
/// top-down card of what happens between speaking and text landing in an app.
///
/// When the bakeoff has measured the model on this phone's own clips, that result shows as
/// mistakes per 100 words. Publishers' benchmark numbers are not shown: each comes from a
/// different test set and says nothing about this person's voice.
struct ModelLibraryView: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var scheme
    @State private var inventory: ModelLibraryInventory?
    @State private var measured: [EngineKind: EngineResult] = [:]
    @State private var keyboardRecognition = KeyboardVoiceRoute.load().mode
    @State private var selecting = false
    @State private var clearingHelper = false
    @State private var pendingDelete: [SpeechModel]?

    private var keyboardRouteLabel: String {
        switch keyboardRecognition {
        case .standard: "Zone default"
        case .webView: "Fluid Speech Mini · iPhone"
        case .computer: "Zone Link GPU · Beta"
        }
    }

    private let model = SpeechModel.fluidSpeechMini

    var body: some View {
        List {
            if let notice = coordinator.libraryNotice {
                Text(notice).font(.subheadline).accessibilityIdentifier("modelCleanupResult")
            }
            Section {
                modelCard
            }
            .listRowBackground(Zone.card(scheme))

            if coordinator.selectedModel != model {
                // Only Diagnostics can pick another engine (Apple's, for comparison).
                Section {
                    Text("Diagnostics switched dictation to \(coordinator.selectedModel.displayName).")
                        .font(.subheadline)
                    Button(selecting ? "Switching…" : "Use \(model.displayName)") { select() }
                        .disabled(selecting || coordinator.isDeletingModels || !downloaded)
                }
                .listRowBackground(Zone.card(scheme))
            }

            Section {
                SpeechPipelineCard()
                DisclosureGroup("What changes when I use the keyboard?") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Selected keyboard route", value: keyboardRouteLabel)
                        Label("With Zone ready, the app handles recognition.", systemImage: "waveform")
                        Label("With the app closed, the keyboard uses its configured route. Fluid Speech Mini in WebKit can run on iPhone after its separate download.", systemImage: "keyboard")
                        Label("Zone Link GPU (beta) can send the finished audio to your own server over HTTPS (for example, over Tailscale). Your words and writing style are applied on iPhone.", systemImage: "desktopcomputer")
                        NavigationLink("Choose keyboard recognition") { KeyboardVoiceSettings() }
                    }.font(.subheadline).padding(.vertical, 6)
                }
            } header: {
                Text("How your words get here")
            } footer: {
                Text("This is the on-device dictation path. Open the keyboard routes below the diagram to see where recognition can also run.")
            }
            .listRowBackground(Zone.card(scheme))

            storageSection
        }
        .scrollContentBackground(.hidden)
        .tint(Zone.inlineInk(scheme))
        .navigationTitle("Speech model")
        .zoneBackButton()
        .zoneScreen()
        .onAppear { loadMeasurements(); keyboardRecognition = KeyboardVoiceRoute.load().mode }
        .task(id: "\(coordinator.libraryRevision)-\(coordinator.isPreparingModel)-\(coordinator.selectedModel.rawValue)") {
            let snapshot = await ModelLibraryInventory.read()
            guard !Task.isCancelled else { return }
            inventory = snapshot
        }
        .alert("Model action failed", isPresented: Binding(
            get: { coordinator.libraryError != nil },
            set: { if !$0 { coordinator.clearLibraryError() } }
        )) {
            Button("OK", role: .cancel) { coordinator.clearLibraryError() }
        } message: {
            Text(coordinator.libraryError ?? "")
        }
        .confirmationDialog(
            pendingDelete.map { $0.count == 1 ? "Remove \($0[0].libraryName)?" : "Remove \($0.count) speech models?" } ?? "Remove speech models?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            if let models = pendingDelete {
                let bytes = models.reduce(Int64(0)) { $0 + (inventory?.entries[$1]?.storage.total ?? 0) }
                Button((coordinator.isArmed ? "Turn dictation off & remove " : "Remove ") + bytes.byteCountLabel, role: .destructive) {
                    pendingDelete = nil
                    Task { await coordinator.deleteModels(models) }
                }
            }
        } message: {
            Text(pendingDelete == [model]
                 ? "Your notes, recordings and transcripts stay. To dictate again, Zone downloads the model again."
                 : "Your notes, recordings and transcripts stay.")
        }
    }

    // MARK: Model

    private var storage: ModelStorageBreakdown {
        inventory?.entries[model]?.storage ?? ModelStorageBreakdown(directory: nil, preparedFiles: 0)
    }

    private var downloaded: Bool { inventory?.entries[model]?.downloaded == true }

    @ViewBuilder
    private var modelCard: some View {
        let progress = downloadProgress
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName).font(.title3.weight(.semibold))
                    Text("English · on this iPhone").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                action(progress: progress)
            }
            Text(model.blurb)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let progress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                        .tint(Zone.accentTone(scheme))
                    Text("\(Int64(Double(model.approximateDownloadBytes) * progress).byteCountLabel) of \(model.approximateDownloadBytes.byteCountLabel) · \(Int(progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Downloading \(model.libraryName)")
                .accessibilityValue("\(Int(progress * 100)) percent")
            } else {
                let facts = sizeFacts
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { ForEach(facts, id: \.text) { SizePill(fact: $0) } }
                    VStack(alignment: .leading, spacing: 4) { ForEach(facts, id: \.text) { SizePill(fact: $0) } }
                }
            }
            if let accuracy = accuracyLine {
                Text(accuracy).font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    detail("Model", "FluidVoice-Labs/fluid-speech-mini-coreml, built on NVIDIA Parakeet TDT v3")
                    detail("Runs with", "FluidAudio (Core ML), on the processor")
                    detail("Download", model.approximateDownloadBytes.byteCountLabel)
                    if storage.modelFiles > 0 { detail("Model files", storage.modelFiles.byteCountLabel) }
                    if storage.preparedFiles > 0 { detail("Prepared by iOS", storage.preparedFiles.byteCountLabel) }
                    if storage.helperFiles > 0 {
                        // The keyboard helper's own folder: only the helper can delete in it.
                        HStack(alignment: .firstTextBaseline) {
                            detail("Keyboard helper", storage.helperLeftovers > 0
                                   ? "\(storage.helperFiles.byteCountLabel), \(storage.helperLeftovers.byteCountLabel) left over"
                                   : storage.helperFiles.byteCountLabel)
                            Spacer(minLength: 8)
                            Button(clearingHelper ? "Clearing…" : "Clear") {
                                clearingHelper = true
                                Task {
                                    await coordinator.clearKeyboardHelperFiles()
                                    clearingHelper = false
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .disabled(clearingHelper || coordinator.isDeletingModels)
                            .accessibilityIdentifier("models.clearKeyboardHelper")
                            .accessibilityLabel("Clear keyboard helper files, \(storage.helperFiles.byteCountLabel)")
                        }
                    }
                    SettingsNote("Model storage", "Removal frees the download and prepared files.", detail: "You can also clear files kept by the keyboard speech helper here.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    detail("License", model.license)
                    detail("Comes from", model.downloadHost)
                }
                .padding(.top, 4)
            } label: {
                Text("Details").foregroundStyle(.secondary)
            }
            .font(.caption)
            .tint(.secondary)
        }
        .padding(.vertical, 6)
    }

    /// One action: what the person can do next with the model.
    @ViewBuilder
    private func action(progress: Double?) -> some View {
        if inventory == nil {
            BoundedProgress(message: "Storage did not load. Go back and open this page again.", limit: .seconds(10)) {
                ProgressView().controlSize(.small)
            }
        } else if progress != nil {
            // Offline, a download can wait for a connection for hours; this is the way out.
            Button("Cancel") { coordinator.cancelModelDownload(model) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Cancel downloading \(model.libraryName)")
        } else if downloaded && coordinator.selectedModel == model {
            Label("In use", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .zoneAccentBadge(scheme)
        } else if downloaded {
            Text("Downloaded").font(.subheadline).foregroundStyle(.secondary)
        } else {
            Button("Download") { Task { await coordinator.downloadModel(model) } }
                .buttonStyle(.bordered)
                .foregroundStyle(Zone.ink(scheme))
                .controlSize(.small)
                .disabled(coordinator.isDeletingModels)
                .accessibilityLabel("Download \(model.libraryName), \(model.approximateDownloadBytes.byteCountLabel)")
        }
    }

    /// The model's own size: measured files once they exist, the download size before that.
    private var sizeFacts: [SizeFact] {
        guard inventory != nil else { return [SizeFact(symbol: "hourglass", text: "Checking…", spoken: "Checking storage")] }
        if downloaded {
            var facts = [SizeFact(symbol: "shippingbox", text: storage.modelFiles.byteCountLabel,
                                  spoken: "\(storage.modelFiles.byteCountLabel) model")]
            if storage.preparedFiles > 0 {
                facts.append(SizeFact(symbol: "gearshape", text: "\(storage.preparedFiles.byteCountLabel) prepared",
                                      spoken: "\(storage.preparedFiles.byteCountLabel) prepared by iOS"))
            }
            return facts
        }
        var facts = [SizeFact(symbol: "arrow.down.circle", text: model.approximateDownloadBytes.byteCountLabel,
                              spoken: "\(model.approximateDownloadBytes.byteCountLabel) download")]
        if storage.modelFiles > 0 {
            facts.append(SizeFact(symbol: "shippingbox", text: "\(storage.modelFiles.byteCountLabel) so far",
                                  spoken: "\(storage.modelFiles.byteCountLabel) already stored"))
        }
        return facts
    }

    /// A library download, or the model in use fetching its files on the way to loading.
    private var downloadProgress: Double? {
        if let fraction = coordinator.libraryDownloads[model] { return fraction }
        guard model == coordinator.selectedModel, case .downloading(let fraction, _) = coordinator.modelState else { return nil }
        return fraction
    }

    /// Only when the bakeoff measured this model on the person's own recordings.
    private var accuracyLine: String? {
        guard let result = measured[model.productEngine], result.error == nil else { return nil }
        let per100 = max(0, (result.pooledWER.rate * 100).rounded())
        return "About \(Int(per100)) mistakes per 100 words on your recordings"
    }

    // MARK: Storage

    @ViewBuilder
    private var storageSection: some View {
        let stored = SpeechModel.allCases.filter { $0.needsDownload && (inventory?.entries[$0]?.storage.total ?? 0) > 0 }
        let retired = stored.filter(\.isRetired)
        Section {
            LabeledContent("Speech model storage", value: !coordinator.libraryDownloads.isEmpty ? "Updating…" : inventory == nil ? "Checking…" : stored.reduce(Int64(0)) {
                $0 + (inventory?.entries[$1]?.storage.total ?? 0)
            }.byteCountLabel)
            if coordinator.isDeletingModels {
                BoundedProgress(message: "Removing files is taking longer than usual. Reopen Zone to check storage.") {
                    ProgressView("Removing model files…")
                }
            } else if let blocker = coordinator.modelDeletionBlocker {
                Text(blocker).font(.footnote).foregroundStyle(.secondary)
            }
            if !retired.isEmpty {
                // Zone deletes these on launch; this is for a launch that could not.
                Button("Remove old models", role: .destructive) { pendingDelete = retired }
                    .disabled(coordinator.modelDeletionBlocker != nil || selecting)
                    .accessibilityIdentifier("removeRetiredSpeechModels")
            }
            Button("Remove speech model", role: .destructive) { pendingDelete = stored }
                .disabled(stored.isEmpty || coordinator.modelDeletionBlocker != nil || selecting)
                .accessibilityIdentifier("deleteAllSpeechModels")
        } header: {
            Text("Free up storage")
        } footer: {
            Text("Only the speech model is removed. Your notes, recordings and transcripts stay.")
        }
        .listRowBackground(Zone.card(scheme))
    }

    // MARK: Helpers

    private func detail(_ label: String, _ value: String) -> some View {
        (Text(label + ": ").foregroundStyle(.secondary) + Text(value))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func select() {
        selecting = true
        Task {
            await coordinator.selectModel(model)
            selecting = false
        }
    }

    private func loadMeasurements() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var latest: [EngineKind: EngineResult] = [:]
        // One report only. Mixing each engine's latest run compares different recordings.
        // Synthetic-clip runs exercise the harness; only the user's own clips count as "your recordings".
        for url in BakeoffFiles.reports()
        where url.lastPathComponent.hasPrefix("accuracy-") && !url.lastPathComponent.hasPrefix("accuracy-synthetic") {
            guard let data = try? Data(contentsOf: url),
                  let report = try? decoder.decode(AccuracyReport.self, from: data) else { continue }
            for result in report.engines where latest[result.engine] == nil {
                latest[result.engine] = result
            }
            break
        }
        measured = latest
    }
}

/// From speaking to text in an app, top to bottom: one dot per stage on a line, the speech
/// model's dot filled and lit. The stages are `SpeechPipelineStep.all`.
struct SpeechPipelineCard: View {
    @Environment(\.colorScheme) private var scheme
    private let steps = SpeechPipelineStep.all
    private let dot: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                row(step, isLast: index == steps.count - 1)
            }
        }
        .padding(.vertical, 8)
    }

    private func row(_ step: SpeechPipelineStep, isLast: Bool) -> some View {
        return HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(step.isModel ? Zone.controlFill(scheme) : Zone.rule(scheme))
                Image(systemName: step.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(step.isModel ? Zone.controlInk(scheme) : Zone.ink(scheme))
            }
            .frame(width: dot, height: dot)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(step.isModel ? .subheadline.weight(.bold) : .subheadline.weight(.semibold))
                Text(step.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 5)
            .padding(.bottom, isLast ? 0 : 16)
        }
        // The line to the next stage runs from under this dot to the bottom of the row, which
        // is the top of the next dot.
        .background(alignment: .topLeading) {
            if !isLast {
                Rectangle().fill(Zone.rule(scheme))
                    .frame(width: 2)
                    .padding(.top, dot + 2)
                    .padding(.leading, dot / 2 - 1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("speechModel.step.\(step.id)")
    }
}

struct SizeFact {
    let symbol: String
    let text: String
    let spoken: String
}

/// One size figure as a quiet capsule, so the row reads as numbers rather than a sentence.
private struct SizePill: View {
    @Environment(\.colorScheme) private var scheme
    let fact: SizeFact

    var body: some View {
        Label(fact.text, systemImage: fact.symbol)
            .font(.caption.monospacedDigit())
            .labelStyle(.titleAndIcon)
            .imageScale(.small)
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Zone.controlFill(scheme), in: Capsule())
            .foregroundStyle(Zone.controlInk(scheme))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(fact.spoken)
    }
}
