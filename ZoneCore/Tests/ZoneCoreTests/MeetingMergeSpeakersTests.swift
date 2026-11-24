// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// Zayd, 2026-11-20: a meeting with one other person was stopped, started again and the two
/// recordings merged. The second recording's two people came in as Speaker 3 and Speaker 4, and
/// marking Speaker 3 as "me" took "me" away from Speaker 1.
final class MeetingMergeSpeakersTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for url in directories { try? FileManager.default.removeItem(at: url) }
        directories = []
        super.tearDown()
    }

    private func makeStore() -> MeetingStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("merge-speakers-" + UUID().uuidString)
        directories.append(url)
        return MeetingStore(directory: url)
    }

    /// A voice print pointing mostly along `axis`, with a little of `lean` so two recordings of
    /// one person are close but not identical.
    static func voice(_ axis: Int, lean: Int = 200, by amount: Float = 0) -> [Float] {
        var print = [Float](repeating: 0, count: 256)
        print[axis] = 1
        print[lean] = amount
        return print
    }

    /// A finished two-person meeting: `first` speaks, then `second`, each twice. Voice prints go
    /// in through the saved file, as the speaker model leaves them.
    private func twoPersonMeeting(_ store: MeetingStore, at date: Date, voices: [(id: String, print: [Float]?)],
                                  words: [String]) async throws -> Meeting {
        let (meeting, writer) = try store.beginRecording(now: date)
        // Twenty seconds, a second at a time as the microphone delivers it (the writer holds at
        // most thirty seconds it has not written yet and drops the rest).
        for _ in 0..<20 { writer.append([Float](repeating: 0.25, count: 16_000)) }
        try await writer.finish()
        XCTAssertEqual(try store.finishRecording(meeting.id, now: date).duration, 20, accuracy: 0.001)
        try store.update(meeting.id, now: date) { meeting in
            meeting.speakers = voices.map { MeetingSpeaker(id: $0.id) }
            meeting.segments = (0..<4).map { index in
                MeetingSegment(start: Double(index) * 5, end: Double(index) * 5 + 4.5,
                               speaker: voices[index % 2].id, text: words[index % 2] + " \(index)")
            }
            meeting.transcribedThrough = 20
            meeting.progress = 1
            meeting.status = .done
        }
        let url = store.folder(meeting.id).appendingPathComponent("meeting.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var speakers = try XCTUnwrap(json["speakers"] as? [[String: Any]])
        for index in speakers.indices {
            if let print = voices[index].print { speakers[index]["voice"] = print.map(Double.init) }
        }
        json["speakers"] = speakers
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return try store.meeting(meeting.id)
    }

    /// The names the transcript shows, in order of first appearance.
    private func namesShown(_ meeting: Meeting) -> [String] {
        var seen: [String] = []
        for paragraph in MeetingExport.paragraphs(meeting) {
            guard let name = meeting.speakerName(paragraph.speaker), !seen.contains(name) else { continue }
            seen.append(name)
        }
        return seen
    }

    func testMergingTwoRecordingsOfTheSameTwoPeopleKeepsTwoSpeakers() async throws {
        let store = makeStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        // The second recording's speaker model heard the other person first, so its numbers are
        // the other way round: only the voices say who is who.
        let first = try await twoPersonMeeting(store, at: start, voices: [("S1", Self.voice(0)), ("S2", Self.voice(1))],
                                               words: ["zayd", "riju"])
        let second = try await twoPersonMeeting(store, at: start.addingTimeInterval(600),
                                                voices: [("S1", Self.voice(1, by: 0.3)), ("S2", Self.voice(0, by: 0.3))],
                                                words: ["riju", "zayd"])

        let merged = try store.merge(first.id, second.id)

        XCTAssertEqual(namesShown(merged), ["Speaker 1", "Speaker 2"], "the same two people are two speakers, not four")
        for paragraph in MeetingExport.paragraphs(merged) {
            let expected = paragraph.text.hasPrefix("zayd") ? "Speaker 1" : "Speaker 2"
            XCTAssertEqual(merged.speakerName(paragraph.speaker), expected, "\(paragraph.text) is under the wrong person")
        }
        let text = MeetingExport.text(merged)
        XCTAssertFalse(text.contains("Speaker 3") || text.contains("Speaker 4"), text)
    }

    func testMarkingASecondSpeakerAsMeNeverTakesMeFromTheFirst() async throws {
        let store = makeStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        // No voice prints, as on meetings recorded before prints were kept: four speakers.
        let first = try await twoPersonMeeting(store, at: start, voices: [("S1", nil), ("S2", nil)], words: ["zayd", "riju"])
        let second = try await twoPersonMeeting(store, at: start.addingTimeInterval(600), voices: [("S1", nil), ("S2", nil)],
                                                words: ["zayd", "riju"])
        try store.setMe(first.id, speaker: "S1")
        let merged = try store.merge(first.id, second.id)
        XCTAssertEqual(merged.speakerName("S1"), "Me")
        XCTAssertEqual(merged.speakerName("S3"), "Speaker 3")

        try store.setMe(merged.id, speaker: "S3")

        let after = try store.meeting(merged.id)
        XCTAssertEqual(after.speakerName("S1"), "Me", "Speaker 1 was me and still is")
        XCTAssertEqual(after.speakerName("S3"), "Me", "Speaker 3 is the same person")
        for paragraph in MeetingExport.paragraphs(after) where paragraph.text.hasPrefix("zayd") {
            XCTAssertEqual(after.speakerName(paragraph.speaker), "Me")
        }
        XCTAssertEqual(namesShown(after), ["Me", "Speaker 2", "Speaker 3"], "one person fewer, numbered with no hole")
    }

    // MARK: Recordings labeled before voice prints were kept

    /// The app listens to each voice (`MeetingVoiceMatch.spans`) and hands the prints back.
    private func fillPrints(_ store: MeetingStore, _ id: UUID, _ prints: [String: [Float]]) throws -> Meeting {
        try store.update(id) { meeting in
            for index in meeting.speakers.indices where meeting.speakers[index].voice == nil {
                meeting.speakers[index].voice = prints[meeting.speakers[index].id]
            }
        }
    }

    func testRecordingsWithoutPrintsWaitToBeListenedToThenBecomeTwoPeople() async throws {
        let store = makeStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try await twoPersonMeeting(store, at: start, voices: [("S1", nil), ("S2", nil)], words: ["zayd", "riju"])
        let second = try await twoPersonMeeting(store, at: start.addingTimeInterval(600), voices: [("S1", nil), ("S2", nil)],
                                                words: ["riju", "zayd"])
        try store.setMe(first.id, speaker: "S1")
        try store.renameSpeaker(first.id, speaker: "S2", to: "Riju")

        let merged = try store.merge(first.id, second.id)
        XCTAssertEqual(merged.status, .done, "the merged transcript reads at once")
        XCTAssertEqual(merged.speakerGroupsToMatch, [["S3", "S4"]], "the later recording's voices wait to be compared")
        XCTAssertEqual(Set(MeetingVoiceMatch.voicesNeedingPrints(in: merged)), ["S1", "S2", "S3", "S4"])
        XCTAssertNil(merged.message)
        // Reopened from disk (Zone closed in the middle), the list is still there.
        XCTAssertEqual(try MeetingStore(directory: store.directory).meeting(merged.id).speakerGroupsToMatch, [["S3", "S4"]])

        _ = try fillPrints(store, merged.id, ["S1": Self.voice(0), "S2": Self.voice(1),
                                              "S3": Self.voice(1, by: 0.3), "S4": Self.voice(0, by: 0.3)])
        var outcome = MeetingVoiceMatch.Outcome()
        let matched = try store.update(merged.id) { outcome = MeetingVoiceMatch.resolve(&$0) }

        XCTAssertEqual(outcome.joined, ["S3": "S2", "S4": "S1"])
        XCTAssertTrue(outcome.unmatched.isEmpty)
        XCTAssertNil(matched.speakerGroupsToMatch)
        XCTAssertEqual(namesShown(matched), ["Me", "Riju"], "names from the first recording carry over")
        for paragraph in MeetingExport.paragraphs(matched) {
            XCTAssertEqual(matched.speakerName(paragraph.speaker), paragraph.text.hasPrefix("zayd") ? "Me" : "Riju")
        }
        // The lines themselves are untouched: the later voices keep their own ids.
        XCTAssertEqual(matched.segments.map(\.speaker), ["S1", "S2", "S1", "S2", "S3", "S4", "S3", "S4"])
        XCTAssertEqual(matched.segments.map(\.text), merged.segments.map(\.text))
    }

    func testWhatGoesToTheComputerAndToCopyUsesTheJoinedNames() async throws {
        let store = makeStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try await twoPersonMeeting(store, at: start, voices: [("S1", Self.voice(0)), ("S2", Self.voice(1))],
                                               words: ["zayd", "riju"])
        let second = try await twoPersonMeeting(store, at: start.addingTimeInterval(600),
                                                voices: [("S1", Self.voice(1, by: 0.3)), ("S2", Self.voice(0, by: 0.3))],
                                                words: ["riju", "zayd"])
        try store.setMe(first.id, speaker: "S1")
        try store.renameSpeaker(second.id, speaker: "S1", to: "Riju")
        let merged = try store.merge(first.id, second.id)

        // A name typed only in the later recording reaches the earlier person it matched.
        XCTAssertEqual(namesShown(merged), ["Me", "Riju"])
        let item = try XCTUnwrap(LinkEncoding.item(merged))
        let sent = try XCTUnwrap(item.text)
        let lines = sent.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 8)
        for line in lines {
            XCTAssertTrue(line.hasPrefix(line.contains("zayd") ? "Me: " : "Riju: "), line)
        }
        XCTAssertFalse(sent.contains("Speaker"), sent)
        let shared = MeetingExport.text(merged)
        XCTAssertFalse(shared.contains("Speaker"), shared)
        let package = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zonebackup")
        directories.append(package)
        let snapshot = LibraryBackup(notes: [], dictations: [], meetings: try store.backupMeetings())
        try LibraryBackupFiles.write(snapshot, to: package, meetingDirectory: store.directory)
        let backup = try LibraryBackupFiles.read(package)
        let restored = makeStore()
        XCTAssertEqual(try LibraryBackupFiles.restoreMeetings(backup, from: package, into: restored), 1)
        XCTAssertEqual(try restored.meeting(merged.id).speakers, merged.speakers)
        XCTAssertEqual(try restored.meeting(merged.id).segments, merged.segments)
        XCTAssertEqual(try restored.audio(merged.id).duration, merged.duration, accuracy: 0.001)
        let wire = String(decoding: try JSONEncoder().encode(item), as: UTF8.self)
        XCTAssertFalse(wire.contains("sameAs"))
        XCTAssertFalse(wire.contains("\"voice\""))
    }

    func testVoicesThatAreNotCloseEnoughStaySeparateAndAreOfferedInstead() async throws {
        let store = makeStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        // Zayd matches. The other voice is at 0.6: more alike than strangers, not enough to join.
        var unsure = Self.voice(1)
        unsure[201] = 1.333
        let first = try await twoPersonMeeting(store, at: start, voices: [("S1", Self.voice(0)), ("S2", Self.voice(1))],
                                               words: ["zayd", "riju"])
        let second = try await twoPersonMeeting(store, at: start.addingTimeInterval(600),
                                                voices: [("S1", Self.voice(0, by: 0.3)), ("S2", unsure)], words: ["zayd", "riju"])
        let merged = try store.merge(first.id, second.id)

        XCTAssertEqual(merged.person("S3"), "S1")
        XCTAssertEqual(merged.person("S4"), "S4", "below \(MeetingVoices.sameVoice) nothing is joined on its own")
        XCTAssertEqual(namesShown(merged), ["Speaker 1", "Speaker 2", "Speaker 3"])
        XCTAssertEqual(merged.message, MeetingVoiceMatch.unmatchedMessage)
        XCTAssertEqual(MeetingVoiceMatch.closest(to: "S4", in: merged).first?.person, "S2", "the Speakers screen offers the closest voice")
        XCTAssertEqual(try XCTUnwrap(MeetingVoiceMatch.closest(to: "S4", in: merged).first).similarity, 0.6, accuracy: 0.01)

        let joined = try store.joinSpeakers(merged.id, speaker: "S4", into: "S2")
        XCTAssertEqual(namesShown(joined), ["Speaker 1", "Speaker 2"])
    }

    func testTwoPeopleSomeoneNamedDifferentlyAreNeverJoinedByVoice() async throws {
        let store = makeStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try await twoPersonMeeting(store, at: start, voices: [("S1", Self.voice(0)), ("S2", Self.voice(1))],
                                               words: ["zayd", "riju"])
        let second = try await twoPersonMeeting(store, at: start.addingTimeInterval(600),
                                                voices: [("S1", Self.voice(0, by: 0.1)), ("S2", Self.voice(1, by: 0.1))],
                                                words: ["zayd", "riju"])
        try store.renameSpeaker(first.id, speaker: "S2", to: "Riju")
        try store.renameSpeaker(second.id, speaker: "S2", to: "Raj")
        let merged = try store.merge(first.id, second.id)
        XCTAssertEqual(namesShown(merged), ["Speaker 1", "Riju", "Raj"], "typed names win over the model")
    }

    // MARK: Changing who is who

    func testAWrongJoinCanBeSeparatedAndEveryChangeUndone() async throws {
        let store = makeStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try await twoPersonMeeting(store, at: start, voices: [("S1", Self.voice(0)), ("S2", Self.voice(1))],
                                               words: ["zayd", "riju"])
        let second = try await twoPersonMeeting(store, at: start.addingTimeInterval(600),
                                                voices: [("S1", Self.voice(0, by: 0.3)), ("S2", Self.voice(1, by: 0.3))],
                                                words: ["zayd", "riju"])
        let merged = try store.merge(first.id, second.id)
        XCTAssertEqual(merged.voices(of: "S1").map(\.id), ["S1", "S3"])

        let separated = try store.separateSpeaker(merged.id, speaker: "S3")
        XCTAssertEqual(namesShown(separated), ["Speaker 1", "Speaker 2", "Speaker 3"])
        XCTAssertEqual(separated.speakerName("S4"), "Speaker 2", "the other join is untouched")

        let undone = try store.restoreSpeakers(merged.id, to: merged.speakers)
        XCTAssertEqual(namesShown(undone), ["Speaker 1", "Speaker 2"])

        // Naming through a joined voice names the person; the name survives a separate on them.
        let named = try store.renameSpeaker(merged.id, speaker: "S3", to: " Zayd ")
        XCTAssertEqual(named.speakerName("S1"), "Zayd")
        XCTAssertEqual(named.people.map(\.name), ["Zayd", nil])

        // After Transcribe again the voices are different ones: an old Undo does nothing.
        try store.resetTranscript(merged.id)
        let reset = try store.meeting(merged.id)
        XCTAssertEqual(reset.speakers.map(\.id), ["S1"], "only the named person is kept for the new pass, with no joined voices")
        XCTAssertEqual(try store.restoreSpeakers(merged.id, to: merged.speakers).speakers, reset.speakers)
    }

    func testMovingMeIsItsOwnChoiceAndClearingItNeverJoins() async throws {
        let store = makeStore()
        let first = try await twoPersonMeeting(store, at: Date(timeIntervalSince1970: 1_800_000_000),
                                               voices: [("S1", nil), ("S2", nil)], words: ["zayd", "riju"])
        try store.setMe(first.id, speaker: "S1")
        let moved = try store.moveMe(first.id, to: "S2")
        XCTAssertEqual(moved.people.map(\.isMe), [false, true])
        XCTAssertEqual(moved.people.count, 2, "moving joins nobody")
        let cleared = try store.setMe(first.id, speaker: nil)
        XCTAssertEqual(cleared.people.map(\.isMe), [false, false])
        // Me set again on the person who already is: nothing changes.
        try store.setMe(first.id, speaker: "S2")
        XCTAssertEqual(try store.setMe(first.id, speaker: "S2").people.map(\.isMe), [false, true])
    }

    func testAThirdRecordingIsComparedWithEveryoneBeforeIt() async throws {
        let store = makeStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let one = try await twoPersonMeeting(store, at: start, voices: [("S1", Self.voice(0)), ("S2", Self.voice(1))], words: ["zayd", "riju"])
        let two = try await twoPersonMeeting(store, at: start.addingTimeInterval(600),
                                             voices: [("S1", Self.voice(1, by: 0.2)), ("S2", Self.voice(2))], words: ["riju", "dana"])
        let three = try await twoPersonMeeting(store, at: start.addingTimeInterval(1_200),
                                               voices: [("S1", Self.voice(2, by: 0.2)), ("S2", Self.voice(0, by: 0.2))], words: ["dana", "zayd"])
        let both = try store.merge(one.id, two.id)
        XCTAssertEqual(namesShown(both), ["Speaker 1", "Speaker 2", "Speaker 3"])
        let all = try store.merge(both.id, three.id)
        XCTAssertEqual(all.people.count, 3)
        for paragraph in MeetingExport.paragraphs(all) {
            let expected = ["zayd": "Speaker 1", "riju": "Speaker 2", "dana": "Speaker 3"][String(paragraph.text.prefix(4))]
            XCTAssertEqual(all.speakerName(paragraph.speaker), expected, paragraph.text)
        }
    }

    func testAppendingAMatchedRecordingKeepsTheEarlierVoiceReview() async throws {
        let store = makeStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try await twoPersonMeeting(store, at: start,
            voices: [("S1", Self.voice(0)), ("S2", Self.voice(1))], words: ["a", "b"])
        let second = try await twoPersonMeeting(store, at: start.addingTimeInterval(600),
            voices: [("S1", Self.voice(2)), ("S2", Self.voice(3))], words: ["c", "d"])
        let third = try await twoPersonMeeting(store, at: start.addingTimeInterval(1_200),
            voices: [("S1", Self.voice(0)), ("S2", Self.voice(1))], words: ["a", "b"])

        let both = try store.merge(first.id, second.id)
        let originalPairs = Set(MeetingVoiceMatch.reviewPairs(in: both))
        XCTAssertEqual(originalPairs.count, 4)
        _ = try store.merge(both.id, third.id)
        let reopened = try store.meeting(both.id)
        XCTAssertEqual(Set(MeetingVoiceMatch.reviewPairs(in: reopened)), originalPairs)
        XCTAssertEqual(reopened.visibleMessage, MeetingVoiceMatch.unmatchedMessage)
    }

    func testPrependingARecordingRemapsBothSidesOfDeferredVoiceReview() async throws {
        let store = makeStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try await twoPersonMeeting(store, at: start,
            voices: [("S1", Self.voice(0)), ("S2", Self.voice(1))], words: ["a", "b"])
        let second = try await twoPersonMeeting(store, at: start.addingTimeInterval(600),
            voices: [("S1", Self.voice(2)), ("S2", Self.voice(3))], words: ["c", "d"])
        let third = try await twoPersonMeeting(store, at: start.addingTimeInterval(1_200),
            voices: [("S1", Self.voice(4)), ("S2", Self.voice(5))], words: ["e", "f"])

        let both = try store.merge(second.id, third.id)
        XCTAssertEqual(MeetingVoiceMatch.reviewPairs(in: both).count, 4)
        let queued = try store.merge(first.id, both.id, queueVoiceMatch: true)
        let inherited = Set(["S5", "S6"].flatMap { from in
            ["S3", "S4"].map { MeetingVoiceMatch.ReviewPair(from: from, to: $0) }
        })
        XCTAssertEqual(Set(MeetingVoiceMatch.reviewPairs(in: queued)), inherited)
        _ = try store.update(queued.id) { meeting in MeetingVoiceMatch.resolve(&meeting) }
        let reopened = try store.meeting(queued.id)
        let pairs = Set(MeetingVoiceMatch.reviewPairs(in: reopened))
        XCTAssertTrue(inherited.isSubset(of: pairs))
        XCTAssertTrue(pairs.contains(.init(from: "S5", to: "S1")))
        XCTAssertEqual(reopened.visibleMessage, MeetingVoiceMatch.unmatchedMessage)
    }

    func testRetryReplacesComparisonsWhenASiblingHasTakenAnEarlierSpeaker() {
        var meeting = Meeting(title: "Meeting", createdAt: Date())
        meeting.speakers = ["A", "B", "C", "D"].map { MeetingSpeaker(id: $0) }
        meeting.speakerGroupsToMatch = [["C", "D"]]
        MeetingVoiceMatch.resolve(&meeting)
        XCTAssertEqual(meeting.voiceReviewCandidates?["D"], ["A", "B"])

        for (index, axis) in [0, 1, 0, 2].enumerated() { meeting.speakers[index].voice = Self.voice(axis) }
        meeting.speakerGroupsToMatch = [["C", "D"]]
        MeetingVoiceMatch.resolve(&meeting)
        XCTAssertEqual(meeting.person("C"), "A")
        XCTAssertEqual(meeting.voiceReviewCandidates, ["D": ["B"]])
    }

    func testInheritedReviewFollowsBothPeopleThroughAutomaticJoins() {
        var meeting = Meeting(title: "Meeting", createdAt: Date())
        for (id, axis) in [("A", 0), ("B", 1), ("C", 3), ("D", 0)] {
            meeting.speakers.append(MeetingSpeaker(id: id, voice: Self.voice(axis)))
        }
        meeting.voiceReviewCandidates = ["D": ["C"]]
        meeting.speakerGroupsToMatch = [["C", "D"]]
        MeetingVoiceMatch.resolve(&meeting)
        XCTAssertEqual(meeting.person("D"), "A")
        XCTAssertEqual(Set(MeetingVoiceMatch.reviewPairs(in: meeting)),
                       [.init(from: "C", to: "A"), .init(from: "C", to: "B")])
    }

    func testVoiceReviewCannotJoinConflictingNamesThroughAnUnnamedSpeaker() throws {
        var meeting = Meeting(title: "Meeting", createdAt: Date())
        meeting.speakers = [
            MeetingSpeaker(id: "A", name: "Ali", voice: Self.voice(0)),
            MeetingSpeaker(id: "B", voice: Self.voice(0)),
            MeetingSpeaker(id: "C", name: "Bea", voice: Self.voice(0))
        ]
        meeting.voiceReviewCandidates = ["B": ["A"], "C": ["B"]]
        let choices = Set(MeetingVoiceMatch.reviewPairs(in: meeting))
        XCTAssertEqual(choices.count, 2, "either individual choice is possible")
        XCTAssertNil(MeetingVoiceMatch.reviewedSpeakers(for: choices, in: meeting))
        XCTAssertEqual(MeetingVoiceMatch.suggestedPairs(in: meeting).count, 1)

        meeting.speakers[2].name = "Ali"
        XCTAssertEqual(MeetingVoiceMatch.suggestedPairs(in: meeting), choices)
        meeting.speakers = try XCTUnwrap(MeetingVoiceMatch.reviewedSpeakers(for: choices, in: meeting))
        XCTAssertEqual(meeting.people.compactMap(\.name), ["Ali"])
    }

    func testMergingMeetingsPreservesConflictingNamesMarkedMe() async throws {
        let store = makeStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try await twoPersonMeeting(store, at: start,
            voices: [("S1", Self.voice(0)), ("S2", Self.voice(1))], words: ["Ali", "other"])
        let second = try await twoPersonMeeting(store, at: start.addingTimeInterval(600),
            voices: [("S1", Self.voice(0)), ("S2", Self.voice(1))], words: ["Bea", "other"])
        for (recording, name) in [(first, "Ali"), (second, "Bea")] {
            try store.renameSpeaker(recording.id, speaker: "S1", to: name)
            try store.setMe(recording.id, speaker: "S1")
        }

        let merged = try store.merge(second.id, first.id)
        XCTAssertEqual(merged.people.filter(\.isMe).map(\.id), ["S1"])
        XCTAssertEqual(merged.people.compactMap(\.name), ["Ali", "Bea"])
        XCTAssertEqual(merged.person("S3"), "S3")
        XCTAssertEqual(merged.speakerName("S3"), "Bea")
    }

    func testALaterRecordingStillToBeTranscribedBringsOnlyItsNamedPeople() async throws {
        let store = makeStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try await twoPersonMeeting(store, at: start, voices: [("S1", Self.voice(0)), ("S2", Self.voice(1))], words: ["zayd", "riju"])
        let second = try await twoPersonMeeting(store, at: start.addingTimeInterval(600),
                                                voices: [("S1", Self.voice(2)), ("S2", Self.voice(3))], words: ["dana", "sam"])
        try store.renameSpeaker(second.id, speaker: "S1", to: "Dana")
        // Its transcript stopped half way: the merge redoes it, and the redone stretch finds people by voice.
        try store.update(second.id) { $0.transcribedThrough = 10; $0.status = .recorded }
        let merged = try store.merge(first.id, second.id)
        XCTAssertEqual(merged.status, .recorded)
        XCTAssertEqual(merged.people.map { merged.speakerName($0.id) }, ["Speaker 1", "Speaker 2", "Dana"])
        XCTAssertNil(merged.speakerGroupsToMatch)
        XCTAssertEqual(merged.segments.count, 4, "only the finished earlier transcript is kept")
    }

    func testTheStretchesListenedToAreAVoicesLongestLines() {
        var segments = [MeetingSegment(start: 0, end: 1, speaker: "S1", text: "yeah"),
                        MeetingSegment(start: 2, end: 30, speaker: "S1", text: "a long one"),
                        MeetingSegment(start: 31, end: 36, speaker: "S1", text: "a middling one"),
                        MeetingSegment(start: 40, end: 60, speaker: "S2", text: "someone else")]
        let spans = MeetingVoiceMatch.spans(forVoice: "S1", in: segments)
        XCTAssertEqual(spans, [11..<21, 31..<36], "the middle ten seconds of a long line; a one second yeah is left out")
        segments = (0..<20).map { MeetingSegment(start: Double($0) * 10, end: Double($0) * 10 + 2 + Double($0 % 5), speaker: "S1", text: "x") }
        let many = MeetingVoiceMatch.spans(forVoice: "S1", in: segments)
        XCTAssertEqual(many.count, MeetingVoiceMatch.printSpans)
        XCTAssertTrue(many.allSatisfy { $0.upperBound - $0.lowerBound >= 5 }, "the longest eight")
        XCTAssertEqual(many, many.sorted { $0.lowerBound < $1.lowerBound })
        XCTAssertEqual(MeetingVoiceMatch.spans(forVoice: "S1", in: [MeetingSegment(start: 0, end: 1, speaker: "S1", text: "hm")]),
                       [0..<1], "a voice with only short lines is still heard")
    }

    func testTwoStrongRivalsRequireAListener() {
        var meeting = Meeting(title: "Team", createdAt: Date())
        meeting.speakers = ["A", "B", "C"].map { MeetingSpeaker(id: $0, voice: Self.voice(0)) }
        meeting.speakerGroupsToMatch = [["C"]]
        XCTAssertTrue(MeetingVoiceMatch.resolve(&meeting).joined.isEmpty)
        XCTAssertEqual(MeetingVoiceMatch.reviewPairs(in: meeting).count, 2)
        XCTAssertEqual(meeting.people.count, 3)
    }

    func testTwoLonePrintsCanBeMixedVoicesAndNeedAListener() {
        var meeting = Meeting(title: "Team", createdAt: Date())
        meeting.speakers = ["A", "B"].map { MeetingSpeaker(id: $0, voice: Self.voice(0)) }
        meeting.speakerGroupsToMatch = [["B"]]
        XCTAssertTrue(MeetingVoiceMatch.resolve(&meeting).joined.isEmpty)
        XCTAssertEqual(MeetingVoiceMatch.suggestedPairs(in: meeting).count, 1)
        XCTAssertEqual(meeting.people.count, 2)
    }

    func testSettingMeLeavesTwoConflictingNamesIntact() {
        var meeting = Meeting(title: "Team", createdAt: Date())
        meeting.speakers = [MeetingSpeaker(id: "A", name: "Ali", isMe: true), MeetingSpeaker(id: "B", name: "Bea")]
        MeetingSpeakerEdit.setMe("B", in: &meeting)
        XCTAssertEqual(meeting.me()?.id, "A")
        XCTAssertEqual(meeting.people.compactMap(\.name), ["Ali", "Bea"])
    }

    func testMeetingsSavedBeforeJoinsStillRead() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"Old","createdAt":"2026-11-01T10:00:00Z","updatedAt":"2026-11-01T10:00:00Z",
         "status":"done","parts":[],"segments":[{"start":0,"end":1,"speaker":"S2","text":"hi"}],
         "speakers":[{"id":"S1","isMe":true},{"id":"S2","isMe":false}],"transcribedThrough":1,"progress":1}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meeting = try decoder.decode(Meeting.self, from: Data(json.utf8))
        XCTAssertEqual(meeting.speakerName("S2"), "Speaker 2")
        XCTAssertEqual(meeting.people.count, 2)
        XCTAssertNil(meeting.speakerGroupsToMatch)
        // A pointer at a voice that is gone, or at itself, never hides or loops.
        var odd = meeting
        odd.speakers[1].sameAs = "S9"
        XCTAssertEqual(odd.person("S2"), "S2")
        odd.speakers[0].sameAs = "S2"
        odd.speakers[1].sameAs = "S1"
        XCTAssertNotNil(odd.speakerName("S2"))
    }
}
