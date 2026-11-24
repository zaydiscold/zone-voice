// by zayd/cold @ zayd.wtf

import UserNotifications
import XCTest
@testable import Zone

/// A tap on Zone's notice ended the app on November 22, 2026: iOS delivered the answer on a
/// background thread and UIKit's completion ran there. Whatever thread the answer arrives on,
/// Zone's work and iOS's completion handler must run on the main thread.
final class NotificationResponderTests: XCTestCase {
    private func answerFromABackgroundThread(identifier: String, action: String) -> (turnedOff: Bool, order: [String]) {
        let done = expectation(description: "completion")
        var order: [String] = []
        var turnedOff = false
        DispatchQueue.global(qos: .userInitiated).async {
            XCTAssertFalse(Thread.isMainThread)
            ZoneNotificationResponder.shared.answer(identifier: identifier, action: action, turnOff: {
                XCTAssertTrue(Thread.isMainThread, "Zone's own work must be on the main thread")
                turnedOff = true
                order.append("turnOff")
            }, completion: {
                XCTAssertTrue(Thread.isMainThread, "UIKit's completion handler must be called on the main thread")
                order.append("completion")
                done.fulfill()
            })
        }
        wait(for: [done], timeout: 5)
        return (turnedOff, order)
    }

    func testATapOnTheNoticeCompletesOnTheMainThreadWithoutTurningZoneOff() {
        let result = answerFromABackgroundThread(identifier: IslandLostNotice.identifier,
                                                 action: UNNotificationDefaultActionIdentifier)
        XCTAssertFalse(result.turnedOff)
        XCTAssertEqual(result.order, ["completion"])
    }

    func testTurnZoneOffRunsOnTheMainThreadBeforeTheCompletion() {
        let result = answerFromABackgroundThread(identifier: IslandLostNotice.identifier,
                                                 action: IslandLostNotice.turnOffAction)
        XCTAssertTrue(result.turnedOff)
        XCTAssertEqual(result.order, ["turnOff", "completion"])
    }

    func testAnotherNotificationStillCompletesOnTheMainThread() {
        // The cleared-card and recording-safety notices have no action of Zone's, but iOS still
        // waits for the completion handler, and UIKit still runs it.
        let result = answerFromABackgroundThread(identifier: "wtf.zayd.zone.some-other-notice",
                                                 action: IslandLostNotice.turnOffAction)
        XCTAssertFalse(result.turnedOff)
        XCTAssertEqual(result.order, ["completion"])
    }

    func testAnAnswerAlreadyOnTheMainThreadRunsAtOnce() {
        var completed = false
        ZoneNotificationResponder.shared.answer(identifier: IslandLostNotice.identifier, action: "open", turnOff: {},
                                                completion: { completed = true })
        XCTAssertTrue(completed, "no hop when iOS already called on the main thread")
    }

    func testAFailedTurnOffStillCompletes() {
        struct Refused: Error {}
        let done = expectation(description: "completion")
        DispatchQueue.global().async {
            ZoneNotificationResponder.shared.answer(identifier: IslandLostNotice.identifier,
                                                    action: IslandLostNotice.turnOffAction,
                                                    turnOff: { throw Refused() }, completion: { done.fulfill() })
        }
        wait(for: [done], timeout: 5)
    }
}
