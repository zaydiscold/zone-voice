// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// Recent recovery text stays on Home; the complete searchable archive remains one tap away.
struct HomeLibraryView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var records: [TranscriptRecord] = []
    @State private var retention: HistoryRetention = .default
    @State private var loaded = false
    @State private var unavailable = false
    @State private var deleting = false
    @State private var refreshToken = UUID()
    @AppStorage("zone.home.notesCollapsed") private var notesCollapsed = false
    @State private var allNotesShown = false
    @State private var editingNote: Note?
    @State private var opened: TranscriptRecord?
    /// Where HomeView scrolls for Added to Notes.
    static let notesAnchor = "home.notes"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if settings.notesFirst {
                notes
                Hairline()
                history
            } else {
                history
                Hairline()
                notes
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await refresh()
        }
        .task(id: coordinator.activity) {
            guard scenePhase == .active else { return }
            await refresh()
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("History").font(.headline)
                Spacer()
                NavigationLink { HistoryView() } label: { Text("See all").frame(minHeight: 44) }
                    .accessibilityLabel("See all dictation history")
            }
            if unavailable {
                Text("History couldn't load. Reopen Zone; nothing was deleted.")
                    .font(.subheadline).foregroundStyle(Zone.live)
            } else if records.isEmpty && loaded {
                Text(retention == .off ? "History is off" : "No dictations yet")
                    .font(.subheadline).foregroundStyle(Zone.muted(scheme))
            }
            RuledList(items: records) { record in
                LibraryRow(kind: .dictation, text: record.text,
                           detail: Self.detail(LibraryRow.when(record.createdAt), quiet: Self.quietStatus(record.status)),
                           alert: Self.alertStatus(record.status), recoveredFrom: record.recoveredFrom,
                           onOpen: { opened = record }, onDelete: { delete(record) })
            }
        }
        .sheet(item: $opened) { record in
            RecordSheet(record: record, onDelete: { delete(record); opened = nil })
        }
    }

    /// A status that means the words may not be where the person wanted them.
    static func alertStatus(_ status: TranscriptStatus) -> String? {
        status == .cutOff || status == .notDelivered || status == .offered ? status.label : nil
    }

    /// Every other status worth a word, in the quiet line.
    static func quietStatus(_ status: TranscriptStatus) -> String? {
        alertStatus(status) == nil ? status.label : nil
    }

    static func detail(_ when: String, quiet: String?) -> String {
        [when, quiet].compactMap { $0 }.joined(separator: " · ")
    }

    /// Notes stay contained: the newest few, the rest behind "Show all", and the whole section
    /// folds away with the chevron (remembered). Tap a note to edit it in place and save.
    private static let shownNotes = 3

    private var notes: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.3)) { notesCollapsed.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text("Notes").font(.headline)
                        if !coordinator.notes.notes.isEmpty {
                            Text("\(coordinator.notes.notes.count)").font(.subheadline).foregroundStyle(Zone.muted(scheme))
                        }
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Zone.muted(scheme))
                            .rotationEffect(.degrees(notesCollapsed ? -90 : 0))
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(notesCollapsed ? "Show notes" : "Hide notes")
                Spacer()
                Button { coordinator.beginNoteDictation() } label: {
                    Label("New note", systemImage: "mic.fill").frame(minHeight: 44)
                }.font(.subheadline)
                    // A loading engine is fine: the note card says it is turning on, as for the
                    // Action Button. Only a missing model has nothing to turn on.
                    .disabled(coordinator.modelState == .missing || coordinator.activity.isBusy || coordinator.noteIsLive)
                    .accessibilityIdentifier("home.dictateNote")
            }
            .id(Self.notesAnchor)
            if !notesCollapsed {
                if coordinator.notes.notes.isEmpty {
                    Text("No notes yet")
                        .font(.subheadline).foregroundStyle(Zone.muted(scheme))
                }
                if let error = coordinator.notes.lastError {
                    Text(error).font(.footnote).foregroundStyle(Zone.live)
                }
                let all = coordinator.notes.notes
                RuledList(items: allNotesShown ? all : Array(all.prefix(Self.shownNotes))) { note in
                    LibraryRow(kind: .note, text: note.text,
                               detail: Self.detail(LibraryRow.when(note.createdAt), quiet: note.editedAt == nil ? nil : "Edited"),
                               highlighted: coordinator.noteReveal?.noteID == note.id,
                               onOpen: { editingNote = note }, onDelete: { coordinator.notes.delete(note) })
                }
                if all.count > Self.shownNotes {
                    Button(allNotesShown ? "Show fewer" : "Show all \(all.count) notes") {
                        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.3)) { allNotesShown.toggle() }
                    }
                    .buttonStyle(ZoneLinkButtonStyle())
                }
            }
        }
        .sheet(item: $editingNote) { note in
            NoteEditorSheet(note: note) { text in coordinator.notes.update(note, text: text) }
        }
        // Added to Notes on the Note saved page: the section opens, far enough to show the note.
        .onChange(of: coordinator.noteReveal?.token, initial: true) { _, token in
            guard token != nil, let id = coordinator.noteReveal?.noteID else { return }
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.3)) {
                notesCollapsed = false
                if !coordinator.notes.notes.prefix(Self.shownNotes).contains(where: { $0.id == id }) { allNotesShown = true }
            }
        }
    }

    private func refresh() async {
        guard !deleting else { return }
        guard let store = TranscriptHistory.shared else { unavailable = true; return }
        unavailable = false
        let token = UUID()
        refreshToken = token
        let result = await Task.detached(priority: .utility) { (store.recent(limit: 8).filter { $0.status != .note }.prefix(3).map { $0 }, store.retention) }.value
        guard !Task.isCancelled, !deleting, token == refreshToken else { return }
        records = result.0
        retention = result.1
        loaded = true
    }

    private func delete(_ record: TranscriptRecord) {
        guard !deleting, let store = TranscriptHistory.shared else { return }
        deleting = true
        refreshToken = UUID()
        records.removeAll { $0.id == record.id }
        Task {
            await Task.detached(priority: .utility) { store.delete(id: record.id) }.value
            deleting = false
            await refresh()
        }
    }
}

/// Failed recordings are immediately visible; successful retries remain until copied or deleted.
struct HomeAudioRecoverySection: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var scheme
    @State private var expanded: Set<UUID> = []
    @State private var showsRecovery = false

    /// "Audio kept for 7 more days": a calm promise, not a deadline with a clock time.
    /// Builds before 2026-11-03 ended a recording at an interruption and filed it here as
    /// "Recording was interrupted." although its words were complete and in History.
    static func cardMessage(_ record: AudioRecoveryRecord) -> String? {
        if record.message == "Recording was interrupted.", !record.text.isEmpty {
            return "Cut off by a call or alarm. The words are saved in History."
        }
        return record.message
    }

    static func keptLabel(until expiry: Date, now: Date = Date()) -> String {
        let days = Int((expiry.timeIntervalSince(now) / 86_400).rounded(.up))
        if days > 1 { return "Audio kept for \(days) days" }
        let hours = max(Int((expiry.timeIntervalSince(now) / 3_600).rounded(.up)), 1)
        return hours == 1 ? "Audio kept for 1 hour" : "Audio kept for \(hours) hours"
    }

    private var records: [AudioRecoveryRecord] {
        coordinator.audioRecoveryRecords.filter { $0.state != .recording }
    }

    var body: some View {
        Group {
        if !records.isEmpty {
        VStack(alignment: .leading, spacing: 12) {
            if !records.isEmpty {
                Button {
                    withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.35)) { showsRecovery.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.counterclockwise.circle.fill")
                            .font(.title3).foregroundStyle(Zone.accentText(scheme))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(records.count == 1 ? "1 recording to recover" : "\(records.count) recordings to recover")
                                .font(.headline).foregroundStyle(Zone.ink(scheme))
                            Text("Tap to copy or transcribe again.")
                                .font(.caption).foregroundStyle(Zone.muted(scheme))
                        }
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Zone.muted(scheme))
                            .rotationEffect(.degrees(showsRecovery ? 180 : 0))
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .zoneCard(padding: 12)
                .accessibilityHint(showsRecovery ? "Hides recordings" : "Shows recordings")
                if showsRecovery {
                ForEach(records) { record in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(Zone.muted(scheme))
                            Spacer()
                            if !record.text.isEmpty {
                                Button {
                                    Clipboard.copy(record.text)
                                    if record.state == .textReady { coordinator.useRecoveredText(record.id) }
                                } label: {
                                    Text("Copy").frame(minWidth: 44, minHeight: 44)
                                }
                            }
                            Button(role: .destructive) { coordinator.deleteAudioRecovery(record.id) } label: {
                                Image(systemName: "trash").frame(width: 44, height: 44)
                            }.accessibilityLabel("Delete recovered dictation")
                                .disabled(coordinator.retryingAudioID == record.id)
                        }
                        if record.state == .textReady {
                            Button {
                                if !expanded.insert(record.id).inserted { expanded.remove(record.id) }
                            } label: {
                                HStack(alignment: .top) {
                                    Text(record.text).lineLimit(expanded.contains(record.id) ? nil : 3)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: expanded.contains(record.id) ? "chevron.up" : "chevron.down")
                                        .font(.caption)
                                }.frame(minHeight: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Text("Recovered").font(.caption).foregroundStyle(Zone.muted(scheme))
                        } else {
                            if let message = Self.cardMessage(record) {
                                Text(message).font(.subheadline)
                            }
                            if !record.text.isEmpty {
                                Text(record.text).font(.subheadline).lineLimit(3)
                            }
                            HStack {
                                Text(record.audioBytes < 2 ? "No audio" : "\(record.audioSeconds.countdownLabel) of audio saved").font(.caption)
                                Spacer()
                                if coordinator.retryingAudioID == record.id {
                                    ProgressView()
                                    Button("Cancel") { coordinator.cancelAudioRetry() }.frame(minHeight: 44)
                                } else {
                                    if !record.text.isEmpty {
                                        // The words are already in History; this only lets the audio go.
                                        Button("Done") { coordinator.deleteAudioRecovery(record.id) }.frame(minHeight: 44)
                                            .accessibilityHint("Keeps the words in History and deletes the saved audio")
                                    }
                                    Button(record.text.isEmpty ? "Transcribe" : "Transcribe again") { coordinator.retryAudioRecovery(record) }
                                        .frame(minHeight: 44)
                                        .disabled(record.audioBytes < 2 || coordinator.activity.isBusy || !coordinator.modelIsReady || coordinator.retryingAudioID != nil)
                                }
                            }
                            if !coordinator.modelIsReady {
                                NavigationLink("Get a model to retry") { ModelLibraryView() }
                                    .font(.subheadline).frame(minHeight: 44)
                            }
                            if let expiry = record.expiresAt {
                                Text(Self.keptLabel(until: expiry))
                                    .font(.caption).foregroundStyle(Zone.muted(scheme))
                            }
                        }
                    }.zoneCard(padding: 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                }
            }
        }
        }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await coordinator.refreshAudioRecovery()
        }
    }
}

/// The one place a failure or storage warning shows on Home, with a close button. A message
/// a recovery card already carries is not repeated above it.
struct HomeNotice: View {
    @Environment(DictationCoordinator.self) private var coordinator

    private var message: String? {
        // The plain hold status shows in the hero card; only a failed resume is a warning.
        let resumeFailure = coordinator.holdNotice == DictationCoordinator.heldMessage ? nil : coordinator.holdNotice
        var candidate = resumeFailure ?? coordinator.autoStopNotice ?? coordinator.audioRecoveryWarning
        if candidate == nil, case .failed(let failure) = coordinator.activity { candidate = failure }
        guard let candidate,
              !coordinator.audioRecoveryRecords.contains(where: { $0.state != .recording && $0.message == candidate })
        else { return nil }
        return candidate
    }

    var body: some View {
        if let message {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle").padding(.top, 2)
                Text(message).frame(maxWidth: .infinity, alignment: .leading)
                Button { coordinator.dismissNotice() } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.semibold))
                        .frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .font(.subheadline).foregroundStyle(Zone.live)
            .zoneCard(padding: 12)
            .transition(.opacity)
        }
    }
}

/// One note, editable, with Save. Emptying it and saving deletes the note.
private struct NoteEditorSheet: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    let note: Note
    let onSave: (String) -> Void
    @State private var text: String
    @FocusState private var focused: Bool

    init(note: Note, onSave: @escaping (String) -> Void) {
        self.note = note
        self.onSave = onSave
        _text = State(initialValue: note.text)
    }

    private var changed: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines) != note.text }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $text)
                    .font(.body)
                    .foregroundStyle(Zone.ink(scheme))
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .zoneCard(padding: 0)
                    .focused($focused)
                    .frame(minHeight: 180)
                Text(note.createdAt.formatted(date: .abbreviated, time: .shortened)
                     + (note.editedAt.map { " · edited " + $0.formatted(date: .omitted, time: .shortened) } ?? ""))
                    .font(.footnote).foregroundStyle(Zone.muted(scheme))
                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Note")
            .zoneBackButton()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ZoneBarItem(.cancellationAction) { Button("Cancel") { dismiss() } }
                ZoneBarItem(.confirmationAction, prominent: true) {
                    Button("Save") {
                        onSave(text)
                        Haptics.success()
                        dismiss()
                    }
                    .disabled(!changed)
                }
            }
            .zoneScreen()
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}
