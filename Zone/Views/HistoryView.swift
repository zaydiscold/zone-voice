// by zayd/cold @ zayd.wtf

import Combine
import SwiftUI
import ZoneCore

/// Every dictation's text, newest first, kept on this device so a long dictation that was cut
/// off or landed in the wrong place can be found and used again.
/// Search, copy, share and delete, how long to keep them, and Delete All. Text only, never audio.
struct HistoryView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(LinkCoordinator.self) private var link: LinkCoordinator?
    @Environment(AppSettings.self) private var settings: AppSettings?
    @Environment(DictationCoordinator.self) private var coordinator: DictationCoordinator?
    @Environment(MeetingCoordinator.self) private var meetings: MeetingCoordinator?
    /// Fixed records for the design screenshots; nil reads the real store.
    var preview: [TranscriptRecord]? = nil
    var previewRetention: HistoryRetention = .default

    @State private var records: [TranscriptRecord] = []
    @State private var retention: HistoryRetention = .default
    @State private var query = ""
    @State private var loaded = false
    @State private var confirmingDeleteAll = false
    @State private var clipChangeFailed = false
    @State private var historyDeleteFailed = false
    @State private var failedDeleteRecord: TranscriptRecord?
    @State private var opened: TranscriptRecord?
    @State private var pendingRetention: HistoryRetention?
    @State private var confirmingRetention = false
    @State private var storeUnavailable = false
    @State private var totalRecords = 0
    /// Every kept dictation's words and UTF-8 bytes, whatever the search shows.
    @State private var library = (words: 0, bytes: 0)
    @State private var mutationInProgress = false
    @State private var loadToken = UUID()
    /// Select mode: pick several dictations and copy them as one text, each under its date and
    /// time (for pasting a day's dictations into a chat or a document in one go).
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var copiedCount = 0
    /// Clipboard history: the newest few copies (or, while searching, the ones that match).
    @State private var clipMarks: [UUID: [Range<Int>]] = [:]
    @State private var clips: [ClipboardEntry] = []
    @State private var clipTotal = 0
    @State private var swipeDelete: ClipboardEntry?
    @State private var openedClip: ClipboardEntry?
    private static let shownClips = 3
    private static let matchedClips = 12
    /// The search's answer: where the found words are in each dictation, and what it read in
    /// place of a word the library does not have. The index is kept between the once-a-second
    /// reloads and rebuilt only when the dictations changed.
    @State private var marks: [UUID: [Range<Int>]] = [:]
    @State private var searchNote: String?
    @State private var searchIndex: HistorySearchIndex?
    /// The search looks at dictations (and kept copies, when that is on), or at every list: the
    /// same words in notes and meetings.
    @State private var scope: LibraryScope = .here
    @State private var finder = LibraryFinder()
    @State private var libraryRevision = 0
    @State private var target: LibraryTarget?
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var elsewhere: [LibraryFinder.Group] { searching && finder.answered == query ? finder.groups : [] }
    /// The copies to draw: none the moment the switch is off, even before the next read empties
    /// `clips`, so turning clipboard history off never leaves copies on screen or in a search.
    private var visibleClips: [ClipboardEntry] { settings?.clipboardHistoryEnabled == true ? clips : [] }

    private var history: TranscriptHistory? { TranscriptHistory.shared }

    /// Names of the paired computers: with any, the text here is not only on this device.
    private var pairedNames: [String] { preview == nil ? (link?.computers.map(\.name) ?? []) : [] }
    /// The paired computers that keep their copy of what is deleted here.
    private var keepingNames: [String] { preview == nil ? (link?.computers.keepingNames ?? []) : [] }

    private var selectedRecords: [TranscriptRecord] { records.filter { selected.contains($0.id) } }

    private var selectionText: String {
        TranscriptExport.text(for: selectedRecords.map { TranscriptExport.Item(date: $0.createdAt, text: $0.text) })
    }

    var body: some View {
        List(selection: $selected) {
            if storeUnavailable {
                Section {
                    Label("History unavailable", systemImage: "exclamationmark.triangle")
                    Text("Shared storage couldn't open. Reopen Zone and try again; existing dictations are untouched.")
                }
                .listRowBackground(Zone.paper(scheme))
            } else if records.isEmpty && visibleClips.isEmpty && loaded {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: retention == .off ? "clock.badge.xmark" : "clock.arrow.circlepath")
                            .font(.system(size: 26)).foregroundStyle(Zone.accentTone(scheme))
                        Text(emptyTitle).font(.headline).foregroundStyle(Zone.ink(scheme))
                        Text(emptyDetail).font(.subheadline).foregroundStyle(Zone.muted(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 8)
                }
                .listRowBackground(Zone.paper(scheme))
            }

            if preview == nil, !selecting, let settings { clipboardSection(settings) }

            if let searchNote, !records.isEmpty {
                Text(searchNote)
                    .font(.subheadline).foregroundStyle(Zone.muted(scheme))
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 0, trailing: 20))
                    .listRowBackground(Zone.paper(scheme))
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("history.searchSummary")
            }

            // The dictations sit on the paper, a hairline apart, under their day: a list, not a
            // stack of cards. Settings below them keep the system's grouped rows.
            ForEach(days, id: \.title) { day in
                Section {
                    ForEach(day.records) { record in
                        // A search shows the words around what it found, lit.
                        let found = marks[record.id].map { LibrarySearch.excerpt(record.text, marks: $0) }
                        LibraryRow(kind: .dictation, text: found?.text ?? record.text, whole: record.text,
                                   marks: found?.marks ?? [],
                                   detail: HomeLibraryView.detail(record.createdAt.formatted(date: .omitted, time: .shortened),
                                                                  quiet: HomeLibraryView.quietStatus(record.status)),
                                   alert: HomeLibraryView.alertStatus(record.status), recoveredFrom: record.recoveredFrom,
                                   showsCopy: !selecting, copiedDictationID: record.id,
                                   onOpen: { if selecting { toggle(record) } else { opened = record } },
                                   onDelete: { delete(record) })
                            .tag(record.id)
                            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 12))
                            .listRowBackground(Zone.paper(scheme))
                            .listRowSeparatorTint(Zone.rule(scheme))
                    }
                } header: {
                    Text(day.title).font(.subheadline.weight(.semibold)).foregroundStyle(Zone.ink(scheme))
                        .textCase(nil)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                        .background(Zone.paper(scheme))
                        .listRowInsets(EdgeInsets())
                }
                .listSectionSeparator(.hidden)
            }

            // The same words in notes and meetings: counted under the dictations, listed under Everything.
            if scope == .everything {
                LibraryFoundSections(groups: elsewhere) { target = $0 }
            } else {
                LibraryElsewhereRow(groups: elsewhere) { scope = .everything }
            }

            Section {
                Picker("Keep dictations for", selection: Binding(get: { retention }, set: { requestRetention($0) })) {
                    ForEach(HistoryRetention.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if !records.isEmpty {
                    Button("Delete all dictations", role: .destructive) { confirmingDeleteAll = true }
                }
            } header: {
                Spacer(minLength: 0).frame(height: 20).listRowInsets(EdgeInsets())
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(LinkCopy.historyFooter(pairedNames))
                    Text("Automatic expiry and Off remove transcripts, not stats. Reset words and stats in Settings to clear the counts.")
                        .accessibilityIdentifier("history.footer")
                    if library.words > 0 {
                        // How little all of it takes, against the library it would take to fill.
                        Text(WordScale.libraryLine(words: library.words, bytes: library.bytes))
                    }
                }
                .font(.footnote).foregroundStyle(Zone.muted(scheme))
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .listRowInsets(EdgeInsets())
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            .listRowBackground(Zone.paper(scheme))
            .listRowSeparatorTint(Zone.rule(scheme))
        }
        .listStyle(.plain)
        .disabled(mutationInProgress)
        .scrollContentBackground(.hidden)
        .searchable(text: $query, prompt: settings?.clipboardHistoryEnabled == true ? "Search dictations and copies" : "Search your dictations")
        .searchScopes($scope) {
            Text("Dictations").tag(LibraryScope.here)
            Text("Everything").tag(LibraryScope.everything)
        }
        .alert("Could not change the saved copy", isPresented: $clipChangeFailed) { Button("OK") {} }
        .confirmClipboardDeletion($swipeDelete, delete: deleteClip)
        .opensLibraryTargets($target)
        .onReceive(NotificationCenter.default.publisher(for: .init("ZoneLibraryDidChange"))
            .merge(with: NotificationCenter.default.publisher(for: MeetingStore.finishedMeetingDidChange))
            .receive(on: RunLoop.main)) { _ in libraryRevision &+= 1 }
        .task(id: LibraryQuery(words: query, revision: libraryRevision)) {
            guard preview == nil else { return }
            if searching { try? await Task.sleep(for: .milliseconds(140)) }
            guard !Task.isCancelled else { return }
            await finder.search(query, kinds: [.notes, .meetings], notes: coordinator?.notes.notes ?? [], meetings: meetings?.meetings ?? [])
        }
        .navigationTitle("History")
        .zoneBackButton()
        .toolbar(.visible, for: .navigationBar)
        .environment(\.editMode, .constant(selecting ? .active : .inactive))
        .toolbar {
            if !records.isEmpty {
                ZoneBarItem(.topBarTrailing) {
                    Button(selecting ? "Done" : "Select") {
                        withAnimation { selecting.toggle() }
                        if !selecting { selected = []; copiedCount = 0 }
                    }
                }
            }
            if selecting {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(selected.count == records.count ? "Deselect all" : "Select all") {
                        selected = selected.count == records.count ? [] : Set(records.map(\.id))
                        copiedCount = 0
                    }
                    Spacer()
                    Text(selected.isEmpty ? "Pick dictations" : "\(selected.count) selected")
                        .font(.footnote).foregroundStyle(Zone.muted(scheme))
                    Spacer()
                    ShareLink(item: selectionText) { Label("Share", systemImage: "square.and.arrow.up") }
                        .disabled(selected.isEmpty)
                    Button {
                        Clipboard.copy(selectionText)
                        let counts = selectedRecords.map { ($0.id, $0.wordCount) }
                        DictationCoordinator.history { $0.confirmKept(counts) }
                        Haptics.success()
                        copiedCount = selected.count
                    } label: {
                        Label(copiedCount == selected.count && copiedCount > 0 ? "Copied" : "Copy", systemImage: "doc.on.doc")
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
        .zoneScreen()
        .confirmationDialog("Delete all dictations?", isPresented: $confirmingDeleteAll, titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { deleteAll() }
        } message: {
            Text(["This can't be undone. Notes and stats are kept.", LinkCopy.deleteNote(pairedNames, keeping: keepingNames)].compactMap { $0 }.joined(separator: " "))
        }
        .sheet(item: $opened) { record in RecordSheet(record: record, onDelete: { delete(record); opened = nil }) }
        .alert("Some dictation history could not be deleted. Try again.", isPresented: $historyDeleteFailed) {
            Button("Try again") {
                if let failedDeleteRecord { delete(failedDeleteRecord) } else { confirmingDeleteAll = true }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $openedClip) { clip in
            ClipSheet(entry: clip, onDelete: { deleteClip(clip); openedClip = nil }, onPin: { setPinned(clip, $0) })
        }
        .confirmationDialog("Change retention?", isPresented: $confirmingRetention, titleVisibility: .visible) {
            Button(pendingRetention == .off ? "Turn off history" : "Delete older dictations", role: .destructive) {
                if let pendingRetention { setRetention(pendingRetention) }
                pendingRetention = nil
            }
            Button("Cancel", role: .cancel) { pendingRetention = nil }
        } message: {
            Text([pendingRetention == .off
                  ? "Stops saving finished dictations. Notes stay. Recovery files can still appear in backups or return as cut-off dictations. To clear those files too, use Delete everything in Settings > Your data > Delete data."
                  : "Deletes dictations older than \(pendingRetention?.label.lowercased() ?? "that"). Notes and stats are kept.",
                  LinkCopy.agedOutNote(pairedNames)].compactMap { $0 }.joined(separator: " "))
        }
        .refreshable { await load() }
        .task(id: query) { await load() }
        .task(id: scenePhase) {
            guard scenePhase == .active, preview == nil else { return }
            while !Task.isCancelled {
                await load()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
    }

    // MARK: Clipboard

    /// What Zone kept from the clipboard, above the dictations: the newest few and a way to all
    /// of them, or, while searching, the copies that match. Off, one row that leads to the switch.
    @ViewBuilder
    private func clipboardSection(_ settings: AppSettings) -> some View {
        if settings.clipboardHistoryEnabled ? !(searching && visibleClips.isEmpty) : !searching {
            Section {
                ForEach(visibleClips) { clip in
                    ClipRow(entry: clip, marks: clipMarks[clip.id] ?? [], onOpen: { openedClip = clip }, onDelete: { deleteClip(clip) }, onSwipeDelete: { swipeDelete = clip },
                            onPin: { setPinned(clip, !clip.pinned) })
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 12))
                        .listRowBackground(Zone.paper(scheme))
                        .listRowSeparatorTint(Zone.rule(scheme))
                }
                NavigationLink {
                    ClipboardHistoryView()
                } label: {
                    LabeledContent(clipboardLinkTitle(settings, searching: searching),
                                   value: settings.clipboardHistoryEnabled ? "" : "Off")
                        .font(.subheadline)
                        .foregroundStyle(Zone.ink(scheme))
                }
                .accessibilityIdentifier("history.clipboard.all")
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                .listRowBackground(Zone.paper(scheme))
                .listRowSeparatorTint(Zone.rule(scheme))
            } header: {
                Text("Clipboard").font(.subheadline.weight(.semibold)).foregroundStyle(Zone.ink(scheme))
                    .textCase(nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                    .background(Zone.paper(scheme))
                    .listRowInsets(EdgeInsets())
            }
            .listSectionSeparator(.hidden)
        }
    }

    private func clipboardLinkTitle(_ settings: AppSettings, searching: Bool) -> String {
        guard settings.clipboardHistoryEnabled else { return "Keep what you copy" }
        if searching { return "Search all copies" }
        switch clipTotal {
        case 0: return "No copies yet"
        case 1: return "Clipboard history"
        default: return "All \(clipTotal) copies"
        }
    }

    private func deleteClip(_ clip: ClipboardEntry) {
        mutationInProgress = true
        loadToken = UUID()
        Task {
            let saved = await Task.detached { ClipboardHistory.shared?.delete(id: clip.id) }.value
            clipChangeFailed = saved != true
            mutationInProgress = false
            await load()
        }
    }

    private func setPinned(_ clip: ClipboardEntry, _ pinned: Bool) {
        mutationInProgress = true
        loadToken = UUID()
        Task {
            let saved = await Task.detached { ClipboardHistory.shared?.setPinned(id: clip.id, pinned) }.value
            clipChangeFailed = saved != true
            mutationInProgress = false
            await load()
        }
    }

    // MARK: Rows

    private func toggle(_ record: TranscriptRecord) {
        if selected.contains(record.id) { selected.remove(record.id) } else { selected.insert(record.id) }
        copiedCount = 0
    }

    private struct Day { let title: String; let records: [TranscriptRecord] }

    private var days: [Day] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: records) { calendar.startOfDay(for: $0.createdAt) }
        return groups.keys.sorted(by: >).map { day in
            let title: String
            if calendar.isDateInToday(day) { title = "Today" }
            else if calendar.isDateInYesterday(day) { title = "Yesterday" }
            else { title = day.formatted(.dateTime.weekday(.wide).month().day()) }
            return Day(title: title, records: groups[day]!.sorted { $0.createdAt > $1.createdAt })
        }
    }

    private var emptyTitle: String {
        if !query.isEmpty { return elsewhere.isEmpty ? "Nothing matches “\(query)”" : "No dictation matches “\(query)”" }
        return retention == .off ? "History is off" : "No dictations yet"
    }

    private var emptyDetail: String {
        if !query.isEmpty {
            return settings?.clipboardHistoryEnabled == true
                ? "Search reads every word of every saved dictation and kept copy, and close spellings too."
                : "Search reads every word of every saved dictation, and close spellings too."
        }
        return retention == .off
            ? "New dictations aren't saved. Change retention below, or find cut-off dictations here."
            : (retention == .untilDeleted
               ? "Your dictations show up here, text only, until you delete them."
               : "Your dictations show up here, text only, for \(retention.label.lowercased()).")
    }

    // MARK: Store

    private func load() async {
        guard !mutationInProgress else { return }
        if let preview {
            totalRecords = preview.count
            library = preview.reduce(into: (words: 0, bytes: 0)) { $0.words += $1.wordCount; $0.bytes += $1.text.utf8.count }
            retention = previewRetention
            let answer = HistorySearchIndex.answer(query, in: preview, cached: searchIndex)
            records = answer.map { answer in preview.filter { answer.marks[$0.id] != nil } } ?? preview
            marks = answer?.marks ?? [:]
            searchNote = answer?.note
            searchIndex = answer?.index ?? searchIndex
            loaded = true
            return
        }
        guard let history else { storeUnavailable = true; loaded = true; return }
        storeUnavailable = false
        let q = query
        let token = UUID()
        loadToken = token
        // The search and the word count walk the whole library, so they run with the read, off
        // the main thread: this happens every second while History is open.
        let clipsOn = settings?.clipboardHistoryEnabled == true
        // Read here, on the main actor: the detached read below cannot touch the view's statics.
        let clipLimit = q.isEmpty ? Self.shownClips : Self.matchedClips
        let savedRecordings = Set(coordinator?.notes.notes.compactMap(\.recordingID) ?? [])
        let cached = searchIndex
        let (found, kept, shown, size, answer, copies, copyCount, copyMarks) = await Task.detached(priority: .userInitiated) {
            let found = history.records().filter { $0.status != .note && !savedRecordings.contains($0.id) }
            let answer = HistorySearchIndex.answer(q, in: found, cached: cached)
            let shown = answer.map { answer in found.filter { answer.marks[$0.id] != nil } } ?? found
            let size = found.reduce(into: (words: 0, bytes: 0)) { $0.words += $1.wordCount; $0.bytes += $1.text.utf8.count }
            // The same search runs over what was copied, so one field finds either. Nothing is
            // read from the clipboard store while the switch is off.
            var copies: [ClipboardEntry] = []
            var copyMarks: [UUID: [Range<Int>]] = [:]
            var copyCount = 0
            if clipsOn, let clipboard = ClipboardHistory.shared {
                let all = clipboard.entries()
                copyCount = all.count
                let result = ClipboardHistory.matches(q, copies: all)
                copies = Array(result.copies.prefix(clipLimit))
                copyMarks = result.marks
            }
            return (found, history.retention, shown, size, answer, copies, copyCount, copyMarks)
        }.value
        guard !Task.isCancelled, !mutationInProgress, token == loadToken, q == query else { return }
        if clipMarks != copyMarks { clipMarks = copyMarks }
        if clips != copies { clips = copies }
        if clipTotal != copyCount { clipTotal = copyCount }
        // Assign only what changed: rewriting identical state re-renders every row, and a row's
        // long-press menu or a picker menu that is open at that moment can be rebuilt empty
        // underneath the finger.
        if totalRecords != found.count { totalRecords = found.count }
        if library != size { library = size }
        if records != shown { records = shown }
        if marks != (answer?.marks ?? [:]) { marks = answer?.marks ?? [:] }
        if searchNote != answer?.note { searchNote = answer?.note }
        if let index = answer?.index, index.records != cached?.records { searchIndex = index }
        if retention != kept { retention = kept }
        if !loaded { loaded = true }
    }

    private func requestRetention(_ new: HistoryRetention) {
        guard new != retention else { return }
        let shortensRetention = (new.maxAge ?? .infinity) < (retention.maxAge ?? .infinity)
        if shortensRetention && totalRecords > 0 {
            pendingRetention = new
            confirmingRetention = true
        } else {
            setRetention(new)
        }
    }

    private func setRetention(_ new: HistoryRetention) {
        retention = new
        guard preview == nil, let history else { return }
        loadToken = UUID()
        mutationInProgress = true
        Task {
            await Task.detached { history.setRetention(new) }.value
            mutationInProgress = false
            await load()
        }
    }

    private func delete(_ record: TranscriptRecord) {
        records.removeAll { $0.id == record.id }
        guard preview == nil, let history else { return }
        loadToken = UUID()
        mutationInProgress = true
        Task {
            let saved = await Task.detached { history.delete(id: record.id) }.value
            failedDeleteRecord = saved ? nil : record
            historyDeleteFailed = !saved
            mutationInProgress = false
            await load()
        }
    }

    private func deleteAll() {
        records = []
        guard preview == nil, let history else { return }
        loadToken = UUID()
        mutationInProgress = true
        Task {
            let erased = await Task.detached { history.deleteAllWithRecovery(clearingStats: false) }.value
            failedDeleteRecord = nil
            historyDeleteFailed = !erased
            mutationInProgress = false
            await load()
        }
    }
}

/// History's search over its dictations: the same `LibrarySearch` the Notes page uses, so a word
/// in another form, a close spelling or a sound-alike finds a dictation here too. The dictations
/// stay under their days, newest first; the search decides which ones show and lights the words.
struct HistorySearchIndex: Sendable {
    let records: [TranscriptRecord]
    let search: LibrarySearch

    struct Answer: Sendable {
        let marks: [UUID: [Range<Int>]]
        /// Said above the results when the search looked past the words as typed.
        let note: String?
        let index: HistorySearchIndex
    }

    /// nil when there is nothing to search for. Reuses `cached` while the dictations are the same.
    static func answer(_ query: String, in records: [TranscriptRecord], cached: HistorySearchIndex?) -> Answer? {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let index = cached?.records == records ? cached! : HistorySearchIndex(
            records: records,
            search: LibrarySearch(documents: records.map { .init(id: $0.id, text: $0.text, date: $0.createdAt) }))
        let result = index.search.search(query)
        var note: String?
        if result.widened {
            note = "No dictation has every word. These have some."
        } else if let respelled = result.respelled.first, let shown = respelled.found.first {
            note = "No “\(respelled.typed)”. Showing \(shown)."
        }
        return Answer(marks: Dictionary(result.hits.map { ($0.id, $0.ranges) }, uniquingKeysWith: { first, _ in first }), note: note, index: index)
    }
}

/// One dictation in full, with the three things to do with it. Opened from History and from
/// the three on Home.
struct RecordSheet: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @Environment(LinkCoordinator.self) private var link: LinkCoordinator?
    let record: TranscriptRecord
    let onDelete: () -> Void
    @State private var copied = false
    @State private var confirmingDelete = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if record.status == .cutOff {
                        Label("Cut off mid-dictation. Everything recognized up to that point is below.", systemImage: "scissors")
                            .font(.subheadline).foregroundStyle(Zone.live)
                    }
                    if record.status == .offered || record.status == .dismissed || record.status == .notDelivered {
                        Label("Not inserted. Copy it below to paste anywhere.", systemImage: "doc.on.clipboard")
                            .font(.subheadline).foregroundStyle(Zone.muted(scheme))
                    }
                    Text(record.text).font(.body).foregroundStyle(Zone.ink(scheme)).textSelection(.enabled)
                    Text("\(record.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(record.wordCount) words")
                        .font(.footnote).foregroundStyle(Zone.muted(scheme))
                    if let note = KeyboardCapture.historyNote(engine: record.engine, source: record.source) {
                        Text(note).font(.footnote).foregroundStyle(Zone.muted(scheme))
                            .accessibilityIdentifier("history.recognizer")
                    }
                    if let recoveredFrom = record.recoveredFrom { RecoveredFromLabel(date: recoveredFrom) }

                }
                .padding(24)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    Hairline()
                    SavedTextActions(text: record.text, copied: copied, prefix: "record", copy: {
                        Clipboard.copy(record.text)
                        let id = record.id, count = record.wordCount
                        DictationCoordinator.history { $0.confirmKept(id: id, words: count) }
                        Haptics.success()
                        copied = true
                    }, delete: { confirmingDelete = true }) {
                        EmptyView()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .background(Zone.paper(scheme))
            }
            .confirmationDialog("Delete this dictation?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete dictation", role: .destructive, action: onDelete)
            } message: {
                Text(LibraryRow.deleteMessage(link: link))
            }
            .navigationTitle("Dictation")
            .zoneBackButton()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ZoneBarItem(.confirmationAction, prominent: true) { Button("Done") { dismiss() } }
            }
            .zoneScreen()
        }
        .presentationDetents([.medium, .large])
    }
}
