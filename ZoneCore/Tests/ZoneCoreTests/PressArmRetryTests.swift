// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class PressArmRetryTests: XCTestCase {
    private func worth(_ domain: String, _ code: Int, inFront: Bool = false, carPlay: Bool = false) -> Bool {
        PressArmRetry.worthRetrying(domain: domain, code: code, inFront: inFront, carPlay: carPlay)
    }

    /// The two refusals the phone logged with no call or Siri running, each of which a second
    /// press seconds later got past.
    func testTheTwoBackgroundRefusalsAreTriedAgain() {
        XCTAssertTrue(worth("com.apple.coreaudio.avfaudio", 2_003_329_396))
        XCTAssertTrue(worth(NSOSStatusErrorDomain, 561_015_905))
    }

    /// A call (!pri) or Siri holds the microphone until it ends: waiting 2 seconds changes nothing.
    func testACallOrSiriIsNotWaitedFor() {
        XCTAssertFalse(worth(NSOSStatusErrorDomain, 561_017_449))
        XCTAssertFalse(worth(NSOSStatusErrorDomain, 1_936_290_409))
    }

    func testOtherErrorsAndOtherDomainsAreNot() {
        XCTAssertFalse(worth("com.apple.coreaudio.avfaudio", -10868))
        XCTAssertFalse(worth(NSOSStatusErrorDomain, 2_003_329_396))
        XCTAssertFalse(worth("ZoneCore.CaptureError", 0))
    }

    /// In front there is no background grant to wait for. In the car the refusal repeated four
    /// times in nine seconds, so waiting would only delay the answer.
    func testNotInFrontAndNotInTheCar() {
        XCTAssertFalse(worth("com.apple.coreaudio.avfaudio", 2_003_329_396, inFront: true))
        XCTAssertFalse(worth("com.apple.coreaudio.avfaudio", 2_003_329_396, carPlay: true))
    }

    /// Long enough to pass the 1.8 s after which a second press was seen to work, short enough
    /// that a control does not sit spinning.
    func testTheWaitsCoverTheSecondPressThatWorked() {
        let total = PressArmRetry.pauses.reduce(Duration.zero, +)
        XCTAssertGreaterThanOrEqual(total, .milliseconds(1800))
        XCTAssertLessThanOrEqual(total, .seconds(3))
    }
}
