// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class DictationLimitsTests: XCTestCase {
    private let limits = DictationLimits.standard
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testAVisibleKeyboardKeepsRecording() {
        XCTAssertEqual(limits.decision(now: t0 + 600, startedAt: t0, keyboardLastSeen: t0 + 598,
                                       appLastActive: nil, watchesKeyboard: true), .keepRecording)
    }

    func testAKeyboardGoneForThirtySecondsStopsTheDictation() {
        XCTAssertEqual(limits.decision(now: t0 + 40, startedAt: t0, keyboardLastSeen: t0 + 10,
                                       appLastActive: nil, watchesKeyboard: true), .keyboardGone)
        XCTAssertEqual(limits.decision(now: t0 + 39, startedAt: t0, keyboardLastSeen: t0 + 10,
                                       appLastActive: nil, watchesKeyboard: true), .keepRecording)
    }

    func testHiddenKeyboardGraceIsTheChosenTime() {
        XCTAssertEqual(DictationLimits.hiddenKeyboard(grace: 120, stoppableElsewhere: true).keyboardGoneAfter, 120)
        XCTAssertEqual(DictationLimits.hiddenKeyboard(grace: 900, stoppableElsewhere: false).keyboardGoneAfter, 900)
        XCTAssertEqual(DictationLimits.hiddenKeyboard(grace: 10, stoppableElsewhere: true).keyboardGoneAfter, 30, "never shorter than before")
        // Zoomed into a photo for four minutes on the 5-minute default: still recording.
        let limits = DictationLimits.hiddenKeyboard(grace: DictationLimits.defaultHiddenKeyboardGrace, stoppableElsewhere: true)
        XCTAssertEqual(limits.decision(now: t0 + 250, startedAt: t0, keyboardLastSeen: t0 + 10,
                                       appLastActive: nil, watchesKeyboard: true), .keepRecording)
        XCTAssertEqual(limits.decision(now: t0 + 311, startedAt: t0, keyboardLastSeen: t0 + 10,
                                       appLastActive: nil, watchesKeyboard: true), .keyboardGone)
    }

    func testUntilIStopNeedsAWayToStopIt() {
        let controlled = DictationLimits.hiddenKeyboard(grace: 0, stoppableElsewhere: true)
        XCTAssertEqual(controlled.decision(now: t0 + 5_000, startedAt: t0, keyboardLastSeen: t0 + 10,
                                           appLastActive: nil, watchesKeyboard: true), .keepRecording)
        XCTAssertEqual(controlled.decision(now: t0 + 7_200, startedAt: t0, keyboardLastSeen: t0 + 10,
                                           appLastActive: nil, watchesKeyboard: true), .reachedMaximum,
                       "the two-hour ceiling still applies")
        // Live Activities off: nothing on screen can stop it, so it ends after five minutes.
        let uncontrolled = DictationLimits.hiddenKeyboard(grace: 0, stoppableElsewhere: false)
        XCTAssertEqual(uncontrolled.keyboardGoneAfter, DictationLimits.uncontrolledCeiling)
        XCTAssertEqual(DictationLimits.hiddenKeyboardLabel(0), "Until I stop")
        XCTAssertEqual(DictationLimits.hiddenKeyboardLabel(30), "30 seconds")
        XCTAssertEqual(DictationLimits.hiddenKeyboardLabel(120), "2 minutes")
    }

    func testTheFirstSecondsAreNeverJudgedOnAnOldStamp() {
        // The keyboard appeared an hour ago, then started this dictation just now.
        XCTAssertEqual(limits.decision(now: t0 + 5, startedAt: t0, keyboardLastSeen: t0 - 3_600,
                                       appLastActive: nil, watchesKeyboard: true), .keepRecording)
    }

    func testZoneOnScreenCountsAsWatched() {
        // Cold path: the keyboard opened Zone, which shows the recording itself.
        XCTAssertEqual(limits.decision(now: t0 + 300, startedAt: t0, keyboardLastSeen: nil,
                                       appLastActive: t0 + 299, watchesKeyboard: true), .keepRecording)
    }

    func testShortcutDictationsOnlyHaveTheLengthLimit() {
        XCTAssertEqual(limits.decision(now: t0 + 3_000, startedAt: t0, keyboardLastSeen: nil,
                                       appLastActive: nil, watchesKeyboard: false), .keepRecording)
        XCTAssertEqual(limits.decision(now: t0 + 7_200, startedAt: t0, keyboardLastSeen: nil,
                                       appLastActive: nil, watchesKeyboard: false), .reachedMaximum)
    }

    func testTheLengthLimitAppliesEvenWithTheKeyboardOnScreen() {
        XCTAssertEqual(limits.decision(now: t0 + 7_200, startedAt: t0, keyboardLastSeen: t0 + 7_199,
                                       appLastActive: nil, watchesKeyboard: true), .reachedMaximum)
    }

    func testAStampFromTheFutureNeverStopsARecording() {
        XCTAssertEqual(limits.decision(now: t0 + 100, startedAt: t0, keyboardLastSeen: t0 + 5_000,
                                       appLastActive: nil, watchesKeyboard: true), .keepRecording)
    }

    func testEveryStopHasAPlainNotice() {
        XCTAssertNil(DictationLimits.notice(for: .keepRecording))
        XCTAssertNotNil(DictationLimits.notice(for: .keyboardGone))
        XCTAssertNotNil(DictationLimits.notice(for: .reachedMaximum))
    }
}
