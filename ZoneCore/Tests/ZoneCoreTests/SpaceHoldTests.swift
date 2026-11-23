// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class SpaceHoldTests: XCTestCase {
    // MARK: The setting

    func testMoveCursorIsTheDefaultForNewAndOlderRecords() throws {
        XCTAssertEqual(KeyboardPreferences().spaceHold, .moveCursor)
        // A record written before the setting existed keeps today's space bar.
        let old = try JSONDecoder().decode(KeyboardPreferences.self, from: Data(#"{"showsPasteKey":true}"#.utf8))
        XCTAssertEqual(old.spaceHold, .moveCursor)
        XCTAssertTrue(old.showsPasteKey)
    }

    func testEveryChoiceSurvivesTheSharedStore() throws {
        for choice in SpaceHold.allCases {
            let stored = try JSONEncoder().encode(KeyboardPreferences(spaceHold: choice))
            XCTAssertEqual(try JSONDecoder().decode(KeyboardPreferences.self, from: stored).spaceHold, choice)
        }
    }

    func testAnUnknownChoiceFallsBackAloneWithoutResettingOtherSwitches() throws {
        // A later build's choice read by this one: only this field falls back.
        let future = Data(#"{"spaceHold":"somethingNew","swipeTypingEnabled":true,"autocorrectEnabled":false}"#.utf8)
        let decoded = try JSONDecoder().decode(KeyboardPreferences.self, from: future)
        XCTAssertEqual(decoded.spaceHold, .moveCursor)
        XCTAssertTrue(decoded.swipeTypingEnabled)
        XCTAssertFalse(decoded.autocorrectEnabled)
    }

    func testLabelsMarkTalkAsBeta() {
        XCTAssertEqual(SpaceHold.moveCursor.label, "Move cursor")
        XCTAssertEqual(SpaceHold.talk.label, "Talk (Beta)")
        XCTAssertEqual(SpaceHold.allCases, [.moveCursor, .talk])
    }

    // MARK: Starting

    func testAReadyZoneTalks() {
        XCTAssertEqual(SpaceTalk.start(hasFullAccess: true, appGroupReachable: true, dictationUnderWay: false,
                                       zoneListensInPlace: true), .talk)
    }

    func testASleepingZoneIsExplainedAndNeverOpened() {
        XCTAssertEqual(SpaceTalk.start(hasFullAccess: true, appGroupReachable: true, dictationUnderWay: false,
                                       zoneListensInPlace: false), .explainNotReady)
    }

    func testNothingToTalkWithMovesTheCursorAsBefore() {
        for (access, reachable, underWay) in [(false, true, false), (true, false, false), (true, true, true), (false, false, true)] {
            for ready in [true, false] {
                XCTAssertEqual(SpaceTalk.start(hasFullAccess: access, appGroupReachable: reachable,
                                               dictationUnderWay: underWay, zoneListensInPlace: ready), .moveCursor,
                               "access \(access) reachable \(reachable) underWay \(underWay) ready \(ready)")
            }
        }
    }

    func testTheHoldWaitsAsLongAsTheCursorHold() {
        // A slow tap on space types a space in both settings.
        XCTAssertEqual(SpaceTalk.holdDuration, SpacebarCursorGesture.holdDuration)
    }

    // MARK: Letting go

    func testLettingGoStopsOnlyWhatIsListening() {
        XCTAssertEqual(SpaceTalk.release(.listening), .stop)
        XCTAssertEqual(SpaceTalk.release(.starting), .withdrawTooSoon)
        XCTAssertEqual(SpaceTalk.release(.none), .nothing)
    }

    // MARK: Words on screen

    func testTheSpaceBarSaysWhatToDo() {
        XCTAssertNil(SpaceTalk.spaceLabel(.none))
        XCTAssertEqual(SpaceTalk.spaceLabel(.starting), "Starting…")
        XCTAssertEqual(SpaceTalk.spaceLabel(.listening), "Let go to insert")
        // Drawn at 12 points on the space bar, beside "Slide to move cursor" (20 characters).
        for phase in [SpaceTalk.Phase.starting, .listening] {
            XCTAssertLessThanOrEqual(SpaceTalk.spaceLabel(phase)?.count ?? 0, 20)
        }
    }

    func testStripMessagesAreAProblemThenWhatToDo() {
        // The strip draws the first sentence as the title and the rest as one line of detail.
        for message in [SpaceTalk.notReadyMessage, SpaceTalk.tooSoonMessage] {
            let sentences = message.split(separator: ".", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            XCTAssertEqual(sentences.count, 2, message)
            XCTAssertLessThanOrEqual(sentences[0].count, 40, message)
            XCTAssertFalse(message.contains("\u{2014}"), message)
        }
        XCTAssertTrue(SpaceTalk.notReadyMessage.hasSuffix("Tap the mic to wake it."))
    }
}
