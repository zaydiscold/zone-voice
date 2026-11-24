// by zayd/cold @ zayd.wtf

import Foundation

/// Apple's supplementary terms stay separate from the person's editable My Words list.
public struct SystemLexiconSnapshot: Codable, Equatable, Sendable {
    public var version = 1
    public let names: [String]
    public let replacements: [String: String]

    public init(entries: [(input: String, text: String)]) {
        var names: [String] = []
        var replacements: [String: String] = [:]
        for entry in entries {
            let input = entry.input.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !input.isEmpty, !text.isEmpty else { continue }
            // Apple also supplies case-only pairs, such as iphone → iPhone.
            let caseOnly = input.caseInsensitiveCompare(text) == .orderedSame
            if caseOnly { names.append(text) }
            // A case-only pair for an ordinary word ("the" to "The" from a contact card) is a
            // contact field, not a replacement the person wrote: typing "the" must stay "the".
            if input != text, !caseOnly || SystemLexiconSpelling.keepsOwnCasing(text) { replacements[input] = text }
        }
        self.names = PersonalVocabulary.normalized(names)
        self.replacements = replacements
    }

    public static let empty = SystemLexiconSnapshot(entries: [])

    /// The terms swipe typing may write in their own casing. A contact card holds ordinary words
    /// too ("The Barber", "Guy From Gym", "Mom And Dad"), and each arrives here as a term of its
    /// own; those are left to the dictionary, so a swiped "the" is never "The".
    public var swipeWords: [String] { names.filter { SystemLexiconSpelling.keepsOwnCasing($0) } }

    /// The same, less what the person has taught the keyboard. "Mark" and "Bill" are names and
    /// words at once, and no list can say which this person means. Undoing the capital once
    /// (the keyboard learns the word as kept) settles it for swipe as it already does for taps.
    /// Only an ordinary word can be taken back this way: a kept "nika" is still the contact Nika.
    public func swipeWords(keptLowercase kept: some Sequence<String>) -> [String] {
        let kept = Set(kept.map { $0.lowercased() })
        guard !kept.isEmpty else { return swipeWords }
        return swipeWords.filter { !(kept.contains($0.lowercased()) && SystemLexiconSpelling.isOrdinaryWord($0)) }
    }

    /// Lowercase contact surnames that are also ordinary words, for `ContactSurnames`.
    public var surnames: Set<String> { ContactSurnames.candidates(names) }

    /// The part of `speechWords` a recognizer is told to listen for. A surname that is also a word
    /// ("Brown", and whatever else a card holds: "Idiot", "Boss", "Dentist") is in `speechWords` so
    /// the formatter can write "Sarah Brown", but a recognizer already knows the word, and hinting
    /// its capitalized form makes it write "you Idiot" in every sentence.
    public static func recognizerHints(from speechWords: [String]) -> [String] {
        speechWords.filter { !ContactSurnames.isCandidate($0) }
    }

    /// Hint the expansion, never the typed shortcut. Hint budgets belong to each recognizer.
    public var speechWords: [String] {
        let terms = names.filter { word in
            guard !word.contains(where: \.isUppercase) else {
                return SystemLexiconSpelling.keepsOwnCasing(word, rewritingProse: true) || ContactSurnames.isCandidate(word)
            }
            guard let entry = WordList.shared?.lookup(word.lowercased()) else { return true }
            return entry.display != entry.display.lowercased()
        }
        return PersonalVocabulary.normalized(terms + replacements.keys.sorted().compactMap { replacements[$0] })
    }
}

/// Replaced atomically by the keyboard with Full Access; read locally by either process.
public final class SystemLexiconStore: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()
    public enum StoreError: Error { case unsupportedVersion, coordinationFailed }

    public static var shared: SystemLexiconStore? {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ZoneContract.appGroup) else { return nil }
        return SystemLexiconStore(fileURL: root.appendingPathComponent("Library/Application Support/SystemLexicon/terms.json"))
    }

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func snapshot() throws -> SystemLexiconSnapshot {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
        var error: NSError?
        var result: Result<SystemLexiconSnapshot, Error>?
        NSFileCoordinator().coordinate(readingItemAt: fileURL, options: [], error: &error) { url in
            result = Result {
                guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
                let value = try JSONDecoder().decode(SystemLexiconSnapshot.self, from: Data(contentsOf: url))
                guard value.version == 1 else { throw StoreError.unsupportedVersion }
                return value
            }
        }
        if let error { throw error }
        guard let result else { throw StoreError.coordinationFailed }
        return try result.get()
    }

    /// What this process last wrote to each file. The keyboard asks the system for its lexicon on
    /// every appearance and gets the same one back nearly every time; without this each
    /// appearance was a coordinated atomic rewrite of an unchanged file in the App Group.
    private static let writtenLock = NSLock()
    nonisolated(unsafe) private static var written: [String: SystemLexiconSnapshot] = [:]

    public func save(_ snapshot: SystemLexiconSnapshot) throws {
        lock.lock(); defer { lock.unlock() }
        Self.writtenLock.lock()
        let unchanged = Self.written[fileURL.path] == snapshot
        Self.writtenLock.unlock()
        // Only this process's own last write is trusted, and only while the file is still there.
        if unchanged, FileManager.default.fileExists(atPath: fileURL.path) { return }
        var directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try directory.setResourceValues(resources)
        let data = try JSONEncoder().encode(snapshot)
        var error: NSError?
        var failure: Error?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: .forReplacing, error: &error) { url in
            do {
                #if os(iOS)
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                #else
                try data.write(to: url, options: .atomic)
                #endif
            } catch { failure = error }
        }
        if let error { throw error }
        if let failure { throw failure }
        Self.writtenLock.lock()
        Self.written[fileURL.path] = snapshot
        Self.writtenLock.unlock()
    }
}

/// A contact's surname that is also an ordinary word: Brown, Stone, Khan. It cannot carry its
/// capital everywhere ("the brown house"), so it takes one only where a surname goes: right
/// after a capitalized first name or a title ("Sarah Brown", "Dr. Khan"). Very common words
/// ("will", "long", "young") never qualify, so "Grace will call" stays as said.
public enum ContactSurnames {
    static let titles: Set<String> = ["mr", "mrs", "ms", "miss", "dr", "doctor", "prof", "professor", "uncle", "aunt",
                                      "auntie", "coach", "officer", "judge", "senator", "captain", "sir"]

    static func isCandidate(_ term: String) -> Bool {
        guard term.count >= 3, term.allSatisfy(\.isLetter), term.first?.isUppercase == true,
              term.dropFirst().allSatisfy(\.isLowercase),
              let entry = WordList.shared?.lookup(term.lowercased()), entry.display == entry.display.lowercased(),
              entry.rank >= 900 else { return false }
        return !SystemLexiconSpelling.keepsOwnCasing(term, rewritingProse: true)
    }

    public static func candidates(_ terms: [String]) -> Set<String> {
        Set(terms.filter(isCandidate).map { $0.lowercased() })
    }

    /// Whether `word` is something a surname follows: a title, or a first name written with its capital.
    static func leads(_ word: Substring) -> Bool {
        let lower = word.lowercased()
        if titles.contains(lower) { return true }
        guard word.first?.isUppercase == true, word.dropFirst().allSatisfy(\.isLowercase) else { return false }
        if TextStyle.givenNames.contains(lower) { return true }
        // The long list of registered first names has "My" and "Young" in it; a word counts
        // from that list only when it is not ordinary English.
        guard SpokenMentions.firstNames.contains(lower) else { return false }
        return WordList.shared?.lookup(lower).map { $0.rank >= 5_000 } ?? true
    }

    /// True when the text before the cursor ends in a title or first name and a space, so the
    /// next word typed can be a surname.
    public static func follows(_ before: String) -> Bool {
        guard before.last == " " else { return false }
        var rest = before.dropLast()
        if rest.last == "." { rest = rest.dropLast() }
        let word = rest[(rest.lastIndex(where: { !$0.isLetter }).map(rest.index(after:)) ?? rest.startIndex)...]
        guard !word.isEmpty else { return false }
        // "v2 " or "user_mark " is not a name.
        if word.startIndex > rest.startIndex, let prior = rest[..<word.startIndex].last, prior.isNumber || prior == "_" || prior == "@" { return false }
        return leads(word)
    }

    private static let word = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_'’\-@#./])\p{L}+(?![\p{L}\p{N}_\-@/])"#)

    /// `text` with each candidate capitalized where it follows a title or first name, and the
    /// full names that made ("Sarah Brown").
    static func capitalizing(_ text: String, surnames: Set<String>) -> (text: String, names: [String]) {
        guard !surnames.isEmpty else { return (text, []) }
        var out = text
        var names: [String] = []
        for match in word.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            let found = out[range]
            let before = out[..<range.lowerBound]
            guard surnames.contains(found.lowercased()), found.dropFirst().allSatisfy(\.isLowercase),
                  follows(String(before)) else { continue }
            let surname = found.prefix(1).uppercased() + found.dropFirst()
            let stem = before.dropLast()
            let lead = stem[(stem.lastIndex(where: { !$0.isLetter }).map(stem.index(after:)) ?? stem.startIndex)...]
            if !lead.isEmpty, !titles.contains(lead.lowercased()) { names.append(lead + " " + surname) }
            out.replaceSubrange(range, with: surname)
        }
        return (out, names)
    }
}

/// Conservative contact spelling for recognizers that cannot accept vocabulary hints.
enum SystemLexiconSpelling {
    static func formattingWords(_ words: [String]) -> [String] {
        PersonalVocabulary.normalized(words).filter { word in
            guard word.contains(where: \.isUppercase) else { return false }
            return keepsOwnCasing(word, rewritingProse: true)
        }
    }

    /// Whether a contact term is written the contact's way. A word the dictionary writes in
    /// lowercase is ordinary English ("the", "uncle", "amazing"), whatever a contact card
    /// capitalizes, unless it is an uncommon word that is also a first name.
    /// A swiped word is one deliberate word, so a common given name keeps its capital there
    /// ("John", "Mark"); `rewritingProse` is dictation, which recases words already written and
    /// must leave "I will mark it" alone. Several words count when any one does.
    static func keepsOwnCasing(_ term: String, rewritingProse: Bool = false) -> Bool {
        term.split(whereSeparator: { !$0.isLetter }).contains { token in
            let lower = token.lowercased()
            let uncommon: Bool
            let entry = WordList.shared?.lookup(lower)
            if let entry, entry.display == entry.display.lowercased() {
                uncommon = entry.rank >= 5_000
            } else if let entry, entry.display.count > 1, entry.display == entry.display.uppercased(), token != entry.display {
                // A job title or initials typed into a card ("Ceo", "Td"): the dictionary's
                // acronym ("CEO") is how the word is written, not the card's casing.
                return false
            } else if ModernVocabulary.ordinaryWords.contains(lower) {
                // "Bestie" on a contact card is the word the keyboard already types as "bestie".
                uncommon = false
            } else {
                return true
            }
            if TextStyle.givenNames.contains(lower) { return uncommon || !rewritingProse }
            return uncommon && SpokenMentions.firstNames.contains(lower)
        }
    }

    /// One word that Zone writes in lowercase on its own: the dictionary's or the current-words list's.
    static func isOrdinaryWord(_ term: String) -> Bool {
        let lower = term.lowercased()
        if let entry = WordList.shared?.lookup(lower) { return entry.display == entry.display.lowercased() }
        return ModernVocabulary.ordinaryWords.contains(lower)
    }

    static func correct(_ text: String, words: [String], explicitWords: [String], mentions: Bool) -> String {
        guard !words.isEmpty else { return text }
        let protected = Set(explicitWords.map { $0.lowercased() })
        let phrases = Array(VocabularyCandidates.matchedRanges(in: text,
            words: explicitWords.filter { $0.contains(where: \.isWhitespace) }).reversed())
        var phraseIndex = 0
        let canonical = Dictionary(PersonalVocabulary.normalized(words).map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var index: [String: [String]] = [:]
        for word in words where word.count >= 4 && word.allSatisfy(\.isLetter) {
            let sound = key(word)
            if sound.count >= 2 { index[sound, default: []].append(word) }
        }
        guard !canonical.isEmpty, let regex = try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}_'’\-@])([\p{L}]{2,})(?:['’]s)?(?![\p{L}\p{N}_'’\-])"#) else { return text }
        var output = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let tokenRange = match.range(at: 1)
            while phraseIndex < phrases.count, phrases[phraseIndex].location >= NSMaxRange(tokenRange) { phraseIndex += 1 }
            if phraseIndex < phrases.count, NSIntersectionRange(tokenRange, phrases[phraseIndex]).length > 0 { continue }
            guard let range = Range(match.range(at: 1), in: output) else { continue }
            let token = String(output[range]), lower = token.lowercased()
            guard !protected.contains(lower) else { continue }
            // An acronym ("CLI") or a word the current-words list knows is not a misheard contact:
            // a contact called Cali turned every "CLI" into "Cali" (Zayd, November 15).
            if token.count >= 2, token.allSatisfy({ $0.isUppercase }) { continue }
            if ModernVocabulary.names[lower] != nil || ModernVocabulary.ordinaryWords.contains(lower) { continue }
            if followsHandle(output[..<range.lowerBound], mentions: mentions) { continue }
            if let name = canonical[lower] {
                output.replaceSubrange(range, with: name)
                continue
            }
            if let entry = WordList.shared?.lookup(lower), entry.display == entry.display.lowercased(),
               entry.rank < 5_000 || token.first?.isUppercase != true { continue }
            // Contacts are not social handles. Their spelling cannot change an explicit tag.
            let candidates = (index[key(token)] ?? []).filter {
                $0.first?.lowercased() == token.first?.lowercased()
                    && abs($0.count - token.count) <= 1
                    && PersonalWordMatcher.editDistance(lower, $0.lowercased()) == 1
            }
            // An ambiguous name stays as recognized; importing a large address book must not guess.
            guard candidates.count == 1, let name = candidates.first else { continue }
            output.replaceSubrange(range, with: name)
        }
        return output
    }

    /// Inspect only the words immediately before this token, not its entire preceding transcript.
    private static func followsHandle(_ prefix: Substring, mentions: Bool) -> Bool {
        var position = prefix.endIndex
        func previousWord() -> String? {
            while position > prefix.startIndex, prefix[prefix.index(before: position)].isWhitespace {
                position = prefix.index(before: position)
            }
            let end = position
            var count = 0
            while position > prefix.startIndex, prefix[prefix.index(before: position)].isLetter {
                count += 1
                guard count <= 4 else { return nil }
                position = prefix.index(before: position)
            }
            guard position < end else { return nil }
            if position > prefix.startIndex {
                let preceding = prefix[prefix.index(before: position)]
                if preceding.isNumber || preceding == "_" { return nil }
            }
            return prefix[position..<end].lowercased()
        }
        let last = previousWord()
        return (mentions && last == "at") || (last == "sign" && previousWord() == "at")
    }

    private static func key(_ word: String) -> String {
        PersonalWordMatcher.soundKey(word.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX")))
            .replacingOccurrences(of: "T", with: "D")
            .replacingOccurrences(of: "P", with: "B").replacingOccurrences(of: "K", with: "G")
    }
}

/// Normalizes final user transcripts for every ASR backend, including engines without hints.
/// Streaming partials stay cheap and unmodified; audio ownership/cancellation remain with the engine.
public final class LexiconRecognitionSession: RecognitionSession {
    private let base: RecognitionSession
    private let systemWords: [String]
    private let personalWords: [String]
    private let onAudioSubmitted: (() -> Void)?
    private let mentions: Bool

    public init(base: RecognitionSession, systemWords: [String], personalWords: [String], mentions: Bool, onAudioSubmitted: (() -> Void)? = nil) {
        self.onAudioSubmitted = onAudioSubmitted
        self.base = base; self.systemWords = systemWords; self.personalWords = personalWords; self.mentions = mentions
    }

    public var audioSeconds: Double { base.audioSeconds }
    public var textSoFar: String { base.textSoFar }
    public var failure: Error? { base.failure }
    public var availableAudioSamples: Int { base.availableAudioSamples }
    /// The engine's own unsure words. Without this the protocol's empty default answered, and no
    /// dictation ever reached the keyboard with any (every app dictation goes through this
    /// wrapper). A word the lexicon respelled is no longer in the text and is dropped by
    /// `DoubtfulWords.place`, never guessed at.
    public var doubtfulWords: [DoubtfulWord] { base.doubtfulWords }
    public func feed(_ samples: [Float]) {
        base.feed(samples)
        if !samples.isEmpty { onAudioSubmitted?() }
    }
    public func cancel() { base.cancel() }
    public func finish() async throws -> String {
        let text = try await base.finish()
        return TextStyle.correctingSystemVocabulary(text, systemWords: systemWords,
            personalWords: personalWords, mentions: mentions)
    }
}
