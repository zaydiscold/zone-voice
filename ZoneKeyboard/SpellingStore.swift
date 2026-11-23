// by zayd/cold @ zayd.wtf

import Foundation
import UIKit
import ZoneCore

/// One autocorrector per keyboard process. The host may create a new keyboard view controller
/// every time the keyboard appears while the process lives on, so the 1.2 MB word list is parsed
/// once, off the main thread, and shared. Words the user insists on are kept in the extension's
/// own defaults, which work without Full Access.
@MainActor
enum SpellingStore {
    private static var corrector: Autocorrector?
    private static var isLoading = false
    private static var waiters: [(Autocorrector?) -> Void] = []
    private static let learnedKey = "zone.keyboard.learnedWords"
    /// Oldest learned words are dropped past this many. A word is a few bytes, so 5,000 is about
    /// 40 KB of defaults: enough that a person's own words are never forgotten in practice.
    private static let learnedLimit = 5_000

    /// Calls `completion` on the main thread with the shared corrector, loading it on first use.
    static func load(_ completion: @escaping (Autocorrector?) -> Void) {
        if let corrector {
            completion(corrector)
            return
        }
        waiters.append(completion)
        guard !isLoading else { return }
        isLoading = true
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            SystemSpelling.warm()
            let list = WordList.shared
            // The swipe word-pair table, so a typo is read against the word before it.
            let pairs = WordPairs.shared
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    isLoading = false
                    let learned = UserDefaults.standard.stringArray(forKey: learnedKey) ?? []
                    corrector = list.map { Autocorrector(words: $0, learnedWords: Set(learned)) }
                    corrector?.systemAccepts = { word in MainActor.assumeIsolated { SystemSpelling.accepts(word) } }
                    corrector?.context = pairsOverride ?? pairs
                    corrector?.systemGuesses = { word in MainActor.assumeIsolated { SystemSpelling.guesses(for: word) } }
                    corrector?.systemCompletions = { word in MainActor.assumeIsolated { SystemSpelling.completions(for: word) } }
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    if let list {
                        KeyboardLog.typing.info("word list loaded: \(list.count) words in \(ms) ms")
                    } else {
                        KeyboardLog.typing.error("word list missing from the bundle; autocorrect is off")
                    }
                    let pending = waiters
                    waiters = []
                    pending.forEach { $0(corrector) }
                }
            }
        }
    }

    /// Tests run outside the keyboard's bundle, where `WordPairs.shared` finds no table.
    private static var pairsOverride: WordPairs?
    static func useWordPairs(_ pairs: WordPairs?) {
        pairsOverride = pairs
        corrector?.context = pairs ?? WordPairs.shared
    }

    /// The shared corrector once loaded, for callers that cannot wait (the doubt row's alternatives).
    static var current: Autocorrector? { corrector }

    /// Words the user kept, oldest first. Swipe offers them like personal words.
    static var learnedWords: [String] { UserDefaults.standard.stringArray(forKey: learnedKey) ?? [] }

    /// How a kept word is saved. Swipe writes kept words as saved, so a word with capitals inside
    /// it ("OpenRouter", "iPhone") keeps them. Anything else is saved in lowercase: a capital on
    /// the first letter is usually the sentence start, and would otherwise follow the word everywhere.
    static func storedForm(of word: String) -> String {
        let letters = word.filter(\.isLetter)
        let inner = letters.dropFirst().contains(where: \.isUppercase)
        let allCapitals = !letters.isEmpty && letters.allSatisfy(\.isUppercase)
        return inner && !allCapitals ? word : word.lowercased()
    }

    /// Remembers a word the user kept, so it is never corrected again on this phone.
    /// Returns true when the word was new.
    @discardableResult
    static func learn(_ word: String) -> Bool {
        guard let corrector else { return false }
        let before = corrector.learnedWords.count
        corrector.learn(word)
        guard corrector.learnedWords.count != before else { return false }
        var stored = UserDefaults.standard.stringArray(forKey: learnedKey) ?? []
        stored.append(storedForm(of: word))
        if stored.count > learnedLimit {
            stored.removeFirst(stored.count - learnedLimit)
        }
        UserDefaults.standard.set(stored, forKey: learnedKey)
        KeyboardLog.typing.info("learned a word (\(stored.count) kept)")
        return true
    }
}

/// Where this person's taps land on each letter key (`TouchAdaptation`), so the
/// grid aims where they actually tap. One per keyboard process, kept in the extension's own
/// defaults (no Full Access needed). Only per-key offset sums are stored, never text.
@MainActor
enum TouchAdaptationStore {
    /// Off gives the grid's fixed targets.
    static let isEnabled = true
    private static let defaultsKey = "zone.keyboard.touchAdaptation"
    /// Set once the bottom row learned before builds that kept slipped spaces out has been reset.
    private static let bottomRowResetKey = "zone.keyboard.touchAdaptation.bottomRowReset"
    /// Saved after this many learned words, and when the keyboard goes away.
    private static let saveEvery = 15
    private static var model = load()
    private static var unsaved = 0

    /// Per letter a...z, the learned offset in key and row pitches; the touch path reads only this.
    private(set) static var offsets: [KeyTouch] = isEnabled ? model.offsetTable : []

    /// A committed word teaches where its taps landed (see `TouchAdaptation.learn`).
    static func learn(typed: String, committed: String, touches: [KeyTouch], recognized: Bool) {
        guard isEnabled, model.learn(typed: typed, committed: committed, touches: touches, recognized: recognized) else { return }
        offsets = model.offsetTable
        unsaved += 1
        if unsaved >= saveEvery { save() }
    }

    static func save() {
        guard isEnabled, unsaved > 0, let data = try? JSONEncoder().encode(model) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
        unsaved = 0
        #if DEBUG
        let shown = offsets.enumerated().filter { abs($0.element.dx) > 0.05 || abs($0.element.dy) > 0.05 }.prefix(6)
            .map { "\(Character(UnicodeScalar(UInt8(0x61 + $0.offset))))=\(String(format: "%.2f,%.2f", $0.element.dx, $0.element.dy))" }
        KeyboardLog.typing.info("touch offsets saved after \(Int(model.taps), privacy: .public) taps: \(shown.joined(separator: " "), privacy: .public)")
        #endif
    }

    private static func load() -> TouchAdaptation {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: defaultsKey),
              var model = try? JSONDecoder().decode(TouchAdaptation.self, from: data) else { return TouchAdaptation() }
        // Earlier builds learned from unrecognized runs too, so a space bar tap that typed v taught
        // v to sit lower, which turned more spaces into v. Those keys start over once.
        if !defaults.bool(forKey: bottomRowResetKey) {
            model.forgetBottomRow()
            if let repaired = try? JSONEncoder().encode(model) { defaults.set(repaired, forKey: defaultsKey) }
            defaults.set(true, forKey: bottomRowResetKey)
        }
        return model
    }
}

/// Apple's own dictionary through `UITextChecker`, the public way to ask it whether a word is
/// real (about 200k English words; a keyboard cannot read the files or Apple's learned words).
/// The lexicon is mapped as clean pages, so the extension's footprint stays flat; measured on the
/// iOS 26.2 simulator, 6,000 lookups added no footprint and cost 0.01 ms each. The first lookup
/// in a process opens the lexicon (about 20 ms), so it is made once off the main thread.
@MainActor
enum SystemSpelling {
    private static let checker = UITextChecker()
    private nonisolated static let language: String = {
        let available = UITextChecker.availableLanguages
        return available.contains("en_US") ? "en_US" : available.first { $0.hasPrefix("en") } ?? "en_US"
    }()

    /// Opens the lexicon on the calling (background) thread with its own checker.
    nonisolated static func warm() {
        _ = isWord("warm", checker: UITextChecker())
    }

    static func accepts(_ word: String) -> Bool {
        isWord(word, checker: checker)
    }

    /// Apple's corrections for a misspelled word, best first, at most `limit`. About 1 ms each
    /// on the simulator (18 ms for the first in a process); the corrector asks once per word
    /// state and only for words neither dictionary knows, and the answers are remembered here.
    static func guesses(for word: String, limit: Int = 3) -> [String] {
        if let known = guessCache[word] { return known }
        let range = NSRange(location: 0, length: (word as NSString).length)
        let found = Array((checker.guesses(forWordRange: range, in: word, language: language) ?? []).prefix(limit))
        remember(found, for: word, in: &guessCache)
        return found
    }

    /// Apple's completions of a partial word, most likely first, at most `limit`.
    static func completions(for prefix: String, limit: Int = 3) -> [String] {
        if let known = completionCache[prefix] { return known }
        let range = NSRange(location: 0, length: (prefix as NSString).length)
        let found = Array((checker.completions(forPartialWordRange: range, in: prefix, language: language) ?? []).prefix(limit))
        remember(found, for: prefix, in: &completionCache)
        return found
    }

    private static var guessCache: [String: [String]] = [:]
    private static var completionCache: [String: [String]] = [:]
    private static func remember(_ value: [String], for key: String, in cache: inout [String: [String]]) {
        if cache.count >= 128 { cache.removeAll(keepingCapacity: true) }
        cache[key] = value
    }

    private nonisolated static func isWord(_ word: String, checker: UITextChecker) -> Bool {
        let range = NSRange(location: 0, length: (word as NSString).length)
        return checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: language).location == NSNotFound
    }
}

/// What the strip's unsure-word checks have learned on this phone (`DoubtCalibration`,
/// `DoubtMemory`), kept in the extension's own defaults like the learned words. Only counts per
/// confidence band and the person's chosen words are stored, never the dictated text.
@MainActor
enum DoubtStore {
    private static let calibrationKey = "zone.keyboard.doubtCalibration"
    private static let memoryKey = "zone.keyboard.doubtMemory"

    static var calibration: DoubtCalibration = load(calibrationKey) ?? DoubtCalibration() {
        didSet { save(calibration, calibrationKey) }
    }

    static var memory: DoubtMemory = load(memoryKey) ?? DoubtMemory() {
        didSet { save(memory, memoryKey) }
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private static func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}
