// by zayd/cold @ zayd.wtf

import Foundation

/// Where friends get Zone, and the message that goes out with a share. The App Store link has no
/// region in it, so it opens the store of whoever taps it.
public enum ZoneLinks {
    public static let appStore = URL(string: "https://apps.apple.com/app/zone-ai-voice-to-text-dictate/id6830955448")!
    /// The App Store's own review sheet for Zone, for the Rate Zone row in Settings. Only ever
    /// opened by a tap on that row: Zone never prompts for a review itself (Guideline 5.6.1).
    public static let writeReview = URL(string: "https://apps.apple.com/app/id6830955448?action=write-review")!
    /// Zone for the computer (Settings > Computers): the app and the `zone` program, with downloads.
    public static let computerApp = URL(string: "https://github.com/zaydiscold/zone-mcp")!

    /// One line on its own, for link previews and share-sheet titles.
    public static let pitch = "I dictate everything now. Zone is a free voice keyboard for iPhone."

    /// The invitation sent with a milestone card or on its own.
    public static let invite = invite(sendsToComputer: false)

    /// The same message from someone who has paired a computer: their words do leave the phone,
    /// by their own choice, so the message does not claim otherwise.
    public static func invite(sendsToComputer: Bool) -> String {
        """
        \(pitch) \(LinkCopy.inviteClaim(sendsToComputer: sendsToComputer))

        Get it on the App Store: \(appStore.absoluteString)
        """
    }
}
