// by zayd/cold @ zayd.wtf

import Foundation

/// One slot of the suggestion row.
public struct Suggestion: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The word exactly as typed; tapping it keeps it and teaches the keyboard the word.
        case literal
        /// A spelling fix or recasing of the typed word.
        case correction
        /// A longer word that starts with what was typed.
        case completion
        /// A whole next word, offered between words; tapping it writes the word and a space.
        case prediction
    }

    public let text: String
    public let kind: Kind
    /// True for the one candidate that space or punctuation commits in place of the typed word.
    public let autoApplies: Bool

    public init(text: String, kind: Kind, autoApplies: Bool = false) {
        self.text = text
        self.kind = kind
        self.autoApplies = autoApplies
    }
}

/// What the strip shows for the word under the cursor and what a separator will do to it.
public struct Evaluation: Equatable, Sendable {
    public let typed: String
    public let suggestions: [Suggestion]
    /// True when the word before this one could change the answer: the typed word is not one the
    /// keyboard accepts, and a previous-word table is loaded. The keyboard reads the text at the
    /// cursor before committing such a word; for every other word a plain space needs no read.
    public let dependsOnPrevious: Bool

    /// The text a separator commits instead of `typed`; nil leaves the typed word alone.
    public var replacement: String? { suggestions.first(where: { $0.autoApplies })?.text }

    public init(typed: String, suggestions: [Suggestion], dependsOnPrevious: Bool = false) {
        self.typed = typed
        self.suggestions = suggestions
        self.dependsOnPrevious = dependsOnPrevious
    }
}

/// English autocorrect for the keyboard: decides, from the word being typed, where its taps
/// landed and (when the keyboard knows it) the word before, what the three suggestion slots show
/// and whether the next separator replaces it.
///
/// Rules, in order: a word the user vouched for stays; a known texting contraction gets its
/// apostrophe; a dictionary word stays, except that an all-lowercase proper noun or acronym is
/// recased when common and a lowercase abbreviation one slip from a very common word ("amd")
/// becomes that word; a contraction missing only its apostrophe gets it; anything else is
/// matched against nearby dictionary words by weighted edit cost (with touch evidence when the
/// grid supplied it) and frequency, and against a split into two common words. Automatic
/// replacements require a clear lead over alternatives and conservative casing checks.
/// Acronyms, mixed case and digits are preserved; two-letter tokens change only with touch
/// evidence.
public final class Autocorrector {
    public static let maxSuggestions = 3
    /// Corrections at or below this cost are applied without asking.
    static let confidentCost: Float = 1.0
    /// Two-edit corrections are applied on words this long that land on words this common.
    static let twoEditMinimumLength = 6
    static let twoEditMaximumRank = 30_000
    static let minimumCorrectedLength = 3

    public let words: WordList
    /// Lowercase words the user kept despite a suggestion; they are never corrected again.
    public private(set) var learnedWords: Set<String>
    /// Current personal vocabulary, separate from spelling choices learned permanently.
    /// Replacing this set allows removing a personal term without an invisible permanent override.
    /// Built-in words ("Zayd", "imma") are always part of it.
    private var personalWords: Set<String> = []
    /// The person's own share of `personalWords`: a spelling they chose beats a built-in name.
    private var ownWords: Set<String> = []

    public func setPersonalWords(_ words: [String]) {
        ownWords = protectedKeys(words)
        personalWords = protectedKeys(BuiltInVocabulary.withAll(words) + ModernVocabulary.words)
        ownCompletions = Self.completionIndex(words)
        ownCorrections = ownCompletions.filter { $0.key.utf8.count >= Self.minimumOwnCorrectionLength }
            .map { (key: Array($0.key.utf8), display: $0.display) }
        ownSpellings = [:]
        // The person's own spellings first, then the built-in names, which swipe and dictation
        // already write with their capital.
        for word in (words + BuiltInVocabulary.names).map(TypingEdits.normalized) {
            guard word != word.lowercased(), let key = WordList.foldedKey(word) else { continue }
            let lower = String(decoding: key, as: UTF8.self)
            // An everyday word saved with a capital ("Will", "Apple") is still typed as the word.
            if self.words.lookup(lower)?.display == lower { continue }
            if ownSpellings[lower] == nil { ownSpellings[lower] = word }
        }
        memo = nil
    }

    /// The person's own words as spelling fixes: "Aalua" is "Aalia" when Aalia is in My words.
    /// Before this a saved word was only protected and completed, so a slip in it was matched
    /// against the dictionary alone and stayed wrong or became another word. One slip only, on
    /// words of four letters or more, and never for a typed word the dictionary knows.
    private var ownCorrections: [(key: [UInt8], display: String)] = []
    /// One-word entries saved with capitals, by their lowercase spelling: "aalia" typed in
    /// lowercase is written "Aalia", as a contact's name is. Phrases and everyday words are left out.
    private var ownSpellings: [String: String] = [:]
    static let minimumOwnCorrectionLength = 4
    static let ownCorrectionMaximumCost: Float = 1.0
    /// A saved word competes as a common word would: the person wrote it down because they use it.
    static let ownCorrectionRank = 300

    private func ownNeighbors(of key: [UInt8], touches: [KeyTouch]?) -> [Candidate] {
        guard key.count >= Self.minimumOwnCorrectionLength, !ownCorrections.isEmpty else { return [] }
        let substitutions = EditCost.Substitutions(typed: key, touches: touches)
        var scratch = EditCost.Scratch()
        var found: [Candidate] = []
        key.withUnsafeBufferPointer { typed in
            for own in ownCorrections where abs(own.key.count - key.count) <= 1 && own.key != key {
                let cost = own.key.withUnsafeBufferPointer {
                    EditCost.cost(typed, $0, substitutions: substitutions, limit: Self.ownCorrectionMaximumCost, scratch: &scratch)
                }
                guard cost <= Self.ownCorrectionMaximumCost else { continue }
                found.append(Candidate(text: own.display, cost: cost, rank: Self.ownCorrectionRank, length: own.key.count,
                                       firstLetterMatches: own.key[0] == key[0],
                                       startsLowercase: own.display.first?.isLowercase == true, isOwn: true))
            }
        }
        return found
    }

    /// The newer words Zone ships that the dictionary lacks ("spacebar", "ChatGPT") as spelling
    /// fixes. They were only protected as typed, so one slip in one ("soacebar") matched nothing
    /// and stayed. One slip, five letters or more, each at its own frequency rank, so a
    /// dictionary word that fits as well still wins.
    private lazy var modernCorrections: [(key: [UInt8], display: String, rank: Int)] = ModernVocabulary.correctionWords.compactMap {
        // Swearing and slurs are kept as typed, never reached by a slip (`correctionWords`).
        guard let key = WordList.foldedKey($0.word), key.count >= Self.minimumModernCorrectionLength,
              words.lookup(String(decoding: key, as: UTF8.self)) == nil else { return nil }
        return (key: key, display: $0.word, rank: $0.rank)
    }
    static let minimumModernCorrectionLength = 5

    private func modernNeighbors(of key: [UInt8], touches: [KeyTouch]?) -> [Candidate] {
        guard key.count >= Self.minimumModernCorrectionLength else { return [] }
        let substitutions = EditCost.Substitutions(typed: key, touches: touches)
        var scratch = EditCost.Scratch()
        var found: [Candidate] = []
        key.withUnsafeBufferPointer { typed in
            for modern in modernCorrections where abs(modern.key.count - key.count) <= 1 && modern.key != key {
                // "spacebars", "besties": a plural of one is a word, not a slip.
                if key.count == modern.key.count + 1, key.last == UInt8(ascii: "s"), key.dropLast().elementsEqual(modern.key) { continue }
                let cost = modern.key.withUnsafeBufferPointer {
                    EditCost.cost(typed, $0, substitutions: substitutions, limit: Self.ownCorrectionMaximumCost, scratch: &scratch)
                }
                guard cost <= Self.ownCorrectionMaximumCost else { continue }
                found.append(Candidate(text: modern.display, cost: cost, rank: modern.rank, length: modern.key.count,
                                       firstLetterMatches: modern.key[0] == key[0],
                                       startsLowercase: modern.display.first?.isLowercase == true))
            }
        }
        return found
    }

    /// The person's own words and contact names as the suggestion row can complete them: each
    /// word of each entry in its saved spelling, sorted by its lowercase key. Before this they only
    /// protected a word from correction, so "Matts" never offered a saved "Mattson". Offered,
    /// never applied by a separator; the built-in lists (names, slang and brands Zone ships) are
    /// left out.
    private var ownCompletions: [(key: String, display: String)] = []
    /// Contact names the dictionary does not know. A contact's "Will" or "Grace" is left to the
    /// dictionary, which offers it lowercase: a contact card never capitalizes an everyday word.
    private var nameCompletions: [(key: String, display: String)] = []
    /// At most this many of the row's slots go to the person's own words and contacts.
    static let maxOwnCompletions = 2
    static let minimumOwnPrefix = 2
    /// Contacts can run to thousands of names, so two letters matched one for nearly every
    /// prefix and pushed "the" and "that" out of the row. They wait for a third letter and take
    /// one slot.
    static let minimumNamePrefix = 3
    static let maxNameCompletions = 1

    private static func completionIndex(_ words: [String]) -> [(key: String, display: String)] {
        var table: [String: String] = [:]
        for phrase in words {
            for part in phrase.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "\u{2019}" }) {
                let word = TypingEdits.normalized(String(part))
                guard word.count > minimumOwnPrefix, let key = WordList.foldedKey(word) else { continue }
                // The first spelling saved wins, as in the list the person sees.
                let lower = String(decoding: key, as: UTF8.self)
                if table[lower] == nil { table[lower] = word }
            }
        }
        return table.map { (key: $0.key, display: $0.value) }.sorted { $0.key < $1.key }
    }

    /// Entries of a sorted index that start with `lower` and are longer than it, shortest first.
    private static func matches(_ lower: String, in index: [(key: String, display: String)], limit: Int) -> [(key: String, display: String)] {
        var low = 0
        var high = index.count
        while low < high {
            let mid = (low + high) / 2
            if index[mid].key < lower { low = mid + 1 } else { high = mid }
        }
        var found: [(key: String, display: String)] = []
        while low < index.count, index[low].key.hasPrefix(lower) {
            if index[low].key.count > lower.count { found.append(index[low]) }
            low += 1
        }
        return Array(found.sorted { ($0.key.count, $0.key) < ($1.key.count, $1.key) }.prefix(limit))
    }

    /// The person's own words first, then a contact name, at most `maxOwnCompletions` in all.
    private func ownCompletions(of lower: String) -> [String] {
        guard lower.count >= Self.minimumOwnPrefix else { return [] }
        var found = Self.matches(lower, in: ownCompletions, limit: Self.maxOwnCompletions)
        if found.count < Self.maxOwnCompletions, lower.count >= Self.minimumNamePrefix {
            let saved = Set(found.map(\.key))
            found += Self.matches(lower, in: nameCompletions, limit: Self.maxNameCompletions + saved.count)
                .filter { !saved.contains($0.key) }
                .prefix(min(Self.maxNameCompletions, Self.maxOwnCompletions - found.count))
        }
        return found.map(\.display)
    }

    private func protectedKeys(_ words: [String]) -> Set<String> {
        // Autocorrect evaluates individual words, so a phrase must protect each of its words.
        // A contraction missing its apostrophe ("thats") is never protected: earlier builds saved
        // one as a personal word when a selected typo was retyped, which then blocked "that's"
        // for good. Skipping it here repairs those dictionaries without editing them.
        Set(words.flatMap { phrase in
            phrase.split { !$0.isLetter && $0 != "'" && $0 != "’" }.compactMap { word in
                WordList.foldedKey(String(word)).map { String(decoding: $0, as: UTF8.self) }
            }
        }).filter { !isBareContraction($0) }
    }

    /// An ordinary dictionary word that is written in lowercase ("the", "will"), whatever case
    /// it was just typed in. Such a word needs no place in the person's own words, and saving
    /// it with a sentence-start capital would capitalize it everywhere it is later dictated.
    public func isEverydayWord(_ word: String) -> Bool {
        guard let key = WordList.foldedKey(word) else { return false }
        let lower = String(decoding: key, as: UTF8.self)
        return words.lookup(lower)?.display == lower
    }

    /// "thats", "theyll", "hows": a contraction typed without its apostrophe, which autocorrect
    /// writes with it. Such a spelling is a typing shortcut, not a word to learn or protect.
    public func isBareContraction(_ word: String) -> Bool {
        guard let key = WordList.foldedKey(word) else { return false }
        let lower = String(decoding: key, as: UTF8.self)
        if let override = Self.overrides[lower] {
            return override.contains("'") && override.lowercased().replacingOccurrences(of: "'", with: "") == lower
        }
        return words.contraction(forBare: lower)?.isSuggestible == true
    }

    /// Contact names from the system lexicon (`UILexicon`), lowercase to their own spelling, and
    /// the user's text replacements, lowercase shortcut to phrase.
    private var systemNames: [String: String] = [:]
    private var textReplacements: [String: String] = [:]

    /// The system's supplementary lexicon: `names` are contact first and last names (an unknown
    /// word that is one stays, recased to the contact's spelling; a dictionary word is never
    /// touched, so a contact called Will does not capitalize "will"); `replacements` are the
    /// user's text replacements, shortcut to phrase, applied as iOS applies them.
    public func setSystemLexicon(names: [String], replacements: [String: String]) {
        var table: [String: String] = [:]
        for name in names {
            for part in name.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "\u{2019}" }) {
                let word = TypingEdits.normalized(String(part))
                guard word.count >= 2, let key = WordList.foldedKey(word) else { continue }
                table[String(decoding: key, as: UTF8.self)] = word
            }
        }
        systemNames = table
        nameCompletions = table.filter { $0.key.count > Self.minimumOwnPrefix && words.lookup($0.key) == nil }
            .map { (key: $0.key, display: $0.value) }.sorted { $0.key < $1.key }
        var shortcuts: [String: String] = [:]
        for (shortcut, phrase) in replacements {
            guard !phrase.isEmpty, let key = WordList.foldedKey(TypingEdits.normalized(shortcut)), !key.isEmpty else { continue }
            shortcuts[String(decoding: key, as: UTF8.self)] = phrase
        }
        textReplacements = shortcuts
        memo = nil
    }

    /// Apple's spell checker (`UITextChecker` in the keyboard): true when the system dictionary
    /// knows the word. Zone's list is 77k words; Apple's is about 200k, and half of its 3,000
    /// commonest words Zone lacks were being "fixed" (meds to mess, donut to don't, cancelled to
    /// canceled, gameplay to game play). A word only Apple knows is kept: its corrections still
    /// show in the strip, but space no longer applies one. Nil (tests, other platforms) skips it.
    public var systemAccepts: ((String) -> Bool)? {
        didSet { memo = nil }
    }

    /// The letters right above the space bar, which a thumb that stops short of it types in place
    /// of a space. The keyboard sets them from its layout (`KeyGridGeometry.keys(above:)`): x to
    /// n beside 123 and globe or emoji, z to n beside 123 alone.
    public var spaceBarLetters: Set<Character> = Autocorrector.defaultSpaceBarLetters {
        didSet { memo = nil }
    }

    /// Above the space bar beside 123 and globe (or emoji), iOS 26 on a 393 to 402 pt phone.
    public static let defaultSpaceBarLetters: Set<Character> = ["x", "c", "v", "b", "n"]

    static let oneLetterWords: Set<String> = ["a", "i"]

    /// Apple's spelling guesses for a word neither dictionary knows (`UITextChecker` in the
    /// keyboard), best first. Zone's own two candidates keep the first two places and the
    /// automatic decision; one Apple guess the row does not already show takes the last place.
    /// Measured on the 345 audit cases (2026-11-14): no intended answer lost, donuut, glitchyy,
    /// backemd and medss gained. Never applied by space. Nil (tests, other platforms) skips it.
    public var systemGuesses: ((String) -> [String])? {
        didSet { memo = nil }
    }

    /// Apple's completions for a prefix Zone's list has none for ("donu"). Shown, never applied.
    public var systemCompletions: ((String) -> [String])? {
        didSet { memo = nil }
    }

    /// How many of Apple's guesses are considered for the one place.
    static let systemGuessDepth = 2

    /// Typos Apple's dictionary lists as words, so its checker would wrongly vouch for them.
    /// Measured on `TypoEvaluationSet` against UITextChecker on iOS 26.2 (2026-11-08).
    static let systemTypos: Set<String> = ["agin", "kist", "hwy", "yesh", "oaky", "whaat"]

    /// Apple's checker vouches for a word Zone's list does not have.
    private func systemKnows(_ lower: String, typed: String, casing: Casing, autoCapitalized: Bool) -> Bool {
        guard let systemAccepts, lower.count >= Self.minimumCorrectedLength, !Self.systemTypos.contains(lower) else { return false }
        // A capital the user typed is asked about as typed ("Snapchat"); otherwise lowercase.
        return systemAccepts(casing == .capitalized && !autoCapitalized ? typed : lower)
    }

    /// How likely each word is after the one before it: the table swipe typing already ships
    /// (`en-pairs.bin`). With it and a previous word, the candidates for an unknown word are
    /// ranked by how often each follows that word instead of by how common each is anywhere, so
    /// "i lovr" reads as "love" and "the lovr" does not. Nil, or no previous word, ranks exactly
    /// as before. A word the keyboard already accepts is never changed by it.
    public var context: WordPairs? {
        didSet { memo = nil }
    }

    /// What following `previousIndex` adds to a candidate's score: its cost after that word less
    /// its cost anywhere, in nats, on the scale of the frequency term (`frequencyWeight` per
    /// decade is `frequencyWeight / ln 10` per nat), so the pair replaces the plain frequency
    /// instead of counting twice. `entryIndex` nil (two words, a possessive) pays what a pair the
    /// table never saw pays. Clamped, so one pair cannot outvote the taps.
    private func contextShift(entryIndex: Int?, previousIndex: Int?) -> Float {
        guard let context, let previousIndex, context.knows(previous: previousIndex) else { return 0 }
        let delta: Float
        if let entryIndex, let cost = context.cost(of: entryIndex, after: previousIndex) {
            delta = cost - context.unigramCost(of: entryIndex)
        } else {
            delta = context.backoff(after: previousIndex)
        }
        return Self.contextWeight * min(max(delta, -Self.contextClamp), Self.contextClamp)
    }

    static let contextWeight: Float = frequencyWeight / 2.302585
    static let contextClamp: Float = 4

    public init(words: WordList, learnedWords: Set<String> = []) {
        self.words = words
        // Kept words are matched by their folded spelling. The store keeps a word with inner
        // capitals as typed ("OpenRouter", for swipe), and older entries were lowercased only.
        self.learnedWords = Set(learnedWords.compactMap { WordList.foldedKey($0).map { String(decoding: $0, as: UTF8.self) } })
        // Built-in words are protected and the built-in names recased before any personal words
        // load, and on a keyboard without Full Access, where they never do.
        setPersonalWords([])
    }

    /// The last answer. A keystroke asks about the same word up to three times (the key, the host's
    /// text-change callback, then space), so it is computed once.
    private var memo: Evaluation?
    private var memoAutoCapitalized = false
    private var memoPreserveLowercase = false
    private var memoTouches: [KeyTouch]?
    private var memoPrevious: String?

    /// True when the word is one the keyboard knows: in the dictionary, learned, personal, or a
    /// contact's name. Only such a word may teach the learned touch offsets: a run kept because
    /// nothing could read it ("lotvinstead") holds a space typed as v, and learning that v lands
    /// low on its key moves v's target onto the space bar, which turns more spaces into v.
    public func recognizes(_ word: String) -> Bool {
        guard let key = WordList.foldedKey(word) else { return false }
        let lower = String(decoding: key, as: UTF8.self)
        return learnedWords.contains(lower) || personalWords.contains(lower) || systemNames[lower] != nil ||
            dictionaryForm(of: lower) != nil ||
            (!Self.systemTypos.contains(lower) && lower.count >= Self.minimumCorrectedLength && systemAccepts?(lower) == true)
    }

    public func learn(_ word: String) {
        guard let key = WordList.foldedKey(word) else { return }
        learnedWords.insert(String(decoding: key, as: UTF8.self))
        memo = nil
    }

    // MARK: Evaluation

    /// - Parameters:
    ///   - autoCapitalized: the first letter is a capital only because the keyboard shifted at
    ///     a sentence start. Such a word is judged like a lowercase one, so "Ehat" at the start
    ///     of a sentence is fixed exactly as "ehat" is mid-sentence.
    ///   - preserveLowercase: keep corrections and completions lowercase for lowercase input.
    ///     Deliberate capitals and user-authored text replacements retain their formatting.
    ///   - touches: where each letter's tap landed on its key, letter for letter (see
    ///     `KeyTouch`). A tap near the boundary with another key makes reading it as that key
    ///     cheap; nil, or a count that does not match the word, means no touch evidence.
    ///   - previous: the word this one follows in the same sentence (`SwipeSpacing.previousWord`),
    ///     or nil at a sentence start or when the keyboard cannot tell. Used only with `context`.
    public func evaluate(_ typed: String, autoCapitalized: Bool = false, touches: [KeyTouch]? = nil, preserveLowercase: Bool = false,
                         previous: String? = nil) -> Evaluation {
        let touches = touches.flatMap { $0.count == typed.utf8.count ? $0 : nil }
        let previous = context == nil ? nil : previous
        if let memo, memo.typed == typed, memoAutoCapitalized == autoCapitalized, memoTouches == touches,
           memoPreserveLowercase == preserveLowercase, memoPrevious == previous { return memo }
        var evaluation = computeEvaluation(typed, autoCapitalized: autoCapitalized, touches: touches, previous: previous)
        // The dictionary supplies spellings, not permission to override a lowercase preference.
        // Explicit text replacements are authored phrases and keep their intended formatting.
        let key = WordList.foldedKey(typed).map { String(decoding: $0, as: UTF8.self) }
        let authoredPhrase = key.flatMap { textReplacements[$0] }
        if preserveLowercase, Casing(of: typed) == .lower {
            var seen = Set<String>()
            let dependsOnPrevious = evaluation.dependsOnPrevious
            evaluation = Evaluation(typed: typed, suggestions: evaluation.suggestions.compactMap { suggestion in
                let text = suggestion.kind == .literal || suggestion.text == authoredPhrase
                    ? suggestion.text : suggestion.text.lowercased()
                guard seen.insert(text).inserted else { return nil }
                return Suggestion(text: text, kind: suggestion.kind,
                                  autoApplies: suggestion.autoApplies && text != typed)
            }, dependsOnPrevious: dependsOnPrevious)
        }
        memo = evaluation
        memoAutoCapitalized = autoCapitalized
        memoPreserveLowercase = preserveLowercase
        memoTouches = touches
        memoPrevious = previous
        return evaluation
    }

    /// One ranked alternative to the typed word: a dictionary neighbour or two words.
    struct Candidate {
        var text: String
        var cost: Float
        var rank: Int
        var length: Int
        var isSplit = false
        var firstLetterMatches: Bool
        var startsLowercase: Bool
        /// One of the person's own words (`ownNeighbors`).
        var isOwn = false
        /// The first word's entry, for the previous-word term; nil when it is not one list entry.
        var entryIndex: Int?
        /// What following the previous word adds to the score (`contextShift`); 0 without one.
        var context: Float = 0

        /// Lower is better: edit cost plus a gentle frequency term, with a nudge for keeping
        /// the first letter.
        var score: Float {
            cost + Autocorrector.frequencyWeight * log10(Float(rank) + 10) - (firstLetterMatches ? Autocorrector.firstLetterBonus : 0) + context
        }
    }

    /// Neighbors ranked per word. More (16, 24) only adds near-ties that block clear leads
    ///.
    static let candidateLimit = 8
    static let frequencyWeight: Float = 0.4
    static let firstLetterBonus: Float = 0.05
    /// Searched up to two edits for any word of three letters or more.
    static let maxSearchCost: Float = 2.0
    /// A candidate this cheap leads on geometry alone when the next one costs clearly more.
    static let geometryLeadCost: Float = 1.0
    static let requiredMargin: Float = 0.2
    /// ...and costs at least this much less than the runner-up, it needs only this score margin.
    static let geometryGap: Float = 0.15
    static let geometryMargin: Float = 0.1
    /// Two-letter words change only when a tap sat this close to the intended key.
    static let twoLetterMaximumCost: Float = 0.6
    /// The rarest two-letter word a tap may be read as. "we" sits at 532; the old limit of 500
    /// left it out, so "wr" typed with the tap on the e side of r was never fixed. "la" (549) is not one.
    static let twoLetterMaximumRank = 540
    /// Three to five letter words take two slips only when both were near keys and the word is common.
    static let shortTwoEditMaximumCost: Float = 1.45
    static let shortTwoEditMaximumRank = 2_000

    private func computeEvaluation(_ typed: String, autoCapitalized: Bool, touches: [KeyTouch]?, previous: String? = nil) -> Evaluation {
        completionPreviousIndex = context == nil ? nil : previous.flatMap { words.lookup($0)?.index }
        defer { completionPreviousIndex = nil }
        return evaluateWord(typed, autoCapitalized: autoCapitalized, touches: touches, previous: previous)
    }

    private func evaluateWord(_ typed: String, autoCapitalized: Bool, touches: [KeyTouch]?, previous: String?) -> Evaluation {
        guard let key = WordList.foldedKey(typed) else {
            return Evaluation(typed: typed, suggestions: [])
        }
        let lower = String(decoding: key, as: UTF8.self)
        let casing = Casing(of: typed)

        // A current name typed in lowercase takes its capitals ("reddit" is Reddit, "chatgpt" is
        // ChatGPT), unless the person kept or saved the word their own way.
        // A word only the built-in supplement knows ("matson", a surname) is still a slip in the
        // person's own word ("Mattson") one key away: their word wins over the built-in one.
        if !ownCorrections.isEmpty, !ownWords.contains(lower), !learnedWords.contains(lower),
           textReplacements[lower] == nil, words.lookup(lower) == nil,
           ModernVocabulary.names[lower] != nil || personalWords.contains(lower),
           let own = ownNeighbors(of: key, touches: touches).min(by: { $0.cost < $1.cost }) {
            return corrected(typed, to: own.text, lower: lower, casing: casing)
        }
        if casing == .lower, !learnedWords.contains(lower), !ownWords.contains(lower),
           textReplacements[lower] == nil, let name = ModernVocabulary.names[lower] {
            return corrected(typed, to: name, lower: lower, casing: casing)
        }
        if casing == .lower, !learnedWords.contains(lower), textReplacements[lower] == nil, let saved = ownSpellings[lower] {
            return corrected(typed, to: saved, lower: lower, casing: casing)
        }
        // A word the person kept or saved is theirs as typed, even over a shortcut on it.
        if learnedWords.contains(lower) || ownWords.contains(lower) {
            return accepted(typed, lower: lower, casing: casing)
        }
        // Their iPhone text replacements come next, before the words Zone ships with: an "ily"
        // shortcut expands as it does on Apple's keyboard, though "ily" is also a modern word.
        if let phrase = textReplacements[lower], phrase != typed {
            // "a" and "i" are words: a shortcut on one is offered, never applied by space.
            if Self.oneLetterWords.contains(lower) {
                let offer = Suggestion(text: phrase, kind: .correction, autoApplies: false)
                return Evaluation(typed: typed, suggestions: [literal(typed), offer])
            }
            return corrected(typed, to: phrase, lower: lower, casing: casing)
        }
        if personalWords.contains(lower) {
            return accepted(typed, lower: lower, casing: casing)
        }
        if let override = Self.overrides[lower] {
            return corrected(typed, to: Self.cased(override, like: casing), lower: lower, casing: casing)
        }
        let judgedLower = casing == .lower || (casing == .capitalized && autoCapitalized)
        if judgedLower, let fix = shortWordSlip(lower, touches: touches) {
            return corrected(typed, to: Self.cased(fix, like: casing), lower: lower, casing: casing)
        }
        if let match = dictionaryForm(of: lower) {
            if judgedLower, let fix = commonWordBehindAbbreviation(lower, form: match, touches: touches) {
                return corrected(typed, to: Self.cased(fix, like: casing), lower: lower, casing: casing)
            }
            if casing == .lower, match != lower, match.count >= Self.minimumCorrectedLength,
               words.lookup(lower).map({ $0.rank < 10_000 }) ?? false {
                return corrected(typed, to: match, lower: lower, casing: casing)
            }
            // A rarer proper noun is recased only when it is one of the user's contacts.
            if casing == .lower, match != lower, let name = systemNames[lower] {
                return corrected(typed, to: name, lower: lower, casing: casing)
            }
            return accepted(typed, lower: lower, casing: casing)
        }

        // Unknown word. Acronyms and deliberate mixed case are left alone.
        if casing == .mixed || (casing == .upper && lower.count > 1) {
            return Evaluation(typed: typed, suggestions: [literal(typed)])
        }
        // A contact's name is a word here: kept, and written the way the contact is.
        if let name = systemNames[lower] {
            let fix = casing == .lower ? name : Self.cased(name, like: casing)
            return fix == typed ? accepted(typed, lower: lower, casing: casing) : corrected(typed, to: fix, lower: lower, casing: casing)
        }
        // "theyll", "wouldve": a contraction missing only its apostrophe.
        if let contraction = words.contraction(forBare: lower), contraction.isSuggestible {
            return corrected(typed, to: Self.cased(contraction.display, like: casing), lower: lower, casing: casing)
        }
        // "carefull", "helpfull", "usefull": the suffix is -ful. Without this the two words
        // "care full" outrank "careful", and "careful" ties with "carefully" and nothing is fixed.
        if lower.count >= 6, lower.hasSuffix("full"), let word = words.lookup(String(lower.dropLast())),
           word.isSuggestible, word.display.first?.isLowercase == true {
            return corrected(typed, to: Self.cased(word.display, like: casing), lower: lower, casing: casing)
        }
        // "sooo", "yesss", "damnnn": a word drawn out on its last letter is meant that way. The
        // plain word is offered, never applied ("sooo" used to become "soon", "gooo" "good").
        if let plain = drawnOutWord(lower, touches: touches) {
            let offer = Suggestion(text: Self.cased(plain, like: casing), kind: .correction)
            return Evaluation(typed: typed, suggestions: fill([literal(typed), offer], lower: lower, casing: casing))
        }
        let vouched = systemKnows(lower, typed: typed, casing: casing, autoCapitalized: autoCapitalized)
        let maxCost: Float = lower.count >= 3 ? Self.maxSearchCost : Self.confidentCost
        var ranked = words.neighbors(of: lower, maxCost: maxCost, limit: Self.candidateLimit, touches: touches).map { neighbor in
            // A slip that lands on "cant" or "wont" means the contraction, as typing them does.
            let override = Self.overrides[neighbor.entry.display]
            let entry = override.map { words.lookup($0) } ?? neighbor.entry
            return Candidate(text: override ?? neighbor.entry.display,
                      cost: neighbor.cost, rank: override.flatMap { words.lookup($0)?.rank } ?? neighbor.entry.rank,
                      length: neighbor.entry.display.count,
                      firstLetterMatches: neighbor.entry.display.utf8.first.map { ($0 | 0x20) == key[0] } ?? false,
                      startsLowercase: neighbor.entry.display.first?.isLowercase == true,
                      entryIndex: entry?.index)
        }
        ranked += ownNeighbors(of: key, touches: touches)
        ranked += modernNeighbors(of: key, touches: touches)
        if let split = bestSplit(lower, touches: touches) { ranked.append(split) }
        if let possessive = possessiveCandidate(lower) { ranked.append(possessive) }
        if context != nil, let previousIndex = previous.flatMap({ words.lookup($0)?.index }) {
            for i in ranked.indices {
                ranked[i].context = contextShift(entryIndex: ranked[i].entryIndex, previousIndex: previousIndex)
            }
        }
        ranked.sort { $0.score < $1.score }
        // A slip onto a bare contraction ("whats", overridden to "what's") and the contraction's
        // own entry are one reading. Keeping both lets the copy pose as a distant runner-up, which
        // hides the real alternative ("what a") and fakes a confident margin.
        var seen = Set<String>()
        ranked = ranked.filter { seen.insert($0.text.lowercased()).inserted }

        var suggestions = [literal(typed)]
        for (offset, candidate) in ranked.prefix(2).enumerated() {
            // Word frequency alone cannot distinguish equally plausible corrections. Keep the
            // literal when the next candidate is close, especially with suggestions hidden.
            let runnerUp = ranked.dropFirst().first
            let margin = runnerUp.map { $0.score - candidate.score } ?? .infinity
            // A clear keyboard-geometry advantage can break a close frequency ranking:
            // adjacent-key "whst" -> "what" beats the nonadjacent alternative "west".
            // Equally close alternatives such as hello/cello still require the normal margin.
            let geometryLead = candidate.cost <= Self.geometryLeadCost &&
                runnerUp.map { $0.cost - candidate.cost >= Self.geometryGap } == true
            let hasClearLead = margin >= Self.requiredMargin || (geometryLead && margin >= Self.geometryMargin)
            let preservesCapitalizedWord = casing != .capitalized || autoCapitalized || candidate.isSplit || candidate.isOwn ||
                (candidate.cost <= Self.geometryLeadCost && candidate.startsLowercase &&
                 candidate.text.lowercased().first == lower.first)
            let auto = offset == 0 && !vouched && hasClearLead && preservesCapitalizedWord &&
                shouldAutoApply(candidate, typedLength: lower.count)
            suggestions.append(Suggestion(text: Self.cased(candidate.text, like: casing), kind: .correction, autoApplies: auto))
        }
        if !vouched, let guess = systemGuess(for: lower, casing: casing, shown: suggestions) {
            if suggestions.count < Self.maxSuggestions {
                suggestions.append(guess)
            } else if let last = suggestions.last, last.kind == .correction, !last.autoApplies {
                suggestions[suggestions.count - 1] = guess
            }
        }
        return Evaluation(typed: typed, suggestions: fill(suggestions, lower: lower, casing: casing), dependsOnPrevious: context != nil)
    }

    /// The word behind one whose last letter is held for three or more ("sooo" is "so", "yesss"
    /// "yes", "lmaooo" "lmao"), or nil. Only the end of a word: a run in the middle ("toook") is
    /// a key pressed too often, and the usual search fixes it. So is exactly one letter too many
    /// on a common word that ends in a double ("willl", "seee", "tooo"): fast thumbs do that, and
    /// the typing simulation loses words if those are kept. So is a run made by one tap on
    /// the key beside the right one: "theee" is "there" and "weee" is "were" (r beside e), a
    /// common word of the same length one neighbouring key away.
    private func drawnOutWord(_ lower: String, touches: [KeyTouch]?) -> String? {
        let letters = Array(lower)
        guard letters.count >= 4, let last = letters.last, last.isLetter else { return nil }
        let run = letters.reversed().prefix { $0 == last }.count
        guard run >= 3 else { return nil }
        let stem = String(letters.dropLast(run))
        let single = stem + String(last), double = single + String(last)
        func known(_ word: String) -> String? {
            guard word.count >= 2 else { return nil }
            return dictionaryForm(of: word) ?? (personalWords.contains(word) ? word : nil)
        }
        if let entry = words.lookup(double), entry.rank < Self.drawnOutDoubleMaximumRank {
            return run == 3 ? nil : entry.display
        }
        guard let plain = known(single) ?? known(double) else { return nil }
        let slip = words.neighbors(of: lower, maxCost: EditCost.adjacentSubstitution, limit: 4, touches: touches).contains {
            $0.entry.display.count == letters.count && $0.entry.rank < Self.drawnOutDoubleMaximumRank
        }
        return slip ? nil : plain
    }

    /// A word ending in a double letter this common ("will", "see", "too") is the likelier
    /// reading of one more of that letter; a rarer one ("goo" for "gooo") is not.
    static let drawnOutDoubleMaximumRank = 3_000

    /// The first of Apple's leading guesses the row does not already show.
    private func systemGuess(for lower: String, casing: Casing, shown: [Suggestion]) -> Suggestion? {
        guard let systemGuesses, lower.count >= Self.minimumCorrectedLength,
              !Self.systemTypos.contains(lower) else { return nil }
        let taken = Set(shown.map { $0.text.lowercased() })
        for guess in systemGuesses(lower).prefix(Self.systemGuessDepth) {
            let key = guess.lowercased()
            guard !guess.isEmpty, key != lower, !taken.contains(key) else { continue }
            let text = guess == key ? Self.cased(guess, like: casing) : guess
            return Suggestion(text: text, kind: .correction, autoApplies: false)
        }
        return nil
    }

    /// A lowercase word that is in the list only as an abbreviation or symbol ("amd" as AMD,
    /// "si" as Si) is far more often one slip from a very common word ("and", "is"). Corrected
    /// only to a word at least fifty times as common and one cheap edit away, and only when no
    /// other common word is just as close ("ne" could be "me" or "be").
    private func commonWordBehindAbbreviation(_ lower: String, form: String, touches: [KeyTouch]?) -> String? {
        guard form != lower, form.lowercased() == lower, !lower.contains("'"),
              let entry = words.lookup(lower) else { return nil }
        let candidates = words.neighbors(of: lower, maxCost: 0.75, limit: 6, touches: touches).filter {
            $0.entry.display.first?.isLowercase == true &&
                $0.entry.display.count >= min(lower.count, Self.minimumCorrectedLength) &&
                $0.entry.rank < 1_000 && $0.entry.rank * 50 < entry.rank
        }
        guard let best = candidates.first else { return nil }
        if candidates.count > 1, candidates[1].cost - best.cost < 0.1 { return nil }
        return best.entry.display
    }

    /// Two- and three-letter slips the general search cannot settle, because every reading of a
    /// two-letter token is equally short:
    /// - a doubled first key on a very common word ("tto", "sso", "mme", "ii"), when the typed
    ///   form is not itself an ordinary lowercase word ("too", "all", "ass" stay); a doubled last
    ///   letter is a name or a drawn-out word ("ann", "ohh", "noo") and stays;
    /// - two letters registered in the wrong order by alternating thumbs ("ot", "si", "em"), only
    ///   with touch evidence, and only when no tap sat near the edge of a key that would make a
    ///   common word by itself (a tap on i near o in "si" means "so", and the general rules decide).
    func shortWordSlip(_ lower: String, touches: [KeyTouch]?) -> String? {
        let key = Array(lower.utf8)
        guard key.count == 2 || key.count == 3, !key.contains(0x27) else { return nil }
        var collapsed: String?
        if key.count == 3, key[0] == key[1] {
            collapsed = String(lower.dropFirst())
        } else if key.count == 2, key[0] == key[1] {
            collapsed = String(lower.prefix(1))
        }
        if let collapsed, let target = words.lookup(collapsed), target.isSuggestible, target.rank < Self.doubledKeyMaximumRank,
           words.lookup(lower).map({ $0.display != lower }) ?? true {
            return target.display
        }
        guard key.count == 2, let touches, touches.count == 2, let fix = Self.swappedTwoLetterWords[lower] else { return nil }
        for position in 0..<2 {
            for letter in UInt8(ascii: "a")...UInt8(ascii: "z") where letter != key[position] {
                var other = key
                other[position] = letter
                guard let word = words.lookup(String(decoding: other, as: UTF8.self)), word.rank < Self.swapRivalMaximumRank,
                      word.display.first?.isLowercase == true || word.display == "I" else { continue }
                if KeyboardProximity.substitutionCost(typed: key[position], as: letter, touch: touches[position]) <= Self.swapRivalCost {
                    return nil
                }
            }
        }
        return fix
    }

    static let doubledKeyMaximumRank = 300
    /// A one-key reading of a swapped pair wins when its tap sat this close to the other key.
    static let swapRivalCost: Float = 0.3
    static let swapRivalMaximumRank = 500
    /// Two-letter tokens that are, in typing, almost always a very common word with its letters
    /// in the wrong order. Chat words (ma, eh, ew, ah, na, ya, yo) are deliberately absent.
    static let swappedTwoLetterWords: [String: String] = [
        "ot": "to", "fo": "of", "si": "is", "ti": "it", "ni": "in", "ta": "at", "em": "me", "eb": "be",
        "os": "so", "yb": "by", "fi": "if", "ym": "my", "pu": "up", "su": "us", "ro": "or", "od": "do",
        "og": "go",
    ]

    /// "womens", "patsys": a possessive typed without its apostrophe, which sits on another
    /// layer. Only for stems that cannot take a plain plural s (names, and plurals without one),
    /// so "dads" and "emails" are never touched.
    func possessiveCandidate(_ lower: String) -> Candidate? {
        guard lower.count >= 4, lower.hasSuffix("s"), !lower.contains("'"),
              let entry = words.lookup(String(lower.dropLast())), entry.isSuggestible else { return nil }
        let display = entry.display
        let isName = display != "I" && display.first?.isUppercase == true && display.dropFirst().allSatisfy { $0.isLowercase }
        guard isName || Self.pluralsWithoutS.contains(display) else { return nil }
        let text = display + "'s"
        return Candidate(text: text, cost: EditCost.apostrophe, rank: entry.rank, length: text.count,
                         firstLetterMatches: true, startsLowercase: display.first?.isLowercase == true)
    }

    static let pluralsWithoutS: Set<String> = ["women", "men", "children", "people"]

    /// The best reading of an unknown word as two or more words: fused ("thisis"), or with keys
    /// right above the space bar typed in place of spaces ("inbthe", "lotvinstead",
    /// "youxarexproud"). Fused parts must be common words. Beside a slipped space the key itself
    /// is the evidence, so a part may be rarer, a common name ("inbhouston"), or, from four
    /// letters, one or two cheap slips from a common word ("incestigstecthus"). Where the slipped
    /// key was tapped weighs in too (`slipTouchCost`): "youcare" tapped low on c is "you are",
    /// tapped on c's center "you care".
    func bestSplit(_ lower: String, touches: [KeyTouch]? = nil) -> Candidate? {
        let letters = Array(lower)
        let n = letters.count
        guard n >= 3, n <= WordList.maxWordLength else { return nil }
        let touches = touches?.count == n ? touches : nil

        struct Part {
            var display: String
            var rank: Int
            /// Number of consumed input characters, which may omit an apostrophe.
            var inputLength: Int
            /// Edit cost of reading the typed letters as this word; 0 when typed exactly.
            var cost: Float = 0
            var hasLetterEdits = false
            /// A misspelled part of four or five letters, which is believable only beside very
            /// common words ("homexmske" is "home make").
            var isShortFuzzy = false
            var explicitlyTypedRestrictedWord = false
        }
        enum Side { case edge, fused, slip }
        var searchEnd = n

        func exact(_ i: Int, _ j: Int, names: Bool) -> Part? {
            let characters = letters[i..<j]
            let text = String(characters)
            // An apostrophe only inside a part ("i'mglad", not "glad'").
            guard characters.count >= 2 || text == "a" || text == "i",
                  characters.first != "'", characters.last != "'",
                  // "st", "ms": abbreviations the list ranks as words are never a part.
                  characters.contains(where: { Self.vowels.contains($0) }) else { return nil }
            // The same omitted-apostrophe spelling accepted as a standalone word must also
            // work beside a missing space. Do not reinterpret a personal spelling or turn a
            // real-word ambiguity (well/we'll, were/we're) into an automatic contraction.
            let protected = learnedWords.contains(text) || personalWords.contains(text) || systemNames[text] != nil
            let override = protected ? nil : Self.overrides[text].flatMap { fix in
                fix.contains("'") && fix.replacingOccurrences(of: "'", with: "").lowercased() == text ? fix : nil
            }
            let contraction = protected ? nil : words.contraction(forBare: text)
            // Standalone overrides include contractions absent from the bundled dictionary
            // (he's, she's). Read the same deliberate spelling inside a phrase, using its
            // ordinary stem's frequency rather than requiring a missing dictionary entry.
            let explicit = Self.overrides[text.replacingOccurrences(of: "'", with: "")]
            let canonical = override ?? (explicit == text ? explicit : nil)
            if let canonical, (!protected || canonical == text), canonical.contains("'"), words.lookup(canonical) == nil,
               let stem = canonical.split(separator: "'").first,
               let base = words.lookup(String(stem)), base.isSuggestible, base.rank < Self.splitMaximumRank {
                return Part(display: canonical, rank: max(base.rank, 100), inputLength: characters.count,
                            cost: text == canonical ? 0 : EditCost.apostrophe)
            }
            let entry = override.flatMap { words.lookup($0) } ?? words.lookup(text) ?? contraction
            // A no-suggest word deliberately typed in full beside a slipped space is not
            // an invented suggestion. Keep fuzzy and fused-word filtering unchanged.
            guard let entry, entry.isSuggestible || (names && entry.display.lowercased() == text) else { return nil }
            let display = entry.display
            let restoredApostrophe = display.contains("'") && !text.contains("'") &&
                display.replacingOccurrences(of: "'", with: "").lowercased() == text
            // Bare contractions are already supported standalone. Their dictionary ranks can
            // be lower than the ordinary split vocabulary; still require a common neighbor.
            let maximumRank = restoredApostrophe ? Self.twoEditMaximumRank :
                (characters.count == 2 ? Self.splitTwoLetterMaximumRank : Self.splitRareMaximumRank)
            guard entry.rank < maximumRank else { return nil }
            if restoredApostrophe {
                return Part(display: display, rank: entry.rank, inputLength: characters.count, cost: EditCost.apostrophe)
            }
            if display == text || display == "I" || (display.hasPrefix("I'") && display.lowercased() == text) {
                return Part(display: display, rank: entry.rank, inputLength: characters.count,
                            explicitlyTypedRestrictedWord: !entry.isSuggestible)
            }
            // A common name beside a slipped space keeps its capital ("in Houston").
            if names, entry.rank < Self.splitMaximumRank, display.count >= 3, display.first?.isUppercase == true,
               display.dropFirst().allSatisfy({ $0.isLowercase }), display.lowercased() == text {
                return Part(display: display, rank: entry.rank, inputLength: characters.count)
            }
            return nil
        }
        var fuzzyMemo: [Int: Part?] = [:]
        func fuzzy(_ i: Int, _ j: Int) -> Part? {
            let length = j - i
            let short = length < Self.slipFuzzyMinimumLength
            guard length >= Self.shortSlipFuzzyMinimumLength, i == 0 || j == n else { return nil }
            if let hit = fuzzyMemo[i * 32 + j] { return hit }
            let text = String(letters[i..<j])
            // A word typed exactly ("lately") is that word, however rare.
            guard words.lookup(text) == nil else {
                fuzzyMemo[i * 32 + j] = .some(nil)
                return nil
            }
            // Four or five letters take one near-key slip onto a very common word of the same
            // length ("mske" is "make"); longer parts may be further off.
            let maxCost = short ? Self.shortSlipFuzzyCost : length >= Self.twoEditMinimumLength ? Self.slipFuzzyLongCost : Self.slipFuzzyCost
            let part = words.neighbors(of: text, maxCost: maxCost, limit: 3).first { neighbor in
                let display = neighbor.entry.display
                guard neighbor.entry.isSuggestible, display.first?.isLowercase == true, display.first == letters[i],
                      !display.contains("'") else { return false }
                if short {
                    return neighbor.entry.rank < Self.spaceSlipCommonRank && display.count == length
                }
                return neighbor.entry.rank < Self.slipFuzzyMaximumRank &&
                    display.count >= Self.slipFuzzyMinimumLength && abs(display.count - length) <= 1
            }.map { Part(display: $0.entry.display, rank: $0.entry.rank, inputLength: length, cost: $0.cost,
                         hasLetterEdits: true, isShortFuzzy: short) }
            fuzzyMemo[i * 32 + j] = .some(part)
            return part
        }
        /// A part between two boundaries. Next to a fused boundary only an exact, ordinary word
        /// will do; a part with a slipped space on one side and nothing fused may be fuzzy.
        func parts(_ i: Int, _ j: Int, left: Side, right: Side) -> [Part] {
            let fused = left == .fused || right == .fused
            let slipped = left == .slip || right == .slip
            if let word = exact(i, j, names: slipped && !fused) { return [word] }
            guard slipped, !fused, let word = fuzzy(i, j) else { return [] }
            return [word]
        }

        var best: Candidate?
        /// Per boundary, the typed letter a slipped space sits on (unused for other sides).
        var slipped: [Int] = []
        func finish(_ chosen: [Part], _ sides: [Side]) {
            // A misspelled part only in a two-word reading ("investigate thus"): with more
            // parts it is guessing.
            if chosen.count > 2, chosen.contains(where: { $0.hasLetterEdits }) { return }
            // A short misspelled part needs very common company: "home make", never "zorp make".
            if chosen.contains(where: { $0.isShortFuzzy }),
               !chosen.allSatisfy({ $0.rank < Self.spaceSlipCommonRank }) || !sides.allSatisfy({ $0 == .slip }) { return }
            var cost: Float = 0
            if searchEnd < n {
                // Only recover a final slip after an otherwise exact multiword reading
                // already containing a slipped boundary. Never strip x/c/v off one word.
                guard sides.contains(.slip), !chosen.contains(where: { $0.hasLetterEdits }) else { return }
                cost += Self.spaceSlipCost + Self.slipTouchCost(touches?[n - 1])
            }
            for (k, side) in sides.enumerated() {
                let a = chosen[k].rank, b = chosen[k + 1].rank
                switch side {
                case .fused:
                    // Three or more words fuse only around a lone "a" or "I" ("inaminute"):
                    // chains of short fused words read nonsense into names ("be tho Kong").
                    if chosen.count > 2, chosen[k].display.count > 1, chosen[k + 1].display.count > 1 { return }
                    // Both common, or one very common word fused to a rarer one ("bigstorms").
                    guard min(a, b) < Self.splitMaximumRank else { return }
                    let rare = max(a, b) >= Self.splitMaximumRank
                    if rare, min(a, b) >= Self.splitAnchorMaximumRank { return }
                    cost += Self.splitCost + (rare ? Self.rareSplitCost : 0)
                case .slip:
                    // Every slipped space sits beside at least one common word. Beside a rarer
                    // one it costs more, so a one-word fix still wins ("toomrow" is "tomorrow",
                    // not "too row").
                    let deliberateRestricted = chosen[k].explicitlyTypedRestrictedWord || chosen[k + 1].explicitlyTypedRestrictedWord
                    guard min(a, b) < Self.splitMaximumRank ||
                            (deliberateRestricted && max(a, b) < Self.splitRareMaximumRank) else { return }
                    cost += Self.spaceSlipCost + (max(a, b) >= Self.spaceSlipCommonRank ? Self.rareSpaceSlipCost : 0)
                    cost += Self.slipTouchCost(touches?[slipped[k]])
                case .edge:
                    break
                }
            }
            var end = 0
            for (k, part) in chosen.enumerated() {
                cost += part.cost
                // "I" fuses with the next word all the time ("iam"); another lone letter rarely
                // does, and "go a" is a poor reading of "gona".
                if part.display.count == 1, part.display != "I" || k == chosen.count - 1 { cost += Self.loneLetterCost }
                // A lone letter and the slipped key beside it that spell a common word read
                // better as that word: "inconvene..." starts with "in", not "I".
                end += k < sides.count && sides[k] == .slip ? part.inputLength + 1 : part.inputLength
                if part.display.count == 1, k < sides.count, sides[k] == .slip,
                   let pair = words.lookup(String(letters[(end - 2)..<end])), pair.rank < Self.splitTwoLetterMaximumRank {
                    cost += Self.loneLetterCost
                }
            }
            let text = chosen.map(\.display).joined(separator: " ")
            let candidate = Candidate(text: text, cost: cost, rank: chosen.map(\.rank).max() ?? 0, length: n, isSplit: true,
                                      firstLetterMatches: true, startsLowercase: chosen[0].display.first?.isLowercase == true,
                                      entryIndex: words.lookup(chosen[0].display)?.index)
            if best.map({ candidate.score < $0.score }) ?? true { best = candidate }
        }
        var chosen: [Part] = []
        var sides: [Side] = []
        func search(from start: Int, left: Side) {
            guard chosen.count < Self.maximumSplitParts else { return }
            for end in (start + 1)...searchEnd {
                if end == searchEnd {
                    guard !chosen.isEmpty else { continue }
                    for part in parts(start, end, left: left, right: .edge) {
                        chosen.append(part)
                        finish(chosen, sides)
                        chosen.removeLast()
                    }
                    continue
                }
                guard chosen.count + 1 < Self.maximumSplitParts else { continue }
                var options: [(side: Side, next: Int)] = [(.fused, end)]
                if end + 1 < searchEnd, spaceBarLetters.contains(letters[end]) { options.append((.slip, end + 1)) }
                for option in options {
                    for part in parts(start, end, left: left, right: option.side) {
                        chosen.append(part)
                        sides.append(option.side)
                        slipped.append(end)
                        search(from: option.next, left: option.side)
                        slipped.removeLast()
                        sides.removeLast()
                        chosen.removeLast()
                    }
                }
            }
        }
        search(from: 0, left: .edge)
        // Prefer every complete reading before considering a mistaken final space key.
        if best == nil, n > 4, spaceBarLetters.contains(letters[n - 1]) {
            searchEnd = n - 1
            search(from: 0, left: .edge)
        }
        return best
    }

    static let splitCost: Float = 0.7
    static let spaceSlipCost: Float = 0.8
    static let loneLetterCost: Float = 0.5
    static let splitMaximumRank = 3_000
    /// A fused part this rare is read only beside a word at least as common as `splitAnchorMaximumRank`.
    static let splitRareMaximumRank = 20_000
    static let splitAnchorMaximumRank = 300
    static let rareSplitCost: Float = 0.2
    static let spaceSlipCommonRank = 1_000
    static let rareSpaceSlipCost: Float = 0.4
    static let maximumSplitParts = 4
    static let splitTwoLetterMaximumRank = 1_000
    static let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
    /// A misspelled part beside a slipped space: at least this long, this close to a word this common.
    static let slipFuzzyMinimumLength = 6
    static let slipFuzzyCost: Float = 1.0
    static let slipFuzzyLongCost: Float = 1.6
    static let slipFuzzyMaximumRank = 10_000
    /// The same for a part of four or five letters: one near-key slip onto a very common word.
    static let shortSlipFuzzyMinimumLength = 4
    static let shortSlipFuzzyCost: Float = 0.75

    /// What the tap on a slipped key adds to the slip's cost. A thumb that stops short of the
    /// space bar lands low on the key above it; a tap meant for the letter lands near its center.
    /// `dy` is in row pitches below the key's center, after the learned offsets, so it is judged
    /// against where this person's own taps on that key land. The key's edge is at about 0.4 and
    /// the space bar's region starts at 0.5; at `slipTouchNeutral` the touch says nothing, and the
    /// cost moves linearly over `slipTouchSpan` either way, to `lowSlipBonus` off or
    /// `highSlipPenalty` on. No touch, no change.
    static func slipTouchCost(_ touch: KeyTouch?) -> Float {
        guard let dy = touch?.dy, dy.isFinite else { return 0 }
        let t = min(max((dy - slipTouchNeutral) / slipTouchSpan, -1), 1)
        return t >= 0 ? -t * lowSlipBonus : -t * highSlipPenalty
    }

    static let slipTouchNeutral: Float = 0.2
    static let slipTouchSpan: Float = 0.15
    static let lowSlipBonus: Float = 0.3
    static let highSlipPenalty: Float = 0.8

    // MARK: Composition

    /// The word the cursor sits at the end of, or nil when the cursor is not at a word end (mid-word,
    /// after a space, after a digit) or the run is not a plausible word.
    public static func composingWord(before: String?, after: String?) -> String? {
        if let after, let first = after.first, isWordCharacter(first) { return nil }
        guard let before, !before.isEmpty else { return nil }
        var run: [Character] = []
        var iterator = before.reversed().makeIterator()
        var boundary: Character?
        while let character = iterator.next() {
            if isWordCharacter(character) {
                run.append(character == "\u{2019}" ? "'" : character)
                if run.count > WordList.maxWordLength { return nil }
            } else {
                boundary = character
                break
            }
        }
        guard !run.isEmpty else { return nil }
        if let boundary, boundary.isNumber { return nil }
        return String(run.reversed())
    }

    /// The word `composing` follows, given the text up to the cursor that ends with it; nil at a
    /// sentence start, after a number or a newline, or when the host shows too little to tell.
    public static func previousWord(before: String?, composing: String) -> String? {
        guard let before, before.count > composing.count else { return nil }
        return SwipeSpacing.previousWord(before: String(before.dropLast(composing.count)))
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character == "'" || character == "\u{2019}"
    }

    // MARK: Internals

    private func accepted(_ typed: String, lower: String, casing: Casing) -> Evaluation {
        Evaluation(typed: typed, suggestions: fill([Suggestion(text: typed, kind: .literal)], lower: lower, casing: casing))
    }

    private func corrected(_ typed: String, to fix: String, lower: String, casing: Casing) -> Evaluation {
        let suggestion = Suggestion(text: fix, kind: .correction, autoApplies: true)
        return Evaluation(typed: typed, suggestions: fill([literal(typed), suggestion], lower: lower, casing: casing))
    }

    private func literal(_ typed: String) -> Suggestion {
        Suggestion(text: typed, kind: .literal)
    }

    /// The word the one being evaluated follows, as a list index, while `computeEvaluation` runs:
    /// completions are ranked by it. Nil without a pair table or a previous word.
    private var completionPreviousIndex: Int?

    /// How many of the commonest words with a prefix are ranked by the word before, beside the
    /// ones the table has seen after it.
    static let contextCompletionPool = 16

    /// The dictionary's longer words that start with `lower`, likeliest first. With a previous
    /// word the table knows, that is how likely each is after it ("good l" offers "luck" before
    /// "like"): the words the table has seen after it, then the commonest words with the
    /// prefix, all on the table's one scale. Otherwise how common each is anywhere, exactly as
    /// before. On real messages the row then holds the wanted word a keystroke sooner about
    /// one word in ten (docs/research/next-word-bar-2026-11-18).
    private func listedCompletions(of lower: String) -> [WordList.Entry] {
        let limit = Self.maxSuggestions + 2
        guard let context, let previous = completionPreviousIndex, context.knows(previous: previous),
              let key = WordList.foldedKey(lower) else {
            return words.completions(of: lower, limit: limit)
        }
        var indexes = context.successors(after: previous, limit: limit) { words.isCompletion($0, of: key) }
        for entry in words.completions(of: lower, limit: Self.contextCompletionPool) where !indexes.contains(entry.index) {
            indexes.append(entry.index)
        }
        let costs = indexes.map { context.cost(of: $0, after: previous) ?? .infinity }
        // Stable: equal costs keep the seen pair, then the commoner word, first.
        let order = indexes.indices.sorted { costs[$0] < costs[$1] || (costs[$0] == costs[$1] && $0 < $1) }
        return order.prefix(limit).compactMap { words.entry(index: indexes[$0]) }
    }

    /// The likeliest longer word starting with `lower` that the table has seen after the word
    /// before, or nil without such a pair. Never a word kept out of predictions.
    private func completionThatFollows(_ lower: String) -> WordList.Entry? {
        guard let context, let previous = completionPreviousIndex else { return nil }
        return listedCompletions(of: lower).first {
            context.seenCost(of: $0.index, after: previous) != nil && !Self.neverPredicted.contains($0.display.lowercased())
        }
    }

    /// Oaths and grim or insulting words the subtitle-built table ranks high after everyday words
    /// ("the", "my", "oh", "will").
    /// Still typed, completed and corrected like any word; only never offered unasked.
    static let neverPredicted: Set<String> = ["hell", "damn", "damned", "god", "goddamn", "lord", "jesus", "christ", "crap", "kill", "die", "dead", "sex", "sexy", "gun", "drunk", "stupid", "idiot"]

    /// Whole next words for the row between words: the likeliest to follow `previous`, in
    /// dictionary casing ("I", "I'm", "Monday"). Empty without a pair table, when `previous` is
    /// not a list word, or when the table has nothing after it. Never a word the list will not
    /// suggest. The top three hold the next word about one time in five on real messages.
    public func predictions(after previous: String, limit: Int = Autocorrector.maxSuggestions) -> [Suggestion] {
        guard let context, let entry = words.lookup(previous) else { return [] }
        let indexes = context.successors(after: entry.index, limit: limit) { index in
            guard let next = words.entry(index: index), next.isSuggestible else { return false }
            return !Self.neverPredicted.contains(next.display.lowercased())
        }
        return indexes.compactMap { words.entry(index: $0) }.map { Suggestion(text: $0.display, kind: .prediction) }
    }

    /// Tops the slots up with completions so the row rarely sits empty while a word is typed.
    private func fill(_ suggestions: [Suggestion], lower: String, casing: Casing) -> [Suggestion] {
        var result = suggestions
        let hasLongerPrefix = result.contains { $0.text.count > lower.count && $0.text.lowercased().hasPrefix(lower) }
        // Two correction candidates used to occupy both non-literal slots, hiding even an
        // exact-prefix completion (keybo -> keyboard). Keep the best correction and its auto
        // decision; use the last slot for a completion if none is already visible. Very short
        // prefixes still need their correction alternatives, and completions never auto-apply.
        guard result.count < Self.maxSuggestions || (lower.count >= 4 && !hasLongerPrefix) else {
            // A short prefix with both places taken by spelling alternatives ("y" after "thank":
            // "ya", "ye"). When the table has seen a longer word after the one before, that word
            // is likelier than a second guess at the spelling and takes the last place.
            if let follows = completionThatFollows(lower), let last = result.last, last.kind == .correction, !last.autoApplies,
               !result.contains(where: { $0.text.lowercased() == follows.display.lowercased() }) {
                result[result.count - 1] = Suggestion(text: Self.cased(follows.display, like: casing), kind: .completion)
            }
            return result
        }
        var taken = Set(result.map { $0.text.lowercased() })
        // The person's own words first: one they saved is likelier than a dictionary word that
        // happens to share the prefix. They keep their saved capitals ("Mattson" for "matts").
        let own = ownCompletions(of: lower).map { casing == .upper ? $0.uppercased() : $0 }
        let listed = listedCompletions(of: lower).map { Self.cased($0.display, like: casing) }
        for text in own + listed {
            guard taken.insert(text.lowercased()).inserted else { continue }
            let completion = Suggestion(text: text, kind: .completion)
            if result.count == Self.maxSuggestions {
                if let last = result.last, last.kind == .correction, !last.autoApplies {
                    result[result.count - 1] = completion
                }
                break
            }
            result.append(completion)
            if result.count == Self.maxSuggestions { break }
        }
        // Zone's list has nothing longer: ask Apple's, for the places still empty.
        if result.count < Self.maxSuggestions, lower.count >= 4, let systemCompletions,
           !result.contains(where: { $0.kind == .completion }) {
            var shown = Set(result.map { $0.text.lowercased() })
            for word in systemCompletions(lower) {
                let key = word.lowercased()
                guard key.count > lower.count, key.hasPrefix(lower), shown.insert(key).inserted else { continue }
                result.append(Suggestion(text: word == key ? Self.cased(word, like: casing) : word, kind: .completion))
                if result.count == Self.maxSuggestions { break }
            }
        }
        return result
    }

    /// The dictionary's casing of `lower`, honoring a possessive suffix, or nil when unknown.
    private func dictionaryForm(of lower: String) -> String? {
        if let entry = words.lookup(lower) { return entry.display }
        if lower.count > 2, lower.hasSuffix("'s"), let entry = words.lookup(String(lower.dropLast(2))) {
            return entry.display + "'s"
        }
        if lower.count > 2, lower.hasSuffix("s'"), let entry = words.lookup(String(lower.dropLast())) {
            return entry.display + "'"
        }
        return nil
    }

    private func shouldAutoApply(_ candidate: Candidate, typedLength: Int) -> Bool {
        if candidate.isSplit { return true }
        // Two-letter words change only with touch evidence: a tap near the boundary with the
        // intended key, landing on a very common word.
        if typedLength == 2 {
            return candidate.length == 2 && candidate.cost <= Self.twoLetterMaximumCost && candidate.rank < Self.twoLetterMaximumRank
        }
        // Never correct tiny tokens, and never shrink a word into a two-letter one ("usa" is not "us").
        guard typedLength >= Self.minimumCorrectedLength,
              candidate.length >= Self.minimumCorrectedLength else { return false }
        if candidate.cost <= Self.confidentCost { return true }
        // Two edits never add or drop more than one letter overall: a name like "mattson" is not "mason".
        guard abs(candidate.length - typedLength) <= 1 else { return false }
        if typedLength >= Self.twoEditMinimumLength { return candidate.rank < Self.twoEditMaximumRank }
        // Short words: two slips only onto a very common word of the same length, each slip a
        // near key or a swap (xang can be "can't", not "can").
        return candidate.length == typedLength && candidate.cost <= Self.shortTwoEditMaximumCost && candidate.rank < Self.shortTwoEditMaximumRank
    }

    /// Applies the user's casing to a dictionary form: capitals stay capitals, a capitalized typed
    /// word capitalizes the suggestion, lowercase keeps the dictionary's own casing.
    static func cased(_ word: String, like casing: Casing) -> String {
        switch casing {
        case .upper:
            return word.uppercased()
        case .capitalized:
            guard let first = word.first, first.isLowercase else { return word }
            return first.uppercased() + word.dropFirst()
        case .lower, .mixed:
            return word
        }
    }

    enum Casing: Equatable {
        case lower
        case capitalized
        case upper
        case mixed

        init(of word: String) {
            let letters = word.filter { $0.isLetter }
            let uppers = letters.filter { $0.isUppercase }.count
            if uppers == 0 {
                self = .lower
            } else if uppers == letters.count {
                self = letters.count == 1 ? .capitalized : .upper
            } else if word.first?.isUppercase == true, uppers == 1 {
                self = .capitalized
            } else {
                self = .mixed
            }
        }
    }

    /// Fixes that frequency alone would get wrong ("hes" is closer to "yes" than to "he's").
    static let overrides: [String: String] = [
        "i": "I", "im": "I'm", "ive": "I've",
        "dont": "don't", "cant": "can't", "wont": "won't", "didnt": "didn't", "doesnt": "doesn't",
        "isnt": "isn't", "wasnt": "wasn't", "werent": "weren't", "arent": "aren't", "aint": "ain't",
        "havent": "haven't", "hasnt": "hasn't", "hadnt": "hadn't", "couldnt": "couldn't",
        "wouldnt": "wouldn't", "shouldnt": "shouldn't", "mustnt": "mustn't",
        "youre": "you're", "theyre": "they're", "thats": "that's", "whats": "what's",
        "theres": "there's", "heres": "here's", "wheres": "where's", "hes": "he's", "shes": "she's",
        "whos": "who's", "hows": "how's", "whens": "when's", "someones": "someone's",
        "youll": "you'll", "youve": "you've", "theyve": "they've", "weve": "we've", "youd": "you'd",
        "alot": "a lot",
        // Established adjacent-letter transpositions. Ambiguous forms such as hwo (how/who)
        // and realy (really/relay) deliberately still require the ordinary confidence margin.
        "hte": "the", "waht": "what", "wierd": "weird",
    ]
}
