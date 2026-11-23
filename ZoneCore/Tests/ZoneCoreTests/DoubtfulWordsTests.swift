// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// The words of a dictation the engine was least sure of: from decoder pieces to words, to the
/// few worth flagging, to where they landed in the text the keyboard inserted, and to a fix.
final class DoubtfulWordsTests: XCTestCase {
    private func doubt(_ word: String, _ confidence: Float) -> DoubtfulWord {
        DoubtfulWord(word: word, confidence: confidence)
    }

    // MARK: Pieces to words

    func testPiecesGroupIntoWordsWithTheirLeastSurePiece() {
        // " Th" "ere" "'" "s" " ir" "on" "," " they": Parakeet v3's pieces for "There's iron, they".
        let pieces: [(piece: String, confidence: Float)] = [
            (" Th", 0.99), ("ere", 1), ("'", 0.98), ("s", 1), (" ir", 0.62), ("on", 1), (",", 0.31), (" they", 1),
        ]
        let words = DoubtfulWords.words(pieces: pieces)
        XCTAssertEqual(words.map(\.word), ["There's", "iron", "they"])
        XCTAssertEqual(words[1].confidence, 0.62)
        // The comma's 0.31 is a doubt about punctuation, not about "iron"; the apostrophe's 0.98
        // likewise does not count against "There's".
        XCTAssertEqual(words[0].confidence, 0.99)
    }

    func testSentencePieceMarkersBlanksAndUnknownsAreHandled() {
        let pieces: [(piece: String, confidence: Float)] = [
            ("\u{2581}see", 0.5), ("<blank>", 0.1), ("<unk>", 0.1), ("\u{2581}you", 0.9), (".", 0.2),
        ]
        XCTAssertEqual(DoubtfulWords.words(pieces: pieces), [doubt("see", 0.5), doubt("you", 0.9)])
        XCTAssertEqual(DoubtfulWords.words(pieces: []), [])
    }

    func testCandidatesKeepSpokenOrderUnderTheCeiling() {
        let words = [doubt("a", 0.99), doubt("b", 0.4), doubt("c", 0.85), doubt("d", 0.7)]
        XCTAssertEqual(DoubtfulWords.candidates(words).map(\.word), ["b", "d"])
        let many = (0..<40).map { doubt("w\($0)", Float($0) / 100) }
        let kept = DoubtfulWords.candidates(many)
        XCTAssertEqual(kept.count, DoubtfulWords.candidateLimit)
        XCTAssertEqual(kept.first?.word, "w0", "the least sure are kept")
        XCTAssertEqual(kept.map(\.word), kept.sorted { $0.confidence < $1.confidence }.map(\.word), "still in spoken order")
    }

    // MARK: Which to flag

    func testOnlyWordsMoreLikelyWrongThanRightAreFlagged() {
        let calibration = DoubtCalibration()
        XCTAssertTrue(calibration.flags(0.25))
        XCTAssertTrue(calibration.flags(0.45))
        XCTAssertFalse(calibration.flags(0.55), "44% of these were wrong: not flagged")
        XCTAssertFalse(calibration.flags(0.65))
        XCTAssertFalse(calibration.flags(0.79))
        XCTAssertFalse(calibration.flags(0.95), "outside the bands")
    }

    func testAtMostThreeAreShownTheLeastSureInSpokenOrder() {
        let calibration = DoubtCalibration()
        let words = [doubt("one", 0.48), doubt("two", 0.2), doubt("three", 0.75), doubt("four", 0.4), doubt("five", 0.45)]
        XCTAssertEqual(calibration.select(words).map(\.word), ["two", "four", "five"])
    }

    func testKeepsLowerAndFixesRaiseTheBar() {
        var calibration = DoubtCalibration()
        // One keep does not silence a band; a dozen do.
        calibration.record(confidence: 0.45, fixed: false)
        XCTAssertTrue(calibration.flags(0.45))
        for _ in 0..<11 { calibration.record(confidence: 0.45, fixed: false) }
        XCTAssertFalse(calibration.flags(0.45))
        // Fixes in a band that was not flagged start flagging it.
        XCTAssertFalse(calibration.flags(0.55))
        for _ in 0..<3 { calibration.record(confidence: 0.55, fixed: true) }
        XCTAssertFalse(calibration.flags(0.55))
        calibration.record(confidence: 0.55, fixed: true)
        XCTAssertTrue(calibration.flags(0.55))
        // Fairly sure words stay unflagged however the counts go.
        for _ in 0..<200 { calibration.record(confidence: 0.9, fixed: true) }
        XCTAssertFalse(calibration.flags(0.9))
    }

    func testCalibrationSurvivesAReload() throws {
        var calibration = DoubtCalibration()
        calibration.record(confidence: 0.35, fixed: true)
        let data = try JSONEncoder().encode(calibration)
        XCTAssertEqual(try JSONDecoder().decode(DoubtCalibration.self, from: data), calibration)
    }

    // MARK: Where they landed

    func testWordsAreFoundInTheStyledText() {
        let inserted = "I'll be there in an hour. Bring the deck."
        let placements = DoubtfulWords.place([doubt("hour", 0.4), doubt("deck", 0.5)], in: inserted)
        XCTAssertEqual(placements.map(\.word), ["hour", "deck"])
        XCTAssertEqual(placements[1].charactersAfter, 1, "the period follows deck")
        XCTAssertEqual(placements[0].charactersAfter, "hour. Bring the deck.".count - "hour".count)
    }

    func testCaseChangesStillMatchAndRewrittenWordsAreDropped() {
        // Styling capitalized "kaylee" and wrote "two" as "2": the first is found, the second is not.
        let inserted = "Kaylee has 2 dogs."
        let placements = DoubtfulWords.place([doubt("kaylee", 0.3), doubt("two", 0.4), doubt("dogs", 0.6)], in: inserted)
        XCTAssertEqual(placements.map(\.word), ["Kaylee", "dogs"])
    }

    func testARepeatedWordIsTheOneAtItsTurn() {
        let inserted = "the cat saw the cat"
        let placements = DoubtfulWords.place([doubt("saw", 0.5), doubt("cat", 0.4)], in: inserted)
        XCTAssertEqual(placements.map(\.charactersAfter), [8, 0], "the cat after saw, not the first one")
    }

    func testApostrophesAndCurlyQuotes() {
        let inserted = "Don\u{2019}t forget the kids\u{2019} lunch."
        let placements = DoubtfulWords.place([doubt("don't", 0.4), doubt("kids", 0.5)], in: inserted)
        XCTAssertEqual(placements.map(\.word), ["Don\u{2019}t", "kids"])
    }

    // MARK: A fix

    func testReplacingAWordMovesTheEarlierOnesOnly() throws {
        let inserted = "meet at noon by the dock"
        let placements = DoubtfulWords.place([doubt("meet", 0.4), doubt("noon", 0.5), doubt("dock", 0.3)], in: inserted)
        let noon = try XCTUnwrap(placements.first { $0.word == "noon" })
        XCTAssertEqual(DoubtfulWords.tail(of: noon, in: inserted), "noon by the dock")
        let edit = try XCTUnwrap(DoubtfulWords.replacing(noon, with: "nine", in: inserted, placements: placements))
        XCTAssertEqual(edit.text, "meet at nine by the dock")
        let again = DoubtfulWords.place([doubt("meet", 0.4), doubt("dock", 0.3)], in: edit.text)
        XCTAssertEqual(edit.placements, again, "the others still point at their words")

        let longer = try XCTUnwrap(DoubtfulWords.replacing(noon, with: "midnight", in: inserted, placements: placements))
        XCTAssertEqual(longer.text, "meet at midnight by the dock")
        XCTAssertEqual(longer.placements, DoubtfulWords.place([doubt("meet", 0.4), doubt("dock", 0.3)], in: longer.text))
    }

    func testAPlacementThatNoLongerFitsIsRefused() {
        let stale = DoubtfulWords.Placement(word: "noon", confidence: 0.5, charactersAfter: 3)
        XCTAssertNil(DoubtfulWords.replacing(stale, with: "nine", in: "meet at noon", placements: [stale]))
        let tooFar = DoubtfulWords.Placement(word: "noon", confidence: 0.5, charactersAfter: 40)
        XCTAssertNil(DoubtfulWords.replacing(tooFar, with: "nine", in: "meet at noon", placements: [tooFar]))
    }

    // MARK: Alternatives

    func testAlternativesPreferPastChoicesThenOwnWordsThenTheDictionary() {
        let corrector = Autocorrector(words: WordListTests.list)
        var memory = DoubtMemory()
        XCTAssertFalse(DoubtfulWords.alternatives(for: "hear", previous: "over", corrector: corrector,
                                                  personalWords: [], memory: memory).isEmpty)
        memory.record(heard: "hear", chosen: "here")
        let options = DoubtfulWords.alternatives(for: "hear", previous: "over", corrector: corrector,
                                                 personalWords: [], memory: memory)
        XCTAssertEqual(options.first, "here")
        XCTAssertFalse(options.contains("hear"), "never the heard word itself")
        XCTAssertLessThanOrEqual(options.count, 3)

        let named = DoubtfulWords.alternatives(for: "Kaylee", previous: nil, corrector: corrector,
                                               personalWords: ["Kayleigh", "Marcus"], memory: DoubtMemory())
        XCTAssertEqual(named.first, "Kayleigh", "an own word that sounds the same comes first")
        XCTAssertFalse(named.contains("Marcus"))
    }

    func testAlternativesTakeTheHeardCapital() {
        let corrector = Autocorrector(words: WordListTests.list)
        var memory = DoubtMemory()
        memory.record(heard: "hear", chosen: "here")
        XCTAssertEqual(DoubtfulWords.alternatives(for: "Hear", previous: nil, corrector: corrector,
                                                  personalWords: [], memory: memory).first, "Here")
        XCTAssertEqual(DoubtfulWords.alternatives(for: "kaylee", previous: nil, corrector: nil,
                                                  personalWords: ["Kayleigh"], memory: DoubtMemory()), ["Kayleigh"])
    }

    func testMemoryKeepsTheNewestChoicesAndForgetsTheOldest() {
        var memory = DoubtMemory()
        memory.record(heard: "there", chosen: "their")
        memory.record(heard: "There", chosen: "they're")
        XCTAssertEqual(memory.choices(for: "there"), ["they're", "their"])
        memory.record(heard: "there", chosen: "there")
        XCTAssertEqual(memory.choices(for: "there"), ["they're", "their"], "choosing the word itself is no choice")
        for n in 0..<(DoubtMemory.limit + 5) { memory.record(heard: "w\(n)", chosen: "x\(n)") }
        XCTAssertEqual(memory.choices(for: "there"), [], "the oldest heard words are dropped")
        XCTAssertEqual(memory.choices(for: "w\(DoubtMemory.limit + 4)"), ["x\(DoubtMemory.limit + 4)"])
    }

    // MARK: Carried through recognition

    func testSegmentsCarryTheirDoubtsInOrder() async throws {
        let segmenter = RollingSegmenter(segmentSeconds: 1, searchSeconds: 0.2)
        let counter = RollingRecognitionSessionTests.Counter()
        let session = RollingRecognitionSession(segmenter: segmenter, decodeSegment: { _ in
            let n = await counter.next()
            return RecognizedSegment(text: "part\(n)", doubts: [DoubtfulWord(word: "part\(n)", confidence: 0.4)])
        })
        for _ in 0..<3 { session.feed(Array(repeating: 0.1, count: 16_000)) }
        _ = try await session.finish()
        XCTAssertEqual(session.doubtfulWords.map(\.word), ["part1", "part2", "part3"])
    }

    /// Every app dictation is a `SegmentedRecognition` over a `LexiconRecognitionSession` over the
    /// engine's utterance (`DictationCoordinator.beginUserUtterance`). The lexicon wrapper is what
    /// the coordinator reads, so it must pass the engine's doubts on: with the protocol's empty
    /// default it sent none, and the strip never showed on a phone.
    func testTheAppsRecognitionChainKeepsTheEnginesDoubts() async throws {
        let engine = DoubtingSession(text: "I met Nida at the hear", doubts: [DoubtfulWord(word: "hear", confidence: 0.31)])
        let lexicon = LexiconRecognitionSession(base: engine, systemWords: ["Nita"], personalWords: [], mentions: false)
        XCTAssertEqual(lexicon.doubtfulWords, engine.doubts)
        let recording = SegmentedRecognition(first: lexicon)
        recording.feed([0, 0, 0])
        let text = try await recording.finish()
        XCTAssertEqual(text, "I met Nita at the hear")
        XCTAssertEqual(recording.doubtfulWords, [DoubtfulWord(word: "hear", confidence: 0.31)])
        // What the coordinator sends, and what the keyboard then places in the casual insert.
        let sent = DoubtfulWords.candidates(recording.doubtfulWords)
        let inserted = TextStyle.casual.insertion(of: text, contextBefore: nil, fieldCapitalizesSentences: true)
        XCTAssertEqual(DoubtfulWords.place(DoubtCalibration().select(sent), in: inserted).map(\.word), ["hear"])
    }

    func testAResultWithoutDoubtsStillDecodes() throws {
        // A payload written by a build before doubts existed.
        let old = #"{"requestID":"7B1C2F0E-3C1B-4B8E-9A55-0E8C1F2A9B11","generation":1,"text":"hi","audioSeconds":1,"createdAt":0,"inputSession":null}"#
        let result = try JSONDecoder().decode(DictationResult.self, from: Data(old.utf8))
        XCTAssertNil(result.doubts)
        let withDoubts = DictationResult(requestID: UUID(), generation: 1, text: "hi there", audioSeconds: 1, createdAt: Date(),
                                         inputSession: nil, doubts: [DoubtfulWord(word: "there", confidence: 0.4)])
        let decoded = try JSONDecoder().decode(DictationResult.self, from: JSONEncoder().encode(withDoubts))
        XCTAssertEqual(decoded.doubts, withDoubts.doubts)
    }
}

/// An engine utterance that reports confidence, as Fluid Speech Mini's does.
private final class DoubtingSession: RecognitionSession {
    let text: String
    let doubts: [DoubtfulWord]
    private var fed = 0
    init(text: String, doubts: [DoubtfulWord]) { self.text = text; self.doubts = doubts }
    var audioSeconds: Double { Double(fed) / 16_000 }
    var textSoFar: String { text }
    var failure: Error? { nil }
    var availableAudioSamples: Int { 16_000 }
    var doubtfulWords: [DoubtfulWord] { doubts }
    func feed(_ samples: [Float]) { fed += samples.count }
    func finish() async throws -> String { text }
    func cancel() {}
}
