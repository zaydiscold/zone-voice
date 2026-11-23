// by zayd/cold @ zayd.wtf

import Foundation

/// Splits a long recording into segments a batch recognizer can decode while the person is
/// still talking, so recognition can overlap recording. The caller must separately bound queued audio.
///
/// Once `segmentSeconds` of audio are buffered, the cut goes in the middle of the quietest
/// 200 ms in the last `searchSeconds`: a likely pause between words. This heuristic can still split a word in uninterrupted speech. With no
/// pause at all (someone reading without breath) the quietest stretch still wins, and the
/// buffer never grows past `segmentSeconds`.
public struct RollingSegmenter: Sendable {
    public var segmentSeconds: Double
    public var searchSeconds: Double
    public static let sampleRate = 16_000

    public init(segmentSeconds: Double = 24, searchSeconds: Double = 6) {
        self.segmentSeconds = segmentSeconds
        self.searchSeconds = searchSeconds
    }

    /// How many leading samples make a finished segment, or nil while the buffer is short.
    public func cut(_ samples: [Float]) -> Int? {
        let rate = Self.sampleRate
        guard Double(samples.count) >= segmentSeconds * Double(rate) else { return nil }
        let frame = rate / 50                      // 20 ms
        let window = 10                            // 200 ms of frames
        // A large feed may already contain the next segment. Its pauses belong to the next cut.
        let windowEnd = Int((segmentSeconds * Double(rate)).rounded(.up))
        let searchStart = max(0, windowEnd - Int(searchSeconds * Double(rate)))
        let frames = (windowEnd - searchStart) / frame
        guard frames > window else { return windowEnd }
        var energies = [Float](repeating: 0, count: frames)
        for index in 0..<frames {
            let base = searchStart + index * frame
            var sum: Float = 0
            for offset in 0..<frame { sum += samples[base + offset] * samples[base + offset] }
            energies[index] = sum
        }
        var running = energies[0..<window].reduce(0, +)
        var best = (sum: running, start: 0)
        for start in 1...(frames - window) {
            running += energies[start + window - 1] - energies[start - 1]
            if running < best.sum { best = (running, start) }
        }
        return searchStart + (best.start + window / 2) * frame
    }
}
