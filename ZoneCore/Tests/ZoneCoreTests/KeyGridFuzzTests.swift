// by zayd/cold @ zayd.wtf

import CoreGraphics
import XCTest
@testable import ZoneCore

/// Random touches over every layer and host width: every point belongs to exactly one key,
/// regions are monotonic, dynamic targets never move a boundary more than their bound, and the
/// touch path is cheap.
final class KeyGridFuzzTests: XCTestCase {
    private static let layers: [[KeyGridRow]] = [
        // Letters.
        [KeyGridRow(Array(repeating: .units(1), count: 10)),
         KeyGridRow(Array(repeating: .units(1), count: 9)),
         KeyGridRow([.units(1.355)] + Array(repeating: .units(1), count: 7) + [.units(1.355)], edgeGaps: true),
         KeyGridRow([.units(1.29), .units(1.29), .fill, .units(2.78)])],
        // Numbers and symbols: five fill keys on the third row.
        [KeyGridRow(Array(repeating: .units(1), count: 10)),
         KeyGridRow(Array(repeating: .units(1), count: 10)),
         KeyGridRow([.units(1.29)] + Array(repeating: .fill, count: 5) + [.units(1.355)], edgeGaps: true),
         KeyGridRow([.units(1.29), .units(1.29), .fill, .units(2.78)])],
        // Degenerate: an empty row between two, and a one-key row.
        [KeyGridRow([.units(1), .units(1)]), KeyGridRow([]), KeyGridRow([.fill])],
    ]

    private func randomGeometry(_ rng: inout StressRNG) -> KeyGridGeometry {
        let width = CGFloat(rng.int(280...1_100))
        let height = CGFloat(rng.int(150...320))
        return KeyGridGeometry(size: CGSize(width: width, height: height), rows: rng.pick(Self.layers))
    }

    func testEveryTouchLandsOnExactlyOneKeyMatchingItsRegion() {
        var rng = StressRNG(seed: 0x6B_E1)
        for _ in 0..<Stress.iterations(60, heavy: 1_000) {
            let grid = randomGeometry(&rng)
            for _ in 0..<500 {
                // Mostly inside the grid, sometimes far outside it (a thumb sliding off).
                let x = CGFloat(Double.random(in: -60...(Double(grid.size.width) + 60), using: &rng))
                let y = CGFloat(Double.random(in: -60...(Double(grid.size.height) + 60), using: &rng))
                guard let key = grid.key(at: CGPoint(x: x, y: y)) else { return XCTFail("touch at \(x),\(y) reached no key") }
                XCTAssertNotNil(grid.cap(key))
                guard (0..<grid.size.width).contains(x), (0..<grid.size.height).contains(y) else { continue }
                let owners = grid.caps.indices.flatMap { row in grid.caps[row].indices.compactMap { index -> KeyGridGeometry.Position? in
                    let position = KeyGridGeometry.Position(row: row, index: index)
                    return grid.touchRegion(position)?.contains(CGPoint(x: x, y: y)) == true ? position : nil
                } }
                // Region edges are half-open, so a point can sit on two regions' shared edge.
                XCTAssertTrue(owners.contains(key), "key \(key) at \(x),\(y) is not in its own region; owners \(owners)")
                XCTAssertLessThanOrEqual(owners.count, 4)
            }
        }
    }

    func testSweepsAcrossTheGridAreMonotonic() {
        var rng = StressRNG(seed: 0x6B_E2)
        for _ in 0..<Stress.iterations(40, heavy: 600) {
            let grid = randomGeometry(&rng)
            for row in grid.caps.indices where !grid.caps[row].isEmpty {
                let y = grid.caps[row][0].midY + KeyGridGeometry.touchBias
                var last = -1
                var x: CGFloat = -10
                while x < grid.size.width + 10 {
                    let key = grid.key(at: CGPoint(x: x, y: y))!
                    XCTAssertEqual(key.row, row)
                    XCTAssertGreaterThanOrEqual(key.index, last, "x \(x) went back from \(last) to \(key.index)")
                    last = key.index
                    x += 0.5
                }
                XCTAssertEqual(last, grid.caps[row].count - 1, "the last key owns the right edge")
            }
            let x = grid.size.width / 2
            var lastRow = -1
            var y: CGFloat = -10
            while y < grid.size.height + 10 {
                let row = grid.key(at: CGPoint(x: x, y: y))!.row
                XCTAssertGreaterThanOrEqual(row, lastRow)
                lastRow = row
                y += 0.5
            }
        }
    }

    /// Whatever the likelihoods (including zero, huge, infinite or NaN), a boundary moves at most
    /// `maxClaim` of the neighbor's width from mid-gap, boundaries stay ordered, the row never
    /// changes, and the middle half of every cap always types that cap.
    func testDynamicTargetsStayWithinTheirBound() {
        var rng = StressRNG(seed: 0x6B_E3)
        let extremes: [Double] = [0, 1e-300, 0.02, 0.5, 1, 1e300, .greatestFiniteMagnitude, .infinity, -1, .nan]
        for _ in 0..<Stress.iterations(80, heavy: 1_500) {
            let grid = randomGeometry(&rng)
            var table: [KeyGridGeometry.Position: Double?] = [:]
            for row in grid.caps.indices {
                for index in grid.caps[row].indices {
                    let value: Double? = rng.chance(0.15) ? nil : (rng.chance(0.2) ? rng.pick(extremes) : Double.random(in: 0...1, using: &rng))
                    table[KeyGridGeometry.Position(row: row, index: index)] = value
                }
            }
            let likelihood: (KeyGridGeometry.Position) -> Double? = { table[$0] ?? nil }
            for row in grid.caps.indices where grid.caps[row].count > 1 {
                var previous = -CGFloat.infinity
                for index in 0..<(grid.caps[row].count - 1) {
                    let plain = grid.boundary(row: row, after: index)
                    let leaned = grid.boundary(row: row, after: index, likelihood: likelihood)
                    XCTAssertTrue(leaned.isFinite, "boundary \(row)/\(index) is not finite")
                    let bound = KeyGridGeometry.maxClaim * max(grid.caps[row][index].width, grid.caps[row][index + 1].width) + 1e-6
                    XCTAssertLessThanOrEqual(abs(leaned - plain), bound)
                    XCTAssertGreaterThan(leaned, previous, "boundaries out of order")
                    previous = leaned
                }
                for index in grid.caps[row].indices {
                    let cap = grid.caps[row][index]
                    for _ in 0..<5 {
                        let x = cap.midX + CGFloat(Double.random(in: -0.25...0.25, using: &rng)) * cap.width
                        let touch = CGPoint(x: x, y: cap.midY + KeyGridGeometry.touchBias)
                        XCTAssertEqual(grid.key(at: touch, likelihood: likelihood), KeyGridGeometry.Position(row: row, index: index))
                    }
                }
            }
        }
    }

    func testHitTestingIsCheap() {
        let grid = KeyGridGeometry(size: CGSize(width: 393, height: 212), rows: Self.layers[0])
        let likelihood = NextLetterModel.likelihood(after: "th", in: WordList.shared!)!
        let letters = ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map { Array($0).map(String.init) }
        let lookup: (KeyGridGeometry.Position) -> Double? = { position in
            guard position.row < 3 else { return nil }
            let row = position.row == 2 ? position.index - 1 : position.index
            guard letters[position.row].indices.contains(row) else { return nil }
            return likelihood.probability(of: letters[position.row][row])
        }
        var rng = StressRNG(seed: 0x6B_E4)
        let touches = (0..<100_000).map { _ in
            CGPoint(x: Double.random(in: 0...393, using: &rng), y: Double.random(in: 0...212, using: &rng))
        }
        var sink = 0
        let seconds = Stress.time { for touch in touches { sink &+= grid.key(at: touch, likelihood: lookup)?.index ?? 0 } }
        XCTAssertGreaterThan(sink, 0)
        XCTAssertLessThan(seconds / Double(touches.count), 20e-6, "\(seconds / Double(touches.count) * 1e6) us per touch")
    }

    func testNextLetterLikelihoodsAreProbabilitiesForEveryPrefix() throws {
        let list = try XCTUnwrap(WordList.shared)
        var rng = StressRNG(seed: 0x6B_E5)
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz'")
        var prefixes = ["th", "q", "qu", "xz", "'", "a'", "zzzz", "the", "can'", String(repeating: "a", count: 30), "É", "1", " ", ""]
        prefixes += (0..<Stress.iterations(400, heavy: 10_000)).map { _ in String((0..<rng.int(1...6)).map { _ in rng.pick(alphabet) }) }
        prefixes += Stress.bundledWords.prefix(2_000).map { String($0.word.prefix(max(1, $0.word.count - 1))) }
        var built = 0
        let seconds = try Stress.time {
            for prefix in prefixes {
                guard let model = NextLetterModel.likelihood(after: prefix, in: list) else { continue }
                built += 1
                XCTAssertEqual(model.probabilities.count, 27)
                XCTAssertEqual(model.probabilities.reduce(0, +), 1, accuracy: 1e-9, prefix)
                XCTAssertTrue(model.probabilities.allSatisfy { $0.isFinite && $0 >= NextLetterModel.floorShare / 27 - 1e-12 })
                XCTAssertNil(model.probability(of: "1"))
                XCTAssertNil(model.probability(of: "ab"))
                XCTAssertEqual(model.probability(of: "A"), model.probability(of: "a"))
                _ = try XCTUnwrap(model.probability(of: "'"))
            }
        }
        XCTAssertGreaterThan(built, 1_000)
        XCTAssertLessThan(seconds / Double(prefixes.count), 0.001)
    }
}
