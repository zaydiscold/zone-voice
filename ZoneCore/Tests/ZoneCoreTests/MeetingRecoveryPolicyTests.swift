// by zayd/cold @ zayd.wtf

import Foundation
import Testing
@testable import ZoneCore

@Suite struct MeetingRecoveryPolicyTests {
    private func meeting(status: Meeting.Status, seconds: Double = 3, at: Double = 0) -> Meeting {
        var meeting = Meeting(title: "Recovery", createdAt: Date(timeIntervalSince1970: at), status: status)
        meeting.parts = [MeetingAudioPart(fileName: "part-1.pcm", bytes: Int64(seconds * 32_000))]
        return meeting
    }

    @Test func newBuildRetriesFailedAudioButNeverDoneOrEmpty() {
        let failed = meeting(status: .failed, at: 1)
        let queued = meeting(status: .recorded, at: 0)
        let ids = MeetingLaunchQueue.ids([failed, queued, meeting(status: .done), meeting(status: .failed, seconds: 0), meeting(status: .recording)], currentBuild: "new", lastRetriedBuild: "old")
        #expect(ids == [queued.id, failed.id])
    }

    @Test func sameBuildDoesNotLoopOnFailure() {
        let failed = meeting(status: .failed)
        let queued = meeting(status: .recorded)
        #expect(MeetingLaunchQueue.ids([failed, queued], currentBuild: "1", lastRetriedBuild: "1") == [queued.id])
    }

    @Test func gapUsesRecordedTimeAndKeepsFirstInterruption() {
        let start = Date(timeIntervalSince1970: 100)
        var tracker = MeetingGapTracker()
        tracker.began(at: start, audioSeconds: 12, reason: "default")
        tracker.began(at: start.addingTimeInterval(2), audioSeconds: 14, reason: "mediaServicesReset")
        let gap = tracker.ended(at: start.addingTimeInterval(8))
        #expect(gap == MeetingGap(at: 12, seconds: 8, reason: "default"))
        #expect(!tracker.isOpen)
        #expect(tracker.ended(at: start) == nil)
    }

    @Test func shortGlitchIgnoredAndOpenGapClosesOnStop() {
        let now = Date(timeIntervalSince1970: 100)
        var tracker = MeetingGapTracker()
        tracker.began(at: now, audioSeconds: -1, reason: "routeDisconnected")
        #expect(tracker.ended(at: now.addingTimeInterval(0.1)) == nil)
        tracker.began(at: now, audioSeconds: 0, reason: "routeDisconnected")
        #expect(tracker.close(at: now.addingTimeInterval(1))?.at == 0)
        #expect(!tracker.isOpen)
    }

    @Test func gapSplitsSameSpeakerParagraphAndSurvivesExport() {
        var meeting = meeting(status: .done, seconds: 4)
        meeting.segments = [MeetingSegment(start: 0, end: 2, speaker: "S1", text: "Before."), MeetingSegment(start: 2, end: 4, speaker: "S1", text: "After.")]
        meeting.gaps = [MeetingGap(at: 2, seconds: 80, reason: "default")]
        let paragraphs = MeetingExport.paragraphs(meeting)
        #expect(paragraphs.count == 3)
        #expect(paragraphs.map(\.isGap) == [false, true, false])
        #expect(paragraphs[0].text == "Before.")
        #expect(paragraphs[2].text == "After.")
        #expect(MeetingExport.text(meeting).contains("Not recorded for 1 min 20 s"))
        #expect(Set(paragraphs.map(\.id)).count == 3)
    }

    @Test func gapsRemainVisibleBeforeTranscription() {
        var meeting = meeting(status: .failed)
        meeting.gaps = [MeetingGap(at: 1, seconds: 3, reason: "inputStalled")]
        #expect(MeetingExport.paragraphs(meeting).first?.isGap == true)
    }

    @Test func oldMeetingWithoutGapKeyStillDecodes() throws {
        let old = meeting(status: .failed)
        let encoder = JSONEncoder()
        let data = try encoder.encode(old)
        #expect(!String(decoding: data, as: UTF8.self).contains("gaps"))
        #expect(try JSONDecoder().decode(Meeting.self, from: data).gaps == nil)
        var newer = old
        newer.gaps = [MeetingGap(at: 1, seconds: 2, reason: "default")]
        #expect(try JSONDecoder().decode(Meeting.self, from: encoder.encode(newer)) == newer)
    }

    @Test func transcriptCorrectionsPreserveAudioAndRejectStaleEditors() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(directory: directory)
        let (recording, writer) = try store.beginRecording()
        writer.append(Array(repeating: 0.25, count: 16_000))
        try await writer.finish()
        var meeting = try store.finishRecording(recording.id)
        meeting = try store.update(meeting.id) {
            $0.status = .done
            $0.segments = [MeetingSegment(start: 0, end: 1, speaker: "S1", text: "Wrong name")]
            $0.speakers = [MeetingSpeaker(id: "S1")]
        }
        let original = meeting.segments
        let corrected = try store.editTranscript(meeting.id, original: original, texts: ["  Right name.  "])
        #expect(corrected.segments[0].text == "Right name.")
        #expect(corrected.segments[0].speaker == "S1")
        #expect(corrected.parts == meeting.parts)
        #expect(try store.audio(meeting.id).sampleCount == 16_000)
        #expect(throws: MeetingStoreError.transcriptChanged) {
            try store.editTranscript(meeting.id, original: original, texts: ["Stale copy"])
        }
        _ = try store.update(meeting.id) { $0.status = .transcribing }
        #expect(throws: MeetingStoreError.busy) {
            try store.editTranscript(meeting.id, original: corrected.segments, texts: ["Interrupted"])
        }
    }

    @Test func repeatedResumeAttemptsBackOffWithoutGivingUp() {
        #expect((0...6).map(MeetingResumeSchedule.delay) == [2, 5, 10, 20, 30, 30, 30])
    }

    @Test func chunksCannotCrossAnInterruptionGap() {
        let input = [MeetingChunk(start: 0, end: 8, speaker: "S1")]
        #expect(MeetingChunkPlanner.splitting(input, at: [4, 4, -1, 8, .nan]) == [
            MeetingChunk(start: 0, end: 4, speaker: "S1"),
            MeetingChunk(start: 4, end: 8, speaker: "S1")
        ])
    }

    @Test func multipleGapsWithoutNewAudioHaveUniqueParagraphIDs() {
        var meeting = meeting(status: .recorded)
        meeting.gaps = [MeetingGap(at: 1, seconds: 3, reason: "default"), MeetingGap(at: 1, seconds: 3, reason: "default")]
        let paragraphs = MeetingExport.paragraphs(meeting)
        #expect(paragraphs.count == 2)
        #expect(Set(paragraphs.map(\.id)).count == 2)
    }

    @Test func progressNeverRunsBackwardsWhenTranscriptFollowsDiarizer() {
        var progress = MeetingOverallProgress()
        #expect(progress.update(phase: "Finding speakers", fraction: 1) == 0.2)
        #expect(progress.update(phase: "Transcribing", fraction: 0) == 0.2)
        #expect(abs(progress.update(phase: "Transcribing", fraction: 0.5) - 0.6) < 0.000001)
        #expect(abs(progress.update(phase: "Transcribing", fraction: 0.1) - 0.6) < 0.000001)
        #expect(progress.update(phase: "Transcribing", fraction: 2) == 1)
    }
}
