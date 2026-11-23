// by zayd/cold @ zayd.wtf

import Foundation

/// Where a tap landed relative to the center of the key it typed, after the grid's touch bias:
/// `dx` in key pitches (a letter key's width plus the spacing), `dy` in row pitches. A tap at
/// the key's center is (0, 0); one on the boundary with the key to its right is about (0.5, 0).
public struct KeyTouch: Equatable, Sendable {
    public var dx: Float
    public var dy: Float

    public init(dx: Float, dy: Float) {
        self.dx = dx
        self.dy = dy
    }

    public static let center = KeyTouch(dx: 0, dy: 0)
}

/// Weighted Damerau-Levenshtein distance (adjacent transpositions allowed once) tuned for touch
/// typing: hitting a neighbouring key, swapping two letters and doubling or dropping a repeated
/// letter are cheaper than an arbitrary edit, so they win ties against rarer words.
///
/// Substituting one key for another costs by distance on the keyboard rather than a yes/no
/// adjacency: from the tap to the other key's center, against the tap to the typed key's center
/// (`KeyboardProximity.substitutionCost`). Without touch data the tap is taken to be the typed
/// key's center, so a side neighbour costs 0.7, a key on the row below a little more and a key
/// two away the full 1.0. A tap that landed near the boundary with the intended key makes that
/// substitution almost free, which is how "xang" can still be "can't".
public enum EditCost {
    public static let substitution: Float = 1.0
    public static let adjacentSubstitution: Float = 0.7
    /// A letter the typist left out, put back. Fast thumbs drop letters about three times as
    /// often as they add one (Palin et al., MobileHCI 2019: a third of uncorrected errors are
    /// omissions, a ninth insertions), so restoring one costs less than removing one.
    public static let insertion: Float = 0.65
    /// A letter the typist added (not a doubled one), removed.
    public static let deletion: Float = 1.0
    /// Inserting or dropping a letter next to the same letter ("untill", "tomorow").
    public static let repeatedLetter: Float = 0.6
    public static let transposition: Float = 0.7
    /// An apostrophe the typist skipped on purpose ("womens", "patsys"): it is on another layer,
    /// so people leave it out and expect the keyboard to add it.
    public static let apostrophe: Float = 0.25

    /// Reusable rows so a scan over thousands of candidates does not allocate per word.
    public struct Scratch {
        var rows: [Float] = Array(repeating: 0, count: 3 * (WordList.maxWordLength + 2))
        public init() {}
    }

    /// Per typed position, the cost of reading that letter as each of the 27 slots (a to z,
    /// apostrophe). Built once per evaluation, so the scan over candidates is a table lookup.
    public struct Substitutions {
        public static let slots = 27
        let costs: [Float]
        public let count: Int

        /// `touches` lines up with `typed` letter for letter; nil, or a different length, means
        /// no touch evidence and every tap is taken as dead center.
        public init(typed: [UInt8], touches: [KeyTouch]? = nil) {
            let usable = touches.flatMap { $0.count == typed.count ? $0 : nil }
            var costs = [Float](repeating: EditCost.substitution, count: typed.count * Self.slots)
            for (i, a) in typed.enumerated() {
                let touch = usable?[i] ?? .center
                for slot in 0..<Self.slots {
                    let b: UInt8 = slot == 26 ? 0x27 : UInt8(0x61 + slot)
                    costs[i * Self.slots + slot] = a == b ? 0 : KeyboardProximity.substitutionCost(typed: a, as: b, touch: touch)
                }
            }
            self.costs = costs
            self.count = typed.count
        }

        @inline(__always)
        func cost(at position: Int, as letter: UInt8) -> Float {
            let slot: Int
            if letter >= 0x61, letter <= 0x7A { slot = Int(letter - 0x61) } else if letter == 0x27 { slot = 26 } else { return EditCost.substitution }
            return costs[position * Self.slots + slot]
        }
    }

    /// Cost of putting back candidate letter `j` (1-based) that the typed word lacks.
    @inline(__always)
    static func insertionCost(_ b: UnsafeBufferPointer<UInt8>, at j: Int) -> Float {
        let bj = b[j - 1] | 0x20
        if bj == 0x27 { return apostrophe }
        return j >= 2 && bj == b[j - 2] | 0x20 ? repeatedLetter : insertion
    }

    /// Cost between lowercase ASCII `a` (typed) and `b` (candidate). Returns a value above `limit`
    /// as soon as no alignment can stay within it, so callers can discard early.
    public static func cost(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>, substitutions: Substitutions, limit: Float, scratch: inout Scratch) -> Float {
        let n = a.count
        let m = b.count
        if n == 0 { return Float(m) * insertion }
        if m == 0 { return Float(n) * deletion }
        let width = m + 1
        return scratch.rows.withUnsafeMutableBufferPointer { rows in
            // Three rolling rows: i-2, i-1, i.
            var previous2 = 0
            var previous = width
            var current = 2 * width
            rows[previous] = 0
            for j in 1...m {
                rows[previous + j] = rows[previous + j - 1] + insertionCost(b, at: j)
            }
            for i in 1...n {
                let ai = a[i - 1]
                let deleteCost = (i >= 2 && ai == a[i - 2]) ? repeatedLetter : deletion
                rows[current] = rows[previous] + deleteCost
                var rowMin = rows[current]
                for j in 1...m {
                    // Candidates keep their dictionary casing (Friday, NASA); compare folded, or
                    // every capitalized word paid a full substitution for its first letter.
                    let bj = b[j - 1] | 0x20
                    var best = rows[previous + j] + deleteCost
                    best = min(best, rows[current + j - 1] + insertionCost(b, at: j))
                    if ai == bj {
                        best = min(best, rows[previous + j - 1])
                    } else {
                        best = min(best, rows[previous + j - 1] + substitutions.cost(at: i - 1, as: bj))
                        if i >= 2, j >= 2, ai == b[j - 2] | 0x20, a[i - 2] == bj {
                            best = min(best, rows[previous2 + j - 2] + transposition)
                        }
                    }
                    rows[current + j] = best
                    if best < rowMin { rowMin = best }
                }
                if rowMin > limit { return rowMin }
                let next = previous2
                previous2 = previous
                previous = current
                current = next
            }
            return rows[previous + m]
        }
    }
}

/// QWERTY geometry for substitution scoring, in key units: x in key pitches with the rows
/// staggered as iOS draws them (the home row half a key in, z under s), y in rows.
public enum KeyboardProximity {
    private static let rows: [[UInt8]] = [
        Array("qwertyuiop".utf8),
        Array("asdfghjkl".utf8),
        Array("zxcvbnm".utf8),
    ]
    /// Horizontal offset of each row in key units, matching how the rows stagger on iOS.
    private static let offsets: [Float] = [0, 0.5, 1.5]

    /// A row is 54 pt apart on a key pitch of about 38.6 pt, but thumbs also miss further up
    /// and down than sideways; one row counts as this many key widths.
    static let rowDistance: Float = 1.3
    /// Cost of a substitution when the tap sat exactly on the boundary between the two keys.
    static let boundaryCost: Float = 0.1
    /// Cost growth per squared key unit the other key's center is further from the tap. Gentle on
    /// purpose: real touch clouds sit off the key centers (0.8 to 1.6 was tried with
    /// touch data and lost more slips than it won).
    static let distanceWeight: Float = 0.4
    static let floorCost: Float = 0.1

    /// Key centers for a to z: x in key pitches, y in rows; NaN for anything else.
    private static let centers: [(x: Float, y: Float)] = {
        var table = [(x: Float, y: Float)](repeating: (.nan, .nan), count: 26)
        for (r, row) in rows.enumerated() {
            for (c, key) in row.enumerated() {
                table[Int(key - 0x61)] = (Float(c) + offsets[r], Float(r))
            }
        }
        return table
    }()

    /// A letter key's center (lowercase or uppercase ASCII), x in key pitches, y in rows.
    public static func center(of letter: UInt8) -> (x: Float, y: Float)? {
        let folded = letter | 0x20
        guard folded >= 0x61, folded <= 0x7A else { return nil }
        return centers[Int(folded - 0x61)]
    }

    /// What reading typed key `typed` as `intended` costs, given where the tap landed on the
    /// typed key. A log-likelihood ratio of two keys under a round touch spread, clamped to
    /// [floorCost, substitution]: a tap on the boundary costs `boundaryCost`, one at the typed
    /// key's center costs more the further away the other key is.
    public static func substitutionCost(typed: UInt8, as intended: UInt8, touch: KeyTouch = .center) -> Float {
        guard typed >= 0x61, typed <= 0x7A, intended >= 0x61, intended <= 0x7A else { return EditCost.substitution }
        let a = centers[Int(typed - 0x61)], b = centers[Int(intended - 0x61)]
        let dx = a.x + touch.dx - b.x, dy = (a.y + touch.dy - b.y) * rowDistance
        let toTyped = touch.dx * touch.dx + (touch.dy * rowDistance) * (touch.dy * rowDistance)
        let toIntended = dx * dx + dy * dy
        let cost = boundaryCost + distanceWeight * (toIntended - toTyped)
        return min(max(cost, floorCost), EditCost.substitution)
    }

    /// True for two keys whose substitution without touch data costs less than an arbitrary
    /// edit: side neighbours and the keys above and below.
    @inline(__always)
    public static func areAdjacent(_ a: UInt8, _ b: UInt8) -> Bool {
        guard a != b else { return false }
        return substitutionCost(typed: a, as: b) < EditCost.substitution
    }
}
