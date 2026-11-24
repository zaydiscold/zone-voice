// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class MeetingSecondLookTests: XCTestCase {
    private let a: [Float] = [1, 0, 0, 0]
    private let b: [Float] = [0, 1, 0, 0]
    private let nobody: [Float] = [0, 0, 1, 0]

    /// Windows over `[from, to)` with a voice per window centre.
    private func embed(_ windows: [Range<Double>], _ voice: (Double) -> [Float]) -> [[Float]] {
        windows.map { voice(($0.lowerBound + $0.upperBound) / 2) }
    }

    // MARK: Windows

    func testWindowsSkipSilenceAndStepByHop() {
        var levels = [Float](repeating: 0, count: 200)
        for index in 0..<100 { levels[index] = 0.05 }
        let windows = MeetingSecondLook.windows(levels: levels, from: 0, to: 20)
        XCTAssertFalse(windows.isEmpty)
        XCTAssertTrue(windows.allSatisfy { $0.lowerBound < 10.5 }, "no window in the silent second half")
        XCTAssertEqual(windows[1].lowerBound - windows[0].lowerBound, 0.75, accuracy: 1e-9)
        XCTAssertTrue(windows.allSatisfy { $0.upperBound - $0.lowerBound <= 1.5 + 1e-9 })
    }

    func testWindowsStayInsideTheStretch() {
        let levels = [Float](repeating: 0.05, count: 600)
        let windows = MeetingSecondLook.windows(levels: levels, from: 30.05, to: 40)
        XCTAssertTrue(windows.allSatisfy { $0.lowerBound >= 30.05 && $0.upperBound <= 40 })
    }

    // MARK: Relabel

    func testFindsAChangeOfVoiceInsideOneFirstPassTurn() {
        let levels = [Float](repeating: 0.05, count: 100)
        let windows = MeetingSecondLook.windows(levels: levels, from: 0, to: 10)
        let turns = MeetingSecondLook.relabel(
            turns: [MeetingTurn(start: 0, end: 10, speaker: "S1")],
            windows: windows, embeddings: embed(windows) { $0 < 5 ? self.a : self.b },
            voices: ["S1": a, "S2": b], levels: levels, from: 0, to: 10)
        XCTAssertEqual(turns.map(\.speaker), ["S1", "S2"])
        XCTAssertEqual(turns[0].end, 5, accuracy: 0.35)
        XCTAssertEqual(turns[0].start, 0, accuracy: 1e-9)
        XCTAssertEqual(turns[1].end, 10, accuracy: 1e-9)
    }

    func testKeepsTheFirstPassWhenTheWindowsAgree() {
        let levels = [Float](repeating: 0.05, count: 100)
        let windows = MeetingSecondLook.windows(levels: levels, from: 0, to: 10)
        let first = [MeetingTurn(start: 0, end: 4, speaker: "S1"), MeetingTurn(start: 4, end: 10, speaker: "S2")]
        let turns = MeetingSecondLook.relabel(
            turns: first, windows: windows, embeddings: embed(windows) { $0 < 4 ? self.a : self.b },
            voices: ["S1": a, "S2": b], levels: levels, from: 0, to: 10)
        XCTAssertEqual(turns.map(\.speaker), ["S1", "S2"])
        XCTAssertEqual(turns[0].end, 4, accuracy: 0.25)
    }

    func testNamesAnAudibleStretchTheFirstPassMissedOnlyWhenItSoundsLikeSomeone() {
        let levels = [Float](repeating: 0.05, count: 200)
        let windows = MeetingSecondLook.windows(levels: levels, from: 0, to: 20)
        let first = [MeetingTurn(start: 0, end: 5, speaker: "S1"), MeetingTurn(start: 15, end: 20, speaker: "S2")]
        // 5...10 sounds like S2; 10...15 sounds like nobody known.
        let turns = MeetingSecondLook.relabel(
            turns: first, windows: windows,
            embeddings: embed(windows) { t in t < 5 ? self.a : t < 10 ? self.b : t < 15 ? self.nobody : self.b },
            voices: ["S1": a, "S2": b], levels: levels, from: 0, to: 20)
        func who(_ time: Double) -> String? { turns.first { $0.start <= time && $0.end > time }?.speaker }
        XCTAssertEqual(who(2), "S1")
        XCTAssertEqual(who(7.5), "S2")
        XCTAssertNil(who(12.5), "an unknown voice stays unlabeled for the planner")
        XCTAssertEqual(who(18), "S2")
    }

    func testSilenceIsNeverLabeled() {
        var levels = [Float](repeating: 0.05, count: 200)
        for index in 60..<140 { levels[index] = 0 }
        let windows = MeetingSecondLook.windows(levels: levels, from: 0, to: 20)
        let turns = MeetingSecondLook.relabel(
            turns: [MeetingTurn(start: 0, end: 5, speaker: "S1"), MeetingTurn(start: 15, end: 20, speaker: "S1")],
            windows: windows, embeddings: embed(windows) { _ in self.a },
            voices: ["S1": a], levels: levels, from: 0, to: 20)
        XCTAssertFalse(turns.contains { $0.start < 13 && $0.end > 7 })
    }

    func testReturnsTheFirstPassWhenAVoiceIsMissingOrSizesDisagree() {
        let levels = [Float](repeating: 0.05, count: 100)
        let windows = MeetingSecondLook.windows(levels: levels, from: 0, to: 10)
        let first = [MeetingTurn(start: 0, end: 10, speaker: "S1")]
        XCTAssertEqual(MeetingSecondLook.relabel(turns: first, windows: windows, embeddings: embed(windows) { _ in self.b },
                                                 voices: ["S2": b], levels: levels, from: 0, to: 10), first)
        XCTAssertEqual(MeetingSecondLook.relabel(turns: first, windows: windows, embeddings: [],
                                                 voices: ["S1": a], levels: levels, from: 0, to: 10), first)
        XCTAssertEqual(MeetingSecondLook.relabel(turns: first, windows: windows, embeddings: embed(windows) { _ in [1, 0] },
                                                 voices: ["S1": a], levels: levels, from: 0, to: 10), first)
    }

    func testTurnsNeverOverlapAndStayInsideTheStretch() {
        var levels = [Float](repeating: 0.05, count: 1_200)
        for index in stride(from: 0, to: 1_200, by: 37) { levels[index] = 0 }
        let windows = MeetingSecondLook.windows(levels: levels, from: 12.34, to: 118.7)
        let turns = MeetingSecondLook.relabel(
            turns: [MeetingTurn(start: 12.34, end: 60, speaker: "S1"), MeetingTurn(start: 60, end: 118.7, speaker: "S2")],
            windows: windows, embeddings: embed(windows) { Int($0 / 3) % 3 == 0 ? self.b : self.a },
            voices: ["S1": a, "S2": b], levels: levels, from: 12.34, to: 118.7)
        XCTAssertFalse(turns.isEmpty)
        XCTAssertTrue(turns.allSatisfy { $0.start >= 12.34 - 1e-9 && $0.end <= 118.7 + 1e-9 && $0.end > $0.start })
        for (x, y) in zip(turns, turns.dropFirst()) { XCTAssertLessThanOrEqual(x.end, y.start + 1e-9) }
    }

    // MARK: Snap and absorb

    func testAChangeOfSpeakerMovesToTheQuietestNearbyFrame() {
        var levels = [Float](repeating: 0.05, count: 100)
        levels[52] = 0.001
        let snapped = MeetingSecondLook.snap(
            [MeetingTurn(start: 0, end: 5.1, speaker: "S1"), MeetingTurn(start: 5.1, end: 10, speaker: "S2")],
            levels: levels, parameters: .init())
        XCTAssertEqual(snapped[0].end, 5.25, accuracy: 1e-9)
        XCTAssertEqual(snapped[1].start, 5.25, accuracy: 1e-9)
        // Same voice, or a pause between: left alone.
        let apart = [MeetingTurn(start: 0, end: 5.1, speaker: "S1"), MeetingTurn(start: 6, end: 10, speaker: "S2")]
        XCTAssertEqual(MeetingSecondLook.snap(apart, levels: levels, parameters: .init()), apart)
    }

    func testAShortTurnBetweenTwoOthersJoinsTheLongerOne() {
        let turns = [MeetingTurn(start: 0, end: 3, speaker: "S1"),
                     MeetingTurn(start: 3, end: 3.2, speaker: "S2"),
                     MeetingTurn(start: 3.2, end: 10, speaker: "S1")]
        XCTAssertEqual(MeetingSecondLook.absorbShort(turns, shortest: 0.5), [MeetingTurn(start: 0, end: 10, speaker: "S1")])
        let alone = [MeetingTurn(start: 0, end: 3, speaker: "S1"), MeetingTurn(start: 5, end: 5.2, speaker: "S2")]
        XCTAssertEqual(MeetingSecondLook.absorbShort(alone, shortest: 0.5), alone, "an isolated short turn keeps its padding in the planner")
    }

    // MARK: Voices

    func testVoiceMatchingIsOneToOneAndNeedsTheThreshold() {
        let near: [Float] = [0.95, 0.31, 0, 0]
        let matches = MeetingVoices.match(["x": a, "y": near, "z": nobody], to: ["S1": a, "S2": b])
        XCTAssertEqual(matches, ["x": "S1"], "y also resembles S1 but S1 is taken by the closer x; z resembles no one")
        XCTAssertEqual(MeetingVoices.match(["y": near], to: ["S1": a]), ["y": "S1"])
        XCTAssertEqual(MeetingVoices.similarity(a, [1, 0]), -1)
    }

    func testNormalizeKeepsAKnownVoiceUnderItsIdAndStoresNewVoices() {
        let existing = [MeetingSpeaker(id: "S1", name: "Jonathan", voice: a), MeetingSpeaker(id: "S2", isMe: true, voice: b)]
        let raw = [MeetingTurn(start: 0, end: 2, speaker: "S1"), MeetingTurn(start: 2, end: 4, speaker: "S2"),
                   MeetingTurn(start: 4, end: 6, speaker: "S3")]
        let result = MeetingSpeakerLabels.normalize(raw, existing: existing, voices: ["S1": b, "S2": a, "S3": nobody])
        XCTAssertEqual(result.turns.map(\.speaker), ["S2", "S1", "S3"])
        XCTAssertEqual(result.speakers.map(\.id), ["S1", "S2", "S3"])
        XCTAssertEqual(result.speakers[2].voice, nobody)
        XCTAssertEqual(result.speakers[0].name, "Jonathan")
    }

    func testMeetingsSavedWithoutVoicesStillDecode() throws {
        let json = #"{"id":"S1","name":"Kim","isMe":false}"#
        let speaker = try JSONDecoder().decode(MeetingSpeaker.self, from: Data(json.utf8))
        XCTAssertNil(speaker.voice)
        XCTAssertEqual(speaker.name, "Kim")
    }

    func testTranscribeAgainKeepsNamedVoicesOnly() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("second-look-" + UUID().uuidString)
        directories.append(url)
        let store = MeetingStore(directory: url)
        let meeting = try await transcribed(store, at: Date(timeIntervalSince1970: 1_800_000_000), speakers: [
            MeetingSpeaker(id: "S1", name: "Jonathan", voice: a), MeetingSpeaker(id: "S2", isMe: true, voice: b),
            MeetingSpeaker(id: "S3", voice: nobody), MeetingSpeaker(id: "S4", name: "Kim")])
        try store.resetTranscript(meeting.id, expectedSpeakerCount: 2)
        let reset = try store.meeting(meeting.id)
        XCTAssertEqual(reset.speakers.map(\.id), ["S1", "S2"], "unnamed voices and names without a print go")
        // The fresh pass hears the two again in the other order and gives back their names.
        let fresh = MeetingSpeakerLabels.normalize([MeetingTurn(start: 0, end: 1, speaker: "S1"), MeetingTurn(start: 1, end: 2, speaker: "S2")],
                                                   existing: reset.speakers, voices: ["S1": b, "S2": a])
        XCTAssertEqual(fresh.turns.compactMap(\.speaker), ["S2", "S1"])
        XCTAssertEqual(fresh.speakers.count, 2)
    }

    // MARK: Planner

    func testChunksOfDifferentVoicesNeverOverlap() {
        let levels = [Float](repeating: 0.05, count: 300)
        for turns in [
            [MeetingTurn(start: 1, end: 5, speaker: "S1"), MeetingTurn(start: 5, end: 9, speaker: "S2")],
            [MeetingTurn(start: 1, end: 5, speaker: "S1"), MeetingTurn(start: 5.2, end: 9, speaker: "S2")],
            [MeetingTurn(start: 1, end: 5, speaker: "S1"), MeetingTurn(start: 5.5, end: 9, speaker: "S2")],
        ] {
            let chunks = MeetingChunkPlanner.plan(turns: turns, levels: levels, from: 0, to: 30)
            let labeled = chunks.filter { $0.speaker != nil }
            XCTAssertEqual(labeled.map(\.speaker), ["S1", "S2"])
            XCTAssertLessThanOrEqual(labeled[0].end, labeled[1].start + 1e-9)
            XCTAssertEqual(labeled[0].start, 0.85, accuracy: 1e-9, "padding is kept away from another voice")
            XCTAssertEqual(labeled[1].end, 9.15, accuracy: 1e-9)
        }
        let wide = MeetingChunkPlanner.plan(turns: [MeetingTurn(start: 1, end: 5, speaker: "S1"),
                                                    MeetingTurn(start: 5.5, end: 9, speaker: "S2")],
                                            levels: levels, from: 0, to: 30).filter { $0.speaker != nil }
        XCTAssertEqual(wide[0].end, 5.15, accuracy: 1e-9, "a pause wider than both paddings keeps full padding")
        XCTAssertEqual(wide[1].start, 5.35, accuracy: 1e-9)
    }

    // MARK: Merge

    private var directories: [URL] = []

    override func tearDown() {
        for url in directories { try? FileManager.default.removeItem(at: url) }
        directories = []
        super.tearDown()
    }

    private func transcribed(_ store: MeetingStore, at date: Date, speakers: [MeetingSpeaker]) async throws -> Meeting {
        let (meeting, writer) = try store.beginRecording(now: date)
        writer.append([Float](repeating: 0.1, count: 32_000))
        try await writer.finish()
        _ = try store.finishRecording(meeting.id, now: date)
        return try store.update(meeting.id) { meeting in
            meeting.speakers = speakers
            meeting.segments = speakers.enumerated().map {
                MeetingSegment(start: Double($0.offset), end: Double($0.offset) + 0.5, speaker: $0.element.id, text: "hi")
            }
            meeting.transcribedThrough = meeting.duration
            meeting.status = .done
        }
    }

    func testMergeFindsTheSamePersonByVoice() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("second-look-" + UUID().uuidString)
        directories.append(url)
        let store = MeetingStore(directory: url)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try await transcribed(store, at: start, speakers: [
            MeetingSpeaker(id: "S1", name: "Jonathan", voice: a), MeetingSpeaker(id: "S2", isMe: true, voice: b)])
        let second = try await transcribed(store, at: start.addingTimeInterval(600), speakers: [
            MeetingSpeaker(id: "S1", voice: b), MeetingSpeaker(id: "S2", voice: a), MeetingSpeaker(id: "S3", voice: nobody)])
        let merged = try store.merge(first.id, second.id)
        XCTAssertEqual(merged.people.map(\.id), ["S1", "S2", "S5"])
        XCTAssertEqual(merged.segments.map { merged.person($0.speaker) }, ["S1", "S2", "S2", "S1", "S5"])
        XCTAssertNil(merged.message, "with both earlier people matched, the third voice is simply someone new")

        // Names someone typed win: two differently named people are never joined by voice.
        let third = try await transcribed(store, at: start.addingTimeInterval(1_200), speakers: [
            MeetingSpeaker(id: "S1", name: "Priya", voice: a)])
        let again = try store.merge(merged.id, third.id)
        XCTAssertEqual(again.people.count, 4)
        XCTAssertEqual(again.people.last?.name, "Priya")

        // A name given only in the later part carries over to the matched earlier speaker.
        let fourth = try await transcribed(store, at: start.addingTimeInterval(1_800), speakers: [
            MeetingSpeaker(id: "S1", name: "Sam", voice: nobody)])
        let last = try store.merge(again.id, fourth.id)
        XCTAssertEqual(last.people.count, 4)
        XCTAssertEqual(last.people.first { $0.id == "S5" }?.name, "Sam")
    }
}
