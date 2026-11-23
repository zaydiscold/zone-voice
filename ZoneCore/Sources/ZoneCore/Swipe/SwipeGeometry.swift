// by zayd/cold @ zayd.wtf

import Foundation

/// One sample of a swipe, in key pitches: `x` across the keyboard, `y` down it, both measured in
/// the width of one letter key plus its gap, so a row step is about 1.37 pitches on an iPhone.
/// Isotropic units let every distance in the decoder mean the same thing in both directions.
/// `t` is seconds since the swipe's first sample.
public struct SwipePoint: Equatable, Sendable {
    public var x: Float
    public var y: Float
    public var t: Float

    public init(x: Float, y: Float, t: Float = 0) {
        self.x = x
        self.y = y
        self.t = t
    }
}

/// Where the 26 letter keys sit, in the same key-pitch units as `SwipePoint`. Built from the
/// drawn grid on the keyboard, from the corpus layout in evaluation, or from the standard
/// QWERTY stagger in tests.
public struct SwipeLayout: Equatable, Sendable {
    /// Centers for a to z; NaN for a letter the layout lacks.
    public let x: [Float]
    public let y: [Float]
    /// The row pitch in key pitches, kept so geometry tuned in rows can be converted.
    public let rowPitch: Float

    public init(x: [Float], y: [Float], rowPitch: Float) {
        precondition(x.count == 26 && y.count == 26)
        self.x = x
        self.y = y
        self.rowPitch = rowPitch
    }

    /// Centers keyed by lowercase letter.
    public init(centers: [Character: SwipePoint], rowPitch: Float) {
        var xs = [Float](repeating: .nan, count: 26), ys = [Float](repeating: .nan, count: 26)
        for (letter, point) in centers {
            guard let byte = letter.lowercased().utf8.first, byte >= 0x61, byte <= 0x7A else { continue }
            xs[Int(byte - 0x61)] = point.x
            ys[Int(byte - 0x61)] = point.y
        }
        self.init(x: xs, y: ys, rowPitch: rowPitch)
    }

    /// The standard three-row QWERTY stagger: the home row half a key in, the bottom row one
    /// and a half (where z sits beside shift on an iPhone). `rowPitch` is the row step in key
    /// pitches: 54 / 39.5 on a 402 pt iPhone.
    public static func qwerty(rowPitch: Float = 1.37) -> SwipeLayout {
        let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        let offsets: [Float] = [0.5, 1.0, 2.0]
        var centers: [Character: SwipePoint] = [:]
        for (r, row) in rows.enumerated() {
            for (c, letter) in row.enumerated() {
                centers[letter] = SwipePoint(x: Float(c) + offsets[r], y: Float(r) * rowPitch + 0.5)
            }
        }
        return SwipeLayout(centers: centers, rowPitch: rowPitch)
    }

    @inline(__always)
    func has(_ letter: Int) -> Bool { !x[letter].isNaN }

    /// Letters (0 to 25) whose center lies within `radius` of a point, nearest first.
    public func letters(near px: Float, _ py: Float, within radius: Float) -> [Int] {
        var found: [(Int, Float)] = []
        let r2 = radius * radius
        for i in 0..<26 where !x[i].isNaN {
            let dx = x[i] - px, dy = y[i] - py
            let d2 = dx * dx + dy * dy
            if d2 <= r2 { found.append((i, d2)) }
        }
        return found.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// One bit per letter whose center lies within `radius` of any of the points.
    func visitedMask(xs: [Float], ys: [Float], radius: Float) -> UInt32 {
        var mask: UInt32 = 0
        let r2 = radius * radius
        for i in 0..<26 where !x[i].isNaN {
            let cx = x[i], cy = y[i]
            for j in xs.indices {
                let dx = xs[j] - cx, dy = ys[j] - cy
                if dx * dx + dy * dy <= r2 { mask |= 1 << UInt32(i); break }
            }
        }
        return mask
    }
}

/// Arc-length tools for swipe paths, on parallel x and y arrays for speed.
public enum SwipePath {
    public static func length(xs: [Float], ys: [Float]) -> Float {
        guard xs.count > 1 else { return 0 }
        var total: Float = 0
        for i in 1..<xs.count {
            let dx = xs[i] - xs[i - 1], dy = ys[i] - ys[i - 1]
            total += (dx * dx + dy * dy).squareRoot()
        }
        return total
    }

    /// `count` points spaced evenly along the path. Speed drops out, so a slow corner and a fast
    /// straight compare alike. A path of one point, or of zero length, repeats that point.
    public static func resample(xs: [Float], ys: [Float], count: Int) -> (xs: [Float], ys: [Float]) {
        guard count > 1, let fx = xs.first, let fy = ys.first else { return (xs, ys) }
        let n = xs.count
        var cumulative = [Float](repeating: 0, count: n)
        for i in 1..<max(n, 1) {
            let dx = xs[i] - xs[i - 1], dy = ys[i] - ys[i - 1]
            cumulative[i] = cumulative[i - 1] + (dx * dx + dy * dy).squareRoot()
        }
        let total = cumulative[n - 1]
        guard total > 0.0001 else {
            return ([Float](repeating: fx, count: count), [Float](repeating: fy, count: count))
        }
        var outX = [Float](repeating: 0, count: count), outY = [Float](repeating: 0, count: count)
        var segment = 1
        let step = total / Float(count - 1)
        for i in 0..<count {
            let target = step * Float(i)
            while segment < n - 1, cumulative[segment] < target { segment += 1 }
            let span = cumulative[segment] - cumulative[segment - 1]
            let f = span > 0 ? (target - cumulative[segment - 1]) / span : 0
            outX[i] = xs[segment - 1] + f * (xs[segment] - xs[segment - 1])
            outY[i] = ys[segment - 1] + f * (ys[segment] - ys[segment - 1])
        }
        return (outX, outY)
    }

    /// Drops samples closer than `minimumStep` to the kept sample before them, so a slow finger
    /// at 120 Hz does not pile up hundreds of identical points. The last sample is always kept.
    public static func decimate(_ points: [SwipePoint], minimumStep: Float) -> [SwipePoint] {
        guard points.count > 2 else { return points }
        var kept: [SwipePoint] = [points[0]]
        kept.reserveCapacity(points.count)
        let m2 = minimumStep * minimumStep
        for p in points.dropFirst().dropLast() {
            let last = kept[kept.count - 1]
            let dx = p.x - last.x, dy = p.y - last.y
            if dx * dx + dy * dy >= m2 { kept.append(p) }
        }
        kept.append(points[points.count - 1])
        return kept
    }

    /// Translates to the centroid and scales the larger extent to one, for a comparison of
    /// shape alone (the SHARK2 shape channel). A path with no extent stays at the origin.
    static func normalizedShape(xs: [Float], ys: [Float]) -> (xs: [Float], ys: [Float]) {
        guard !xs.isEmpty else { return (xs, ys) }
        let n = Float(xs.count)
        let cx = xs.reduce(0, +) / n, cy = ys.reduce(0, +) / n
        var minX = Float.infinity, maxX = -Float.infinity, minY = Float.infinity, maxY = -Float.infinity
        for i in xs.indices {
            minX = min(minX, xs[i]); maxX = max(maxX, xs[i]); minY = min(minY, ys[i]); maxY = max(maxY, ys[i])
        }
        let extent = max(maxX - minX, maxY - minY)
        let scale: Float = extent > 0.05 ? 1 / extent : 0
        return (xs.map { ($0 - cx) * scale }, ys.map { ($0 - cy) * scale })
    }
}
