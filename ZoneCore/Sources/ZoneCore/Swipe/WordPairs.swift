// by zayd/cold @ zayd.wtf

import Foundation

/// A word-pair prior for the swipe decoder: how likely each word is after the word before it.
///
/// Built by `scripts/swipe-eval/build-wordpairs.py` from conversational text into `en-pairs.bin`, mapped
/// read-only so its pages stay clean and leave the keyboard's footprint once touched. Costs are
/// `-log P(word | previous)` in nats from absolute discounting, quantized to sixteenths. For a
/// pair not in the table the cost is the previous word's backoff plus the word's unigram cost,
/// so every candidate gets a number on the same scale.
///
/// Layout (little endian): `ZPR1`, word count, 64-bit FNV-1a of the word list's bytes (so a
/// table built from another list is refused), pair count, unigram constant (Float32), then
/// `wordCount` backoff bytes, `wordCount + 1` UInt32 offsets, `pairCount` UInt32 next-word
/// indexes (ascending within each previous word), `pairCount` cost bytes.
public final class WordPairs: SwipeContextModel, @unchecked Sendable {
    public static let scale: Float = 16
    private let data: Data
    private let wordCount: Int
    public let pairCount: Int
    private let unigramConstant: Float
    private let backoffStart: Int
    private let offsetStart: Int
    private let nextStart: Int
    private let costStart: Int
    private let ranks: [Int32]

    /// Nil when the file is missing, malformed, or built from a different word list.
    public convenience init?(url: URL, words: WordList) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        self.init(data: data, words: words)
    }

    public init?(data: Data, words: WordList) {
        guard data.count >= 24 else { return nil }
        func u32(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
        }
        guard data[0] == 0x5A, data[1] == 0x50, data[2] == 0x52, data[3] == 0x31 else { return nil }
        let count = Int(u32(4))
        let digest = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self).littleEndian }
        let pairs = Int(u32(16))
        let constant = Float(bitPattern: u32(20))
        guard count == words.count, digest == Self.digest(of: words), pairs >= 0, constant.isFinite else { return nil }
        backoffStart = 24
        offsetStart = backoffStart + count
        nextStart = offsetStart + (count + 1) * 4
        costStart = nextStart + pairs * 4
        guard data.count == costStart + pairs else { return nil }
        self.data = data
        wordCount = count
        pairCount = pairs
        unigramConstant = constant
        var ranks = [Int32](repeating: 0, count: count)
        words.visitEntries { index, _, rank, _ in ranks[index] = Int32(rank) }
        self.ranks = ranks
        // The last offset must close the table; a bad one would read past the end.
        guard Int(u32(offsetStart + count * 4)) == pairs else { return nil }
    }

    /// The table in `bundle` (the keyboard extension ships it; the app has no use for it), if
    /// it matches `words`.
    public static func load(from bundle: Bundle, words: WordList) -> WordPairs? {
        guard let url = bundle.url(forResource: "en-pairs", withExtension: "bin") else { return nil }
        return WordPairs(url: url, words: words)
    }

    /// The main bundle's table for `WordList.shared`, opened once per process: swipe typing and
    /// tap autocorrect read the same one.
    public static let shared: WordPairs? = WordList.shared.flatMap { load(from: .main, words: $0) }

    /// 64-bit FNV-1a over every entry's bytes in index order.
    public static func digest(of words: WordList) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        words.visitEntries { _, bytes, _, _ in
            for b in bytes {
                hash ^= UInt64(b)
                hash = hash &* 0x100000001b3
            }
        }
        return hash
    }

    @inline(__always)
    private func u32(_ offset: Int) -> UInt32 {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
    }

    /// `-log P(word | previous)` in nats.
    public func cost(of entryIndex: Int, after previousIndex: Int) -> Float? {
        guard previousIndex >= 0, previousIndex < wordCount, entryIndex >= 0, entryIndex < wordCount else { return nil }
        if let seen = seenCost(of: entryIndex, after: previousIndex) { return seen }
        let backoff = Float(data[backoffStart + previousIndex]) / Self.scale
        return backoff + unigramCost(of: entryIndex)
    }

    /// The cost of a pair the table holds, or nil for one it never saw (which `cost` prices by
    /// backing off): the difference between "follows this word" and "is a common word".
    public func seenCost(of entryIndex: Int, after previousIndex: Int) -> Float? {
        guard previousIndex >= 0, previousIndex < wordCount, entryIndex >= 0, entryIndex < wordCount else { return nil }
        var low = Int(u32(offsetStart + previousIndex * 4))
        var high = Int(u32(offsetStart + (previousIndex + 1) * 4))
        guard low <= high, high <= pairCount else { return nil }
        let wanted = UInt32(entryIndex)
        while low < high {
            let mid = (low + high) / 2
            let next = u32(nextStart + mid * 4)
            if next == wanted { return Float(data[costStart + mid]) / Self.scale }
            if next < wanted { low = mid + 1 } else { high = mid }
        }
        return nil
    }

    public func cost(rank: Float, after previousIndex: Int) -> Float? {
        guard previousIndex >= 0, previousIndex < wordCount, rank.isFinite, rank >= 0 else { return nil }
        return Float(data[backoffStart + previousIndex]) / Self.scale + log(rank + 2) + unigramConstant
    }

    /// What a pair the table never saw pays on top of the word's unigram cost, in nats.
    public func backoff(after previousIndex: Int) -> Float {
        guard previousIndex >= 0, previousIndex < wordCount else { return 0 }
        return Float(data[backoffStart + previousIndex]) / Self.scale
    }

    /// `-log P(word)` from its rank, on the Zipf curve the builder fitted.
    public func unigramCost(of entryIndex: Int) -> Float {
        log(Float(ranks[entryIndex]) + 2) + unigramConstant
    }

    /// True when the table has pairs starting with this word.
    public func knows(previous entryIndex: Int) -> Bool {
        guard entryIndex >= 0, entryIndex < wordCount else { return false }
        return u32(offsetStart + (entryIndex + 1) * 4) > u32(offsetStart + entryIndex * 4)
    }

    /// The words most likely to follow `previousIndex`, likeliest first: the table's own pairs
    /// only, so a word it never saw after this one is never offered. `allowed` filters by entry
    /// index and is asked only about a pair that would make the list. Equal costs (they are
    /// quantized) go to the commoner word. A linear pass over that word's pairs: the longest
    /// run in the shipped table ("the") is about 26,000 one-byte costs.
    public func successors(after previousIndex: Int, limit: Int, allowed: (Int) -> Bool = { _ in true }) -> [Int] {
        guard limit > 0, previousIndex >= 0, previousIndex < wordCount else { return [] }
        let low = Int(u32(offsetStart + previousIndex * 4))
        let high = Int(u32(offsetStart + (previousIndex + 1) * 4))
        guard low < high, high <= pairCount else { return [] }
        var best: [(cost: UInt8, rank: Int32, index: Int)] = []
        best.reserveCapacity(limit + 1)
        data.withUnsafeBytes { raw in
            for position in low..<high {
                let cost = raw[costStart + position]
                if best.count == limit, cost > best[limit - 1].cost { continue }
                let index = Int(raw.loadUnaligned(fromByteOffset: nextStart + position * 4, as: UInt32.self).littleEndian)
                guard index < wordCount else { continue }
                let rank = ranks[index]
                if best.count == limit, cost == best[limit - 1].cost, rank >= best[limit - 1].rank { continue }
                guard allowed(index) else { continue }
                let at = best.firstIndex { cost < $0.cost || (cost == $0.cost && rank < $0.rank) } ?? best.count
                best.insert((cost, rank, index), at: at)
                if best.count > limit { best.removeLast() }
            }
        }
        return best.map(\.index)
    }
}
