// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

struct CleanupView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(LinkCoordinator.self) private var link: LinkCoordinator?
    @State private var text: String
    @State private var original = ""
    @State private var proposal: String?
    @State private var acceptedOriginal: String?
    @State private var task: Task<Void, Never>?
    @State private var requestID = UUID()
    @State private var error: String?
    @State private var unavailable = CleanupEngine.unavailableReason
    @State private var copied = false
    @State private var unchanged = false
    @State private var downloadTask: Task<Void, Never>?
    @State private var downloadProgress = 0.0
    @AppStorage(CleanupEngine.automaticKey) private var automatic = false
    @State private var recent: [CleanupArchive.Entry] = []
    @State private var recentLimit = 10
    @FocusState private var editing: Bool
    var isActive = true

    init(text: String = "", isActive: Bool = true) {
        _text = State(initialValue: text)
        self.isActive = isActive
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let proposal {
                    DisplayText("Compare", size: 32)
                    Text("Cleaned text on top, your original below.")
                        .foregroundStyle(Zone.muted(scheme))
                    textCard("Cleaned", proposal)
                    textCard("Original", original)
                    Button("Use cleaned text") {
                        acceptedOriginal = acceptedOriginal ?? original
                        text = proposal
                        self.proposal = nil
                    }.buttonStyle(ZonePrimaryButtonStyle())
                    Button("Keep original") {
                        text = original
                        self.proposal = nil
                    }.buttonStyle(ZoneQuietButtonStyle(fullWidth: true))
                } else {
                    DisplayText("Cleanup", size: 32)
                    Text("Strip filler words and tighten punctuation locally. Your original is always saved.")
                        .foregroundStyle(Zone.muted(scheme))
                    if unavailable != nil { availabilityCard }
                    if text.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Example").font(.headline)
                            Text("um can you send the draft today please")
                                .foregroundStyle(Zone.muted(scheme))
                            Image(systemName: "arrow.down").foregroundStyle(Zone.accentText(scheme))
                            Text("Can you send the draft today, please?")
                            Button("Load example") { replaceDraft("um can you send the draft today please") }
                                .buttonStyle(ZoneLinkButtonStyle())
                        }.zoneCard()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Draft").font(.headline)
                            Spacer()
                            // PasteButton pastes without the Allow Paste prompt, but its UIPasteControl
                            // asks the pasteboard server, synchronously on the main thread, after every
                            // pasteboard change (Zone's own Copy included); that hung the app for up to
                            // 2 s. Home keeps this page mounted while hidden, so the control exists
                            // only while the page is showing.
                            if isActive {
                                PasteButton(payloadType: String.self) { values in
                                    replaceDraft(values.joined(separator: "\n"))
                                }
                                .labelStyle(.titleOnly)
                                .buttonBorderShape(.roundedRectangle(radius: Zone.keyRadius))
                                .controlSize(.small)
                                .disabled(task != nil)
                            }
                        }
                        TextEditor(text: $text)
                            .frame(height: 180)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(Zone.field(scheme), in: Zone.fieldShape)
                            .overlay(Zone.fieldShape.strokeBorder(Zone.rule(scheme), lineWidth: 1))
                            .focused($editing)
                            .accessibilityLabel("Text to clean up")
                            .disabled(task != nil)
                        Text("\(text.count) / 4,000").font(.caption).foregroundStyle(Zone.muted(scheme))
                    }.zoneCard()
                    if task != nil {
                        HStack(spacing: 12) {
                            ProgressView().tint(Zone.accentGraphic)
                            Text("Cleaning up…").foregroundStyle(Zone.muted(scheme))
                            Spacer()
                            Button("Cancel", action: cancel).buttonStyle(ZonePillButtonStyle())
                        }
                        .frame(minHeight: 52)
                    } else {
                        Button("Clean up", action: run).buttonStyle(ZonePrimaryButtonStyle())
                            .disabled(unavailable != nil || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 4000)
                    }
                    if unchanged { Text("No changes needed.").foregroundStyle(Zone.muted(scheme)) }
                    if let error { Text(error).foregroundStyle(Zone.live).accessibilityLabel("Cleanup error: \(error)") }
                    if let acceptedOriginal {
                        Button("Restore original") { text = acceptedOriginal; self.acceptedOriginal = nil; copied = false }
                            .buttonStyle(ZoneLinkButtonStyle())
                    }
                    if !text.isEmpty && task == nil {
                        Button(copied ? "Copied" : "Copy text") { Clipboard.copy(text); copied = true }
                            .buttonStyle(ZoneQuietButtonStyle(fullWidth: true))
                    }
                    if unavailable == nil { availabilityCard }
                    Toggle("Automatically clean dictation", isOn: $automatic)
                        .tint(Zone.accentGraphic(scheme))
                        .disabled(unavailable != nil)
                    Text("Cleans dictations automatically and keeps your originals below.")
                        .font(.footnote).foregroundStyle(Zone.muted(scheme))
                    if !recent.isEmpty {
                        Text("Recent cleanups").font(.headline)
                        ForEach(recent.prefix(recentLimit)) { entry in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(entry.original).lineLimit(3)
                                HStack(spacing: 8) {
                                    Button("Use original") { replaceDraft(entry.original) }
                                    if let cleaned = entry.cleaned {
                                        Button("Use cleaned") { replaceDraft(cleaned); acceptedOriginal = entry.original }
                                    }
                                    Spacer()
                                    Button("Delete", role: .destructive) {
                                        do { try CleanupEngine.archive.delete(entry.id); refreshRecent() }
                                        catch { self.error = error.localizedDescription }
                                    }
                                }.buttonStyle(ZonePillButtonStyle())
                                Hairline()
                            }
                        }
                        if recent.count > recentLimit {
                            Button("Show more cleanups") { recentLimit += 20 }
                                .buttonStyle(ZoneLinkButtonStyle())
                        }
                    }
                }
            }.padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if isActive && editing {
                    Spacer()
                    Button("Done editing") { editing = false }
                }
            }
        }
        .onChange(of: text) { _, _ in copied = false; unchanged = false; error = nil }
        .onChange(of: scenePhase) { _, phase in if phase == .active { unavailable = CleanupEngine.unavailableReason } }
        .onChange(of: isActive) { _, active in
            if !active { cancel(); editing = false }
            else { unavailable = CleanupEngine.unavailableReason; refreshRecent() }
        }
        .onDisappear(perform: cancel)
        .onAppear { unavailable = CleanupEngine.unavailableReason; refreshRecent() }
        .zoneScreen()
    }

    private var availabilityCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(unavailable == nil ? "Model installed" : "Download cleanup model", systemImage: "iphone")
                .font(.headline)
            Text(unavailable ?? "Fluid-1 Pico · 372 MB · runs offline on this iPhone.")
                .foregroundStyle(Zone.muted(scheme))
            if downloadTask != nil {
                ProgressView(value: downloadProgress).tint(Zone.accentGraphic)
                Text("Downloading · \(Int(downloadProgress * 100))%")
                    .font(.caption).monospacedDigit()
                Button("Cancel download") { downloadTask?.cancel() }.buttonStyle(ZonePillButtonStyle())
            } else if CleanupModelStore.installed {
                Button("Remove model", role: .destructive) {
                    Task {
                        do { try await CleanupModelStore.shared.remove() }
                        catch { self.error = error.localizedDescription }
                        unavailable = CleanupEngine.unavailableReason
                    }
                }.buttonStyle(ZoneLinkButtonStyle()).disabled(task != nil)
            } else if #available(iOS 18, *) {
                Button("Download · 372 MB", action: download)
                    .buttonStyle(ZoneQuietButtonStyle(fullWidth: true))
            }
            Text("Fluid-1 Pico by ALTIC (Liquid AI) · Beta · English")
                .font(.caption).foregroundStyle(Zone.muted(scheme))
            Link("Model and license", destination: URL(string: "https://huggingface.co/altic-dev/Fluid-1-Pico-CoreML")!)
                .font(.caption)
        }.zoneCard()
    }

    private func download() {
        error = nil
        downloadTask = Task { @MainActor in
            do {
                try await CleanupModelStore.shared.download { value in
                    Task { @MainActor in downloadProgress = value }
                }
            } catch is CancellationError {
                // Verified completed files remain available for the next attempt.
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            unavailable = CleanupEngine.unavailableReason
            downloadTask = nil
        }
    }

    private func textCard(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.zoneCard()
    }

    private func replaceDraft(_ value: String) {
        text = value
        original = ""
        acceptedOriginal = nil
    }

    private func refreshRecent() {
        do { recent = try CleanupEngine.archive.entries() }
        catch { self.error = "Recent cleanups couldn't be read. Your current text is still here." }
    }

    private func cancel() {
        requestID = UUID()
        task?.cancel()
        task = nil
    }

    private func run() {
        editing = false
        error = nil
        unchanged = false
        original = text
        let input = text
        let id = UUID()
        requestID = id
        task = Task { @MainActor in
            do {
                let result = try await Watchdog.run(what: "Cleanup", limit: 45) {
                    try await CleanupEngine.cleanAndSave(input)
                }
                guard !Task.isCancelled, requestID == id else { return }
                if result == input { unchanged = true } else { proposal = result }
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                self.error = (error as? CleanupError)?.errorDescription ?? "Cleanup couldn't finish. Your original is unchanged. Try again."
            }
            if requestID == id { task = nil }
            refreshRecent()
        }
    }
}

struct CleanupSheet: View {
    @Environment(\.dismiss) private var dismiss
    let text: String
    var body: some View {
        NavigationStack {
            CleanupView(text: text)
                .navigationTitle("Cleanup")
                .zoneBackButton()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ZoneBarItem(.confirmationAction, prominent: true) { Button("Done") { dismiss() } } }
        }
    }
}
