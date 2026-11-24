// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class InactivityPolicyTests: XCTestCase {
    func testMicReadySummaryForEveryDuration() {
        for policy in InactivityPolicy.presets where !policy.isUnbounded {
            XCTAssertEqual(policy.micReadySummary, "When you stop using the mic, it turns off after \(policy.label).")
        }
        XCTAssertEqual(InactivityPolicy(timeout: .infinity).micReadySummary, "The mic stays ready until you turn it off.")
    }

    func testDefaultTimeoutIsFiveMinutes() {
        XCTAssertEqual(InactivityPolicy().timeout, 300)
    }

    func testDeadlineAndShouldEnd() {
        let policy = InactivityPolicy(timeout: 300)
        let t = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(policy.deadline(after: t), t.addingTimeInterval(300))
        XCTAssertFalse(policy.shouldEnd(now: t.addingTimeInterval(299), lastActivity: t))
        XCTAssertTrue(policy.shouldEnd(now: t.addingTimeInterval(300), lastActivity: t))
    }

    func testPresetsIncludeSixHoursAndUnbounded() {
        XCTAssertEqual(InactivityPolicy.presets.map(\.timeout), [30, 60, 300, 900, 3600, 21600, .infinity])
        XCTAssertFalse(InactivityPolicy(timeout: .infinity).shouldEnd(now: .distantFuture, lastActivity: .distantPast))
        XCTAssertEqual(InactivityPolicy(timeout: .infinity).label, "until I turn it off")
        XCTAssertEqual(InactivityPolicy(timeout: 3600).label, "1 hour")
        XCTAssertEqual(InactivityPolicy(timeout: 21600).label, "6 hours")
    }

    func testShortPresetsReadInSecondsAndMinutes() {
        XCTAssertEqual(InactivityPolicy(timeout: 30).label, "30 seconds")
        XCTAssertEqual(InactivityPolicy(timeout: 60).label, "1 minute")
        XCTAssertEqual(InactivityPolicy(timeout: 300).label, "5 minutes")
        let t = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(InactivityPolicy(timeout: 30).shouldEnd(now: t.addingTimeInterval(29), lastActivity: t))
        XCTAssertTrue(InactivityPolicy(timeout: 30).shouldEnd(now: t.addingTimeInterval(30), lastActivity: t))
    }

    func testPauseLimitNeverDropsBelowFiveMinutes() {
        XCTAssertEqual(InactivityPolicy(timeout: 30).pauseLimit, 300)
        XCTAssertEqual(InactivityPolicy(timeout: 60).pauseLimit, 300)
        XCTAssertEqual(InactivityPolicy(timeout: 900).pauseLimit, 900)
        XCTAssertNil(InactivityPolicy(timeout: .infinity).pauseLimit)
    }
}
