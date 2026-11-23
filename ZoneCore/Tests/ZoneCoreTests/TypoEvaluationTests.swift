// by zayd/cold @ zayd.wtf

import CoreGraphics
import XCTest
@testable import ZoneCore

/// Scores the autocorrector on `TypoEvaluationSet` and on simulated thumb typing, and holds the
/// score above a floor so a later change cannot quietly make typing worse. Run with
/// `swift test --package-path ZoneCore --filter TypoEvaluationTests` to see the table.
final class TypoEvaluationTests: XCTestCase {
    // MARK: Static set

    func testTypoSetAccuracy() {
        let corrector = Autocorrector(words: WordListTests.list)
        var byCategory: [String: (pass: Int, total: Int)] = [:]
        var failures: [String] = []
        for item in TypoEvaluationSet.cases {
            let got = corrector.evaluate(item.typed, autoCapitalized: item.autoCapitalized).replacement ?? item.typed
            let pass = got == item.wanted
            byCategory[item.category, default: (0, 0)].total += 1
            if pass { byCategory[item.category, default: (0, 0)].pass += 1 } else {
                failures.append("\(item.typed) -> \(got) (want \(item.wanted), \(item.category))")
            }
        }
        let pass = byCategory.values.reduce(0) { $0 + $1.pass }
        let total = byCategory.values.reduce(0) { $0 + $1.total }
        let keep = byCategory["keep"] ?? (0, 0)
        print("typo set: \(pass)/\(total) (\(Self.percent(pass, total)))")
        for (category, score) in byCategory.sorted(by: { $0.key < $1.key }) {
            print("  \(category): \(score.pass)/\(score.total)")
        }
        print("  failures: " + failures.joined(separator: "; "))
        XCTAssertGreaterThanOrEqual(pass, Self.typoSetFloor, "typo set accuracy fell")
        // Words, names and slang that must stay are never traded for a fix.
        XCTAssertEqual(keep.pass, keep.total, "a word that must stay was changed")
    }

    /// Raise this when accuracy improves; never lower it to make a change pass. Baseline before
    /// the 2026-11-01 keyboard pass: 250 of 326; 306 before the fast-typing pass; one passing item
    /// removed since (311 of 325).
    static let typoSetFloor = 311

    // MARK: Simulated thumb typing

    /// Each sentence typed several times by a simulated thumb: every tap aims at the key's
    /// center, lands below it by the grid's touch bias (as iOS reports thumbs), plus Gaussian
    /// noise. The grid's own nearest-key rule decides the letter; a tap that lands on shift,
    /// delete or the bottom row loses the letter.
    func testSimulatedThumbTyping() {
        let corrector = Autocorrector(words: WordListTests.list)
        for sigma in [7.0, 10.0, 13.0] {
            let plain = Self.simulate(sigma: sigma, repeats: 4) { typed, _ in
                corrector.evaluate(typed).replacement ?? typed
            }
            let touched = Self.simulate(sigma: sigma, repeats: 4) { typed, points in
                corrector.evaluate(typed, touches: Self.offsets(points)).replacement ?? typed
            }
            print(String(format: "thumb sigma %.0f pt: %d words, typed right %@, autocorrect %@ without touches, %@ with touches; correct words changed %d / %d",
                         sigma, plain.words, Self.percent(plain.typedRight, plain.words),
                         Self.percent(plain.finalRight, plain.words), Self.percent(touched.finalRight, touched.words),
                         plain.broken, touched.broken))
            XCTAssertGreaterThanOrEqual(plain.finalRight, plain.typedRight, "autocorrect made simulated typing worse")
            XCTAssertGreaterThanOrEqual(touched.finalRight, plain.finalRight, "touch evidence made simulated typing worse")
            if let floor = Self.thumbFloors[sigma] {
                XCTAssertGreaterThanOrEqual(Double(touched.finalRight) / Double(touched.words), floor, "thumb typing accuracy fell at sigma \(sigma)")
            }
        }
    }

    /// Raise these when accuracy improves; never lower them to make a change pass. Baseline
    /// before the 2026-11-01 keyboard pass (no touch evidence): 0.939 at 10 pt, 0.753 at 13 pt.
    static let thumbFloors: [Double: Double] = [10: 0.975, 13: 0.895]

    /// The grid's touch offsets for each simulated tap, as the keyboard passes them.
    static func offsets(_ points: [CGPoint]) -> [KeyTouch] {
        points.map { point in
            guard let hit = grid.key(at: point) else { return .center }
            return grid.touchOffset(point, on: hit) ?? .center
        }
    }

    struct SimulatedRun {
        var words = 0
        var typedRight = 0
        var finalRight = 0
        var broken = 0
    }

    /// The letters layer on a 393 pt phone, as `KeyGridGeometryTests` lays it out.
    static let grid = KeyGridGeometry(size: CGSize(width: 393, height: 212), rows: [
        KeyGridRow(Array(repeating: .units(1), count: 10)),
        KeyGridRow(Array(repeating: .units(1), count: 9)),
        KeyGridRow([.units(1.355)] + Array(repeating: .units(1), count: 7) + [.units(1.355)], edgeGaps: true),
        KeyGridRow([.units(1.29), .units(1.29), .fill, .units(2.78)]),
    ])
    static let letterRows: [[Character?]] = [
        Array("qwertyuiop").map { $0 },
        Array("asdfghjkl").map { $0 },
        [nil] + Array("zxcvbnm").map { $0 } + [nil],
    ]

    static func position(of letter: Character) -> KeyGridGeometry.Position? {
        for (r, row) in letterRows.enumerated() {
            if let i = row.firstIndex(of: letter) { return .init(row: r, index: i) }
        }
        return nil
    }

    static func letter(at position: KeyGridGeometry.Position) -> Character? {
        guard letterRows.indices.contains(position.row), letterRows[position.row].indices.contains(position.index) else { return nil }
        return letterRows[position.row][position.index]
    }

    /// One simulated word: the letters the grid typed and, per letter, the raw touch point.
    static func type(_ word: String, sigma: Double, rng: inout SplitMix) -> (typed: String, touches: [CGPoint]) {
        var typed = ""
        var touches: [CGPoint] = []
        for character in word {
            guard let target = position(of: character), let cap = grid.cap(target) else { continue }
            let point = CGPoint(x: cap.midX + rng.gaussian() * sigma,
                                y: cap.midY + KeyGridGeometry.touchBias + rng.gaussian() * sigma)
            guard let hit = grid.key(at: point), let letter = letter(at: hit) else { continue }
            typed.append(letter)
            touches.append(point)
        }
        return (typed, touches)
    }

    static func simulate(sigma: Double, repeats: Int, correct: (String, [CGPoint]) -> String) -> SimulatedRun {
        simulate(sigma: sigma, repeats: repeats) { typed, points, _ in correct(typed, points) }
    }

    /// As above, and `correct` is also given the word the keyboard committed before this one in
    /// the sentence (its own output, right or wrong, as on a phone), nil for the first word.
    static func simulate(sigma: Double, repeats: Int, sentences: [String] = TypoEvaluationSet.sentences, seed: UInt64 = 20261101,
                         correct: (String, [CGPoint], String?) -> String) -> SimulatedRun {
        var run = SimulatedRun()
        var rng = SplitMix(seed: seed)
        for _ in 0..<repeats {
            for sentence in sentences {
                var previous: String?
                for word in sentence.split(separator: " ").map(String.init) {
                    let wanted = Self.recased[word] ?? word
                    let (typed, touches) = type(word, sigma: sigma, rng: &rng)
                    guard !typed.isEmpty else { run.words += 1; previous = nil; continue }
                    let out = correct(typed, touches, previous)
                    previous = out
                    run.words += 1
                    if typed == word { run.typedRight += 1 }
                    if out == wanted { run.finalRight += 1 }
                    if typed == word, out != wanted { run.broken += 1 }
                }
            }
        }
        return run
    }

    // MARK: Previous word

    static let pairs: WordPairs? = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ZoneKeyboard/Resources/en-pairs.bin")
        return WordPairs(url: url, words: WordListTests.list)
    }()

    /// The same simulated typing with and without the word before each word, on the sentences
    /// the other numbers were tuned on and on a set nothing was tuned on. The previous word may
    /// only help: it must fix more words than it costs at every noise level, and it must never
    /// change a word that was typed right.
    func testPreviousWordHelpsSimulatedTyping() throws {
        let pairs = try XCTUnwrap(Self.pairs, "en-pairs.bin is missing or was built from another word list")
        let plain = Autocorrector(words: WordListTests.list)
        let contextual = Autocorrector(words: WordListTests.list)
        contextual.context = pairs
        for (name, sentences) in [("tuned", TypoEvaluationSet.sentences), ("held out", TypoEvaluationSet.heldOutSentences)] {
            for sigma in [7.0, 10.0, 13.0] {
                let without = Self.simulate(sigma: sigma, repeats: 8, sentences: sentences) { typed, points, _ in
                    plain.evaluate(typed, touches: Self.offsets(points)).replacement ?? typed
                }
                let with = Self.simulate(sigma: sigma, repeats: 8, sentences: sentences) { typed, points, previous in
                    contextual.evaluate(typed, touches: Self.offsets(points), previous: previous).replacement ?? typed
                }
                print(String(format: "previous word, %@ sentences, sigma %.0f pt: %d words, right %d (%@) without, %d (%@) with; correct words changed %d",
                             name, sigma, with.words, without.finalRight, Self.percent(without.finalRight, without.words),
                             with.finalRight, Self.percent(with.finalRight, with.words), with.broken))
                XCTAssertGreaterThanOrEqual(with.finalRight, without.finalRight, "the previous word made \(name) typing worse at sigma \(sigma)")
                XCTAssertEqual(with.broken, 0, "the previous word changed a correctly typed word")
            }
        }
        // Held out, heavy noise: 2,707 of 3,024 without, 2,734 with (2026-11-14). Raise, never lower.
        let heavy = Self.simulate(sigma: 13, repeats: 8, sentences: TypoEvaluationSet.heldOutSentences) { typed, points, previous in
            contextual.evaluate(typed, touches: Self.offsets(points), previous: previous).replacement ?? typed
        }
        XCTAssertGreaterThanOrEqual(heavy.finalRight, 2_730)
    }

    /// Words autocorrect rightly recases.
    static let recased = ["i": "I", "friday": "Friday"]

    static func percent(_ part: Int, _ whole: Int) -> String {
        whole == 0 ? "n/a" : String(format: "%.1f%%", 100 * Double(part) / Double(whole))
    }

    /// Small, seeded and portable, so every run and every machine sees the same taps.
    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func gaussian() -> Double {
            let u = max(uniform(), 1e-12), v = uniform()
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
    }
}
