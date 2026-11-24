// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// One dictation, note, kept copy or found meeting in a list, straight on the paper: its words,
/// a quiet line under them, and Copy beside them. Rows are divided by hairlines, never boxed, so
/// three items read as one list and not three cards.
///
/// - Copy is always one tap and never moves: people copy what they said far more than anything
///   else they do with it.
/// - Tapping the words opens the item to read: the whole dictation, or the note's page. Nothing
///   here opens a keyboard.
/// - A note leads with a few of its own words in bold (`NotePreview`), the way a meeting leads
///   with its name, so a list of long notes has something to tell them apart by.
/// - A search lights the words it found (`marks`), in the lead and in the words under it.
/// - Share and Delete are in the long-press menu, and Delete asks first: a stray tap must never
///   lose words, and on a paired computer the delete goes there too.
struct LibraryRow: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(LinkCoordinator.self) private var link: LinkCoordinator?
    /// Kept copies live on this iPhone.
    enum Kind { case dictation, note, meeting, clip }
    /// One more thing a row can do, in its long-press menu (a kept copy's Keep).
    struct Action {
        let title: String
        let symbol: String
        let action: () -> Void
        var enabled = true
    }

    let kind: Kind
    /// A note's lead: the words to know it by, on a line of their own. Dictations have none.
    var title: String? = nil
    /// The words shown under the title (all of a dictation; the rest of a note, or the part a
    /// search found).
    let text: String
    /// What Copy and Share take when the row shows only part of the item.
    var whole: String? = nil
    /// Words a search found, as UTF-16 offsets into `title` and `text`.
    var titleMarks: [Range<Int>] = []
    var marks: [Range<Int>] = []
    /// The quiet line: when, and any status that needs no attention ("Edited", "Sent to computer").
    let detail: String
    /// A status that needs attention ("Not inserted", "Cut off, saved"), in the alarm color.
    var alert: String? = nil
    var recoveredFrom: Date? = nil
    var lineLimit = 2
    /// Select mode in History: the row picks instead of opening, and Copy steps aside.
    var showsCopy = true
    var copiedDictationID: UUID?
    /// Lit for a moment: Added to Notes on the Note saved page points at this note.
    var highlighted = false
    let onOpen: () -> Void
    /// A missing callback hides Delete.
    let onDelete: (() -> Void)?
    var extraActions: [Action] = []
    var swipeDelete: (() -> Void)? = nil
    @State private var copied = false
    @State private var confirmingDelete = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    private var shown: String { text.isEmpty && title == nil ? "(nothing heard)" : text }
    private var noun: String {
        switch kind {
        case .note: return "note"
        case .dictation: return "dictation"
        case .meeting: return "meeting"
        case .clip: return "copy"
        }
    }
    private var copiedText: String { whole ?? text }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 4) {
                    if let title, !title.isEmpty {
                        Text(Self.marked(title, titleMarks, scheme: scheme))
                            .font(.body.weight(.semibold)).foregroundStyle(Zone.ink(scheme))
                            // A lead is at most 60 characters: two lines, and it is never cut short.
                            .lineLimit(typeSize.isAccessibilitySize ? nil : 3)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !shown.isEmpty {
                        Text(Self.marked(shown, marks, scheme: scheme))
                            .font(title == nil ? .body : .subheadline).foregroundStyle(Zone.ink(scheme))
                            .lineSpacing(title == nil ? 0 : 2)
                            .lineLimit(lineLimit)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    meta
                    if let recoveredFrom { RecoveredFromLabel(date: recoveredFrom) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(kind == .dictation || kind == .clip ? "Opens the full text" : "Opens this \(noun)")
            .accessibilityIdentifier(kind == .note ? "note.row" : (kind == .meeting ? "meeting.row" : "library.row"))
            if showsCopy {
                LibraryCopyButton(noun: Self.copyNoun(kind, noun: noun), copied: copied, action: copy)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 10)
        // A wash of the accent behind the words that fades out, not a box around them: the
        // list stays a list while the eye finds the note.
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Zone.accentTone(scheme).opacity(0.16))
                .padding(.horizontal, -10)
                .opacity(highlighted ? 1 : 0)
                .scaleEffect(highlighted && !reduceMotion ? 1 : 0.98)
                .animation(.timingCurve(0.22, 1, 0.36, 1, duration: highlighted ? 0.35 : 1.1), value: highlighted)
        }
        .contentShape(Rectangle())
        .modifier(RowMenu(text: copiedText, copy: copy,
                          actions: menuActions,
                          delete: onDelete == nil ? nil : { confirmingDelete = true }, swipeDelete: swipeDelete))
        .confirmationDialog("Delete this \(noun)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete \(noun)", role: .destructive) { onDelete?() }
        } message: {
            Text(kind == .clip ? "This can't be undone." : LibraryRow.deleteMessage(link: link))
        }
        .onChange(of: copiedText) { _, _ in copied = false }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private var menuActions: [Action] {
        [Action(title: "Open", symbol: "text.alignleft", action: onOpen)] + extraActions
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
        Clipboard.copy(copiedText)
        if let id = copiedDictationID {
            let words = copiedText.split(whereSeparator: \.isWhitespace).count
            DictationCoordinator.history { $0.confirmKept(id: id, words: words) }
        }
        Haptics.tap()
        copied = true
    }

    /// What the Copy button's label names: "Copy transcript" for a meeting, "Copy saved text" for
    /// a kept copy (never "Copy copy"), and the noun for the rest.
    static func copyNoun(_ kind: Kind, noun: String) -> String {
        switch kind {
        case .meeting: return "transcript"
        case .clip: return "saved text"
        case .dictation, .note: return noun
        }
    }

    /// The words with the ones a search found lit: a wash of the accent behind them and a
    /// heavier weight, so they show in both color schemes and without color at all.
    @MainActor static func marked(_ text: String, _ marks: [Range<Int>], scheme: ColorScheme) -> AttributedString {
        guard !marks.isEmpty else { return AttributedString(text) }
        let units = Array(text.utf16)
        var out = AttributedString()
        var at = 0
        func piece(_ range: Range<Int>) -> String { String(utf16CodeUnits: Array(units[range]), count: range.count) }
        for mark in marks.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let lower = max(mark.lowerBound, at), upper = min(mark.upperBound, units.count)
            guard lower < upper else { continue }
            if at < lower { out += AttributedString(piece(at..<lower)) }
            var lit = AttributedString(piece(lower..<upper))
            lit.backgroundColor = Zone.accentTone(scheme).opacity(scheme == .dark ? 0.34 : 0.26)
            lit.inlinePresentationIntent = .stronglyEmphasized
            out += lit
            at = upper
        }
        if at < units.count { out += AttributedString(piece(at..<units.count)) }
        return out
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

struct LibraryCopyButton: View {
    @Environment(\.colorScheme) private var scheme
    let noun: String
    let copied: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // Muted until it has done its job: a column of accent words down a list is
            // the loudest thing on the page, and the words are what should be read.
            Text(copied ? "Copied" : "Copy")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(copied ? Zone.inlineInk(scheme) : Zone.muted(scheme))
                .underline(copied && scheme == .light, color: Zone.accentStroke(scheme))
                // Top-aligned in its 44 pt target, so the label sits on the first line of
                // the words and the target hangs down beside them, not above the row.
                .frame(minWidth: 44, minHeight: 44, alignment: .top)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "Copied" : "Copy \(noun)")
        .accessibilityIdentifier("library.copy")
    }
}

/// Rows with a hairline between each, none above the first or below the last.
struct RuledList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    var textInset: CGFloat = 0
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { RowRule().padding(.leading, textInset) }
                row(item)
            }
        }
    }
}

/// The same controls power a hold and VoiceOver's Actions rotor.
struct RowMenu: ViewModifier {
    var text: String
    var copy: (() -> Void)? = nil
    var copyTitle = "Copy"
    var share: (() -> Void)? = nil
    var actions: [LibraryRow.Action] = []
    var deleteTitle = "Delete"
    var delete: (() -> Void)?
    var swipeDelete: (() -> Void)? = nil
    @State private var sharing = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .contextMenu { buttons }
            .accessibilityActions { buttons }
            .swipeActions(allowsFullSwipe: false) {
                if let action = swipeDelete ?? delete {
                    Button(deleteTitle, systemImage: "trash", action: action).tint(Zone.live)
                }
            }
            .background { ShareSheet(isPresented: $sharing, items: [text]) { _, _ in } }
    }

    @ViewBuilder private var buttons: some View {
        if !text.isEmpty {
            Button(copyTitle, systemImage: "doc.on.doc") {
                if let copy { copy() } else { Clipboard.copy(text) }
            }
            Button("Share", systemImage: "square.and.arrow.up") {
                if let share { share() } else { sharing = true }
            }
        }
        ForEach(actions, id: \.title) { extra in
            Button(extra.title, systemImage: extra.symbol, action: extra.action)
                .disabled(!extra.enabled)
        }
        if let delete {
            Divider()
            Button(deleteTitle, systemImage: "trash", role: .destructive, action: delete)
        }
    }
}
