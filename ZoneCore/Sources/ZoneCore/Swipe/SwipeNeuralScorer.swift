// by zayd/cold @ zayd.wtf

import Foundation

/// CPU-only neural reranker. Owned by the decoder's serial worker, never shared across queues.
/// The model is the FUTO Swipe encoder; Swift inference is MIT VietTelex code. No GPL runtime.
public final class SwipeNeuralScorer {
    private let model: FutoSwipeModel
    public var weight: Float = 0.035
    public init?() {
        guard let url = Bundle.module.url(forResource: "futoswipe", withExtension: "bin"),
              let data = try? Data(contentsOf: url, options: .alwaysMapped),
              let model = FutoSwipeModel.load(data) else { return nil }
        self.model = model
    }

    public static var notices: String {
        guard let url = Bundle.module.url(forResource: "SwipeNotices", withExtension: "txt") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Map the actual drawn key centers and trace to the model's letter-row canvas.
    /// Time interpolation preserves dwell, unlike geometry's arc-length interpolation.
    public func rank(_ candidates: [SwipeCandidate], points: [SwipePoint], layout: SwipeLayout) -> [SwipeCandidate] {
        guard !candidates.isEmpty, points.count >= 2,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.t.isFinite }),
              layout.x.allSatisfy(\.isFinite), layout.y.allSatisfy(\.isFinite), layout.rowPitch > 0 else { return candidates }
        let x0 = layout.x.min()! - 0.5, width = layout.x.max()! - x0 + 0.5
        let y0 = layout.y.min()! - layout.rowPitch / 2, height = layout.rowPitch * 3
        var keys: [Float] = []
        for i in 0..<26 { keys += [(layout.x[i] - x0) / width, (layout.y[i] - y0) / height] }
        let features = Self.features(points, x0: x0, y0: y0, width: width, height: height)
        var emissions = [Float](repeating: 0, count: 32 * 27)
        model.run(features, keys, 26, &emissions)
        guard emissions.allSatisfy(\.isFinite) else { return candidates }
        return candidates.map { candidate in
            let cost = -Self.ctcScore(candidate.word, emissions: emissions)
            return SwipeCandidate(word: candidate.word, score: candidate.score + weight * cost, entryIndex: candidate.entryIndex)
        }.sorted { $0.score == $1.score ? $0.word < $1.word : $0.score < $1.score }
    }

    static func features(_ points: [SwipePoint], x0: Float, y0: Float, width: Float, height: Float) -> [Float] {
        let duration = points.last!.t - points[0].t
        let timed = duration > 0 && zip(points, points.dropFirst()).allSatisfy { $0.t <= $1.t }
        // Bound an accidentally held finger to a small working buffer.
        let n = timed ? min(2048, max(2, Int((min(duration, 30) * 60).rounded()) + 1)) : points.count
        var xs = [Float](repeating: 0, count: n), ys = xs
        var j = 0
        for i in 0..<n {
            let p: SwipePoint
            if timed {
                let time = points[0].t + duration * Float(i) / Float(n - 1)
                while j < points.count - 2 && points[j + 1].t < time { j += 1 }
                let dt = points[j + 1].t - points[j].t
                let a = dt > 0 ? min(1, max(0, (time - points[j].t) / dt)) : 0
                p = SwipePoint(x: points[j].x + a * (points[j + 1].x - points[j].x), y: points[j].y + a * (points[j + 1].y - points[j].y))
            } else { p = points[i] }
            xs[i] = min(1, max(0, (p.x - x0) / width))
            ys[i] = min(1, max(0, (p.y - y0) / height))
        }
        var result = [Float](repeating: 0, count: 128)
        for i in 0..<64 {
            let pos = Float(n - 1) * Float(i) / 63
            let lo = min(Int(pos), n - 2), a = pos - Float(lo)
            result[i] = xs[lo] + a * (xs[lo + 1] - xs[lo])
            result[64 + i] = ys[lo] + a * (ys[lo + 1] - ys[lo])
        }
        return result
    }

    /// Forward CTC probability of the collapsed key sequence. Repeated letters share a key
    /// visit, so book and bok can share geometry; word frequency and context disambiguate them.
    static func ctcScore(_ word: String, emissions: [Float]) -> Float {
        var letters: [Int] = []
        for b in word.lowercased().utf8 where b >= 97 && b <= 122 {
            if letters.last != Int(b - 97) { letters.append(Int(b - 97)) }
        }
        guard !letters.isEmpty, letters.count <= 32 else { return -.infinity }
        var labels = [26]
        for letter in letters { labels += [letter, 26] }
        var prev = [Float](repeating: -.infinity, count: labels.count)
        prev[0] = 0
        for t in 0..<32 {
            var next = [Float](repeating: -.infinity, count: labels.count)
            for s in labels.indices {
                var total = prev[s]
                if s > 0 { total = logAdd(total, prev[s - 1]) }
                if s > 1, labels[s] != 26, labels[s] != labels[s - 2] { total = logAdd(total, prev[s - 2]) }
                next[s] = total + emissions[t * 27 + labels[s]]
            }
            prev = next
        }
        return logAdd(prev[prev.count - 1], prev[prev.count - 2])
    }

    private static func logAdd(_ a: Float, _ b: Float) -> Float {
        let m = max(a, b)
        guard m.isFinite else { return m }
        return m + log1p(exp(-abs(a - b)))
    }
}

extension Bundle {
    static var zoneSwipeResources: Bundle { .module }
}
