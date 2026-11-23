// by zayd/cold @ zayd.wtf

import Foundation

/// Local, case-preserving ASR vocabulary shared by the app and keyboard. No replacement rules.
public final class PersonalVocabulary: @unchecked Sendable {
    public struct Document: Codable, Equatable, Sendable {
        public var version: Int = 1
        public var words: [String]
        public var learnsFromCorrections: Bool = true
        /// Handles said as "at" and the handle ("at cold" writes @cold), stored without the @.
        public var handles: [String] = []
        /// Lowercased words that arrived through `learnCorrection`, not typed into My Words, so the
        /// screen can say where a word came from. Always a subset of `words`.
        public var learned: [String] = []
        /// What the recognizer wrote, lowercased, to the spelling the person retyped it as right
        /// after a dictation ("versailles" to "Vercel"). Learned only, never typed in; a pair goes
        /// when its word leaves My Words.
        public var misheard: [String: String] = [:]
        private enum CodingKeys: String, CodingKey { case version, words, learnsFromCorrections, handles, learned, misheard }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decode(Int.self, forKey: .version)
            words = try c.decode([String].self, forKey: .words)
            learnsFromCorrections = try c.decodeIfPresent(Bool.self, forKey: .learnsFromCorrections) ?? true
            handles = (try? c.decodeIfPresent([String].self, forKey: .handles)) ?? []
            learned = (try? c.decodeIfPresent([String].self, forKey: .learned)) ?? []
            misheard = (try? c.decodeIfPresent([String: String].self, forKey: .misheard)) ?? [:]
        }
        public init(words: [String]) { self.words = words }

        /// The words typing, swipe and dictation write in their saved spelling: everything in
        /// `words`, less what `PersonalVocabulary.applied` leaves out.
        public var appliedWords: [String] { PersonalVocabulary.applied(words, learned: learned) }
    }

    /// One rule for every path that writes a personal word's spelling. A word Zone learned from
    /// a correction that is an ordinary lowercase word ("The", saved by an earlier build from a
    /// fixed sentence-start typo) is left out: it carried a sentence-start capital, not a
    /// spelling, and applied it would capitalize the word in every later dictation. Words the
    /// person typed into My words always apply, and the list itself is never changed.
    public static func applied(_ words: [String], learned: some Collection<String>) -> [String] {
        guard !learned.isEmpty else { return words }
        let learned = Set(learned.map { $0.lowercased() })
        return words.filter { !(learned.contains($0.lowercased()) && SystemLexiconSpelling.isOrdinaryWord($0)) }
    }
    public enum StoreError: Error { case unsupportedVersion, coordinationFailed }
    public let fileURL: URL
    private let lock = NSLock()

    public static var shared: PersonalVocabulary? {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ZoneContract.appGroup) else { return nil }
        return PersonalVocabulary(fileURL: root.appendingPathComponent("Library/Application Support/Vocabulary/words.json"))
    }

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func words() throws -> [String] { try document().words }

    public func document() throws -> Document {
        lock.lock(); defer { lock.unlock() }
        let fileURL = storeURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Document(words: []) }
        var coordinationError: NSError?
        var result: Result<Document, Error>?
        NSFileCoordinator().coordinate(readingItemAt: fileURL, options: [], error: &coordinationError) { url in
            result = Result { try self.read(url) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw StoreError.coordinationFailed }
        return try result.get()
    }

    /// Merges explicit additions without losing concurrent app/keyboard updates.
    @discardableResult public func add(_ words: [String]) throws -> [String] {
        try update { current in current.words = Self.normalized(current.words + words) }.words
    }

    /// Three-way edit: remove only words the editor actually saw, retaining concurrent additions.
    @discardableResult public func save(_ edited: [String], replacing original: [String]) throws -> [String] {
        let edited = Self.normalized(edited)
        let removed = Set(Self.normalized(original).map { $0.lowercased() })
            .subtracting(edited.map { $0.lowercased() })
        let originalByKey = Dictionary(uniqueKeysWithValues: Self.normalized(original).map { ($0.lowercased(), $0) })
        let changedWords = edited.filter { originalByKey[$0.lowercased()] != $0 }
        let changed = Set(changedWords.map { $0.lowercased() })
        return try update { current in
            // Untouched editor lines must not overwrite a concurrent spelling/case update or
            // resurrect a concurrently deleted word. Explicit additions/edits get hint priority.
            current.words = Self.normalized(changedWords + current.words.filter {
                !removed.contains($0.lowercased()) && !changed.contains($0.lowercased())
            })
            // A word the person retyped here is theirs now, not a learned one.
            current.learned.removeAll { changed.contains($0) }
            // A removed word takes the mishearings it was learned from with it.
            current.misheard = current.misheard.filter { !removed.contains($0.value.lowercased()) || changed.contains($0.value.lowercased()) }
        }.words
    }

    public func setLearningEnabled(_ enabled: Bool) throws {
        _ = try update { $0.learnsFromCorrections = enabled }
    }

    /// At most this many learned mishearings are kept; past it, the first in alphabetical order goes.
    public static let maxMisheard = 300

    /// Rechecks the opt-out inside the same transaction as the learned addition. `heard` is what
    /// dictation wrote where the person typed `word` instead, kept so dictation writes it next time.
    public func learnCorrection(_ word: String, heard: String? = nil) throws {
        _ = try update { current in
            guard current.learnsFromCorrections else { return }
            if let heard = heard?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !heard.isEmpty,
               heard != word.lowercased() {
                current.misheard[heard] = word
                if current.misheard.count > Self.maxMisheard, let oldest = current.misheard.keys.sorted().first {
                    current.misheard[oldest] = nil
                }
            }
            let key = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // A word already in My Words keeps the origin it has.
            if !key.isEmpty, !current.words.contains(where: { $0.lowercased() == key }) { current.learned.append(key) }
            current.words = Self.normalized([word] + current.words)
        }
    }

    public func handles() throws -> [String] { try document().handles }

    /// A learned mishearing is applied only when what the recognizer wrote is not an everyday word:
    /// "Versailles" to Vercel is safe; a taught "lift" to Lyft would rewrite every lift.
    static let misheardMinimumRank = 10_000

    /// `text` with each learned mishearing written the way the person retyped it. Whole words,
    /// any case; a possessive keeps its 's.
    public static func applyingMisheard(_ text: String, _ misheard: [String: String],
                                        rank: (String) -> Int?) -> String {
        guard !misheard.isEmpty, !text.isEmpty else { return text }
        let usable = misheard.filter { heard, _ in
            guard let rank = rank(heard) else { return true }
            return rank >= misheardMinimumRank
        }
        guard !usable.isEmpty else { return text }
        let alternation = usable.keys.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        guard let expression = try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}_'’\-@#./])(?:"# + alternation + #")(?=(?:['’]s)?(?![\p{L}\p{N}_'’\-]))"#,
            options: [.caseInsensitive]) else { return text }
        var out = text
        for match in expression.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
            guard let range = Range(match.range, in: out), let written = usable[out[range].lowercased()] else { continue }
            out.replaceSubrange(range, with: written)
        }
        return out
    }

    /// Every "at sign" teaches one, so the list is bounded: the most recently added or taught are kept.
    public static let maxHandles = 200

    /// Adds handles typed in Settings or taught by saying "at sign" and the handle. One added again
    /// moves to the end, so a handle in use is never the one that falls off.
    @discardableResult public func addHandles(_ handles: [String]) throws -> [String] {
        let added = Self.normalizedHandles(handles)
        return try update { current in
            current.handles = Array(Self.normalizedHandles(current.handles.filter { !added.contains($0) } + added).suffix(Self.maxHandles))
        }.handles
    }

    @discardableResult public func removeHandles(_ handles: [String]) throws -> [String] {
        let removed = Set(Self.normalizedHandles(handles))
        return try update { current in current.handles.removeAll { removed.contains($0) } }.handles
    }

    /// Lowercase, without the @, and only the characters a handle can hold: "@Cold " is "cold" and
    /// "Zoë" is "zoe".
    public static func normalizedHandles(_ handles: [String]) -> [String] {
        var seen = Set<String>()
        return handles.map { handle in
            String(handle.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).drop { $0 == "@" || $0.isWhitespace }
                .filter { ($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") && $0.isASCII }
                .prefix(32))
        }
        .filter { $0.contains(where: \.isLetter) && seen.insert($0).inserted }
    }

    /// The words in text typed or pasted into My Words: one per line, or separated by commas,
    /// semicolons or tabs, with blank lines ignored. A list pasted from Notes or a message keeps
    /// working: a leading bullet or number ("- ", "• ", "1. ", "2) ") and quotes around a word are
    /// dropped. Spaces inside an entry stay, so "Claude Code" is one phrase.
    public static func entries(fromDraft draft: String) -> [String] {
        let separators = CharacterSet.newlines.union(CharacterSet(charactersIn: ",;\t，、"))
        return normalized(draft.components(separatedBy: separators).map(cleanEntry))
    }

    private static let listMarker = try! NSRegularExpression(pattern: #"^\s*(?:[-–—•*·▪◦]+|\d{1,3}[.)])\s+"#)

    private static func cleanEntry(_ raw: String) -> String {
        var entry = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        entry = listMarker.stringByReplacingMatches(in: entry, range: NSRange(entry.startIndex..., in: entry), withTemplate: "")
        let quotes: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’")]
        for (open, close) in quotes where entry.count >= 2 && entry.first == open && entry.last == close {
            entry = String(entry.dropFirst().dropLast())
        }
        return entry.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func normalized(_ words: [String]) -> [String] {
        var seen = Set<String>()
        return words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Learned marks for words that are still saved, each once.
    static func prunedLearned(_ learned: [String], words: [String]) -> [String] {
        let present = Set(words.map { $0.lowercased() })
        var seen = Set<String>()
        return learned.filter { present.contains($0) && seen.insert($0).inserted }
    }

    private func read(_ url: URL) throws -> Document {
        guard FileManager.default.fileExists(atPath: url.path) else { return Document(words: []) }
        var document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        guard document.version == 1 else { throw StoreError.unsupportedVersion }
        document.words = Self.normalized(document.words)
        document.handles = Self.normalizedHandles(document.handles)
        document.learned = Self.prunedLearned(document.learned, words: document.words)
        return document
    }

    private func update(_ change: (inout Document) -> Void) throws -> Document {
        lock.lock(); defer { lock.unlock() }
        do { return try write(change) } catch {
            // A folder this process did not create (seeded by a developer tool, or restored) can
            // refuse every write while its words stay readable, and it cannot be renamed or
            // removed either. The words move once to a folder of the app's own, which the app
            // and the keyboard both prefer from then on. Words that cannot be read are left
            // where they are: nothing is replaced by an empty list.
            let refused = (error as NSError).domain == NSCocoaErrorDomain
                && [CocoaError.fileWriteNoPermission.rawValue, CocoaError.fileWriteUnknown.rawValue].contains((error as NSError).code)
            guard storeURL == fileURL,
                  refused || !FileManager.default.isWritableFile(atPath: fileURL.deletingLastPathComponent().path),
                  FileManager.default.fileExists(atPath: fileURL.path), let current = try? read(fileURL),
                  let data = try? JSONEncoder().encode(current) else { throw error }
            do {
                try FileManager.default.createDirectory(at: ownedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: ownedURL, options: .atomic)
            } catch { throw error }
            return try write(change)
        }
    }

    /// Where the words live when `fileURL`'s folder refuses writes.
    private var ownedURL: URL {
        let directory = fileURL.deletingLastPathComponent()
        return directory.deletingLastPathComponent()
            .appendingPathComponent(directory.lastPathComponent + "-2").appendingPathComponent(fileURL.lastPathComponent)
    }
    private var storeURL: URL { FileManager.default.fileExists(atPath: ownedURL.path) ? ownedURL : fileURL }

    private func write(_ change: (inout Document) -> Void) throws -> Document {
        let fileURL = storeURL
        var directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try directory.setResourceValues(resources)
        var coordinationError: NSError?
        var result: Result<Document, Error>?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: .forMerging, error: &coordinationError) { url in
            result = Result {
                var next = try self.read(url)
                change(&next)
                next.learned = Self.prunedLearned(next.learned, words: next.words)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(next).write(to: url, options: .atomic)
                return next
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw StoreError.coordinationFailed }
        return try result.get()
    }
}
