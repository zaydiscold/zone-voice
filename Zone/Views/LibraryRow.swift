// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// One dictation or note in a list, straight on the paper: its words, a quiet line under them,
/// and Copy beside them. Rows are divided by hairlines, never boxed, so three items read as one
/// list and not three cards.
///
/// - Copy is always one tap and never moves: people copy what they said far more than anything
///   else they do with it.
/// - Tapping the words opens the item (the whole dictation, or the note's editor).
/// - Share and Delete are in the long-press menu, and Delete asks first: a stray tap must never
///   lose words, and on a paired computer the delete goes there too.
struct LibraryRow: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(LinkCoordinator.self) private var link: LinkCoordinator?
    enum Kind { case dictation, note }

    let kind: Kind
    let text: String
    /// The quiet line: when, and any status that needs no attention ("Edited", "Sent to computer").
    let detail: String
    /// A status that needs attention ("Not inserted", "Cut off, saved"), in the alarm color.
    var alert: String? = nil
    var recoveredFrom: Date? = nil
    var lineLimit = 2
    /// Select mode in History: the row picks instead of opening, and Copy steps aside.
    var showsCopy = true
    /// Lit for a moment: Added to Notes on the Note saved page points at this note.
    var highlighted = false
    let onOpen: () -> Void
    let onDelete: () -> Void
    @State private var copied = false
    @State private var confirmingDelete = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shown: String { text.isEmpty ? "(nothing heard)" : text }
    private var noun: String { kind == .note ? "note" : "dictation" }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(shown)
                        .font(.body).foregroundStyle(Zone.ink(scheme))
                        .lineLimit(lineLimit)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    meta
                    if let recoveredFrom { RecoveredFromLabel(date: recoveredFrom) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(kind == .note ? "Edits this note" : "Opens the full text")
            .accessibilityIdentifier("library.row")
            if showsCopy {
                Button(action: copy) {
                    // Muted until it has done its job: a column of accent words down a list is
                    // the loudest thing on the page, and the words are what should be read.
                    Text(copied ? "Copied" : "Copy")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(copied ? Zone.accentText(scheme) : Zone.muted(scheme))
                        // Top-aligned in its 44 pt target, so the label sits on the first line of
                        // the words and the target hangs down beside them, not above the row.
                        .frame(minWidth: 44, minHeight: 44, alignment: .top)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "Copied" : "Copy \(noun)")
                .accessibilityIdentifier("library.copy")
                .transition(.opacity)
            }
        }
        .padding(.vertical, 10)
        // A wash of the accent behind the words that fades out, not a box around them: the
        // list stays a list while the eye finds the note.
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Zone.accentGraphic(scheme).opacity(0.16))
                .padding(.horizontal, -10)
                .opacity(highlighted ? 1 : 0)
                .scaleEffect(highlighted && !reduceMotion ? 1 : 0.98)
                .animation(.timingCurve(0.22, 1, 0.36, 1, duration: highlighted ? 0.35 : 1.1), value: highlighted)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button(kind == .note ? "Edit" : "Open", systemImage: kind == .note ? "pencil" : "text.alignleft", action: onOpen)
            Button("Copy", systemImage: "doc.on.doc", action: copy)
            ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }
            Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }
        }
        .confirmationDialog("Delete this \(noun)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete \(noun)", role: .destructive, action: onDelete)
        } message: {
            Text(LibraryRow.deleteMessage(link: link))
        }
        .onChange(of: text) { _, _ in copied = false }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private var meta: some View {
        HStack(spacing: 6) {
            Text(detail).foregroundStyle(Zone.muted(scheme))
            if let alert {
                Text("·").foregroundStyle(Zone.muted(scheme))
                Text(alert).fontWeight(.medium).foregroundStyle(Zone.live)
            }
        }
        .font(.caption.monospacedDigit())
        .lineLimit(1)
    }

    private func copy() {
        Clipboard.copy(text)
        Haptics.tap()
        copied = true
    }

    /// What a delete confirmation says: it is final, and what a paired computer does with it.
    @MainActor static func deleteMessage(link: LinkCoordinator?) -> String {
        let names = link?.computers.map(\.name) ?? []
        let keeping = link?.computers.keepingNames ?? []
        return ["This can't be undone.", LinkCopy.deleteNote(names, keeping: keeping)].compactMap { $0 }.joined(separator: " ")
    }

    /// When, as short as it can be said: the time today, "Yesterday" and the time, then the date.
    static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, \(time)"
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// Rows with a hairline between each, none above the first or below the last.
struct RuledList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Hairline() }
                row(item)
            }
        }
    }
}
