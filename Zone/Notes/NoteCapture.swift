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

/// The Note saved page, for one note.
struct NotePage: Equatable, Identifiable {
    let noteID: UUID
    let savedAt: Date
    /// How many notes there were before this one, so the page can count up to the new total.
    let notesBefore: Int
    let audioSeconds: Double
    var id: UUID { noteID }
}

/// A request to show one note in Notes on Home: the section opens, scrolls into view and
/// lights the note up for a moment.
struct NoteReveal: Equatable {
    let noteID: UUID
    let token = UUID()
}
