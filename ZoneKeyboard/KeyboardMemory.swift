// by zayd/cold @ zayd.wtf

import Foundation
import ZoneCore

/// How close the keyboard runs to its jetsam limit, in the shareable recording log, and what it
/// gives back when iOS warns. A keyboard extension's limit is far below an app's; past it the
/// keyboard goes blank or iOS swaps in its own (JetsamEvent reports, November 12 and 13: 28 to
/// 113 MB). Only numbers are logged, never text.
@MainActor
enum KeyboardMemory {
    /// One line per appearance: the footprint once the host's document is live.
    static func logAppearance() {
        KeyboardLog.journal?.log("keyboardMemory", MemoryFootprint.journalFields())
    }

    /// Drops what is rebuilt on demand, then logs the warning with the footprint before and after.
    /// `emojiPanelOpen` keeps the emoji catalog while the panel reads it.
    static func handleWarning(emojiPanelOpen: Bool) {
        var fields = MemoryFootprint.journalFields()
        KeyGlyphs.purge()
        let droppedEmoji = !emojiPanelOpen && EmojiStore.purge()
        fields["emojiDropped"] = droppedEmoji ? "true" : "false"
        if let after = MemoryFootprint.current() { fields["afterMB"] = MemoryFootprint.megabytes(after) }
        KeyboardLog.journal?.log("keyboardMemoryWarning", fields)
        KeyboardLog.typing.error("memory warning: \(fields["mb"] ?? "?", privacy: .public) MB, after purge \(fields["afterMB"] ?? "?", privacy: .public) MB")
    }
}
