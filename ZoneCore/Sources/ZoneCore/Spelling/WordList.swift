// by zayd/cold @ zayd.wtf

import Foundation

/// English word list for the keyboard's autocorrect, loaded from `en-words.txt` (built by
/// `scripts/build-wordlist.py` from SCOWL and Wikipedia word frequencies).
///
/// Every word's bytes live in one buffer, grouped by length and sorted case-insensitively, so a
/// lookup is a binary search over a (length, first letter) range and no `String` is retained per
/// word. The whole index for 76k words is about 1.6 MB, which matters inside a keyboard extension.
public final class WordList: @unchecked Sendable {
    /// Longest word the list and the engine handle.
    public static let maxWordLength = 24

    public struct Entry: Equatable {
        /// Position in the list; stable for the lifetime of the list.
        public let index: Int
        /// Frequency rank, 0 for the most frequent word.
        public let rank: Int
        /// The word with its dictionary casing (Monday, NASA, I'm).
        public let display: String
        /// False for profanity and slurs: valid when typed, never offered (see wordlist-no-suggest.txt).
        public let isSuggestible: Bool
    }

    public struct Neighbor: Equatable {
        public let entry: Entry
        /// Weighted edit cost between the typed word and this entry (see `EditCost`).
        public let cost: Float
    }

    private static let slots = 28 // a...z, apostrophe, end sentinel

    /// Display forms, concatenated. Entry `i` of length `L` starts at `byteStart[L] + (i - entryStart[L]) * L`.
    private let bytes: [UInt8]
    /// Frequency rank in the low bits; `blockedBit` marks a word that is never suggested.
    /// Set once, in `init`: the file's ranks, then `chat-ranks.txt` over them.
    private var ranks: [UInt32]
    private static let blockedBit: UInt32 = 1 << 31
    /// One bit per distinct letter in the word (a...z, apostrophe); a cheap edit-distance prefilter.
    private let letterMasks: [UInt32]
    /// `entryStart[L]` is the index of the first entry of length `L`; `entryStart[maxWordLength + 1]` is `count`.
    private let entryStart: [Int]
    private let byteStart: [Int]
    /// `letterStart[L * slots + s]` is the first entry of length `L` whose first letter is in slot `s` or later.
    private let letterStart: [Int]
    public let count: Int
    /// Contractions keyed by their spelling without the apostrophe ("theyll" to the index of
    /// "they'll"), for words whose bare spelling is not itself a word ("well", "ill" and "were"
    /// are, so they stay as typed).
    private var contractionIndex: [String: Int] = [:]
    /// Per prefix of a bare contraction ("is", "isn" of "isnt"), the letters that continue one.
    private var bareContractionMasks: [String: UInt32] = [:]

    // MARK: Loading

    /// One parsed copy per process, shared by autocorrect and text formatting (the keyboard had
    /// been parsing it twice: 9.5 ms and about 1.6 MB each). Loaded lazily and thread-safely.
    nonisolated(unsafe) public static let shared: WordList? = loadBundled()

    /// The list shipped in the package. Nil only if the resource is missing or corrupt.
    public static func loadBundled() -> WordList? {
        guard let url = Bundle.module.url(forResource: "en-words", withExtension: "txt"),
              // Mapped, so the file's pages stay clean and leave the extension's footprint once parsed.
              let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        let chatRanks = Bundle.module.url(forResource: "chat-ranks", withExtension: "txt").flatMap { try? Data(contentsOf: $0) }
        return WordList(data: data, rankOverrides: chatRanks)
    }

    /// Parses "<word>\t<rank>\n" lines (optionally "\tx" for never-suggested words) that are
    /// already sorted by length, then case-insensitively.
    /// Returns nil when a line is out of order or malformed, so a bad resource fails loudly in tests
    /// rather than mis-searching at runtime.
    ///
    /// `rankOverrides` is `chat-ranks.txt`: "<word>\t<rank>" lines (and `#` notes) for words the
    /// list has but ranks as rare because its frequencies come from an encyclopedia, where
    /// nobody writes "nah", "lemme" or "it'll". Each named word takes the given rank when that is
    /// commoner than its own; a line naming no entry, or a rarer rank, changes nothing. Entries
    /// and their order are untouched, so the word-pair table still matches the list.
    public init?(data: Data, rankOverrides: Data? = nil) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(data.count / 2)
        var ranks = [UInt32]()
        var masks = [UInt32]()
        var lengths = [UInt8]()
        ranks.reserveCapacity(80_000)
        masks.reserveCapacity(80_000)
        lengths.reserveCapacity(80_000)

        var ordered = true
        var previousKey = [UInt8]()
        var apostropheIndices: [Int] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            let n = p.count
            var i = 0
            var key = [UInt8]()
            key.reserveCapacity(Self.maxWordLength)
            while i < n {
                let wordBegin = i
                while i < n, p[i] != 0x09, p[i] != 0x0A { i += 1 }
                let wordLength = i - wordBegin
                guard i < n, p[i] == 0x09 else { ordered = false; return }
                i += 1
                var rank: UInt32 = 0
                var digits = 0
                while i < n, p[i] >= 0x30, p[i] <= 0x39 {
                    rank = rank &* 10 &+ UInt32(p[i] - 0x30)
                    digits += 1
                    i += 1
                }
                guard digits > 0, digits <= 9 else { ordered = false; return }
                if i + 1 < n, p[i] == 0x09, p[i + 1] == 0x78 {
                    rank |= Self.blockedBit
                    i += 2
                }
                guard i >= n || p[i] == 0x0A else { ordered = false; return }
                i += 1
                guard wordLength >= 1, wordLength <= Self.maxWordLength else { ordered = false; return }
                key.removeAll(keepingCapacity: true)
                var mask: UInt32 = 0
                for j in 0..<wordLength {
                    let folded = p[wordBegin + j] | 0x20
                    guard let slot = Self.slot(folded) else { ordered = false; return }
                    key.append(folded)
                    mask |= 1 << UInt32(slot)
                }
                if !previousKey.isEmpty {
                    if key.count < previousKey.count || (key.count == previousKey.count && !(previousKey.lexicographicallyPrecedes(key))) {
                        ordered = false
                        return
                    }
                }
                previousKey = key
                if key.contains(0x27) { apostropheIndices.append(ranks.count) }
                bytes.append(contentsOf: UnsafeBufferPointer(rebasing: p[wordBegin..<(wordBegin + wordLength)]))
                ranks.append(rank)
                masks.append(mask)
                lengths.append(UInt8(wordLength))
            }
        }
        guard ordered, !ranks.isEmpty else { return nil }

        let count = ranks.count
        var entryStart = [Int](repeating: 0, count: Self.maxWordLength + 2)
        var byteStart = [Int](repeating: 0, count: Self.maxWordLength + 2)
        var letterStart = [Int](repeating: 0, count: (Self.maxWordLength + 1) * Self.slots)
        var index = 0
        var byteOffset = 0
        for length in 0...Self.maxWordLength {
            entryStart[length] = index
            byteStart[length] = byteOffset
            let base = length * Self.slots
            for slot in 0..<(Self.slots - 1) {
                letterStart[base + slot] = index
                while index < count, Int(lengths[index]) == length,
                      Self.slot(bytes[byteOffset + (index - entryStart[length]) * length] | 0x20) == slot {
                    index += 1
                }
            }
            letterStart[base + Self.slots - 1] = index
            byteOffset += (index - entryStart[length]) * length
        }
        entryStart[Self.maxWordLength + 1] = index
        byteStart[Self.maxWordLength + 1] = byteOffset
        guard index == count else { return nil }

        self.bytes = bytes
        self.ranks = ranks
        self.letterMasks = masks
        self.entryStart = entryStart
        self.byteStart = byteStart
        self.letterStart = letterStart
        self.count = count
        self.contractionIndex = buildContractionIndex(apostropheIndices)
        var contractionMasks: [String: UInt32] = [:]
        for (bare, i) in contractionIndex where entry(at: i).isSuggestible {
            let letters = Array(bare.utf8)
            for end in 1..<letters.count {
                guard let slot = Self.slot(letters[end]) else { continue }
                contractionMasks[String(decoding: letters[..<end], as: UTF8.self), default: 0] |= 1 << UInt32(slot)
            }
        }
        self.bareContractionMasks = contractionMasks
        if let rankOverrides { applyRankOverrides(rankOverrides) }
    }

    private func applyRankOverrides(_ data: Data) {
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t")
            guard fields.count == 2, let rank = UInt32(fields[1]), rank < Self.blockedBit,
                  let key = Self.foldedKey(String(fields[0])), let index = findExact(key),
                  rank < ranks[index] & ~Self.blockedBit else { continue }
            ranks[index] = rank | (ranks[index] & Self.blockedBit)
        }
    }

    /// A contraction is a word whose part after the apostrophe is a clitic (d, ll, m, re, s, t,
    /// ve) and whose part before it is a word or "I": "they'll", "would've", "how'd", not
    /// "O'Hara" or "e'er".
    private func buildContractionIndex(_ indices: [Int]) -> [String: Int] {
        let clitics: Set<String> = ["d", "ll", "m", "re", "s", "t", "ve"]
        var index: [String: Int] = [:]
        for i in indices {
            let display = entry(at: i).display
            let parts = display.split(separator: "'", omittingEmptySubsequences: false)
            guard parts.count == 2, clitics.contains(String(parts[1])),
                  parts[0] == "I" || (parts[0].count >= 2 && parts[0].first?.isLowercase == true) else { continue }
            let bare = display.lowercased().replacingOccurrences(of: "'", with: "")
            guard Self.foldedKey(bare).flatMap({ findExact($0) }) == nil else { continue }
            index[bare] = i
        }
        return index
    }

    // MARK: Lookup

    /// The entry matching `word` regardless of case, or nil.
    public func lookup(_ word: String) -> Entry? {
        guard let key = Self.foldedKey(word) else { return nil }
        return findExact(key).map(entry(at:))
    }

    /// The contraction typed without its apostrophe ("theyll" gives "they'll"), or nil.
    public func contraction(forBare word: String) -> Entry? {
        guard let key = Self.foldedKey(word) else { return nil }
        return contractionIndex[String(decoding: key, as: UTF8.self)].map(entry(at:))
    }

    /// Bit `slot` set for each letter that continues `prefix` toward a contraction typed without
    /// its apostrophe: n after "is" ("isnt"), v and m after "i" ("ive", "im").
    public func bareContractionLetters(after prefix: String) -> UInt32 {
        guard let key = Self.foldedKey(prefix) else { return 0 }
        return bareContractionMasks[String(decoding: key, as: UTF8.self)] ?? 0
    }

    /// Words longer than `prefix` that start with it (case-insensitive), most frequent first.
    public func completions(of prefix: String, limit: Int) -> [Entry] {
        guard limit > 0, let key = Self.foldedKey(prefix), let slot = Self.slot(key[0]) else { return [] }
        var best: [(rank: UInt32, index: Int)] = []
        let prefixLength = key.count
        guard prefixLength < Self.maxWordLength else { return [] }
        for length in (prefixLength + 1)...Self.maxWordLength {
            let base = length * Self.slots
            var low = letterStart[base + slot]
            var high = letterStart[base + slot + 1]
            let first = entryStart[length]
            let bytesBase = byteStart[length]
            // Lower bound: first entry whose leading bytes are not below the prefix.
            while low < high {
                let mid = (low + high) / 2
                if comparePrefix(key, at: bytesBase + (mid - first) * length) > 0 {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            var index = low
            let end = letterStart[base + slot + 1]
            while index < end, comparePrefix(key, at: bytesBase + (index - first) * length) == 0 {
                let rank = ranks[index]
                if rank & Self.blockedBit != 0 {
                    index += 1
                    continue
                }
                if best.count < limit {
                    best.append((rank, index))
                    best.sort { $0.rank < $1.rank }
                } else if rank < best[best.count - 1].rank {
                    best[best.count - 1] = (rank, index)
                    best.sort { $0.rank < $1.rank }
                }
                index += 1
            }
        }
        return best.map { entry(at: $0.index) }
    }

    /// Entries within `maxCost` weighted edits of `word`, cheapest first (ties by rank). Candidates
    /// are drawn from words of similar length that start with the typed first or second letter,
    /// which covers every single edit except an error on the very first key.
    public func neighbors(of word: String, maxCost: Float, limit: Int, touches: [KeyTouch]? = nil) -> [Neighbor] {
        guard limit > 0, let key = Self.foldedKey(word) else { return [] }
        let n = key.count
        let maxEdits = Int(maxCost.rounded(.up))
        let substitutions = EditCost.Substitutions(typed: key, touches: touches)
        var mask: UInt32 = 0
        for b in key { if let s = Self.slot(b) { mask |= 1 << UInt32(s) } }
        var slots: [Int] = []
        if let s = Self.slot(key[0]) { slots.append(s) }
        if n > 1, let s = Self.slot(key[1]), !slots.contains(s) { slots.append(s) }
        // A thumb that lands one key off on the first letter ("rhe", "yhe" for "the") is the most
        // common touch typo the two buckets above miss, so the first letter's neighbours are
        // searched too: every key the first tap could plausibly have meant.
        for letter in UInt8(ascii: "a")...UInt8(ascii: "z") where letter != key[0] && substitutions.cost(at: 0, as: letter) < EditCost.substitution {
            if let s = Self.slot(letter), !slots.contains(s) { slots.append(s) }
        }

        var scratch = EditCost.Scratch()
        var found: [(index: Int, cost: Float)] = []
        let lowLength = max(1, n - maxEdits)
        let highLength = min(Self.maxWordLength, n + maxEdits)
        guard lowLength <= highLength else { return [] }
        let maskBudget = 2 * maxEdits
        key.withUnsafeBufferPointer { keyBuffer in
            bytes.withUnsafeBufferPointer { all in
                for length in lowLength...highLength {
                    let base = length * Self.slots
                    let first = entryStart[length]
                    let bytesBase = byteStart[length]
                    for slot in slots {
                        var index = letterStart[base + slot]
                        let end = letterStart[base + slot + 1]
                        while index < end {
                            if ranks[index] & Self.blockedBit == 0,
                               (mask ^ letterMasks[index]).nonzeroBitCount <= maskBudget {
                                let start = bytesBase + (index - first) * length
                                let candidate = UnsafeBufferPointer(rebasing: all[start..<(start + length)])
                                let cost = EditCost.cost(keyBuffer, candidate, substitutions: substitutions, limit: maxCost, scratch: &scratch)
                                if cost <= maxCost {
                                    found.append((index, cost))
                                }
                            }
                            index += 1
                        }
                    }
                }
            }
        }
        found.sort { lhs, rhs in
            if lhs.cost != rhs.cost { return lhs.cost < rhs.cost }
            return (ranks[lhs.index] & ~Self.blockedBit) < (ranks[rhs.index] & ~Self.blockedBit)
        }
        return found.prefix(limit).map { Neighbor(entry: entry(at: $0.index), cost: $0.cost) }
    }

    // MARK: Whole-list visits

    /// The entry at a stable index (`Entry.index`).
    public func entry(index: Int) -> Entry? {
        guard index >= 0, index < count else { return nil }
        return entry(at: index)
    }

    /// Visits every entry's stored bytes (display casing, so a capital first byte marks a
    /// proper noun or acronym) with its rank and whether it may be suggested, in index order,
    /// without allocating a `String` per word. For building indexes over the whole list.
    public func visitEntries(_ body: (_ index: Int, _ bytes: UnsafeBufferPointer<UInt8>, _ rank: Int, _ isSuggestible: Bool) -> Void) {
        bytes.withUnsafeBufferPointer { all in
            for length in 1...Self.maxWordLength {
                let first = entryStart[length], end = entryStart[length + 1]
                guard end > first else { continue }
                let base = byteStart[length]
                for index in first..<end {
                    let start = base + (index - first) * length
                    let raw = ranks[index]
                    body(index, UnsafeBufferPointer(rebasing: all[start..<(start + length)]),
                         Int(raw & ~Self.blockedBit), raw & Self.blockedBit == 0)
                }
            }
        }
    }

    // MARK: Internals

    private func entry(at index: Int) -> Entry {
        let length = lengthOfEntry(index)
        let start = byteStart[length] + (index - entryStart[length]) * length
        let display = String(decoding: bytes[start..<(start + length)], as: UTF8.self)
        let raw = ranks[index]
        return Entry(index: index, rank: Int(raw & ~Self.blockedBit), display: display, isSuggestible: raw & Self.blockedBit == 0)
    }

    /// True when entry `index` is a suggestible word longer than `key` (lowercased ASCII, as
    /// `foldedKey` returns) that starts with it. Reads the stored bytes; allocates nothing, so
    /// it can filter thousands of entries per keystroke.
    func isCompletion(_ index: Int, of key: [UInt8]) -> Bool {
        guard index >= 0, index < count, ranks[index] & Self.blockedBit == 0 else { return false }
        let length = lengthOfEntry(index)
        guard length > key.count else { return false }
        return comparePrefix(key, at: byteStart[length] + (index - entryStart[length]) * length) == 0
    }

    private func lengthOfEntry(_ index: Int) -> Int {
        var length = 1
        while length < Self.maxWordLength, entryStart[length + 1] <= index { length += 1 }
        return length
    }

    private func findExact(_ key: [UInt8]) -> Int? {
        let length = key.count
        guard let slot = Self.slot(key[0]) else { return nil }
        let base = length * Self.slots
        var low = letterStart[base + slot]
        var high = letterStart[base + slot + 1]
        let first = entryStart[length]
        let bytesBase = byteStart[length]
        while low < high {
            let mid = (low + high) / 2
            let order = comparePrefix(key, at: bytesBase + (mid - first) * length)
            if order == 0 { return mid }
            if order < 0 { high = mid } else { low = mid + 1 }
        }
        return nil
    }

    /// Compares the folded `key` with the stored bytes at `offset` over `key.count` bytes.
    private func comparePrefix(_ key: [UInt8], at offset: Int) -> Int {
        for i in 0..<key.count {
            let stored = bytes[offset + i] | 0x20
            if key[i] != stored { return key[i] < stored ? -1 : 1 }
        }
        return 0
    }

    /// Lowercased ASCII bytes of `word`, or nil if it contains anything but letters and apostrophes.
    static func foldedKey(_ word: String) -> [UInt8]? {
        var key = [UInt8]()
        key.reserveCapacity(word.utf8.count)
        for b in word.utf8 {
            let folded = b | 0x20
            guard slot(folded) != nil, (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x27 else { return nil }
            key.append(folded)
        }
        guard !key.isEmpty, key.count <= maxWordLength else { return nil }
        return key
    }

    /// 0...25 for a lowercase letter, 26 for the apostrophe, nil otherwise.
    @inline(__always)
    static func slot(_ folded: UInt8) -> Int? {
        if folded >= 0x61, folded <= 0x7A { return Int(folded - 0x61) }
        if folded == 0x27 { return 26 }
        return nil
    }
}
