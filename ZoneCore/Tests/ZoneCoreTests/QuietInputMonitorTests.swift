// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class QuietInputMonitorTests: XCTestCase {
    func testInitialGraceAndQuietBoundary() {
        var monitor = QuietInputMonitor(startedAt: 100)
        XCTAssertFalse(monitor.sample(level: 0, at: 103))
        XCTAssertFalse(monitor.sample(level: 0, at: 107.99))
        XCTAssertTrue(monitor.sample(level: 0, at: 108))
    }

    func testNormalPauseDoesNotWarnAndSignalClearsWarning() {
        var monitor = QuietInputMonitor(startedAt: 0)
        XCTAssertFalse(monitor.sample(level: 0.4, at: 3))
        XCTAssertFalse(monitor.sample(level: 0, at: 5))
        XCTAssertFalse(monitor.sample(level: 0.3, at: 6))
        XCTAssertFalse(monitor.sample(level: 0, at: 13.99))
        XCTAssertTrue(monitor.sample(level: 0, at: 14))
        XCTAssertFalse(monitor.sample(level: 0.04, at: 14.1))
        XCTAssertFalse(monitor.sample(level: 0, at: 20))
    }

    func testNewRecordingAndUnknownSampleDoNotInheritQuiet() {
        var monitor = QuietInputMonitor(startedAt: 0)
        XCTAssertTrue(monitor.sample(level: 0, at: 9))
        monitor = QuietInputMonitor(startedAt: 10)
        XCTAssertFalse(monitor.sample(level: 0, at: 11))
        XCTAssertFalse(monitor.sample(level: .nan, at: 17))
        XCTAssertFalse(monitor.sample(level: 0, at: 18))
        XCTAssertTrue(monitor.sample(level: 0, at: 25))
    }
}
