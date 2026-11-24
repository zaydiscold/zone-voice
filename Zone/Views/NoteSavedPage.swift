// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// After a note is saved: the words, and what to do with them, without leaving for Notes.
/// Edit is in place (tap the words), Copy, Share and Delete sit in one row, "Added to Notes" takes you to the note on Home, and Done and the next note's mic sit
/// at the bottom under the thumb. Another Action Button press closes the page by itself (the
/// coordinator drops it when the next note starts), saving an edit in progress first.
/// Notes saved in a row away from Zone all come on the one page: it says how many, steps
/// between them and copies them together.
struct NoteSavedPage: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(LinkCoordinator.self) private var link: LinkCoordinator?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let page: NotePage

    @State private var editing = false
    @State private var draft = NoteEditDraft()
    @State private var deleteFailed = false
    @State private var confirmingDelete = false
    @State private var copied = false
    @State private var drag: CGFloat = 0
    /// Flips just after the page lands: the check pops in and the Notes count ticks up.
    @State private var arrived = false
    @FocusState private var editorFocused: Bool
    /// Which of the page's notes is showing; nil is the newest. Only matters when several
    /// notes were saved in a row away from Zone.
    @State private var shownID: UUID?
    @State private var copiedAll = false

    /// The note showing: the one stepped to, or the newest.
    private var current: NotePage.Entry {
        page.entries.first { $0.noteID == shownID } ?? NotePage.Entry(noteID: page.noteID, audioSeconds: page.audioSeconds)
    }
    private var position: Int { page.entries.firstIndex { $0.noteID == current.noteID } ?? page.entries.count - 1 }
    private var note: Note? { coordinator.notes.notes.first { $0.id == current.noteID } }
    private var changed: Bool { draft.changed(from: note) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            dragArea
            if let message = coordinator.recordingCardStopMessage {
                Text(message).font(.subheadline).foregroundStyle(Zone.ink(scheme)).padding(.top, 8)
                    .accessibilityIdentifier("notePage.recordingStopped")
            }
            if page.entries.count > 1, !editing { pager.padding(.top, 12) }
            if let note {
                words(note).padding(.top, page.entries.count > 1 && !editing ? 10 : 18).layoutPriority(1)
                if editing {
                    editBar.padding(.top, 12)
                } else {
                    actions(note).padding(.top, 14)
                }
            }
            if !editing { Spacer(minLength: 16) }
            if !editing, let note {
                notesLink(note)
                bottomBar.padding(.top, 14)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
        .zoneScreen()
        .offset(y: drag)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { coordinator.closeNotePage(reason: "escape") }
        .accessibilityIdentifier("notePage")
        .alert("Your note could not be deleted", isPresented: $deleteFailed) {
            Button("Try again") { confirmingDelete = true }
            Button("Keep note", role: .cancel) {}
        }
        .confirmationDialog("Delete this note?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete note", role: .destructive) {
                Haptics.tap()
                deleteFailed = !coordinator.deleteNote(current.noteID)
            }
        } message: {
            Text(["The note is removed from Zone.",
                  LinkCopy.deleteNote(link?.computers.map(\.name) ?? [], keeping: link?.computers.keepingNames ?? [])]
                .compactMap { $0 }.joined(separator: " "))
        }
        .onAppear {
            Haptics.success()
            UIAccessibility.post(notification: .screenChanged, argument: nil)
            withAnimation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.62).delay(0.18)) { arrived = true }
        }
        // The next note, a delete elsewhere or a keyboard request can take the page away while
        // an edit is open: the words typed so far are kept, never thrown away.
        .onChange(of: coordinator.failedNoteEdits[current.noteID]) { old, new in
            if old != nil, new == nil, !changed { editing = false }
        }
        .onDisappear { keepDraft() }
        .onChange(of: note == nil) { _, gone in
            if gone { coordinator.closeNotePage(reason: "noteGone") }
        }
    }

    // MARK: Top: swipe down to close

    /// The handle and the title. Dragging here pulls the page down; far enough closes it.
    private var dragArea: some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule()
                .fill(Zone.rule(scheme))
                .frame(width: 40, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .accessibilityHidden(true)
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle().fill(Zone.controlFill(scheme))
                    Image(systemName: "checkmark")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Zone.controlInk(scheme))
                }
                .frame(width: 36, height: 36)
                .scaleEffect(arrived ? 1 : 0.3)
                .opacity(arrived ? 1 : 0)
                .accessibilityHidden(true)
                DisplayText(title, size: 34)
                    .accessibilityAddTraits(.isHeader)
            }
            Text(subtitle)
                .font(.subheadline).foregroundStyle(Zone.muted(scheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .gesture(dismissDrag, including: editing ? .subviews : .all)
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in drag = max(value.translation.height, 0) }
            .onEnded { value in
                if value.translation.height > 110 || value.predictedEndTranslation.height > 280 {
                    coordinator.closeNotePage(reason: "swipe")
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { drag = 0 }
                }
            }
    }

    private var title: String {
        page.entries.count > 1 ? "\(page.entries.count) notes saved" : "Note saved"
    }

    private var subtitle: String {
        let time = (note?.createdAt ?? page.savedAt).formatted(date: .omitted, time: .shortened)
        var parts = ["Saved at \(time)"]
        if current.audioSeconds >= 1 { parts.append("\(current.audioSeconds.countdownLabel) of speech") }
        if note?.editedAt != nil { parts.append("edited") }
        return parts.joined(separator: " · ")
    }

    // MARK: Several notes: step between them, or take them all

    /// Shown only when more than one note was saved since Zone was last looked at. The arrows
    /// step through them, oldest to newest, and everything below acts on the one showing.
    private var pager: some View {
        HStack(spacing: 4) {
            pagerArrow("chevron.left", label: "Earlier note", identifier: "notePage.earlier", to: position - 1)
            Text("Note \(position + 1) of \(page.entries.count)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(Zone.ink(scheme))
                .contentTransition(.numericText(value: Double(position)))
                .accessibilityIdentifier("notePage.position")
            pagerArrow("chevron.right", label: "Later note", identifier: "notePage.later", to: position + 1)
            Spacer(minLength: 8)
            Button { copyAll() } label: {
                Label(copiedAll ? "Copied" : "Copy all", systemImage: copiedAll ? "checkmark" : "doc.on.doc")
                    .font(.subheadline.weight(.semibold))
                    .zoneAccentLink(scheme)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(ScaleButtonStyle())
            .accessibilityHint("Copies all \(page.entries.count) notes, oldest first")
            .accessibilityIdentifier("notePage.copyAll")
        }
    }

    private func pagerArrow(_ symbol: String, label: String, identifier: String, to index: Int) -> some View {
        let reachable = page.entries.indices.contains(index)
        return Button {
            guard reachable else { return }
            Haptics.tap()
            copied = false
            withAnimation(reduceMotion ? nil : Zone.motion) { shownID = page.entries[index].noteID }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(reachable ? Zone.ink(scheme) : Zone.muted(scheme).opacity(0.45))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(ScaleButtonStyle())
        .disabled(!reachable)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    // MARK: The words, read or edited in place

    @ViewBuilder
    private func words(_ note: Note) -> some View {
        if editing {
            TextEditor(text: $draft.text)
                .font(.body)
                .foregroundStyle(Zone.ink(scheme))
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
                .padding(10)
                .frame(minHeight: 140, maxHeight: .infinity)
                .zoneCard(padding: 0)
                .accessibilityIdentifier("notePage.editor")
        } else {
            // Short notes sit in a card their own size; long ones scroll inside it.
            ViewThatFits(in: .vertical) {
                wordsText(note)
                ScrollView { wordsText(note) }
                    .scrollIndicators(.visible)
            }
            .zoneCard()
            .accessibilityAction(named: "Edit") { beginEditing(note) }
        }
    }

    private func wordsText(_ note: Note) -> some View {
        Text(note.text)
            .font(.body)
            .foregroundStyle(Zone.ink(scheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .textSelection(.enabled)
            .accessibilityIdentifier("notePage.text")
            .accessibilityHint("Choose Edit to change the note.")
    }

    private var editBar: some View {
        HStack(spacing: 12) {
            Button("Cancel") { cancelEditing() }
                .buttonStyle(ZoneQuietButtonStyle())
                .accessibilityIdentifier("notePage.cancelEdit")
            Spacer(minLength: 8)
            if draft.trimmed.isEmpty {
                Text("Empty. Use Delete to remove the note.")
                    .font(.footnote).foregroundStyle(Zone.muted(scheme))
                    .multilineTextAlignment(.trailing)
            }
            Button("Save") { saveEdit() }
                .buttonStyle(ZonePrimaryButtonStyle())
                .frame(maxWidth: 140)
                .disabled(!draft.canSave(over: note))
                .accessibilityIdentifier("notePage.saveEdit")
        }
    }

    // MARK: Actions

    private func actions(_ note: Note) -> some View {
        SavedTextActions(text: note.text, copied: copied, prefix: "notePage",
                         copy: { copy(note) }, delete: { confirmingDelete = true }) {
            PageAction(title: "Edit", symbol: "pencil", identifier: "notePage.edit") { beginEditing(note) }
        }
    }

    // MARK: Added to Notes, Done and the next note

    /// Not a sentence about where the note went: the way there. The count ticks up to include
    /// this note as the page lands.
    private func notesLink(_ note: Note) -> some View {
        let total = coordinator.notes.notes.count
        let shown = arrived ? total : min(page.notesBefore, total)
        return Button { coordinator.revealNoteInLibrary(note.id) } label: {
            HStack(spacing: 14) {
                Image(systemName: "note.text")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Zone.ink(scheme))
                    .frame(width: 42, height: 42)
                    .background(Zone.accentTone(scheme).opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .symbolEffect(.bounce, value: arrived)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Added to Notes")
                        .font(.headline).foregroundStyle(Zone.ink(scheme))
                    Text("\(shown) \(shown == 1 ? "note" : "notes") on Home")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(Zone.muted(scheme))
                        .contentTransition(.numericText(value: Double(shown)))
                }
                Spacer(minLength: 8)
                Text("Show")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Zone.inlineInk(scheme))
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Zone.accentTone(scheme))
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
            .zoneCard(padding: 14)
        }
        .buttonStyle(ScaleButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Added to Notes. \(total) \(total == 1 ? "note" : "notes") on Home")
        .accessibilityHint("Shows this note in Notes on Home")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("notePage.openNotes")
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button("Done") { coordinator.closeNotePage() }
                .buttonStyle(ZonePrimaryButtonStyle())
                .accessibilityIdentifier("notePage.done")
            NewNoteButton {
                Image(systemName: "mic.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Zone.controlInk(scheme))
                    .frame(width: 52, height: 52)
                    .background(Zone.controlFill(scheme), in: Circle())
            }
            .buttonStyle(ScaleButtonStyle())
            .accessibilityLabel("New note")
            .accessibilityIdentifier("notePage.newNote")
        }
    }

    // MARK: Behavior

    private func beginEditing(_ note: Note) {
        draft = NoteEditDraft(opening: note)
        withAnimation(Zone.motion) { editing = true }
        Task { @MainActor in editorFocused = true }
    }

    private func cancelEditing() {
        editorFocused = false
        withAnimation(Zone.motion) { editing = false }
        draft = NoteEditDraft()
    }

    private func saveEdit() {
        guard draft.canSave(over: note) else { return }
        guard coordinator.saveNoteDraft(draft) else { return }
        Haptics.success()
        editorFocused = false
        withAnimation(Zone.motion) { editing = false }
        draft = NoteEditDraft()
    }

    /// The page is going while an edit is open: keep what was typed.
    private func keepDraft() {
        guard editing, changed, !draft.trimmed.isEmpty else { return }
        coordinator.saveNoteDraft(draft)
    }

    /// Every note on the page, oldest first, a blank line between them.
    private func copyAll() {
        let text = page.combinedText(in: coordinator.notes.notes)
        guard !text.isEmpty else { return }
        Clipboard.copy(text)
        Haptics.tap()
        copiedAll = true
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            copiedAll = false
        }
    }

    private func copy(_ note: Note) {
        Clipboard.copy(note.text)
        Haptics.tap()
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            copied = false
        }
    }
}

/// One of the page's four actions: an icon on a tile, its name under it. The note's read page
/// (`NoteReadView`) uses the same four.
struct PageAction: View {
    let title: String
    let symbol: String
    var tone: Color? = nil
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { PageActionLabel(title: title, symbol: symbol, tone: tone) }
            .buttonStyle(ScaleButtonStyle())
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier(identifier)
    }
}

struct PageActionLabel: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    let symbol: String
    var tone: Color? = nil

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(tone ?? Zone.ink(scheme))
                .frame(width: 52, height: 48)
                .background(Zone.card(scheme), in: Zone.cardShape)
                .overlay(Zone.cardShape.strokeBorder(Zone.rule(scheme), lineWidth: 1))
                .contentTransition(.symbolEffect(.replace))
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(tone ?? Zone.ink(scheme))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
    }
}

/// The first tile is specific to the item. The other three stay in the same place.
struct SavedTextActions<First: View>: View {
    let text: String
    let copied: Bool
    let prefix: String
    let copy: () -> Void
    let delete: () -> Void
    @ViewBuilder var first: First

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            first
            PageAction(title: copied ? "Copied" : "Copy", symbol: copied ? "checkmark" : "doc.on.doc",
                       identifier: "\(prefix).copy", action: copy)
            ShareLink(item: text) { PageActionLabel(title: "Share", symbol: "square.and.arrow.up") }
                .buttonStyle(ScaleButtonStyle())
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("\(prefix).share")
            PageAction(title: "Delete", symbol: "trash", tone: Zone.live, identifier: "\(prefix).delete", action: delete)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}
