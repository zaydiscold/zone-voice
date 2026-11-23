// by zayd/cold @ zayd.wtf

import ActivityKit
import Foundation

struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// `paused`: an interruption (an alarm, a call) holds the recording or the standby.
        enum Phase: String, Codable, Hashable { case ready, recording, processing, paused }
        var phase: Phase
        var noteMode: Bool
        var startedAt: Date
        /// Present only for a long meeting; older activities decode with no meeting title.
        var meetingTitle: String? = nil
        /// Only a recording started by its standalone control may advertise that control's Stop.
        var controlOwned: Bool? = nil
        /// A meeting's own line in place of its title: held for a call, about to stop, or why it
        /// was saved. Older activities decode without it.
        var meetingNote: String? = nil
        /// A meeting held by a call or another app, not paused by the person.
        var meetingHeld: Bool? = nil

        // MARK: Island presentation. All optional so an older payload still decodes.

        /// How the Dynamic Island draws Zone. Settings > Dynamic Island.
        var look: IslandLook? = nil
        /// The person's accent (Settings > Appearance), so the island matches the app.
        var accentHex: UInt32? = nil
        /// The microphone over the last couple of seconds, oldest first, each 0...15
        /// (`IslandLevels.scale`). Sent about once a second while recording.
        var levels: [UInt8]? = nil
        /// The last few recognized words. Shown only in the expanded island and redacted
        /// on a locked phone.
        var tail: String? = nil
        /// Words recognized so far in this recording, or in the last one while ready.
        var words: Int? = nil
        /// Standby: when the microphone session started waiting, and when it ends. Drives the
        /// countdown ring, which iOS animates by itself with no further updates.
        var readySince: Date? = nil
        var readyUntil: Date? = nil
        /// Whether the card draws its buttons (Settings > Dynamic Island > Buttons). Nil, from an
        /// older payload, counts as on.
        var controls: Bool? = nil
        /// The person paused this recording themselves, from the island or the keyboard. Not
        /// `Phase.paused`, which is an interruption holding it. Carries the time recorded so
        /// far, because a timer text cannot stand still.
        var userPausedAt: TimeInterval? = nil
        /// Standby right after a recording finished: the island shows a check for a moment, so
        /// the person sees their words were kept without opening anything. Zone clears it a few
        /// seconds later (`RecordingLiveActivity.doneFor`).
        var justFinished: Bool? = nil
        /// Standby while an interruption (Siri, a call, an alarm, another app's audio) has the
        /// microphone. Zone takes it back by itself when the interruption ends; the card stays
        /// up meanwhile, because iOS would not let Zone make a new one from the background.
        var standbyHeld: Bool? = nil
        /// This standby session, stamped on every update: since it was turned on, and the
        /// dictations and notes it kept, with their words and speaking time. Nil with no session.
        var session: IslandSession? = nil
    }
}

/// A standby session's numbers. The island says them after the fact, never while someone
/// speaks: feedback after a session costs less attention than live feedback (Rego and Montague,
/// JMIR Formative Research 2023), and counting during an activity takes from enjoying it (Etkin,
/// JCR 2016). Plain counts, no targets and no streaks (Silverman and Barasch, JCR 2023).
struct IslandSession: Codable, Hashable {
    /// Phone typing, as `DictationStats.typingWordsPerMinute` (Palin et al., MobileHCI 2019). The
    /// island's extension does not link ZoneCore; a test keeps the two equal.
    static let typingWordsPerMinute = 36.2

    /// When the person (or the keyboard) turned Zone on. An interruption does not restart it.
    var since: Date
    var dictations = 0
    var words = 0
    /// Seconds of audio kept, for the time saved.
    var seconds = 0
    /// Words and seconds spent speaking (`SpeakingTime`), for words per minute. Tenths of a
    /// second, so many short dictations do not round away.
    var timedWords = 0
    var speakingTenths = 0
    /// The last kept dictation's speed, shown with the check after it: "Kept 42 words · 128 wpm."
    var lastWordsPerMinute: Int? = nil

    mutating func add(words: Int, seconds: Double, speakingSeconds: Double? = nil) {
        guard words > 0 else { return }
        dictations += 1
        self.words += words
        self.seconds += Int(seconds.rounded())
        guard let speaking = speakingSeconds, speaking > 0 else { lastWordsPerMinute = nil; return }
        timedWords += words
        speakingTenths += Int((speaking * 10).rounded())
        // One short dictation is a noisy speed, so it needs a few words and 2 s of speech.
        lastWordsPerMinute = words >= 3 && speaking >= 2 ? Self.perMinute(words, speaking) : nil
    }

    /// The session's speaking speed, as `DictationStats.wordsPerMinute`: nil under 10 s of speech.
    var wordsPerMinute: Int? {
        let speaking = Double(speakingTenths) / 10
        return speaking >= 10 ? Self.perMinute(timedWords, speaking) : nil
    }

    private static func perMinute(_ words: Int, _ seconds: Double) -> Int {
        Int((Double(words) / seconds * 60).rounded())
    }

    /// "4 dictations · 312 words", or nil before the first one.
    var tally: String? {
        guard dictations > 0 else { return nil }
        let count = dictations == 1 ? "1 dictation" : "\(dictations.formatted()) dictations"
        let words = self.words == 1 ? "1 word" : "\(self.words.formatted()) words"
        return "\(count) · \(words)"
    }

    /// Typing those words on a phone would have taken this much longer (`DictationStats`, the
    /// same 36.2 words a minute Home uses), or nil under a minute.
    var minutesSaved: Int? {
        let typing = Double(words) / Self.typingWordsPerMinute
        let saved = Int((typing - Double(seconds) / 60).rounded())
        return saved >= 1 ? saved : nil
    }

    /// The expanded island's line: "4 dictations · 312 words since 8:31", or before the first
    /// dictation "On since 8:31. Audio is not saved." The start time, not a running clock: a
    /// ticking clock is what recording and calls look like.
    func islandLine(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let start = Self.clock(since, locale: locale, timeZone: timeZone)
        guard let tally else { return "On since \(start). Audio is not saved." }
        return "\(tally) since \(start)"
    }

    /// The Lock Screen's second line, or nil before the first dictation: "312 words · 128 wpm ·
    /// 6 min saved" once there is a speed (the island's line keeps the dictation count; one
    /// caption line holds three figures), otherwise the tally and the time saved.
    var lockScreenLine: String? {
        guard let tally else { return nil }
        let saved = minutesSaved.map { "\($0) min saved" }
        guard let wpm = wordsPerMinute else { return [tally, saved].compactMap { $0 }.joined(separator: " · ") }
        let count = words == 1 ? "1 word" : "\(words.formatted()) words"
        return [count, "\(wpm) wpm", saved].compactMap { $0 }.joined(separator: " · ")
    }

    /// With the check after a kept dictation: "Kept 42 words · 128 wpm." or "Kept 42 words."
    func keptLine(words: Int) -> String {
        guard let wpm = lastWordsPerMinute else { return "Kept \(words) words." }
        return "Kept \(words) words · \(wpm) wpm."
    }

    static func clock(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.locale = locale
        style.timeZone = timeZone
        return date.formatted(style)
    }
}

/// The island's looks. Each is a complete, self-consistent presentation; the person picks one.
enum IslandLook: String, Codable, Hashable, CaseIterable, Identifiable {
    /// Zone's own: accent-colored live waveform, a countdown ring on standby.
    case halo
    /// Apple's voice recorder, measured point for point (islandcn's spec): red waveform, red
    /// clock, a stop ring concentric with the island's corner.
    case recorder
    /// Words first: the expanded island is a live caption of what Zone hears.
    case caption
    /// Almost nothing: one accent dot, the smallest footprint iOS allows.
    case ghost

    var id: String { rawValue }
    var title: String {
        switch self {
        case .halo: "Halo"
        case .recorder: "Recorder"
        case .caption: "Caption"
        case .ghost: "Ghost"
        }
    }
    var summary: String {
        switch self {
        case .halo: "Accent waveform while dictating, countdown ring on standby."
        case .recorder: "Matches Apple's Voice Memos layout: red waveform, timer, and stop button."
        case .caption: "Hold the island to read live captions as you speak."
        case .ghost: "Minimal single dot."
        }
    }
}

/// Level history for the island, quantized so a second of updates stays a few bytes.
enum IslandLevels {
    /// Bars in the compact island: islandcn measured 13 on Apple's recorder pill.
    static let compactBars = 13
    /// Bars in the expanded recorder row: 15, then grey dots where the recording has not reached.
    static let expandedBars = 15
    static let scale: UInt8 = 15

    static func quantize(_ level: Float) -> UInt8 {
        UInt8((min(max(level, 0), 1) * Float(scale)).rounded())
    }
    static func unit(_ value: UInt8) -> Double { Double(min(value, scale)) / Double(scale) }

    /// The newest `count` values, padded with silence at the old end.
    static func last(_ count: Int, of levels: [UInt8]?) -> [UInt8] {
        let levels = levels ?? []
        let tail = levels.suffix(count)
        return Array(repeating: 0, count: count - tail.count) + tail
    }
}

/// Speech as it reads in a caption: the last words, cut at a word boundary.
enum IslandCaption {
    static let maxCharacters = 64

    /// Punctuation and its spacing are what a streaming recognizer rewrites most: about half
    /// of all on-screen flicker in Google's measurement (Shangguan et al., Interspeech 2020),
    /// and the person speaking barely reads the caption anyway (7 to 11% of the time, Liang et
    /// al., CHI 2026). The caption shows words only, so it changes by adding words, not by
    /// commas and periods coming and going. Apostrophes and hyphens stay inside words.
    static func words(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if CharacterSet.punctuationCharacters.contains(scalar), scalar != "'", scalar != "\u{2019}", scalar != "-" {
                kept.append(" ")
            } else {
                kept.append(scalar)
            }
        }
        return String(kept).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func tail(of text: String, maxCharacters: Int = maxCharacters) -> String? {
        let trimmed = words(text)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maxCharacters else { return trimmed }
        let cut = trimmed.suffix(maxCharacters)
        // Drop the partial first word so the caption never starts mid-word.
        if let space = cut.firstIndex(where: \.isWhitespace) {
            return "…" + cut[space...].trimmingCharacters(in: .whitespaces)
        }
        return "…" + cut
    }
}
