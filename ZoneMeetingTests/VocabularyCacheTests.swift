// by zayd/cold @ zayd.wtf

import XCTest
import ZoneCore
@testable import Zone

/// Vocabulary at dictation start comes from memory, and is reread off the main thread.
@MainActor
final class VocabularyCacheTests: XCTestCase {
    private var root: URL!
    private var suite: String!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "vocabulary-cache-" + UUID().uuidString
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    private func makeSettings() -> (AppSettings, PersonalVocabulary, SystemLexiconStore) {
        let vocabulary = PersonalVocabulary(fileURL: root.appendingPathComponent("words.json"))
        let lexicon = SystemLexiconStore(fileURL: root.appendingPathComponent("system.json"))
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!, store: UserDefaultsSharedStore(suiteName: suite),
                                   vocabulary: vocabulary, systemLexicon: lexicon)
        return (settings, vocabulary, lexicon)
    }

    func testCacheReadsNothingUntilRefreshedAndThenHasBothSources() async throws {
        let (settings, vocabulary, lexicon) = makeSettings()
        // Written behind the app's back, the way the keyboard learns a correction.
        try vocabulary.add(["Dahlsson"])
        try lexicon.save(SystemLexiconSnapshot(entries: [(input: "nita", text: "Nita")]))
        XCTAssertFalse(settings.cachedSpeechHintWords().contains("Dahlsson"))
        XCTAssertFalse(settings.cachedSpeechHintWords().contains("Nita"))
        await settings.refreshVocabularyCache()
        XCTAssertTrue(settings.cachedSpeechHintWords().contains("Dahlsson"))
        XCTAssertTrue(settings.cachedSpeechHintWords().contains("Nita"))
        XCTAssertEqual(settings.personalWords, ["Dahlsson"])
        XCTAssertEqual(settings.cachedSystemSpeechWords, ["Nita"])
    }

    func testABackgroundReadNeverOverwritesANewerSave() async throws {
        let (settings, vocabulary, _) = makeSettings()
        try vocabulary.add(["Old"])
        let refresh = Task { await settings.refreshVocabularyCache() }
        try settings.savePersonalWords(["Newer"], replacing: ["Old"])
        await refresh.value
        XCTAssertEqual(settings.personalWords, ["Newer"])
        await settings.refreshVocabularyCache()
        XCTAssertEqual(settings.personalWords, ["Newer"])
    }

    func testDictationStartUsesTheCacheAndRefreshesItForTheNextOne() async throws {
        let (settings, vocabulary, _) = makeSettings()
        settings.soundsEnabled = false
        settings.startsSessionOnOpen = false
        let store = UserDefaultsSharedStore(suiteName: suite)
        let engine = HintRecordingEngine()
        let dictation = DictationCoordinator(settings: settings, store: store, engine: engine, reviews: .forTests,
                                             requestSessionPermission: { true })
        defer { dictation.endSession(reason: .user) }
        await dictation.vocabularyRefreshed() // The read every launch starts.
        try vocabulary.add(["Learned"])
        await dictation.prepareModelAndWait()
        await dictation.startAppDictation(contextBefore: nil)
        guard case .recording = dictation.activity else { return XCTFail("Did not record: \(dictation.activity)") }
        XCTAssertFalse(engine.words.contains("Learned"), "Start read the file instead of the cache")
        await dictation.vocabularyRefreshed()
        XCTAssertTrue(settings.cachedSpeechHintWords().contains("Learned"), "The start did not refresh the cache")
        dictation.cancelDictation(playsSound: false)
    }
}

private final class HintRecordingEngine: SpeechEngine {
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
    func beginUtterance() throws -> UtteranceSession { SilentUtterance() }
    func unload() {}
}

private final class SilentUtterance: UtteranceSession {
    var audioSeconds: Double { 0 }
    var textSoFar: String { "" }
    var failure: Error? { nil }
    var availableAudioSamples: Int { 0 }
    func feed(_ samples: [Float]) {}
    func finish() async throws -> String { "" }
    func cancel() {}
}
