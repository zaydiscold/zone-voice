// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class WordListTransferTests: XCTestCase {
    func testExportRoundTripsCaseCommasQuotesAndSeveralHeardForms() throws {
        let original = try WordListCSV.read("word,heard as\r\n\"Quill, Berry\",kwill\r\n\"Quill, Berry\",cwill\r\n\"A\"\"B\",\r\n蒼\r\n")
        XCTAssertEqual(original.words, ["Quill, Berry", "A\"B", "蒼"])
        XCTAssertEqual(original.misheard, ["kwill": "Quill, Berry", "cwill": "Quill, Berry"])
        XCTAssertEqual(try WordListCSV.read(WordListCSV.write(original)), original)
    }

    func testWisprAndReplacementPairsAndPlainText() throws {
        for header in ["", "word,replacement\n", "misspelling,correction\n"] {
            let doc = try WordListCSV.read("\u{feff}" + header + "kwill,QuillBerry\r\nÉlan\r\n")
            XCTAssertEqual(doc.words, ["QuillBerry", "Élan"])
            XCTAssertEqual(doc.misheard, ["kwill": "QuillBerry"])
        }
    }

    func testTransferKeepsLearnedCapitalizationOutOfAppliedSpellings() throws {
        var original = PersonalVocabulary.Document(words: ["The", "QuillBerry"])
        original.learned = ["the"]
        original.misheard = ["kwill": "QuillBerry", "cwill": "QuillBerry"]
        var fresh = PersonalVocabulary.Document(words: [])
        fresh.merge(try WordListCSV.read(WordListCSV.write(original)))
        XCTAssertEqual(fresh.words, original.words)
        XCTAssertEqual(fresh.misheard, original.misheard)
        XCTAssertEqual(fresh.learned, ["the"])
        XCTAssertEqual(fresh.appliedWords, ["QuillBerry"])
        XCTAssertEqual(try WordListCSV.read("word,heard as\nThe,\n").appliedWords, ["The"])
    }

    func testConflictingOrUnknownCSVWordSourcesRejectTheImport() {
        for rows in ["The,,learned\nThe,,added", "The,,typo", "The,"] {
            XCTAssertThrowsError(try WordListCSV.read("word,heard as,source\n" + rows))
        }
    }

    func testMalformedImportRejectsAllRows() {
        for input in ["", "Good\n\"unfinished", "Good\na,b,c", "Good\n\"a\"x", "a,b\na,c", "word,heard as\n,orphan"] {
            XCTAssertThrowsError(try WordListCSV.read(input))
        }
    }

    func testOldBackupAndVocabularyMerge() throws {
        let old = Data(#"{"formatVersion":1,"createdAt":0,"notes":[],"dictations":[],"meetings":[]}"#.utf8)
        XCTAssertNil(try LibraryBackup.decode(old).vocabulary)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersonalVocabulary(fileURL: root.appendingPathComponent("words.json"))
        try store.add(["QuillBerry", "LocalOnly"])
        try store.learnCorrection("Previous", heard: "kwill")
        try store.addHandles(["local"])
        try store.setLearningEnabled(false)
        var incoming = PersonalVocabulary.Document(words: ["QUILLBERRY", "Other"])
        incoming.learned = ["quillberry", "other"]
        incoming.misheard = ["kwill": "Other", "berryquill": "QUILLBERRY"]
        incoming.handles = ["remote"]
        incoming.typedWords = ["fernSpark"]
        incoming.correctionChoices.record(heard: "firn", chosen: "Fern")
        try store.restore(incoming)
        let once = try store.document()
        try store.restore(incoming)
        XCTAssertEqual(try store.document(), once)
        XCTAssertEqual(once.words, ["Previous", "QuillBerry", "LocalOnly", "Other"])
        XCTAssertEqual(once.learned, ["previous", "other"])
        XCTAssertEqual(once.handles, ["local", "remote"])
        XCTAssertFalse(once.learnsFromCorrections)
        XCTAssertEqual(once.misheard, ["kwill": "Previous", "berryquill": "QuillBerry"])
        let keyboard = try store.exchangeKeyboard(typed: ["ivyPod"], previously: [], choices: DoubtMemory())
        XCTAssertEqual(keyboard.typedWords, ["ivyPod", "fernSpark"])
        XCTAssertEqual(keyboard.correctionChoices.choices(for: "firn"), ["Fern"])
        XCTAssertEqual(try store.exchangeKeyboard(typed: ["fernSpark"], previously: keyboard.typedWords, choices: keyboard.correctionChoices).typedWords, ["fernSpark"])
    }
}
