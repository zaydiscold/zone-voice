// by zayd/cold @ zayd.wtf

import CoreGraphics
import Foundation

/// How wide one key is, in a row of the key grid.
public enum KeySlotWidth: Equatable, Sendable {
    /// A multiple of a letter key's width (1 for a letter, 1.355 for shift and delete).
    case units(CGFloat)
    /// Shares whatever width the row has left with the row's other fill keys (the space bar,
    /// the punctuation keys on the number layers' third row).
    case fill
}

/// One row of keys, left to right.
public struct KeyGridRow: Equatable, Sendable {
    public var widths: [KeySlotWidth]
    /// Extra room after the first key and before the last (shift and delete on the third row).
    public var duplicatesCenter: Bool = false
    public var edgeGaps: Bool

    public init(_ widths: [KeySlotWidth], edgeGaps: Bool = false) {
        self.widths = widths
        self.edgeGaps = edgeGaps
    }
}

/// The fixed measurements of the grid. The defaults are iOS 26's on a 393 to 402 pt phone,
/// measured 2026-10-31. The 3 pt under the last row was measured 2026-11-18 on a 402 pt
/// simulator: with none, every row sat 3 pt lower than Apple's against the globe row
/// (docs/investigations/2026-11-18-keyboard-height-jump.md).
public struct KeyGridMetrics: Equatable, Sendable {
    /// Hosts narrower than this (compact phones, split layouts) get shorter rows.
    public static let narrowWidth: CGFloat = 380

    public var sideInset: CGFloat
    public var keySpacing: CGFloat
    public var keyHeight: CGFloat
    /// Top of one row's cap to the top of the next.
    public var rowPitch: CGFloat
    /// Space between the last row's cap and the grid's bottom edge.
    public var bottomInset: CGFloat
    /// Extra room between shift or delete and the letters (13.7 pt including the key spacing).
    public var edgeGap: CGFloat
    /// The top row always has this many unit keys; it fixes the unit width.
    public var unitsPerFullRow: Int

    public init(sideInset: CGFloat = 6.5, keySpacing: CGFloat = 6, keyHeight: CGFloat = 43, rowPitch: CGFloat = 54,
                bottomInset: CGFloat = 3, edgeGap: CGFloat = 7.7, unitsPerFullRow: Int = 10) {
        self.sideInset = sideInset
        self.keySpacing = keySpacing
        self.keyHeight = keyHeight
        self.rowPitch = rowPitch
        self.bottomInset = bottomInset
        self.edgeGap = edgeGap
        self.unitsPerFullRow = unitsPerFullRow
    }

    /// 43 pt keys on a 54 pt pitch, 3 pt off the bottom; 38 on 50 on a narrow host, one point off the bottom.
    public static func standard(width: CGFloat) -> KeyGridMetrics {
        width < narrowWidth
            ? KeyGridMetrics(keyHeight: 38, rowPitch: 50, bottomInset: 1)
            : KeyGridMetrics()
    }
}

/// Where every key's cap sits, and which key a touch belongs to.
///
/// The hit rule follows Apple's keyboard rather than the caps' rectangles, so no touch on the
/// grid ever misses: the touch point is first moved up by `touchBias` (iOS reports a thumb's
/// contact a little below where the user aimed), then it belongs to the row whose cap center is
/// nearest vertically, then to the key in that row whose cap is nearest horizontally. A row's
/// boundaries sit at the middle of each gap between neighboring caps; for keys of equal width
/// that is exactly the nearest center, and for unequal ones (space beside return) it keeps a
/// touch inside a cap on that cap. The first and last keys of a row own everything out to the
/// grid's edges, which is how A and L own the empty margins of the home row.
public struct KeyGridGeometry: Equatable, Sendable {
    /// Points the touch is moved up before assignment. A constant to tune on the device.
    public static let touchBias: CGFloat = 4.5
    /// A thumb rolls a few points between down and up; a release this close to the pressed
    /// key's cap still types it.
    public static let releaseTolerance: CGFloat = 16

    public struct Position: Hashable, Sendable {
        public var row: Int
        public var index: Int
        public init(row: Int, index: Int) {
            self.row = row
            self.index = index
        }
    }

    public let size: CGSize
    public let metrics: KeyGridMetrics
    /// The width of a one-unit (letter) key.
    public let unitWidth: CGFloat
    /// Visible caps, per row, left to right, in the grid's coordinates.
    public let caps: [[CGRect]]

    /// First key of the right group in each row, including duplicated letters and space.
    private let splits: [Int]?

    public init(size: CGSize, rows: [KeyGridRow], metrics: KeyGridMetrics? = nil, splitAt: [Int]? = nil) {
        let metrics = metrics ?? .standard(width: size.width)
        self.size = size
        self.metrics = metrics
        let usable = max(size.width - 2 * metrics.sideInset, 0)
        let full = CGFloat(metrics.unitsPerFullRow)
        let unit = max((usable - metrics.keySpacing * (full - 1)) / full, 0)
        let splitAt = splitAt.flatMap { cuts in
            cuts.count == rows.count && zip(cuts, rows).allSatisfy { $0 > 0 && $0 < $1.widths.count } ? cuts : nil
        }
        self.splits = splitAt
        unitWidth = splitAt == nil ? unit : 46.3
        let count = rows.count
        caps = rows.enumerated().map { rowIndex, row in
            let bottom = size.height - metrics.bottomInset - CGFloat(count - 1 - rowIndex) * metrics.rowPitch
            let top = bottom - metrics.keyHeight
            if let splitAt {
                return Self.splitCaps(row: row, index: rowIndex, cut: splitAt[rowIndex],
                                      side: metrics.sideInset, width: size.width, top: top, height: metrics.keyHeight)
            }
            return Self.layoutRow(row, unit: unit, usable: usable, metrics: metrics, top: top)
        }
    }

    // Cap measurements from the iOS 27.2 English split. Build each half from its
    // outside edge so Return and Delete stay under the right thumb as the host resizes.
    private static func splitCaps(row: KeyGridRow, index: Int, cut: Int, side: CGFloat,
                                  width: CGFloat, top: CGFloat, height: CGFloat) -> [CGRect] {
        let pitch: CGFloat = 57, letter: CGFloat = 46.3, gap = pitch - letter
        func half(_ keys: ArraySlice<KeySlotWidth>, right: Bool) -> [CGRect] {
            var offset = side
            if index == 1 && row.widths.count == 10 && row.duplicatesCenter { offset += pitch / 2 }
            let outward = right ? Array(keys.reversed()) : Array(keys)
            let bottom = outward.enumerated().map { slot, key -> CGFloat in
                if key == .fill { return 0 }
                if slot == 0 { return right ? 66 : 66.7 }
                return 40.7
            }
            let space = 5 * pitch - gap - bottom.reduce(0, +) - gap * CGFloat(max(0, bottom.count - 1))
            var caps: [CGRect] = []
            for (slot, key) in outward.enumerated() {
                var capWidth = letter
                if index == 2 && slot == 0 { capWidth = 63.3 }
                if index == 3 { capWidth = key == .fill ? space : bottom[slot] }
                let x = right ? width - offset - capWidth : offset
                caps.append(CGRect(x: x, y: top, width: capWidth, height: height))
                offset += capWidth + gap
                if index == 2 && slot == 0 { offset = side + 1.5 * pitch }
            }
            return right ? Array(caps.reversed()) : caps
        }
        return half(row.widths[..<cut], right: false) + half(row.widths[cut...], right: true)
    }

    public func sameHalf(_ first: CGPoint, _ second: CGPoint) -> Bool {
        splits == nil || (first.x < size.width / 2) == (second.x < size.width / 2)
    }

    private func inSplitGap(_ x: CGFloat, row: Int) -> Bool {
        guard let cut = splits?[row] else { return false }
        let padding: CGFloat = 5.35
        return x >= caps[row][cut - 1].maxX + padding && x < caps[row][cut].minX - padding
    }

    private static func layoutRow(_ row: KeyGridRow, unit: CGFloat, usable: CGFloat, metrics: KeyGridMetrics, top: CGFloat) -> [CGRect] {
        let n = row.widths.count
        guard n > 0 else { return [] }
        let edge = row.edgeGaps && n >= 2 ? metrics.edgeGap : 0
        let gaps = metrics.keySpacing * CGFloat(n - 1) + 2 * edge
        var fixed: CGFloat = 0
        var fills = 0
        for width in row.widths {
            switch width {
            case .units(let units): fixed += units * unit
            case .fill: fills += 1
            }
        }
        let fillWidth = fills > 0 ? max((usable - fixed - gaps) / CGFloat(fills), 0) : 0
        let rowWidth = fixed + CGFloat(fills) * fillWidth + gaps
        // Rows narrower than the grid (the home row) sit centered in it.
        var x = metrics.sideInset + (usable - rowWidth) / 2
        var rects: [CGRect] = []
        rects.reserveCapacity(n)
        for (index, width) in row.widths.enumerated() {
            let w: CGFloat
            switch width {
            case .units(let units): w = units * unit
            case .fill: w = fillWidth
            }
            rects.append(CGRect(x: x, y: top, width: w, height: metrics.keyHeight))
            x += w + metrics.keySpacing
            if index == 0 || index == n - 2 { x += edge }
        }
        return rects
    }

    public func cap(_ position: Position) -> CGRect? {
        guard caps.indices.contains(position.row), caps[position.row].indices.contains(position.index) else { return nil }
        return caps[position.row][position.index]
    }

    /// The keys of the nearest row above `position` whose caps overlap its cap by at least a
    /// quarter of their width: for the space bar, the letters a thumb that stops short of it
    /// types instead. Which those are depends on the row: x to n beside 123 and globe or emoji,
    /// z to n beside 123 alone (m sits over return either way).
    public func keys(above position: Position) -> [Position] {
        guard let below = cap(position),
              let row = caps[..<position.row].lastIndex(where: { !$0.isEmpty }) else { return [] }
        return caps[row].indices.filter { index in
            let cap = caps[row][index]
            return min(cap.maxX, below.maxX) - max(cap.minX, below.minX) >= cap.width / 4
        }.map { Position(row: row, index: $0) }
    }

    /// The touch point as the grid judges it: moved up by `touchBias`.
    public static func aimed(_ touch: CGPoint) -> CGPoint {
        CGPoint(x: touch.x, y: touch.y - touchBias)
    }

    /// The row whose cap center is nearest to an already aimed y. Ties go to the upper row.
    public func nearestRow(toAimedY y: CGFloat) -> Int? {
        var best: Int?
        var bestDistance = CGFloat.infinity
        for (index, row) in caps.enumerated() {
            guard let first = row.first else { continue }
            let distance = abs(first.midY - y)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    /// The key a raw touch point belongs to. Never nil while the grid has a key.
    public func key(at touch: CGPoint) -> Position? {
        key(at: touch, likelihood: nil)
    }

    /// Most a likely key may move a boundary into its neighbor, as a share of the neighbor's
    /// width, measured from the middle of the gap between them.
    public static let maxClaim: CGFloat = 0.25

    /// Most the space bar row may move its boundary up into the letter above, as a share of that
    /// key's height. With `maxLearnedShiftY` on top, a tap on a letter's center still always types it.
    public static let maxVerticalClaim: CGFloat = 0.3

    /// The key a raw touch point belongs to, with Apple-style dynamic hit targets: `likelihood`
    /// gives each key's chance of being the next one typed (nil for keys without an opinion, such
    /// as shift). Between two neighbors in a row that both have one, the boundary leans toward the
    /// less likely key by `(a - b) / (a + b)` of `maxClaim` of that key's width. Between the last
    /// row and the row above, a more likely key below (the space bar after a finished word) claims
    /// up to `maxVerticalClaim` of the key above's height by the same share; it never gives room
    /// away, so a likely letter never takes taps on the space bar. The caps never move. A nil
    /// closure is pure nearest key.
    public func key(at touch: CGPoint, likelihood: ((Position) -> Double?)?) -> Position? {
        let aimed = Self.aimed(touch)
        guard let nearest = nearestRow(toAimedY: aimed.y) else { return nil }
        let row = likelihood.map { claimedRow(from: nearest, aimed: aimed, likelihood: $0) } ?? nearest
        guard !inSplitGap(aimed.x, row: nearest), !inSplitGap(aimed.x, row: row) else { return nil }
        return Position(row: row, index: index(inRow: row, atAimedX: aimed.x, likelihood: likelihood))
    }

    private func index(inRow row: Int, atAimedX x: CGFloat, likelihood: ((Position) -> Double?)?) -> Int {
        let rects = caps[row]
        for index in 0..<(rects.count - 1) where x < boundary(row: row, after: index, likelihood: likelihood) {
            return index
        }
        return rects.count - 1
    }

    /// The nearest row, or the last row when the touch sits low on a key just above it and the
    /// key below is so much more likely that its claim reaches the touch.
    private func claimedRow(from nearest: Int, aimed: CGPoint, likelihood: @escaping (Position) -> Double?) -> Int {
        guard let lowerRow = caps.indices.last(where: { !caps[$0].isEmpty }),
              let upperRow = caps.indices[..<lowerRow].last(where: { !caps[$0].isEmpty }),
              nearest == upperRow else { return nearest }
        let upper = Position(row: upperRow, index: index(inRow: upperRow, atAimedX: aimed.x, likelihood: likelihood))
        let lower = Position(row: lowerRow, index: index(inRow: lowerRow, atAimedX: aimed.x, likelihood: likelihood))
        guard let u = likelihood(upper), let d = likelihood(lower),
              u >= 0, d >= 0, u.isFinite, d.isFinite, (u + d).isFinite, d > u else { return nearest }
        // With no claim this is exactly `nearestRow`'s split.
        let middle = (caps[upperRow][0].midY + caps[lowerRow][0].midY) / 2
        let claim = CGFloat((d - u) / (d + u)) * Self.maxVerticalClaim * caps[upperRow][upper.index].height
        return aimed.y > middle - claim ? lowerRow : upperRow
    }

    /// The x where key `index` of `row` hands over to key `index + 1`.
    public func boundary(row: Int, after index: Int, likelihood: ((Position) -> Double?)? = nil) -> CGFloat {
        let left = caps[row][index], right = caps[row][index + 1]
        let middle = (left.maxX + right.minX) / 2
        guard splits?[row] != index + 1, let likelihood,
              let l = likelihood(Position(row: row, index: index)),
              let r = likelihood(Position(row: row, index: index + 1)),
              l >= 0, r >= 0, l.isFinite, r.isFinite, (l + r).isFinite, l + r > 0 else { return middle }
        let lean = CGFloat((l - r) / (l + r))
        return middle + lean * Self.maxClaim * (lean > 0 ? right.width : left.width)
    }

    // MARK: Learned offsets

    /// Most a learned offset may move a key's target: a share of the key pitch across and of the
    /// row pitch down. With `maxClaim` on top, a tap on a cap's center still always types that
    /// cap (0.25 pitch plus a quarter of a key stays inside half a pitch).
    public static let maxLearnedShiftX: CGFloat = 0.25
    public static let maxLearnedShiftY: CGFloat = 0.2

    /// The raw touch moved by this person's learned offsets (`TouchAdaptation`), ready for
    /// `key(at:likelihood:)` and `touchOffset(_:on:)`. `offsets` gives, per key, where taps meant
    /// for it land relative to its cap center (after `touchBias`), in points; nil for keys
    /// without one. The shift at a point is interpolated between the nearest key centers of the
    /// two nearest rows, so it is continuous: two neighbors with opposite offsets meet in the
    /// middle instead of trading regions. Each key's offset is clamped to the bounds above.
    public func adjusted(_ touch: CGPoint, offsets: (Position) -> CGVector?) -> CGPoint {
        let aimed = Self.aimed(touch)
        let rows = caps.indices.filter { !caps[$0].isEmpty }
        guard let firstRow = rows.first else { return touch }
        let pitch = unitWidth + metrics.keySpacing
        func clamped(_ v: CGVector) -> CGVector {
            let mx = Self.maxLearnedShiftX * pitch, my = Self.maxLearnedShiftY * metrics.rowPitch
            return CGVector(dx: min(max(v.dx, -mx), mx), dy: min(max(v.dy, -my), my))
        }
        func shift(inRow row: Int) -> CGVector {
            let rects = caps[row]
            func at(_ index: Int) -> CGVector { offsets(Position(row: row, index: index)).map(clamped) ?? .zero }
            guard let upper = rects.firstIndex(where: { $0.midX >= aimed.x }) else { return at(rects.count - 1) }
            guard upper > 0 else { return at(0) }
            let left = rects[upper - 1].midX, right = rects[upper].midX
            let t = right > left ? (aimed.x - left) / (right - left) : 0
            let a = at(upper - 1), b = at(upper)
            return CGVector(dx: a.dx + (b.dx - a.dx) * t, dy: a.dy + (b.dy - a.dy) * t)
        }
        let centers = rows.map { caps[$0][0].midY }
        var total: CGVector
        if let upper = centers.firstIndex(where: { $0 >= aimed.y }) {
            if upper == 0 {
                total = shift(inRow: firstRow)
            } else {
                let t = (aimed.y - centers[upper - 1]) / (centers[upper] - centers[upper - 1])
                let a = shift(inRow: rows[upper - 1]), b = shift(inRow: rows[upper])
                total = CGVector(dx: a.dx + (b.dx - a.dx) * t, dy: a.dy + (b.dy - a.dy) * t)
            }
        } else {
            total = shift(inRow: rows[rows.count - 1])
        }
        return CGPoint(x: touch.x - total.dx, y: touch.y - total.dy)
    }

    /// Where a raw touch sits on a key for autocorrect's touch evidence: from the cap's center
    /// to the aimed point, in key pitches across and row pitches down (`KeyTouch`).
    public func touchOffset(_ touch: CGPoint, on position: Position) -> KeyTouch? {
        guard let cap = cap(position) else { return nil }
        let pitch = unitWidth + metrics.keySpacing
        guard pitch > 0, metrics.rowPitch > 0 else { return nil }
        let aimed = Self.aimed(touch)
        return KeyTouch(dx: Float((aimed.x - cap.midX) / pitch), dy: Float((aimed.y - cap.midY) / metrics.rowPitch))
    }

    /// True while a raw touch point stays within `releaseTolerance` of the key's cap, judged
    /// with the same bias as the touch-down.
    public func isNear(_ touch: CGPoint, to position: Position, tolerance: CGFloat = releaseTolerance) -> Bool {
        guard let cap = cap(position) else { return false }
        return cap.insetBy(dx: -tolerance, dy: -tolerance).contains(Self.aimed(touch))
    }

    /// The region of raw touch points that belong to a key, clipped to the grid's bounds. The
    /// regions of all keys tile the bounds with no gaps and no overlaps.
    public func touchRegion(_ position: Position) -> CGRect? {
        guard let cap = cap(position) else { return nil }
        let rects = caps[position.row]
        var left = position.index == 0 ? 0 : (rects[position.index - 1].maxX + cap.minX) / 2
        var right = position.index == rects.count - 1 ? size.width : (cap.maxX + rects[position.index + 1].minX) / 2
        if let cut = splits?[position.row] {
            if position.index == cut - 1 { right = cap.maxX + 5.35 }
            if position.index == cut { left = cap.minX - 5.35 }
        }
        // Neighbors are the nearest rows that have keys: `nearestRow` skips empty rows, so the
        // regions must too or they disagree with `key(at:)`.
        let bias = Self.touchBias
        let center = cap.midY
        let above = caps[..<position.row].last(where: { !$0.isEmpty })?.first?.midY
        let below = caps[(position.row + 1)...].first(where: { !$0.isEmpty })?.first?.midY
        let top = above.map { ($0 + center) / 2 + bias } ?? 0
        let bottom = below.map { (center + $0) / 2 + bias } ?? size.height
        return CGRect(x: left, y: max(top, 0), width: max(right - left, 0), height: max(min(bottom, size.height) - max(top, 0), 0))
    }
}
