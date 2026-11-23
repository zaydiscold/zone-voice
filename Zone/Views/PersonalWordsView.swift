// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// My words: one field to add, and every saved word as a key that can be fixed or removed.
/// Changes save as they are made; there is nothing to forget to save.
struct PersonalWordsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var draft = ""
    /// The saved word being fixed in the field, or nil when the field adds a new one.
    @State private var editing: String?
    @State private var removed: [String] = []
    @State private var error: String?
    @FocusState private var fieldFocused: Bool

    private var learned: [String] { settings.personalWords.filter { settings.learnedWords.contains($0.lowercased()) } }
    private var own: [String] { settings.personalWords.filter { !settings.learnedWords.contains($0.lowercased()) } }
    private var entries: [String] { PersonalVocabulary.entries(fromDraft: draft) }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 10) {
                    TextField(editing == nil ? "Add a word or name" : "Fix the spelling", text: $draft, axis: .vertical)
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
                Text("Custom names, brands, and spellings used across typing, swipe, and dictation. Separate multiple words with commas or newlines.")
            }

            if !removed.isEmpty {
                Section {
                    HStack {
                        Text(removed.count == 1 ? "Removed \(removed[0])" : "Removed \(removed.count) words")
                            .foregroundStyle(Zone.muted(scheme))
                            .lineLimit(1)
                        Spacer()
                        Button("Undo") { undoRemoval() }
                            .buttonStyle(ZoneKeyButtonStyle())
                            .accessibilityIdentifier("words.undo")
                    }
                }
            }

            Section {
                if own.isEmpty {
                    Text("No words yet").foregroundStyle(Zone.muted(scheme))
                } else {
                    chips(own)
                }
            } header: {
                Text(own.isEmpty ? "Your words" : "Your words (\(own.count))")
            } footer: {
                if !own.isEmpty { Text("Tap a word to edit, or tap × to remove.") }
            }

            if !learned.isEmpty {
                Section {
                    chips(learned)
                } header: {
                    Text("Learned from corrections (\(learned.count))")
                } footer: {
                    Text("Saved automatically when you corrected a selected word or the end of a dictation.")
                }
            }

            Section {
                Toggle("Learn from corrections", isOn: Binding(
                    get: { settings.learnsFromCorrections },
                    set: { enabled in
                        do { try settings.setLearningFromCorrections(enabled) }
                        catch { self.error = "Couldn't save setting. Try again." }
                    }))
            } footer: {
                Text("Select a misheard word and retype it, or backspace the last word of a dictation and fix it. Zone remembers your spelling for next time.")
            }
        }
        .navigationTitle("My words")
        .zoneBackButton()
        .onAppear { settings.refreshPersonalWords() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { settings.refreshPersonalWords() }
        }
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
                    remove(word)
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
            self.error = "Couldn't save your words. Try again."
            return false
        }
    }
}

/// One saved word, drawn as a keyboard key: tap the word to fix it, the x to remove it.
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
                    .foregroundStyle(Zone.muted(scheme))
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
            .strokeBorder(isEditing ? Zone.accentText(scheme) : Zone.rule(scheme), lineWidth: isEditing ? 1.5 : 1))
    }
}
