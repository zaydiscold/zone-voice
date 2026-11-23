// by zayd/cold @ zayd.wtf

import Foundation

/// "4:32" labels for the app and the keyboard, one formatter for both.
extension TimeInterval {
    /// Elapsed time, whole seconds only: a running clock never shows a second early.
    var clockLabel: String { Self.minutesSeconds(Int(rounded(.down))) }

    /// Time left, rounded to the nearest second.
    var countdownLabel: String { Self.minutesSeconds(Int(rounded())) }

    private static func minutesSeconds(_ seconds: Int) -> String {
        let total = max(seconds, 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
