// by zayd/cold @ zayd.wtf

import Combine
import SwiftUI
import ZoneCore

/// One note in a list: a few of its own words in bold to know it by, the words after them to
/// skim, then when it was said and, for a long one, how long it is. Under a search it shows the
/// part that was found instead, with the found words lit. Home shows three of these; the Notes
/// page shows them all.
struct NoteRow: View {
    @Environment(DictationCoordinator.self) private var coordinator
    let note: Note
    @State private var deleteFailed = false
    /// The search's ranges in this note, or nil when just browsing.
    var marks: [Range<Int>]? = nil
    /// Lines of the note under its lead.
    var lines = 2
    /// The time alone, under a heading that already says the day.
    var timeOnly = false
    var swipeDelete: (() -> Void)? = nil
    let onOpen: (NoteRoute) -> Void

    /// A note this long gets its length in the quiet line: under it, the row shows most of it.
    static let lengthFrom = 40

    var body: some View {
        let preview = NotePreview(note.text)
        let found = marks.map { preview.found($0) }
        LibraryRow(kind: .note, title: found?.lead ?? preview.lead, text: found?.rest ?? preview.rest, whole: note.text,
                   titleMarks: found?.leadMarks ?? [], marks: found?.restMarks ?? [],
                   detail: Self.detail(note, words: preview.words, timeOnly: timeOnly), lineLimit: lines,
                   highlighted: coordinator.noteReveal?.noteID == note.id,
                   onOpen: { onOpen(NoteRoute(id: note.id, marks: marks ?? [])) },
                   onDelete: { deleteFailed = !coordinator.deleteNote(note.id) },
                   extraActions: [.init(title: "Edit", symbol: "pencil") {
                       onOpen(NoteRoute(id: note.id, opensEditor: true))
                   }], swipeDelete: swipeDelete)
            .alert("Could not delete note", isPresented: $deleteFailed) {
                Button("OK") {}
            } message: { Text(coordinator.notes.lastError ?? "Try again.") }
    }

    static func detail(_ note: Note, words: Int, timeOnly: Bool) -> String {
        var parts = [timeOnly ? note.createdAt.formatted(date: .omitted, time: .shortened) : LibraryRow.when(note.createdAt)]
        if words >= lengthFrom { parts.append("\(words.formatted()) words") }
        if note.editedAt != nil { parts.append("Edited") }
        return parts.joined(separator: " · ")
    }
}

/// Every note, newest first, under a few headings (today, yesterday, this week, this month, then
/// months and years), with a search that reads every word of every note and forgives the
/// spellings speech and thumbs produce (`LibrarySearch`). Tapping a note opens it to read. Home's
/// "See all" comes here, the way History's does.
struct NotesView: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(MeetingCoordinator.self) private var meetings
    @Environment(LinkCoordinator.self) private var link: LinkCoordinator?
    @Environment(\.colorScheme) private var scheme
    /// A note to arrive at: scrolled to and lit (Added to Notes, for a note below Home's three).
    var reveal: UUID? = nil

    @State private var query = ""
    @State private var index: LibrarySearch?
    /// The notes the index was built from, to tell when it is out of date.
    @State private var indexed: [Note] = []
    @State private var result: LibrarySearch.Result?
    /// The query `result` answers: rows never show one search's marks under another's words.
    @State private var answered = ""
    @State private var reading: NoteRoute?
    /// The search looks at notes, or at every list: the same words in dictations and meetings.
    @State private var scope: LibraryScope = .here
    @State private var finder = LibraryFinder()
    @State private var libraryRevision = 0
    @State private var target: LibraryTarget?
    @State private var deleting: Note?
    @State private var deleteFailed = false
    @State private var revealed = false
    /// The headings and the count line, worked out when the notes change and not on every
    /// redraw: with hundreds of notes a keystroke in the search field should cost nothing here.
    @State private var groups: [NoteGroup] = []
    @State private var footer = ""
    /// Counts index builds, so a search is run again when a note under it was edited.
    @State private var revision = 0

    private var notes: [Note] { coordinator.notes.notes }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var noteList: some View {
        ScrollViewReader { reader in
            List {
                if let error = coordinator.notes.lastError {
                    Text(error).font(.footnote).foregroundStyle(Zone.live)
                        .listRowBackground(Zone.paper(scheme))
                }
                if notes.isEmpty && !searching {
                    empty(symbol: "note.text", title: "No notes yet",
                          detail: "Say a note with the Action Button, or tap New note. Each one is kept here until you delete it.")
                } else if searching {
                    results
                } else {
                    ForEach(groups, id: \.title) { group in
                        Section {
                            ForEach(group.notes) { note in
                                row(note, marks: nil, timeOnly: group.byDay)
                            }
                        } header: {
                            heading(group.title)
                        }
                        .listSectionSeparator(.hidden)
                    }
                    Section {
                        Text(footer)
                            .font(.footnote).foregroundStyle(Zone.muted(scheme))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 16)
                            .padding(.bottom, 24)
                            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                            .listRowBackground(Zone.paper(scheme))
                            .listRowSeparator(.hidden)
                            .accessibilityIdentifier("notes.footer")
                    }
                    .listSectionSeparator(.hidden)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .searchable(text: $query, prompt: "Search your notes")
            .searchScopes($scope) {
                Text("Notes").tag(LibraryScope.here)
                Text("Everything").tag(LibraryScope.everything)
            }
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onChange(of: groups.count, initial: true) { _, _ in
                guard let reveal, !revealed, !groups.isEmpty, notes.contains(where: { $0.id == reveal }) else { return }
                revealed = true
                // One pass for the list to exist before scrolling in it.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.5)) { reader.scrollTo(reveal, anchor: .center) }
                }
            }
        }
    }

    private var navigation: some View {
        noteList
        .navigationTitle("Notes")
        .zoneBackButton()
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ZoneBarItem(.topBarTrailing) {
                NewNoteButton {
                    Label("New note", systemImage: "mic.fill").labelStyle(.titleAndIcon)
                }
                .accessibilityIdentifier("notes.newNote")
            }
        }
        .zoneScreen()
        .navigationDestination(item: $reading) { NoteReadView($0) }
        .opensLibraryTargets($target)
        .confirmationDialog("Delete this note?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { note in
            Button("Delete note", role: .destructive) { deleteFailed = !coordinator.deleteNote(note.id) }
        } message: { _ in
            Text(LibraryRow.deleteMessage(link: link))
        }
        .alert("Could not delete note", isPresented: $deleteFailed) {
            Button("OK") {}
        } message: { Text(coordinator.notes.lastError ?? "Try again.") }
    }

    var body: some View {
        navigation
        // The index is rebuilt off the main thread whenever a note is added, edited or deleted,
        // and the search runs there too, a moment after the last keystroke.
        .onChange(of: notes, initial: true) { _, _ in regroup() }
        .task(id: notes) { await buildIndex() }
        .task(id: SearchKey(query: query, revision: revision)) { await search() }
        // The same words in the other lists: counted under the notes, listed under Everything.
        .onReceive(NotificationCenter.default.publisher(for: .init("ZoneLibraryDidChange"))
            .merge(with: NotificationCenter.default.publisher(for: MeetingStore.finishedMeetingDidChange))
            .receive(on: RunLoop.main)) { _ in libraryRevision &+= 1 }
        .task(id: LibraryQuery(words: query, revision: libraryRevision)) {
            if searching { try? await Task.sleep(for: .milliseconds(140)) }
            guard !Task.isCancelled else { return }
            await finder.search(query, kinds: [.dictations, .meetings], notes: [], meetings: meetings.meetings)
        }
    }

    // MARK: Rows

    private func row(_ note: Note, marks: [Range<Int>]?, timeOnly: Bool) -> some View {
        NoteRow(note: note, marks: marks, lines: 4, timeOnly: timeOnly, swipeDelete: { deleting = note }) { reading = $0.within(sequence) }
            .id(note.id)
            .listRowInsets(EdgeInsets(top: 2, leading: 20, bottom: 2, trailing: 12))
            .listRowBackground(Zone.recess(scheme))
            .listRowSeparatorTint(Zone.rule(scheme))
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Zone.ink(scheme))
            .textCase(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 4)
            .background(Zone.paper(scheme))
            .listRowInsets(EdgeInsets())
    }

    private func empty(symbol: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(Zone.accentTone(scheme))
            Text(title).font(.headline).foregroundStyle(Zone.ink(scheme))
            Text(detail).font(.subheadline).foregroundStyle(Zone.muted(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
        .listRowBackground(Zone.paper(scheme))
        .listRowSeparator(.hidden)
    }

    private struct NoteGroup { let title: String; let byDay: Bool; let notes: [Note] }

    /// The notes as the page lists them now, for the read page's Note above and Note below: the
    /// search's results while searching, otherwise every note under its heading.
    private var sequence: [NoteStep] {
        if searching, answered == query, let result {
            return result.hits.map { NoteStep(id: $0.id, marks: $0.ranges) }
        }
        return groups.flatMap { $0.notes.map { NoteStep(id: $0.id) } }
    }

    /// Newest first, as the store keeps them; a restored backup can put an old note anywhere, so
    /// the groups are made by date and not by position.
    private func regroup() {
        let now = Date()
        var order: [String] = []
        var grouped: [String: [Note]] = [:]
        var words = 0
        for note in notes.sorted(by: { $0.createdAt > $1.createdAt }) {
            let title = NoteGroups.title(for: note.createdAt, now: now)
            if grouped[title] == nil { order.append(title) }
            grouped[title, default: []].append(note)
            words += NotePreview(note.text).words
        }
        groups = order.map { NoteGroup(title: $0, byDay: $0 == "Today" || $0 == "Yesterday", notes: grouped[$0] ?? []) }
        footer = "\(notes.count == 1 ? "1 note" : "\(notes.count.formatted()) notes") · \(words.formatted()) words"
    }

    // MARK: Search

    @ViewBuilder private var results: some View {
        let byID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let current = answered == query ? result : nil
        let hits = (current?.hits ?? []).compactMap { hit in byID[hit.id].map { (note: $0, hit: hit) } }
        let elsewhere = finder.answered == query ? finder.groups : []
        if let current {
            if !hits.isEmpty {
                Section {
                    ForEach(hits, id: \.note.id) { item in
                        row(item.note, marks: item.hit.ranges, timeOnly: false)
                    }
                } header: {
                    heading(Self.summary(current, count: hits.count))
                        .accessibilityIdentifier("notes.searchSummary")
                }
                .listSectionSeparator(.hidden)
            } else if elsewhere.isEmpty {
                empty(symbol: "magnifyingglass", title: "Nothing matches “\(query)”",
                      detail: "Search reads every word of every note, and close spellings too.")
            } else if scope == .here {
                Text("No note matches “\(query)”.")
                    .font(.subheadline).foregroundStyle(Zone.muted(scheme))
                    .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 0, trailing: 20))
                    .listRowBackground(Zone.paper(scheme))
                    .listRowSeparator(.hidden)
            }
            if scope == .everything {
                LibraryFoundSections(groups: elsewhere) { target = $0 }
            } else {
                LibraryElsewhereRow(groups: elsewhere) { scope = .everything }
            }
        }
    }

    /// What the search did, in a line: how many it found, and when it had to look past the words
    /// as typed, which words it read instead.
    static func summary(_ result: LibrarySearch.Result, count: Int) -> String {
        let found = count == 1 ? "1 note" : "\(count.formatted()) notes"
        if result.widened { return "No note has every word. \(found) with some" }
        if let respelled = result.respelled.first, let shown = respelled.found.first {
            return "No “\(respelled.typed)”. Showing \(shown)"
        }
        return found
    }

    private struct SearchKey: Equatable { let query: String; let revision: Int }

    private func buildIndex() async {
        let current = notes
        guard current != indexed || index == nil else { return }
        let built = await Task.detached(priority: .userInitiated) {
            LibrarySearch(documents: current.map { .init(id: $0.id, text: $0.text, date: $0.createdAt) })
        }.value
        guard !Task.isCancelled else { return }
        index = built
        indexed = current
        revision += 1
    }

    private func search() async {
        let asked = query
        guard searching, let index else {
            if !searching { result = nil; answered = "" }
            return
        }
        // Typing fast should not search for every letter on the way.
        if result != nil { try? await Task.sleep(for: .milliseconds(90)) }
        guard !Task.isCancelled else { return }
        let found = await Task.detached(priority: .userInitiated) { index.search(asked) }.value
        guard !Task.isCancelled, asked == query else { return }
        result = found
        answered = asked
    }
}
