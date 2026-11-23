// by zayd/cold @ zayd.wtf

import Foundation

/// The decoder's weights, in one place so the evaluation harness can sweep them. Defaults are
/// the values tuned on the swipe.futo.org dev split (docs/research/swipe-2026-11-08).
public struct SwipeTuning: Equatable, Sendable {
    /// Weight of the squared distance between the trace's first point and the word's first key.
    /// Touch-down is the most reliable sample of a swipe (std 0.28 pitch across the corpus).
    public var startWeight: Float = 0.3
    /// The same for lift-off, which is far sloppier (std 0.48 pitch), so it counts for less.
    public var endWeight: Float = 0.05
    /// Weight of `log(rank + 2)`: how much a common word beats a rare one of the same shape.
    public var priorWeight: Float = 0.045
    /// Weight of the shape channel (location and scale removed), zero to switch it off.
    public var shapeWeight: Float = 0
    /// Weight of the context model's `-log P(word | previous)`. Tuned with the shipped
    /// subtitle pair table on 11,109 dev swipes (docs/research/swipe-context-2026-11-08).
    public var contextWeight: Float = 0.05
    /// Added to a dictionary entry that starts with a capital (proper nouns, acronyms), unless
    /// it is a personal word or a word this person has swiped before.
    public var casingPenalty: Float = 0.1
    /// Bonus per log unit of the user's own swipe choices and word pairs, and their caps.
    public var choiceWeight: Float = 0.045
    public var choiceCap: Float = 0.18
    public var pairWeight: Float = 0.06
    public var pairCap: Float = 0.2
    /// Penalty for a word the user deleted right after swiping it, per rejection, capped.
    public var rejectionWeight: Float = 0.12
    public var rejectionCap: Float = 0.36
    /// Samples along the trace and each template: `samplesPerPitch` times the trace length,
    /// clamped. Both sides always use the same count.
    public var samplesPerPitch: Float = 4
    public var minimumSamples = 24
    public var maximumSamples = 56
    /// Warping tolerance of the DTW pass, in samples either way.
    public var band = 4
    /// Candidates must start within `startRadius` of the touch-down and end within `endRadius`
    /// of the lift-off, in pitches.
    public var startRadius: Float = 1.5
    public var endRadius: Float = 2.2
    /// Every letter of a candidate must have its key within this distance of some trace point.
    /// Zero switches the prune off.
    public var visitRadius: Float = 1.25
    /// How many prefiltered candidates reach the DTW pass.
    public var shortlist = 96
    /// A candidate's ideal path length must satisfy `trace < ideal * slack + pad` and the reverse.
    public var lengthSlack: Float = 2.2
    public var lengthPad: Float = 2
    /// Traces shorter than this (in pitches) are taps, not swipes, and decode to nothing.
    public var minimumLength: Float = 0.5
    /// Vertical distances are multiplied by this before matching. Rows are taller than keys are
    /// wide, and a thumb's vertical error is smaller in proportion, so less than one weights a
    /// row miss like a key miss.
    public var yScale: Float = 1

    public init() {}
}

/// One decoded word.
public struct SwipeCandidate: Equatable, Sendable {
    /// Dictionary casing ("Monday", "don't"), or the personal word as the user spelled it.
    public let word: String
    /// Lower is better; the gap between the first two says how sure the decoder is.
    public let score: Float
    /// The word's index in the `WordList`, nil for a personal word.
    public let entryIndex: Int?

    public init(word: String, score: Float, entryIndex: Int?) {
        self.word = word
        self.score = score
        self.entryIndex = entryIndex
    }
}

/// What the decoder knows besides the trace.
public struct SwipeContext: Sendable {
    /// The word before the cursor, if any, for the context model and the user's pair counts.
    public var previousWord: String?
    /// This person's swipe history.
    public var learning: SwipeLearning
    /// Words to leave out of this decode (the one just deleted, when the user swipes again).
    public var excluded: Set<String>

    public init(previousWord: String? = nil, learning: SwipeLearning = SwipeLearning(), excluded: Set<String> = []) {
        self.previousWord = previousWord
        self.learning = learning
        self.excluded = excluded
    }
}

/// A word-pair prior: `-log P(word | previous)` in nats, or nil when the pair is unknown.
public protocol SwipeContextModel: AnyObject, Sendable {
    func cost(of entryIndex: Int, after previousIndex: Int) -> Float?
    /// The cost of a word outside the list (a personal word) at this frequency rank: the
    /// previous word's backoff plus a unigram cost, so it pays like an unseen dictionary pair
    /// instead of skipping the context term every dictionary candidate pays.
    func cost(rank: Float, after previousIndex: Int) -> Float?
}

/// Decodes a swiped path into dictionary words.
///
/// A template matcher in the SHARK2 family, tuned on 2,000 human swipes and evaluated on the held-out test split (docs/research/swipe-2026-11-08): the trace and every candidate word's ideal path (its
/// key centers, doubled letters collapsed) are resampled to the same number of points by arc
/// length, so speed drops out; candidates are found through the keys near the touch-down and
/// the lift-off, pruned by the keys the trace passed and by path length, ranked by direct
/// point distance, and the best few dozen are re-scored by a banded dynamic time warp that
/// forgives a corner taken early or late. Word frequency, the previous word, and the person's
/// own swipe history settle paths that geometry cannot (to, too, top).
///
/// Memory: no templates are stored. The index is a few bytes per word (its folded letters, a
/// bucket by first and last key), and templates are built on the fly for the few hundred
/// candidates of one decode. This class runs on the calling thread; SwipeEngine owns a serial
/// background worker. Corpus timings are Mac measurements, not iPhone extension benchmarks.
///
/// Immutable once built except for the personal-word set, which is replaced whole under a lock.
public final class SwipeDecoder: @unchecked Sendable {
    public let tuning: SwipeTuning
    private let words: WordList

    /// Letters of each swipeable entry, consecutive duplicates removed, as 0 to 25.
    private let letters: [UInt8]
    private let letterStart: [Int32]
    private let entryIndex: [Int32]
    private let ranks: [Int32]
    private let masks: [UInt32]
    private let capitalized: [Bool]
    /// Entries by first and last letter (`first * 26 + last`).
    private let buckets: [[Int32]]

    private struct Personal {
        var words: [String] = []
        /// A starter word's own frequency rank; nil for the person's words (personal rank).
        var ranks: [Float?] = []
        var letters: [[UInt8]] = []
        var buckets: [Int: [Int]] = [:]
        var dictionaryEntries: Set<Int32> = []
        /// A capitalized name from the broad built-in list (`ModernVocabulary.broadNames`): it pays
        /// the casing penalty a capitalized dictionary word pays, so "Fergusson" does not win a
        /// swipe meant for "fashion" that the list's own "Ferguson" would lose.
        var broadName: [Bool] = []
    }
    private var personal = Personal()
    private let lock = NSLock()
    public private(set) var context: SwipeContextModel?

    public init(words: WordList, tuning: SwipeTuning = SwipeTuning(), context: SwipeContextModel? = nil) {
        self.words = words
        self.tuning = tuning
        self.context = context
        var letters: [UInt8] = []
        letters.reserveCapacity(words.count * 6)
        var starts: [Int32] = [0]
        var indexes: [Int32] = []
        var ranks: [Int32] = []
        var masks: [UInt32] = []
        var capitalized: [Bool] = []
        var buckets = [[Int32]](repeating: [], count: 26 * 26)
        words.visitEntries { index, bytes, rank, suggestible in
            // A deliberate swipe is text input, not an unsolicited autocorrect suggestion.
            // Keep no-suggest flags in the tap engine, but allow these words to be traced.
            _ = suggestible
            var sequence: [UInt8] = []
            var mask: UInt32 = 0
            for b in bytes {
                let folded = b | 0x20
                guard folded >= 0x61, folded <= 0x7A else { continue } // apostrophes drop out
                let letter = folded - 0x61
                mask |= 1 << UInt32(letter)
                if sequence.last != letter { sequence.append(letter) }
            }
            // One distinct key is a tap, never a swipe.
            guard sequence.count >= 2 else { return }
            let id = Int32(indexes.count)
            letters.append(contentsOf: sequence)
            starts.append(Int32(letters.count))
            indexes.append(Int32(index))
            ranks.append(Int32(rank))
            masks.append(mask)
            capitalized.append(bytes[0] >= 0x41 && bytes[0] <= 0x5A)
            buckets[Int(sequence[0]) * 26 + Int(sequence[sequence.count - 1])].append(id)
        }
        self.letters = letters
        self.letterStart = starts
        self.entryIndex = indexes
        self.ranks = ranks
        self.masks = masks
        self.capitalized = capitalized
        self.buckets = buckets
        setPersonalWords([])
    }

    /// Personal vocabulary, contacts and learned spellings override dictionary casing and
    /// eligibility. They get a fairly common prior, preserving any better dictionary rank.
    /// The swipe-only starter vocabulary follows explicit personal spellings, each at its own
    /// measured frequency rank (or its dictionary rank, if better).
    public func setPersonalWords(_ list: [String], starter: [(word: String, rank: Int)] = SwipeVocabulary.starter + ModernVocabulary.swipeWords) {
        var next = Personal()
        var seen = Set<String>()
        let starterRanks = Dictionary(starter.map { ($0.word.lowercased(), Float($0.rank)) }, uniquingKeysWith: min)
        let personalCount = list.count
        for (position, word) in (list + starter.map(\.word)).enumerated() {
            let trimmed = word.replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .whitespaces)
            guard (2...WordList.maxWordLength).contains(trimmed.count), seen.insert(trimmed.lowercased()).inserted else { continue }
            var sequence: [UInt8] = []
            var valid = true
            for b in trimmed.utf8 {
                let folded = b | 0x20
                if b == 0x27 { continue }
                guard folded >= 0x61, folded <= 0x7A else { valid = false; break }
                let letter = folded - 0x61
                if sequence.last != letter { sequence.append(letter) }
            }
            guard valid, sequence.count >= 2 else { continue }
            let id = next.words.count
            if let entry = words.lookup(trimmed) { next.dictionaryEntries.insert(Int32(entry.index)) }
            next.words.append(trimmed)
            next.ranks.append(position < personalCount ? nil : starterRanks[trimmed.lowercased()])
            next.broadName.append(position >= personalCount && ModernVocabulary.broadNames.contains(trimmed.lowercased()))
            next.letters.append(sequence)
            next.buckets[Int(sequence[0]) * 26 + Int(sequence[sequence.count - 1]), default: []].append(id)
        }
        lock.lock()
        personal = next
        lock.unlock()
    }

    public func setContextModel(_ model: SwipeContextModel?) {
        lock.lock()
        context = model
        lock.unlock()
    }

    /// Rank of a personal word: common enough to beat a rare dictionary word of the same shape.
    static let personalRank: Float = 1_500

    private struct Scored {
        var id: Int32          // index into the decoder's arrays, or -1 - personalId
        var direct: Float
        var startD2: Float
        var endD2: Float
    }

    // MARK: Decoding

    /// The best `limit` words for a trace, best first. Empty for a trace too short to be a swipe
    /// or one that starts and ends nowhere near any key.
    public func decode(_ points: [SwipePoint], layout: SwipeLayout, context ctx: SwipeContext = SwipeContext(), limit: Int = 5) -> [SwipeCandidate] {
        guard limit > 0, points.count >= 2, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return [] }
        var t = tuning
        let rawX = points.map(\.x)
        var rawY = points.map(\.y)
        var layout = layout
        if t.yScale != 1 {
            rawY = rawY.map { $0 * t.yScale }
            layout = SwipeLayout(x: layout.x, y: layout.y.map { $0 * t.yScale }, rowPitch: layout.rowPitch * t.yScale)
        }
        t.yScale = 1
        let traceLength = SwipePath.length(xs: rawX, ys: rawY)
        guard traceLength >= t.minimumLength else { return [] }
        let n = min(max(Int(t.samplesPerPitch * traceLength), t.minimumSamples), t.maximumSamples)
        let trace = SwipePath.resample(xs: rawX, ys: rawY, count: n)
        let sx = rawX[0], sy = rawY[0], ex = rawX[rawX.count - 1], ey = rawY[rawY.count - 1]
        let starts = layout.letters(near: sx, sy, within: t.startRadius)
        let ends = layout.letters(near: ex, ey, within: t.endRadius)
        guard !starts.isEmpty, !ends.isEmpty else { return [] }
        let visited = t.visitRadius > 0 ? layout.visitedMask(xs: rawX, ys: rawY, radius: t.visitRadius) : UInt32.max

        lock.lock()
        let personal = self.personal
        let contextModel = self.context
        lock.unlock()

        // Prefilter: every word in the start/end buckets that the trace could have drawn.
        var scored: [Scored] = []
        scored.reserveCapacity(512)
        var tx = [Float](repeating: 0, count: 0), ty = [Float](repeating: 0, count: 0)
        var px = [Float](), py = [Float]()
        px.reserveCapacity(WordList.maxWordLength)
        py.reserveCapacity(WordList.maxWordLength)
        let maxIdeal = (traceLength - t.lengthPad) / t.lengthSlack
        let minIdeal = traceLength * t.lengthSlack + t.lengthPad

        func consider(id: Int32, sequence: UnsafeBufferPointer<UInt8>, mask: UInt32) {
            guard mask & ~visited == 0 else { return }
            px.removeAll(keepingCapacity: true)
            py.removeAll(keepingCapacity: true)
            var ideal: Float = 0
            for (k, letter) in sequence.enumerated() {
                let i = Int(letter)
                guard layout.has(i) else { return }
                let cx = layout.x[i], cy = layout.y[i]
                if k > 0 {
                    let dx = cx - px[k - 1], dy = cy - py[k - 1]
                    ideal += (dx * dx + dy * dy).squareRoot()
                }
                px.append(cx)
                py.append(cy)
            }
            // Length gate, both ways (a short trace cannot be a long word and the reverse).
            guard ideal >= maxIdeal, ideal <= minIdeal else { return }
            let template = SwipePath.resample(xs: px, ys: py, count: n)
            tx = template.xs
            ty = template.ys
            var direct: Float = 0
            for i in 0..<n {
                let dx = trace.xs[i] - tx[i], dy = trace.ys[i] - ty[i]
                direct += dx * dx + dy * dy
            }
            direct /= Float(n)
            let sdx = sx - px[0], sdy = sy - py[0]
            let edx = ex - px[px.count - 1], edy = ey - py[py.count - 1]
            scored.append(Scored(id: id, direct: direct, startD2: sdx * sdx + sdy * sdy, endD2: edx * edx + edy * edy))
        }

        letters.withUnsafeBufferPointer { all in
            for first in starts {
                for last in ends {
                    for id in buckets[first * 26 + last] {
                        if personal.dictionaryEntries.contains(entryIndex[Int(id)]) { continue }
                        let from = Int(letterStart[Int(id)]), to = Int(letterStart[Int(id) + 1])
                        consider(id: id, sequence: UnsafeBufferPointer(rebasing: all[from..<to]), mask: masks[Int(id)])
                    }
                    if let ids = personal.buckets[first * 26 + last] {
                        for id in ids {
                            var mask: UInt32 = 0
                            for letter in personal.letters[id] { mask |= 1 << UInt32(letter) }
                            personal.letters[id].withUnsafeBufferPointer { consider(id: -1 - Int32(id), sequence: $0, mask: mask) }
                        }
                    }
                }
            }
        }
        guard !scored.isEmpty else { return [] }

        // Shortlist by the cheap distance plus the endpoint terms, then warp.
        scored.sort { ($0.direct + t.startWeight * $0.startD2 + t.endWeight * $0.endD2) < ($1.direct + t.startWeight * $1.startD2 + t.endWeight * $1.endD2) }
        let shape = t.shapeWeight > 0 ? SwipePath.normalizedShape(xs: trace.xs, ys: trace.ys) : (xs: [], ys: [])
        let previousIndex = ctx.previousWord.flatMap { words.lookup($0)?.index }
        let previousKey = ctx.previousWord.flatMap(SwipeLearning.key)
        var results: [SwipeCandidate] = []
        results.reserveCapacity(min(t.shortlist, scored.count))
        var seen = Set<String>()
        var dtwPrevious = [Float](repeating: 0, count: n + 1)
        var dtwCurrent = [Float](repeating: 0, count: n + 1)

        for s in scored.prefix(t.shortlist) {
            let sequence: [UInt8]
            let word: String
            let rank: Float
            let entry: Int?
            /// The list entry a personal word shares, for the context model only.
            let contextEntry: Int?
            let isCapitalized: Bool
            if s.id >= 0 {
                let id = Int(s.id)
                sequence = Array(letters[Int(letterStart[id])..<Int(letterStart[id + 1])])
                guard let e = words.entry(index: Int(entryIndex[id])) else { continue }
                word = e.display
                rank = Float(ranks[id])
                entry = e.index
                contextEntry = e.index
                isCapitalized = capitalized[id]
            } else {
                let id = Int(-1 - s.id)
                sequence = personal.letters[id]
                word = personal.words[id]
                let listed = words.lookup(word)
                let own = personal.ranks[id] ?? Self.personalRank
                rank = min(own, listed.map { Float($0.rank) } ?? own)
                entry = nil
                contextEntry = listed?.index
                isCapitalized = personal.broadName[id]
            }
            let key = word.lowercased()
            guard !ctx.excluded.contains(key) else { continue }
            px.removeAll(keepingCapacity: true)
            py.removeAll(keepingCapacity: true)
            for letter in sequence {
                px.append(layout.x[Int(letter)])
                py.append(layout.y[Int(letter)])
            }
            let template = SwipePath.resample(xs: px, ys: py, count: n)
            let warped = Self.warpedDistance(trace.xs, trace.ys, template.xs, template.ys, band: t.band, previous: &dtwPrevious, current: &dtwCurrent)
            var score = warped + t.startWeight * s.startD2 + t.endWeight * s.endD2 + t.priorWeight * log(rank + 2)
            if t.shapeWeight > 0 {
                let ts = SwipePath.normalizedShape(xs: template.xs, ys: template.ys)
                var d: Float = 0
                for i in 0..<n {
                    let dx = shape.xs[i] - ts.xs[i], dy = shape.ys[i] - ts.ys[i]
                    d += dx * dx + dy * dy
                }
                score += t.shapeWeight * d / Float(n)
            }
            let chosen = ctx.learning.choices(of: key)
            if isCapitalized, chosen == 0 { score += t.casingPenalty }
            if chosen > 0 { score -= min(t.choiceCap, t.choiceWeight * log(Float(chosen) + 1)) }
            if let previousKey {
                let pairs = ctx.learning.pairs(previous: previousKey, word: key)
                if pairs > 0 { score -= min(t.pairCap, t.pairWeight * log(Float(pairs) + 1)) }
            }
            let rejected = ctx.learning.rejections(of: key)
            if rejected > 0 { score += min(t.rejectionCap, t.rejectionWeight * Float(rejected)) }
            if let contextModel, let previousIndex,
               let cost = contextEntry.map({ contextModel.cost(of: $0, after: previousIndex) }) ?? contextModel.cost(rank: rank, after: previousIndex) {
                score += t.contextWeight * cost
            }
            if seen.insert(key).inserted {
                results.append(SwipeCandidate(word: word, score: score, entryIndex: entry))
            }
        }
        results.sort { $0.score == $1.score ? $0.word < $1.word : $0.score < $1.score }
        return Array(results.prefix(limit))
    }

    /// Mean squared distance along the cheapest monotonic alignment within `band` samples of
    /// the diagonal. Both paths have the same count.
    static func warpedDistance(_ ax: [Float], _ ay: [Float], _ bx: [Float], _ by: [Float], band: Int,
                               previous: inout [Float], current: inout [Float]) -> Float {
        let n = ax.count
        for j in 0...n { previous[j] = .infinity }
        previous[0] = 0
        for i in 0..<n {
            for j in 0...n { current[j] = .infinity }
            let lo = max(0, i - band), hi = min(n - 1, i + band)
            let x = ax[i], y = ay[i]
            for j in lo...hi {
                let dx = x - bx[j], dy = y - by[j]
                let best = min(previous[j], previous[j + 1], current[j])
                current[j + 1] = dx * dx + dy * dy + best
            }
            swap(&previous, &current)
        }
        return previous[n] / Float(n)
    }
}
