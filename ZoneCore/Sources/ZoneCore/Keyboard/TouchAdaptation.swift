// by zayd/cold @ zayd.wtf

import CoreGraphics
import Foundation

/// Learns where one person's taps land on each letter key, so the key grid can aim where they
/// actually tap. Thumbs miss in consistent, personal directions (Azenkot and Zhai, MobileHCI
/// 2012: per-key touch clouds are Gaussians off the key centers, and people differ more from each
/// other than each varies; two-thumb typists undershoot keys far from each thumb), and Gboard
/// ships exactly this personalization (Sivek and Riley, "Spatial model personalization in
/// Gboard", 2022): per-key-cluster offset means learned from the touches of committed words.
///
/// The rules follow Gboard's: learn only from words that were committed as typed or as
/// autocorrect left them (never from deleted text), keep a window of recent taps (about 800),
/// and pool keys so rare keys borrow from their neighbors: each key's mean is shrunk toward its
/// cluster (row and thumb side), and each cluster's toward zero. Offsets are in key pitches across
/// and row pitches down, so they survive rotation and width changes, and the grid clamps them
/// (`KeyGridGeometry.maxLearnedShiftX`). Only offsets per key are kept, never letters or words in
/// order, so the typed text cannot be rebuilt from it.
public struct TouchAdaptation: Codable, Equatable, Sendable {
    /// Taps after which an old tap's weight has decayed by 1/e.
    public static let window: Double = 800
    /// Pseudo-taps pulling a key's mean toward its cluster's, and a cluster's toward zero.
    public static let keyPrior: Double = 12
    public static let clusterPrior: Double = 30
    /// A learned word whose letters differ from the typed ones in more than this share is not a
    /// slip of the thumb (a different word was chosen), so it teaches nothing.
    static let maximumChangedShare = 0.34

    /// Per letter a...z: decayed sums of offsets and the decayed tap count.
    var sumX: [Double]
    var sumY: [Double]
    var weight: [Double]

    public init() {
        sumX = Array(repeating: 0, count: 26)
        sumY = Array(repeating: 0, count: 26)
        weight = Array(repeating: 0, count: 26)
    }

    enum CodingKeys: String, CodingKey {
        case sumX, sumY, weight
    }

    /// Rejects stored tables of the wrong size or with non-finite or negative weights, so a
    /// damaged preference can never reach the touch path.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let x = try container.decode([Double].self, forKey: .sumX)
        let y = try container.decode([Double].self, forKey: .sumY)
        let w = try container.decode([Double].self, forKey: .weight)
        guard x.count == 26, y.count == 26, w.count == 26, (x + y + w).allSatisfy(\.isFinite), w.allSatisfy({ $0 >= 0 }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: container.codingPath,
                                                   debugDescription: "touch adaptation needs 26 finite values per table"))
        }
        sumX = x
        sumY = y
        weight = w
    }

    /// Taps learned, after decay.
    public var taps: Double { weight.reduce(0, +) }

    /// One tap meant for `letter` (ASCII a to z) that landed `offset` from its cap center.
    public mutating func record(_ offset: KeyTouch, for letter: UInt8) {
        let folded = letter | 0x20
        guard folded >= 0x61, folded <= 0x7A, offset.dx.isFinite, offset.dy.isFinite,
              abs(offset.dx) <= 1.5, abs(offset.dy) <= 1.5 else { return }
        let keep = 1 - 1 / Self.window
        for i in 0..<26 {
            sumX[i] *= keep
            sumY[i] *= keep
            weight[i] *= keep
        }
        let i = Int(folded - 0x61)
        sumX[i] += Double(offset.dx)
        sumY[i] += Double(offset.dy)
        weight[i] += 1
    }

    /// Learns from a committed word. `touches` are the raw taps (no learned shift) relative to
    /// the keys that were typed, letter for letter with `typed`; `committed` is what stayed in
    /// the text. Only same-length, mostly unchanged letter words teach: each tap is re-measured
    /// from the key it was meant for. Returns whether the word taught anything.
    ///
    /// A word the keyboard does not recognize (`recognized` false) may hold a space bar tap that
    /// landed high and typed a bottom-row letter ("lotvinstead", "youxare"). Its taps low on a
    /// bottom-row key teach nothing: learning them would move those keys' targets down onto the
    /// space bar and turn more spaces into letters.
    @discardableResult
    public mutating func learn(typed: String, committed: String, touches: [KeyTouch], recognized: Bool = true) -> Bool {
        // Validate before any record() call, including its decay of older evidence. Otherwise
        // one malformed observation silently leaves a partially learned word.
        guard touches.allSatisfy({ $0.dx.isFinite && $0.dy.isFinite && abs($0.dx) <= 1.5 && abs($0.dy) <= 1.5 }) else { return false }
        let a = Array(typed.utf8), b = Array(committed.utf8)
        guard a.count == b.count, a.count == touches.count, a.count >= 2 else { return false }
        var changed = 0
        for (x, y) in zip(a, b) {
            guard Self.isLetter(x), Self.isLetter(y) else { return false }
            if x | 0x20 != y | 0x20 { changed += 1 }
        }
        guard Double(changed) <= Self.maximumChangedShare * Double(a.count) else { return false }
        var lesson: [(UInt8, KeyTouch)] = []
        for i in a.indices {
            let typedKey = a[i] | 0x20, meant = b[i] | 0x20
            guard let from = KeyboardProximity.center(of: typedKey), let to = KeyboardProximity.center(of: meant) else { continue }
            if !recognized, from.y >= Self.bottomRow, touches[i].dy > Self.unrecognizedLowestDy { continue }
            // Where the tap sat, measured from the meant key: the typed key's center plus the
            // tap's offset on it, minus the meant key's center.
            let dx = Float(from.x - to.x) + touches[i].dx
            let dy = Float(from.y - to.y) + touches[i].dy
            // A distant corrected letter is not a plausible calibration sample. As before,
            // skip that aligned letter, while valid unchanged letters can still teach.
            guard dx.isFinite, dy.isFinite, abs(dx) <= 1.5, abs(dy) <= 1.5 else { continue }
            lesson.append((meant, KeyTouch(dx: dx, dy: dy)))
        }
        for (letter, touch) in lesson { record(touch, for: letter) }
        return !lesson.isEmpty
    }

    /// Row of z to m in `KeyboardProximity`'s coordinates.
    static let bottomRow: Float = 2
    /// In an unrecognized word, a bottom-row tap below this (row pitches from the cap center)
    /// is skipped: it may be a space bar tap that landed high.
    static let unrecognizedLowestDy: Float = 0

    /// Drops everything learned for z to m, which then borrow from their cluster and relearn.
    public mutating func forgetBottomRow() {
        for i in 0..<26 where KeyboardProximity.center(of: UInt8(0x61 + i))?.y == Self.bottomRow {
            sumX[i] = 0
            sumY[i] = 0
            weight[i] = 0
        }
    }

    /// `offset(for:)` for a to z, for a touch path that should only read an array.
    public var offsetTable: [KeyTouch] {
        (0..<26).map { offset(for: UInt8(0x61 + $0)) }
    }

    /// Where taps meant for `letter` land relative to its cap center, in key and row pitches,
    /// shrunk toward its cluster when there is little data. Zero for anything but a to z.
    public func offset(for letter: UInt8) -> KeyTouch {
        let folded = letter | 0x20
        guard folded >= 0x61, folded <= 0x7A else { return .center }
        let i = Int(folded - 0x61)
        let cluster = Self.cluster[i]
        var cx = 0.0, cy = 0.0, cw = 0.0
        for j in 0..<26 where Self.cluster[j] == cluster {
            cx += sumX[j]
            cy += sumY[j]
            cw += weight[j]
        }
        let mx = cx / (cw + Self.clusterPrior), my = cy / (cw + Self.clusterPrior)
        let x = (sumX[i] + Self.keyPrior * mx) / (weight[i] + Self.keyPrior)
        let y = (sumY[i] + Self.keyPrior * my) / (weight[i] + Self.keyPrior)
        return KeyTouch(dx: Float(x), dy: Float(y))
    }

    /// Cluster of each letter: its row, and which thumb's half of the keyboard it sits in.
    static let cluster: [Int] = (0..<26).map { i in
        guard let c = KeyboardProximity.center(of: UInt8(0x61 + i)) else { return 0 }
        return Int(c.y) * 2 + (c.x < 4.75 ? 0 : 1)
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        let folded = byte | 0x20
        return folded >= 0x61 && folded <= 0x7A
    }
}
