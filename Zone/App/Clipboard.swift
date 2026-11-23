// by zayd/cold @ zayd.wtf

import UIKit
import UniformTypeIdentifiers

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
            [[UTType.utf8PlainText.identifier: text]],
            options: [
                .localOnly: true,
                .expirationDate: now.addingTimeInterval(automatic ? automaticLifetime : explicitLifetime),
            ])
    }
}
