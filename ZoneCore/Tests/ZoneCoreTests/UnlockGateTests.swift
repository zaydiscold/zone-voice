// by zayd/cold @ zayd.wtf

import Foundation
import XCTest
@testable import ZoneCore

@MainActor
final class UnlockGateTests: XCTestCase {
    /// Stand-in for the app: what it read when it was built.
    private final class App {
        let accent: String
        init(accent: String) { self.accent = accent }
    }

    /// The phone's preferences: empty to a process that reads them before the first unlock.
    private final class Phone {
        var unlocked = false
        let savedAccent = "orange"
        var reads = 0
        var accent: String? {
            reads += 1
            return unlocked ? savedAccent : nil
        }
    }

    func testAnUnlockedLaunchBuildsAtOnce() {
        let phone = Phone()
        phone.unlocked = true
        let gate = UnlockGate(isAvailable: { phone.unlocked }, build: { App(accent: phone.accent ?? "violet") })
        XCTAssertEqual(gate.value?.accent, "orange")
        XCTAssertNil(gate.waitedSince)
    }

    /// The reported fault: built before the first unlock, Zone ran on violet until it was killed.
    func testALaunchBeforeTheFirstUnlockReadsNothingUntilUnlock() {
        let phone = Phone()
        var builds = 0
        let start = Date(timeIntervalSince1970: 1_000)
        let gate = UnlockGate(now: start, isAvailable: { phone.unlocked }, build: { () -> App in
            builds += 1
            return App(accent: phone.accent ?? "violet")
        })
        XCTAssertNil(gate.value)
        XCTAssertEqual(gate.waitedSince, start)
        XCTAssertNil(gate.check(), "still locked: nothing is built")
        XCTAssertEqual(phone.reads, 0, "no preference is read while locked")
        XCTAssertEqual(builds, 0)

        phone.unlocked = true
        XCTAssertEqual(gate.check()?.accent, "orange", "built on the person's settings, not the defaults")
        XCTAssertEqual(builds, 1)
        _ = gate.check()
        _ = gate.force()
        XCTAssertEqual(builds, 1, "never built twice")
        XCTAssertEqual(gate.waitedSince, start, "kept for the log line")
    }

    /// On screen means unlocked: a probe that still says no must not leave an empty app.
    func testForceBuildsWhenTheProbeDisagrees() {
        let gate = UnlockGate(isAvailable: { false }, build: { App(accent: "orange") })
        XCTAssertNil(gate.check())
        XCTAssertEqual(gate.force().accent, "orange")
        XCTAssertEqual(gate.check()?.accent, "orange")
    }
}
