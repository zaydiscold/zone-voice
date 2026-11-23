// by zayd/cold @ zayd.wtf

import OSLog
import ZoneCore

/// Keyboard-side handshake logs, same subsystem as the app so one predicate shows both.
enum KeyboardLog {
    static let mic = Logger(subsystem: "wtf.zayd.zone", category: "keyboard")
    /// Typing: word list loading, autocorrections, feedback. Debug level so it costs nothing unless streamed.
    static let typing = Logger(subsystem: "wtf.zayd.zone", category: "typing")
    /// The keyboard's side of the recording log (`RecordingJournal`), read with the app's in
    /// Diagnostics. Needs Full Access, like everything in the App Group.
    static let journal = RecordingJournal.shared(process: "keyboard")
}
