// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class MeetingStoreTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for url in directories { try? FileManager.default.removeItem(at: url) }
        directories = []
        super.tearDown()
    }

    private func makeStore() -> MeetingStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meetings-" + UUID().uuidString)
        directories.append(url)
        return MeetingStore(directory: url)
    }

    private func record(_ store: MeetingStore, seconds: Double, value: Float = 0.25, at date: Date) async throws -> Meeting {
        let (meeting, writer) = try store.beginRecording(now: date)
        writer.append([Float](repeating: value, count: Int(seconds * 16_000)))
        try await writer.finish()
        return try store.finishRecording(meeting.id, now: date)
    }

    // MARK: Recording

    func testRecordingWritesPCMAndFinishesAsRecordedWithFileDuration() async throws {
        let store = makeStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let (meeting, writer) = try store.beginRecording(now: start)
        XCTAssertEqual(try store.meeting(meeting.id).status, .recording)
        XCTAssertTrue(meeting.title.hasPrefix("Meeting, "))
        for _ in 0..<10 { writer.append([Float](repeating: 0.5, count: 1_600)) }
        try await writer.finish()
        XCTAssertEqual(writer.writtenSamples, 16_000)
        XCTAssertEqual(writer.droppedSamples, 0)
        let finished = try store.finishRecording(meeting.id)
        XCTAssertEqual(finished.status, .recorded)
        XCTAssertEqual(finished.duration, 1, accuracy: 0.0001)
        let audio = try store.audio(meeting.id)
        XCTAssertEqual(audio.sampleCount, 16_000)
        XCTAssertEqual(try audio.read(offset: 100, count: 1).first ?? 0, 0.5, accuracy: 0.0001)
    }

    func testInterruptedRecordingIsRecoveredOnLaunchWithAudioThatReachedDisk() async throws {
        let store = makeStore()
        let (meeting, writer) = try store.beginRecording()
        writer.append([Float](repeating: 0.1, count: 32_000))
        try await writer.finish()
        // Simulate a crash: metadata still says recording, and a torn final byte.
        let url = store.audioURLs(try store.meeting(meeting.id))[0]
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([7])); try handle.close()

        let relaunched = MeetingStore(directory: store.directory)
        XCTAssertEqual(relaunched.recoverInterrupted(), [meeting.id])
        let recovered = try relaunched.meeting(meeting.id)
        XCTAssertEqual(recovered.status, .recorded)
        XCTAssertEqual(recovered.duration, 2, accuracy: 0.0001)
        XCTAssertNotNil(recovered.message)
        // A second launch finds nothing left to recover.
        XCTAssertEqual(relaunched.recoverInterrupted(), [])
    }

    func testRecoverySkipsTheActiveRecordingAndDropsEmptyMeetings() async throws {
        let store = makeStore()
        let (active, activeWriter) = try store.beginRecording()
        let (empty, emptyWriter) = try store.beginRecording()
        try await emptyWriter.finish()
        XCTAssertEqual(store.recoverInterrupted(activeIDs: [active.id]), [])
        XCTAssertEqual(try store.meeting(active.id).status, .recording)
        XCTAssertThrowsError(try store.meeting(empty.id))
        try await activeWriter.finish()
    }

    func testInterruptedTranscriptionKeepsSegmentsAndResumes() async throws {
        let store = makeStore()
        let meeting = try await record(store, seconds: 4, at: Date())
        try store.update(meeting.id) {
            $0.status = .transcribing
            $0.segments = [MeetingSegment(start: 0, end: 2, speaker: nil, text: "first half")]
            $0.transcribedThrough = 2
        }
        XCTAssertEqual(MeetingStore(directory: store.directory).recoverInterrupted(), [meeting.id])
        let resumed = try store.meeting(meeting.id)
        XCTAssertEqual(resumed.status, .recorded)
        XCTAssertEqual(resumed.transcribedThrough, 2)
        XCTAssertEqual(resumed.segments.count, 1)
    }

    func testContinueRecordingAddsASecondPartReadAsOneSignal() async throws {
        let store = makeStore()
        let (meeting, first) = try store.beginRecording()
        first.append([Float](repeating: 0.25, count: 16_000))
        try await first.finish()
        let second = try store.continueRecording(meeting.id)
        second.append([Float](repeating: -0.5, count: 8_000))
        try await second.finish()
        let finished = try store.finishRecording(meeting.id)
        XCTAssertEqual(finished.parts.count, 2)
        XCTAssertEqual(finished.duration, 1.5, accuracy: 0.0001)
        let audio = try store.audio(meeting.id)
        let across = try audio.read(offset: 15_999, count: 2)
        XCTAssertEqual(across[0], 0.25, accuracy: 0.0001)
        XCTAssertEqual(across[1], -0.5, accuracy: 0.0001)
        // Reading past the end is clipped, not padded.
        XCTAssertEqual(try audio.read(offset: 23_990, count: 100).count, 10)
    }

    func testWriterDropsAudioPastItsBacklogInsteadOfGrowing() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pcm")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try MeetingAudioWriter(url: url, maxQueuedSamples: 100)
        writer.append([Float](repeating: 0, count: 101))
        XCTAssertEqual(writer.droppedSamples, 101)
        writer.append([Float](repeating: 0, count: 50))
        try await writer.finish()
        XCTAssertEqual(writer.writtenSamples, 50)
        writer.append([0, 0]) // After finish: ignored, never a crash.
        try await writer.finish()
    }

    // MARK: Editing

    func testRenameSpeakersAndOnlyOneMe() async throws {
        let store = makeStore()
        let meeting = try await record(store, seconds: 1, at: Date())
        try store.update(meeting.id) { $0.speakers = [MeetingSpeaker(id: "S1"), MeetingSpeaker(id: "S2")] }
        try store.rename(meeting.id, to: "  Design review ")
        try store.renameSpeaker(meeting.id, speaker: "S2", to: "Priya")
        try store.setMe(meeting.id, speaker: "S1")
        var stored = try store.meeting(meeting.id)
        XCTAssertEqual(stored.title, "Design review")
        XCTAssertEqual(stored.speakerName("S1"), "Me")
        XCTAssertEqual(stored.speakerName("S2"), "Priya")
        try store.setMe(meeting.id, speaker: "S2")
        stored = try store.meeting(meeting.id)
        XCTAssertEqual(stored.speakers.filter(\.isMe).map(\.id), ["S2"])
        XCTAssertEqual(stored.speakerName("S1"), "Speaker 1")
        XCTAssertEqual(stored.speakerName("S2"), "Priya") // A name beats "Me".
        try store.renameSpeaker(meeting.id, speaker: "S2", to: " ")
        XCTAssertEqual(try store.meeting(meeting.id).speakerName("S2"), "Me")
        try store.rename(meeting.id, to: "   ")
        XCTAssertEqual(try store.meeting(meeting.id).title, "Design review")
    }

    func testResetTranscriptKeepsAudioAndStartsSpeakersOver() async throws {
        let store = makeStore()
        let meeting = try await record(store, seconds: 1, at: Date())
        try store.update(meeting.id) {
            $0.status = .done
            $0.segments = [MeetingSegment(start: 0, end: 1, speaker: "S1", text: "hi")]
            $0.speakers = [MeetingSpeaker(id: "S1", name: "Sam")]
            $0.transcribedThrough = 1
        }
        try store.resetTranscript(meeting.id)
        let reset = try store.meeting(meeting.id)
        XCTAssertEqual(reset.status, .recorded)
        XCTAssertTrue(reset.segments.isEmpty)
        XCTAssertEqual(reset.transcribedThrough, 0)
        XCTAssertTrue(reset.speakers.isEmpty)
        XCTAssertEqual(reset.duration, 1, accuracy: 0.0001)
    }

    func testDeleteRemovesAudioAndMetadata() async throws {
        let store = makeStore()
        let meeting = try await record(store, seconds: 1, at: Date())
        try store.delete(meeting.id)
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(meeting.id).path))
    }

    func testSpeakerCountHintPersistsPerMeetingAndAutomaticClearsIt() async throws {
        let store = makeStore()
        let meeting = try await record(store, seconds: 1, at: Date())
        let audio = try store.audio(meeting.id).read(offset: 0, count: 16_000)
        try store.resetTranscript(meeting.id, expectedSpeakerCount: 2)
        XCTAssertEqual(try store.meeting(meeting.id).speakerCountHint, 2)
        XCTAssertEqual(try store.audio(meeting.id).read(offset: 0, count: 16_000), audio)
        let oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(meeting)) as! [String: Any]
        var withoutHint = oldJSON
        withoutHint.removeValue(forKey: "expectedSpeakerCount")
        XCTAssertNil(try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: withoutHint)).speakerCountHint)
        try store.resetTranscript(meeting.id)
        XCTAssertNil(try store.meeting(meeting.id).speakerCountHint)
        try store.resetTranscript(meeting.id, expectedSpeakerCount: 100)
        XCTAssertNil(try store.meeting(meeting.id).speakerCountHint)
    }

    func testCountRetryCannotResetAnActiveTranscription() async throws {
        let store = makeStore()
        let meeting = try await record(store, seconds: 1, at: Date())
        try store.update(meeting.id) {
            $0.status = .transcribing
            $0.segments = [MeetingSegment(start: 0, end: 1, speaker: "S1", text: "Keep this")]
        }
        XCTAssertThrowsError(try store.resetTranscript(meeting.id, expectedSpeakerCount: 2)) {
            XCTAssertEqual($0 as? MeetingStoreError, .busy)
        }
        XCTAssertEqual(try store.meeting(meeting.id).segments.first?.text, "Keep this")
        XCTAssertNil(try store.meeting(meeting.id).speakerCountHint)
    }

    // MARK: Merge

    func testMergeConcatenatesAudioAndOffsetsSegmentsInTimeOrder() async throws {
        let store = makeStore()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        // Recorded second but passed first: merge orders by start time.
        let later = try await record(store, seconds: 2, value: -0.5, at: base.addingTimeInterval(600))
        let earlier = try await record(store, seconds: 3, value: 0.25, at: base)
        try store.update(earlier.id) {
            $0.status = .done; $0.transcribedThrough = 3
            $0.expectedSpeakerCount = 2
            $0.segments = [MeetingSegment(start: 0.5, end: 2.5, speaker: "S1", text: "opening")]
            $0.speakers = [MeetingSpeaker(id: "S1", isMe: true), MeetingSpeaker(id: "S2", name: "Ana")]
        }
        try store.update(later.id) {
            $0.status = .done; $0.transcribedThrough = 2
            $0.segments = [MeetingSegment(start: 0, end: 1, speaker: "S1", text: "me again"),
                           MeetingSegment(start: 1, end: 1.5, speaker: "S2", text: "ana again"),
                           MeetingSegment(start: 1.5, end: 2, speaker: "S3", text: "someone new")]
            $0.speakers = [MeetingSpeaker(id: "S1", isMe: true), MeetingSpeaker(id: "S2", name: "ana"),
                           MeetingSpeaker(id: "S3")]
        }
        let merged = try store.merge(later.id, earlier.id)
        XCTAssertEqual(merged.id, earlier.id)
        XCTAssertNil(merged.speakerCountHint)
        XCTAssertEqual(merged.duration, 5, accuracy: 0.0001)
        XCTAssertEqual(merged.status, .done)
        XCTAssertEqual(merged.transcribedThrough, 5, accuracy: 0.0001)
        XCTAssertEqual(merged.segments.map(\.start), [0.5, 3, 4, 4.5])
        // Me maps to me, a shared name maps to that speaker, a stranger gets a fresh id.
        XCTAssertEqual(merged.segments.map(\.speaker), ["S1", "S1", "S2", "S3"])
        XCTAssertEqual(merged.speakers.map(\.id), ["S1", "S2", "S3"])
        XCTAssertEqual(merged.speakers.filter(\.isMe).count, 1)
        XCTAssertThrowsError(try store.meeting(later.id))
        XCTAssertEqual(store.all().count, 1)
        let audio = try store.audio(merged.id)
        XCTAssertEqual(audio.sampleCount, 80_000)
        XCTAssertEqual(try audio.read(offset: 47_999, count: 1)[0], 0.25, accuracy: 0.0001)
        XCTAssertEqual(try audio.read(offset: 48_000, count: 1)[0], -0.5, accuracy: 0.0001)
    }

    func testMergeWithUntranscribedLaterKeepsEarlierTranscriptAndResumesAfterIt() async throws {
        let store = makeStore()
        let base = Date()
        let one = try await record(store, seconds: 2, at: base)
        let two = try await record(store, seconds: 1, at: base.addingTimeInterval(60))
        try store.update(one.id) {
            $0.status = .done; $0.transcribedThrough = 2
            $0.segments = [MeetingSegment(start: 0, end: 2, speaker: nil, text: "kept")]
        }
        let merged = try store.merge(one.id, two.id)
        XCTAssertEqual(merged.status, .recorded)
        XCTAssertEqual(merged.transcribedThrough, 2, accuracy: 0.0001)
        XCTAssertEqual(merged.segments.map(\.text), ["kept"])
    }

    func testMergeWithUntranscribedEarlierDropsTheLaterTranscript() async throws {
        let store = makeStore()
        let base = Date()
        let one = try await record(store, seconds: 2, at: base)
        let two = try await record(store, seconds: 1, at: base.addingTimeInterval(60))
        try store.update(two.id) {
            $0.status = .done; $0.transcribedThrough = 1
            $0.segments = [MeetingSegment(start: 0, end: 1, speaker: nil, text: "redone later")]
        }
        let merged = try store.merge(one.id, two.id)
        XCTAssertEqual(merged.status, .recorded)
        XCTAssertEqual(merged.transcribedThrough, 0)
        XCTAssertTrue(merged.segments.isEmpty)
    }

    func testMergeRefusesRecordingSelfAndTranscribing() async throws {
        let store = makeStore()
        let done = try await record(store, seconds: 1, at: Date())
        let (recording, writer) = try store.beginRecording()
        XCTAssertThrowsError(try store.merge(done.id, recording.id)) { XCTAssertEqual($0 as? MeetingStoreError, .stillRecording) }
        XCTAssertThrowsError(try store.merge(done.id, done.id)) { XCTAssertEqual($0 as? MeetingStoreError, .sameMeeting) }
        try await writer.finish()
        try store.finishRecording(recording.id)
        try store.update(recording.id) { $0.status = .transcribing }
        XCTAssertThrowsError(try store.merge(done.id, recording.id)) { XCTAssertEqual($0 as? MeetingStoreError, .busy) }
        XCTAssertEqual(store.all().count, 2)
    }

    func testMergeTwiceKeepsUniquePartNames() async throws {
        let store = makeStore()
        let base = Date()
        let a = try await record(store, seconds: 1, at: base)
        let b = try await record(store, seconds: 1, at: base.addingTimeInterval(10))
        let c = try await record(store, seconds: 1, at: base.addingTimeInterval(20))
        _ = try store.merge(a.id, b.id)
        let merged = try store.merge(a.id, c.id)
        XCTAssertEqual(Set(merged.parts.map(\.fileName)).count, 3)
        XCTAssertEqual(merged.duration, 3, accuracy: 0.0001)
    }

    func testListIsNewestFirst() async throws {
        let store = makeStore()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let old = try await record(store, seconds: 0.5, at: base)
        let new = try await record(store, seconds: 0.5, at: base.addingTimeInterval(3_600))
        XCTAssertEqual(store.all().map(\.id), [new.id, old.id])
    }
}

final class MeetingTranscriptTests: XCTestCase {
    func testUndividedAudioIsCutAtPausesAndSilenceIsSkipped() {
        // 70 s: speech everywhere except a dip at 20 s and silence from 50 s to 70 s.
        var levels = [Float](repeating: 0.1, count: 700)
        levels[200] = 0.001
        for index in 500..<700 { levels[index] = 0.0001 }
        let chunks = MeetingChunkPlanner.plan(turns: [], levels: levels, from: 0, to: 70)
        XCTAssertEqual(chunks.first?.start, 0)
        XCTAssertEqual(chunks.first?.end ?? 0, 20, accuracy: 0.001)
        XCTAssertTrue(chunks.allSatisfy { $0.duration <= 28.001 })
        XCTAssertTrue(chunks.allSatisfy { $0.speaker == nil })
        // Nothing past 50 s plus the split tail is sent to the engine.
        XCTAssertLessThan(chunks.last?.start ?? 70, 50)
    }

    func testTurnsMergeSameSpeakerAndSplitLongOnes() {
        let levels = [Float](repeating: 0.1, count: 700) + [Float](repeating: 0, count: 300)
        let turns = [MeetingTurn(start: 0, end: 4, speaker: "S1"),
                     MeetingTurn(start: 4.5, end: 8, speaker: "S1"),
                     MeetingTurn(start: 8.2, end: 70, speaker: "S2")]
        let chunks = MeetingChunkPlanner.plan(turns: turns, levels: levels, from: 0, to: 100, padding: 0)
        XCTAssertEqual(chunks.first, MeetingChunk(start: 0, end: 8, speaker: "S1"))
        let second = chunks.dropFirst()
        XCTAssertTrue(second.allSatisfy { $0.speaker == "S2" })
        XCTAssertGreaterThanOrEqual(second.count, 3)
        XCTAssertEqual(second.last?.end ?? 0, 70, accuracy: 0.001)
        XCTAssertTrue(chunks.allSatisfy { $0.duration <= 28.001 })
    }

    func testPlanningResumesFromAnOffset() {
        let levels = [Float](repeating: 0.1, count: 600)
        let chunks = MeetingChunkPlanner.plan(turns: [], levels: levels, from: 30, to: 60)
        XCTAssertEqual(chunks.first?.start, 30)
        XCTAssertEqual(chunks.last?.end, 60)
    }

    func testMissedSpeakerAudioIsTranscribedWithoutInventingALabel() {
        var levels = [Float](repeating: 0, count: 200)
        for range in [10..<30, 50..<80, 100..<130, 160..<190] {
            for i in range { levels[i] = 0.04 }
        }
        let turns = [MeetingTurn(start: 5, end: 8, speaker: "S1"),
                     MeetingTurn(start: 10, end: 13, speaker: "S2")]
        let chunks = MeetingChunkPlanner.plan(turns: turns, levels: levels, from: 0, to: 20)
        for time in [1.5, 6, 11, 17] {
            XCTAssertTrue(chunks.contains { $0.start <= time && $0.end >= time })
        }
        XCTAssertNil(chunks.first?.speaker)
        XCTAssertNil(chunks.last?.speaker)
        XCTAssertEqual(chunks.compactMap(\.speaker), ["S1", "S2"])
        for (a, b) in zip(chunks, chunks.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.start) }
    }

    func testMissedSpeechBetweenTurnsAndAfterResumeIsPreserved() {
        let turns = [MeetingTurn(start: 0, end: 10, speaker: "S1"),
                     MeetingTurn(start: 50, end: 55, speaker: "S2")]
        let chunks = MeetingChunkPlanner.plan(turns: turns, levels: [Float](repeating: 0.04, count: 600),
                                              from: 20, to: 60)
        XCTAssertEqual(chunks.first?.start, 20)
        XCTAssertNil(chunks.first?.speaker)
        XCTAssertTrue(chunks.allSatisfy { $0.start >= 20 && $0.end <= 60 && $0.duration <= 28.001 })
        XCTAssertTrue(chunks.contains { $0.start <= 35 && $0.end >= 35 && $0.speaker == nil })
    }

    func testUncoveredSilenceDoesNotCreateExtraChunks() {
        var levels = [Float](repeating: 0, count: 200)
        for i in 50..<80 { levels[i] = 0.04 }
        let chunks = MeetingChunkPlanner.plan(turns: [MeetingTurn(start: 5, end: 8, speaker: "S1")],
                                              levels: levels, from: 0, to: 20)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.speaker, "S1")
    }

    func testSpeakerLabelsNormalizeAfterExistingSpeakers() {
        let turns = [MeetingTurn(start: 5, end: 6, speaker: "SPEAKER_01"),
                     MeetingTurn(start: 1, end: 2, speaker: "SPEAKER_00"),
                     MeetingTurn(start: 7, end: 8, speaker: "SPEAKER_00")]
        let result = MeetingSpeakerLabels.normalize(turns, existing: [MeetingSpeaker(id: "S1", name: "Kim")])
        XCTAssertEqual(result.turns.map(\.speaker), ["S2", "S3", "S2"])
        XCTAssertEqual(result.speakers.map(\.id), ["S1", "S2", "S3"])
    }

    func testExportGroupsBySpeakerWithTimestamps() {
        var meeting = Meeting(title: "Standup", createdAt: Date(timeIntervalSince1970: 1_800_000_000), status: .done)
        meeting.parts = [MeetingAudioPart(fileName: "part-1.pcm", bytes: 2 * 16_000 * 3_725)]
        meeting.speakers = [MeetingSpeaker(id: "S1", isMe: true), MeetingSpeaker(id: "S2", name: "Leo")]
        meeting.segments = [MeetingSegment(start: 0, end: 5, speaker: "S1", text: "Morning."),
                            MeetingSegment(start: 5, end: 9, speaker: "S1", text: "Quick one today."),
                            MeetingSegment(start: 3_700, end: 3_705, speaker: "S2", text: "Shipped it.")]
        let text = MeetingExport.text(meeting, locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(text.hasPrefix("Standup\n"))
        XCTAssertTrue(text.contains("1 h 2 min"))
        XCTAssertTrue(text.contains("[0:00] Me: Morning. Quick one today."))
        XCTAssertTrue(text.contains("[1:01:40] Leo: Shipped it."))
    }

    func testParagraphsJoinTwoIdsRenamedToTheSamePerson() {
        var meeting = Meeting(title: "Sync", createdAt: Date(), status: .done)
        meeting.speakers = [MeetingSpeaker(id: "S1", name: "Ravi"), MeetingSpeaker(id: "S2"), MeetingSpeaker(id: "S3", name: "ravi ")]
        meeting.segments = [MeetingSegment(start: 0, end: 1, speaker: "S1", text: "one"),
                            MeetingSegment(start: 1, end: 2, speaker: "S3", text: "two"),
                            MeetingSegment(start: 2, end: 3, speaker: "S2", text: "three"),
                            MeetingSegment(start: 3, end: 4, speaker: "S2", text: "  "),
                            MeetingSegment(start: 4, end: 5, speaker: "S2", text: "four")]
        let paragraphs = MeetingExport.paragraphs(meeting)
        // "Ravi" and "ravi " are different strings, so they stay apart; same ids join.
        XCTAssertEqual(paragraphs.map(\.text), ["one", "two", "three four"])
        meeting.speakers[2].name = "Ravi"
        XCTAssertEqual(MeetingExport.paragraphs(meeting).map(\.text), ["one two", "three four"])
    }

    func testExportWithoutSpeakersAndDefaultTitle() {
        var meeting = Meeting(title: Meeting.defaultTitle(for: Date(timeIntervalSince1970: 0),
                                                          calendar: { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }(),
                                                          locale: Locale(identifier: "en_US")),
                              createdAt: Date(timeIntervalSince1970: 0), status: .done)
        // Foundation puts a narrow no-break space before AM; compare with plain spaces.
        XCTAssertEqual(meeting.title.replacingOccurrences(of: "\u{202F}", with: " "), "Meeting, Jan 1 at 12:00 AM")
        meeting.segments = [MeetingSegment(start: 65, end: 70, speaker: nil, text: "No labels here.")]
        XCTAssertTrue(MeetingExport.text(meeting).contains("[1:05] No labels here."))
        XCTAssertEqual(MeetingExport.durationLabel(42), "42 s")
        XCTAssertEqual(MeetingExport.durationLabel(48 * 60), "48 min")
    }
}
