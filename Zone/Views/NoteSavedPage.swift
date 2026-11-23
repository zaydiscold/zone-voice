// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// After a note is saved: the words, and what to do with them, without leaving for Notes.
/// Edit is in place (tap the words), Copy, Share and Delete sit in one row, Cleanup is a quiet
/// link, "Added to Notes" takes you to the note on Home, and Done and the next note's mic sit
/// at the bottom under the thumb. Another Action Button press closes the page by itself (the
/// coordinator drops it when the next note starts), saving an edit in progress first.
struct NoteSavedPage: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(LinkCoordinator.self) private var link: LinkCoordinator?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let page: NotePage

    @State private var editing = false
    @State private var draft = ""
    @State private var confirmingDelete = false
    @State private var cleaning = false
    @State private var copied = false
    @State private var drag: CGFloat = 0
    /// Flips just after the page lands: the check pops in and the Notes count ticks up.
    @State private var arrived = false
    @FocusState private var editorFocused: Bool

    private var note: Note? { coordinator.notes.notes.first { $0.id == page.noteID } }
    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var changed: Bool { trimmedDraft != (note?.text ?? "") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            dragArea
            if let note {
                words(note).padding(.top, 18).layoutPriority(1)
                if editing {
                    editBar.padding(.top, 12)
                } else {
                    actions(note).padding(.top, 14)
                    cleanupLink.padding(.top, 4)
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
        .confirmationDialog("Delete this note?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete note", role: .destructive) {
                Haptics.tap()
                coordinator.deleteNote(page.noteID)
            }
        } message: {
            Text(["The note is removed from Zone.",
                  LinkCopy.deleteNote(link?.computers.map(\.name) ?? [], keeping: link?.computers.keepingNames ?? [])]
                .compactMap { $0 }.joined(separator: " "))
        }
        .sheet(isPresented: $cleaning) { CleanupSheet(text: note?.text ?? "") }
        .onAppear {
            Haptics.success()
            UIAccessibility.post(notification: .screenChanged, argument: nil)
            withAnimation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.62).delay(0.18)) { arrived = true }
        }
        // The next note, a delete elsewhere or a keyboard request can take the page away while
        // an edit is open: the words typed so far are kept, never thrown away.
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
                    Circle().fill(Zone.accentGraphic(scheme))
                    Image(systemName: "checkmark")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Zone.onAccent)
                }
                .frame(width: 36, height: 36)
                .scaleEffect(arrived ? 1 : 0.3)
                .opacity(arrived ? 1 : 0)
                .accessibilityHidden(true)
                DisplayText("Note saved", size: 34)
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

    private var subtitle: String {
        let time = (note?.createdAt ?? page.savedAt).formatted(date: .omitted, time: .shortened)
        var parts = ["Saved at \(time)"]
        if page.audioSeconds >= 1 { parts.append("\(page.audioSeconds.countdownLabel) of speech") }
        if note?.editedAt != nil { parts.append("edited") }
        return parts.joined(separator: " · ")
    }

    // MARK: The words, read or edited in place

    @ViewBuilder
    private func words(_ note: Note) -> some View {
        if editing {
            TextEditor(text: $draft)
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
            .onTapGesture { beginEditing(note) }
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("notePage.text")
            .accessibilityHint("Edits the note")
    }

    private var editBar: some View {
        HStack(spacing: 12) {
            Button("Cancel") { cancelEditing() }
                .buttonStyle(ZoneQuietButtonStyle())
                .accessibilityIdentifier("notePage.cancelEdit")
            Spacer(minLength: 8)
            if trimmedDraft.isEmpty {
                Text("Empty. Use Delete to remove the note.")
                    .font(.footnote).foregroundStyle(Zone.muted(scheme))
                    .multilineTextAlignment(.trailing)
            }
            Button("Save") { saveEdit() }
                .buttonStyle(SaveCapsuleStyle())
                .disabled(!changed || trimmedDraft.isEmpty)
                .accessibilityIdentifier("notePage.saveEdit")
        }
    }

    // MARK: Actions

    private func actions(_ note: Note) -> some View {
        HStack(alignment: .top, spacing: 0) {
            PageAction(title: "Edit", symbol: "pencil", identifier: "notePage.edit") { beginEditing(note) }
            PageAction(title: copied ? "Copied" : "Copy", symbol: copied ? "checkmark" : "doc.on.doc",
                       identifier: "notePage.copy") { copy(note) }
            ShareLink(item: note.text) {
                PageActionLabel(title: "Share", symbol: "square.and.arrow.up")
            }
            .buttonStyle(ScaleButtonStyle())
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("notePage.share")
            PageAction(title: "Delete", symbol: "trash", tone: Zone.live, identifier: "notePage.delete") {
                confirmingDelete = true
            }
        }
    }

    /// Cleanup, kept small: most notes never need it.
    private var cleanupLink: some View {
        Button { cleaning = true } label: {
            Label("Clean up", systemImage: "wand.and.stars")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Zone.muted(scheme))
                .frame(minHeight: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("notePage.cleanup")
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
                    .foregroundStyle(Zone.accentText(scheme))
                    .frame(width: 42, height: 42)
                    .background(Zone.accentGraphic(scheme).opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Zone.accentText(scheme))
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Zone.accentText(scheme))
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
            Button { coordinator.beginNoteDictation() } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Zone.onAccent)
                    .frame(width: 52, height: 52)
                    .background(Zone.accent, in: Circle())
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(coordinator.activity.isBusy)
            .accessibilityLabel("New note")
            .accessibilityIdentifier("notePage.newNote")
        }
    }

    // MARK: Behavior

    private func beginEditing(_ note: Note) {
        draft = note.text
        withAnimation(Zone.motion) { editing = true }
        Task { @MainActor in editorFocused = true }
    }

    private func cancelEditing() {
        editorFocused = false
        withAnimation(Zone.motion) { editing = false }
        draft = ""
    }

    private func saveEdit() {
        guard changed, !trimmedDraft.isEmpty else { return }
        coordinator.updateNote(page.noteID, text: draft)
        Haptics.success()
        editorFocused = false
        withAnimation(Zone.motion) { editing = false }
        draft = ""
    }

    /// The page is going while an edit is open: keep what was typed.
    private func keepDraft() {
        guard editing, changed, !trimmedDraft.isEmpty else { return }
        coordinator.updateNote(page.noteID, text: draft)
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

/// One of the page's four actions: an icon on a tile, its name under it.
private struct PageAction: View {
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

private struct PageActionLabel: View {
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
                .background(Zone.card(scheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Zone.rule(scheme), lineWidth: 1))
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

/// Save beside Cancel while editing: an ink capsule the size of its neighbour.
private struct SaveCapsuleStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Zone.onInk(scheme))
            .padding(.horizontal, 22)
            .frame(minHeight: 44)
            .background(Zone.ink(scheme).opacity(isEnabled ? 1 : 0.35), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Zone.motion, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}
