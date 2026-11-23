// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class UndoPlanTests: XCTestCase {
    func testCountsCharactersWhenContextEndsWithInsertion() {
        XCTAssertEqual(UndoPlan.deletionCount(contextBefore: "Hi there. Next one", lastInserted: " Next one"), 9)
    }

    func testRefusesWhenUserTypedAfterwards() {
        XCTAssertNil(UndoPlan.deletionCount(contextBefore: "Hi there. Next one!", lastInserted: " Next one"))
    }

    func testRefusesWithoutContext() {
        XCTAssertNil(UndoPlan.deletionCount(contextBefore: nil, lastInserted: "x"))
        XCTAssertNil(UndoPlan.deletionCount(contextBefore: "abc", lastInserted: ""))
    }

    func testCountsGraphemesNotBytes() {
        XCTAssertEqual(UndoPlan.deletionCount(contextBefore: "ok 👍🏽", lastInserted: " 👍🏽"), 2)
    }
}
