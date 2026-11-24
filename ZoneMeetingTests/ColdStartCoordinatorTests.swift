// by zayd/cold @ zayd.wtf

import XCTest
import ZoneCore
@testable import Zone

/// The keyboard's cold path against the production coordinator and microphone: the tap writes
/// its request and a `requested` status, then iOS launches Zone, which gets the `zone://` URL.
/// From November 5 to 10 the launch itself marked that brand-new tap interrupted in 45 of 50
/// cold taps, and the keyboard said so a moment after the tap.
@MainActor
final class ColdStartCoordinatorTests: XCTestCase {
    private var coordinator: DictationCoordinator?
    private var suites: [String] = []

    override func tearDownWithError() throws {
        coordinator?.endSession(reason: .user)
        coordinator = nil
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }

    /// One App Group per launch, so a coordinator left from an earlier launch cannot answer.
    private func newStore() -> StatusLog {
        let suite = "cold-start-" + UUID().uuidString
        suites.append(suite)
        return StatusLog(suite: suite)
    }

    /// The keyboard's side of a tap, as `MicController.tapMic` writes it. Its `requestChanged` ping
    /// goes out before iOS has started Zone, so no app process hears it; it is left out here.
    private func keyboardTaps(_ store: SharedStore, generation: Int = 4) -> DictationRequest {
        let request = DictationRequest(id: UUID(), generation: generation, createdAt: Date(),
                                       inputSession: "field", contextBefore: "Meet me at")
        store.request = request
        store.status = DictationStatus(requestID: request.id, generation: generation, phase: .requested,
                                       updatedAt: Date(), message: nil)
        return request
    }

    private func launch(_ store: StatusLog, engine: ColdStartEngine) -> DictationCoordinator {
        let settings = AppSettings(defaults: UserDefaults(suiteName: store.suite)!, store: store)
        settings.soundsEnabled = false
        settings.startsSessionOnOpen = false
        let launched = DictationCoordinator(settings: settings, store: store, engine: engine, requestSessionPermission: { true })
        coordinator = launched
        return launched
    }

    private func waitForRecording(_ coordinator: DictationCoordinator, seconds: Double = 5) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if case .recording = coordinator.activity { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testAppleFallbackNeedsAnUnlockedForegroundAndAConfiguredKeyboard() {
        for flags in 0..<32 {
            let allowed = KeyboardSpeechAssets.shouldFetch(setupDone: flags & 1 != 0, enabled: flags & 2 != 0,
                fullAccess: flags & 4 != 0, active: flags & 8 != 0, unlocked: flags & 16 != 0)
            XCTAssertEqual(allowed, flags == 31)
        }
    }

    func testMissingModelRequiresATapInZone() async {
        let store = newStore()
        let engine = ColdStartEngine()
        engine.hasAssets = false
        let launched = launch(store, engine: engine)
        launched.handle(url: ZoneContract.dictateURL(requestID: UUID()))
        XCTAssertTrue(launched.showsDictationScreen)
        XCTAssertNotNil(launched.lastError)
        XCTAssertFalse(launched.isArmed)
        let request = keyboardTaps(store)
        launched.handle(url: ZoneContract.dictateURL(requestID: request.id))
        XCTAssertTrue(launched.showsDictationScreen)
        XCTAssertFalse(launched.isPreparingModel)
        XCTAssertEqual(launched.modelState, .missing)
        XCTAssertTrue(launched.needsFreshKeyboardTap)
        launched.handle(url: ZoneContract.Destination.settings.url)
        XCTAssertEqual(launched.keyboardDestination, .settings)
        XCTAssertFalse(launched.showsDictationScreen)
        engine.hasAssets = true
        await launched.prepareModelAndWait()
        XCTAssertTrue(launched.modelIsReady)
        XCTAssertTrue(launched.needsFreshKeyboardTap, "The download ends with the return-to-keyboard hint")
        XCTAssertEqual(engine.starts, 0, "The old request cannot turn on the mic")
    }

    func testLateModelLoadCannotRecordAfterTheRequestTimesOut() async throws {
        let store = newStore()
        let engine = ColdStartEngine()
        engine.loadTime = .seconds(2)
        let launched = launch(store, engine: engine)
        let old = DictationRequest(id: UUID(), generation: 4, createdAt: Date().addingTimeInterval(-9),
                                   inputSession: nil, contextBefore: nil)
        store.request = old
        store.status = DictationStatus(requestID: old.id, generation: 4, phase: .requested, updatedAt: Date(), message: nil)
        launched.handle(url: ZoneContract.dictateURL(requestID: old.id))
        try await Task.sleep(for: .milliseconds(1400))
        XCTAssertEqual(store.status?.phase, .failed)
        XCTAssertTrue(store.status?.message?.contains("tap the mic again") == true)
        await launched.prepareModelAndWait()
        XCTAssertEqual(engine.starts, 0)
        XCTAssertFalse(launched.isArmed)
    }

    /// Both orders the phone sees: the URL before the model is ready (the cold process) and after.
    func testLaunchServesTheTapThatOpenedItOnceAndNeverCallsItInterrupted() async throws {
        for modelReadyFirst in [false, true] {
            let store = newStore()
            let request = keyboardTaps(store)
            store.phases.removeAll()
            let engine = ColdStartEngine()
            engine.loadTime = .milliseconds(600)
            let launched = launch(store, engine: engine)
            XCTAssertEqual(store.status?.phase, .requested, "The launch must leave the tap it was opened for alone")
            if modelReadyFirst { await launched.prepareModelAndWait() }
            launched.handle(url: ZoneContract.dictateURL(requestID: request.id))
            launched.handle(url: ZoneContract.Destination.settings.url)
            XCTAssertNil(launched.keyboardDestination)
            XCTAssertTrue(launched.showsDictationScreen)
            // A late or repeated ping for the same request reaches the pending path as well.
            DarwinNotifier.post(.requestChanged)
            await waitForRecording(launched)
            guard case .recording(let id, _) = launched.activity else {
                return XCTFail("The tap did not record (model ready first: \(modelReadyFirst)): \(launched.activity)")
            }
            XCTAssertEqual(id, request.id)
            // The pending path re-reads for a second; give it longer than that to start a second time.
            try await Task.sleep(for: .milliseconds(1500))
            XCTAssertEqual(engine.starts, 1, "Served exactly once (model ready first: \(modelReadyFirst))")
            // Nothing but the recording: no interruption, and no `needsApp` from the ping path.
            XCTAssertEqual(store.phases, [.recording], "Statuses written (model ready first: \(modelReadyFirst))")
            XCTAssertEqual(store.status?.requestID, request.id)
            XCTAssertEqual(store.status?.phase, .recording)
            launched.endSession(reason: .user)
            coordinator = nil
        }
    }

    /// What the launch cleanup is for: a recording whose process died is still closed out.
    func testLaunchStillClosesOutARecordingFromADeadProcess() {
        for phase in [DictationPhase.starting, .recording, .transcribing] {
            let store = newStore()
            let request = keyboardTaps(store)
            store.status = DictationStatus(requestID: request.id, generation: request.generation, phase: phase,
                                           updatedAt: Date(), message: nil)
            _ = launch(store, engine: ColdStartEngine())
            XCTAssertEqual(store.status?.phase, .interrupted, "\(phase)")
            XCTAssertEqual(store.status?.requestID, request.id)
            coordinator?.endSession(reason: .user)
            coordinator = nil
        }
    }

    /// A tap from long ago, or one the keyboard already dropped, is not this launch's to serve.
    func testLaunchClosesOutAStaleOrDroppedTap() {
        let stale = newStore()
        let old = keyboardTaps(stale)
        stale.status = DictationStatus(requestID: old.id, generation: old.generation, phase: .requested,
                                       updatedAt: Date().addingTimeInterval(-60), message: nil)
        _ = launch(stale, engine: ColdStartEngine())
        XCTAssertEqual(stale.status?.phase, .interrupted)
        coordinator?.endSession(reason: .user)
        coordinator = nil

        let dropped = newStore()
        _ = keyboardTaps(dropped, generation: 6)
        dropped.ledger = InsertionLedger(droppedGeneration: 6)
        _ = launch(dropped, engine: ColdStartEngine())
        XCTAssertEqual(dropped.status?.phase, .interrupted)
    }
}

/// Every status written, in order, over a real store.
private final class StatusLog: SharedStore {
    let suite: String
    private let base: SharedStore
    var microphoneOwnership: MicrophoneOwnership { base.microphoneOwnership }
    var phases: [DictationPhase] = []
    init(suite: String) {
        self.suite = suite
        base = UserDefaultsSharedStore(suiteName: suite)
    }

    var status: DictationStatus? {
        get { base.status }
        set { if let newValue { phases.append(newValue.phase) }; base.status = newValue }
    }
    var request: DictationRequest? { get { base.request } set { base.request = newValue } }
    var result: DictationResult? { get { base.result } set { base.result = newValue } }
    var control: DictationControl? { get { base.control } set { base.control = newValue } }
    var session: SessionState? { get { base.session } set { base.session = newValue } }
    var ledger: InsertionLedger { get { base.ledger } set { base.ledger = newValue } }
    var keyboardPresence: KeyboardPresence? { get { base.keyboardPresence } set { base.keyboardPresence = newValue } }
    var level: Float { get { base.level } set { base.level = newValue } }
    var textStyle: TextStyle { get { base.textStyle } set { base.textStyle = newValue } }
    var textStylePickedAt: Date? { get { base.textStylePickedAt } set { base.textStylePickedAt = newValue } }
    var defaultTextStyle: TextStyle { get { base.defaultTextStyle } set { base.defaultTextStyle = newValue } }
    var keyboardPreferences: KeyboardPreferences { get { base.keyboardPreferences } set { base.keyboardPreferences = newValue } }
    var dictationsInserted: Int { get { base.dictationsInserted } set { base.dictationsInserted = newValue } }
    var keyboardMode: KeyboardMode { get { base.keyboardMode } set { base.keyboardMode = newValue } }
    var keyboardRecordingClaim: KeyboardRecordingClaim? {
        get { base.keyboardRecordingClaim }
        set { base.keyboardRecordingClaim = newValue }
    }
    var keyboardSpeechReady: Bool { get { base.keyboardSpeechReady } set { base.keyboardSpeechReady = newValue } }
    var appMicrophoneReading: MicrophoneReading? { base.appMicrophoneReading }
    var appMicrophoneGranted: Bool { get { base.appMicrophoneGranted } set { base.appMicrophoneGranted = newValue } }
}

private final class ColdStartEngine: SpeechEngine {
    let kind: EngineKind = .fluidMiniCPU
    var isReady = true
    var starts = 0
    /// A cold model load takes seconds on the phone; long enough here for a ping to land in it.
    var loadTime: Duration = .zero
    var hasAssets = true
    func assetsPresent() -> Bool { hasAssets }
    func bytesOnDisk() -> Int64 { 0 }
    func removeAssets() throws {}
    func downloadAssets(progress: @escaping @Sendable (Double, String) -> Void) async throws {}
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        try await Task.sleep(for: loadTime)
    }
    func setContextHints(_ text: String) {}
    func beginUtterance() throws -> UtteranceSession {
        starts += 1
        return ColdStartUtterance()
    }
    func unload() {}
}

private final class ColdStartUtterance: UtteranceSession {
    var textSoFar: String { "" }
    var audioSeconds: Double { 0 }
    var failure: Error? { nil }
    var availableAudioSamples: Int { 0 }
    func feed(_ samples: [Float]) {}
    func finish() async throws -> String { "" }
    func cancel() {}
}
