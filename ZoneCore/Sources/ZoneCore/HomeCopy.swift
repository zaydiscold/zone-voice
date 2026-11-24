// by zayd/cold @ zayd.wtf

import Foundation

/// Lines on Home that must not contradict what sits beside them (cohesion audit 2026-11-20,
/// finding 6). Kept here, away from the view, so a test can hold them to that.
public enum HomeCopy {
    /// Under "Standby on". The microphone being ready is not the keyboard being ready: until the
    /// Zone keyboard has reported in with Full Access, Home's own setup list still says the
    /// keyboard is missing, so this line may not say "Keyboard ready" above it.
    public static func standby(keyboardReported: Bool, left: String?) -> String {
        let what = keyboardReported ? "Keyboard ready" : "Mic ready"
        return left.map { "\(what) · \($0) left" } ?? what
    }

    /// Under Home's big number, and on the share card. The count takes in voice notes as well as
    /// dictations, and History lists only dictations, so "words dictated" could sit beside "No
    /// dictations yet". Every one of them was spoken.
    public static func wordsLabel(_ words: Int) -> String {
        words == 1 ? "word spoken" : "words spoken"
    }

    /// Both the live stats and the exported card cover dictations from all speech routes.
    public static func stats(wordsPerMinute: Int, minutesSaved: Int) -> [(value: String, label: String)] {
        [(wordsPerMinute > 0 ? String(wordsPerMinute) : "—", "wpm"),
         (DictationStats.timeLabel(minutes: minutesSaved), "est. time saved")]
    }
}
