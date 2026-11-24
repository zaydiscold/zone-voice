// by zayd/cold @ zayd.wtf

import SwiftUI
import UniformTypeIdentifiers
import ZoneCore

/// My words: one field to add, and every saved word as a key that can be fixed or removed.
/// Changes save as they are made; there is nothing to forget to save.
struct PersonalWordsView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var draft = ""
    /// The saved word being fixed in the field, or nil when the field adds a new one.
    @State private var editing: String?
    @State private var removed: [String] = []
    @State private var wordToRemove: String?
    @State private var error: String?
    @FocusState private var fieldFocused: Bool

    private var learned: [String] { settings.personalWords.filter { settings.learnedWords.contains($0.lowercased()) } }
    private var own: [String] { settings.personalWords.filter { !settings.learnedWords.contains($0.lowercased()) } }
    private var entries: [String] { PersonalVocabulary.entries(fromDraft: draft) }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Learn from corrections", isOn: Binding(
                    get: { settings.learnsFromCorrections },
                    set: { enabled in
                        do { try settings.setLearningFromCorrections(enabled) }
                        catch { self.error = "Zone could not save the Learn from corrections setting. Try the switch again." }
                    }))
                Toggle("Learn names", isOn: $settings.usesTypedTextAsHints)
            } footer: {
                SettingsNote("Learning", "Names and spelling.", detail: "Learn from corrections saves spellings you fix. Learn names uses nearby text in the field to recognize names locally.")
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
                layout {
                    TextField(editing == nil ? (typeSize.isAccessibilitySize ? "Word or name" : "Add a word or name") : "Fix the spelling", text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($fieldFocused)
                        .submitLabel(.done)
                        .accessibilityIdentifier("words.field")
                        .onChange(of: draft) { _, text in
                            // Return adds. A pasted list keeps its line breaks until Add is tapped.
                            guard text.hasSuffix("\n") else { return }
                            draft = String(text.dropLast())
                            commit()
                        }
                    if editing != nil {
                        Button("Cancel") { editing = nil; draft = "" }
                            .buttonStyle(ZoneKeyButtonStyle())
                    }
                    Button(editing == nil ? "Add" : "Save") { commit() }
                        .buttonStyle(ZoneKeyButtonStyle(prominent: true))
                        .disabled(entries.isEmpty)
                        .accessibilityIdentifier("words.add")
                }
            } footer: {
                SettingsNote("My words", "Add the spellings you use.", detail: "Custom names, brands, and spellings used across typing, swipe, and dictation. Separate multiple words with commas or newlines.")
            }
            .listRowBackground(Zone.card(scheme))

            if !removed.isEmpty {
                Section {
                    HStack {
                        Text(removed.count == 1 ? "Removed \(removed[0])" : "Removed \(removed.count) words")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button("Undo") { undoRemoval() }
                            .buttonStyle(ZoneKeyButtonStyle())
                            .accessibilityIdentifier("words.undo")
                    }
                }
                .listRowBackground(Zone.card(scheme))
            }

            Section {
                if own.isEmpty {
                    Text("No words yet").foregroundStyle(.secondary)
                } else {
                    chips(own)
                }
            } header: {
                Text(own.isEmpty ? "Your words" : "Your words (\(own.count))")
            } footer: {
                if !own.isEmpty { Text("Tap a word to edit, or tap × to remove.") }
            }
            .listRowBackground(Zone.card(scheme))

            if !learned.isEmpty {
                Section {
                    chips(learned)
                } header: {
                    Text("Learned from corrections (\(learned.count))")
                } footer: {
                    SettingsNote("Learned from corrections", "", detail: "Saved when you correct a selected word or the end of a dictation.")
                }
                .listRowBackground(Zone.card(scheme))
            }

            SavedHandlesDisclosure()
                .listRowBackground(Zone.card(scheme))

            Section {
                NavigationLink("Import or export words") { WordListTransferView() }
            }
            .listRowBackground(Zone.card(scheme))
        }
        .scrollContentBackground(.hidden)
        .zoneScreen()
        .navigationTitle("My words")
        .zoneBackButton()
        .onAppear { settings.refreshPersonalWords() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { settings.refreshPersonalWords() }
        }
        .alert("Delete this word?", isPresented: Binding(
            get: { wordToRemove != nil }, set: { if !$0 { wordToRemove = nil } }
        ), presenting: wordToRemove) { word in
            Button("Delete word", role: .destructive) { remove(word) }
            Button("Cancel", role: .cancel) {}
        } message: { Text($0) }
        .alert("My words", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func chips(_ words: [String]) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(words, id: \.self) { word in
                WordChip(word: word, isEditing: editing == word) {
                    editing = word
                    draft = word
                    fieldFocused = true
                } remove: {
                    wordToRemove = word
                }
            }
        }
        .padding(.vertical, 4)
        .animation(Zone.motion, value: words)
    }

    private func commit() {
        let added = entries
        guard !added.isEmpty else { return }
        let current = settings.personalWords
        var next = current
        if let editing, let index = next.firstIndex(of: editing) {
            // A fix replaces the word in place; anything else typed with it is added.
            next.remove(at: index)
            next.insert(contentsOf: added, at: index)
        } else {
            next = added + next
        }
        guard save(next, replacing: current) else { return }
        fieldFocused = false
        editing = nil
        draft = ""
        removed = []
    }

    private func remove(_ word: String) {
        let current = settings.personalWords
        guard save(current.filter { $0 != word }, replacing: current) else { return }
        if editing == word { editing = nil; draft = "" }
        removed.append(word)
    }

    private func undoRemoval() {
        let current = settings.personalWords
        // Brought back as the person's own words: they chose to keep them.
        if save(removed + current, replacing: current) { removed = [] }
    }

    @discardableResult private func save(_ words: [String], replacing original: [String]) -> Bool {
        do {
            try settings.savePersonalWords(words, replacing: original)
            return true
        } catch {
            // The code only: a failed save left no trace before, and no word is logged.
            Journal.log("vocabularySaveFailed", ["error": "\((error as NSError).domain) \((error as NSError).code)"])
            self.error = "Your changes to My words could not be saved. Open My words and try the change again."
            return false
        }
    }
}

/// One saved word, drawn as a keyboard key: tap the word to fix it, the x to remove it.
struct SavedHandleRow: View {
    let handle: String
    let rename: (String) throws -> Void
    let remove: () -> Void
    @State private var editing = false
    @State private var deleting = false
    @State private var spelling = ""
    @State private var error: String?

    var body: some View {
        Text("@" + handle)
            .modifier(RowMenu(text: "@" + handle, actions: [.init(title: "Edit", symbol: "pencil", action: {
                spelling = handle; editing = true
            })], delete: { deleting = true }))
            .alert("Edit handle", isPresented: $editing) {
                TextField("Handle", text: $spelling).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save") {
                    do { try rename(spelling) } catch { self.error = "The handle was not changed. Check the spelling and try again." }
                }.disabled(PersonalVocabulary.normalizedHandles([spelling]).isEmpty)
                Button("Cancel", role: .cancel) {}
            }
            .alert(error ?? "", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("Edit again") { editing = true }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Delete this handle?", isPresented: $deleting) {
                Button("Delete handle", role: .destructive, action: remove)
                Button("Cancel", role: .cancel) {}
            } message: { Text("@" + handle) }
    }
}

private struct WordChip: View {
    @Environment(\.colorScheme) private var scheme
    let word: String
    let isEditing: Bool
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: edit) {
                Text(word)
                    .font(.body)
                    .foregroundStyle(Zone.ink(scheme))
                    .lineLimit(1)
                    .padding(.leading, 12)
                    .padding(.trailing, 4)
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityHint("Fix the spelling")
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Remove \(word)")
        }
        // Borderless, so each button takes its own taps inside a Form row.
        .buttonStyle(.borderless)
        .background {
            RoundedRectangle(cornerRadius: Zone.keyRadius, style: .continuous)
                .fill(Zone.card(scheme))
                .sunShadow(scale: 0.6)
        }
        .overlay(RoundedRectangle(cornerRadius: Zone.keyRadius, style: .continuous)
            .strokeBorder(isEditing ? Zone.accentStroke(scheme) : Zone.rule(scheme), lineWidth: isEditing ? 1.5 : 1))
        .modifier(RowMenu(text: word, actions: [.init(title: "Edit", symbol: "pencil", action: edit)],
                          delete: remove))

    }
}

/// One place for bringing a list in or taking the editable dictionary out.
private struct WordListTransferView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var busy = false
    @State private var opening = false
    @State private var exporting = false
    @State private var csv: WordListFile?
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextEditor(text: $draft)
                    .scrollContentBackground(.hidden)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(minHeight: 120)
                    .accessibilityLabel("Words to import")
                Button("Open from Files") { opening = true }
            } header: { Text("Paste a word list") } footer: {
                SettingsNote("Paste a word list", "Paste words or import a CSV.", detail: "Paste one word per line, or a correction like kwill,QuillBerry. A CSV headed word,heard as uses the opposite order.")
            }
            .listRowBackground(Zone.card(scheme))
            Section {
                Button("Export My words as CSV") {
                    run {
                        csv = WordListFile(text: try await settings.exportWordList())
                        exporting = true
                    }
                }
            } footer: { SettingsNote("Export My words as CSV", "Share your words as a file.", detail: "Shares My words and their heard spellings. Backup and export also keeps handles and keyboard learning.") }
            .listRowBackground(Zone.card(scheme))
        }
        .scrollContentBackground(.hidden)
        .zoneScreen()
        .navigationTitle("Word list")
        .zoneBackButton()
        .toolbar {
            ZoneBarItem(.confirmationAction, prominent: true) {
                Button("Import") {
                    run { try await settings.importWordList(draft); dismiss() }
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .disabled(busy)
        .fileImporter(isPresented: $opening, allowedContentTypes: [.plainText, .commaSeparatedText]) { result in
            run {
                let url = try result.get()
                draft = try await Task.detached(priority: .userInitiated) { try WordListFile.read(url) }.value
            }
        }
        .fileExporter(isPresented: $exporting, document: csv, contentType: .commaSeparatedText, defaultFilename: "Zone words") { result in
            if case .failure(let failure) = result { error = failure.localizedDescription }
        }
        .alert("Word list", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: { Text(error ?? "") }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await action() }
            catch { if (error as NSError).code != NSUserCancelledError { self.error = error.localizedDescription } }
        }
    }
}

private struct WordListFile: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText]
    static func read(_ url: URL) throws -> String {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: WordListCSV.byteLimit + 1) ?? Data()
        guard data.count <= WordListCSV.byteLimit else { throw WordListCSV.ImportError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw WordListCSV.ImportError.encoding }
        return text
    }

    let text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else { throw WordListCSV.ImportError.encoding }
        self.text = text
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

private struct SavedHandlesDisclosure: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @State private var draft = ""
    @State private var expanded = false
    @FocusState private var handleFocused: Bool
    @State private var error: String?

    var body: some View {
        Section {
            DisclosureGroup("Saved @handles", isExpanded: $expanded) {
                Text(settings.handleRecognition ? "Tagging on" : "Tagging off")
                    .foregroundStyle(.secondary)
                TextField("Add a handle", text: $draft)
                    .focused($handleFocused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onSubmit(addHandle)
                Button("Add", action: addHandle)
                    .buttonStyle(ZoneKeyButtonStyle(prominent: true))
                    .accessibilityLabel("Add handle")
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                ForEach(settings.handles, id: \.self) { handle in
                    SavedHandleRow(handle: handle, rename: { try settings.renameHandle(handle, to: $0) },
                                   remove: { save { try settings.removeHandles([handle]) } })
                }
            }
        } footer: {
            if expanded {
                SettingsNote("Saved @handles", HandleHelp.example(settings.handleRecognition), detail: HandleHelp.meaning, points: ["Spell a handle with “at sign T X M”.", "Hold a handle to rename or delete it, or swipe left to delete."])
            }
        }
        .onAppear { settings.refreshHandles() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { settings.refreshHandles() }
        }
        .alert("Your handles", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func addHandle() {
        guard let normalized = PersonalVocabulary.normalizedHandles([draft]).first else {
            error = "Use letters, numbers, underscores, or periods, with at least one letter."
            return
        }
        do {
            try settings.addHandle(normalized)
            handleFocused = false
            draft = ""
        } catch {
            self.error = "Zone could not add this handle. Keep the spelling here and tap Add again."
        }
    }

    private func save(_ change: () throws -> Void) {
        do { try change() } catch { self.error = "Zone could not update your saved handles. Reopen the list and try again." }
    }
}
