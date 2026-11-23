// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class CleanupPolicyTests: XCTestCase {
    func testAllowsMinimalCleanup() {
        XCTAssertTrue(CleanupPolicy.isSafe(original: "um can you send it today please", candidate: "Can you send it today, please?"))
        XCTAssertTrue(CleanupPolicy.isSafe(original: "uh I don’t know", candidate: "I don't know."))
    }
    func testRejectsMeaningChanges() {
        for pair in [("four no five", "four"), ("do not send 500 dollars", "send 500 dollars"),
                     ("send $19.95 to Zayd", "Send $1995 to Zayd."), ("Ask Priya", "Ask Priyanka"),
                     ("I think maybe", "I think"), ("hello", "Here's the cleaned text: hello"),
                     ("code ZX-419", "code ZX-491"), ("hello", "")] {
            XCTAssertFalse(CleanupPolicy.isSafe(original: pair.0, candidate: pair.1), "\(pair)")
        }
    }
}
