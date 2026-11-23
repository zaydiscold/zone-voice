// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// Meetings at the edges: long merge chains, crashes inside a recording and inside a merge,
/// renames after a merge, a two-hour chunk plan, and parts reopened after a torn write.
final class MeetingStoreStressTests: XCTestCase {
    private var directories: [URL] = []
    private var lockedFiles: [URL] = []

    override func tearDown() {
        for url in lockedFiles { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path) }
        for url in directories { try? FileManager.default.removeItem(at: url) }
        directories = []
        lockedFiles = []
        super.tearDown()
    }

    private func makeStore() -> MeetingStore {
        let url = Stress.temporaryDirectory("meetings")
        directories.append(url)
        return MeetingStore(directory: url)
    }

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    /// A recorded meeting of `samples` samples, all `value`, created at `base + order` seconds.
    private func recorded(_ store: MeetingStore, samples: Int, value: Float, order: Int) async throws -> Meeting {
        let (meeting, writer) = try store.beginRecording(title: "M\(order)", now: base.addingTimeInterval(Double(order)))
        writer.append([Float](repeating: value, count: samples))
        try await writer.finish()
        return try store.finishRecording(meeting.id, now: base.addingTimeInterval(Double(order)))
    }

    // MARK: Merge chains

    func testRandomMergeChainsKeepEverySampleSpeakerAndSegmentConsistent() async throws {
        var rng = StressRNG(seed: 0x3E37)
        for round in 0..<Stress.iterations(4, heavy: 40) {
            let store = makeStore()
            let count = rng.int(3...7)
            /// Expected audio of each live meeting, as a list of (value, samples) blocks.
            var blocks: [UUID: [(Float, Int)]] = [:]
            var created: [UUID: Date] = [:]
            for index in 0..<count {
                let samples = rng.int(1...5) * 3_200
                let value = Float(index + 1) / 10
                let meeting = try await recorded(store, samples: samples, value: value, order: index)
                blocks[meeting.id] = [(value, samples)]
                created[meeting.id] = meeting.createdAt
                // Half are transcribed, with two to three voices; some named, one may be "me".
                if rng.chance(0.5) {
                    let duration = meeting.duration
                    let voices = rng.int(2...3)
                    let names = [nil, "Priya", "Zayd", "Omar"]
                    try store.update(meeting.id) { m in
                        m.speakers = (1...voices).map { MeetingSpeaker(id: "S\($0)", name: rng.pick(names), isMe: $0 == 1 && rng.chance(0.5)) }
                        let pieces = 4
                        m.segments = (0..<pieces).map { piece in
                            MeetingSegment(start: duration * Double(piece) / Double(pieces), end: duration * Double(piece + 1) / Double(pieces),
                                           speaker: "S\(piece % voices + 1)", text: "m\(index) p\(piece)")
                        }
                        m.transcribedThrough = duration
                        m.status = .done
                    }
                }
            }
            while blocks.count > 1 {
                let ids = Array(blocks.keys).shuffled(using: &rng)
                let (a, b) = (ids[0], ids[1])
                let merged = try store.merge(a, b, now: base.addingTimeInterval(1_000))
                let (first, second) = created[a]! <= created[b]! ? (a, b) : (b, a)
                XCTAssertEqual(merged.id, first)
                blocks[first] = blocks[first]! + blocks[second]!
                blocks[second] = nil
                created[second] = nil
            }
            let (id, expected) = blocks.first!
            let meeting = try store.meeting(id)
            let total = expected.reduce(0) { $0 + $1.1 }
            XCTAssertEqual(meeting.duration, Double(total) / 16_000, accuracy: 0.0001, "round \(round)")
            XCTAssertEqual(store.all().count, 1, "every merged-away meeting is deleted")
            XCTAssertEqual(Set(meeting.parts.map(\.fileName)).count, meeting.parts.count, "part names are unique")
            let onDisk = try FileManager.default.contentsOfDirectory(atPath: store.folder(id).path).filter { $0.hasSuffix(".pcm") }
            XCTAssertEqual(Set(onDisk), Set(meeting.parts.map(\.fileName)), "no orphaned or missing part files")
            // The audio plays back as the blocks in merge order.
            let audio = try store.audio(id)
            XCTAssertEqual(audio.sampleCount, total)
            var offset = 0
            for (value, samples) in expected {
                XCTAssertEqual(try audio.read(offset: offset + samples / 2, count: 1).first ?? -1, value, accuracy: 0.0001)
                offset += samples
            }
            // Speakers are unique and every segment names one that exists; segments fit the audio.
            XCTAssertEqual(Set(meeting.speakers.map(\.id)).count, meeting.speakers.count)
            XCTAssertLessThanOrEqual(meeting.speakers.filter(\.isMe).count, 1)
            let known = Set(meeting.speakers.map(\.id))
            for segment in meeting.segments {
                if let speaker = segment.speaker { XCTAssertTrue(known.contains(speaker), "unknown speaker \(speaker)") }
                XCTAssertLessThanOrEqual(segment.end, meeting.duration + 0.001)
                XCTAssertLessThanOrEqual(segment.end, meeting.transcribedThrough + 0.001, "a segment past the resume point")
            }
            let starts = meeting.segments.map(\.start)
            XCTAssertEqual(starts, starts.sorted())
            XCTAssertLessThanOrEqual(meeting.transcribedThrough, meeting.duration + 0.001)
            XCTAssertTrue([.done, .recorded].contains(meeting.status))
        }
    }

    func testRenamingSpeakersAfterAMergeFlowsIntoTheExport() async throws {
        let store = makeStore()
        let one = try await recorded(store, samples: 32_000, value: 0.2, order: 0)
        let two = try await recorded(store, samples: 32_000, value: 0.3, order: 1)
        for (id, text) in [(one.id, "first"), (two.id, "second")] {
            try store.update(id) { m in
                m.speakers = [MeetingSpeaker(id: "S1"), MeetingSpeaker(id: "S2")]
                m.segments = [MeetingSegment(start: 0, end: 1, speaker: "S1", text: "\(text) a"),
                              MeetingSegment(start: 1, end: 2, speaker: "S2", text: "\(text) b")]
                m.transcribedThrough = 2
                m.status = .done
            }
        }
        let merged = try store.merge(two.id, one.id)
        XCTAssertEqual(merged.speakers.map(\.id), ["S1", "S2", "S3", "S4"])
        // The same person carried two numbers; naming both the same joins their paragraphs.
        try store.renameSpeaker(merged.id, speaker: "S2", to: "Priya")
        try store.renameSpeaker(merged.id, speaker: "S3", to: " Priya ")
        try store.setMe(merged.id, speaker: "S4")
        let final = try store.meeting(merged.id)
        let paragraphs = MeetingExport.paragraphs(final)
        XCTAssertEqual(paragraphs.map { final.speakerName($0.speaker) }, ["Speaker 1", "Priya", "Me"])
        XCTAssertEqual(paragraphs[1].text, "first b second a")
        let text = MeetingExport.text(final, locale: Locale(identifier: "en_US_POSIX"), timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(text.contains("[0:01] Priya: first b second a"), text)
        XCTAssertTrue(text.contains("[0:03] Me: second b"), text)
        // Clearing a name falls back to the number.
        try store.renameSpeaker(merged.id, speaker: "S2", to: "   ")
        XCTAssertEqual(try store.meeting(merged.id).speakerName("S2"), "Speaker 2")
    }

    /// A later meeting whose segments name a voice it does not list used to keep the raw id,
    /// which could be a different person in the earlier meeting.
    func testMergeGivesUnlistedSegmentVoicesTheirOwnID() async throws {
        let store = makeStore()
        let one = try await recorded(store, samples: 16_000, value: 0.2, order: 0)
        let two = try await recorded(store, samples: 16_000, value: 0.3, order: 1)
        try store.update(one.id) { m in
            m.speakers = [MeetingSpeaker(id: "S1", name: "Priya")]
            m.segments = [MeetingSegment(start: 0, end: 1, speaker: "S1", text: "hello")]
            m.transcribedThrough = 1
            m.status = .done
        }
        try store.update(two.id) { m in
            m.speakers = []
            m.segments = [MeetingSegment(start: 0, end: 1, speaker: "S1", text: "someone else")]
            m.transcribedThrough = 1
            m.status = .done
        }
        let merged = try store.merge(one.id, two.id)
        XCTAssertEqual(merged.segments.map(\.speaker), ["S1", "S2"])
        XCTAssertEqual(merged.speakerName("S2"), "Speaker 2")
    }

    // MARK: Crashes

    func testInterruptedMultiPartRecordingKeepsEveryWholeSample() async throws {
        let store = makeStore()
        let (meeting, first) = try store.beginRecording(now: base)
        first.append([Float](repeating: 0.1, count: 16_000))
        try await first.finish()
        let second = try store.continueRecording(meeting.id)   // interruption, nothing recorded
        try await second.finish()
        let third = try store.continueRecording(meeting.id)
        third.append([Float](repeating: 0.3, count: 8_000))
        try await third.finish()
        _ = try store.continueRecording(meeting.id)            // killed before its file had a byte
        try FileManager.default.removeItem(at: store.folder(meeting.id).appendingPathComponent("part-4.pcm"))
        let handle = try FileHandle(forWritingTo: store.folder(meeting.id).appendingPathComponent("part-3.pcm"))
        try handle.seekToEnd(); try handle.write(contentsOf: Data([1])); try handle.close()

        let relaunched = MeetingStore(directory: store.directory)
        XCTAssertEqual(relaunched.recoverInterrupted(), [meeting.id])
        let recovered = try relaunched.meeting(meeting.id)
        XCTAssertEqual(recovered.status, .recorded)
        XCTAssertEqual(recovered.parts.map(\.fileName), ["part-1.pcm", "part-3.pcm"])
        XCTAssertEqual(recovered.duration, 1.5, accuracy: 0.0001)
        let audio = try relaunched.audio(meeting.id)
        XCTAssertEqual(audio.sampleCount, 24_000)
        XCTAssertEqual(try audio.read(offset: 23_999, count: 1).first ?? 0, 0.3, accuracy: 0.0001)
        // Recording again after recovery appends a fresh part, never reusing a torn one.
        let resumed = try relaunched.continueRecording(meeting.id)
        resumed.append([Float](repeating: 0.5, count: 1_600))
        try await resumed.finish()
        let final = try relaunched.finishRecording(meeting.id)
        XCTAssertEqual(final.duration, 1.6, accuracy: 0.0001)
    }

    /// Killed after the later meeting's audio moved but before either metadata file changed:
    /// the next launch adopts the audio into the earlier meeting instead of orphaning it.
    func testCrashInsideAMergeIsRepairedOnTheNextLaunch() async throws {
        let store = makeStore()
        let one = try await recorded(store, samples: 16_000, value: 0.2, order: 0)
        let two = try await recorded(store, samples: 32_000, value: 0.4, order: 1)
        try store.update(two.id) { m in
            m.segments = [MeetingSegment(start: 0, end: 2, speaker: nil, text: "the later transcript")]
            m.transcribedThrough = 2
            m.status = .done
        }
        try FileManager.default.moveItem(at: store.folder(two.id).appendingPathComponent("part-1.pcm"),
                                         to: store.folder(one.id).appendingPathComponent("part-2.pcm"))

        let relaunched = MeetingStore(directory: store.directory)
        let repaired = relaunched.recoverInterrupted()
        XCTAssertEqual(Set(repaired), [one.id, two.id])
        let earlier = try relaunched.meeting(one.id)
        XCTAssertEqual(earlier.parts.map(\.fileName), ["part-1.pcm", "part-2.pcm"])
        XCTAssertEqual(earlier.duration, 3, accuracy: 0.0001)
        XCTAssertEqual(try relaunched.audio(one.id).read(offset: 40_000, count: 1).first ?? 0, 0.4, accuracy: 0.0001)
        // The later meeting keeps its transcript text, with no claim on audio it no longer has.
        let later = try relaunched.meeting(two.id)
        XCTAssertEqual(later.parts, [])
        XCTAssertEqual(later.segments.map(\.text), ["the later transcript"])
        XCTAssertEqual(later.transcribedThrough, 0)
        XCTAssertEqual(later.status, .done)
        XCTAssertThrowsError(try relaunched.audio(two.id))
        // A second launch has nothing left to repair.
        XCTAssertEqual(MeetingStore(directory: store.directory).recoverInterrupted(), [])
    }

    /// A move that fails halfway used to leave the moved parts orphaned in the earlier folder.
    func testFailedMergeLeavesBothMeetingsAsTheyWere() async throws {
        let store = makeStore()
        let one = try await recorded(store, samples: 16_000, value: 0.2, order: 0)
        let (twoMeeting, writer) = try store.beginRecording(now: base.addingTimeInterval(5))
        writer.append([Float](repeating: 0.4, count: 16_000))
        try await writer.finish()
        let next = try store.continueRecording(twoMeeting.id)
        next.append([Float](repeating: 0.6, count: 16_000))
        try await next.finish()
        let two = try store.finishRecording(twoMeeting.id)
        // The second part cannot be moved (immutable), so the merge fails after the first moved.
        let stuck = store.folder(two.id).appendingPathComponent("part-2.pcm")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: stuck.path)
        lockedFiles.append(stuck)

        XCTAssertThrowsError(try store.merge(one.id, two.id))
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: stuck.path)
        XCTAssertEqual(try store.meeting(one.id).duration, 1, accuracy: 0.0001)
        XCTAssertEqual(try store.meeting(two.id).duration, 2, accuracy: 0.0001)
        let earlierFiles = try FileManager.default.contentsOfDirectory(atPath: store.folder(one.id).path).filter { $0.hasSuffix(".pcm") }
        XCTAssertEqual(earlierFiles, ["part-1.pcm"], "nothing was left behind in the earlier meeting")
        XCTAssertEqual(try store.audio(two.id).read(offset: 100, count: 1).first ?? 0, 0.4, accuracy: 0.0001)
        // Once the file can move, the same merge succeeds.
        XCTAssertEqual(try store.merge(one.id, two.id).duration, 3, accuracy: 0.0001)
    }

    func testMergeSkipsEmptyAndMissingParts() async throws {
        let store = makeStore()
        let one = try await recorded(store, samples: 16_000, value: 0.2, order: 0)
        let two = try await recorded(store, samples: 16_000, value: 0.4, order: 1)
        try store.update(two.id) { $0.parts.append(MeetingAudioPart(fileName: "part-9.pcm", bytes: 0)) }
        let merged = try store.merge(one.id, two.id)
        XCTAssertEqual(merged.parts.count, 2)
        XCTAssertEqual(merged.duration, 2, accuracy: 0.0001)
    }

    func testWriterReopeningATornPartKeepsSamplesAligned() async throws {
        let directory = Stress.temporaryDirectory("torn")
        directories.append(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("part-1.pcm")
        try (PCM16.encode([0.25]) + Data([0x40])).write(to: url)
        let writer = try MeetingAudioWriter(url: url)
        writer.append([0.5, -0.5])
        try await writer.finish()
        XCTAssertEqual(try Data(contentsOf: url).count, 6)
        let samples = try MeetingAudio(urls: [url]).read(offset: 0, count: 3)
        XCTAssertEqual(samples[0], 0.25, accuracy: 0.0001)
        XCTAssertEqual(samples[1], 0.5, accuracy: 0.0001)
        XCTAssertEqual(samples[2], -0.5, accuracy: 0.0001)
    }

    // MARK: Two hours

    /// A two-hour meeting: 72,000 level frames, speech in bursts, three voices. Chunks stay in
    /// bounds and engine-sized, no loud frame is left out, and planning is quick.
    func testTwoHourChunkPlanCoversAllSpeechWithinBounds() {
        var rng = StressRNG(seed: 0x2_0000)
        let seconds = 7_200.0, frame = 0.1
        var levels = [Float](repeating: 0.001, count: Int(seconds / frame))
        var cursor = 0
        while cursor < levels.count {
            let burst = rng.int(5...400), pause = rng.int(1...80)
            for index in cursor..<min(levels.count, cursor + burst) { levels[index] = Float.random(in: 0.01...0.3, using: &rng) }
            cursor += burst + pause
        }
        var turns: [MeetingTurn] = []
        var start = 0.0
        while start < seconds {
            let length = Double(rng.int(1...300))
            turns.append(MeetingTurn(start: start, end: min(seconds, start + length), speaker: "S\(rng.int(1...3))"))
            start += length + Double(rng.int(0...3))
        }
        for useTurns in [false, true] {
            var chunks: [MeetingChunk] = []
            let elapsed = Stress.time {
                chunks = MeetingChunkPlanner.plan(turns: useTurns ? turns : [], levels: levels, from: 0, to: seconds)
            }
            XCTAssertLessThan(elapsed, 0.5, "planning two hours took \(elapsed) s")
            XCTAssertGreaterThan(chunks.count, 200)
            for chunk in chunks {
                XCTAssertGreaterThanOrEqual(chunk.start, 0)
                XCTAssertLessThanOrEqual(chunk.end, seconds)
                XCTAssertLessThanOrEqual(chunk.duration, 28 + 1e-6)
                XCTAssertGreaterThanOrEqual(chunk.duration, 0.3)
            }
            if !useTurns {
                for (a, b) in zip(chunks, chunks.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.start + 1e-9, "chunks overlap") }
            }
            // Every loud frame inside a turn (or anywhere, without turns) lies in some chunk.
            let speaking = useTurns ? turns : [MeetingTurn(start: 0, end: seconds, speaker: nil)]
            var missed = 0
            var chunkIndex = 0
            let sorted = chunks.sorted { $0.start < $1.start }
            for (index, level) in levels.enumerated() where level >= 0.004 {
                let time = (Double(index) + 0.5) * frame
                guard speaking.contains(where: { $0.start <= time && time < $0.end }) else { continue }
                while chunkIndex < sorted.count, sorted[chunkIndex].end < time - 30 { chunkIndex += 1 }
                if !sorted[chunkIndex...].prefix(64).contains(where: { $0.start - frame <= time && time <= $0.end + frame }) { missed += 1 }
            }
            XCTAssertEqual(missed, 0, "loud frames outside every chunk (turns: \(useTurns))")
        }
    }

    func testPlannerSurvivesDegenerateInput() {
        let cases: [(turns: [MeetingTurn], levels: [Float], from: Double, to: Double)] = [
            ([], [], 0, 7_200),
            ([], [Float](repeating: 0, count: 10), 0, 100),
            ([MeetingTurn(start: .nan, end: 5, speaker: "S1")], [0.1, 0.1], 0, 10),
            ([MeetingTurn(start: 50, end: 40, speaker: "S1")], [Float](repeating: 0.1, count: 1_000), 0, 100),
            ([MeetingTurn(start: -10, end: 1e9, speaker: nil)], [Float](repeating: 0.1, count: 100), 0, 10),
            ([], [Float](repeating: .nan, count: 500), 0, 50),
            ([], [Float](repeating: 0.1, count: 500), 30, 20),
        ]
        for input in cases {
            let chunks = MeetingChunkPlanner.plan(turns: input.turns, levels: input.levels, from: input.from, to: input.to)
            for chunk in chunks {
                XCTAssertTrue(chunk.start.isFinite && chunk.end.isFinite)
                XCTAssertLessThanOrEqual(chunk.duration, 28 + 1e-6)
                XCTAssertGreaterThanOrEqual(chunk.start, input.from)
                XCTAssertLessThanOrEqual(chunk.end, input.to)
            }
        }
        // No level profile: nothing is skipped as silence, two hours still plan into chunks.
        XCTAssertGreaterThanOrEqual(MeetingChunkPlanner.plan(turns: [], levels: [], from: 0, to: 7_200).count, 7_200 / 28)
    }

    /// Two hours of PCM16 (230 MB) as a sparse file: the level profile streams through it and
    /// reads at the far end work, without holding the recording in memory.
    func testTwoHourPartStreamsLevelsWithoutLoadingTheFile() throws {
        let directory = Stress.temporaryDirectory("twohours")
        directories.append(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("part-1.pcm")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let bytes: UInt64 = 2 * 3_600 * 16_000 * 2
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: bytes - 3_200)
        try handle.seekToEnd()
        try handle.write(contentsOf: PCM16.encode([Float](repeating: 0.5, count: 1_600)))
        try handle.close()
        let audio = try MeetingAudio(urls: [url])
        XCTAssertEqual(audio.duration, 7_200, accuracy: 0.001)
        XCTAssertEqual(try audio.read(offset: audio.sampleCount - 1, count: 10), [Float(Int16((0.5 * 32_767).rounded())) / 32_767])
        // The last ten minutes of levels; the full two hours runs under ZONE_STRESS=1.
        let window = Stress.enabled ? audio.sampleCount : 600 * 16_000
        let levels = try audio.levels(frameSamples: 1_600, from: audio.sampleCount - window)
        XCTAssertEqual(levels.count, window / 1_600)
        XCTAssertEqual(levels.last ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(levels.dropLast().max() ?? 1, 0)
    }
}
