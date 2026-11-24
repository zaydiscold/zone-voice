// by zayd/cold @ zayd.wtf

import UIKit
import UniformTypeIdentifiers
import ZoneCore

/// Every copy of dictated or transcribed text. Local only, so Universal Clipboard never sends it
/// to the person's other devices ("Your voice never leaves your iPhone"), and it expires, so it
/// does not sit on the pasteboard for any app to read later (failure map S5).
enum Clipboard {
    /// A copy Zone makes by itself (the Shortcut's "dictate and copy"): pasted right away or not at all.
    static let automaticLifetime: TimeInterval = 5 * 60
    /// A copy the person asked for with a Copy button.
    static let explicitLifetime: TimeInterval = 60 * 60

    static func copy(_ text: String, automatic: Bool = false, now: Date = Date()) {
        UIPasteboard.general.setItems(
            // The second type marks the copy as Zone's own, so clipboard history does not keep
            // a dictation or a note a second time (`ClipboardPolicy.ownType`). It holds nothing.
            [[UTType.utf8PlainText.identifier: text, ClipboardPolicy.ownType: Data()]],
            options: [
                .localOnly: true,
                .expirationDate: now.addingTimeInterval(automatic ? automaticLifetime : explicitLifetime),
            ])
    }
}
