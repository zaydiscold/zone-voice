// by zayd/cold @ zayd.wtf

import XCTest
import ZoneCore
@testable import Zone

@MainActor
final class MeetingCoordinatorTests: XCTestCase {
    private var roots: [URL] = []
    private var suites: [String] = []
    private let speakerLabelKey = "zone.meetings.labelSpeakers"
    private var savedSpeakerLabelPreference: Any?

    override func setUp() {
        super.setUp()
        savedSpeakerLabelPreference = UserDefaults.standard.object(forKey: speakerLabelKey)
    }

    override func tearDown() {
        for url in roots { try? FileManager.default.removeItem(at: url) }
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        roots = []; suites = []
        // MeetingCoordinator uses standard defaults, independently of the dictation test suite.
        // Restore absence as absence so the app retains its default-on behavior.
        if let savedSpeakerLabelPreference {
            UserDefaults.standard.set(savedSpeakerLabelPreference, forKey: speakerLabelKey)
        } else {
            UserDefaults.standard.removeObject(forKey: speakerLabelKey)
        }
        savedSpeakerLabelPreference = nil
        super.tearDown()
    }

    private func makeDictation(engine: SpeechEngine = TestSpeechEngine()) -> DictationCoordinator {
        let suite = "meeting-test-" + UUID().uuidString
        suites.append(suite)
        let store = UserDefaultsSharedStore(suiteName: suite)
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!, store: store)
        // The rating prompt's record stays in the test suite, never the App Group.
        let reviews = ReviewPrompter(store: ReviewPromptStore(suiteName: suite), appVersion: "test")
        return DictationCoordinator(settings: settings, store: store, engine: engine, reviews: reviews)
    }

    private func makeStore() -> MeetingStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root)
        return MeetingStore(directory: root)
    }

    func testStopDuringPermissionCancelsStartWithoutCreatingAudio() async {
        let entered = expectation(description: "permission requested")
        let gate = PermissionGate()
        let store = makeStore()
        var captureStarts = 0
        let coordinator = MeetingCoordinator(dictation: makeDictation(), store: store, recover: { _ in }, requestPermission: {
            entered.fulfill()
            await gate.wait()
            return true
        }, startCapture: { _ in captureStarts += 1 }, stopCapture: {})
        coordinator.labelsSpeakers = false
        let start = Task { await coordinator.startRecording() }
        await fulfillment(of: [entered], timeout: 3)
        for _ in 0..<8 { await coordinator.startRecording() }
        await coordinator.stopRecording()
        await gate.open()
        await start.value
        XCTAssertFalse(coordinator.isRecording)
        XCTAssertFalse(coordinator.isStartingRecording)
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertEqual(captureStarts, 0)
        if coordinator.isRecording { await coordinator.discardRecording() }
    }

    func testRecoveryFinishesBeforePermissionAndCancelledStartupDoesNotEscape() async {
        let entered = expectation(description: "recovery entered")
        let gate = PermissionGate()
        var permissionRequests = 0
        let store = makeStore()
        let coordinator = MeetingCoordinator(dictation: makeDictation(), store: store, recover: { _ in
            entered.fulfill()
            await gate.wait()
        }, requestPermission: { permissionRequests += 1; return false })
        await fulfillment(of: [entered], timeout: 3)
        let start = Task { await coordinator.startRecording() }
        // Force the start method through its first suspension while recovery is still held.
        while !coordinator.isStartingRecording { await Task.yield() }
        XCTAssertEqual(permissionRequests, 0)
        await coordinator.stopRecording()
        await gate.open()
        await start.value
        XCTAssertEqual(permissionRequests, 0)
        XCTAssertTrue(store.all().isEmpty)
    }

    func testDiscardDuringPermissionCancelsStart() async {
        let entered = expectation(description: "permission requested")
        let gate = PermissionGate()
        let store = makeStore()
        var captureStarts = 0
        let coordinator = MeetingCoordinator(dictation: makeDictation(), store: store, recover: { _ in }, requestPermission: {
            entered.fulfill(); await gate.wait(); return true
        }, startCapture: { _ in captureStarts += 1 }, stopCapture: {})
        coordinator.labelsSpeakers = false
        let start = Task { await coordinator.startRecording() }
        await fulfillment(of: [entered], timeout: 3)
        await coordinator.discardRecording()
        await gate.open()
        await start.value
        XCTAssertFalse(coordinator.isRecording)
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertEqual(captureStarts, 0)
        if coordinator.isRecording { await coordinator.discardRecording() }
    }

    func testSpammedStopsSaveExactlyOnceAndOldSinkCannotWriteToNextRecording() async throws {
        let store = makeStore()
        var sink: (([Float]) -> Void)?
        var starts = 0, stops = 0
        let coordinator = MeetingCoordinator(dictation: makeDictation(), store: store, recover: { _ in },
            requestPermission: { true }, startCapture: { sink = $0; starts += 1 }, stopCapture: { stops += 1 })
        coordinator.labelsSpeakers = false
        await coordinator.startRecording()
        let oldSink = try XCTUnwrap(sink)
        oldSink([Float](repeating: 0.2, count: 32_000))
        let stopTasks = (0..<8).map { _ in Task { await coordinator.stopRecording() } }
        for task in stopTasks { await task.value }
        await coordinator.drainProcessing()
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(store.all().first?.duration, 2)
        await coordinator.startRecording()
        oldSink([Float](repeating: 0.8, count: 32_000))
        sink?([Float](repeating: 0.4, count: 16_000))
        await coordinator.stopRecording()
        await coordinator.drainProcessing()
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(stops, 2)
        XCTAssertEqual(store.all().map(\.duration).sorted(), [1, 2])
    }

    func testTwoMeetingsSpammedTranscribeProduceExactlyOneTranscriptEach() async throws {
        let engine = TestSpeechEngine()
        let dictation = makeDictation(engine: engine)
        let store = makeStore()
        let coordinator = MeetingCoordinator(dictation: dictation, store: store, recover: { _ in }, requestPermission: { false })
        coordinator.labelsSpeakers = false
        await coordinator.startRecording() // joins launch recovery; permission refused, no capture
        try await waitForModel(dictation)
        let a = try await recorded(store), b = try await recorded(store)
        for _ in 0..<8 { coordinator.enqueue(a); coordinator.enqueue(b) }
        XCTAssertEqual(coordinator.transcribingID, a)
        XCTAssertEqual(coordinator.queued, [b])
        await coordinator.drainProcessing()
        for id in [a, b] {
            let meeting = try store.meeting(id)
            XCTAssertEqual(meeting.status, .done)
            XCTAssertEqual(meeting.segments.count, 1)
            XCTAssertEqual(meeting.segments.first?.text, "Test speech.")
            XCTAssertEqual(meeting.transcribedThrough, 2)
        }
        XCTAssertEqual(engine.utterances, 2)
    }

    func testWriterOverloadAutomaticallyStopsAndKeepsTheRecordingNoticeAfterTranscription() async throws {
        let store = makeStore()
        let dictation = makeDictation()
        var sink: (([Float]) -> Void)?
        let coordinator = MeetingCoordinator(dictation: dictation, store: store, recover: { _ in },
            requestPermission: { true }, startCapture: { sink = $0 }, stopCapture: {})
        coordinator.labelsSpeakers = false
        try await waitForModel(dictation)
        await coordinator.startRecording()
        sink?([Float](repeating: 0.2, count: 16_000))
        // Larger than the writer's whole 30-second queue: deterministic rejection.
        sink?([Float](repeating: 0.3, count: 31 * 16_000))
        for _ in 0..<200 {
            if !coordinator.isRecording { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(coordinator.isRecording, "overload must stop capture, not just show a warning")
        // stopRecording clears capture before the asynchronous flush and enqueue finish.
        for _ in 0..<200 {
            if !coordinator.isFinishingRecording { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await coordinator.drainProcessing()
        let meeting = try XCTUnwrap(store.all().first)
        XCTAssertEqual(meeting.status, .done)
        XCTAssertEqual(meeting.duration, 1)
        XCTAssertTrue(meeting.recordingNotice?.contains("Some audio was skipped") == true)
        XCTAssertTrue(MeetingExport.text(meeting).contains("Some audio was skipped"))
    }

    func testPauseBeforeWorkerStartsLeavesAudioAndNoTranscriptThenCanResume() async throws {
        let engine = TestSpeechEngine()
        let dictation = makeDictation(engine: engine)
        let store = makeStore()
        let coordinator = MeetingCoordinator(dictation: dictation, store: store, recover: { _ in }, requestPermission: { false })
        coordinator.labelsSpeakers = false
        await coordinator.startRecording()
        try await waitForModel(dictation)
        let id = try await recorded(store)
        coordinator.enqueue(id)
        coordinator.cancelTranscription(id)
        await coordinator.drainProcessing()
        XCTAssertEqual(engine.utterances, 0)
        XCTAssertEqual(try store.meeting(id).status, .recorded)
        XCTAssertEqual(try store.audio(id).duration, 2)
        coordinator.enqueue(id)
        await coordinator.drainProcessing()
        XCTAssertEqual(try store.meeting(id).status, .done)
        XCTAssertEqual(engine.utterances, 1)
    }

    private func recorded(_ store: MeetingStore) async throws -> UUID {
        let (meeting, writer) = try store.beginRecording()
        writer.append([Float](repeating: 0.25, count: 32_000))
        try await writer.finish()
        try store.finishRecording(meeting.id)
        return meeting.id
    }

    private func waitForModel(_ dictation: DictationCoordinator) async throws {
        for _ in 0..<200 {
            if dictation.modelIsReady { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("test model did not become ready")
    }
}

private actor PermissionGate {
    private var openState = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if openState { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { openState = true; for waiter in waiters { waiter.resume() }; waiters.removeAll() }
}

private final class TestSpeechEngine: SpeechEngine {
    let kind: EngineKind = .fluidMiniCPU
    var isReady = true
    var utterances = 0
    func assetsPresent() -> Bool { true }
    func bytesOnDisk() -> Int64 { 0 }
    func removeAssets() throws {}
    func downloadAssets(progress: @escaping @Sendable (Double, String) -> Void) async throws {}
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {}
    func setContextHints(_ text: String) {}
    func beginUtterance() throws -> UtteranceSession { utterances += 1; return TestUtterance() }
    func unload() {}
}

private final class TestUtterance: UtteranceSession {
    var audioSeconds: Double = 0
    var textSoFar = ""
    var failure: Error? { nil }
    var availableAudioSamples: Int { 48 * 16_000 }
    func feed(_ samples: [Float]) { audioSeconds += Double(samples.count) / 16_000 }
    func finish() async throws -> String { try Task.checkCancellation(); return "Test speech." }
    func cancel() {}
}
