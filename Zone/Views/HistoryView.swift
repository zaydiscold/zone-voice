// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// Every dictation's text, newest first, kept on this device so a long dictation that was cut
/// off or landed in the wrong place can be found and used again.
/// Search, copy, share and delete, how long to keep them, and Delete All. Text only, never audio.
struct HistoryView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(LinkCoordinator.self) private var link: LinkCoordinator?
    /// Fixed records for the design screenshots; nil reads the real store.
    var preview: [TranscriptRecord]? = nil
    var previewRetention: HistoryRetention = .default

    @State private var records: [TranscriptRecord] = []
    @State private var retention: HistoryRetention = .default
    @State private var query = ""
    @State private var loaded = false
    @State private var confirmingDeleteAll = false
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
            } else if records.isEmpty && loaded {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: retention == .off ? "clock.badge.xmark" : "clock.arrow.circlepath")
                            .font(.system(size: 26)).foregroundStyle(Zone.accentText(scheme))
                        Text(emptyTitle).font(.headline).foregroundStyle(Zone.ink(scheme))
                        Text(emptyDetail).font(.subheadline).foregroundStyle(Zone.muted(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 8)
                }
                .listRowBackground(Zone.paper(scheme))
            }

            // The dictations sit on the paper, a hairline apart, under their day: a list, not a
            // stack of cards. Settings below them keep the system's grouped rows.
            ForEach(days, id: \.title) { day in
                Section {
                    ForEach(day.records) { record in
                        LibraryRow(kind: .dictation, text: record.text,
                                   detail: HomeLibraryView.detail(record.createdAt.formatted(date: .omitted, time: .shortened),
                                                                  quiet: HomeLibraryView.quietStatus(record.status)),
                                   alert: HomeLibraryView.alertStatus(record.status), recoveredFrom: record.recoveredFrom,
                                   showsCopy: !selecting,
                                   onOpen: { if selecting { toggle(record) } else { opened = record } },
                                   onDelete: { delete(record) })
                            .tag(record.id)
                            // A full swipe deleted at once; now the swipe shows Delete and a second,
                            // deliberate tap deletes.
                            .swipeActions(allowsFullSwipe: false) {
                                Button(role: .destructive) { delete(record) } label: { Label("Delete", systemImage: "trash") }
                                    .tint(Zone.live)
                            }
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
        .searchable(text: $query, prompt: "Search your dictations")
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
            Text(["This can't be undone. Notes are untouched.", LinkCopy.deleteNote(pairedNames, keeping: keepingNames)].compactMap { $0 }.joined(separator: " "))
        }
        .sheet(item: $opened) { record in RecordSheet(record: record, onDelete: { delete(record); opened = nil }) }
        .confirmationDialog("Change retention?", isPresented: $confirmingRetention, titleVisibility: .visible) {
            Button(pendingRetention == .off ? "Turn off and clear history" : "Delete older dictations", role: .destructive) {
                if let pendingRetention { setRetention(pendingRetention) }
                pendingRetention = nil
            }
            Button("Cancel", role: .cancel) { pendingRetention = nil }
        } message: {
            Text([pendingRetention == .off
                  ? "Clears History and stops saving new dictations. Notes stay, and cut-off dictations are still rescued."
                  : "Deletes dictations older than \(pendingRetention?.label.lowercased() ?? "that"). Notes are untouched.",
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
        if !query.isEmpty { return "Nothing matches “\(query)”" }
        return retention == .off ? "History is off" : "No dictations yet"
    }

    private var emptyDetail: String {
        if !query.isEmpty { return "Searches the text of every saved dictation." }
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
            records = query.isEmpty ? preview : preview.filter { $0.text.localizedCaseInsensitiveContains(query) }
            loaded = true
            return
        }
        guard let history else { storeUnavailable = true; loaded = true; return }
        storeUnavailable = false
        let q = query
        let token = UUID()
        loadToken = token
        let (found, kept) = await Task.detached(priority: .userInitiated) {
            (history.records(), history.retention)
        }.value
        guard !Task.isCancelled, !mutationInProgress, token == loadToken, q == query else { return }
        // This runs every second while History is open. Assign only what changed: rewriting
        // identical state re-renders every row, and a row's long-press menu or a picker menu
        // that is open at that moment can be rebuilt empty underneath the finger.
        let shown = q.isEmpty ? found : found.filter { $0.text.localizedCaseInsensitiveContains(q) }
        if totalRecords != found.count { totalRecords = found.count }
        let size = found.reduce(into: (words: 0, bytes: 0)) { $0.words += $1.wordCount; $0.bytes += $1.text.utf8.count }
        if library != size { library = size }
        if records != shown { records = shown }
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
            await Task.detached { history.delete(id: record.id) }.value
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
            await Task.detached { history.deleteAll() }.value
            mutationInProgress = false
            await load()
        }
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
    @State private var cleaning = false
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
                    if let recoveredFrom = record.recoveredFrom { RecoveredFromLabel(date: recoveredFrom) }
                    HStack(spacing: 10) {
                        Button(copied ? "Copied" : "Copy") {
                            Clipboard.copy(record.text)
                            Haptics.success()
                            copied = true
                        }
                        .buttonStyle(ZonePrimaryButtonStyle())
                        ShareLink(item: record.text) { Text("Share") }.buttonStyle(ZoneQuietButtonStyle(fullWidth: true))
                    }
                    Button("Clean up") { cleaning = true }.buttonStyle(ZoneQuietButtonStyle(fullWidth: true))
                    Button("Delete", role: .destructive) { confirmingDelete = true }
                        .font(.subheadline.weight(.medium)).foregroundStyle(Zone.live)
                        .frame(minHeight: 44)
                        .confirmationDialog("Delete this dictation?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                            Button("Delete dictation", role: .destructive, action: onDelete)
                        } message: {
                            Text(LibraryRow.deleteMessage(link: link))
                        }
                }
                .padding(24)
            }
            .navigationTitle("Dictation")
            .zoneBackButton()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Copy is the large key under the words; a second one up here drew as "..." in
                // the narrow bar slot.
                ZoneBarItem(.confirmationAction, prominent: true) { Button("Done") { dismiss() } }
            }
            .zoneScreen()
        }
        .sheet(isPresented: $cleaning) { CleanupSheet(text: record.text) }
        .presentationDetents([.medium, .large])
    }
}
