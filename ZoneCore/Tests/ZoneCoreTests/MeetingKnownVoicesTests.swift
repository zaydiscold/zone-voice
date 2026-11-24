// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class MeetingKnownVoicesTests: XCTestCase {
    private let jonathan: [Float] = [1, 0, 0, 0]
    private let owner: [Float] = [0, 1, 0, 0]
    private let kim: [Float] = [0, 0, 1, 0]
    private let stranger: [Float] = [0, 0, 0, 1]
    private var directories: [URL] = []

    override func tearDown() {
        for url in directories { try? FileManager.default.removeItem(at: url) }
        directories = []
        super.tearDown()
    }

    private func meeting(_ speakers: [MeetingSpeaker], at seconds: TimeInterval = 1_800_000_000) -> Meeting {
        var meeting = Meeting(title: "Sync", createdAt: Date(timeIntervalSince1970: seconds), status: .done)
        meeting.speakers = speakers
        return meeting
    }

    /// `voice` turned a little toward `toward`, still the same person by a wide margin.
    private func near(_ voice: [Float], _ toward: [Float], by amount: Float = 0.3) -> [Float] {
        zip(voice, toward).map { $0 + amount * $1 }
    }

    /// Thirty seconds of speech for each id.
    private func turns(_ ids: [String]) -> [MeetingTurn] {
        ids.enumerated().map { MeetingTurn(start: Double($0.offset) * 30, end: Double($0.offset + 1) * 30, speaker: $0.element) }
    }

    // MARK: Learning

    func testLearnsNamedVoicesAndMeOnly() {
        let people = MeetingKnownVoices.people(in: [meeting([
            MeetingSpeaker(id: "S1", name: " Jonathan ", voice: jonathan),
            MeetingSpeaker(id: "S2", isMe: true, voice: owner),
            MeetingSpeaker(id: "S3", voice: stranger),
            MeetingSpeaker(id: "S4", name: "Kim"),
        ])])
        XCTAssertEqual(people.count, 2, "an unnamed voice and a name without a print teach nothing")
        XCTAssertEqual(people.first(where: { $0.isMe })?.name, nil)
        XCTAssertEqual(people.first(where: { !$0.isMe })?.name, "Jonathan")
    }

    func testAveragesAPersonOverMeetingsAndKeepsTheNewestSpelling() {
        let people = MeetingKnownVoices.people(in: [
            meeting([MeetingSpeaker(id: "S1", name: "jon", voice: jonathan)], at: 1_800_000_000),
            meeting([MeetingSpeaker(id: "S2", name: "Jon", voice: near(jonathan, kim))], at: 1_800_100_000),
        ])
        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people[0].name, "Jon")
        XCTAssertEqual(people[0].meetings, 2)
        let length = sqrt(people[0].voice.reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(length, 1, accuracy: 1e-5)
        XCTAssertGreaterThan(people[0].voice[2], 0, "the second meeting moved the average")
    }

    func testARecognizedNameIsNeverLearnedFrom() {
        let people = MeetingKnownVoices.people(in: [meeting([
            MeetingSpeaker(id: "S1", name: "Jonathan", voice: stranger, recognized: true),
        ])])
        XCTAssertTrue(people.isEmpty, "a wrong guess must not teach itself")
    }

    func testSkipsTheMeetingBeingLabeledAndPrintsOfAnotherSize() {
        let current = meeting([MeetingSpeaker(id: "S1", name: "Jonathan", voice: jonathan)])
        XCTAssertTrue(MeetingKnownVoices.people(in: [current], excluding: current.id).isEmpty)
        let people = MeetingKnownVoices.people(in: [
            meeting([MeetingSpeaker(id: "S1", name: "Jonathan", voice: jonathan)]),
            meeting([MeetingSpeaker(id: "S1", name: "Jonathan", voice: [1, 0, 0, 0, 0, 0])]),
        ])
        XCTAssertEqual(people.map(\.meetings), [1])
        XCTAssertEqual(people[0].voice.count, 4)
    }

    // MARK: Recognizing

    func testNamesTheVoicesItKnowsAndLeavesStrangersAlone() {
        let people = MeetingKnownVoices.people(in: [meeting([
            MeetingSpeaker(id: "S1", name: "Jonathan", voice: jonathan), MeetingSpeaker(id: "S2", isMe: true, voice: owner),
        ])])
        let fresh = [MeetingSpeaker(id: "S1", voice: near(owner, stranger)), MeetingSpeaker(id: "S2", voice: near(jonathan, kim)),
                     MeetingSpeaker(id: "S3", voice: stranger)]
        let named = MeetingKnownVoices.recognize(fresh, turns: turns(["S1", "S2", "S3"]), people: people)
        XCTAssertEqual(named[0].isMe, true)
        XCTAssertNil(named[0].name)
        XCTAssertEqual(named[1].name, "Jonathan")
        XCTAssertEqual(named[0].recognized, true)
        XCTAssertEqual(named[1].recognized, true)
        XCTAssertEqual(named[2], fresh[2], "a voice nobody named stays Speaker 3")
    }

    func testNeedsTheThresholdAndEnoughSpeech() {
        let people = MeetingKnownVoices.people(in: [meeting([MeetingSpeaker(id: "S1", name: "Jonathan", voice: jonathan)])])
        // cos([1,1,0,0], [1,0,0,0]) = 0.707: over 0.70, under the same-meeting 0.75.
        let fresh = [MeetingSpeaker(id: "S1", voice: [1, 1, 0, 0])]
        XCTAssertEqual(MeetingKnownVoices.recognize(fresh, turns: turns(["S1"]), people: people)[0].name, "Jonathan")
        let farther = [MeetingSpeaker(id: "S1", voice: [1, 1.1, 0, 0])]
        XCTAssertNil(MeetingKnownVoices.recognize(farther, turns: turns(["S1"]), people: people)[0].name)
        let brief = [MeetingTurn(start: 0, end: 10, speaker: "S1")]
        XCTAssertNil(MeetingKnownVoices.recognize(fresh, turns: brief, people: people)[0].name,
                     "ten seconds of speech is too little to name anyone")
    }

    func testOnePersonPerSpeakerMostSimilarFirst() {
        let people = MeetingKnownVoices.people(in: [meeting([MeetingSpeaker(id: "S1", name: "Jonathan", voice: jonathan)])])
        let fresh = [MeetingSpeaker(id: "S1", voice: near(jonathan, kim, by: 0.5)), MeetingSpeaker(id: "S2", voice: near(jonathan, kim, by: 0.1))]
        let named = MeetingKnownVoices.recognize(fresh, turns: turns(["S1", "S2"]), people: people)
        XCTAssertNil(named[0].name)
        XCTAssertEqual(named[1].name, "Jonathan")
    }

    func testNeverRenamesAnyoneOrAddsASecondNameOrMe() {
        let people = MeetingKnownVoices.people(in: [meeting([
            MeetingSpeaker(id: "S1", name: "Jonathan", voice: jonathan), MeetingSpeaker(id: "S2", isMe: true, voice: owner),
        ])])
        let fresh = [MeetingSpeaker(id: "S1", name: "Kim", voice: jonathan), MeetingSpeaker(id: "S2", isMe: true, voice: kim),
                     MeetingSpeaker(id: "S3", voice: owner), MeetingSpeaker(id: "S4", name: "jonathan", voice: kim),
                     MeetingSpeaker(id: "S5", voice: near(jonathan, stranger))]
        let named = MeetingKnownVoices.recognize(fresh, turns: turns(["S1", "S2", "S3", "S4", "S5"]), people: people)
        XCTAssertEqual(named, fresh, "names typed here win; Jonathan and me are already in this meeting")
    }

    // MARK: Confirming

    func testSavingANameConfirmsItAndMovingMeOffARecognitionDropsItsName() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("known-voices-" + UUID().uuidString)
        directories.append(url)
        let store = MeetingStore(directory: url)
        let (started, writer) = try store.beginRecording(now: Date(timeIntervalSince1970: 1_800_000_000))
        _ = writer.append([Float](repeating: 0.1, count: 16_000))
        try await writer.finish()
        _ = try store.finishRecording(started.id)
        _ = try store.update(started.id) {
            $0.speakers = [MeetingSpeaker(id: "S1", name: "Jonathan", voice: self.jonathan, recognized: true),
                           MeetingSpeaker(id: "S2", name: "Zayd", isMe: true, voice: self.owner, recognized: true)]
        }
        try store.renameSpeaker(started.id, speaker: "S1", to: "Jonathan")
        try store.moveMe(started.id, to: "S1")
        let after = try store.meeting(started.id)
        XCTAssertNil(after.speakers[0].recognized)
        XCTAssertTrue(after.speakers[0].isMe)
        XCTAssertNil(after.speakers[1].name, "a name that only came with a recognized me goes with it")
        XCTAssertNil(after.speakers[1].recognized)
        XCTAssertFalse(after.speakers[1].isMe)
    }

    func testSpeakersSavedBeforeRecognitionStillDecode() throws {
        let json = #"{"id":"S1","name":"Jonathan","isMe":false}"#
        let speaker = try JSONDecoder().decode(MeetingSpeaker.self, from: Data(json.utf8))
        XCTAssertNil(speaker.recognized)
        XCTAssertNil(speaker.voice)
    }

    // MARK: Voice setup

    private func setup(_ prints: [(VoiceSetup.Part, [Float], Double)]) -> VoiceProfile {
        VoiceProfile(model: "m", prints: prints.map { VoiceProfile.Print(part: $0.0, voice: $0.1, seconds: $0.2, recordedAt: Date()) },
                     createdAt: Date())
    }

    func testVoiceSetupAloneNamesMe() {
        let profile = setup([(.read, owner, 45), (.talk, owner, 30)])
        let people = MeetingKnownVoices.people(in: [], profile: profile)
        XCTAssertEqual(people.count, 1)
        XCTAssertTrue(people[0].isMe)
        XCTAssertTrue(people[0].voice.isEmpty)
        let fresh = [MeetingSpeaker(id: "S1", voice: near(owner, stranger)), MeetingSpeaker(id: "S2", voice: jonathan)]
        let named = MeetingKnownVoices.recognize(fresh, turns: turns(["S1", "S2"]), people: people)
        XCTAssertEqual(named[0].isMe, true)
        XCTAssertEqual(named[0].recognized, true)
        XCTAssertNil(named[0].name)
        XCTAssertEqual(named[1], fresh[1])
    }

    func testVoiceSetupJoinsTheMeLearnedFromMeetingsAndTheBestPrintWins() {
        // Learned close in a meeting; setup also recorded the far voice, which this meeting sounds like.
        let farVoice: [Float] = [0, 0.6, 0, 0.8]
        let people = MeetingKnownVoices.people(in: [meeting([MeetingSpeaker(id: "S1", name: "Zayd", isMe: true, voice: owner)])],
                                               profile: setup([(.read, owner, 45), (.far, farVoice, 18)]))
        XCTAssertEqual(people.filter(\.isMe).count, 1, "one me, not two")
        let me = people.first { $0.isMe }!
        XCTAssertEqual(me.name, "Zayd", "the name typed in a meeting is kept")
        XCTAssertEqual(me.voices.count, 2, "the print learned in meetings and setup's")
        // cos(owner, farVoice) = 0.6: under the threshold alone; setup's print, with the far
        // part averaged in, reaches 0.78.
        let fresh = [MeetingSpeaker(id: "S1", voice: farVoice)]
        let named = MeetingKnownVoices.recognize(fresh, turns: turns(["S1"]), people: people)
        XCTAssertEqual(named[0].isMe, true)
        XCTAssertEqual(named[0].name, "Zayd")
    }

    func testAWhisperOnlySetupNamesNobody() {
        let people = MeetingKnownVoices.people(in: [], profile: setup([(.whisper, owner, 8)]))
        XCTAssertTrue(people.isEmpty)
    }

    func testSetupPrintsOfAnotherSizeAreIgnoredForALearnedMe() {
        let people = MeetingKnownVoices.people(in: [meeting([MeetingSpeaker(id: "S1", isMe: true, voice: owner)])],
                                               profile: setup([(.read, [1, 0, 0, 0, 0, 0], 45)]))
        XCTAssertNil(people.first { $0.isMe }?.setupVoice)
    }

    func testTheWhisperNamesMeOnlyAboveItsOwnBar() {
        let whisper: [Float] = [0, 0, 0, 1]
        let people = MeetingKnownVoices.people(in: [], profile: setup([(.read, owner, 45), (.whisper, whisper, 8)]))
        XCTAssertEqual(people.count, 1)
        // A whispering speaker: 0.96 to the whisper print, 0.29 to the normal one.
        let whispering = [MeetingSpeaker(id: "S1", voice: [0, 0.3, 0, 1])]
        XCTAssertEqual(MeetingKnownVoices.recognize(whispering, turns: turns(["S1"]), people: people)[0].isMe, true)
        // Someone else whispering: 0.74 to the whisper print, over the usual 0.70 but under 0.80.
        let other = [MeetingSpeaker(id: "S1", voice: [0, 0, 0.9, 1])]
        XCTAssertEqual(MeetingKnownVoices.recognize(other, turns: turns(["S1"]), people: people), other)
        XCTAssertEqual(people[0].similarity([0, 0, 0.9, 1]), 0, accuracy: 1e-9, "only the normal print counts below the bar")
    }

    func testFindsMeInEarlierMeetingsOnlyWhereNobodyIsMe() {
        let profile = setup([(.read, owner, 45), (.talk, owner, 30)])
        var plain = meeting([MeetingSpeaker(id: "S1", voice: jonathan), MeetingSpeaker(id: "S2", voice: near(owner, kim))])
        plain.turns = turns(["S1", "S2"])
        var marked = meeting([MeetingSpeaker(id: "S1", voice: jonathan), MeetingSpeaker(id: "S2", isMe: true, voice: owner)])
        marked.turns = turns(["S1", "S2"])
        var short = meeting([MeetingSpeaker(id: "S1", voice: owner)])
        short.turns = [MeetingTurn(start: 0, end: 5, speaker: "S1")]
        var recording = meeting([MeetingSpeaker(id: "S1", voice: owner)])
        recording.status = .recording
        recording.turns = turns(["S1"])
        var segmentsOnly = meeting([MeetingSpeaker(id: "S1", voice: owner)])
        segmentsOnly.segments = [MeetingSegment(start: 0, end: 40, speaker: "S1", text: "hello")]
        let found = MeetingKnownVoices.findMe(in: [plain, marked, short, recording, segmentsOnly], profile: profile)
        XCTAssertEqual(found, [MeetingKnownVoices.MeMatch(meeting: plain.id, speaker: "S2"),
                               MeetingKnownVoices.MeMatch(meeting: segmentsOnly.id, speaker: "S1")])
        XCTAssertEqual(MeetingKnownVoices.findMe(in: [plain], profile: setup([(.whisper, owner, 8)])), [])
    }
}
