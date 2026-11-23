// by zayd/cold @ zayd.wtf

import CoreGraphics
import XCTest
@testable import ZoneCore

final class KeyGridGeometryTests: XCTestCase {
    /// The letters layer as the keyboard maps it: q to p, a to l, shift z to m delete, then
    /// 123, globe, space, return.
    private static let letters: [KeyGridRow] = [
        KeyGridRow(Array(repeating: .units(1), count: 10)),
        KeyGridRow(Array(repeating: .units(1), count: 9)),
        KeyGridRow([.units(1.355)] + Array(repeating: .units(1), count: 7) + [.units(1.355)], edgeGaps: true),
        KeyGridRow([.units(1.29), .units(1.29), .fill, .units(2.78)]),
    ]

    /// The numbers layer's third row: #+=, five punctuation keys that share the width, delete.
    private static let numbersThirdRow = KeyGridRow([.units(1.29)] + Array(repeating: .fill, count: 5) + [.units(1.355)], edgeGaps: true)

    /// An iPhone 15 Pro / 16 / 17 class host: 393 pt wide, a 252 pt keyboard minus the 40 pt strip.
    private let grid = KeyGridGeometry(size: CGSize(width: 393, height: 212), rows: letters)

    private func pos(_ row: Int, _ index: Int) -> KeyGridGeometry.Position { .init(row: row, index: index) }

    // MARK: Layout matches the SwiftUI grid it replaces

    func testKeySizesMatchApple() throws {
        XCTAssertEqual(grid.unitWidth, 32.6, accuracy: 0.001)
        let q = try XCTUnwrap(grid.cap(pos(0, 0)))
        XCTAssertEqual(q.minX, 6.5, accuracy: 0.001)
        XCTAssertEqual(q.minY, 4, accuracy: 0.001)
        XCTAssertEqual(q.width, 32.6, accuracy: 0.001)
        XCTAssertEqual(q.height, 43)
        let w = try XCTUnwrap(grid.cap(pos(0, 1)))
        XCTAssertEqual(w.minX - q.maxX, 6, accuracy: 0.001)
        let a = try XCTUnwrap(grid.cap(pos(1, 0)))
        XCTAssertEqual(a.minY - q.minY, 54, accuracy: 0.001)
        // Home row centered: 19.3 pt of margin beside A and L.
        XCTAssertEqual(a.minX, 25.8, accuracy: 0.001)
        let l = try XCTUnwrap(grid.cap(pos(1, 8)))
        XCTAssertEqual(393 - l.maxX, 25.8, accuracy: 0.001)
    }

    /// The last row ends 3 pt above the bottom edge, level with Apple's rows against the globe row.
    func testRowsSitOnTheBottomEdge() throws {
        let space = try XCTUnwrap(grid.cap(pos(3, 2)))
        XCTAssertEqual(space.maxY, 209, accuracy: 0.001)
        let narrow = KeyGridGeometry(size: CGSize(width: 320, height: 196), rows: Self.letters)
        let narrowSpace = try XCTUnwrap(narrow.cap(pos(3, 2)))
        XCTAssertEqual(narrowSpace.height, 38)
        XCTAssertEqual(narrowSpace.maxY, 195, accuracy: 0.001)
    }

    func testThirdRowEdgeGapsAndSpecialWidths() throws {
        let shift = try XCTUnwrap(grid.cap(pos(2, 0)))
        let z = try XCTUnwrap(grid.cap(pos(2, 1)))
        let m = try XCTUnwrap(grid.cap(pos(2, 7)))
        let delete = try XCTUnwrap(grid.cap(pos(2, 8)))
        XCTAssertEqual(shift.width, 1.355 * 32.6, accuracy: 0.001)
        XCTAssertEqual(z.minX - shift.maxX, 13.7, accuracy: 0.001)
        XCTAssertEqual(delete.minX - m.maxX, 13.7, accuracy: 0.001)
        XCTAssertEqual(shift.minX, 6.5, accuracy: 0.05)
        XCTAssertEqual(393 - delete.maxX, 6.5, accuracy: 0.05)
    }

    func testSpaceTakesTheRemainingWidth() throws {
        let symbols = try XCTUnwrap(grid.cap(pos(3, 0)))
        let ret = try XCTUnwrap(grid.cap(pos(3, 3)))
        let space = try XCTUnwrap(grid.cap(pos(3, 2)))
        XCTAssertEqual(symbols.minX, 6.5, accuracy: 0.001)
        XCTAssertEqual(ret.maxX, 386.5, accuracy: 0.001)
        XCTAssertEqual(ret.width, 2.78 * 32.6, accuracy: 0.001)
        XCTAssertEqual(space.width, 380 - 2 * 1.29 * 32.6 - 2.78 * 32.6 - 18, accuracy: 0.001)
    }

    func testPunctuationKeysShareTheThirdRow() throws {
        let rows = [Self.letters[0], Self.letters[1], Self.numbersThirdRow, Self.letters[3]]
        let numbers = KeyGridGeometry(size: CGSize(width: 393, height: 212), rows: rows)
        let period = try XCTUnwrap(numbers.cap(pos(2, 1)))
        // (380 - 42.054 - 44.173 - 6 * 6 - 15.4) / 5, the old punctuationWidth.
        XCTAssertEqual(period.width, (380 - 1.29 * 32.6 - 1.355 * 32.6 - 36 - 15.4) / 5, accuracy: 0.001)
        let delete = try XCTUnwrap(numbers.cap(pos(2, 6)))
        XCTAssertEqual(delete.maxX, 386.5, accuracy: 0.001)
    }

    // MARK: Nearest key

    func testCenterOfEveryCapIsItsOwnKey() {
        for (r, row) in grid.caps.enumerated() {
            for (i, cap) in row.enumerated() {
                // A touch reported touchBias below the center is aimed at the center.
                let touch = CGPoint(x: cap.midX, y: cap.midY + KeyGridGeometry.touchBias)
                XCTAssertEqual(grid.key(at: touch), pos(r, i), "row \(r) key \(i)")
            }
        }
    }

    func testGapBetweenKeysSplitsAtItsMiddle() {
        // q ends at 39.1, w starts at 45.1: the 6 pt gap splits at 42.1, never a dead touch.
        let y = grid.caps[0][0].midY
        XCTAssertEqual(grid.key(at: CGPoint(x: 39.5, y: y)), pos(0, 0))
        XCTAssertEqual(grid.key(at: CGPoint(x: 42.0, y: y)), pos(0, 0))
        XCTAssertEqual(grid.key(at: CGPoint(x: 42.2, y: y)), pos(0, 1))
        XCTAssertEqual(grid.key(at: CGPoint(x: 44.9, y: y)), pos(0, 1))
    }

    func testEqualWidthKeysUseTheNearestCenter() {
        // Within q..p every boundary is equidistant from the two centers beside it.
        let row = grid.caps[0]
        for x in stride(from: CGFloat(0), through: 393, by: 0.5) {
            let nearest = row.indices.min { abs(row[$0].midX - x) < abs(row[$1].midX - x) }!
            let assigned = grid.key(at: CGPoint(x: x, y: row[0].midY))!.index
            if abs(abs(row[nearest].midX - x) - abs(row[assigned].midX - x)) > 0.001 {
                XCTFail("x \(x): nearest \(nearest), assigned \(assigned)")
            }
        }
    }

    func testEdgeMarginsBelongToTheEdgeKeys() {
        let y = grid.caps[1][0].midY
        // The home row's 19.3 pt margins: A and L own them out to the screen edge.
        XCTAssertEqual(grid.key(at: CGPoint(x: 0, y: y)), pos(1, 0))
        XCTAssertEqual(grid.key(at: CGPoint(x: 12, y: y)), pos(1, 0))
        XCTAssertEqual(grid.key(at: CGPoint(x: 393, y: y)), pos(1, 8))
        XCTAssertEqual(grid.key(at: CGPoint(x: 380, y: y)), pos(1, 8))
        // The side insets of full rows: Q, P, shift, delete.
        XCTAssertEqual(grid.key(at: CGPoint(x: 1, y: grid.caps[0][0].midY)), pos(0, 0))
        XCTAssertEqual(grid.key(at: CGPoint(x: 392, y: grid.caps[0][0].midY)), pos(0, 9))
        XCTAssertEqual(grid.key(at: CGPoint(x: 1, y: grid.caps[2][0].midY)), pos(2, 0))
        XCTAssertEqual(grid.key(at: CGPoint(x: 392, y: grid.caps[2][0].midY)), pos(2, 8))
    }

    func testTouchesOutsideTheRowsGoToTheNearestRow() {
        XCTAssertEqual(grid.key(at: CGPoint(x: 100, y: -20))?.row, 0)
        XCTAssertEqual(grid.key(at: CGPoint(x: 100, y: 2))?.row, 0)
        XCTAssertEqual(grid.key(at: CGPoint(x: 100, y: 400))?.row, 3)
    }

    func testRowBoundaryIsMidGapShiftedDownByTheBias() {
        // Row 0 center 25.5, row 1 center 79.5: midpoint 52.5, plus the bias in raw coordinates.
        let bias = KeyGridGeometry.touchBias
        let x = grid.caps[0][3].midX
        XCTAssertEqual(grid.key(at: CGPoint(x: x, y: 52.5 + bias - 0.1))?.row, 0)
        XCTAssertEqual(grid.key(at: CGPoint(x: x, y: 52.5 + bias + 0.1))?.row, 1)
        // Between the third row and the bottom row: centers 133.5 and 187.5.
        XCTAssertEqual(grid.key(at: CGPoint(x: x, y: 160.5 + bias - 0.1))?.row, 2)
        XCTAssertEqual(grid.key(at: CGPoint(x: x, y: 160.5 + bias + 0.1))?.row, 3)
    }

    func testBiasMovesALowContactUpAKey() {
        // 57 pt is inside row 1's half of the gap, but a thumb reported there aimed 3 pt higher.
        let x = grid.caps[0][4].midX
        XCTAssertEqual(grid.nearestRow(toAimedY: 57), 1)
        XCTAssertEqual(grid.key(at: CGPoint(x: x, y: 57)), pos(0, 4))
        // The bias (3 pt) is under half the row gap (5.5 pt), so it moves only the boundary in the
        // gap: the top edge of row 1's cap is still row 1.
        XCTAssertEqual(grid.key(at: CGPoint(x: grid.caps[1][4].midX, y: grid.caps[1][4].minY + 0.1)), pos(1, 4))
    }

    func testEveryPointInsideACapIsThatKey() {
        for width in [CGFloat(393), 320] {
            let height: CGFloat = width < 380 ? 196 : 212
            let g = KeyGridGeometry(size: CGSize(width: width, height: height), rows: Self.letters)
            for (r, row) in g.caps.enumerated() {
                for (i, cap) in row.enumerated() {
                    for x in stride(from: cap.minX + 0.05, to: cap.maxX, by: 1) {
                        for y in stride(from: cap.minY + 0.05, to: cap.maxY, by: 1) {
                            XCTAssertEqual(g.key(at: CGPoint(x: x, y: y)), pos(r, i), "w\(width) \(x),\(y)")
                        }
                    }
                }
            }
        }
    }

    func testThirdRowGapBetweenShiftAndZ() {
        let shift = grid.caps[2][0], z = grid.caps[2][1]
        let middle = (shift.maxX + z.minX) / 2
        XCTAssertEqual(grid.key(at: CGPoint(x: middle - 0.1, y: shift.midY)), pos(2, 0))
        XCTAssertEqual(grid.key(at: CGPoint(x: middle + 0.1, y: shift.midY)), pos(2, 1))
    }

    func testATouchInsideTheSpaceBarIsSpaceEvenNearReturn() {
        // Plain nearest-center would hand this to return (61 pt away vs 108); the gap rule does not.
        let space = grid.caps[3][2]
        let touch = CGPoint(x: space.maxX - 10, y: space.midY)
        XCTAssertEqual(grid.key(at: touch), pos(3, 2))
        XCTAssertEqual(grid.key(at: CGPoint(x: space.maxX + 2.9, y: space.midY)), pos(3, 2))
        XCTAssertEqual(grid.key(at: CGPoint(x: space.maxX + 3.1, y: space.midY)), pos(3, 3))
    }

    // MARK: Regions and release

    func testTouchRegionsTileTheGrid() {
        var area: CGFloat = 0
        var regions: [(KeyGridGeometry.Position, CGRect)] = []
        for (r, row) in grid.caps.enumerated() {
            for i in row.indices {
                let region = grid.touchRegion(pos(r, i))!
                area += region.width * region.height
                regions.append((pos(r, i), region))
            }
        }
        XCTAssertEqual(area, 393 * 212, accuracy: 0.01)
        // Every sampled point lands in the region of the key it is assigned.
        for x in stride(from: CGFloat(0.25), to: 393, by: 2.5) {
            for y in stride(from: CGFloat(0.25), to: 212, by: 2.5) {
                let key = grid.key(at: CGPoint(x: x, y: y))!
                let region = regions.first { $0.0 == key }!.1
                XCTAssertTrue(region.insetBy(dx: -0.01, dy: -0.01).contains(CGPoint(x: x, y: y)), "\(x),\(y) -> \(key)")
            }
        }
    }

    func testReleaseToleranceKeepsARollingThumbOnItsKey() {
        let e = pos(0, 2)
        let cap = grid.cap(e)!
        let down = CGPoint(x: cap.midX, y: cap.midY + KeyGridGeometry.touchBias)
        XCTAssertTrue(grid.isNear(down, to: e))
        // 15 pt past the right edge (into r) still counts as e; 17 pt does not.
        XCTAssertTrue(grid.isNear(CGPoint(x: cap.maxX + 15, y: down.y), to: e))
        XCTAssertFalse(grid.isNear(CGPoint(x: cap.maxX + 17, y: down.y), to: e))
    }

    func testEmptyGridHasNoKeys() {
        let empty = KeyGridGeometry(size: CGSize(width: 393, height: 212), rows: [])
        XCTAssertNil(empty.key(at: CGPoint(x: 10, y: 10)))
        XCTAssertNil(empty.cap(pos(0, 0)))
    }

    // MARK: Keys above the space bar

    /// The letters a thumb that stops short of the space bar types, per bottom row, on a 393 pt
    /// and a 402 pt phone. Third row: shift, z x c v b n m (indices 1 to 7), delete.
    func testKeysAboveTheSpaceBarFollowTheBottomRow() {
        let thirdRow = Self.letters[2]
        let bottomRows: [(name: String, row: KeyGridRow, space: Int, letters: String)] = [
            ("123, globe or emoji, space, return", KeyGridRow([.units(1.29), .units(1.29), .fill, .units(2.78)]), 2, "xcvbn"),
            ("123, space, return (Face ID phones)", KeyGridRow([.units(1.29), .fill, .units(2.78)]), 1, "zxcvbn"),
            ("123, globe, emoji, space, return", KeyGridRow([.units(1.29), .units(1.29), .units(1.29), .fill, .units(2.78)]), 3, "cvbn"),
            // Return narrows beside paste; n still sits mostly over the space bar.
            ("123, globe or emoji, space, paste, return",
             KeyGridRow([.units(1.29), .units(1.29), .fill, .units(1.29), .units(1.85)]), 2, "xcvbn"),
            ("123, space, paste, return", KeyGridRow([.units(1.29), .fill, .units(1.29), .units(1.85)]), 1, "zxcvbn"),
        ]
        for width: CGFloat in [393, 402] {
            for bottom in bottomRows {
                let geometry = KeyGridGeometry(size: CGSize(width: width, height: 212),
                                               rows: Array(Self.letters.prefix(2)) + [thirdRow, bottom.row])
                let above = geometry.keys(above: pos(3, bottom.space))
                XCTAssertTrue(above.allSatisfy { $0.row == 2 && (1...7).contains($0.index) }, bottom.name)
                let letters = String(above.map { Array("zxcvbnm")[$0.index - 1] })
                XCTAssertEqual(letters, bottom.letters, "\(bottom.name) at \(width) pt")
            }
        }
    }

    func testKeysAboveSkipEmptyRowsAndTheTopRow() {
        XCTAssertEqual(grid.keys(above: pos(0, 3)), [])
        let gapped = KeyGridGeometry(size: CGSize(width: 393, height: 212),
                                     rows: [Self.letters[2], KeyGridRow([]), Self.letters[3]])
        XCTAssertEqual(gapped.keys(above: pos(2, 2)).map(\.row), Array(repeating: 0, count: 5))
        XCTAssertNil(gapped.cap(pos(5, 0)))
        XCTAssertEqual(gapped.keys(above: pos(5, 0)), [])
    }
}
