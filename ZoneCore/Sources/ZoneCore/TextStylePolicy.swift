// by zayd/cold @ zayd.wtf

import Foundation

/// One style, and the last choice wins: a pick from the keyboard's Z stays until the next pick, from
/// the Z or from Settings > Text style. The app folds a keyboard pick into its setting when it comes
/// to the front, so Settings always shows the style the next dictation uses.
///
/// A pick used to lapse back to the app's default after 15 minutes without a dictation (Wispr Flow's
/// model). On 2026-11-19 that turned a message picked as casual in Teams formal ("7 AM", "Hi Riju.")
/// with nothing on screen to say why, so the lapse is gone.
public enum TextStylePolicy {
    /// The style a dictation uses.
    /// - Parameters:
    ///   - defaultStyle: chosen in the app's settings.
    ///   - override: the keyboard's last pick, if any.
    ///   - chosenAt: when the keyboard picked it; nil when the app's setting is newer.
    public static func effective(defaultStyle: TextStyle, override: TextStyle?, chosenAt: Date?) -> TextStyle {
        guard let override, chosenAt != nil else { return defaultStyle }
        return override
    }
}

public extension SharedStore {
    /// The style a dictation uses now: the latest choice from the keyboard or the app.
    func effectiveTextStyle() -> TextStyle {
        TextStylePolicy.effective(defaultStyle: defaultTextStyle, override: textStyle, chosenAt: textStylePickedAt)
    }

    /// A keyboard pick the app has not folded into its setting yet, if any.
    var pendingKeyboardTextStyle: TextStyle? {
        textStylePickedAt == nil ? nil : textStyle
    }

    /// A tap on the Z: the next style after the one in effect.
    @discardableResult
    func chooseNextTextStyle(now: Date = Date()) -> TextStyle {
        let next = effectiveTextStyle().next
        chooseTextStyle(next, now: now)
        return next
    }

    /// A pick from the keyboard's style row. It stays until the next pick.
    func chooseTextStyle(_ style: TextStyle, now: Date = Date()) {
        textStyle = style
        textStylePickedAt = now
    }

    /// A pick in the app's Settings, or the app folding in the keyboard's pick: it replaces any
    /// keyboard pick, so the two never disagree.
    func chooseDefaultTextStyle(_ style: TextStyle) {
        defaultTextStyle = style
        textStylePickedAt = nil
    }
}

/// Zeroes the first samples of a recording so the start chime, which the microphone hears, is never
/// transcribed. Fed from the audio thread only, one buffer at a time.
public final class SampleGate: @unchecked Sendable {
    private var remaining: Int

    /// - Parameter mutedSamples: how many leading samples to replace with silence.
    public init(mutedSamples: Int) {
        remaining = max(mutedSamples, 0)
    }

    public func pass(_ samples: [Float]) -> [Float] {
        guard remaining > 0, !samples.isEmpty else { return samples }
        let count = min(remaining, samples.count)
        remaining -= count
        if count == samples.count {
            return [Float](repeating: 0, count: count)
        }
        var out = samples
        for i in 0..<count { out[i] = 0 }
        return out
    }
}
