// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class MeetingTextTests: XCTestCase {
    func testDictationAndMeetingAgreeOnWordsNamesAndTimes() {
        let words = ["FernSpark", "QuillBerry"]
        let contacts = ["Sarah Kowalski"]
        let fixes = ["furnsparc": "FernSpark"]
        let input = "I sent quillberry and furnsparc to Sarah kowalski at two fifteen."
        let meeting = TextStyle.meetingTranscript(input, personalWords: words, systemWords: contacts, misheard: fixes)
        XCTAssertEqual(meeting, "I sent QuillBerry and FernSpark to Sarah Kowalski at 2:15.")
        XCTAssertEqual(meeting, TextStyle.formal.apply(input, personalWords: words, systemWords: contacts, misheard: fixes))
    }

    func testSpokenCommandsFillersAndLiteralsRemainInTheTranscript() {
        let input = "um i said new line, scratch that, at sign, https://example.com/versales"
        XCTAssertEqual(TextStyle.meetingTranscript(input, personalWords: [], systemWords: [], misheard: ["versales": "Vercel"]),
                       "um I said new line, scratch that, at sign, https://example.com/versales")
    }
}
