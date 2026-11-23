// by zayd/cold @ zayd.wtf

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
}
