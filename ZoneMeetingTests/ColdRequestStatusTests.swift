// by zayd/cold @ zayd.wtf

import XCTest
import ZoneCore
@testable import Zone

/// What a new app process does to the status it finds in the shared store.
@MainActor
final class ColdRequestStatusTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func launch(over status: DictationStatus) -> DictationStatus? {
        let suite = "cold-status-test-" + UUID().uuidString
        suites.append(suite)
        let store = UserDefaultsSharedStore(suiteName: suite)
        store.status = status
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!, store: store, vocabulary: nil, systemLexicon: nil)
        let coordinator = DictationCoordinator(settings: settings, store: store, engine: ColdStatusEngine(), reviews: .forTests)
        withExtendedLifetime(coordinator) {}
        return store.status
    }

    /// The keyboard writes `.requested` and opens Zone; that launch serves the request.
    func testARequestWrittenJustBeforeLaunchIsNotCalledInterrupted() {
        let status = DictationStatus(requestID: UUID(), generation: 1, phase: .requested, updatedAt: Date(), message: nil)
        XCTAssertEqual(launch(over: status)?.phase, .requested)
    }

    func testAnOldRequestIsInterrupted() {
        let status = DictationStatus(requestID: UUID(), generation: 1, phase: .requested,
                                     updatedAt: Date().addingTimeInterval(-60), message: nil)
        XCTAssertEqual(launch(over: status)?.phase, .interrupted)
    }

    /// A recording has no process behind it after a relaunch, however recent.
    func testARecordingLeftByADeadProcessIsInterrupted() {
        let status = DictationStatus(requestID: UUID(), generation: 1, phase: .recording, updatedAt: Date(), message: nil)
        XCTAssertEqual(launch(over: status)?.phase, .interrupted)
    }
}

private final class ColdStatusEngine: SpeechEngine {
    let kind: EngineKind = .fluidMiniCPU
    var isReady = true
    func assetsPresent() -> Bool { true }
    func bytesOnDisk() -> Int64 { 0 }
    func removeAssets() throws {}
    func downloadAssets(progress: @escaping @Sendable (Double, String) -> Void) async throws {}
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {}
    func setContextHints(_ text: String) {}
    func beginUtterance() throws -> UtteranceSession { throw SpeechEngineError.notReady }
    func unload() {}
}
