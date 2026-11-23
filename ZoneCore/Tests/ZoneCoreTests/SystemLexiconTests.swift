// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class SystemLexiconTests: XCTestCase {
    private let entries = [(input: "nita", text: "Nita"), (input: "Nika", text: "Nika"),
                           (input: "iphone", text: "iPhone"), (input: "omw", text: "On my way!")]

    func testCaseOnlyPairsFeedSwipeNamesWithoutLosingTypedReplacements() {
        let snapshot = SystemLexiconSnapshot(entries: entries)
        XCTAssertEqual(snapshot.names, ["Nita", "Nika", "iPhone"])
        XCTAssertEqual(snapshot.replacements["nita"], "Nita")
        XCTAssertEqual(snapshot.replacements["omw"], "On my way!")
        let corrector = Autocorrector(words: WordListTests.list)
        corrector.setSystemLexicon(names: snapshot.names, replacements: snapshot.replacements)
        XCTAssertEqual(corrector.evaluate("omw").replacement, "On my way!")
        XCTAssertTrue(corrector.recognizes("Nita"))
    }

    func testAnotherProcessReadsLatestSnapshotAndEmptyRefreshRemovesOldTerms() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = SystemLexiconStore(fileURL: root.appendingPathComponent("terms.json"))
        let reader = SystemLexiconStore(fileURL: writer.fileURL)
        XCTAssertEqual(try reader.snapshot(), .empty)
        try writer.save(SystemLexiconSnapshot(entries: entries))
        XCTAssertTrue(try reader.snapshot().speechWords.contains("Nita"))
        XCTAssertFalse(try reader.snapshot().speechWords.contains("omw"))
        try writer.save(.empty)
        XCTAssertEqual(try reader.snapshot(), .empty)
    }

    /// The keyboard saves the system's lexicon on every appearance; the same one again must not
    /// rewrite the file, and a file that went missing must come back.
    func testUnchangedSnapshotIsNotRewrittenAndAMissingFileIs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SystemLexiconStore(fileURL: root.appendingPathComponent("terms.json"))
        let snapshot = SystemLexiconSnapshot(entries: entries)
        try store.save(snapshot)
        // A marker in place of the file shows whether the next save wrote.
        try Data("marker".utf8).write(to: store.fileURL)
        try store.save(snapshot)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), Data("marker".utf8))
        try store.save(.empty)
        XCTAssertEqual(try store.snapshot(), .empty)
        try store.save(snapshot)
        XCTAssertEqual(try store.snapshot(), snapshot)
        try FileManager.default.removeItem(at: store.fileURL)
        try store.save(snapshot)
        XCTAssertEqual(try store.snapshot(), snapshot)
    }

    func testVoiceUsesImportedNamesWithoutAddingThemToMyWords() {
        let words = SystemLexiconSnapshot(entries: entries).speechWords
        XCTAssertEqual(TextStyle.casual.apply("I met Nida and Nica", systemWords: words), "I met Nita and Nika")
        XCTAssertEqual(TextStyle.formal.apply("Nida called", systemWords: words), "Nita called.")
        XCTAssertEqual(TextStyle.casual.insertion(of: "Nica called", contextBefore: nil,
            fieldCapitalizesSentences: false, opening: .lowercase, systemWords: words), "Nika called")
    }

    func testImportedContactsDoNotRewriteOrdinaryProseShortcutsOrLiteralTags() {
        let words = ["Will", "May", "Mark", "Rose", "Nita", "Nika", "On my way!"]
        XCTAssertEqual(TextStyle.casual.apply("I will mark it in may", systemWords: words),
                       TextStyle.casual.apply("I will mark it in may"))
        XCTAssertEqual(TextStyle.casual.apply("omw", systemWords: words), TextStyle.casual.apply("omw"))
        XCTAssertEqual(TextStyle.casual.apply("ask @Nida and `Nica`", systemWords: words), "Ask @Nida and `Nica`")
        XCTAssertEqual(TextStyle.casual.apply("at sign Nida", systemWords: words), "@nida")
    }

    func testExplicitWordsAndExistingContactSpellingsWinOverFuzzyMatchAndBuiltIns() {
        XCTAssertEqual(TextStyle.casual.apply("I met Nida", personalWords: ["Nida"], systemWords: ["Nita"]), "I met Nida")
        XCTAssertEqual(TextStyle.casual.apply("I met Nida", systemWords: ["Nida", "Nita"]), "I met Nida")
        XCTAssertEqual(TextStyle.casual.apply("I met Zaid", systemWords: ["Zaid"]), "I met Zaid")
    }

    func testAmbiguousCandidatesStayRecognizedAndDiacriticsAndPossessivesSurvive() {
        XCTAssertEqual(TextStyle.casual.apply("I met Nita", systemWords: ["Neta", "Nuta"]), "I met Nita")
        XCTAssertEqual(TextStyle.casual.apply("I met Soren's team", systemWords: ["Sören"]), "I met Sören's team")
        XCTAssertEqual(TextStyle.casual.apply("my iphone", systemWords: ["iPhone"]), "My iPhone")
        XCTAssertEqual(TextStyle.casual.apply("ask @NiTa.name and nida@example.com", systemWords: ["Nita"]),
                       "Ask @NiTa.name and nida@example.com")
    }

    func testExplicitPhrasesProtectOnlyTheirMatchedSpansIncludingOverlaps() {
        let text = "I met Nida Jones and Nida"
        XCTAssertEqual(TextStyle.correctingSystemVocabulary(text, systemWords: ["Nita"], personalWords: ["Nida Jones"]),
                       "I met Nida Jones and Nita")
        XCTAssertEqual(TextStyle.casual.apply(text, personalWords: ["Nida Jones"], systemWords: ["Nita"]),
                       "I met Nida Jones and Nita")
        XCTAssertEqual(TextStyle.correctingSystemVocabulary("I met nida  jones and Nida", systemWords: ["Nita"], personalWords: ["Nida Jones"]),
                       "I met nida  jones and Nita")
        XCTAssertEqual(TextStyle.correctingSystemVocabulary("Nida Jones Smith", systemWords: ["Nita", "Smeth"],
            personalWords: ["Nida Jones", "Jones Smith"]), "Nida Jones Smith")
    }

    func testLowercaseDictionaryProseIsNotRewrittenByImportedNames() {
        let words = Stress.bundledWords.map(\.word).filter { $0 == $0.lowercased() && $0.allSatisfy(\.isLetter) }.prefix(5_000)
        let text = "so " + words.joined(separator: " ")
        let imported = ["Nita", "Nika", "Will", "May", "Mark", "Rose", "Dahlsson", "Sören", "Siobhan"]
        XCTAssertEqual(TextStyle.correctingSystemVocabulary(text, systemWords: imported), text)
    }

    func testFinalRecognitionUsesLexiconWhileForwardingAudioPartialsAndCancellation() async throws {
        let base = LexiconFixtureSession()
        let session = LexiconRecognitionSession(base: base, systemWords: ["Nita", "Nika"], personalWords: [], mentions: false)
        session.feed([0, 0, 0])
        XCTAssertEqual(base.fed, 3)
        XCTAssertEqual(session.textSoFar, "I met Nida and Nica")
        XCTAssertEqual(session.availableAudioSamples, 123)
        let text = try await session.finish()
        XCTAssertEqual(text, "I met Nita and Nika")
        XCTAssertEqual(base.textSoFar, "I met Nida and Nica", "The ASR result itself is not mutated")
        session.cancel()
        XCTAssertTrue(base.cancelled)
    }

    // Moved here from the fixture class below, where XCTest never ran them.
    func testOneLetterShortcutApplies() {
        let corrector = Autocorrector(words: WordListTests.list)
        corrector.setSystemLexicon(names: [], replacements: ["u": "you", "omw": "On my way!"])
        XCTAssertEqual(corrector.evaluate("u").replacement, "you")
        XCTAssertEqual(corrector.evaluate("omw").replacement, "On my way!")
    }
    func testShortcutOnAOneLetterWordIsOfferedNotApplied() {
        let corrector = Autocorrector(words: WordListTests.list)
        corrector.setSystemLexicon(names: [], replacements: ["a": "alpha", "i": "india"])
        XCTAssertNil(corrector.evaluate("a").replacement)
        XCTAssertNil(corrector.evaluate("i").replacement)
        XCTAssertTrue(corrector.evaluate("a").suggestions.contains(Suggestion(text: "alpha", kind: .correction, autoApplies: false)))
    }
}

private final class LexiconFixtureSession: RecognitionSession {
    var fed = 0
    var cancelled = false
    var audioSeconds: Double { Double(fed) / 16_000 }
    var textSoFar: String { "I met Nida and Nica" }
    var failure: Error? { nil }
    var availableAudioSamples: Int { 123 }
    func feed(_ samples: [Float]) { fed += samples.count }
    func finish() async throws -> String { textSoFar }
    func cancel() { cancelled = true }
}
