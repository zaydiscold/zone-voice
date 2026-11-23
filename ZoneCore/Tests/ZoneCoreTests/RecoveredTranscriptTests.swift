// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// A retried recording shows up as the newest item, dated when it was transcribed, and still
/// says when it was recorded.
final class RecoveredTranscriptTests: XCTestCase {
    private var directory: URL!
    private var history: TranscriptHistory!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("recovered-\(UUID().uuidString)")
        history = TranscriptHistory(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testARetriedRecordingIsTheNewestItemAndKeepsItsOriginalTime() {
        let lost = UUID(), later = UUID()
        // Recorded at t0, killed, nothing recognized: no history record, only saved audio.
        history.begin(id: lost, engine: "moonshineSmall", source: .keyboard, now: t0)
        history.recoverCutOff(now: t0 + 60, activeWindow: 0)
        // A normal dictation an hour later.
        history.begin(id: later, engine: "moonshineSmall", source: .app, now: t0 + 3_600)
        history.finish(id: later, text: "an ordinary dictation", audioSeconds: 3, now: t0 + 3_605)
        // The retry, two hours after the recording.
        history.finish(id: lost, text: "the words that were lost", audioSeconds: 7, status: .finished,
                       engine: "moonshineSmall", source: .keyboard, recoveredFrom: t0, now: t0 + 7_200)

        let records = history.records(now: t0 + 7_300)
        XCTAssertEqual(records.map(\.text), ["the words that were lost", "an ordinary dictation"])
        XCTAssertEqual(records[0].createdAt, t0 + 7_200, "dated when it was transcribed")
        XCTAssertEqual(records[0].recoveredFrom, t0, "keeps when it was recorded")
        XCTAssertNil(records[1].recoveredFrom)
    }

    func testARetryReplacesTheCutOffRecordAndKeepsTheEarliestTime() {
        let id = UUID()
        history.begin(id: id, engine: "moonshineSmall", source: .keyboard, now: t0)
        history.saveProgress(id: id, text: "the first half", audioSeconds: 4, now: t0 + 4)
        history.recoverCutOff(now: t0 + 60, activeWindow: 0)
        XCTAssertEqual(history.records(now: t0 + 61).first?.status, .cutOff)

        // The audio record's own time is a few ms later than the history's begin.
        history.finish(id: id, text: "the first half and the rest", audioSeconds: 9,
                       recoveredFrom: t0 + 0.2, now: t0 + 600)
        var records = history.records(now: t0 + 601)
        XCTAssertEqual(records.count, 1, "the cut-off record is replaced, not duplicated")
        XCTAssertEqual(records[0].status, .finished)
        XCTAssertEqual(records[0].recoveredFrom, t0)
        XCTAssertEqual(records[0].createdAt, t0 + 600)

        // Retrying again later moves it to the top again, still from the same moment.
        history.finish(id: id, text: "the first half and the rest, again", audioSeconds: 9,
                       recoveredFrom: t0 + 0.2, now: t0 + 900)
        records = history.records(now: t0 + 901)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].recoveredFrom, t0)
        XCTAssertEqual(records[0].createdAt, t0 + 900)
    }

    func testOrdinaryRecordsDoNotWriteTheField() throws {
        let id = UUID()
        history.finish(id: id, text: "plain", audioSeconds: 1, now: t0)
        let record = try XCTUnwrap(history.record(id: id))
        XCTAssertNil(record.recoveredFrom)
        let json = try XCTUnwrap(String(data: try JSONEncoder().encode(record), encoding: .utf8))
        XCTAssertFalse(json.contains("recoveredFrom"), "absent for ordinary dictations, so older builds read the same shape")
    }
}
