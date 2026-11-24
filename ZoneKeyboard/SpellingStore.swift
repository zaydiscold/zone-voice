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
    /// Words kept once, waiting for a second keep (`KeepConfirmation`).
    private static let pendingKeepsKey = "zone.keyboard.pendingKeeps"
    /// Kept words that are one slip from an everyday word, each with that word
    /// (`Autocorrector.keptSlips`), and how many of the kept words have been checked for it.
    private static let slipsKey = "zone.keyboard.learnedSlips"
    private static let slipsCheckedKey = "zone.keyboard.learnedSlipsChecked"
    /// Called on the main thread when the kept slips change, so swipe drops or regains a word.
    static var keptSlipsChanged: (() -> Void)?

    private static let mirroredKey = "zone.keyboard.mirroredTypedWords"
    private static var sharedStore: (@Sendable () -> PersonalVocabulary?)?
    private static var exchangeRunning = false
    private static var exchangeRequested = false

    static func refreshSharedLearning(fullAccess: Bool, store: @escaping @Sendable () -> PersonalVocabulary?) {
        sharedStore = fullAccess ? store : nil
        if fullAccess { exchange() }
    }

    /// The extension owns its defaults even without Full Access. Reconcile off the typing
    /// thread. A local edit during I/O starts another pass before applying the result.
    static func exchange() {
        guard let sharedStore else { return }
        if exchangeRunning { exchangeRequested = true; return }
        exchangeRunning = true
        let typed = learnedWords
        let choices = DoubtStore.memory
        let previous = UserDefaults.standard.stringArray(forKey: mirroredKey) ?? []
        Task {
            let snapshot = await Task.detached(priority: .utility) {
                try? sharedStore()?.exchangeKeyboard(typed: typed, previously: previous, choices: choices)
            }.value
            exchangeRunning = false
            if let snapshot, Self.sharedStore != nil {
                // This pass published the captured local words, even when an edit overtook it.
                if previous != typed { UserDefaults.standard.set(typed, forKey: mirroredKey) }
                if learnedWords == typed, DoubtStore.memory == choices {
                    if typed != snapshot.typedWords {
                        UserDefaults.standard.set(snapshot.typedWords, forKey: learnedKey)
                        UserDefaults.standard.set(snapshot.typedWords, forKey: mirroredKey)
                        for word in snapshot.typedWords.dropFirst(typed.count) { corrector?.learn(word) }
                        checkKeptWords()
                        keptSlipsChanged?()
                    }
                    if choices != snapshot.correctionChoices { DoubtStore.memory = snapshot.correctionChoices }
                } else { exchangeRequested = true }
            }
            if exchangeRequested { exchangeRequested = false; exchange() }
        }
    }

    /// Calls `completion` on the main thread with the shared corrector, loading it on first use.
    static func load(_ completion: @escaping (Autocorrector?) -> Void) {
        if let corrector {
            retryMissingContext()
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
                    corrector?.setKeptSlips(keptSlips)
                    let pending = waiters
                    waiters = []
                    pending.forEach { $0(corrector) }
                    checkKeptWords()
                }
            }
        }
    }

    /// Tests run outside the keyboard's bundle, where `WordPairs.shared` finds no table.
    private static var pairsOverride: WordPairs?
    private static var readingContext = false
    static func retryMissingContext() {
        guard let corrector, corrector.context == nil, !readingContext else { return }
        readingContext = true
        Task {
            let pairs = await Task.detached(priority: .utility) { WordPairs.shared }.value
            corrector.context = pairsOverride ?? pairs
            readingContext = false
        }
    }

    static func useWordPairs(_ pairs: WordPairs?) {
        pairsOverride = pairs
        corrector?.context = pairs ?? WordPairs.shared
    }

    /// The shared corrector once loaded, for callers that cannot wait (the doubt row's alternatives).
    static var current: Autocorrector? { corrector }

    /// Words the user kept, oldest first. Swipe offers them like personal words.
    static var learnedWords: [String] { UserDefaults.standard.stringArray(forKey: learnedKey) ?? [] }

    /// Kept words that are a slip for an everyday word, by lowercase spelling.
    static var keptSlips: [String: String] { UserDefaults.standard.dictionary(forKey: slipsKey) as? [String: String] ?? [:] }

    /// The kept words swipe may write: all but the slips, which trace like the everyday word they
    /// sit beside and would take its swipes ("bsby" for every "baby").
    static var swipeableLearnedWords: [String] {
        let slips = keptSlips
        return slips.isEmpty ? learnedWords : learnedWords.filter { slips[$0.lowercased()] == nil }
    }

    /// Words kept before this check existed are looked at once, a few per turn of the main
    /// thread (each costs one evaluation, about a millisecond), oldest first.
    static func checkKeptWords() {
        guard let corrector else { return }
        let defaults = UserDefaults.standard
        let stored = learnedWords
        var checked = min(defaults.integer(forKey: slipsCheckedKey), stored.count)
        guard checked < stored.count else { return }
        var slips = keptSlips
        var found = false
        for word in stored[checked..<min(checked + 8, stored.count)] {
            if let fix = corrector.everydayWordBehindKept(word) {
                slips[word] = fix
                found = true
            }
            checked += 1
        }
        defaults.set(checked, forKey: slipsCheckedKey)
        if found {
            defaults.set(slips, forKey: slipsKey)
            corrector.setKeptSlips(slips)
            keptSlipsChanged?()
        }
        if checked < stored.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { checkKeptWords() } }
        }
    }

    /// The person took the everyday word the row offered for a kept slip: the slip is forgotten.
    /// Returns true when `word` was one.
    @discardableResult
    static func forgetKeptSlip(_ word: String, replacedBy fix: String) -> Bool {
        guard let corrector else { return false }
        let key = word.lowercased()
        var slips = keptSlips
        guard let known = slips[key], known.lowercased() == fix.lowercased() else { return false }
        corrector.forget(word)
        slips[key] = nil
        let defaults = UserDefaults.standard
        let stored = learnedWords
        let kept = stored.filter { $0.lowercased() != key }
        // The count of checked words follows the list, so a later word is not skipped.
        let checkedBefore = min(defaults.integer(forKey: slipsCheckedKey), stored.count)
        let removedChecked = stored.prefix(checkedBefore).filter { $0.lowercased() == key }.count
        defaults.set(kept, forKey: learnedKey)
        defaults.set(checkedBefore - removedChecked, forKey: slipsCheckedKey)
        defaults.set(slips, forKey: slipsKey)
        exchange()
        KeyboardLog.typing.info("forgot a kept slip (\(kept.count) kept)")
        return true
    }

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
    /// The first keep only protects the word until this process ends; the second keep learns it
    /// (`KeepConfirmation`). Returns false for a first keep, so swipe does not offer it yet.
    @discardableResult
    static func learn(_ word: String) -> Bool {
        guard let corrector else { return false }
        let defaults = UserDefaults.standard
        var stored = defaults.stringArray(forKey: learnedKey) ?? []
        let key = word.lowercased()
        guard !stored.contains(where: { $0.lowercased() == key }) else { return false }
        var gate = KeepConfirmation(pending: defaults.stringArray(forKey: pendingKeepsKey) ?? [])
        let confirmed = gate.keep(word)
        defaults.set(gate.pending, forKey: pendingKeepsKey)
        // Protected now either way, so the separator that follows does not undo the person's choice.
        corrector.learn(word)
        guard confirmed else {
            KeyboardLog.typing.info("kept a word once; learned after a second keep")
            return false
        }
        var checked = min(defaults.integer(forKey: slipsCheckedKey), stored.count)
        let form = storedForm(of: word)
        stored.append(form)
        // Checked now when every earlier word already is; otherwise the pass under way reaches it.
        if checked == stored.count - 1 {
            checked += 1
            if let fix = corrector.everydayWordBehindKept(form) {
                var slips = keptSlips
                slips[form] = fix
                defaults.set(slips, forKey: slipsKey)
                corrector.setKeptSlips(slips)
            }
        }
        if stored.count > learnedLimit {
            let dropped = stored.count - learnedLimit
            stored.removeFirst(dropped)
            checked = max(0, checked - dropped)
        }
        defaults.set(checked, forKey: slipsCheckedKey)
        defaults.set(stored, forKey: learnedKey)
        exchange()
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
        didSet { save(memory, memoryKey); SpellingStore.exchange() }
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private static func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}
