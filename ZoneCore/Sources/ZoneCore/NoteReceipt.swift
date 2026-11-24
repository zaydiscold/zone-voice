// by zayd/cold @ zayd.wtf

import Foundation

/// When a finished recording's recovery receipt (its text in `AudioRecoveryStore`) may go, and
/// what History calls a note that the notes file did not take.
///
/// A dictation is safe once History holds it. A note is not: History keeps it as a `.note`
/// record, which Home's recent list and Library search leave out because the note itself is
/// shown from the notes file. Before this rule a note's receipt went as soon as History saved,
/// before the notes file was written, so a
/// failed write or iOS ending Zone in between left a note that was in neither Notes nor a
/// recovery card. Recording from a locked phone is when Zone is likeliest to be ended there.
public enum NoteReceipt {
    /// - Parameters:
    ///   - historyDurable: History saved the recording's final record.
    ///   - isNote: the recording was a voice note.
    ///   - noteWritten: the notes file holds the note. Pass false until the write has succeeded.
    public static func mayRelease(historyDurable: Bool, isNote: Bool, noteWritten: Bool) -> Bool {
        isNote ? noteWritten : historyDurable
    }

    /// History's status for a finished recording. A note the notes file refused is recorded as
    /// cut off, which History, Home and search all show, instead of a `.note` that they hide.
    public static func historyStatus(isNote: Bool, noteWriteFailed: Bool) -> TranscriptStatus {
        guard isNote else { return .finished }
        return noteWriteFailed ? .cutOff : .note
    }
}
