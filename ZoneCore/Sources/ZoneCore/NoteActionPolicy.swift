// by zayd/cold @ zayd.wtf

import Foundation

/// Repeated Action Button presses must never replace speech that is still being processed.
/// A second press while the first is still starting means "stop": it used to do nothing,
/// silently (failure map L7), and the recording then ran until a third press.
public enum NoteActionPolicy {
    public enum State { case idle, starting, recordingNote, recordingDictation, recordingElsewhere, transcribing }
    public enum Action: Equatable { case start, stop, stopWhenStarted, ignore }

    public static func action(for state: State, noteMode: Bool = true, desiredState: Bool? = nil) -> Action {
        if let desiredState {
            switch state {
            case .idle: return desiredState ? .start : .ignore
            case .starting: return desiredState ? .ignore : .stopWhenStarted
            case .recordingNote: return noteMode && !desiredState ? .stop : .ignore
            case .recordingDictation: return !noteMode && !desiredState ? .stop : .ignore
            case .recordingElsewhere, .transcribing: return .ignore
            }
        }
        switch state {
        case .idle: return .start
        case .recordingNote: return noteMode ? .stop : .ignore
        case .recordingDictation: return noteMode ? .ignore : .stop
        case .starting: return .stopWhenStarted
        case .recordingElsewhere, .transcribing: return .ignore
        }
    }

    /// How long after a recording ended by itself an Off press of its control still means
    /// "press" (`offPressStarts`).
    public static let staleControlWindow: TimeInterval = 600

    /// The Voice note and Dictate and copy controls are toggles: iOS sends the opposite of what
    /// the control last showed. A recording that ended some other way than its control's Off
    /// press (Finish when quiet, the time limit, the island's Stop, Zone's own buttons) leaves
    /// the Action Button holding "On" until iOS redraws it, which in the background can take a
    /// while. The next press then arrives as Off with nothing to stop, and used to do nothing
    /// (Zayd's phone, 2026-11-20: a note finished by quiet, the press two seconds later was
    /// dropped). Such a press starts a recording instead.
    ///
    /// Only the first press after that ending, of the same control, within `staleControlWindow`,
    /// and only with nothing recording or starting. Any other Off with nothing to stop stays a
    /// no-op, so a Shortcut that turns the control off never starts a recording.
    /// - Parameter endedByItself: the last recording of a control that ended without that
    ///   control's press, and how long ago, if no press of it has arrived since.
    public static func offPressStarts(state: State, noteMode: Bool,
                                      endedByItself: (noteMode: Bool, secondsAgo: TimeInterval)?) -> Bool {
        guard let endedByItself, endedByItself.noteMode == noteMode,
              endedByItself.secondsAgo >= 0, endedByItself.secondsAgo <= staleControlWindow else { return false }
        switch state {
        case .idle, .transcribing: return true
        case .starting, .recordingNote, .recordingDictation, .recordingElsewhere: return false
        }
    }
}
