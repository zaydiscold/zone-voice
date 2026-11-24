// by zayd/cold @ zayd.wtf

import Foundation
import ZoneCore

#if DEBUG && targetEnvironment(simulator)
/// Simulator Debug builds only: a fixed keyboard state for screenshots, read from a text file in the App Group
/// container so a shell can drive every face and state without a real dictation:
///
///     echo "listening dictate" > <group container>/keyboard-fixture.txt
///
/// Words, in any order: a state (idle, listening, quiet, finishing, low, mid, high, transcribing, inserted,
/// no-full-access, mic-denied, pending, starting, live), a face (type, dictate) and `capslock`
/// (locks Shift as a double tap would); other words are ignored. `live` records with no synthetic levels, so the meter shows only what arrives
/// on `LevelChannel` (post one with `notifyutil` inside the simulator). The keyboard polls the file while it is on screen; deleting it leaves the last state
/// in place. Compiled out of Release and device builds, so a phone's keyboard never reads it.
///
/// `say <tag>: <recognizer text>` delivers a real dictation result through the keyboard's insert
/// path, so spoken repairs and "Scratch that" can be tested in a real host without a microphone.
/// The keyboard deletes the file once it has delivered it, so a relaunched keyboard does not insert
/// it again; write the next line to deliver another. A word written `[hour:0.42]` is delivered as
/// "hour" with that confidence, as Fluid Speech Mini reports it, and turns the unsure-word check on
/// for that dictation.
///
/// `style-formal` (or `style-casual`, `style-veryCasual`, `style-excited`) picks a style as the
/// style row does, and `undo` taps Undo, so a rewrite of the last dictation can be driven after a
/// `say`. Like `say`, each is delivered once and the file is removed.
struct KeyboardFixture: Equatable {
    enum State: String, CaseIterable {
        case idle
        case listening
        case quiet
        /// Finish when quiet counting down: 3 seconds left.
        case finishing
        case low
        case mid
        case high
        case transcribing
        case inserted
        case noFullAccess = "no-full-access"
        case micDenied = "mic-denied"
        case pending
        case starting
        case live
    }

    var state: State?
    var mode: KeyboardMode?
    /// Recognizer text to insert as a finished dictation.
    var say: String?
    /// `capslock`: lock Shift as a double tap would, so a caps-lock dictation can be driven.
    var capsLock = false
    /// `accent-ice`, `accent-ember` and so on: sets the shared accent, so one build shows them all.
    var accent: AccentChoice?
    /// `style-formal`, `style-veryCasual` and so on: picks the style as a tap in the style row
    /// would, which also rewrites a dictation still at the cursor.
    var style: TextStyle?
    /// `undo`: taps Undo, when the strip offers it.
    var undo = false

    static let fileName = "keyboard-fixture.txt"

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ZoneContract.appGroup)?
            .appendingPathComponent(fileName)
    }

    static func parse(_ text: String) -> KeyboardFixture {
        var fixture = KeyboardFixture()
        if text.hasPrefix("say"), let colon = text.firstIndex(of: ":") {
            fixture.say = text[text.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return fixture
        }
        for word in text.split(whereSeparator: { $0.isWhitespace }) {
            let token = String(word)
            if token.lowercased() == "capslock" {
                fixture.capsLock = true
            } else if let state = State(rawValue: token.lowercased()) {
                fixture.state = state
            } else if let mode = KeyboardMode(rawValue: token.lowercased()) {
                fixture.mode = mode
            } else if token.lowercased().hasPrefix("accent-") {
                fixture.accent = AccentChoice(rawValue: String(token.lowercased().dropFirst(7)))
            } else if token.hasPrefix("style-") {
                fixture.style = TextStyle(rawValue: String(token.dropFirst(6)))
            } else if token.lowercased() == "undo" {
                fixture.undo = true
            }
        }
        return fixture
    }

    static func readFile() -> String? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func removeFile() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// `say` text with its `[word:confidence]` marks read out: the plain text and the doubts.
    static func doubtMarks(in text: String) -> (text: String, doubts: [DoubtfulWord]) {
        var plain = ""
        var doubts: [DoubtfulWord] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]") {
            plain += rest[..<open]
            let inside = rest[rest.index(after: open)..<close]
            if let colon = inside.lastIndex(of: ":"), let confidence = Float(inside[inside.index(after: colon)...]) {
                let word = String(inside[..<colon])
                plain += word
                doubts.append(DoubtfulWord(word: word, confidence: confidence))
            } else {
                plain += rest[open...close]
            }
            rest = rest[rest.index(after: close)...]
        }
        return (plain + rest, doubts)
    }

    /// The sample dictation every fixture inserts: 18 words, two sentences.
    static let sampleText = "Can you send me the deck before the call tomorrow? I want to go over the numbers once more."

    /// A plausible speech envelope for the waveform, oldest first.
    static func sampleLevels(count: Int) -> [Float] {
        (0..<count).map { index in
            let t = Double(index) / Double(max(count - 1, 1))
            let envelope = 0.25 + 0.55 * (0.5 + 0.5 * sin(t * 9.4 + 1.2)) * (0.6 + 0.4 * sin(t * 3.1))
            return Float(min(max(envelope, 0.08), 0.95))
        }
    }
}
#endif
