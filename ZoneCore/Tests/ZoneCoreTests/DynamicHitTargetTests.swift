// by zayd/cold @ zayd.wtf

import CoreGraphics
import XCTest
@testable import ZoneCore

final class DynamicHitTargetTests: XCTestCase {
    private static let topRow = Array("qwertyuiop").map(String.init)
    private let grid = KeyGridGeometry(size: CGSize(width: 393, height: 212), rows: [
        KeyGridRow(Array(repeating: .units(1), count: 10)),
        KeyGridRow(Array(repeating: .units(1), count: 9)),
        KeyGridRow([.units(1.355)] + Array(repeating: .units(1), count: 7) + [.units(1.355)], edgeGaps: true),
        KeyGridRow([.units(1.29), .units(1.29), .fill, .units(2.78)]),
    ])

    private func pos(_ row: Int, _ index: Int) -> KeyGridGeometry.Position { .init(row: row, index: index) }

    /// The keyboard's closure: the top row's letters read from a likelihood table.
    private func closure(_ table: NextLetterLikelihood?) -> ((KeyGridGeometry.Position) -> Double?)? {
        guard let table else { return nil }
        return { position in
            guard position.row == 0 else { return nil }
            return table.probability(of: Self.topRow[position.index])
        }
    }

    /// Exactly between r (index 3) and t (index 4), aimed at the row's center.
    private var betweenRAndT: CGPoint {
        let r = grid.caps[0][3], t = grid.caps[0][4]
        return CGPoint(x: (r.maxX + t.minX) / 2, y: r.midY + KeyGridGeometry.touchBias)
    }

    func testWithNoPrefixItIsPureNearestKey() {
        XCTAssertNil(NextLetterModel.likelihood(after: "", in: WordListTests.list))
        let plain = grid.key(at: betweenRAndT)
        XCTAssertEqual(grid.key(at: betweenRAndT, likelihood: nil), plain)
        // A point exactly on the boundary belongs to the right-hand key.
        XCTAssertEqual(plain, pos(0, 4))
    }

    func testAfterTheATouchBetweenRAndTIsR() throws {
        let table = try XCTUnwrap(NextLetterModel.likelihood(after: "the", in: WordListTests.list))
        let r = try XCTUnwrap(table.probability(of: "r")), t = try XCTUnwrap(table.probability(of: "t"))
        XCTAssertGreaterThan(r, t)
        let weights = closure(table)
        XCTAssertEqual(grid.key(at: betweenRAndT, likelihood: weights), pos(0, 3))
        // Deterministic: the same touch and prefix always give the same key.
        for _ in 0..<5 { XCTAssertEqual(grid.key(at: betweenRAndT, likelihood: weights), pos(0, 3)) }
    }

    func testALikelyKeyClaimsAtMostAQuarterOfItsNeighbor() {
        let left = grid.caps[0][3], right = grid.caps[0][4]
        let middle = (left.maxX + right.minX) / 2
        let certain: (KeyGridGeometry.Position) -> Double? = { $0.index == 3 ? 1 : 0 }
        XCTAssertEqual(grid.boundary(row: 0, after: 3, likelihood: certain), middle + 0.25 * right.width, accuracy: 0.0001)
        let opposite: (KeyGridGeometry.Position) -> Double? = { $0.index == 3 ? 0 : 1 }
        XCTAssertEqual(grid.boundary(row: 0, after: 3, likelihood: opposite), middle - 0.25 * left.width, accuracy: 0.0001)
        // So the far three quarters of t's cap stay t even when r is certain.
        XCTAssertEqual(grid.key(at: CGPoint(x: right.minX + 0.25 * right.width - 3 + 0.5, y: right.midY), likelihood: certain), pos(0, 4))
        XCTAssertEqual(grid.key(at: CGPoint(x: right.midX, y: right.midY), likelihood: certain), pos(0, 4))
    }

    func testKeysWithoutAnOpinionKeepTheMiddle() {
        let any: (KeyGridGeometry.Position) -> Double? = { $0.row == 0 ? 0.9 : nil }
        // Bottom row (123, globe, space, return) has no likelihoods: boundaries unchanged.
        for index in 0..<3 {
            XCTAssertEqual(grid.boundary(row: 3, after: index, likelihood: any), grid.boundary(row: 3, after: index))
        }
        // Equal likelihoods also keep the middle.
        XCTAssertEqual(grid.boundary(row: 0, after: 0, likelihood: any), grid.boundary(row: 0, after: 0))
    }

    func testRowsAreNeverReassigned() {
        let certain: (KeyGridGeometry.Position) -> Double? = { $0.row == 1 ? 1 : 0 }
        for (r, row) in grid.caps.enumerated() {
            for cap in row {
                let touch = CGPoint(x: cap.midX, y: cap.midY)
                XCTAssertEqual(grid.key(at: touch, likelihood: certain)?.row, r)
            }
        }
    }

    func testLikelihoodTable() throws {
        let table = try XCTUnwrap(NextLetterModel.likelihood(after: "Th", in: WordListTests.list))
        XCTAssertEqual(table.prefix, "th")
        XCTAssertEqual(table.probabilities.reduce(0, +), 1, accuracy: 1e-9)
        // "th" is followed by e far more than by z; z still keeps a floor.
        XCTAssertGreaterThan(table.probability(of: "e")!, table.probability(of: "z")!)
        XCTAssertGreaterThan(table.probability(of: "z")!, 0)
        XCTAssertEqual(table.probability(of: "E"), table.probability(of: "e"))
        XCTAssertNil(table.probability(of: "1"))
        XCTAssertNil(table.probability(of: "space"))
        XCTAssertNil(NextLetterModel.likelihood(after: "qzxj", in: WordListTests.list))
    }

    /// The table is built off the touch path; this records its cost on the Mac for the plan doc.
    func testTableCostIsSmall() {
        let list = WordListTests.list
        let prefixes = ["t", "th", "the", "a", "s", "co", "pro", "inte", "keyb"]
        let start = DispatchTime.now().uptimeNanoseconds
        let rounds = 20
        for _ in 0..<rounds { for prefix in prefixes { _ = NextLetterModel.likelihood(after: prefix, in: list) } }
        let micros = Double(DispatchTime.now().uptimeNanoseconds - start) / 1000 / Double(rounds * prefixes.count)
        print("NextLetterModel mean build: \(String(format: "%.1f", micros)) us per prefix")
        XCTAssertLessThan(micros, 20_000)
    }
}
