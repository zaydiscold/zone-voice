// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class PersonalVocabularyTests: XCTestCase {
    private func store() -> PersonalVocabulary {
        PersonalVocabulary(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("words.json"))
    }
    func testPersistsCanonicalCaseAndDeduplicates() throws {
        let first = store(); defer { try? FileManager.default.removeItem(at: first.fileURL.deletingLastPathComponent()) }
        try first.add([" Zayd ", "Dahlsson", "zayd", ""])
        XCTAssertEqual(try PersonalVocabulary(fileURL: first.fileURL).words(), ["Zayd", "Dahlsson"])
    }

    func testRenameHandlePreservesKeyboardChangesAndDoesNotReviveDeletedRows() throws {
        let app = store(); defer { try? FileManager.default.removeItem(at: app.fileURL.deletingLastPathComponent()) }
        let keyboard = PersonalVocabulary(fileURL: app.fileURL)
        try app.addHandles(["old"])
        try keyboard.addHandles(["new", "learned"])
        XCTAssertEqual(try app.renameHandle("old", to: "@NEW"), ["new", "learned"])
        XCTAssertThrowsError(try app.renameHandle("old", to: "lost"))
        XCTAssertThrowsError(try app.renameHandle("new", to: "@"))
        XCTAssertEqual(try keyboard.handles(), ["new", "learned"])
    }
    func testHandlesNormalizeAndSurviveWordEdits() throws {
        let app = store(); defer { try? FileManager.default.removeItem(at: app.fileURL.deletingLastPathComponent()) }
        let legacy = Data(#"{"version":1,"words":["Zayd"],"learnsFromCorrections":true}"#.utf8)
        try FileManager.default.createDirectory(at: app.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try legacy.write(to: app.fileURL)
        XCTAssertEqual(try app.handles(), [])
        XCTAssertEqual(try app.addHandles(["@Cold ", "cold", "snake byte", "@", "Zoë", "x_9.y"]), ["cold", "snakebyte", "zoe", "x_9.y"])
        let keyboard = PersonalVocabulary(fileURL: app.fileURL)
        try keyboard.addHandles(["everyone"])
        XCTAssertEqual(try app.save(["Zayd", "Daan"], replacing: ["Zayd"]), ["Daan", "Zayd"])
        XCTAssertEqual(try app.removeHandles(["@Zoe"]), ["cold", "snakebyte", "x_9.y", "everyone"])
        XCTAssertEqual(try keyboard.document().words, ["Daan", "Zayd"])
    }
    /// A folder the app did not create (seeded by a developer tool, or restored) can refuse every
    /// write. The words were readable all along, so the save sets that folder aside and keeps them.
    func testSaveRecoversFromAFolderThatRefusesWrites() throws {
        let app = store()
        let folder = app.fileURL.deletingLastPathComponent()
        defer {
            for url in (try? FileManager.default.contentsOfDirectory(at: folder.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
            where url.lastPathComponent.hasPrefix(folder.lastPathComponent) {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
                try? FileManager.default.removeItem(at: url)
            }
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"version":1,"words":["Zayd","Mattson"],"learnsFromCorrections":false}"#.utf8).write(to: app.fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        XCTAssertEqual(try app.save(["Zayd", "Mattson", "cli", "grokbot"], replacing: ["Zayd", "Mattson"]),
                       ["cli", "grokbot", "Zayd", "Mattson"])
        let reread = try PersonalVocabulary(fileURL: app.fileURL).document()
        XCTAssertEqual(reread.words, ["cli", "grokbot", "Zayd", "Mattson"])
        XCTAssertFalse(reread.learnsFromCorrections)
        XCTAssertEqual(try app.add(["Daan"]).last, "Daan")
    }
    /// Words that cannot be read are never replaced by an empty list.
    func testUnreadableWordsAreNotSetAside() throws {
        let app = store()
        let folder = app.fileURL.deletingLastPathComponent()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: app.fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        XCTAssertThrowsError(try app.add(["cli"]))
        XCTAssertEqual(try Data(contentsOf: app.fileURL), Data("not json".utf8))
    }
    func testEditorPreservesConcurrentLearnAndExplicitDeletion() throws {
        let app = store(); defer { try? FileManager.default.removeItem(at: app.fileURL.deletingLastPathComponent()) }
        try app.add(["Zayd", "Dahlsson"])
        let original = try app.words()
        try PersonalVocabulary(fileURL: app.fileURL).add(["Grok"])
        XCTAssertEqual(try app.save(["ZAYD"], replacing: original), ["ZAYD", "Grok"])
        XCTAssertEqual(try app.words(), ["ZAYD", "Grok"])
    }
    func testUntouchedEditorLinePreservesConcurrentCanonicalCorrection() throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.add(["Dahlsson"])
        let original = try store.words()
        try store.learnCorrection("DAHLSSON")
        XCTAssertEqual(try store.save(["Dahlsson", "Zayd"], replacing: original), ["Zayd", "DAHLSSON"])
    }
    func testOptOutPreservesManualWordsAndRecentCorrectionHasHintPriority() throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.add((0..<100).map { "Term\($0)" })
        try store.learnCorrection("Zayd")
        XCTAssertEqual(try store.words().first, "Zayd")
        XCTAssertEqual(try store.words().count, 101)
        try store.setLearningEnabled(false)
        try store.learnCorrection("Dahlsson")
        XCTAssertFalse(try store.words().contains("Dahlsson"))
        try store.add(["Dahlsson"])
        XCTAssertTrue(try store.words().contains("Dahlsson"))
        XCTAssertFalse(try store.document().learnsFromCorrections)
    }
    func testCorruptExistingDataIsNotOverwrittenByAnAddition() throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.add(["Zayd"])
        let invalid = Data("broken".utf8)
        try invalid.write(to: store.fileURL)
        XCTAssertThrowsError(try store.add(["Dahlsson"]))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), invalid)
    }
    func testIndependentWritersDoNotLoseAdditions() throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let group = DispatchGroup()
        for i in 0..<20 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do { try PersonalVocabulary(fileURL: store.fileURL).add(["Word\(i)"]) }
                catch { XCTFail("Concurrent add failed: \(error)") }
            }
        }
        group.wait()
        XCTAssertEqual(try store.words().count, 20)
    }
    /// My Words shows learned words apart from typed ones, so the store remembers which is which.
    func testLearnedWordsAreMarkedUntilThePersonRemovesOrRetypesThem() throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.add(["Zayd"])
        try store.learnCorrection("Dahlsson")
        try store.learnCorrection("ZAYD") // already saved: a new capital does not make it learned
        try store.learnCorrection("thier")
        XCTAssertEqual(try store.document().learned, ["dahlsson", "thier"])
        // Another process (the keyboard) reads the same marks.
        XCTAssertEqual(try PersonalVocabulary(fileURL: store.fileURL).document().learned, ["dahlsson", "thier"])
        // Removing a learned word forgets its mark.
        var words = try store.words()
        try store.save(words.filter { $0 != "thier" }, replacing: words)
        XCTAssertEqual(try store.document().learned, ["dahlsson"])
        XCTAssertFalse(try store.words().contains("thier"))
        // Fixing its spelling by hand makes it the person's own word.
        words = try store.words()
        try store.save(words.map { $0 == "Dahlsson" ? "DahlSson" : $0 }, replacing: words)
        XCTAssertEqual(try store.document().learned, [])
        XCTAssertTrue(try store.words().contains("DahlSson"))
    }
    func testAFileFromBeforeLearnedMarksReadsAsNoneLearned() throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":1,"words":["Zayd"],"learnsFromCorrections":true,"learned":["gone","zayd","zayd"]}"#.utf8).write(to: store.fileURL)
        XCTAssertEqual(try store.document().learned, ["zayd"])
        try Data(#"{"version":1,"words":["Zayd"],"learnsFromCorrections":true}"#.utf8).write(to: store.fileURL)
        XCTAssertEqual(try store.document().learned, [])
    }
}
