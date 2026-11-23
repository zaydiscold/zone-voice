// by zayd/cold @ zayd.wtf

import XCTest
import ZoneCore
@testable import Zone

@MainActor
final class SystemLexiconVoiceTests: XCTestCase {
    func testAppLoadsImportedTermsForVoiceHintsAndFormattingWithoutPollutingMyWords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "lexicon-voice-" + UUID().uuidString
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        let lexicon = SystemLexiconStore(fileURL: root.appendingPathComponent("system.json"))
        let own = PersonalVocabulary(fileURL: root.appendingPathComponent("words.json"))
        let defaults = UserDefaults(suiteName: suite)!
        let store = UserDefaultsSharedStore(suiteName: suite)
        let settings = AppSettings(defaults: defaults, store: store, vocabulary: own, systemLexicon: lexicon)
        let engine = LexiconVoiceEngine()
        let dictation = DictationCoordinator(settings: settings, store: store, engine: engine, reviews: .forTests)
        defer { dictation.endSession(reason: .user) }
        try lexicon.save(SystemLexiconSnapshot(entries: [(input: "nita", text: "Nita")]))
        dictation.refreshSpeechVocabulary()
        XCTAssertTrue(engine.words.contains("Nita"))
        XCTAssertEqual(dictation.textStyle.apply("I met Nida", personalWords: dictation.personalWords,
            systemWords: dictation.systemWords), "I met Nita")
        XCTAssertEqual(settings.refreshPersonalWords(), [])
        XCTAssertEqual(try own.words(), [])
        await dictation.prepareModelAndWait()
        let session = try dictation.makeMeetingUtterance()
        let recognized = try await session.finish()
        XCTAssertEqual(recognized, "I met Nita", "Meeting ASR uses the same shared final-transcript normalization")
        try lexicon.save(SystemLexiconSnapshot(entries: [(input: "nika", text: "Nika")]))
        dictation.refreshSpeechVocabulary()
        XCTAssertTrue(engine.words.contains("Nika"))
        XCTAssertFalse(engine.words.contains("Nita"), "A refreshed lexicon must replace old hints while the app stays open")
        XCTAssertEqual(dictation.textStyle.apply("I met Nica", personalWords: dictation.personalWords,
            systemWords: dictation.systemWords), "I met Nika")
    }

    func testMissingOrUnreadableSystemCacheDoesNotDiscardExplicitWords() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "lexicon-failure-" + UUID().uuidString
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        let own = PersonalVocabulary(fileURL: root.appendingPathComponent("words.json"))
        try own.add(["Dahlsson"])
        let lexicon = SystemLexiconStore(fileURL: root.appendingPathComponent("system.json"))
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!,
            store: UserDefaultsSharedStore(suiteName: suite), vocabulary: own, systemLexicon: lexicon)
        XCTAssertTrue(settings.speechHintWords().contains("Dahlsson"))
        try Data("broken cache".utf8).write(to: lexicon.fileURL)
        XCTAssertTrue(settings.speechHintWords().contains("Dahlsson"))
        XCTAssertEqual(settings.systemSpeechWords, [])
        XCTAssertEqual(try own.words(), ["Dahlsson"])
    }
}

private final class LexiconVoiceEngine: SpeechEngine {
    let kind = EngineKind.fluidMiniCPU
    var words: [String] = []
    var isReady = false
    func assetsPresent() -> Bool { false }
    func bytesOnDisk() -> Int64 { 0 }
    func removeAssets() throws {}
    func downloadAssets(progress: @escaping @Sendable (Double, String) -> Void) async throws {}
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws { isReady = true }
    func setPersonalWords(_ words: [String]) { self.words = words }
    func setContextHints(_ text: String) {}
    func beginUtterance() throws -> UtteranceSession { LexiconVoiceFixture() }
    func unload() {}
}

private final class LexiconVoiceFixture: UtteranceSession {
    var audioSeconds: Double { 1 }
    var textSoFar: String { "I met Nida" }
    var failure: Error? { nil }
    var availableAudioSamples: Int { 16_000 }
    func feed(_ samples: [Float]) {}
    func finish() async throws -> String { textSoFar }
    func cancel() {}
}
