// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class TypingEditsTests: XCTestCase {
    private var corrector: Autocorrector { Autocorrector(words: WordListTests.list) }

    func testSpaceReplacesATypedTypo() {
        let edit = TypingEdits.separator(" ", typedWord: "teh", before: "I saw teh", after: nil, corrector: corrector)
        XCTAssertEqual(edit, TypingEdits.Edit(deleteCount: 3, insert: "the ", correction: AppliedCorrection(typed: "teh", replacement: "the", separator: " ")))
    }

    func testPunctuationAlsoCommits() {
        let edit = TypingEdits.separator(",", typedWord: "becuase", before: "becuase", after: "", corrector: corrector)
        XCTAssertEqual(edit.deleteCount, 7)
        XCTAssertEqual(edit.insert, "because,")
    }

    func testOnlyWordsTheUserKeyedAreCorrected() {
        // Dictated or pasted text: the keyed run does not match the word at the cursor.
        let dictated = TypingEdits.separator(" ", typedWord: nil, before: "hello teh", after: nil, corrector: corrector)
        XCTAssertEqual(dictated, TypingEdits.Edit(deleteCount: 0, insert: " "))
        let partial = TypingEdits.separator(" ", typedWord: "h", before: "teh", after: nil, corrector: corrector)
        XCTAssertEqual(partial, TypingEdits.Edit(deleteCount: 0, insert: " "))
    }

    func testNoCorrectorOrValidWordJustInsertsTheSeparator() {
        XCTAssertEqual(TypingEdits.separator(" ", typedWord: "teh", before: "teh", after: nil, corrector: nil),
                       TypingEdits.Edit(deleteCount: 0, insert: " "))
        XCTAssertEqual(TypingEdits.separator(" ", typedWord: "the", before: "the", after: nil, corrector: corrector),
                       TypingEdits.Edit(deleteCount: 0, insert: " "))
        // Cursor in the middle of a word: never corrected.
        XCTAssertEqual(TypingEdits.separator(" ", typedWord: "te", before: "te", after: "h", corrector: corrector),
                       TypingEdits.Edit(deleteCount: 0, insert: " "))
    }

    func testContractionIsFixedOnSpace() {
        let edit = TypingEdits.separator(" ", typedWord: "dont", before: "I dont", after: nil, corrector: corrector)
        XCTAssertEqual(edit, TypingEdits.Edit(deleteCount: 4, insert: "don't ", correction: AppliedCorrection(typed: "dont", replacement: "don't", separator: " ")))
    }

    func testCurlyApostropheInTheDocumentMatchesTheKeyedOne() {
        // The keyboard typed a straight apostrophe; the host stores a curly one.
        let edit = TypingEdits.separator(" ", typedWord: "does'nt", before: "it does\u{2019}nt", after: nil, corrector: corrector)
        XCTAssertEqual(edit.deleteCount, 7)
        XCTAssertEqual(edit.insert, "doesn't ")
    }

    func testDoubleSpacePeriod() {
        XCTAssertEqual(TypingEdits.doubleSpacePeriod(before: "see you "), TypingEdits.Edit(deleteCount: 1, insert: ". "))
        XCTAssertEqual(TypingEdits.doubleSpacePeriod(before: "at 5 "), TypingEdits.Edit(deleteCount: 1, insert: ". "))
        XCTAssertNil(TypingEdits.doubleSpacePeriod(before: "done. "))
        XCTAssertNil(TypingEdits.doubleSpacePeriod(before: "  "))
        XCTAssertNil(TypingEdits.doubleSpacePeriod(before: "word"))
        XCTAssertNil(TypingEdits.doubleSpacePeriod(before: nil))
    }

    func testRevertPutsTheTypedWordBack() {
        let correction = AppliedCorrection(typed: "teh", replacement: "the", separator: " ")
        XCTAssertEqual(TypingEdits.revert(correction, before: "I saw the "), TypingEdits.Edit(deleteCount: 4, insert: "teh"))
        XCTAssertNil(TypingEdits.revert(correction, before: "I saw the x"))
        XCTAssertNil(TypingEdits.revert(correction, before: nil))
    }

    func testChooseReplacesTheWordAndAddsOneSpace() {
        XCTAssertEqual(TypingEdits.choose("tomorrow", before: "see you tomorr", after: nil), TypingEdits.Edit(deleteCount: 6, insert: "tomorrow "))
        XCTAssertEqual(TypingEdits.choose("tomorrow", before: "tomorr", after: " then"), TypingEdits.Edit(deleteCount: 6, insert: "tomorrow"))
        XCTAssertNil(TypingEdits.choose("x", before: "hello ", after: nil))
    }

    func testWordDeletionCount() {
        XCTAssertEqual(TypingEdits.wordDeletionCount(before: "hello world"), 5)
        XCTAssertEqual(TypingEdits.wordDeletionCount(before: "hello world  "), 7)
        XCTAssertEqual(TypingEdits.wordDeletionCount(before: "don't"), 5)
        XCTAssertEqual(TypingEdits.wordDeletionCount(before: "end."), 1)
        XCTAssertEqual(TypingEdits.wordDeletionCount(before: ""), 1)
        XCTAssertEqual(TypingEdits.wordDeletionCount(before: nil), 1)
    }
}
