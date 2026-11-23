// by zayd/cold @ zayd.wtf

import Foundation

/// What one person's swipes have taught the keyboard: bounded word/context counts, never raw traces or full messages.
///
/// Three tables, each capped and trimmed oldest-first:
/// - `choices`: words explicitly selected from the alternatives. Pulls that word up next time its shape is ambiguous.
/// - `pairs`: `previous:word`, the same evidence with the word before it, so "see you"
///   wins over "see tou" after "see".
/// - `rejections`: words deleted right after they were swiped (FUTO's rule for "swiping again
///   gives the same wrong word"). Pushes the word down; a later choice of it forgives one.
///
/// Plus the swipe equivalent of the learned tap offsets: where this person's touch-down and
/// lift-off sit relative to the first and last key, per row, shrunk toward zero with little
/// data. Offsets are in key pitches, so they survive rotation and width changes.
public struct SwipeLearning: Codable, Equatable, Sendable {
    public struct Count: Codable, Equatable, Sendable {
        public var count: Int
        public var sequence: Int
    }

    public private(set) var choices: [String: Count] = [:]
    public private(set) var pairs: [String: Count] = [:]
    public private(set) var rejections: [String: Count] = [:]
    /// Per row (top, home, bottom): decayed sums of the start offset, the end offset, and weights.
    var startX: [Double] = [0, 0, 0]
    var startY: [Double] = [0, 0, 0]
    var startWeight: [Double] = [0, 0, 0]
    var endX: [Double] = [0, 0, 0]
    var endY: [Double] = [0, 0, 0]
    var endWeight: [Double] = [0, 0, 0]
    private var sequence = 0

    public static let capacity = 2_000
    public static let maximumCount = 100
    /// Swipes after which an old offset's weight has decayed by 1/e, and the pseudo-count
    /// shrinking a row's mean toward zero.
    static let offsetWindow: Double = 300
    static let offsetPrior: Double = 20
    /// Most the learned offset may move an endpoint, in pitches.
    public static let maximumOffset: Float = 0.35

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case choices, pairs, rejections, startX, startY, startWeight, endX, endY, endWeight, sequence
    }

    /// Rejects a damaged record whole, so the decoder never reads a table it cannot trust.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        choices = try c.decodeIfPresent([String: Count].self, forKey: .choices) ?? [:]
        pairs = try c.decodeIfPresent([String: Count].self, forKey: .pairs) ?? [:]
        rejections = try c.decodeIfPresent([String: Count].self, forKey: .rejections) ?? [:]
        startX = try c.decodeIfPresent([Double].self, forKey: .startX) ?? [0, 0, 0]
        startY = try c.decodeIfPresent([Double].self, forKey: .startY) ?? [0, 0, 0]
        startWeight = try c.decodeIfPresent([Double].self, forKey: .startWeight) ?? [0, 0, 0]
        endX = try c.decodeIfPresent([Double].self, forKey: .endX) ?? [0, 0, 0]
        endY = try c.decodeIfPresent([Double].self, forKey: .endY) ?? [0, 0, 0]
        endWeight = try c.decodeIfPresent([Double].self, forKey: .endWeight) ?? [0, 0, 0]
        sequence = try c.decodeIfPresent(Int.self, forKey: .sequence) ?? 0
        let tables = [choices, pairs, rejections]
        let offsets = [startX, startY, startWeight, endX, endY, endWeight]
        guard tables.allSatisfy({ $0.count <= Self.capacity }), sequence >= 0, sequence < Int.max - 1,
              tables.joined().allSatisfy({ (1...Self.maximumCount).contains($0.value.count) && $0.value.sequence >= 0 && $0.value.sequence <= sequence }),
              offsets.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }),
              startWeight.allSatisfy({ $0 >= 0 }), endWeight.allSatisfy({ $0 >= 0 }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid swipe learning record"))
        }
    }

    /// The table key for a word: lowercase, letters and apostrophes only, 2 to 24 long.
    public static func key(_ word: String) -> String? {
        let word = word.replacingOccurrences(of: "\u{2019}", with: "'")
        guard (2...WordList.maxWordLength).contains(word.count), word.first?.isLetter == true,
              word.last?.isLetter == true, word.allSatisfy({ $0.isLetter || $0 == "'" }) else { return nil }
        return word.lowercased()
    }

    // MARK: Evidence

    /// An explicit alternative was selected. `previous` is the word before it, if any.
    public mutating func chose(_ word: String, after previous: String? = nil) {
        guard let key = Self.key(word) else { return }
        sequence = min(sequence, Self.sequenceLimit) + 1
        Self.bump(&choices, key, sequence: sequence)
        if let previous, let p = Self.key(previous) { Self.bump(&pairs, p + ":" + key, sequence: sequence) }
        // One rejection is forgiven: the person meant it after all.
        if var r = rejections[key] {
            r.count -= 1
            if r.count <= 0 { rejections[key] = nil } else { rejections[key] = r }
        }
    }

    /// A swiped word was deleted right away.
    public mutating func rejected(_ word: String) {
        guard let key = Self.key(word) else { return }
        sequence = min(sequence, Self.sequenceLimit) + 1
        Self.bump(&rejections, key, sequence: sequence)
    }

    private static let sequenceLimit = Int.max - 2

    private static func bump(_ table: inout [String: Count], _ key: String, sequence: Int) {
        let count = min((table[key]?.count ?? 0) + 1, Self.maximumCount)
        table[key] = Count(count: count, sequence: sequence)
        if table.count > Self.capacity {
            let kept = table.sorted { $0.value.sequence > $1.value.sequence }.prefix(Self.capacity)
            table = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
    }

    public func choices(of word: String) -> Int { choices[word.lowercased()]?.count ?? 0 }
    public func pairs(previous: String, word: String) -> Int { pairs[previous.lowercased() + ":" + word.lowercased()]?.count ?? 0 }
    public func rejections(of word: String) -> Int { rejections[word.lowercased()]?.count ?? 0 }

    /// Words this person has swiped, most recent first, for the decoder's personal set.
    public var words: [String] {
        choices.sorted { $0.value.sequence > $1.value.sequence }.map(\.key)
    }

    /// `words` spelled the way the keyboard writes them. The table keys are lowercase, and a
    /// personal word overrides the dictionary's casing, so handing the keys over as they are
    /// turned a chosen "Google" into "google" and "I'm" into "i'm" for every later swipe.
    public func words(spelledBy list: WordList) -> [String] {
        words.map { key in ModernVocabulary.names[key] ?? list.lookup(key)?.display ?? key }
    }

    // MARK: Endpoint offsets

    /// A swipe stood: where its touch-down sat relative to the first key (`start`, in pitches),
    /// and its lift-off relative to the last key (`end`), with the rows those keys are on.
    public mutating func learnEndpoints(start: SwipePoint, startRow: Int, end: SwipePoint, endRow: Int) {
        guard (0..<3).contains(startRow), (0..<3).contains(endRow),
              start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite,
              abs(start.x) <= 1.5, abs(start.y) <= 1.5, abs(end.x) <= 2, abs(end.y) <= 2 else { return }
        let keep = 1 - 1 / Self.offsetWindow
        for i in 0..<3 {
            startX[i] *= keep; startY[i] *= keep; startWeight[i] *= keep
            endX[i] *= keep; endY[i] *= keep; endWeight[i] *= keep
        }
        startX[startRow] += Double(start.x); startY[startRow] += Double(start.y); startWeight[startRow] += 1
        endX[endRow] += Double(end.x); endY[endRow] += Double(end.y); endWeight[endRow] += 1
    }

    /// Where this person's touch-downs land relative to the key on `row`, shrunk toward zero.
    public func startOffset(row: Int) -> SwipePoint {
        guard (0..<3).contains(row) else { return SwipePoint(x: 0, y: 0) }
        let w = startWeight[row] + Self.offsetPrior
        return SwipePoint(x: Self.clamp(Float(startX[row] / w)), y: Self.clamp(Float(startY[row] / w)))
    }

    public func endOffset(row: Int) -> SwipePoint {
        guard (0..<3).contains(row) else { return SwipePoint(x: 0, y: 0) }
        let w = endWeight[row] + Self.offsetPrior
        return SwipePoint(x: Self.clamp(Float(endX[row] / w)), y: Self.clamp(Float(endY[row] / w)))
    }

    private static func clamp(_ v: Float) -> Float { min(max(v, -maximumOffset), maximumOffset) }

    /// Swipes that have taught the offsets, after decay.
    public var endpointSamples: Double { startWeight.reduce(0, +) }
}
