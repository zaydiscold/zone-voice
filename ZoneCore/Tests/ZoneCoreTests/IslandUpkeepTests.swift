// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class IslandUpkeepTests: XCTestCase {
    private func standby(showsIsland: Bool = true, enabled: Bool = true, ready: Bool = true, card: Bool = false,
                         inFront: Bool = false, cleared: Bool = false, notifies: Bool = true,
                         notified: Bool = false) -> IslandUpkeep.Response {
        IslandUpkeep.response(to: .init(showsIsland: showsIsland, activitiesEnabled: enabled, microphoneReady: ready,
                                        hasCard: card, inFront: inFront, clearedByPerson: cleared, notifies: notifies,
                                        alreadyNotified: notified))
    }

    func testRenewsOnlyACardAtLeastHalfAnHourOld() {
        XCTAssertFalse(IslandUpkeep.shouldRenew(age: 0, held: false))
        XCTAssertFalse(IslandUpkeep.shouldRenew(age: 29 * 60, held: false), "Zone just made it")
        XCTAssertTrue(IslandUpkeep.shouldRenew(age: 30 * 60, held: false))
        XCTAssertTrue(IslandUpkeep.shouldRenew(age: 7 * 3600, held: false))
    }

    /// Leaving Zone, the card has at least 7.5 of its 8 hours left, not 4 as before.
    func testLeavingZoneLeavesAtLeastSevenAndAHalfHours() {
        XCTAssertGreaterThanOrEqual(IslandUpkeep.systemLimit - IslandUpkeep.renewAfter, 7.5 * 3600)
    }

    func testAHeldCardIsNeverReplaced() {
        XCTAssertFalse(IslandUpkeep.shouldRenew(age: 7 * 3600, held: true))
    }

    /// The eight-hour limit took the card while Zone was in the background with the microphone
    /// on: iOS now draws its orange indicator, and only a notification can say why.
    func testNoCardInTheBackgroundWithTheMicrophoneOnNotifiesOnce() {
        XCTAssertEqual(standby(), .notify)
        XCTAssertEqual(standby(notified: true), .nothing, "Once per loss")
    }

    func testInFrontTheCardIsMadeAgainAtOnce() {
        XCTAssertEqual(standby(inFront: true), .restoreNow)
        XCTAssertEqual(standby(inFront: true, cleared: true), .restoreNow, "Opening Zone is asking for it back")
    }

    /// Clearing the card from the Lock Screen is turning Zone off (Zayd, 2026-11-20). Before,
    /// the microphone stayed on behind iOS's orange indicator until Zone was opened.
    func testThePersonClearingTheCardTurnsZoneOff() {
        XCTAssertEqual(standby(cleared: true), .turnOff)
        XCTAssertEqual(standby(cleared: true, notifies: false), .turnOff, "Not a notification: the setting does not gate it")
        XCTAssertEqual(standby(cleared: true, notified: true), .turnOff)
    }

    /// A card cleared while a recording or a call has the microphone turns Zone off only once
    /// that has settled, and never when Zone shows no standby card by the person's own setting.
    func testAClearedCardWaitsForTheMicrophoneAndRespectsTheSetting() {
        XCTAssertEqual(standby(ready: false, cleared: true), .nothing)
        XCTAssertEqual(standby(showsIsland: false, cleared: true), .nothing)
        XCTAssertEqual(standby(enabled: false, cleared: true), .nothing, "Live Activities turned off is not a swipe")
    }

    /// A call or Siri has the microphone, or a recording is running: nothing is drawn as
    /// waiting, so nothing is wrong yet. It is checked again when standby is ready.
    func testOnlyAReadyMicrophoneNeedsTheCard() {
        XCTAssertEqual(standby(ready: false), .nothing)
        XCTAssertEqual(standby(ready: false, inFront: true), .nothing)
    }

    func testNothingWithTheCardUpOrTheIslandOff() {
        XCTAssertEqual(standby(card: true), .nothing)
        XCTAssertEqual(standby(showsIsland: false), .nothing)
        XCTAssertEqual(standby(showsIsland: false, inFront: true), .nothing)
    }

    /// Live Activities turned off for Zone in iOS Settings: no card can be made, so Zone must
    /// neither keep asking iOS for one nor claim the island "ended".
    func testNothingWhenLiveActivitiesAreOff() {
        XCTAssertEqual(standby(enabled: false), .nothing)
        XCTAssertEqual(standby(enabled: false, inFront: true), .nothing)
    }

    func testTheSettingTurnsOnlyTheNotificationOff() {
        XCTAssertEqual(standby(notifies: false), .nothing)
        XCTAssertEqual(standby(inFront: true, notifies: false), .restoreNow)
    }

    func testOnlyThePersonClearingTheCardEndsARecording() {
        XCTAssertEqual(IslandUpkeep.recordingResponse(to: .dismissed), .stop)
        XCTAssertEqual(IslandUpkeep.recordingResponse(to: .ended), .keepRecording, "iOS's time limit never ends a note or a dictation")
    }

    func testTheLimitIsToldApartFromOtherEnds() {
        XCTAssertTrue(IslandUpkeep.reachedSystemLimit(age: 8 * 3600))
        XCTAssertTrue(IslandUpkeep.reachedSystemLimit(age: 8 * 3600 - 30))
        XCTAssertFalse(IslandUpkeep.reachedSystemLimit(age: 3 * 3600))
    }
}
