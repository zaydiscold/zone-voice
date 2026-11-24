// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class SpaceBarLabelTests: XCTestCase {
    func testLineIsTheDefaultForNewAndOlderRecords() throws {
        XCTAssertEqual(KeyboardPreferences().spaceBar, .line)
        let old = try JSONDecoder().decode(KeyboardPreferences.self, from: Data(#"{"showsPasteKey":true}"#.utf8))
        XCTAssertEqual(old.spaceBar, .line)
        XCTAssertTrue(old.showsPasteKey)
    }

    func testEveryChoiceSurvivesTheSharedStore() throws {
        for choice in SpaceBarLabel.allCases {
            let stored = try JSONEncoder().encode(KeyboardPreferences(spaceBar: choice))
            XCTAssertEqual(try JSONDecoder().decode(KeyboardPreferences.self, from: stored).spaceBar, choice)
        }
    }

    func testAnUnknownChoiceFallsBackAloneWithoutResettingOtherSwitches() throws {
        let future = Data(#"{"spaceBar":"sparkles","swipeTypingEnabled":true,"spaceHold":"talk"}"#.utf8)
        let decoded = try JSONDecoder().decode(KeyboardPreferences.self, from: future)
        XCTAssertEqual(decoded.spaceBar, .line)
        XCTAssertTrue(decoded.swipeTypingEnabled)
        XCTAssertEqual(decoded.spaceHold, .talk)
    }

    func testTheVoiceMarkIsTallestInTheMiddleAndSymmetric() {
        let bars = SpaceBarLabel.voiceBars
        XCTAssertEqual(bars.count % 2, 1)
        XCTAssertEqual(bars, bars.reversed())
        XCTAssertEqual(bars.max(), bars[bars.count / 2])
    }

    func testPickerLabels() {
        XCTAssertEqual(SpaceBarLabel.allCases.map(\.label), ["Line", "Voice", "Word", "Blank"])
    }
}
