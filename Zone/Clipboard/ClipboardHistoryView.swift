// by zayd/cold @ zayd.wtf

import SwiftUI
import UniformTypeIdentifiers
import ZoneCore

/// Everything Zone kept from the clipboard, newest first: the copy that was never pasted, found
/// again. Rows like the rest of the library (Copy beside the words, delete asks first), search,
/// and under them the one switch, what to skip, how long to keep, and Delete all.
struct ClipboardHistoryView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(AppSettings.self) private var settings

    @State private var entries: [ClipboardEntry] = []
    @State private var marks: [UUID: [Range<Int>]] = [:]
    @State private var storageBytes: Int64 = 0
    @State private var total = 0
    @State private var retention: ClipboardRetention = .default
    @State private var skips: [ClipboardSkip: Int] = [:]
    @State private var query = ""
    @State private var loaded = false
    @State private var swipeDelete: ClipboardEntry?
    @State private var opened: ClipboardEntry?
    @State private var confirmingDeleteAll = false
    @State private var confirmingOff = false
    @State private var generation = 0
    @State private var lastWrite: Date?
    @State private var nextExpiry = Date.distantFuture
    @State private var changing = false
    @State private var changeFailed = false
    @State private var pasteNote: String?

    private var history: ClipboardHistory? { ClipboardHistory.shared }

    var body: some View {
        @Bindable var settings = settings
        List {
            if !settings.clipboardHistoryEnabled {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 26)).foregroundStyle(Zone.accentTone(scheme))
                        Text("Keep what you copy").font(.headline).foregroundStyle(Zone.ink(scheme))
                        Text("Save a copy here before the next one replaces it. Find it again from History or your Zone keyboard.")
                            .font(.subheadline).foregroundStyle(Zone.muted(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 8)
                }
                .listRowBackground(Zone.paper(scheme))
                .listRowSeparator(.hidden)
            } else if entries.isEmpty && loaded {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 26)).foregroundStyle(Zone.accentTone(scheme))
                        Text(query.isEmpty ? "No copies yet" : "Nothing matches “\(query)”")
                            .font(.headline).foregroundStyle(Zone.ink(scheme))
                        Text(query.isEmpty
                             ? "Copy text or an image, then tap Paste below to save it without inserting it."
                             : "Searches the text of every kept copy.")
                            .font(.subheadline).foregroundStyle(Zone.muted(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 8)
                }
                .listRowBackground(Zone.paper(scheme))
                .listRowSeparator(.hidden)
            }

            if settings.clipboardHistoryEnabled {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Save what is copied now")
                        if let pasteNote {
                            Text(pasteNote).font(.footnote).foregroundStyle(Zone.muted(scheme))
                                .accessibilityIdentifier("clipboard.pasteNote")
                        }
                    }
                    Spacer()
                    // Apple's paste button: the tap is the permission, so iOS asks nothing.
                    SaveCopyControl(saveImage: saveImage, save: savePasted)
                        .frame(width: 44, height: 36)
                }
                .listRowBackground(Zone.paper(scheme))
            }

            ForEach(days, id: \.title) { day in
                Section {
                    ForEach(day.entries) { entry in
                        ClipRow(entry: entry, marks: marks[entry.id] ?? [], onOpen: { opened = entry }, onDelete: { delete(entry) }, onSwipeDelete: { swipeDelete = entry },
                                onPin: { setPinned(entry, !entry.pinned) })
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
                Toggle("Clipboard history", isOn: Binding(
                    get: { settings.clipboardHistoryEnabled },
                    set: { on in
                        if on { settings.clipboardHistoryEnabled = true; Task { await load() } }
                        else if total > 0 { confirmingOff = true }
                        else { settings.clipboardHistoryEnabled = false }
                    }))
                    .accessibilityIdentifier("clipboard.switch")
                if settings.clipboardHistoryEnabled {
                    Toggle("Automatically save copies", isOn: $settings.clipboardAutomatic)
                        .accessibilityIdentifier("clipboard.automatic")
                    Text("While Zone or its keyboard is visible, save the current text or image when it changes. iOS may ask for paste permission. Copies replaced while both are closed are unavailable.")
                        .font(.footnote).foregroundStyle(Zone.muted(scheme))
                    Toggle("Skip things that look like passwords", isOn: $settings.clipboardSkipsSecrets)
                        .accessibilityIdentifier("clipboard.skipSecrets")
                    Picker("Keep copies for", selection: Binding(get: { retention }, set: { setRetention($0) })) {
                        ForEach(ClipboardRetention.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    if total > 0 {
                        Button("Delete all copies", role: .destructive) { confirmingDeleteAll = true }
                    }
                }
            } header: {
                Spacer(minLength: 0).frame(height: 20).listRowInsets(EdgeInsets())
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(settings.clipboardHistoryEnabled ? Self.howItWorks : Self.whenOff)
                        .accessibilityIdentifier("clipboard.footer")
                    if settings.clipboardHistoryEnabled {
                        Text(Self.whereItIsKept)
                        Text("Clipboard storage: \(ByteCountFormatter.string(fromByteCount: storageBytes, countStyle: .file))")
                        if let tally = ClipboardCopyText.tally(skips) {
                            Text(tally).accessibilityIdentifier("clipboard.tally")
                        }
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
        .disabled(changing)
        .alert("Could not change clipboard history", isPresented: $changeFailed) {
            Button("OK") {}
        } message: { Text("Check available storage. If the pinned list is full, unpin a copy and try again.") }
        .scrollContentBackground(.hidden)
        .searchable(text: $query, prompt: "Search your copies")
        .confirmClipboardDeletion($swipeDelete, delete: delete)
        .navigationTitle("Clipboard")
        .zoneBackButton()
        .toolbar(.visible, for: .navigationBar)
        .zoneScreen()
        .confirmationDialog("Delete all copies?", isPresented: $confirmingDeleteAll, titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { deleteAll() }
        } message: {
            Text("This can't be undone. Kept copies go too. Dictations and notes are untouched.")
        }
        .confirmationDialog("Turn off clipboard history?", isPresented: $confirmingOff, titleVisibility: .visible) {
            Button("Turn off and delete \(total == 1 ? "the copy" : "all \(total) copies")", role: .destructive) {
                settings.clipboardHistoryEnabled = false
                deleteAll()
            }
            Button("Turn off and keep them") { settings.clipboardHistoryEnabled = false }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Zone stops reading the clipboard. Copies already saved stay on this iPhone until they expire or you delete them.")
        }
        .sheet(item: $opened) { entry in
            ClipSheet(entry: entry, onDelete: { delete(entry); opened = nil },
                      onPin: { setPinned(entry, $0) })
        }
        .refreshable { await load() }
        .task(id: query) { await load() }
        .task(id: scenePhase == .active && settings.clipboardHistoryEnabled) {
            guard scenePhase == .active && settings.clipboardHistoryEnabled else { return }
            // A copy made inside Zone while this screen is open shows up within a second.
            while !Task.isCancelled {
                if !loaded || history?.lastWrite != lastWrite || Date() >= nextExpiry { await load() }
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
    }

    static let howItWorks = "By default, Paste keeps passwords and API keys, even in or just after a password, code or card field. Turn on the filter to skip sensitive copies."
    static let whereItIsKept = LinkCopy.clipboardStorage + " A copy reaches a computer only when you send it, or add it to Notes and Zone Link syncs that note."
    static let whenOff = "Turn this on to keep text and images you paste with Zone or choose to save."

    // MARK: Rows

    private struct Day { let title: String; let entries: [ClipboardEntry] }

    private var days: [Day] {
        if !query.isEmpty { return entries.isEmpty ? [] : [Day(title: "Matches", entries: entries)] }
        let calendar = Calendar.current
        let groups = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.savedAt) }
        return groups.keys.sorted(by: >).map { day in
            let title: String
            if calendar.isDateInToday(day) { title = "Today" }
            else if calendar.isDateInYesterday(day) { title = "Yesterday" }
            else { title = day.formatted(.dateTime.weekday(.wide).month().day()) }
            return Day(title: title, entries: groups[day]!.sorted { $0.savedAt > $1.savedAt })
        }
    }

    // MARK: Store

    private func load() async {
        guard let history else { loaded = true; return }
        guard !changing else { return }
        generation &+= 1
        let request = generation
        let q = query
        let (found, matches, kept, counted, bytes, stamp, expiry) = await Task.detached(priority: .userInitiated) {
            let stamp = history.lastWrite
            let snapshot = history.snapshot()
            let shown = ClipboardHistory.matches(q, copies: snapshot.copies)
            let expiry = snapshot.copies.lazy.filter { !$0.pinned }.map { $0.savedAt.addingTimeInterval(snapshot.retention.maxAge) }.min()
            return (snapshot.copies.count, shown, snapshot.retention, snapshot.skips, DiskUsage.bytes(at: history.directory), stamp, expiry)
        }.value
        guard !Task.isCancelled, request == generation, q == query else { return }
        lastWrite = stamp
        nextExpiry = expiry ?? .distantFuture
        storageBytes = bytes
        if total != found { total = found }
        if entries != matches.copies { entries = matches.copies }
        if marks != matches.marks { marks = matches.marks }
        if retention != kept { retention = kept }
        if skips != counted { skips = counted }
        if !loaded { loaded = true }
    }

    private func change(_ work: @escaping @Sendable (ClipboardHistory) -> Bool) {
        guard !changing else { return }
        guard let history else { changeFailed = true; return }
        changing = true
        generation &+= 1
        Task {
            let saved = await Task.detached { work(history) }.value
            changing = false
            changeFailed = !saved
            await load()
        }
    }

    private func delete(_ entry: ClipboardEntry) {
        change { $0.delete(id: entry.id) }
    }

    private func deleteAll() {
        change { $0.deleteAll() }
    }

    private func setPinned(_ entry: ClipboardEntry, _ pinned: Bool) {
        change { $0.setPinned(id: entry.id, pinned) }
    }

    private func setRetention(_ new: ClipboardRetention) {
        change { $0.setRetention(new) }
    }

    private func saveImage(_ image: ClipboardImage?, types: [String], token: ClipboardPasteToken) {
        guard let image, let history else { pasteNote = "Zone could not read this image. Try saving a smaller copy."; return }
        let outcome = ClipboardCapture.keepDelivered("", image: image, types: types, token: token,
            deliveredChangeCount: UIPasteboard.general.changeCount, settings: .init(enabled: settings.clipboardHistoryEnabled,
            skipsSecrets: settings.clipboardSkipsSecrets), history: history, seen: SharedClipboardSeenStore())
        switch outcome {
        case .saved: pasteNote = "Image saved."
        case .alreadySaved: pasteNote = "This image is already here."
        case .skipped(let reason): pasteNote = ClipboardCopyText.notKept(reason)
        case .changedSinceLook: pasteNote = "The clipboard changed. Tap Paste again."
        default: pasteNote = "Image could not be saved. Check available storage."
        }
        Task { await load() }
    }

    private func savePasted(_ text: String, types: [String], token: ClipboardPasteToken) {
        switch ClipboardWatcher.shared.keepPasted(text, types: types, token: token, settings: settings) {
        case .saved: pasteNote = "Saved."
        case .alreadySaved: pasteNote = "Already here."
        case .skipped(let reason): pasteNote = ClipboardCopyText.notKept(reason)
        case .changedSinceLook: pasteNote = "The clipboard changed during the paste. Try again."
        default: pasteNote = "Zone could not save this copy. Unlock your iPhone and tap Paste again."
        }
        Haptics.tap()
        Task { await load() }
    }
}

private struct ClipboardImageShare: Transferable {
    let url: URL
    let type: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .image) { image in
            SentTransferredFile(image.url)
        }
        .suggestedFileName { image in "Image." + (UTType(image.type)?.preferredFilenameExtension ?? "jpg") }
    }
}

extension View {
    /// The list owns this alert so closing the swipe action cannot dismiss it with the row.
    func confirmClipboardDeletion(_ selection: Binding<ClipboardEntry?>, delete: @escaping (ClipboardEntry) -> Void) -> some View {
        let presented = Binding(get: { selection.wrappedValue != nil }, set: { if !$0 { selection.wrappedValue = nil } })
        return alert("Delete this copy?", isPresented: presented, presenting: selection.wrappedValue) { entry in
            Button("Delete copy", role: .destructive) { delete(entry) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This can't be undone.")
        }
    }
}

/// One kept copy in a list: the library's row, with what kind of copy it is on the quiet line.
struct ClipRow: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(LinkCoordinator.self) private var link: LinkCoordinator?
    @Environment(\.openURL) private var openURL
    @State private var notice: String?
    let entry: ClipboardEntry
    var marks: [Range<Int>] = []
    var lineLimit = 2
    let onOpen: () -> Void
    let onDelete: () -> Void
    let onSwipeDelete: () -> Void
    let onPin: () -> Void

    var body: some View {
        // Without a search the row shows the copy's own words: a passage that opens with a web
        // address must not read as a link (`ClipboardPreview`). A search shows where it matched.
        let found: (text: String, marks: [Range<Int>]) = marks.isEmpty
            ? (text: ClipboardPreview(entry.text).text, marks: [])
            : LibrarySearch.excerpt(entry.text, marks: marks)
        if entry.imageType != nil {
            HStack {
                Button(action: onOpen) {
                    HStack {
                        SavedClipboardImage(url: ClipboardHistory.shared?.imageURL(entry.id, thumbnail: true)).frame(width: 64, height: 48)
                        VStack(alignment: .leading) {
                            Text("Image").foregroundStyle(.primary)
                            Text(Self.detail(entry)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.accessibilityIdentifier("clipboard.image")
                Spacer()
                Button("Copy", action: copyImage)
            }.buttonStyle(.borderless)
                .modifier(RowMenu(text: "", actions: [
                    .init(title: "Copy", symbol: "doc.on.doc", action: copyImage),
                    .init(title: "Share", symbol: "square.and.arrow.up") {
                        if let url = ClipboardHistory.shared?.imageURL(entry.id) {
                            shareImage = UIImage(contentsOfFile: url.path)
                            sharing = shareImage != nil
                        }
                    },
                    pinAction
                ], delete: onSwipeDelete))
                .background { ShareSheet(isPresented: $sharing, items: shareImage.map { [$0] } ?? []) { _, _ in shareImage = nil } }
        } else {
            LibraryRow(kind: .clip, text: found.text, whole: entry.text, marks: found.marks,
                       detail: Self.detail(entry), lineLimit: lineLimit, onOpen: onOpen, onDelete: onDelete,
                       extraActions: actions, swipeDelete: onSwipeDelete)
                .alert("Clipboard", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: { Text(notice ?? "") }

        }
    }

    @State private var sharing = false
    @State private var shareImage: UIImage?
    private func copyImage() { _ = ClipboardHistory.shared?.copyImage(entry) }

    private var pinAction: LibraryRow.Action {
        .init(title: entry.pinned ? "Unpin" : "Pin", symbol: entry.pinned ? "pin.slash" : "pin", action: onPin)
    }

    private var actions: [LibraryRow.Action] {
        var actions = [pinAction]
        if let url = entry.link {
            actions.append(.init(title: "Open link", symbol: "link") { openURL(url) })
        }
        actions.append(.init(title: link?.isPaired == true ? "Add to Notes and sync" : "Add to Notes", symbol: "note.text") {
            notice = coordinator.notes.add(entry.text) == nil ? "Zone could not add that note." : "Added to Notes."
        })
        if let link, link.isPaired {
            actions.append(.init(title: "Send to computer", symbol: "desktopcomputer") {
                do {
                    let clip = try link.sendClip(entry.text, source: .clipboard)
                    Task {
                        let settled = await link.clipSettled(clip.id, within: 30)
                        notice = settled.map { LinkClipCopy.outcome($0, names: link.computerNames) } ?? LinkClipCopy.removed
                    }
                } catch { notice = (error as? LinkClipFailure)?.plainMessage ?? "Zone could not send that." }
            })
        }
        return actions
    }

    /// "9:41 AM · Link · Kept", "9:41 AM · Link and 503 words"
    static func detail(_ entry: ClipboardEntry, now: Date = Date()) -> String {
        let kind = entry.imageType == nil ? ClipboardPreview(entry.text).detail : nil
        return [LibraryRow.when(entry.savedAt, now: now), kind, entry.pinned ? "Kept" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// One copy in full, and what can be done with it.
struct ClipSheet: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(LinkCoordinator.self) private var link: LinkCoordinator?
    let entry: ClipboardEntry
    let onDelete: () -> Void
    let onPin: (Bool) -> Void
    @State private var copied = false
    @State private var pinned = false
    @State private var note: String?
    /// The clip whose answer the note line is waiting for; a newer send owns the line.
    @State private var sendingClip: UUID?
    @State private var confirmingDelete = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if entry.imageType != nil {
                        SavedClipboardImage(url: ClipboardHistory.shared?.imageURL(entry.id))
                    } else {
                        Text(entry.text).font(.body).foregroundStyle(Zone.ink(scheme)).textSelection(.enabled)
                        .accessibilityIdentifier("clip.text")
                    }
                    Text("Saved \(entry.savedAt.formatted(date: .abbreviated, time: .shortened)) · \(Self.via(entry.route))")
                        .font(.footnote).foregroundStyle(Zone.muted(scheme))
                    if let note {
                        Text(note).font(.footnote).foregroundStyle(Zone.muted(scheme))
                            .accessibilityIdentifier("clip.note")
                    }

                }
                .padding(24)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    Hairline()
                    if entry.imageType != nil {
                        Button(copied ? "Copied" : "Copy image") {
                            copied = ClipboardHistory.shared?.copyImage(entry) == true
                            if copied { Haptics.success() }
                            if !copied { note = "This image is no longer available." }
                        }.buttonStyle(ZoneQuietButtonStyle())
                        Button(pinned ? "Stop keeping" : "Keep until I delete it") {
                            pinned.toggle()
                            onPin(pinned)
                            Haptics.tap()
                        }
                        if let type = entry.imageType, let url = ClipboardHistory.shared?.imageURL(entry.id) {
                            ShareLink(item: ClipboardImageShare(url: url, type: type), preview: SharePreview("Saved image"))
                        }
                        Button("Delete image", role: .destructive) { confirmingDelete = true }
                            .buttonStyle(ZoneQuietButtonStyle())
                    } else {
                        SavedTextActions(text: entry.text, copied: copied, prefix: "clip", copy: {
                            Clipboard.copy(entry.text)
                            Haptics.success()
                            copied = true
                        }, delete: { confirmingDelete = true }) {
                            Menu {
                                if let url = entry.link {
                                    Button("Open link") { openURL(url) }
                                }
                                Button(pinned ? "Stop keeping" : "Keep until I delete it") {
                                    pinned.toggle()
                                    onPin(pinned)
                                    Haptics.tap()
                                }
                                .accessibilityIdentifier("clip.keep")
                                Button(link?.isPaired == true ? "Add to Notes and sync" : "Add to Notes") {
                                    note = coordinator.notes.add(entry.text) == nil ? "Zone could not create a note. The original copy is still in Clipboard." : "Added to Notes."
                                    Haptics.success()
                                }
                                if let link, link.isPaired {
                                    Button("Send to computer") { send(link) }
                                }
                            } label: {
                                PageActionLabel(title: "More", symbol: "ellipsis")
                            }
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("clip.more")
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .background(Zone.paper(scheme))
            }
            .confirmationDialog("Delete this copy?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete copy", role: .destructive, action: onDelete)
            } message: {
                Text("This can't be undone.")
            }
            .navigationTitle("Copy")
            .zoneBackButton()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ZoneBarItem(.confirmationAction, prominent: true) { Button("Done") { dismiss() } }
            }
            .zoneScreen()
        }
        .presentationDetents([.medium, .large])
        .onAppear { pinned = entry.pinned }
    }

    /// How long the note waits for the computers before saying the copy is queued. The
    /// connection gives up on an unreachable computer after 20 seconds (as `ClipSendSheet`).
    private static let settleSeconds: TimeInterval = 30

    /// The one way a copy leaves the phone: the person sends this one, to the computers they
    /// paired. "Sending" once it is saved in the outbox; then, per computer, sent (it
    /// acknowledged) or still waiting. Never "Sent" before a computer has answered.
    private func send(_ link: LinkCoordinator) {
        do {
            let clip = try link.sendClip(entry.text, source: .clipboard)
            note = LinkClipCopy.sending
            sendingClip = clip.id
            Task {
                let settled = await link.clipSettled(clip.id, within: Self.settleSeconds)
                guard sendingClip == clip.id else { return }
                sendingClip = nil
                note = settled.map { LinkClipCopy.outcome($0, names: link.computerNames) } ?? LinkClipCopy.removed
                if settled?.isSent == true { Haptics.success() }
            }
        } catch let failure as LinkClipFailure {
            note = failure.plainMessage
        } catch {
            note = "Zone could not queue this copy for your computer. Try Send again."
        }
    }

    static func via(_ route: ClipboardRoute) -> String {
        switch route {
        case .pasteKey: return "pasted with Zone"
        case .shortcut: return "from a shortcut"
        case .saved: return "saved here"
        default: return "kept by Zone"
        }
    }
}
