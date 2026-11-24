// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class KeepConfirmationTests: XCTestCase {
    func testOneKeepDoesNotLearnASecondDoes() {
        var gate = KeepConfirmation()
        XCTAssertFalse(gate.keep("xqzzv"))
        XCTAssertEqual(gate.pending, ["xqzzv"])
        XCTAssertTrue(gate.keep("Xqzzv"))
        XCTAssertTrue(gate.pending.isEmpty)
    }

    func testSecondKeepSurvivesARestart() {
        var first = KeepConfirmation()
        XCTAssertFalse(first.keep("becuase"))
        var restarted = KeepConfirmation(pending: first.pending)
        XCTAssertTrue(restarted.keep("becuase"))
    }

    func testInnerCapitalsLearnAtOnce() {
        var gate = KeepConfirmation()
        XCTAssertTrue(gate.keep("OpenRouter"))
        XCTAssertTrue(gate.keep("iPhone"))
        XCTAssertFalse(gate.keep("NASA"))
        XCTAssertFalse(gate.keep("Zayd"))
    }

    func testPendingIsBounded() {
        var gate = KeepConfirmation()
        for i in 0..<(KeepConfirmation.limit + 20) { _ = gate.keep("w\(i)x") }
        XCTAssertEqual(gate.pending.count, KeepConfirmation.limit)
        XCTAssertEqual(gate.pending.first, "w20x")
    }
}
