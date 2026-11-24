// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class KeyboardModelCopyTests: XCTestCase {
    func testSettingsAndPrivacyDescribeTheSelectedRouteAndFallback() {
        let routes: [(KeyboardVoiceRoute.Mode, String)] = [
            (.standard, "Zone default tries Zone’s on-device model"),
            (.webView, "Fluid Speech Mini tries to transcribe recordings up to 40 seconds on this iPhone"),
            (.computer, "Zone Link GPU sends finished keyboard audio to your selected HTTPS server")
        ]
        for (mode, description) in routes {
            for neverApple in [false, true] {
                let note = KeyboardModelCopy.settingsNote(mode: mode, enabled: true, neverApple: neverApple)
                let privacy = KeyboardModelCopy.privacyNote(mode: mode, enabled: true, neverApple: neverApple)
                XCTAssertTrue(note.contains(description))
                XCTAssertTrue(note.contains("record first"))
                XCTAssertTrue(note.contains("asks Zone to finish"))
                XCTAssertEqual(note.contains("Apple’s speech model is off"), neverApple)
                XCTAssertEqual(note.contains("fall back to Apple’s"), !neverApple)
                XCTAssertEqual(note.contains("selected HTTPS server"), mode == .computer)
                XCTAssertTrue(privacy.hasPrefix(note))
                XCTAssertTrue(privacy.contains("delete saved keyboard recordings"))
            }
        }
    }

    func testDisabledCaptureDoesNotDescribeTheSavedProviderAsActive() {
        for mode in KeyboardVoiceRoute.Mode.allCases {
            let privacy = KeyboardModelCopy.privacyNote(mode: mode, enabled: false, neverApple: true)
            XCTAssertTrue(privacy.contains("Dictate without opening Zone is off"))
            XCTAssertFalse(privacy.contains("sends finished keyboard audio"))
        }
    }
}
