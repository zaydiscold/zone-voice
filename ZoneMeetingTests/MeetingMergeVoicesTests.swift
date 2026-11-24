// by zayd/cold @ zayd.wtf

import XCTest
import ZoneCore
@testable import Zone

/// Merging two recordings of the same people through the coordinator: the transcript reads at
/// once, the voices are compared behind it, and the result survives Zone closing in between.
/// The speaker model is stood in for by a closure that hands back chosen voice prints.
@MainActor
final class MeetingMergeVoicesTests: XCTestCase {
    private var roots: [URL] = []
    private var suites: [String] = []

    override func tearDown() {
        for url in roots { try? FileManager.default.removeItem(at: url) }
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        roots = []; suites = []
        super.tearDown()
    }

    private func makeDictation() -> DictationCoordinator {
        let suite = "merge-voices-test-" + UUID().uuidString
        suites.append(suite)
        let store = UserDefaultsSharedStore(suiteName: suite)
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!, store: store)
        let reviews = ReviewPrompter(store: ReviewPromptStore(suiteName: suite), appVersion: "test")
        return DictationCoordinator(settings: settings, store: store, engine: TestSpeechEngine(), reviews: reviews)
    }

    private func makeStore() -> MeetingStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root)
        return MeetingStore(directory: root)
    }

    private static func voice(_ axis: Int, lean: Float = 0) -> [Float] {
        var print = [Float](repeating: 0, count: 256)
        print[axis] = 1
        print[200] = lean
        return print
    }

    /// A finished two-person recording with no voice prints, as 1.0.4 and earlier 1.0.5 builds left them.
    private func recording(_ store: MeetingStore, at date: Date, words: [String]) async throws -> Meeting {
        let (meeting, writer) = try store.beginRecording(now: date)
        for _ in 0..<20 { writer.append([Float](repeating: 0.25, count: 16_000)) }
        try await writer.finish()
        try store.finishRecording(meeting.id, now: date)
        return try store.update(meeting.id, now: date) { meeting in
            meeting.speakers = [MeetingSpeaker(id: "S1"), MeetingSpeaker(id: "S2")]
            meeting.segments = (0..<4).map { index in
                MeetingSegment(start: Double(index) * 5, end: Double(index) * 5 + 4.5, speaker: "S\(index % 2 + 1)",
                               text: words[index % 2] + " \(index)")
            }
            meeting.transcribedThrough = 20
            meeting.progress = 1
            meeting.status = .done
        }
    }

    private func coordinator(_ store: MeetingStore, printer: @escaping MeetingCoordinator.VoicePrinter) -> MeetingCoordinator {
        MeetingCoordinator(dictation: makeDictation(), store: store, recover: { _ in }, requestPermission: { true },
                           startCapture: { _ in }, stopCapture: {}, voicePrinter: printer)
    }

    private func wait(_ what: String, until condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(15)) }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    /// Zayd and Riju, heard in the other order by the second recording's speaker model.
    private let prints: [String: [Float]] = ["S1": voice(0), "S2": voice(1), "S3": voice(1, lean: 0.3), "S4": voice(0, lean: 0.3)]

    func testMergingTwoRecordingsListensToTheVoicesAndKeepsTwoPeople() async throws {
        let store = makeStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try await recording(store, at: start, words: ["zayd", "riju"])
        let second = try await recording(store, at: start.addingTimeInterval(600), words: ["riju", "zayd"])
        try store.setMe(first.id, speaker: "S1")
        var asked: [String: [Range<Double>]] = [:]
        let gate = Gate()
        let prints = prints
        let meetings = coordinator(store) { _, spans in
            asked = spans
            await gate.wait()
            return prints.filter { spans[$0.key] != nil }
        }
        await wait("the list", until: { meetings.meetings.count == 2 })

        let id = try XCTUnwrap(meetings.merge(first.id, with: second.id))

        // At once: one meeting, its whole transcript readable, the voices still being compared.
        let now = try XCTUnwrap(meetings.meeting(id))
        XCTAssertEqual(meetings.meetings.count, 1)
        XCTAssertEqual(now.status, .done)
        XCTAssertEqual(now.segments.count, 8)
        XCTAssertTrue(meetings.isMatchingVoices(id))
        XCTAssertEqual(now.people.count, 4)
        await wait("the speaker model to be asked", until: { !asked.isEmpty })
        XCTAssertEqual(Set(asked.keys), ["S1", "S2", "S3", "S4"])
        XCTAssertTrue(asked.values.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.upperBound <= 40 } })

        await gate.open()
        await meetings.drainProcessing()
        let matched = try XCTUnwrap(meetings.meeting(id))
        XCTAssertFalse(meetings.isMatchingVoices(id))
        XCTAssertEqual(matched.people.map { matched.speakerName($0.id) }, ["Me", "Speaker 2"])
        XCTAssertNil(matched.message)
        XCTAssertNil(try store.meeting(id).speakerGroupsToMatch)
        for segment in matched.segments {
            XCTAssertEqual(matched.speakerName(segment.speaker), segment.text.hasPrefix("zayd") ? "Me" : "Speaker 2", segment.text)
        }

        // Zone decided it, so one Undo takes it back, and Undo is then spent.
        XCTAssertEqual(meetings.speakerUndo?.what, "Matched 2 voices across the recordings")
        meetings.undoSpeakerChange()
        XCTAssertEqual(meetings.meeting(id)?.people.count, 4)
        XCTAssertNil(meetings.speakerUndo)
    }

    func testMatchingAThirdRecordingKeepsAnOlderUnansweredReviewVisible() async throws {
        let store = makeStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try await recording(store, at: start, words: ["a", "b"])
        let second = try await recording(store, at: start.addingTimeInterval(600), words: ["c", "d"])
        let third = try await recording(store, at: start.addingTimeInterval(1_200), words: ["a", "b"])
        for (recording, offset) in [(first, 0), (second, 2), (third, 0)] {
            try store.update(recording.id) { meeting in
                for index in meeting.speakers.indices {
                    meeting.speakers[index].voice = Self.voice(offset + index)
                }
            }
        }
        let both = try store.merge(first.id, second.id)
        let expected = Set(MeetingVoiceMatch.reviewPairs(in: both))
        XCTAssertEqual(expected.count, 4)
        let meetings = coordinator(store) { _, _ in XCTFail("All six prints were saved"); return nil }
        await wait("the list", until: { meetings.meetings.count == 2 })
        let id = try XCTUnwrap(meetings.merge(both.id, with: third.id))
        await meetings.drainProcessing()
        let reopened = try store.meeting(id)
        XCTAssertNil(reopened.speakerGroupsToMatch)
        XCTAssertEqual(reopened.visibleMessage, MeetingVoiceMatch.unmatchedMessage)
        XCTAssertEqual(Set(MeetingVoiceMatch.reviewPairs(in: reopened)), expected)
    }

    func testAMatchLeftWaitingWhenZoneClosedRunsAtTheNextLaunch() async throws {
        let store = makeStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try await recording(store, at: start, words: ["zayd", "riju"])
        let second = try await recording(store, at: start.addingTimeInterval(600), words: ["riju", "zayd"])
        // The merge was saved, and Zone closed before the voices were compared.
        let merged = try store.merge(first.id, second.id)
        XCTAssertEqual(merged.speakerGroupsToMatch, [["S3", "S4"]])

        let prints = prints
        let relaunched = coordinator(MeetingStore(directory: store.directory)) { _, spans in prints.filter { spans[$0.key] != nil } }
        await wait("the match", until: { relaunched.meeting(merged.id)?.people.count == 2 })
        await relaunched.drainProcessing()
        XCTAssertNil(try store.meeting(merged.id).speakerGroupsToMatch)
        XCTAssertEqual(try store.meeting(merged.id).segments, merged.segments, "the words and their lines are untouched")
    }

    func testAnInterruptedMatchKeepsWaitingAndFinishesWhenAskedAgain() async throws {
        let store = makeStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try await recording(store, at: start, words: ["zayd", "riju"])
        let second = try await recording(store, at: start.addingTimeInterval(600), words: ["riju", "zayd"])
        var calls = 0
        let prints = prints
        let meetings = coordinator(store) { _, spans in
            calls += 1
            // A recording starting takes the queue: the work is cancelled, not failed.
            if calls == 1 { throw CancellationError() }
            return prints.filter { spans[$0.key] != nil }
        }
        await wait("the list", until: { meetings.meetings.count == 2 })
        let id = try XCTUnwrap(meetings.merge(first.id, with: second.id))
        await meetings.drainProcessing()
        XCTAssertEqual(try store.meeting(id).speakerGroupsToMatch, [["S3", "S4"]], "nothing decided, nothing lost")
        XCTAssertEqual(try store.meeting(id).people.count, 4)
        XCTAssertNil(try store.meeting(id).message)

        meetings.enqueue(id)
        await meetings.drainProcessing()
        XCTAssertEqual(try store.meeting(id).people.count, 2)
    }

    func testRetriesOnlyMissingPrintsAndConfirmsTheRemainingPair() async throws {
        let store = makeStore()
        let first = try await recording(store, at: .distantPast, words: ["one", "two"])
        let second = try await recording(store, at: Date(), words: ["two", "one"])
        var requests: [Set<String>] = []
        let prints = prints
        let meetings = coordinator(store) { _, spans in
            requests.append(Set(spans.keys))
            if requests.count == 1 { return prints.merging(["S4": [Float](repeating: 0, count: 256)]) { _, failed in failed } }
            return ["S4": Self.voice(0, lean: 1.333)]
        }
        await wait("two meetings", until: { meetings.meetings.count == 2 })
        let id = try XCTUnwrap(meetings.merge(first.id, with: second.id))
        await meetings.drainProcessing()
        let review = try store.meeting(id)
        XCTAssertEqual(requests, [["S1", "S2", "S3", "S4"], ["S4"]])
        let pairs = MeetingVoiceMatch.suggestedPairs(in: review)
        XCTAssertEqual(pairs.count, 1)
        try meetings.finishVoiceReview(id, selected: pairs)
        let saved = try store.meeting(id)
        XCTAssertEqual(saved.people.map { saved.speakerName($0.id) }, ["Speaker 1", "Speaker 2"])
        XCTAssertNil(saved.voiceReviewCandidates)
        XCTAssertEqual(saved.segments, review.segments)
        meetings.undoSpeakerChange()
        XCTAssertEqual(meetings.meeting(id)?.people.count, 3)
        XCTAssertEqual(try store.meeting(id).voiceReviewCandidates, review.voiceReviewCandidates)
        XCTAssertEqual(try store.meeting(id).visibleMessage, review.visibleMessage)
        try meetings.finishVoiceReview(id, selected: [])
        XCTAssertNil(try store.meeting(id).voiceReviewCandidates)
        meetings.undoSpeakerChange()
        XCTAssertEqual(MeetingVoiceMatch.suggestedPairs(in: try store.meeting(id)), pairs)
    }

    func testWithoutTheSpeakerModelTheMeetingSaysWhatIsOpenAndTheMatchStaysOwed() async throws {
        let store = makeStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try await recording(store, at: start, words: ["zayd", "riju"])
        let second = try await recording(store, at: start.addingTimeInterval(600), words: ["riju", "zayd"])
        let meetings = coordinator(store) { _, _ in nil }
        await wait("the list", until: { meetings.meetings.count == 2 })
        let id = try XCTUnwrap(meetings.merge(first.id, with: second.id))
        await meetings.drainProcessing()
        let merged = try store.meeting(id)
        XCTAssertEqual(merged.people.count, 4)
        XCTAssertEqual(merged.message, MeetingVoiceMatch.unmatchedMessage)
        XCTAssertNotNil(merged.speakerGroupsToMatch, "owed until the speaker model is back")
        XCTAssertNil(meetings.speakerUndo)
    }

    func testMarkingASecondSpeakerAsMeCombinesThemAndUndoPutsItBack() async throws {
        let store = makeStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try await recording(store, at: start, words: ["zayd", "riju"])
        let second = try await recording(store, at: start.addingTimeInterval(600), words: ["zayd", "riju"])
        let meetings = coordinator(store) { _, _ in nil }
        await wait("the list", until: { meetings.meetings.count == 2 })
        let id = try XCTUnwrap(meetings.merge(first.id, with: second.id))
        await meetings.drainProcessing()

        meetings.setMe(id, speaker: "S1")
        XCTAssertEqual(meetings.speakerUndo?.what, "Marked Speaker 1 as Me")
        meetings.setMe(id, speaker: "S3")
        var meeting = try XCTUnwrap(meetings.meeting(id))
        XCTAssertEqual(meeting.speakerName("S1"), "Me")
        XCTAssertEqual(meeting.speakerName("S3"), "Me")
        XCTAssertEqual(meeting.people.count, 3)
        XCTAssertEqual(meetings.speakerUndo?.what, "Combined Speaker 3 with Me")

        meetings.undoSpeakerChange()
        meeting = try XCTUnwrap(meetings.meeting(id))
        XCTAssertEqual(meeting.speakerName("S1"), "Me", "Undo takes back the last change only")
        XCTAssertEqual(meeting.speakerName("S3"), "Speaker 3")

        meetings.moveMe(id, to: "S3")
        meeting = try XCTUnwrap(meetings.meeting(id))
        XCTAssertEqual(meeting.people.map { meeting.speakerName($0.id) }, ["Speaker 1", "Speaker 2", "Me", "Speaker 4"])
        XCTAssertEqual(meetings.speakerUndo?.what, "Moved Me to Speaker 3")

        meetings.joinSpeakers(id, speaker: "S4", into: "S2")
        meetings.renameSpeaker(id, speaker: "S4", to: "Riju")
        meeting = try XCTUnwrap(meetings.meeting(id))
        XCTAssertEqual(meeting.people.map { meeting.speakerName($0.id) }, ["Speaker 1", "Riju", "Me"])
        meetings.separateSpeaker(id, speaker: "S4")
        XCTAssertEqual(meetings.meeting(id)?.people.count, 4)
        XCTAssertEqual(try store.meeting(id).speakers, meetings.meeting(id)?.speakers, "what is on screen is what is saved")
    }
}

/// Holds an async caller until opened.
private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
