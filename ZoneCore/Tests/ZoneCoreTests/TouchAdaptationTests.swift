// by zayd/cold @ zayd.wtf

import CoreGraphics
import XCTest
@testable import ZoneCore

/// Learned touch offsets (`TouchAdaptation`) and the grid's use of them
/// (`KeyGridGeometry.adjusted`): learning converges, bad input teaches nothing, stored data is
/// validated, and the shifted grid stays continuous, monotonic and bounded.
final class TouchAdaptationTests: XCTestCase {
    /// The letters layer on a 393 pt phone.
    private let grid = KeyGridGeometry(size: CGSize(width: 393, height: 212), rows: [
        KeyGridRow(Array(repeating: .units(1), count: 10)),
        KeyGridRow(Array(repeating: .units(1), count: 9)),
        KeyGridRow([.units(1.355)] + Array(repeating: .units(1), count: 7) + [.units(1.355)], edgeGaps: true),
        KeyGridRow([.units(1.29), .units(1.29), .fill, .units(2.78)]),
    ])

    private func letter(_ c: Character) -> UInt8 { c.asciiValue! }

    func testAnEmptyModelMovesNothing() {
        let model = TouchAdaptation()
        for c in "abcdefghijklmnopqrstuvwxyz" { XCTAssertEqual(model.offset(for: letter(c)), .center) }
        XCTAssertEqual(model.offset(for: UInt8(ascii: "'")), .center)
        let point = CGPoint(x: 120, y: 90)
        XCTAssertEqual(grid.adjusted(point) { _ in nil }, point)
        XCTAssertEqual(grid.adjusted(point) { _ in .zero }, point)
    }

    func testConsistentTapsAreLearnedAndRareKeysBorrowFromTheirCluster() {
        var model = TouchAdaptation()
        // Every tap on the left thumb's top row lands a fifth of a key left and a tenth of a row low.
        for _ in 0..<300 {
            for c in "qwert" { model.record(KeyTouch(dx: -0.2, dy: 0.1), for: letter(c)) }
        }
        let e = model.offset(for: letter("e"))
        XCTAssertEqual(e.dx, -0.2, accuracy: 0.02)
        XCTAssertEqual(e.dy, 0.1, accuracy: 0.01)
        // A key with no taps of its own leans with its cluster, never past it.
        var sparse = TouchAdaptation()
        for _ in 0..<300 { sparse.record(KeyTouch(dx: -0.2, dy: 0), for: letter("e")) }
        let q = sparse.offset(for: letter("q"))
        XCTAssertLessThan(q.dx, -0.05)
        XCTAssertGreaterThan(q.dx, -0.2)
        // The right thumb's keys are another cluster and stay put.
        XCTAssertEqual(sparse.offset(for: letter("p")).dx, 0, accuracy: 1e-6)
    }

    func testOldTapsFade() {
        var model = TouchAdaptation()
        for _ in 0..<400 { model.record(KeyTouch(dx: 0.2, dy: 0), for: letter("k")) }
        for _ in 0..<(Int(TouchAdaptation.window) * 4) { model.record(KeyTouch(dx: -0.2, dy: 0), for: letter("k")) }
        XCTAssertEqual(model.offset(for: letter("k")).dx, -0.2, accuracy: 0.03)
    }

    func testWordsTeachFromTheKeyTheyMeant() {
        var model = TouchAdaptation()
        // "rhe" committed as "the": the first tap typed r but was meant for t, so it sat on t's
        // left: r's center plus the tap's own offset, minus t's center.
        let touches = [KeyTouch(dx: 0.4, dy: 0), .center, .center]
        XCTAssertTrue(model.learn(typed: "rhe", committed: "the", touches: touches))
        let t = model.offset(for: letter("t"))
        XCTAssertLessThan(t.dx, 0)
        // Nothing is learned from words that do not line up or were rewritten.
        var untouched = TouchAdaptation()
        XCTAssertFalse(untouched.learn(typed: "teh", committed: "the", touches: [.center]))
        XCTAssertFalse(untouched.learn(typed: "dont", committed: "don't", touches: Array(repeating: .center, count: 4)))
        XCTAssertFalse(untouched.learn(typed: "inthe", committed: "in the", touches: Array(repeating: .center, count: 5)))
        XCTAssertFalse(untouched.learn(typed: "cat", committed: "dog", touches: Array(repeating: .center, count: 3)))
        XCTAssertFalse(untouched.learn(typed: "a", committed: "a", touches: [.center]))
        XCTAssertEqual(untouched, TouchAdaptation())
        // Capitals fold to their key.
        XCTAssertTrue(untouched.learn(typed: "The", committed: "The", touches: Array(repeating: KeyTouch(dx: 0.1, dy: 0), count: 3)))
        XCTAssertGreaterThan(untouched.offset(for: letter("T")).dx, 0)
    }

    func testWildTapsAreIgnored() {
        var model = TouchAdaptation()
        model.record(KeyTouch(dx: .nan, dy: 0), for: letter("a"))
        model.record(KeyTouch(dx: 0, dy: .infinity), for: letter("a"))
        model.record(KeyTouch(dx: 3, dy: 0), for: letter("a"))
        model.record(KeyTouch(dx: 0.1, dy: 0), for: UInt8(ascii: "1"))
        XCTAssertEqual(model, TouchAdaptation())
    }

    func testStoredModelsRoundTripAndDamagedOnesAreRejected() throws {
        var model = TouchAdaptation()
        for _ in 0..<50 { model.record(KeyTouch(dx: 0.1, dy: -0.05), for: letter("m")) }
        let data = try JSONEncoder().encode(model)
        XCTAssertEqual(try JSONDecoder().decode(TouchAdaptation.self, from: data), model)
        let short = #"{"sumX":[0],"sumY":[0],"weight":[0]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(TouchAdaptation.self, from: Data(short.utf8)))
        let zeros = Array(repeating: "0", count: 26).joined(separator: ",")
        let negative = #"{"sumX":[\#(zeros)],"sumY":[\#(zeros)],"weight":[-1,\#(Array(repeating: "0", count: 25).joined(separator: ","))]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(TouchAdaptation.self, from: Data(negative.utf8)))
        let fine = #"{"sumX":[\#(zeros)],"sumY":[\#(zeros)],"weight":[\#(zeros)]}"#
        XCTAssertEqual(try JSONDecoder().decode(TouchAdaptation.self, from: Data(fine.utf8)), TouchAdaptation())
    }

    // MARK: The grid with learned offsets

    /// Random per-key offsets, some beyond the clamp.
    private func randomOffsets(_ rng: inout StressRNG, scale: Double) -> [KeyGridGeometry.Position: CGVector] {
        var table: [KeyGridGeometry.Position: CGVector] = [:]
        for (r, row) in grid.caps.enumerated() {
            for i in row.indices where rng.chance(0.9) {
                table[.init(row: r, index: i)] = CGVector(dx: Double.random(in: -scale...scale, using: &rng),
                                                         dy: Double.random(in: -scale...scale, using: &rng))
            }
        }
        return table
    }

    func testShiftsAreClampedAndCapCentersStayTheirs() {
        var rng = StressRNG(seed: 0x7A_01)
        let pitch = grid.unitWidth + grid.metrics.keySpacing
        for _ in 0..<Stress.iterations(200, heavy: 4_000) {
            let table = randomOffsets(&rng, scale: 60)
            let offsets: (KeyGridGeometry.Position) -> CGVector? = { table[$0] }
            for (r, row) in grid.caps.enumerated() {
                for (i, cap) in row.enumerated() {
                    let touch = CGPoint(x: cap.midX, y: cap.midY + KeyGridGeometry.touchBias)
                    let moved = grid.adjusted(touch, offsets: offsets)
                    XCTAssertLessThanOrEqual(abs(moved.x - touch.x), KeyGridGeometry.maxLearnedShiftX * pitch + 1e-6)
                    XCTAssertLessThanOrEqual(abs(moved.y - touch.y), KeyGridGeometry.maxLearnedShiftY * grid.metrics.rowPitch + 1e-6)
                    // Learned offsets alone never take a cap's center from it...
                    XCTAssertEqual(grid.key(at: moved), .init(row: r, index: i))
                    // ...and neither do learned offsets plus the strongest likelihood against it,
                    // on the letter rows where likelihoods apply (equal-width neighbors).
                    guard r < 2 else { continue }
                    let against: (KeyGridGeometry.Position) -> Double? = { $0 == .init(row: r, index: i) ? 0 : 1 }
                    XCTAssertEqual(grid.key(at: moved, likelihood: against), .init(row: r, index: i))
                }
            }
        }
    }

    func testShiftedSweepsStayContinuousAndMonotonic() {
        var rng = StressRNG(seed: 0x7A_02)
        for _ in 0..<Stress.iterations(60, heavy: 1_000) {
            let table = randomOffsets(&rng, scale: 12)
            let offsets: (KeyGridGeometry.Position) -> CGVector? = { table[$0] }
            for row in grid.caps.indices {
                let y = grid.caps[row][0].midY + KeyGridGeometry.touchBias
                var lastIndex = -1
                var lastX = -CGFloat.infinity
                var x: CGFloat = -10
                while x < grid.size.width + 10 {
                    let moved = grid.adjusted(CGPoint(x: x, y: y), offsets: offsets)
                    // Continuous: a half-point step never jumps.
                    if lastX.isFinite { XCTAssertLessThan(abs(moved.x - lastX), 1.5) }
                    lastX = moved.x
                    let key = grid.key(at: moved)!
                    if key.row == row {
                        XCTAssertGreaterThanOrEqual(key.index, lastIndex, "x \(x) went back in row \(row)")
                        lastIndex = key.index
                    }
                    x += 0.5
                }
            }
        }
    }

    func testAdjustingIsCheap() {
        var rng = StressRNG(seed: 0x7A_03)
        let table = randomOffsets(&rng, scale: 10)
        let offsets: (KeyGridGeometry.Position) -> CGVector? = { table[$0] }
        let touches = (0..<100_000).map { _ in CGPoint(x: Double.random(in: 0...393, using: &rng), y: Double.random(in: 0...212, using: &rng)) }
        var sink: CGFloat = 0
        let seconds = Stress.time { for touch in touches { sink += grid.adjusted(touch, offsets: offsets).x } }
        let plain = Stress.time { for touch in touches { sink += CGFloat(grid.key(at: touch)?.index ?? 0) } }
        XCTAssertGreaterThan(sink, 0)
        print(String(format: "touch path: adjusted %.3f us, key(at:) %.3f us per touch", seconds / Double(touches.count) * 1e6,
                     plain / Double(touches.count) * 1e6))
        XCTAssertLessThan(seconds / Double(touches.count), 20e-6, "\(seconds / Double(touches.count) * 1e6) us per touch")
    }
}
