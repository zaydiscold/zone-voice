// by zayd/cold @ zayd.wtf

import Combine
import SwiftUI
import ZoneCore

/// The lists a search can read. Zone has one search (`LibrarySearch`) and one kind of result row
/// (`LibraryRow`); each list searches itself by default and offers the others under Everything.
/// A new list (clipboard history) joins by adding a case here and a `rows` branch in
/// `LibraryFinder`.
struct LibraryQuery: Equatable {
    let words: String
    let revision: Int
}

enum LibraryKind: String, CaseIterable, Hashable, Sendable {
    case notes, dictations, meetings

    var title: String {
        switch self {
        case .notes: return "Notes"
        case .dictations: return "Dictations"
        case .meetings: return "Meetings"
        }
    }

    /// "3 notes", "1 dictation".
    func count(_ number: Int) -> String {
        let one: String
        switch self {
        case .notes: one = "note"
        case .dictations: one = "dictation"
        case .meetings: one = "meeting"
        }
        return number == 1 ? "1 \(one)" : "\(number.formatted()) \(one)s"
    }
}

/// Where a search field looks: the list it is on, or every list.
enum LibraryScope: Hashable { case here, everything }

/// Where a tap on a found row goes.
enum LibraryTarget: Hashable, Identifiable {
    case note(NoteRoute)
    case dictation(TranscriptRecord)
    case meeting(UUID)

    var id: String {
        switch self {
        case .note(let route): return "note-\(route.id)"
        case .dictation(let record): return "dictation-\(record.id)"
        case .meeting(let id): return "meeting-\(id)"
        }
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (a: LibraryTarget, b: LibraryTarget) -> Bool { a.id == b.id }
}

/// Runs one query over several lists and hands back rows ready to draw, a group per list. The
/// word indexes are kept while the lists stay the same, and built and searched off the main
/// thread. Used by the Notes page and History for the lists that are not their own, and by
/// `LibrarySearchView` for a list with no search field of its own.
@MainActor
@Observable
final class LibraryFinder {
    struct Row: Identifiable {
        let id: UUID
        let kind: LibraryKind
        let title: String?
        let titleMarks: [Range<Int>]
        let text: String
        let marks: [Range<Int>]
        /// What Copy and Share take.
        let whole: String
        let detail: String
        let alert: String?
        let target: LibraryTarget
    }

    struct Group: Identifiable {
        let kind: LibraryKind
        let rows: [Row]
        /// Every match, when more were found than `rows` holds.
        let total: Int
        /// What the search read in place of a word this list does not have, if anything.
        let note: String?
        var id: LibraryKind { kind }
    }

    /// At most this many rows a list: a search that matches more is asking to be narrowed.
    static let shown = 60

    private(set) var groups: [Group] = []
    /// The query `groups` answers.
    private(set) var answered = ""

    private var notes: (source: [Note], index: LibrarySearch)?
    private var dictations: (source: [TranscriptRecord], index: LibrarySearch)?
    private var meetings: (source: [Meeting], index: LibrarySearch)?
    private var asked = 0

    var total: Int { groups.reduce(0) { $0 + $1.total } }

    /// - Parameters:
    ///   - kinds: the lists to read, in the order their groups should come.
    ///   - notes, meetings: what the stores hold now. Dictations are read from History here.
    func search(_ query: String, kinds: [LibraryKind], notes current: [Note], meetings held: [Meeting]) async {
        asked += 1
        let ticket = asked
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty, !kinds.isEmpty else {
            groups = []
            answered = query
            return
        }
        var found: [Group] = []
        for kind in kinds {
            let group: Group?
            switch kind {
            case .notes: group = await searchNotes(query, current)
            case .dictations: group = await searchDictations(query)
            case .meetings: group = await searchMeetings(query, held)
            }
            guard ticket == asked, !Task.isCancelled else { return }
            if let group, group.total > 0 { found.append(group) }
        }
        groups = found
        answered = query
    }

    // MARK: Each list

    private func searchNotes(_ query: String, _ current: [Note]) async -> Group? {
        if notes?.source != current {
            let index = await Task.detached(priority: .userInitiated) {
                LibrarySearch(documents: current.map { .init(id: $0.id, text: $0.text, date: $0.createdAt) })
            }.value
            notes = (current, index)
        }
        guard let index = notes?.index else { return nil }
        let result = await Task.detached(priority: .userInitiated) { index.search(query) }.value
        let byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = result.hits.prefix(Self.shown).compactMap { hit -> Row? in
            guard let note = byID[hit.id] else { return nil }
            let preview = NotePreview(note.text)
            let shown = preview.found(hit.ranges)
            return Row(id: note.id, kind: .notes, title: shown.lead, titleMarks: shown.leadMarks, text: shown.rest, marks: shown.restMarks,
                       whole: note.text, detail: NoteRow.detail(note, words: preview.words, timeOnly: false), alert: nil,
                       target: .note(NoteRoute(id: note.id, marks: hit.ranges)))
        }
        return Group(kind: .notes, rows: rows, total: result.hits.count, note: Self.note(result, kind: .notes))
    }

    private func searchDictations(_ query: String) async -> Group? {
        // History is read each time: a dictation made a moment ago should be found. The dictation
        // behind a voice note is left to Notes, which has the note itself.
        let current = await Task.detached(priority: .userInitiated) {
            TranscriptHistory.shared?.records().filter { $0.status != .note } ?? []
        }.value
        if dictations?.source != current {
            let index = await Task.detached(priority: .userInitiated) {
                LibrarySearch(documents: current.map { .init(id: $0.id, text: $0.text, date: $0.createdAt) })
            }.value
            dictations = (current, index)
        }
        guard let index = dictations?.index else { return nil }
        let result = await Task.detached(priority: .userInitiated) { index.search(query) }.value
        let byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = result.hits.prefix(Self.shown).compactMap { hit -> Row? in
            guard let record = byID[hit.id] else { return nil }
            let shown = LibrarySearch.excerpt(record.text, marks: hit.ranges)
            return Row(id: record.id, kind: .dictations, title: nil, titleMarks: [], text: shown.text, marks: shown.marks, whole: record.text,
                       detail: HomeLibraryView.detail(LibraryRow.when(record.createdAt), quiet: HomeLibraryView.quietStatus(record.status)),
                       alert: HomeLibraryView.alertStatus(record.status), target: .dictation(record))
        }
        return Group(kind: .dictations, rows: rows, total: result.hits.count, note: Self.note(result, kind: .dictations))
    }

    private func searchMeetings(_ query: String, _ held: [Meeting]) async -> Group? {
        // Only meetings with words: one still recording or waiting has nothing to find but its name.
        let current = held
        if meetings?.source != current {
            let index = await Task.detached(priority: .userInitiated) {
                LibrarySearch(documents: current.map { .init(id: $0.id, text: Self.words(of: $0), date: $0.createdAt) })
            }.value
            meetings = (current, index)
        }
        guard let index = meetings?.index else { return nil }
        let result = await Task.detached(priority: .userInitiated) { index.search(query) }.value
        let byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = result.hits.prefix(Self.shown).compactMap { hit -> Row? in
            guard let meeting = byID[hit.id] else { return nil }
            // The name is the first line of what was searched; the transcript follows it.
            let name = meeting.title.utf16.count
            let inName = hit.ranges.compactMap { mark -> Range<Int>? in
                mark.lowerBound < name ? mark.lowerBound..<min(mark.upperBound, name) : nil
            }
            let body = Self.transcript(of: meeting)
            let inBody = hit.ranges.compactMap { mark -> Range<Int>? in
                mark.lowerBound > name ? (mark.lowerBound - name - 1)..<(mark.upperBound - name - 1) : nil
            }
            let shown = LibrarySearch.excerpt(body, marks: inBody)
            return Row(id: meeting.id, kind: .meetings, title: meeting.title, titleMarks: inName, text: shown.text, marks: shown.marks,
                       whole: MeetingExport.text(meeting), detail: meetingMetaLine(meeting), alert: nil, target: .meeting(meeting.id))
        }
        return Group(kind: .meetings, rows: rows, total: result.hits.count, note: Self.note(result, kind: .meetings))
    }

    /// A meeting as the search reads it: its name, then who said what.
    nonisolated static func words(of meeting: Meeting) -> String {
        meeting.title + "\n" + transcript(of: meeting)
    }

    nonisolated static func transcript(of meeting: Meeting) -> String {
        MeetingExport.paragraphs(meeting).filter { !$0.isGap }.map { paragraph in
            (meeting.speakerName(paragraph.speaker).map { "\($0): " } ?? "") + paragraph.text
        }.joined(separator: " ")
    }

    /// Said beside a list's heading when the search looked past the words as typed.
    static func note(_ result: LibrarySearch.Result, kind: LibraryKind) -> String? {
        if result.widened { return "some of the words" }
        if let respelled = result.respelled.first, let shown = respelled.found.first { return "no “\(respelled.typed)”, showing \(shown)" }
        return nil
    }
}

/// The groups a `LibraryFinder` found, as sections of a list: a heading per list with how many
/// it found, then the same rows History and Notes draw.
struct LibraryFoundSections: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(MeetingCoordinator.self) private var meetings
    @Environment(DictationCoordinator.self) private var coordinator
    let groups: [LibraryFinder.Group]
    let open: (LibraryTarget) -> Void
    @State private var failure: String?
    @State private var mergeTarget: Meeting?

    var body: some View {
        ForEach(groups) { group in
            Section {
                ForEach(group.rows) { row in
                    foundRow(row)
                        .listRowInsets(EdgeInsets(top: 2, leading: 20, bottom: 2, trailing: 12))
                        .listRowBackground(Zone.paper(scheme))
                        .listRowSeparatorTint(Zone.rule(scheme))
                }
            } header: {
                Text(Self.heading(group))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Zone.ink(scheme))
                    .textCase(nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                    .background(Zone.paper(scheme))
                    .listRowInsets(EdgeInsets())
                    .accessibilityIdentifier("search.group.\(group.kind.rawValue)")
            }
            .listSectionSeparator(.hidden)
        }
        .sheet(item: $mergeTarget) { target in
            MergePicker(target: target.id) { _ in }.presentationDetents([.medium, .large])
        }
        .alert("Could not delete this item", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: { Text(failure ?? "Try again.") }
    }

    @ViewBuilder private func foundRow(_ row: LibraryFinder.Row) -> some View {
        if case .meeting(let id) = row.target, let meeting = meetings.meeting(id) {
            HStack(alignment: .firstTextBaseline) {
                Button { open(row.target) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LibraryRow.marked(row.title ?? meeting.title, row.titleMarks, scheme: scheme)).bold()
                        Text(LibraryRow.marked(row.text, row.marks, scheme: scheme)).lineLimit(3)
                        Text(row.detail).font(.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).accessibilityIdentifier("meeting.row")
                LibraryCopyButton(noun: "transcript", copied: false) { Clipboard.copy(row.whole) }
            }
            .padding(.vertical, 10)
            .modifier(MeetingRowMenu(meeting: meeting, merge: { mergeTarget = meeting }))
        } else if case .note(let route) = row.target {
            LibraryRow(kind: .note, title: row.title, text: row.text, whole: row.whole, titleMarks: row.titleMarks,
                       marks: row.marks, detail: row.detail, lineLimit: 3, onOpen: { open(row.target) },
                       onDelete: { if !coordinator.deleteNote(route.id) { failure = coordinator.notes.lastError ?? "Try again." } }, extraActions: [
                        .init(title: "Edit", symbol: "pencil") { open(.note(NoteRoute(id: route.id, opensEditor: true))) }
                       ])
        } else if case .dictation(let record) = row.target {
            LibraryRow(kind: .dictation, text: row.text, whole: row.whole, marks: row.marks,
                       detail: row.detail, alert: row.alert, lineLimit: 3, onOpen: { open(row.target) },
                       onDelete: {
                           Task {
                               let deleted = await Task.detached { TranscriptHistory.shared?.delete(id: record.id) }.value
                               if deleted != true { failure = "Try again." }
                           }
                       })
        }
    }

    /// "Dictations · 4", "Meetings · 2 (no “dentest”, showing dentist)".
    static func heading(_ group: LibraryFinder.Group) -> String {
        let count = group.total > group.rows.count ? "first \(group.rows.count) of \(group.total.formatted())" : "\(group.total.formatted())"
        return "\(group.kind.title) · \(count)" + (group.note.map { " (\($0))" } ?? "")
    }
}

/// One line under a list's own results: what the same words found in the other lists, and the
/// way to see it. Shown only while the search is scoped to the list it is on.
struct LibraryElsewhereRow: View {
    @Environment(\.colorScheme) private var scheme
    let groups: [LibraryFinder.Group]
    let showEverything: () -> Void

    var body: some View {
        if !groups.isEmpty {
            Button(action: showEverything) {
                HStack(spacing: 8) {
                    Text(Self.line(groups))
                        .font(.subheadline).zoneAccentLink(scheme)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Zone.accentTone(scheme))
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Searches every list")
            .accessibilityIdentifier("search.elsewhere")
            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
            .listRowBackground(Zone.paper(scheme))
            .listRowSeparator(.hidden)
        }
    }

    /// "Also 4 dictations and 1 meeting".
    static func line(_ groups: [LibraryFinder.Group]) -> String {
        "Also " + groups.map { $0.kind.count($0.total) }.formatted(.list(type: .and))
    }
}

/// Opens what a found row points at: a note to read, a dictation's sheet, a meeting's page.
/// Attached once by the screen that shows `LibraryFoundSections`.
struct LibraryOpening: ViewModifier {
    @Binding var target: LibraryTarget?
    @State private var deleteFailed = false

    private var note: Binding<NoteRoute?> {
        Binding(get: { if case .note(let route) = target { return route } else { return nil } },
                set: { if $0 == nil, case .note = target { target = nil } })
    }
    private var record: Binding<TranscriptRecord?> {
        Binding(get: { if case .dictation(let record) = target { return record } else { return nil } },
                set: { if $0 == nil, case .dictation = target { target = nil } })
    }
    private var meeting: Binding<MeetingRoute?> {
        Binding(get: { if case .meeting(let id) = target { return MeetingRoute(id: id) } else { return nil } },
                set: { if $0 == nil, case .meeting = target { target = nil } })
    }

    func body(content: Content) -> some View {
        content
            .navigationDestination(item: note) { NoteReadView($0) }
            .navigationDestination(item: meeting) { MeetingDetailView(id: $0.id) }
            .alert("Could not delete dictation", isPresented: $deleteFailed) { Button("OK") {} }
            .sheet(item: record) { record in
                RecordSheet(record: record, onDelete: {
                    let id = record.id
                    Task {
                        let saved = await Task.detached { TranscriptHistory.shared?.delete(id: id) }.value
                        target = nil
                        deleteFailed = saved != true
                    }
                })
            }
    }
}

struct MeetingRoute: Hashable, Identifiable { let id: UUID }

extension View {
    func opensLibraryTargets(_ target: Binding<LibraryTarget?>) -> some View { modifier(LibraryOpening(target: target)) }
}

/// A search page for a list that has no search field of its own: the list's own matches first,
/// and every other list under Everything. `LibrarySearchView(home: .meetings)` is all the
/// Meetings tab needs to be searchable.
struct LibrarySearchView: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(MeetingCoordinator.self) private var meetings
    @Environment(\.colorScheme) private var scheme
    let home: LibraryKind

    @State private var query = ""
    @State private var scope: LibraryScope = .here
    @State private var finder = LibraryFinder()
    @State private var libraryRevision = 0
    @State private var target: LibraryTarget?

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var own: [LibraryFinder.Group] { finder.groups.filter { $0.kind == home } }
    private var others: [LibraryFinder.Group] { finder.groups.filter { $0.kind != home } }

    var body: some View {
        List {
            if searching, finder.answered == query {
                LibraryFoundSections(groups: scope == .everything ? finder.groups : own) { target = $0 }
                if scope == .here { LibraryElsewhereRow(groups: others) { scope = .everything } }
                if (scope == .everything ? finder.groups : own).isEmpty, scope == .everything || others.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 26)).foregroundStyle(Zone.accentTone(scheme))
                        Text("Nothing matches “\(query)”").font(.headline).foregroundStyle(Zone.ink(scheme))
                        Text("Search reads every word, and close spellings too.").font(.subheadline).foregroundStyle(Zone.muted(scheme))
                    }
                    .padding(.vertical, 8)
                    .listRowBackground(Zone.paper(scheme))
                    .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .searchable(text: $query, prompt: "Search \(home.title.lowercased())")
        .searchScopes($scope) {
            Text(home.title).tag(LibraryScope.here)
            Text("Everything").tag(LibraryScope.everything)
        }
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .navigationTitle("Search")
        .zoneBackButton()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .zoneScreen()
        .opensLibraryTargets($target)
        .onReceive(NotificationCenter.default.publisher(for: .init("ZoneLibraryDidChange"))
            .merge(with: NotificationCenter.default.publisher(for: MeetingStore.finishedMeetingDidChange))
            .receive(on: RunLoop.main)) { _ in libraryRevision &+= 1 }
        .task(id: LibraryQuery(words: query, revision: libraryRevision)) {
            if searching { try? await Task.sleep(for: .milliseconds(90)) }
            guard !Task.isCancelled else { return }
            await finder.search(query, kinds: [home] + LibraryKind.allCases.filter { $0 != home },
                                notes: coordinator.notes.notes, meetings: meetings.meetings)
        }
    }
}
