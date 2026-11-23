// by zayd/cold @ zayd.wtf

import SwiftUI
import UniformTypeIdentifiers
import ZoneCore

extension UTType {
    static let zoneBackup = UTType(exportedAs: "wtf.zayd.zone.backup", conformingTo: .package)
}

struct LibraryBackupView: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(MeetingCoordinator.self) private var meetings
    @Environment(\.colorScheme) private var scheme
    @State private var manager = LibraryBackupManager.shared
    @State private var exportURL: URL?
    @State private var showsExport = false
    @State private var showsImport = false
    @State private var showsFolder = false
    @State private var importURL: URL?
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Button {
                    Task {
                        do {
                            let url = try await manager.export(notes: coordinator.notes, meetings: meetings)
                            exportURL = url
                            showsExport = true
                        } catch { message = error.localizedDescription }
                    }
                } label: { Label("Export all notes and recordings", systemImage: "square.and.arrow.up") }
                .disabled(manager.isWorking || meetings.isRecording)
                Button { showsImport = true } label: { Label("Import a Zone backup", systemImage: "square.and.arrow.down") }
                    .disabled(manager.isWorking || meetings.isRecording)
            } header: { Text("Export and import") } footer: {
                Text("Save a `.zonebackup` bundle to On My iPhone or iCloud Drive. Includes notes, history, meeting transcripts, speaker names, meeting audio, and a plain-text copy. Store backups outside Zone's own folder if you plan to delete the app.")
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                Button { showsFolder = true } label: {
                    LabeledContent(manager.hasFolder ? "Backup folder" : "Choose backup folder", value: manager.folderName ?? "Off")
                }
                .disabled(manager.isWorking)
                if manager.hasFolder {
                    Button("Back up now") { Task { await manager.saveNow(notes: coordinator.notes, meetings: meetings) } }
                        .disabled(manager.isWorking || meetings.isRecording)
                    if let date = manager.lastSavedAt {
                        LabeledContent("Last saved", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button("Stop automatic backups", role: .destructive) { manager.stopAutomaticBackups() }
                        .disabled(manager.isWorking)
                }
                if manager.isWorking { ProgressView("Saving backup…") }
                if let error = manager.lastError { Text(error).foregroundStyle(.red).font(.footnote) }
            } header: { Text("Automatic folder backup") } footer: {
                Text("Updates the chosen folder while Zone is open (within ~5 minutes of changes, or right after a meeting stops). Keeps older backed-up items even if you delete them in Zone. Last saved marks the local file write; iOS handles iCloud sync.")
            }
            .listRowBackground(Zone.card(scheme))
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Backup and export")
        .zoneBackButton()
        .navigationBarTitleDisplayMode(.inline)
        .zoneScreen()
        .sheet(isPresented: $showsExport, onDismiss: {
            if let url = exportURL { try? FileManager.default.removeItem(at: url) }
            exportURL = nil
        }) {
            if let url = exportURL {
                BackupExportPicker(url: url) { saved in
                    showsExport = false
                    if saved { message = "Backup saved to Files. Keep the full .zonebackup file to restore later." }
                }
            }
        }
        .fileImporter(isPresented: $showsImport, allowedContentTypes: [.zoneBackup, .folder]) { result in
            switch result {
            case .success(let url): importURL = url
            case .failure(let error): if (error as NSError).code != NSUserCancelledError { message = error.localizedDescription }
            }
        }
        .sheet(isPresented: $showsFolder) {
            BackupFolderPicker { url in
                showsFolder = false
                guard let url else { return }
                Task {
                    do {
                        try await manager.selectFolder(url)
                        await manager.saveNow(notes: coordinator.notes, meetings: meetings)
                    } catch { message = error.localizedDescription }
                }
            }
        }
        .confirmationDialog("Import this backup?", isPresented: Binding(get: { importURL != nil }, set: { if !$0 { importURL = nil } })) {
            Button("Import and keep history") {
                guard let url = importURL else { return }
                importURL = nil
                Task {
                    do { message = try await manager.restore(url, notes: coordinator.notes, meetings: meetings) }
                    catch { message = manager.lastError ?? error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) { importURL = nil }
        } message: {
            Text("Merges missing items without duplicating existing notes or meetings. Switches History retention to Until I delete so imported dictations don't expire.")
        }
        .alert("Backup and export", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
    }
}

/// Hand the package URL to Files. FileDocument/FileWrapper materializes all audio in the
/// app process during a write, which can exhaust memory for multi-hour meetings.
private struct BackupExportPicker: UIViewControllerRepresentable {
    let url: URL
    let completion: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (Bool) -> Void
        init(_ completion: @escaping (Bool) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { completion(true) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion(false) }
    }
}

private struct BackupFolderPicker: UIViewControllerRepresentable {
    let onSelect: (URL?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onSelect) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let selected: (URL?) -> Void
        init(_ selected: @escaping (URL?) -> Void) { self.selected = selected }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { selected(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { selected(nil) }
    }
}

struct LibraryBackupAutosave: ViewModifier {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(MeetingCoordinator.self) private var meetings
    func body(content: Content) -> some View {
        content
            .task {
                // The launch save waits for launch to settle, never ahead of the first frame.
                // After it, a check every 30 seconds writes only if something changed or the
                // last save failed, at most once per 5 minutes (LibraryBackupSchedule).
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                while !Task.isCancelled {
                    await LibraryBackupManager.shared.saveAutomatically(notes: coordinator.notes, meetings: meetings)
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("ZoneLibraryDidChange"))
                .receive(on: DispatchQueue.main)) { _ in
                LibraryBackupManager.shared.libraryChanged(notes: coordinator.notes, meetings: meetings)
            }
            .onChange(of: meetings.isRecording) { _, recording in
                // A finished meeting's audio is worth a prompt save; it skips the 5 minute spacing.
                if !recording { LibraryBackupManager.shared.libraryChanged(notes: coordinator.notes, meetings: meetings, prompt: true) }
            }
    }
}
