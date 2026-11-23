// by zayd/cold @ zayd.wtf

import CoreGraphics
import XCTest
@testable import ZoneCore

/// What autocorrect costs per keystroke: the keyboard evaluates the word at the cursor after
/// every letter (the suggestion strip) and once more on space. Typed with Gaussian thumb noise
/// over the chat corpus so the words are realistic typos, every prefix of every word is
/// evaluated by a fresh corrector (no memo hits). Self-contained on purpose, so the same file can
/// time an older tree.
final class AutocorrectKeystrokeCostTests: XCTestCase {
    /// Mean and 99th-percentile budget per evaluate call, in microseconds, in the test build
    /// (ZoneCore itself is compiled with -O). The phone's A17 Pro runs about this speed; the
    /// keyboard's lag budget is a frame (8 to 16 ms), so this leaves a wide margin.
    static let meanBudget = 150.0
    static let p99Budget = 1_500.0

    func testEvaluateCostPerKeystroke() {
        let grid = KeyGridGeometry(size: CGSize(width: 393, height: 212), rows: [
            KeyGridRow(Array(repeating: .units(1), count: 10)),
            KeyGridRow(Array(repeating: .units(1), count: 9)),
            KeyGridRow([.units(1.355)] + Array(repeating: .units(1), count: 7) + [.units(1.355)], edgeGaps: true),
            KeyGridRow([.units(1.29), .units(1.29), .fill, .units(2.78)]),
        ])
        let rows: [[Character?]] = [Array("qwertyuiop"), Array("asdfghjkl"), [nil] + Array("zxcvbnm") + [nil]]
        var rng = StressRNG(seed: 0x23_23)
        func gaussian() -> Double {
            let u = max(Double.random(in: 0..<1, using: &rng), 1e-12), v = Double.random(in: 0..<1, using: &rng)
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
        var words: [(String, [KeyTouch])] = []
        for sentence in TypingCorpus.sentences.prefix(400) {
            for word in sentence.split(separator: " ") {
                var typed = ""
                var touches: [KeyTouch] = []
                for c in word {
                    guard let r = rows.firstIndex(where: { $0.contains(c) }), let i = rows[r].firstIndex(of: c),
                          let cap = grid.cap(.init(row: r, index: i)) else { continue }
                    let point = CGPoint(x: cap.midX + gaussian() * 9, y: cap.midY + KeyGridGeometry.touchBias + gaussian() * 8)
                    guard let hit = grid.key(at: point), rows.indices.contains(hit.row), rows[hit.row].indices.contains(hit.index),
                          let letter = rows[hit.row][hit.index] else { continue }
                    typed.append(letter)
                    touches.append(grid.touchOffset(point, on: hit) ?? .center)
                }
                if !typed.isEmpty { words.append((typed, touches)) }
            }
        }
        var nanos: [UInt64] = []
        let corrector = Autocorrector(words: WordListTests.list)
        for (typed, touches) in words {
            let letters = Array(typed)
            for n in 1...letters.count {
                let prefix = String(letters[..<n])
                let start = DispatchTime.now().uptimeNanoseconds
                _ = corrector.evaluate(prefix, touches: Array(touches[..<n]))
                nanos.append(DispatchTime.now().uptimeNanoseconds - start)
            }
        }
        nanos.sort()
        let mean = Double(nanos.reduce(0, +)) / Double(nanos.count) / 1000
        let p50 = Double(nanos[nanos.count / 2]) / 1000
        let p99 = Double(nanos[nanos.count * 99 / 100]) / 1000
        let worst = Double(nanos[nanos.count - 1]) / 1000
        print(String(format: "keystroke cost: %d evaluate calls over %d words, mean %.1f us, p50 %.1f us, p99 %.1f us, worst %.1f us",
                     nanos.count, words.count, mean, p50, p99, worst))
        XCTAssertLessThan(mean, Self.meanBudget)
        XCTAssertLessThan(p99, Self.p99Budget)
    }
}
