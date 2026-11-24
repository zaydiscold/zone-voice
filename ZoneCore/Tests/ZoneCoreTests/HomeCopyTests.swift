// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// Home may not say two things that cannot both be true (cohesion audit 2026-11-20, finding 6).
final class HomeCopyTests: XCTestCase {
    func testStandbySaysKeyboardReadyOnlyOnceTheKeyboardHasReportedIn() {
        // The setup list under the hero says "Keyboard" is not done until then.
        XCTAssertEqual(HomeCopy.standby(keyboardReported: false, left: "4:55"), "Mic ready · 4:55 left")
        XCTAssertEqual(HomeCopy.standby(keyboardReported: false, left: nil), "Mic ready")
        XCTAssertFalse(HomeCopy.standby(keyboardReported: false, left: "4:55").contains("Keyboard"))
        XCTAssertEqual(HomeCopy.standby(keyboardReported: true, left: "4:55"), "Keyboard ready · 4:55 left")
        XCTAssertEqual(HomeCopy.standby(keyboardReported: true, left: nil), "Keyboard ready")
    }

    func testTheWordCountNeverClaimsDictationsThatHistoryDoesNotList() {
        // A note's words count, and History then still says "No dictations yet".
        for words in [0, 1, 8, 1_204] {
            XCTAssertFalse(HomeCopy.wordsLabel(words).contains("dictat"), "\(words)")
        }
        XCTAssertEqual(HomeCopy.wordsLabel(1), "word spoken")
        XCTAssertEqual(HomeCopy.wordsLabel(8), "words spoken")
    }

    func testHomeAndShareCardStatsOnlyClaimMeasuredPaceAndEstimatedSavings() {
        let stats = HomeCopy.stats(wordsPerMinute: 103, minutesSaved: 65)
        XCTAssertEqual(stats.map(\.label), ["wpm", "est. time saved"])
        XCTAssertEqual(stats.map(\.value), ["103", "1h 5m"])
        XCTAssertEqual(HomeCopy.stats(wordsPerMinute: 0, minutesSaved: 0).first?.value, "—")
    }
}
