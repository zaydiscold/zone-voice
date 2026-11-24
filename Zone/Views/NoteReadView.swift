// by zayd/cold @ zayd.wtf

import SwiftUI
import UIKit
import ZoneCore

/// Where a tapped note goes: the note, the words a search found in it, and the list it was
/// tapped in, so the read page can step to the note above or below without going back.
struct NoteRoute: Hashable, Identifiable {
    let id: UUID
    var marks: [Range<Int>] = []
    /// The notes of the list the tap came from, in its order. Empty for a note opened alone.
    var sequence: [NoteStep] = []
    var opensEditor = false

    func within(_ sequence: [NoteStep]) -> NoteRoute { NoteRoute(id: id, marks: marks, sequence: sequence, opensEditor: opensEditor) }
}

/// One note of the list a read page steps through, with the search's marks in it, if any.
struct NoteStep: Hashable {
    let id: UUID
    var marks: [Range<Int>] = []
}

/// One note, to read: all of its words, selectable a word at a time, with no keyboard. Editing
/// is a second, deliberate step (Edit), and then the same words become the editor in place, at
/// the same scroll position. Copy, Share and Delete are under the thumb, the same four tiles as
/// the Note saved page. Opened from a search, the found words are lit and scrolled to.
///
/// Two keys in the bar step to the note above and the note below in the list the page was opened
/// from, so a run of long notes is read without going back for each one.
///
/// The note is looked up by its id every time: what is on screen never decides which note this
/// is, and a note deleted somewhere else closes the page.
struct NoteReadView: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(LinkCoordinator.self) private var link: LinkCoordinator?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    let route: NoteRoute
    /// The note stepped to with the bar's keys; nil is the one the page was opened on.
    @State private var steppedTo: UUID?

    init(_ route: NoteRoute) { self.route = route }
    init(noteID: UUID, marks: [Range<Int>] = []) { self.route = NoteRoute(id: noteID, marks: marks) }

    private var noteID: UUID { steppedTo ?? route.id }
    /// UTF-16 offsets into the note as the search read it.
    private var marks: [Range<Int>] {
        noteID == route.id ? route.marks : (route.sequence.first { $0.id == noteID }?.marks ?? [])
    }
    /// The list's notes that still exist, in its order.
    private var steps: [NoteStep] {
        let saved = Set(coordinator.notes.notes.map(\.id))
        return route.sequence.filter { saved.contains($0.id) }
    }
    private var position: Int? { steps.firstIndex { $0.id == noteID } }

    @State private var editing = false
    @State private var draft = NoteEditDraft()
    @State private var copied = false
    @State private var deleteFailed = false
    @State private var confirmingDelete = false
    /// The words the marks were found in. An edit moves them, so they are shown only while the
    /// note still reads the same.
    @State private var searchedText: String?

    private var note: Note? { coordinator.notes.notes.first { $0.id == noteID } }
    private var changed: Bool { draft.changed(from: note) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let note {
                // At the largest text sizes the keyboard and the header would leave the editor
                // two lines: while editing there, the words get the room.
                if !(editing && typeSize.isAccessibilitySize) {
                    header(note)
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                        .padding(.bottom, 12)
                    Hairline().padding(.horizontal, 20)
                }
                NoteTextView(text: note.text, draft: $draft.text, editing: editing,
                             marks: !editing && searchedText == note.text ? marks : [], scheme: scheme, accent: AccentStore.shared.choice)
                    // A new text view for each note: its own scroll position, and its own found word to show.
                    .id(note.id)
                if editing {
                    editBar
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                } else {
                    Hairline().padding(.horizontal, 20)
                    actions(note)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                }
            }
        }
        .onChange(of: coordinator.failedNoteEdits[noteID]) { old, new in
            if old != nil, new == nil, !changed { editing = false }
        }
        .navigationTitle(position.map { steps.count > 1 ? "\($0 + 1) of \(steps.count)" : "Note" } ?? "Note")
        .zoneBackButton {
            guard editing, changed, !draft.trimmed.isEmpty else { return true }
            return coordinator.saveNoteDraft(draft)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if let position, steps.count > 1, !editing {
                ZoneBarItem(.topBarTrailing) {
                    Button { step(to: position - 1) } label: { Image(systemName: "chevron.up").font(.body.weight(.semibold)) }
                        .disabled(position == 0)
                        .accessibilityLabel("Note above")
                        .accessibilityIdentifier("noteRead.previous")
                    Button { step(to: position + 1) } label: { Image(systemName: "chevron.down").font(.body.weight(.semibold)) }
                        .disabled(position == steps.count - 1)
                        .accessibilityLabel("Note below")
                        .accessibilityIdentifier("noteRead.next")
                }
            }
        }
        .zoneScreen()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("noteRead")
        .alert("Your note could not be deleted", isPresented: $deleteFailed) {
            Button("Try again") { confirmingDelete = true }
            Button("Keep note", role: .cancel) {}
        }
        .confirmationDialog("Delete this note?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete note", role: .destructive) {
                Haptics.tap()
                deleteFailed = !coordinator.deleteNote(noteID)
            }
        } message: {
            Text(LibraryRow.deleteMessage(link: link))
        }
        .onAppear {
            if searchedText == nil, let note {
                searchedText = note.text
                if route.opensEditor { beginEditing(note) }
            }
        }
        // Back, a swipe or the next note's recording can take the page away mid-edit: the words
        // typed so far are kept, as on the Note saved page.
        .onDisappear { keepDraft() }
        .onChange(of: note == nil, initial: true) { _, gone in
            if gone { dismiss() }
        }
    }

    // MARK: When, and how long

    private func header(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(note.createdAt.formatted(date: .complete, time: .shortened))
                .font(.subheadline.weight(.semibold)).foregroundStyle(Zone.ink(scheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("noteRead.date")
            Text(Self.detail(note))
                .font(.footnote.monospacedDigit()).foregroundStyle(Zone.muted(scheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // When and how long are a caption: the note's own words take the largest sizes, and
        // these stop growing before they take the screen from them.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    static func detail(_ note: Note) -> String {
        var parts = [NotePreview(note.text).length]
        if let edited = note.editedAt { parts.append("Edited \(LibraryRow.when(edited))") }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    private func actions(_ note: Note) -> some View {
        SavedTextActions(text: note.text, copied: copied, prefix: "noteRead",
                         copy: { copy(note) }, delete: { confirmingDelete = true }) {
            PageAction(title: "Edit", symbol: "pencil", identifier: "noteRead.edit") { beginEditing(note) }
        }
    }

    private var editBar: some View {
        HStack(spacing: 12) {
            Button("Cancel") { cancelEditing() }
                .buttonStyle(ZoneQuietButtonStyle())
                .accessibilityIdentifier("noteRead.cancelEdit")
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
                .accessibilityIdentifier("noteRead.saveEdit")
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    // MARK: Behavior

    private func step(to index: Int) {
        guard steps.indices.contains(index) else { return }
        Haptics.tap()
        copied = false
        let next = steps[index].id
        steppedTo = next
        searchedText = coordinator.notes.notes.first { $0.id == next }?.text
    }

    private func beginEditing(_ note: Note) {
        draft = NoteEditDraft(opening: note)
        withAnimation(Zone.motion) { editing = true }
    }

    private func cancelEditing() {
        withAnimation(Zone.motion) { editing = false }
        draft = NoteEditDraft()
    }

    private func saveEdit() {
        guard draft.canSave(over: note) else { return }
        // A refused write keeps the editor open with the words in it.
        guard coordinator.saveNoteDraft(draft) else { return }
        Haptics.success()
        withAnimation(Zone.motion) { editing = false }
        draft = NoteEditDraft()
    }

    private func keepDraft() {
        guard editing, changed, !draft.trimmed.isEmpty else { return }
        coordinator.saveNoteDraft(draft)
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

/// The note's words in a text view: read-only and selectable until `editing`, then the editor,
/// in place. A SwiftUI `Text` can only be copied whole; this selects a word or a sentence, and
/// offers Look Up and Translate, like any text on iPhone. It scrolls itself, so a note of any
/// length reads and edits at full speed.
private struct NoteTextView: UIViewRepresentable {
    let text: String
    @Binding var draft: String
    let editing: Bool
    let marks: [Range<Int>]
    let scheme: ColorScheme
    let accent: AccentChoice

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.adjustsFontForContentSizeCategory = true
        view.dataDetectorTypes = [.link]
        // The page's 20 pt margin, less the text container's own 5.
        view.textContainerInset = UIEdgeInsets(top: 16, left: 15, bottom: 28, right: 15)
        view.accessibilityIdentifier = "noteRead.text"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let ink = UIColor(Zone.ink(scheme))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: ink, .paragraphStyle: paragraph,
        ]
        view.tintColor = UIColor(Zone.accentTone(scheme))
        if editing {
            if !coordinator.wasEditing {
                coordinator.wasEditing = true
                let offset = view.contentOffset
                view.isEditable = true
                view.attributedText = NSAttributedString(string: draft, attributes: attributes)
                view.typingAttributes = attributes
                view.setContentOffset(offset, animated: false)
                // The caret goes to the end unless the person had already picked a place.
                view.selectedRange = NSRange(location: (draft as NSString).length, length: 0)
                DispatchQueue.main.async { view.becomeFirstResponder() }
            } else if view.textColor != ink || view.font != attributes[.font] as? UIFont {
                view.textStorage.addAttributes(attributes, range: NSRange(location: 0, length: view.textStorage.length))
                view.typingAttributes = attributes
            }
            return
        }
        if coordinator.wasEditing {
            coordinator.wasEditing = false
            view.resignFirstResponder()
            view.isEditable = false
            // The view still holds what was typed: draw the saved words again, also after Cancel,
            // when they are the same words as before the edit.
            coordinator.shown = nil
        }
        let signature = Signature(text: text, marks: marks, accent: accent, dark: scheme == .dark, size: view.traitCollection.preferredContentSizeCategory)
        guard coordinator.shown != signature else { return }
        coordinator.shown = signature
        let shown = NSMutableAttributedString(string: text, attributes: attributes)
        let length = shown.length
        for mark in marks where mark.lowerBound >= 0 && mark.upperBound <= length && !mark.isEmpty {
            shown.addAttributes([
                .backgroundColor: UIColor(Zone.accentTone(scheme)).withAlphaComponent(scheme == .dark ? 0.38 : 0.3),
                .font: UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold)),
            ], range: NSRange(location: mark.lowerBound, length: mark.count))
        }
        view.attributedText = shown
        // Opened from a search: the first found word comes into view, a few lines from the top.
        if let first = marks.first, !coordinator.scrolledToMark, first.upperBound <= length {
            coordinator.scrolledToMark = true
            DispatchQueue.main.async {
                view.layoutIfNeeded()
                guard let start = view.position(from: view.beginningOfDocument, offset: first.lowerBound) else { return }
                let caret = view.caretRect(for: start)
                let top = max(min(caret.minY - 96, view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom), -view.adjustedContentInset.top)
                view.setContentOffset(CGPoint(x: 0, y: top), animated: false)
            }
        }
    }

    struct Signature: Equatable {
        let text: String
        let marks: [Range<Int>]
        let accent: AccentChoice
        let dark: Bool
        let size: UIContentSizeCategory
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NoteTextView
        var wasEditing = false
        var shown: Signature?
        var scrolledToMark = false

        init(_ parent: NoteTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            guard parent.editing else { return }
            parent.draft = textView.text
        }
    }
}
