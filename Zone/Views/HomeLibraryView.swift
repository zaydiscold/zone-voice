// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// The newest three dictations and the newest three notes stay on Home; all of each, with search,
/// is one tap away behind its "See all".
struct HomeLibraryView: View {
    let isActive: Bool
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
    /// The note being read, pushed over Home.
    @State private var reading: NoteRoute?
    /// Added to Notes for a note that is not among Home's three: the Notes page, at that note.
    @State private var revealing: NoteRoute?
    @State private var opened: TranscriptRecord?
    /// Where HomeView scrolls for Added to Notes.
    static let notesAnchor = "home.notes"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if settings.notesFirst {
                notes
                SectionBreak()
                history
            } else {
                history
                SectionBreak()
                notes
            }
        }
        .navigationDestination(item: $reading) { NoteReadView($0) }
        .navigationDestination(item: $revealing) { NotesView(reveal: $0.id) }
        .task(id: isActive && scenePhase == .active) {
            guard isActive && scenePhase == .active else { return }
            await refresh()
        }
        .task(id: coordinator.activity) {
            guard isActive && scenePhase == .active else { return }
            await refresh()
        }
    }

    /// A title sits nearer its first row than the rows sit to each other, so it reads as the
    /// start of what follows rather than the end of what came before.
    static let titleToRows: CGFloat = 4

    private var history: some View {
        VStack(alignment: .leading, spacing: Self.titleToRows) {
            HStack {
                Text("History").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                NavigationLink { HistoryView() } label: { Text("See all").zoneAccentLink(scheme).frame(minHeight: 44) }
                    .accessibilityLabel("See all dictation history")
            }
            if unavailable {
                Text("History couldn't load. Reopen Zone; nothing was deleted.")
                    .font(.subheadline).foregroundStyle(Zone.live)
            } else if records.isEmpty && loaded {
                Text(retention == .off ? "History is off" : "No dictations yet")
                    .font(.subheadline).foregroundStyle(Zone.muted(scheme))
            }
            ForEach(records) { record in
                LibraryRow(kind: .dictation, text: record.text,
                           detail: Self.detail(LibraryRow.when(record.createdAt), quiet: Self.quietStatus(record.status)),
                           alert: Self.alertStatus(record.status), recoveredFrom: record.recoveredFrom, copiedDictationID: record.id,
                           onOpen: { opened = record }, onDelete: { delete(record) })
            }
        }
        .alert("Could not delete dictation", isPresented: $deleteFailed) { Button("OK") {} }
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

    /// Notes on Home have History's shape: the newest three, and "See all" for the Notes page
    /// (every note, with search). Tapping one opens it to read; nothing here opens a keyboard,
    /// and nothing here makes Home longer than three rows.
    static let shownNotes = 3

    private var notes: some View {
        VStack(alignment: .leading, spacing: Self.titleToRows) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    notesTitle
                    newNote
                    Spacer(minLength: 8)
                    seeAllNotes
                }
                // Large text: the title and See all, then the key under them.
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        notesTitle
                        Spacer(minLength: 8)
                        seeAllNotes
                    }
                    newNote
                }
                // The largest text on the narrowest iPhone: one under another, nothing broken mid-word.
                VStack(alignment: .leading, spacing: 0) {
                    notesTitle
                    newNote
                    seeAllNotes
                }
            }
            .id(Self.notesAnchor)
            if coordinator.notes.notes.isEmpty {
                Text("No notes yet")
                    .font(.subheadline).foregroundStyle(Zone.muted(scheme))
            }
            if let error = coordinator.notes.lastError {
                Text(error).font(.footnote).foregroundStyle(Zone.live)
            }
            if !coordinator.notes.notes.isEmpty {
                RuledList(items: Array(coordinator.notes.notes.prefix(Self.shownNotes))) { note in
                    NoteRow(note: note, lines: 4) { reading = $0.within(coordinator.notes.notes.map { NoteStep(id: $0.id) }) }
                        .padding(.vertical, 4)
                }.libraryWell(scheme)
            }
        }
        // Added to Notes on the Note saved page: a note among these three is lit here (HomeView
        // scrolls to it); an older one, from a page of several, is shown on the Notes page.
        .onChange(of: isActive ? coordinator.noteReveal?.token : nil, initial: true) { _, token in
            guard token != nil, let id = coordinator.noteReveal?.noteID else { return }
            if !coordinator.notes.notes.prefix(Self.shownNotes).contains(where: { $0.id == id }) { revealing = NoteRoute(id: id) }
        }
    }

    private var notesTitle: some View {
        HStack(spacing: 6) {
            Text("Notes").font(.headline).lineLimit(1).fixedSize()
            if !coordinator.notes.notes.isEmpty {
                Text("\(coordinator.notes.notes.count)").font(.subheadline.monospacedDigit()).foregroundStyle(Zone.muted(scheme))
                    .lineLimit(1).fixedSize()
                    .accessibilityLabel("\(coordinator.notes.notes.count) notes")
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// A key, not a link: it starts a recording, where See all only goes somewhere.
    private var newNote: some View {
        NewNoteButton {
            Label("New note", systemImage: "mic.fill").lineLimit(1).fixedSize()
                .frame(minHeight: 44).contentShape(Rectangle())
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Zone.accentTone(scheme))
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.dictateNote")
    }

    private var seeAllNotes: some View {
        NavigationLink { NotesView() } label: { Text("See all").zoneAccentLink(scheme).lineLimit(1).fixedSize().frame(minHeight: 44) }
            .accessibilityLabel("See all notes")
            .accessibilityIdentifier("home.seeAllNotes")
    }

    private func refresh() async {
        guard !deleting else { return }
        guard let store = TranscriptHistory.shared else { unavailable = true; return }
        unavailable = false
        let token = UUID()
        refreshToken = token
        let result = await Task.detached(priority: .utility) { (store.recentDictations(limit: 3), store.retention) }.value
        guard !Task.isCancelled, !deleting, token == refreshToken else { return }
        records = result.0
        retention = result.1
        loaded = true
    }

    @State private var deleteFailed = false

    private func delete(_ record: TranscriptRecord) {
        guard !deleting, let store = TranscriptHistory.shared else { return }
        deleting = true
        refreshToken = UUID()
        records.removeAll { $0.id == record.id }
        Task {
            let saved = await Task.detached(priority: .utility) { store.delete(id: record.id) }.value
            deleteFailed = !saved
            deleting = false
            await refresh()
        }
    }
}

/// Failed recordings are immediately visible; successful retries remain until copied or deleted.
struct HomeAudioRecoverySection: View {
    let isActive: Bool
    var fullList = false
    private static let homeLimit = 3
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showsRecovery = false
    @State private var inspecting: AudioRecoveryRecord?
    @State private var shareURL: URL?
    @State private var sharing = false
    @State private var preparingShare = false
    @State private var shareFailed = false
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var deleting: [AudioRecoveryRecord] = []

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
        coordinator.audioRecoveryRecords.filter { $0.state != .recording }.sorted { a, b in
            let first = a.levels?.soundsLikeSpeech == true && a.attempts?.count == 0
            let second = b.levels?.soundsLikeSpeech == true && b.attempts?.count == 0
            return first == second ? a.createdAt > b.createdAt : first
        }
    }

    var body: some View {
        let displayed = records
        return Group {
            if !displayed.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    if !fullList { disclosure(count: displayed.count) }
                    if fullList || showsRecovery {
                        HStack {
                            Button(selecting ? "Cancel selection" : "Select recordings") {
                                selected.removeAll()
                                selecting.toggle()
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            Spacer()
                            if selecting {
                                Button("Delete selected", role: .destructive) {
                                    deleting = records.filter { selected.contains($0.id) && coordinator.retryingAudioID != $0.id }
                                }.buttonStyle(.bordered).controlSize(.small).disabled(selected.isEmpty)
                            }
                        }
                        .padding(.vertical, 5)
                        if fullList {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(displayed) { record in
                                    recoveryRow(record)
                                    if record.id != displayed.last?.id { RowRule().padding(.leading, selecting ? 54 : 0) }
                                }
                            }
                        } else {
                            RuledList(items: Array(displayed.prefix(Self.homeLimit)), textInset: selecting ? 54 : 0) { record in recoveryRow(record) }
                            if displayed.count > Self.homeLimit {
                                RowRule()
                                NavigationLink {
                                    ScrollView { HomeAudioRecoverySection(isActive: true, fullList: true).padding() }
                                        .navigationTitle("Saved recordings").zoneBackButton().zoneScreen()
                                } label: {
                                    HStack {
                                        Text("See all \(displayed.count) recordings")
                                        Spacer()
                                        Image(systemName: "chevron.right").imageScale(.small)
                                    }.font(.subheadline.weight(.semibold)).frame(minHeight: 44).contentShape(Rectangle())
                                }
                                .accessibilityIdentifier("recovery.seeAll")
                            }
                        }
                    }
                }.libraryWell(scheme)
            } else if fullList {
                ContentUnavailableView("No saved recordings", systemImage: "waveform")
            }
        }
        .background {
            ShareSheet(isPresented: $sharing, items: shareURL.map { [$0] } ?? []) { _, _ in
                if let shareURL { try? FileManager.default.removeItem(at: shareURL) }
                shareURL = nil
            }
        }
        .alert("Could not share this recording", isPresented: $shareFailed) { Button("OK") {} }
        .sheet(item: $inspecting) { original in
            let record = coordinator.audioRecoveryRecords.first { $0.id == original.id } ?? original
            NavigationStack {
                Form {
                    if !record.text.isEmpty { Text(coordinator.textForRecoveryCopy(record.text)).textSelection(.enabled) }
                    Text(Self.summary(record))
                    if let message = Self.cardMessage(record) { Text(message) }
                    if let expiry = record.expiresAt { Text(Self.keptLabel(until: expiry)) }
                    if record.audioBytes >= 2 && !coordinator.modelIsReady {
                        NavigationLink("Get a model to retry") { ModelLibraryView() }
                    }
                    if let levels = record.levels {
                        LabeledContent("Peak level", value: Self.decibels(levels.peakDB))
                        LabeledContent("Average level", value: Self.decibels(levels.averageDB))
                        Text("Zone estimates speech from loudness. Music and background noise can look like speech too.")
                    }
                    if let date = record.attempts?.lastTry {
                        LabeledContent("Last try", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .task(id: record.id) { await coordinator.measureSavedAudio(record) }
                .navigationTitle("Recording details")
                .navigationBarTitleDisplayMode(typeSize.isAccessibilitySize ? .inline : .automatic)
                .toolbar { ZoneBarItem(.confirmationAction) { Button("Done") { inspecting = nil } } }
            }.presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        }
        .alert(deleting.count == 1 ? "Delete this recording?" : "Delete \(deleting.count) recordings?",
                            isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } }),
                            presenting: deleting) { targets in
            Button(targets.count == 1 ? "Delete recording" : "Delete recordings", role: .destructive) {
                for record in targets { coordinator.deleteAudioRecovery(record.id) }
                selecting = false
                selected.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: { targets in
            Text(Self.deletionMessage(targets))
        }
        .task(id: isActive && scenePhase == .active) {
            guard isActive && scenePhase == .active else { return }
            await coordinator.refreshAudioRecovery()
        }
    }

    private func disclosure(count: Int) -> some View {
        Button {
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.35)) { showsRecovery.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.title3).foregroundStyle(Zone.accentTone(scheme))
                Text(count == 1 ? "1 recording to recover" : "\(count) recordings to recover")
                    .font(.headline).foregroundStyle(Zone.ink(scheme))
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Zone.muted(scheme))
                    .rotationEffect(.degrees(showsRecovery ? 180 : 0))
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(showsRecovery ? "Expanded" : "Collapsed")
        .accessibilityHint(showsRecovery ? "Hides recordings" : "Shows recordings")
    }

    private func recoveryRow(_ record: AudioRecoveryRecord) -> some View {
        HStack(spacing: 10) {
            if selecting {
                Button {
                    if !selected.insert(record.id).inserted { selected.remove(record.id) }
                } label: {
                    Image(systemName: selected.contains(record.id) ? "checkmark.circle.fill" : "circle")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(selected.contains(record.id) ? "Deselect recording" : "Select recording")
                .accessibilityIdentifier("recovery.select." + record.id.uuidString)
                .disabled(coordinator.retryingAudioID == record.id)
            }
            Button { inspecting = record } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(record.text.isEmpty ? "Saved recording" : coordinator.textForRecoveryCopy(record.text))
                        .font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(Self.summary(record)).font(.caption).foregroundStyle(Zone.muted(scheme))
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityHint("Shows recording details")
                .accessibilityIdentifier("recovery.row." + record.id.uuidString)
                .task(id: record.id) { await coordinator.measureSavedAudio(record) }
            if !selecting {
                Menu {
                    if !record.text.isEmpty { Button("Copy words") { copy(record) } }
                    if coordinator.retryingAudioID == record.id {
                        Button("Cancel transcription") { coordinator.cancelAudioRetry() }
                    } else if record.audioBytes >= 2 {
                        Button(retryTitle(record)) { coordinator.retryAudioRecovery(record) }
                            .disabled(coordinator.activity.isBusy || !coordinator.modelIsReady || coordinator.retryingAudioID != nil)
                    }
                    Button("Recording details") { inspecting = record }
                    if record.audioBytes > 0 { Button("Share audio") { share(record) } }
                    if coordinator.retryingAudioID != record.id {
                        Button("Delete recording", role: .destructive) { deleting = [record] }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
                }.accessibilityLabel("Recording actions")
            }
        }
        .padding(.vertical, 8)
        .modifier(RowMenu(text: record.text.isEmpty ? Self.summary(record) : coordinator.textForRecoveryCopy(record.text),
                          copy: { copy(record) },
                          copyTitle: record.text.isEmpty ? "Copy summary" : "Copy",
                          share: record.audioBytes > 0 ? { share(record) } : nil,
                          actions: actions(record), delete: coordinator.retryingAudioID == record.id ? nil : { deleting = [record] }))
    }

    private func copy(_ record: AudioRecoveryRecord) {
        if record.text.isEmpty {
            Clipboard.copy(Self.summary(record))
        } else {
            let text = coordinator.textForRecoveryCopy(record.text)
            Clipboard.copy(text)
            coordinator.confirmKept(record.id, text: text)
        }
    }

    private func share(_ record: AudioRecoveryRecord) {
        guard !preparingShare, !sharing else { return }
        preparingShare = true
        Task {
            defer { preparingShare = false }
            do {
                shareURL = try await coordinator.shareableAudio(record.id)
                sharing = true
            } catch { shareFailed = true }
        }
    }

    private func retryTitle(_ record: AudioRecoveryRecord) -> String {
        (record.attempts?.count ?? 0) > 0 || !record.text.isEmpty ? "Transcribe again" : "Transcribe"
    }

    private func actions(_ record: AudioRecoveryRecord) -> [LibraryRow.Action] {
        var items: [LibraryRow.Action] = [.init(title: "Details", symbol: "info.circle") { inspecting = record }]
        if coordinator.retryingAudioID == record.id {
            items.append(.init(title: "Cancel transcription", symbol: "stop") { coordinator.cancelAudioRetry() })
        } else if record.audioBytes >= 2 {
            items.append(.init(title: retryTitle(record), symbol: "waveform",
                               action: { coordinator.retryAudioRecovery(record) },
                               enabled: !coordinator.activity.isBusy && coordinator.modelIsReady && coordinator.retryingAudioID == nil))
        }
        return items
    }

    static func decibels(_ level: Double) -> String {
        level <= -120 ? "below -119 dBFS" : "\(level.formatted(.number.precision(.fractionLength(1)))) dBFS"
    }

    static func summary(_ record: AudioRecoveryRecord) -> String {
        var parts = [LibraryRow.when(record.createdAt)]
        if record.audioSeconds > 0 {
            parts.append(Duration.seconds(record.audioSeconds).formatted(.units(allowed: [.minutes, .seconds], width: .narrow,
                fractionalPart: .show(length: record.audioSeconds < 1 ? 1 : 0))))
        }
        if let tries = record.attempts {
            if tries.count > 0 {
                let noun = tries.count == 1 ? "try" : "tries"
                parts.append("\(tries.count) \(tries.earlierUnknown ? "recorded " : "")\(noun)")
            } else {
                parts.append(tries.earlierUnknown ? "Past tries unknown" : "Not tried yet")
            }
        } else {
            parts.append("Past tries unknown")
        }
        if let levels = record.levels { parts.append("Peak " + decibels(levels.peakDB)) }
        return parts.joined(separator: " · ")
    }

    static func deletionMessage(_ targets: [AudioRecoveryRecord]) -> String {
        targets.count == 1
            ? "This permanently deletes the recovery copy and its saved audio from this iPhone."
            : "This permanently deletes the selected recovery copies and their saved audio from this iPhone."

    }

}

/// The one place a failure or storage warning shows on Home, with a close button. A message
/// a recovery card already carries is not repeated above it.
struct HomeNotice: View {
    @Environment(DictationCoordinator.self) private var coordinator

    private var message: String? {
        if let stopped = coordinator.recordingCardStopMessage { return stopped }
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

extension View {
    fileprivate func libraryWell(_ scheme: ColorScheme) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return padding(.horizontal, 12).padding(.vertical, 3)
            .background(shape.fill(Zone.recess(scheme).shadow(.inner(color: .black.opacity(0.16), radius: 1, y: 1))))
            .overlay { shape.strokeBorder(Zone.rule(scheme), lineWidth: 1).allowsHitTesting(false) }
    }
}
