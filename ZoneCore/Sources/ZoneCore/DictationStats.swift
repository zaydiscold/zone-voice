// by zayd/cold @ zayd.wtf

import Foundation

/// The numbers Home and the share card brag with, worked out in one place so both say the same.
public enum DictationStats {
    /// Phone typing averages 36.2 words a minute (Palin et al., MobileHCI 2019, 37,370 people).
    public static let typingWordsPerMinute = 36.2

    /// Words per recorded minute, including pauses. A pool shorter than ten seconds is too noisy.
    public static func wordsPerMinute(words: Int, recordingSeconds: Double) -> Int {
        guard recordingSeconds.isFinite, recordingSeconds >= 10, words > 0 else { return 0 }
        return Int((Double(words) / recordingSeconds * 60).rounded())
    }

    /// Time saved: what typing those words would have taken, less the whole recording, pauses
    /// included, because that is what the dictation cost.
    public static func minutesSaved(words: Int, secondsSpoken: Double) -> Int {
        let typing = Double(max(words, 0)) / typingWordsPerMinute
        let spoken = max(secondsSpoken, 0) / 60
        return max(Int((typing - spoken).rounded()), 0)
    }

    /// "45 min" under an hour, "2h 5m" under a day, "3d 4h" after that. Each step drops the
    /// unit too small to matter at that scale, and a zero remainder ("2h", "3d").
    public static func timeLabel(minutes: Int) -> String {
        let minutes = max(minutes, 0)
        if minutes < 60 { return "\(minutes) min" }
        if minutes < 1_440 {
            let hours = minutes / 60, rest = minutes % 60
            return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
        }
        let days = minutes / 1_440, hours = (minutes % 1_440) / 60
        return hours == 0 ? "\(days)d" : "\(days)d \(hours)h"
    }

    /// The Home line for people Zone has been passed to. It only counts up.
    public static func helpedLine(people: Int) -> String {
        people == 1 ? "Shared Zone with 1 person" : "Shared Zone with \(people) people"
    }

    /// The record afterwards: the finished dictation takes it only when it has words, a real
    /// length, and is strictly longer, so a tie keeps the date it was first set.
    public static func longest(_ current: LongestDictation?, after seconds: Double, words: Int,
                               at date: Date) -> LongestDictation? {
        guard words > 0, seconds.isFinite, seconds > 0 else { return current }
        if let current, words < current.words || (words == current.words && date >= current.date) { return current }
        return LongestDictation(seconds: seconds, words: words, date: date)
    }

    /// The longest finished dictation in saved history, for the one-time backfill. Records still
    /// recording or paused are in flight, not finished, and their length is not final. A tie
    /// goes to the earlier dictation, as it would have live, whatever order the list is in.
    public static func longest(in records: [TranscriptRecord]) -> LongestDictation? {
        var best: LongestDictation?
        for record in records where record.status != .recording && record.status != .paused {
            best = longest(best, after: record.audioSeconds, words: record.wordCount, at: record.createdAt)
        }
        return best
    }

    /// The day a record was set: "Nov 3" in the current year, "Nov 3, 2025" in any other, so an
    /// old record never reads as this year's.
    public static func dayLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                                locale: Locale = .current) -> String {
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .month(.abbreviated).day()
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) { style = style.year() }
        return date.formatted(style)
    }

    /// "8:57" under an hour, "1:02:07" from an hour up, like a clock or a voice memo. Whole
    /// seconds, rounded down, so the label never claims a second that was not spoken.
    public static func durationLabel(seconds: Double) -> String {
        // The cap only keeps a corrupt value from trapping the Int conversion.
        let total = seconds.isFinite ? Int(min(max(seconds, 0), 1e12).rounded(.down)) : 0
        let hours = total / 3_600, minutes = (total % 3_600) / 60, rest = total % 60
        func two(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
        return hours > 0 ? "\(hours):\(two(minutes)):\(two(rest))" : "\(minutes):\(two(rest))"
    }
}

/// The longest single dictation: ranked by word count.
public struct LongestDictation: Codable, Equatable, Sendable {
    /// The whole recording, pauses included, as `TranscriptRecord.audioSeconds` counts it.
    public let seconds: Double
    public let words: Int
    public let date: Date

    public var isDisplayable: Bool { words >= 50 || seconds >= 60 }

    public init(seconds: Double, words: Int, date: Date) {
        self.seconds = seconds
        self.words = words
        self.date = date
    }
}

/// The share card's waveform: a small additive synth. Three partials whose pitch and phase come
/// from the word count, so each total has its own shape, plus a per-render variation so two
/// cards with the same count are siblings, not copies. Heights are 0...1, one per bar.
public enum ShareWave {
    public static func bars(count: Int, words: Int, variation: UInt64) -> [Double] {
        guard count > 0 else { return [] }
        var rng = SplitMix(seed: UInt64(truncatingIfNeeded: words) &* 0x9E37_79B9_7F4A_7C15)
        // The word count fixes the voice: partial pitches and where each starts.
        let pitches = (0..<3).map { index in 1.5 + Double(index) * 2.2 + rng.unit() * 2.5 }
        let phases = (0..<3).map { _ in rng.unit() * 2 * .pi }
        // The variation nudges the phases and the grain a little, never the overall shape.
        var jitter = SplitMix(seed: variation ^ 0xD1B5_4A32_D192_ED03)
        let drift = (0..<3).map { _ in (jitter.unit() - 0.5) * 0.9 }
        return (0..<count).map { index in
            let t = count == 1 ? 0.5 : Double(index) / Double(count - 1)
            var sum = 0.0
            for partial in 0..<3 {
                sum += sin(2 * .pi * pitches[partial] * t + phases[partial] + drift[partial]) / Double(partial + 1)
            }
            // Fade in and out like a spoken phrase, then fold the synth into 0...1.
            let envelope = 0.35 + 0.65 * sin(.pi * t)
            let tone = (sum / 1.83 + 1) / 2
            let grain = 0.82 + 0.18 * jitter.unit()
            return min(max(envelope * (0.25 + 0.75 * tone) * grain, 0.08), 1)
        }
    }

    /// SplitMix64: tiny, fast and stable across platforms and releases, unlike the system RNG.
    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }
}
