// by zayd/cold @ zayd.wtf

import Foundation

/// What Zone does when iOS takes the microphone away (an alarm, a call, Siri, another app that
/// records) and when it gives it back.
///
/// A recording is never ended by an interruption. It is held: the microphone is off, everything
/// heard so far is recognized and saved, and the same recording picks up when the interruption
/// ends. Before 2026-11-03 an interruption ended the recording and filed it as a failure to retry,
/// although its text was complete. In a meeting that day a snoozed alarm went off every nine
/// minutes, and each time iOS handed the microphone back within three seconds and said Zone could
/// resume: one recording became three, each behind a retry card.
///
/// The app runs these decisions; they are plain values so the tests can cover every case.
public enum InterruptionPolicy {
    /// A held recording that has not resumed after this long ends and keeps its words. Holding
    /// costs nothing (the microphone is off), so the limit only keeps a recording from waiting
    /// forever for an interruption that never reports its end.
    public static let holdLimit: TimeInterval = 30 * 60
    /// While a recording runs, no audio for this long means the input stalled: iOS stopped the
    /// engine without saying so. The capture engine restarts it, and holds the recording when
    /// it cannot.
    public static let inputStallThreshold: TimeInterval = 2

    /// What the microphone was doing when the interruption began.
    public enum MicState: Equatable, Sendable {
        /// Off: nothing to do.
        case off
        /// Armed for the keyboard, no recording.
        case standingBy
        /// A recording in progress (paused by the person or not).
        case recording
        /// A recording already held by an earlier interruption.
        case held
    }

    public enum Began: Equatable, Sendable {
        case nothing
        /// Release the microphone, and take it back if iOS says to resume.
        case standDown
        /// Keep the recording: recognize and save what was heard, wait to resume.
        case hold
    }

    public static func began(_ state: MicState) -> Began {
        switch state {
        case .off, .held: return .nothing
        case .standingBy: return .standDown
        case .recording: return .hold
        }
    }

    public enum Ended: Equatable, Sendable {
        case nothing
        /// Take the microphone back and continue the held recording.
        case resume
        /// Arm the microphone again for the keyboard.
        case rearm
        /// Stay held until Zone comes to the front (or the hold limit).
        case waitForApp
    }

    /// - Parameters:
    ///   - shouldResume: iOS's hint that the interruption is over and Zone may take the
    ///     microphone back.
    ///   - appActive: Zone is on screen, so the person can see the recording continue.
    public static func ended(_ state: MicState, wasStandingBy: Bool, shouldResume: Bool, appActive: Bool) -> Ended {
        switch state {
        case .held:
            // A held recording is the person's: they never stopped it. On screen it continues
            // even without the hint, because they can see it; in the background only with it.
            return shouldResume || appActive ? .resume : .waitForApp
        case .off:
            return wasStandingBy && shouldResume ? .rearm : .nothing
        case .standingBy, .recording:
            return .nothing
        }
    }

    public enum Foreground: Equatable, Sendable {
        case nothing
        case resume
        /// Held past the limit: end it, keeping the words.
        case finish
    }

    /// Zone came to the front. iOS does not always report an interruption's end (Apple's docs
    /// say there is no guarantee), so a recording still held resumes here.
    public static func foreground(heldSince: Date?, now: Date) -> Foreground {
        guard let heldSince else { return .nothing }
        return now.timeIntervalSince(heldSince) >= holdLimit ? .finish : .resume
    }

    public static func holdExpired(heldSince: Date, now: Date) -> Bool {
        now.timeIntervalSince(heldSince) >= holdLimit
    }

    /// The input stopped delivering audio while the engine should be running.
    public static func inputStalled(lastBufferAge: TimeInterval) -> Bool {
        lastBufferAge >= inputStallThreshold
    }
}

/// The text of a recording made of several recognizer runs: one per stretch between
/// interruptions, or per rolling segment of a long dictation. Joined with single spaces; a run
/// that recognized nothing adds nothing.
public enum SegmentText {
    public static func join(_ first: String, _ second: String) -> String {
        // A run cut after "the" or "my" ends with the recognizer's period ("we went to the.").
        let a = TextStyle.joiningUnfinishedSentences(first.trimmingCharacters(in: .whitespacesAndNewlines), keeping: [])
        let b = second.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        // A cut at a pause can fall mid-sentence: the first run ends "so this was" with no
        // period, and the recognizer opens the next one as a sentence ("This was one of those
        // times"). The capital belongs to the cut, not the speech, so a plain word is lowered.
        // Names, "I", acronyms and mixed case keep theirs (`TextStyle.lowercasingFirstWord`).
        let continues = !endsSentence(a)
        return a + " " + (continues ? TextStyle.lowercasingFirstWord(b, keeping: []) : b)
    }

    /// One recognizer run's text without the model's unknown-token marker. Parakeet-family
    /// models write `<unk>` for a character they lack. In dictations it has stood for a curly
    /// apostrophe ("I<unk>ll send you"), an ampersand ("the R<unk>D side") and quotation marks
    /// ("<unk>OK,<unk> he said."). Inside a contraction it becomes the apostrophe, inside a known
    /// "&" abbreviation the ampersand, and anywhere else it goes with the space it leaves: between
    /// other capitals it is a gap in a spelling ("D<unk>N"), which is not ours to guess.
    public static func cleaned(_ run: String) -> String {
        guard run.contains("<unk>") else { return run.trimmingCharacters(in: .whitespacesAndNewlines) }
        var text = run.replacingOccurrences(
            of: #"(?<=\p{L})<unk>(?=(?:ll|ve|re|m|s|t|d)(?![\p{L}\p{N}]))"#, with: "'", options: .regularExpression)
        for name in ampersandNames {
            let parts = name.split(separator: "&")
            let pattern = #"(?<![\p{L}\p{N}])"# + parts[0] + "<unk>" + parts[1] + #"(?![\p{L}\p{N}])"#
            text = text.replacingOccurrences(of: pattern, with: name, options: .regularExpression)
        }
        return text.replacingOccurrences(of: "<unk>", with: " ")
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" +([,.;:!?])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Abbreviations written with "&". A closed list: "D<unk>N" in a spelled name is not "D&N".
    private static let ampersandNames = [
        "R&D", "Q&A", "AT&T", "M&A", "P&L", "S&P", "B&B", "H&M", "R&B", "D&D", "A&W", "M&M", "PB&J", "A&E", "B&H", "H&R", "T&C",
    ]

    public static func join(_ runs: [String]) -> String {
        runs.reduce("") { join($0, $1) }
    }

    /// "." "!" "?" "…" or ":" at the end, before any closing quotes or brackets.
    static func endsSentence(_ text: String) -> Bool {
        let end = text.reversed().drop { "\"'”’)]}".contains($0) }.first
        return end.map { ".!?…:\n".contains($0) } ?? true
    }
}
