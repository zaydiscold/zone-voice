// by zayd/cold @ zayd.wtf

import ActivityKit
import Foundation

struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// `paused`: an interruption (an alarm, a call) holds the recording or the standby.
        enum Phase: String, Codable, Hashable { case ready, starting, recording, processing, paused }
        var phase: Phase
        var noteMode: Bool
        var startedAt: Date
        /// Present only for a long meeting; older activities decode with no meeting title.
        var meetingTitle: String? = nil
        /// Only a recording started by its standalone control may advertise that control's Stop.
        var controlOwned: Bool? = nil
        var startedByPress: Bool? = nil
        var pressNotice: String? = nil
        var modelLoading: Bool? = nil
        var waitingForSamples: Bool? = nil
        var recordingHint: String {
            if modelLoading == true { return "Listening · Loading speech model" }
            if startedByPress == true { return "Press again to stop" }
            if controls != false || controlOwned == true { return "Tap Stop to finish" }
            return "Recording on this iPhone"
        }
        /// A meeting's own line in place of its title: held for a call, about to stop, or why it
        /// was saved. Older activities decode without it.
        var meetingNote: String? = nil
        /// Absent in activities started before meeting waves were available.
        var meetingWaveStyle: String? = nil
        /// A meeting held by a call or another app, not paused by the person.
        var meetingHeld: Bool? = nil

        // MARK: Island presentation. All optional so an older payload still decodes.

        /// How the Dynamic Island draws Zone. Settings > Dynamic Island.
        var look: IslandLook? = nil
        /// The person's accent (Settings > Appearance), so the island matches the app.
        var accentChoice: String? = nil
        /// The color choice from earlier beta cards. Nil, from an older payload,
        /// is the accent.
        var palette: IslandPalette? = nil
        /// The microphone over the last couple of seconds, oldest first, each 0...15
        /// (`IslandLevels.scale`). Sent about once a second while recording.
        var levels: [UInt8]? = nil
        var spin: IslandSpin? = nil
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
        /// Counts the live updates of a recording. The living looks pace blinks, wingbeats and
        /// the comet by it; it carries no information about the person.
        var beat: UInt16? = nil
        /// The pet's growth stage (`IslandPetGrowth`), from the words dictated in all.
        var petStage: UInt8? = nil
        var dailyEnergy: UInt8? = nil
        var accessory: UInt8? = nil
        var gallery: Bool? = nil
        var nightGarden: Bool? = nil
        /// Finish when quiet has heard nothing for a moment: from when the card began to say
        /// "Quiet" until the recording ends by itself. A ring drains over it, which iOS animates
        /// with no further updates. Nil while a voice is heard, and from an older payload.
        var quiet: ClosedRange<Date>? = nil
        /// How the card says when standby started and ends (Settings > Dynamic Island > Times).
        /// Nil, from an older payload, is clock times.
        var times: IslandTimes? = nil
    }
}

/// How the island and the Lock Screen card say standby's times.
enum IslandTimes: String, Codable, Hashable, CaseIterable, Identifiable {
    /// "since 5:42", "Off 6:10": fixed clock times, nothing on the card moves.
    case clock
    /// "on for 29 minutes", "Off in 15 minutes": spans iOS advances by itself. Zone sends no
    /// extra updates for them, so they cost the same as the clock times.
    case live

    var id: String { rawValue }
    var title: String {
        switch self {
        case .clock: "Clock"
        case .live: "Live"
        }
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
    var seconds = 0
    // Optional fields keep existing ActivityKit payloads readable.
    var recordedSeconds: Double?
    var measuredSeconds: Double?
    var keptWords: Int?

    mutating func add(words: Int, seconds: Double, kept: Int = 0) {
        guard words > 0, seconds.isFinite, seconds > 0 else { return }
        if let measuredSeconds { self.measuredSeconds = measuredSeconds + seconds }
        recordedSeconds = (recordedSeconds ?? Double(self.seconds)) + seconds
        keptWords = (keptWords ?? 0) + min(words, max(0, kept))
        self.seconds = Int((recordedSeconds ?? 0).rounded())
        dictations += 1
        self.words += words
    }

    var wordsPerMinute: Int? {
        let duration = recordedSeconds ?? Double(seconds)
        return duration >= 10 ? Self.perMinute(words, duration) : nil
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
        let typing = Double(keptWords ?? 0) / Self.typingWordsPerMinute
        let saved = Int((typing - (measuredSeconds ?? recordedSeconds ?? Double(seconds)) / 60).rounded())
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
    /// A tiny spectral companion in the gallery; the classic version uses a dot.
    case ghost

    // The living looks (`IslandArt.swift`). They move only while Zone records.

    /// The island is a black cat: two eyes either side of the camera, which is its nose.
    case void
    /// A pixel pet that hatches and grows with the words you dictate. It never shrinks.
    case mote
    /// A sprout that grows as you speak and flowers when your words are kept.
    case sprout
    /// Ember uses the old Loop key so saved choices still work.
    case loop
    /// A bat whose body is the camera: one wing each side.
    case nocturne

    // The art looks (`IslandArtworks.swift`).

    /// Your words pass through the island as you say them: the newest right of the camera, the
    /// one before it left.
    case stream
    /// A heart and its trace. It beats by itself while Zone waits (`IslandGate`), and the trace
    /// follows your voice.
    case pulse
    /// Petals on the wind. Your voice is the wind; they settle when you stop.
    case drift
    case blackout, hare, wren, rose, synth, cube, sword

    var id: String { rawValue }
    var title: String {
        switch self {
        case .halo: "Halo"
        case .recorder: "Recorder"
        case .caption: "Caption"
        case .ghost: "Ghost"
        case .void: "Void"
        case .blackout: "Full Black"
        case .hare: "Pip"
        case .wren: "Wren"
        case .mote: "Mote"
        case .sprout: "Sprout"
        case .loop: "Ember"
        case .nocturne: "Nocturne"
        case .stream: "Stenographer"
        case .pulse: "Pulse"
        case .drift: "Blossom"
        case .rose: "Rose"
        case .synth: "Synth"
        case .cube: "Orbit Cube"
        case .sword: "Pixel Sword"
        }
    }
    var summary: String {
        switch self {
        case .halo: "Accent waveform while dictating, countdown ring on standby."
        case .recorder: "A recording strip with a timer and stop button."
        case .caption: "Hold the island to read live captions as you speak."
        case .ghost: "A little pearl ghost opens its eyes when you speak."
        case .void: "The island is a black cat. Its eyes open when you speak."
        case .blackout: "A graphite crescent with a glint of your accent."
        case .hare: "A long-eared hare with a twitching ear and keepsakes."
        case .wren: "A small bird from your first word box."
        case .mote: "A moon moth that hatches as you dictate."
        case .sprout: "Grows as you speak, flowers when your words are kept."
        case .loop: "One flame leans toward your voice."
        case .nocturne: "A dusk bat opens its wings. Its face fills the side Island."
        case .stream: "Your words pass through the island as you say them."
        case .pulse: "A coral heart lifts with your voice, beside its trace."
        case .drift: "A violet flower with sage leaves and a dark center."
        case .rose: "A rosebud opens as your words accumulate."
        case .synth: "Seven columns trace your recent microphone levels."
        case .cube: "A floating wireframe cube picks up speed as you speak."
        case .sword: "A little steel blade banks and catches the light with your voice."
        }
    }

    /// A living look: a creature or an ornament in place of the waveform.
    var isAlive: Bool {
        switch self {
        case .void, .mote, .hare, .wren, .sprout, .loop, .nocturne, .pulse, .drift, .rose, .synth, .cube, .sword: true
        case .blackout, .halo, .recorder, .caption, .ghost, .stream: false
        }
    }
    /// The creature spans the camera, one half each side, so the trailing side is its other half
    /// and not a clock.
    var spansCamera: Bool { self == .void || self == .nocturne }
    /// Direct builds, including development-signed Release builds, can evaluate the art.
    /// Archives use the archive or install action. Missing metadata also uses the classic looks.
    static let developmentGallery = Bundle.main.object(forInfoDictionaryKey: "ZoneBuildAction") as? String == "build"

    static let classic: [IslandLook] = [.halo, .recorder, .caption, .ghost]
    var spins: Bool { self == .cube || self == .sword }
    var isPet: Bool { self == .mote || self == .hare || self == .wren }

    static func restored(_ look: Self, palette: IslandPalette) -> Self {
        look == .halo && palette == .blackout ? .blackout : look
    }

}

/// Raw keys from old cards and saved choices. The gallery draws every look in the app accent.
enum IslandPalette: String, Codable, Hashable, CaseIterable {
    case accent, blackout, graphite, red, amber, green, bone, rose
}

/// A turn is one revolution. Retargeting preserves angle and velocity, including when
/// recording stops. The closed-form curve needs no clock running in the recording process.
struct IslandSpin: Codable, Hashable {
    var at: Date
    var turns: Double
    var speed: Double
    var target: Double

    func sample(at date: Date) -> (turns: Double, speed: Double) {
        let t = max(0, date.timeIntervalSince(at))
        let drag = target == 0 ? 0.46 : 0.32
        let decay = exp(-t / drag)
        return (turns + target * t + (speed - target) * drag * (1 - decay),
                target + (speed - target) * decay)
    }

    func retarget(_ rate: Double, at date: Date) -> Self {
        guard rate != target else { return self }
        let pose = sample(at: date)
        return Self(at: date, turns: pose.turns, speed: pose.speed, target: rate)
    }

    static func resting(at date: Date) -> Self {
        Self(at: date, turns: 0.095, speed: 0, target: 0)
    }
}

enum IslandStream {
    /// Long words keep their end, where the eye is when the word lands.
    static let maxCharacters = 9

    static func words(_ tail: String?) -> (previous: String?, newest: String?) {
        let words = (tail ?? "").split(separator: " ").map(String.init).filter { $0 != "…" }
        guard let newest = words.last else { return (nil, nil) }
        return (words.count > 1 ? clip(words[words.count - 2]) : nil, clip(newest))
    }

    static func clip(_ word: String) -> String {
        let word = word.hasPrefix("…") ? String(word.dropFirst()) : word
        return word.count > maxCharacters ? "…" + word.suffix(maxCharacters - 1) : word
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
