// by zayd/cold @ zayd.wtf

import XCTest
import ZoneCore
@testable import Zone

/// Voice setup inside the app: the step flow, the refusals that keep it and meetings apart, and
/// marking the person in earlier meetings. The recording itself runs in the simulator check
/// (`-zoneVoiceSetupAutorun`, next-batch/meeting-voices.md).
@MainActor
final class VoiceSetupFlowTests: XCTestCase {
    private var roots: [URL] = []
    private var suites: [String] = []
    /// The meeting switches live in standard defaults; each test leaves them as it found them.
    private let switches = ["zone.meetings.labelSpeakers", "zone.meetings.recognizeVoices"]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in switches { saved[key] = UserDefaults.standard.object(forKey: key) }
    }

    override func tearDown() {
        for url in roots { try? FileManager.default.removeItem(at: url) }
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        for key in switches {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        roots = []; suites = []; saved = [:]
        super.tearDown()
    }

    private func makeDictation() -> DictationCoordinator {
        let suite = "voice-setup-test-" + UUID().uuidString
        suites.append(suite)
        let store = UserDefaultsSharedStore(suiteName: suite)
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!, store: store)
        let reviews = ReviewPrompter(store: ReviewPromptStore(suiteName: suite), appVersion: "test")
        return DictationCoordinator(settings: settings, store: store, engine: SetupTestEngine(), reviews: reviews)
    }

    private func directory() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root)
        return root
    }

    private func makeMeetings(_ dictation: DictationCoordinator, store: MeetingStore,
                              startCapture: (@MainActor (@escaping ([Float]) -> Void) async throws -> Void)? = nil) -> MeetingCoordinator {
        MeetingCoordinator(dictation: dictation, store: store, recover: { _ in }, requestPermission: { true },
                           startCapture: startCapture ?? { _ in }, stopCapture: {})
    }

    /// A finished meeting with `speakers`, each talking for 30 s.
    private func finishedMeeting(_ store: MeetingStore, _ speakers: [MeetingSpeaker]) async throws -> UUID {
        let (started, writer) = try store.beginRecording(now: Date(timeIntervalSince1970: 1_800_000_000))
        _ = writer.append([Float](repeating: 0.1, count: 16_000))
        try await writer.finish()
        _ = try store.finishRecording(started.id)
        _ = try store.update(started.id) {
            $0.status = .done
            $0.speakers = speakers
            $0.turns = speakers.enumerated().map { MeetingTurn(start: Double($0.offset) * 30, end: Double($0.offset + 1) * 30, speaker: $0.element.id) }
        }
        return started.id
    }

    // MARK: Steps

    func testStepsMoveOnSkipTheSkippedAndEndInReview() async {
        let dictation = makeDictation()
        let session = VoiceSetupSession(dictation: dictation, meetings: makeMeetings(dictation, store: MeetingStore(directory: directory())),
                                        store: VoiceProfileStore(directory: directory()))
        XCTAssertEqual(session.stage, .intro)
        session.begin()
        XCTAssertEqual(session.stage, .step(.read))
        session.talkInstead()
        XCTAssertEqual(session.stage, .step(.talk))
        XCTAssertTrue(session.skipped.contains(.read))
        session.skip(.talk)
        await waitFor { session.stage == .step(.whisper) }
        session.skip(.whisper)
        await waitFor { session.stage == .step(.far) }
        session.skip(.far)
        await waitFor { session.stage == .review }
        XCTAssertFalse(session.canSave, "nothing recorded: nothing to save")
        // Redoing one part from the review comes back to the review, not through the skipped ones.
        session.redo(.read)
        XCTAssertEqual(session.stage, .step(.read))
        session.advance(from: .read)
        XCTAssertEqual(session.stage, .review)
    }

    func testDoneNeedsTheMinimumAndSaveNeedsTheNormalVoice() async {
        let dictation = makeDictation()
        let profiles = VoiceProfileStore(directory: directory())
        let session = VoiceSetupSession(dictation: dictation, meetings: makeMeetings(dictation, store: MeetingStore(directory: directory())),
                                        store: profiles)
        session.begin()
        session.done(.read)
        XCTAssertNotNil(session.message, "Done with no speech asks for more")
        XCTAssertFalse(session.finished.contains(.read))
        await session.save()
        XCTAssertNil(profiles.load(), "nothing is saved without enough of the normal voice")
    }

    // MARK: Microphone

    func testVoiceSetupWaitsForAMeetingToStop() async throws {
        let dictation = makeDictation()
        let meetings = makeMeetings(dictation, store: MeetingStore(directory: directory()))
        meetings.labelsSpeakers = false
        XCTAssertNil(dictation.voiceSetupRefusal)
        await meetings.startRecording()
        XCTAssertTrue(meetings.isRecording)
        XCTAssertEqual(dictation.voiceSetupRefusal, "Stop the meeting to set up your voice.")
        await meetings.stopRecording()
        XCTAssertNil(dictation.voiceSetupRefusal)
    }

    func testRefusalsNameVoiceSetup() {
        XCTAssertEqual(DictationCoordinator.ClipPurpose.voiceSetup.refusal, RecordingRefusal.voiceSetup)
        XCTAssertEqual(DictationCoordinator.ClipPurpose.test.refusal, RecordingRefusal.clip)
        XCTAssertFalse(makeDictation().voiceSetupCaptureActive)
    }

    // MARK: Earlier meetings

    func testFindsAndMarksMeOnlyWhereNobodyChangedTheMeeting() async throws {
        let store = MeetingStore(directory: directory())
        let me: [Float] = [0, 1, 0, 0], jonathan: [Float] = [1, 0, 0, 0]
        let plain = try await finishedMeeting(store, [MeetingSpeaker(id: "S1", voice: jonathan), MeetingSpeaker(id: "S2", voice: me)])
        let changed = try await finishedMeeting(store, [MeetingSpeaker(id: "S1", voice: me)])
        let dictation = makeDictation()
        let meetings = makeMeetings(dictation, store: store)
        meetings.labelsSpeakers = true
        meetings.recognizesVoices = true
        let profile = VoiceProfile(model: "m", prints: [VoiceProfile.Print(part: .read, voice: me, seconds: 45, recordedAt: Date())],
                                   createdAt: Date())
        let found = await meetings.findMe(profile: profile)
        XCTAssertEqual(Set(found.map(\.meeting)), [plain, changed])
        // Meanwhile the person named the speaker in one of them: that one is left alone.
        try store.renameSpeaker(changed, speaker: "S1", to: "Kim")
        meetings.markRecognizedMe(found)
        let marked = try store.meeting(plain)
        XCTAssertEqual(marked.speakers[1].isMe, true)
        XCTAssertEqual(marked.speakers[1].recognized, true, "a dot until the person confirms")
        XCTAssertFalse(marked.speakers[0].isMe)
        let kept = try store.meeting(changed)
        XCTAssertFalse(kept.speakers[0].isMe)
        XCTAssertEqual(kept.speakers[0].name, "Kim")
    }

    func testFindsNothingWithRecognitionOff() async throws {
        let store = MeetingStore(directory: directory())
        _ = try await finishedMeeting(store, [MeetingSpeaker(id: "S1", voice: [0, 1, 0, 0])])
        let meetings = makeMeetings(makeDictation(), store: store)
        meetings.labelsSpeakers = true
        meetings.recognizesVoices = false
        let profile = VoiceProfile(model: "m", prints: [VoiceProfile.Print(part: .read, voice: [0, 1, 0, 0], seconds: 45, recordedAt: Date())],
                                   createdAt: Date())
        let found = await meetings.findMe(profile: profile)
        XCTAssertEqual(found, [])
    }

    private func waitFor(_ condition: @escaping @MainActor () -> Bool, timeout: TimeInterval = 3) async {
        let began = Date()
        while !condition(), Date().timeIntervalSince(began) < timeout { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition())
    }
}

/// No speech model is needed here; voice setup never transcribes.
private final class SetupTestEngine: SpeechEngine {
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
