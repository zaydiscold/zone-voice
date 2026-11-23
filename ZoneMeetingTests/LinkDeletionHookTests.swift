// by zayd/cold @ zayd.wtf

import XCTest
import ZoneCore
@testable import Zone

/// Zone Link tells a paired computer about a meeting the person deleted, and about a meeting a
/// merge absorbed. It learns of both through `MeetingCoordinator.onDelete`.
@MainActor
final class LinkDeletionHookTests: XCTestCase {
    private var roots: [URL] = []
    private var suites: [String] = []

    override func tearDown() {
        for url in roots { try? FileManager.default.removeItem(at: url) }
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        roots = []; suites = []
        super.tearDown()
    }

    private func makeCoordinator() -> (MeetingCoordinator, MeetingStore) {
        let suite = "link-hook-test-" + UUID().uuidString
        suites.append(suite)
        let shared = UserDefaultsSharedStore(suiteName: suite)
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!, store: shared)
        let dictation = DictationCoordinator(settings: settings, store: shared, engine: IdleSpeechEngine())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root)
        let store = MeetingStore(directory: root)
        let coordinator = MeetingCoordinator(dictation: dictation, store: store, recover: { _ in },
                                             requestPermission: { false }, startCapture: { _ in }, stopCapture: {})
        return (coordinator, store)
    }

    /// A finished meeting with one minute of silence and a short transcript.
    private func finishedMeeting(in store: MeetingStore, at date: Date) throws -> Meeting {
        let (meeting, _) = try store.beginRecording(title: "Meeting", now: date)
        try Data(count: 16_000 * 2 * 60).write(to: store.audioURLs(meeting)[0])
        _ = try store.finishRecording(meeting.id, now: date)
        return try store.update(meeting.id, now: date) { meeting in
            meeting.segments = [MeetingSegment(start: 0, end: 5, speaker: nil, text: "Hello there.")]
            meeting.transcribedThrough = meeting.duration
            meeting.status = .done
        }
    }

    func testDeletingAMeetingReportsIt() throws {
        let (coordinator, store) = makeCoordinator()
        let meeting = try finishedMeeting(in: store, at: Date(timeIntervalSince1970: 1_794_000_000))
        var deleted: [UUID] = []
        coordinator.onDelete = { deleted.append($0) }

        coordinator.delete(meeting.id)

        XCTAssertEqual(deleted, [meeting.id])
        XCTAssertTrue(store.all().isEmpty)
    }

    func testMergingReportsTheMeetingThatWasAbsorbed() throws {
        let (coordinator, store) = makeCoordinator()
        let earlier = try finishedMeeting(in: store, at: Date(timeIntervalSince1970: 1_794_000_000))
        let later = try finishedMeeting(in: store, at: Date(timeIntervalSince1970: 1_794_003_600))
        var deleted: [UUID] = []
        coordinator.onDelete = { deleted.append($0) }

        // Whichever way round it is asked, the later meeting is the one that goes.
        let merged = coordinator.merge(later.id, with: earlier.id)

        XCTAssertEqual(merged, earlier.id)
        XCTAssertEqual(deleted, [later.id])
        XCTAssertEqual(store.all().map(\.id), [earlier.id])
    }

    func testFinishedMeetingsAnnounceChangesAndRecordingsDoNot() throws {
        let (_, store) = makeCoordinator()
        let quiet = expectation(forNotification: MeetingStore.finishedMeetingDidChange, object: nil)
        quiet.isInverted = true
        let (recording, _) = try store.beginRecording(title: "Still recording")
        _ = try store.update(recording.id) { $0.progress = 0.5 }
        wait(for: [quiet], timeout: 0.5)

        let announced = expectation(forNotification: MeetingStore.finishedMeetingDidChange, object: nil)
        _ = try store.update(recording.id) { meeting in
            meeting.segments = [MeetingSegment(start: 0, end: 1, speaker: nil, text: "Done.")]
            meeting.status = .done
        }
        wait(for: [announced], timeout: 2)
    }
}

/// These tests never dictate; the coordinator only needs an engine to exist.
private final class IdleSpeechEngine: SpeechEngine {
    let kind: EngineKind = .fluidMiniCPU
    var isReady = true
    func assetsPresent() -> Bool { true }
    func bytesOnDisk() -> Int64 { 0 }
    func removeAssets() throws {}
    func downloadAssets(progress: @escaping @Sendable (Double, String) -> Void) async throws {}
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {}
    func setContextHints(_ text: String) {}
    func beginUtterance() throws -> UtteranceSession { IdleUtterance() }
    func unload() {}
}

private final class IdleUtterance: UtteranceSession {
    var audioSeconds: Double = 0
    var textSoFar = ""
    var failure: Error? { nil }
    var availableAudioSamples: Int { 0 }
    func feed(_ samples: [Float]) {}
    func finish() async throws -> String { "" }
    func cancel() {}
}
