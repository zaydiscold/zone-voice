// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class StandbyAfterPressTests: XCTestCase {
    private func situation(isArmed: Bool = true, armedByPress: Bool = false, showsStandbyCard: Bool = true,
                           turnsOnWhenZoneOpens: Bool = true, turnedOffByPerson: Bool = false,
                           carKeepsItsAudio: Bool = false) -> StandbyAfterPress.Situation {
        .init(isArmed: isArmed, armedByPress: armedByPress, showsStandbyCard: showsStandbyCard,
              turnsOnWhenZoneOpens: turnsOnWhenZoneOpens, turnedOffByPerson: turnedOffByPerson,
              carKeepsItsAudio: carKeepsItsAudio)
    }

    func testAStandbyThatWasOnStaysOn() {
        XCTAssertEqual(StandbyAfterPress.outcome(situation()), .keep)
        // Whatever the person's other choices: they turned it on, a note does not turn it off.
        XCTAssertEqual(StandbyAfterPress.outcome(situation(turnsOnWhenZoneOpens: false)), .keep)
    }

    func testAPressThatTurnedTheMicrophoneOnLeavesItReadyForSomeoneWhoKeepsZoneOn() {
        XCTAssertEqual(StandbyAfterPress.outcome(situation(armedByPress: true)), .keep)
    }

    func testAPressGivesTheMicrophoneBackToSomeoneWhoTurnedZoneOff() {
        XCTAssertEqual(StandbyAfterPress.outcome(situation(armedByPress: true, turnedOffByPerson: true)), .release)
    }

    func testAPressGivesTheMicrophoneBackWhenZoneNeverTurnsItselfOn() {
        XCTAssertEqual(StandbyAfterPress.outcome(situation(armedByPress: true, turnsOnWhenZoneOpens: false)), .release)
    }

    /// Without the card there is no Live Activity, and iOS ends an app whose recording intent
    /// returns with live audio and none.
    func testNoStandbyCardAlwaysReleases() {
        XCTAssertEqual(StandbyAfterPress.outcome(situation(showsStandbyCard: false)), .release)
        XCTAssertEqual(StandbyAfterPress.outcome(situation(armedByPress: true, showsStandbyCard: false)), .release)
    }

    func testTheCarKeepsItsAudio() {
        XCTAssertEqual(StandbyAfterPress.outcome(situation(carKeepsItsAudio: true)), .release)
    }

    func testNothingToKeepWhenTheMicrophoneIsOff() {
        XCTAssertEqual(StandbyAfterPress.outcome(situation(isArmed: false)), .release)
    }
}
