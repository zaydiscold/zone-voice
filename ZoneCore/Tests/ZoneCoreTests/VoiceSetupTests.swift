// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class VoiceSetupTests: XCTestCase {
    // MARK: Steps

    func testStepsAreInOrderWithSaneTargets() {
        XCTAssertEqual(VoiceSetup.steps.map(\.part), [.read, .talk, .whisper, .far])
        for step in VoiceSetup.steps {
            XCTAssertLessThan(step.minimum, step.target, "\(step.part)")
            XCTAssertGreaterThan(step.minimum, 0)
            XCTAssertFalse(step.title.isEmpty)
            XCTAssertFalse(step.placement.isEmpty)
            // Talking freely, near or far, has no script; nobody reads a phone across the room.
            if step.part == .talk || step.part == .far { XCTAssertTrue(step.script.isEmpty) } else { XCTAssertFalse(step.script.isEmpty) }
        }
        XCTAssertGreaterThan(VoiceSetup.step(.far).countdown, 0, "the far step needs time to put the phone down")
        XCTAssertEqual(VoiceSetup.step(.read).countdown, 0)
    }

    func testThePassageIsLongEnoughForItsTarget() {
        // Read aloud at 150 words a minute, the passage must outlast the target's speech.
        let words = VoiceSetup.passage.split(whereSeparator: \.isWhitespace).count
        XCTAssertGreaterThan(Double(words) / 150 * 60, VoiceSetup.step(.read).target * 1.4)
        XCTAssertLessThanOrEqual(VoiceSetup.farPrompt.count, 60, "read once, large, before the phone goes down")
        let whisperWords = VoiceSetup.whisperScript.split(whereSeparator: \.isWhitespace).count
        // Whispering is slower; about 110 words a minute.
        XCTAssertGreaterThan(Double(whisperWords) / 110 * 60, VoiceSetup.step(.whisper).target)
        XCTAssertFalse(VoiceSetup.passage.contains("\\"), "line continuations left a backslash in the text")
        XCTAssertFalse(VoiceSetup.passage.contains("  "))
    }

    func testTalkPromptsAdvanceAndStopAtTheLast() {
        XCTAssertEqual(VoiceSetup.prompt(after: 0), VoiceSetup.talkPrompts[0])
        XCTAssertEqual(VoiceSetup.prompt(after: VoiceSetup.promptSeconds - 0.1), VoiceSetup.talkPrompts[0])
        XCTAssertEqual(VoiceSetup.prompt(after: VoiceSetup.promptSeconds), VoiceSetup.talkPrompts[1])
        XCTAssertEqual(VoiceSetup.prompt(after: 10_000), VoiceSetup.talkPrompts.last)
        XCTAssertEqual(VoiceSetup.prompt(after: -5), VoiceSetup.talkPrompts[0])
        XCTAssertEqual(Set(VoiceSetup.talkPrompts).count, VoiceSetup.talkPrompts.count)
    }

    func testSavingNeedsTheNormalVoiceNotJustWhisperOrFar() {
        XCTAssertFalse(VoiceSetup.canSave([:]))
        XCTAssertFalse(VoiceSetup.canSave([.whisper: 60, .far: 60]))
        XCTAssertFalse(VoiceSetup.canSave([.read: 10, .talk: 10]))
        XCTAssertTrue(VoiceSetup.canSave([.read: 15, .talk: 10]))
        XCTAssertTrue(VoiceSetup.canSave([.talk: 30]), "someone who would rather talk than read")
        XCTAssertTrue(VoiceSetup.canSave([.read: 45]))
    }

    // MARK: Meter

    private func feed(_ meter: inout VoiceSetupMeter, _ level: Float, seconds: Double) {
        for _ in 0..<Int((seconds / VoiceSetupMeter.frameSeconds).rounded()) { meter.add(level) }
    }

    func testCountsNormalSpeechInAQuietRoom() {
        var meter = VoiceSetupMeter()
        feed(&meter, 0.0004, seconds: 2)
        feed(&meter, 0.05, seconds: 10)
        XCTAssertEqual(meter.speechSeconds, 10, accuracy: 0.05)
    }

    func testHearsAWhisperThatAFixedDictationLevelWouldMiss() {
        var meter = VoiceSetupMeter()
        feed(&meter, 0.0003, seconds: 2)
        // A whisper with breath pauses, at -55 dB: a tenth of a quiet voice.
        for _ in 0..<5 {
            feed(&meter, 0.0018, seconds: 1)
            feed(&meter, 0.0003, seconds: 0.3)
        }
        XCTAssertEqual(meter.speechSeconds, 5, accuracy: 0.15)
    }

    func testANoisyRoomIsNotSpeechButAVoiceOverItIs() {
        var meter = VoiceSetupMeter()
        // A fan or a café at a steady -40 dB for 15 s.
        feed(&meter, 0.01, seconds: 15)
        XCTAssertLessThan(meter.speechSeconds, 1.5, "only the first second before the floor learns the room")
        let before = meter.speechSeconds
        // Speaking over it, with pauses for breath (the floor needs quiet frames to stay down).
        for _ in 0..<8 {
            feed(&meter, 0.08, seconds: 1)
            feed(&meter, 0.01, seconds: 0.25)
        }
        XCTAssertEqual(meter.speechSeconds - before, 8, accuracy: 0.2)
    }

    func testKeepsCountingThroughAMinuteOfReading() {
        // Reading: syllables vary by 20 dB and sentences end in a breath.
        var meter = VoiceSetupMeter()
        feed(&meter, 0.0005, seconds: 1)
        for sentence in 0..<12 {
            for syllable in 0..<45 { meter.add(syllable % 3 == 0 ? 0.008 : 0.06) }
            feed(&meter, 0.0005, seconds: sentence % 2 == 0 ? 0.4 : 0.6)
        }
        XCTAssertEqual(meter.speechSeconds, 54, accuracy: 0.2)
    }

    func testSpeechFromTheFirstFrameCounts() {
        var meter = VoiceSetupMeter()
        feed(&meter, 0.04, seconds: 0.5)
        XCTAssertEqual(meter.speechSeconds, 0.5, accuracy: 0.01, "someone who starts talking as they tap Start")
    }

    func testDigitalSilenceIsNeverSpeech() {
        var meter = VoiceSetupMeter()
        feed(&meter, 0, seconds: 5)
        XCTAssertEqual(meter.speechSeconds, 0)
        XCTAssertEqual(meter.frames, 50)
    }

    func testLevelIsRootMeanSquare() {
        XCTAssertEqual(VoiceSetupMeter.level([0.5, -0.5, 0.5, -0.5][...]), 0.5, accuracy: 1e-6)
        XCTAssertEqual(VoiceSetupMeter.level([][...]), 0)
    }

    private func tone(_ hertz: Double, amplitude: Float, seconds: Double) -> [Float] {
        (0..<Int(seconds * 16_000)).map { amplitude * Float(sin(2 * Double.pi * hertz * Double($0) / 16_000)) }
    }

    func testLevelsFilterOutRumbleAndKeepAWhispersHiss() {
        var rumble = VoiceSetupLevels()
        let low = rumble.add(tone(50, amplitude: 0.1, seconds: 1))
        XCTAssertEqual(low.count, 10)
        // A 50 Hz hum loud enough to read as speech across the whole band (-23 dB).
        XCTAssertLessThan(low.last!, 0.1 * 0.707 * 0.15, "hum is cut by more than 16 dB")
        var hiss = VoiceSetupLevels()
        let high = hiss.add(tone(3_000, amplitude: 0.01, seconds: 1))
        XCTAssertEqual(Double(high.last!), 0.01 * 0.7071, accuracy: 0.0005, "a 3 kHz whisper passes untouched")
        var dc = VoiceSetupLevels()
        XCTAssertLessThan(dc.add([Float](repeating: 0.3, count: 16_000)).last!, 0.001, "a DC offset is not a voice")
    }

    func testLevelsFramesSpanChunks() {
        var whole = VoiceSetupLevels(), split = VoiceSetupLevels()
        let samples = tone(800, amplitude: 0.05, seconds: 0.95)
        let once = whole.add(samples)
        var pieces: [Float] = []
        for start in stride(from: 0, to: samples.count, by: 437) {
            pieces += split.add(samples[start..<min(samples.count, start + 437)])
        }
        XCTAssertEqual(once.count, 9, "the half frame left over waits for more")
        XCTAssertEqual(pieces, once)
        XCTAssertEqual(whole.add([Float](repeating: 0, count: 800)).count, 1)
    }

    func testDisplayLevelMovesForAWhisperAndStaysInRange() {
        XCTAssertGreaterThan(VoiceSetupMeter.display(0.002), 0.1)
        XCTAssertEqual(VoiceSetupMeter.display(0), 0)
        XCTAssertEqual(VoiceSetupMeter.display(1), 1)
        XCTAssertLessThan(VoiceSetupMeter.display(0.002), VoiceSetupMeter.display(0.05))
    }

    func testSpansJoinShortPausesAndSplitLongSpeech() {
        var meter = VoiceSetupMeter()
        feed(&meter, 0.0004, seconds: 1)     // 0-1 s quiet
        feed(&meter, 0.05, seconds: 3)       // 1-4 speech
        feed(&meter, 0.0004, seconds: 0.3)   // a breath
        feed(&meter, 0.05, seconds: 8)       // 4.3-12.3 speech
        feed(&meter, 0.0004, seconds: 2)     // a long pause
        feed(&meter, 0.05, seconds: 0.5)     // a cough: too short alone
        feed(&meter, 0.0004, seconds: 1)
        let spans = meter.spans()
        XCTAssertFalse(spans.isEmpty)
        XCTAssertTrue(spans.allSatisfy { $0.upperBound - $0.lowerBound <= 5.0001 }, "\(spans)")
        XCTAssertTrue(spans.allSatisfy { $0.upperBound - $0.lowerBound >= 1.5 })
        let total = spans.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        // 11.3 s joined across the breath, plus a frame of padding on each side; no cough.
        XCTAssertEqual(total, 11.5, accuracy: 0.11)
        XCTAssertEqual(spans.first!.lowerBound, 0.9, accuracy: 0.01)
        XCTAssertLessThan(spans.last!.upperBound, 12.6)
        for (a, b) in zip(spans, spans.dropFirst()) { XCTAssertLessThanOrEqual(a.upperBound, b.lowerBound + 1e-9) }
    }

    func testSpansOfNothingAreEmpty() {
        XCTAssertEqual(VoiceSetupMeter().spans(), [])
        var meter = VoiceSetupMeter()
        feed(&meter, 0.0004, seconds: 3)
        XCTAssertEqual(meter.spans(), [])
    }

    // MARK: Prints

    func testPrintIsTheWeightedUnitMean() throws {
        let print = try XCTUnwrap(VoiceSetup.print(of: [[2, 0], [0, 1]], seconds: [3, 1]))
        XCTAssertEqual(Double(print[0]), 3 / sqrt(10), accuracy: 1e-5)
        XCTAssertEqual(Double(print[1]), 1 / sqrt(10), accuracy: 1e-5)
    }

    func testPrintDropsAPieceThatSoundsLikeSomeoneElse() throws {
        let me: [[Float]] = [[1, 0.1, 0], [1, 0, 0.1], [1, 0.05, 0.05], [1, 0.1, 0.1]]
        let door: [Float] = [0, 0, 1]
        let print = try XCTUnwrap(VoiceSetup.print(of: me + [door], seconds: [5, 5, 5, 5, 5]))
        XCTAssertGreaterThan(MeetingVoices.similarity(print, [1, 0.06, 0.06]), 0.999,
                             "the door's piece left the print where the voice is")
    }

    func testPrintRefusesMismatchedInput() {
        XCTAssertNil(VoiceSetup.print(of: [], seconds: []))
        XCTAssertNil(VoiceSetup.print(of: [[1, 0]], seconds: [1, 2]))
        XCTAssertNil(VoiceSetup.print(of: [[1, 0], [1]], seconds: [1, 1]))
    }

    // MARK: Profile

    private func profile(_ parts: [(VoiceSetup.Part, [Float], Double)], model: String = "m") -> VoiceProfile {
        VoiceProfile(model: model, prints: parts.map { VoiceProfile.Print(part: $0.0, voice: $0.1, seconds: $0.2, recordedAt: Date(timeIntervalSince1970: 1_800_000_000)) },
                     createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testMeetingVoiceAveragesReadTalkAndFarAndKeepsTheWhisperApart() throws {
        let p = profile([(.read, [1, 0, 0, 0], 45), (.talk, [0, 1, 0, 0], 15), (.whisper, [0, 0, 1, 0], 8), (.far, [0, 0, 0, 2], 18)])
        let voice = try XCTUnwrap(p.meetingVoice)
        let norm = Double(2_574).squareRoot()   // 45² + 15² + 18²
        XCTAssertEqual(Double(voice[0]), 45 / norm, accuracy: 1e-5, "weighted by seconds of speech")
        XCTAssertEqual(Double(voice[1]), 15 / norm, accuracy: 1e-5)
        XCTAssertEqual(Double(voice[3]), 18 / norm, accuracy: 1e-5, "the far print is unit length before weighting")
        XCTAssertEqual(voice[2], 0, "the whisper is not averaged in")
        XCTAssertEqual(p.whisperVoice, [0, 0, 1, 0])
        XCTAssertNil(profile([(.whisper, [1, 0], 8)]).meetingVoice)
        XCTAssertEqual(profile([(.far, [1, 0], 18)]).meetingVoice, [1, 0])
    }

    func testStoreSavesLoadsChecksTheModelAndDeletes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VoiceProfileStore(directory: directory)
        XCTAssertNil(store.load())
        let saved = profile([(.read, [1, 0], 45)], model: "pyannote")
        let changed = expectation(forNotification: VoiceProfileStore.didChange, object: nil)
        try store.save(saved)
        wait(for: [changed], timeout: 1)
        XCTAssertEqual(store.load(), saved)
        XCTAssertEqual(store.load(model: "pyannote"), saved)
        XCTAssertNil(store.load(model: "another model"), "prints from another speaker model mean nothing")
        let excluded = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(excluded, true)
        try store.delete()
        XCTAssertNil(store.load())
        try store.delete()   // deleting nothing is fine
    }

    func testStoreIgnoresAProfileFromANewerVersion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VoiceProfileStore(directory: directory)
        var newer = profile([(.read, [1, 0], 45)])
        newer.version = VoiceProfile.currentVersion + 1
        try store.save(newer)
        XCTAssertNil(store.load())
        try Data("not json".utf8).write(to: store.url)
        XCTAssertNil(store.load())
    }

    func testFlagsAPartThatSoundsLikeSomeoneElse() {
        let me: [Float] = [1, 0, 0, 0], alsoMe: [Float] = [1, 0.2, 0, 0], other: [Float] = [0, 0, 1, 0]
        func p(_ part: VoiceSetup.Part, _ voice: [Float]) -> VoiceProfile.Print {
            VoiceProfile.Print(part: part, voice: voice, seconds: 10, recordedAt: Date())
        }
        XCTAssertEqual(VoiceProfile.strangers(in: [p(.read, me), p(.talk, alsoMe), p(.far, alsoMe)]), [])
        XCTAssertEqual(VoiceProfile.strangers(in: [p(.read, me), p(.talk, other), p(.far, alsoMe)]), [.talk])
        XCTAssertEqual(VoiceProfile.strangers(in: [p(.read, me), p(.talk, other)]), [.read, .talk],
                       "with two parts that disagree, either could be the stranger")
        XCTAssertEqual(VoiceProfile.strangers(in: [p(.read, me), p(.whisper, other)]), [], "a whisper is never judged")
        XCTAssertEqual(VoiceProfile.strangers(in: [p(.read, me)]), [])
    }
}
