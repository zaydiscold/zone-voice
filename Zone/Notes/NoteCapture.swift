// by zayd/cold @ zayd.wtf

import Foundation

/// What the note card at the top of Zone shows. One card covers the whole life of a note
/// started in Zone's sight: the press, the recording, the saving, and how it ended when no
/// Note saved page says so. Computed by `DictationCoordinator.noteCard`; nil hides the card.
enum NoteCardPhase: Equatable {
    /// Between the press and the first sample, while the microphone or the speech engine
    /// comes on. `detail` says which.
    case starting(detail: String)
    case recording(startedAt: Date)
    case saving
    /// The note had no words, so nothing was saved.
    case noWords
    /// The note did not save, in one sentence.
    case failed(String)

    /// Which phase, without its contents: what the card animates between.
    var kind: Int {
        switch self {
        case .starting: 0
        case .recording: 1
        case .saving: 2
        case .noWords: 3
        case .failed: 4
        }
    }

    /// Starting, recording or saving: the card is in charge of a note that is still going.
    var isLive: Bool { kind <= 2 }
}

/// How a note ended when no Note saved page says it.
enum NoteOutcome: Equatable {
    case noWords
    case failed(String)
}

/// The Note saved page: the note just saved, and the ones saved before it that nobody has
/// looked at yet.
struct NotePage: Equatable, Identifiable {
    /// A note the page can show, with how long its speech was.
    struct Entry: Equatable {
        let noteID: UUID
        let audioSeconds: Double
    }

    /// The newest note, the one the page opens on.
    let noteID: UUID
    let savedAt: Date
    /// How many notes there were before this one, so the page can count up to the new total.
    let notesBefore: Int
    let audioSeconds: Double
    /// Notes saved earlier that no page was looked at for, oldest first: three presses of the
    /// Action Button away from Zone leave three notes, and the page for the third must not be
    /// the only one that can be read, copied or fixed.
    var earlier: [Entry] = []
    var id: UUID { noteID }

    /// Every note on the page, oldest first; the last is the one just saved.
    var entries: [Entry] { earlier + [Entry(noteID: noteID, audioSeconds: audioSeconds)] }

    /// What Copy all copies: every note still saved, oldest first, a blank line between them.
    func combinedText(in notes: [Note]) -> String {
        entries.compactMap { entry in notes.first { $0.id == entry.noteID }?.text }.joined(separator: "\n\n")
    }

    /// The page without one note, or nil when that was its only one. Losing the newest makes
    /// the one before it the page's note.
    func removing(_ id: UUID) -> NotePage? {
        let kept = entries.filter { $0.noteID != id }
        guard let newest = kept.last else { return nil }
        guard kept.count != entries.count else { return self }
        return NotePage(noteID: newest.noteID, savedAt: savedAt, notesBefore: notesBefore,
                        audioSeconds: newest.audioSeconds, earlier: Array(kept.dropLast()))
    }
}

/// A request to show one note in Notes on Home: the section opens, scrolls into view and
/// lights the note up for a moment.
struct NoteReveal: Equatable {
    let noteID: UUID
    let token = UUID()
}
