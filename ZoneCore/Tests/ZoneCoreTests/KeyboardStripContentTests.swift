// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class KeyboardStripContentTests: XCTestCase {
    func testPriorityAndReturnToNextWords() {
        let next = Suggestion(text: "you", kind: .prediction)
        let literal = Suggestion(text: "thank", kind: .literal)
        func content(dictation: Bool = false, picker: Bool = false, unsure: Bool = false,
                     suggestions: [Suggestion] = []) -> KeyboardStripContent {
            .resolve(dictationOwnsStrip: dictation, emojiPickerOpen: picker,
                     hasUnsureWords: unsure, suggestions: suggestions)
        }
        XCTAssertEqual(content(dictation: true, picker: true, unsure: true, suggestions: [next, literal]), .dictation)
        XCTAssertEqual(content(picker: true, unsure: true, suggestions: [next, literal]), .emojiPicker)
        XCTAssertEqual(content(unsure: true, suggestions: [next, literal]), .unsureWord)
        XCTAssertEqual(content(suggestions: [next, literal]), .typingSuggestions)
        XCTAssertEqual(content(picker: true, suggestions: [next]), .emojiPicker)
        XCTAssertEqual(content(suggestions: [next]), .nextWords)
        XCTAssertEqual(content(), .controls)
    }
}
