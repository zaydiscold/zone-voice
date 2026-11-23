// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class TranscriptHistoryTests: XCTestCase {
    private var directory: URL!
    private var history: TranscriptHistory!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString)")
        history = TranscriptHistory(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAFinishedDictationIsKeptNewestFirst() {
        let a = UUID(), b = UUID()
        history.begin(id: a, engine: "moonshineTiny", source: .keyboard, now: t0)
        history.finish(id: a, text: "first one", audioSeconds: 2, now: t0 + 5)
        history.begin(id: b, engine: "moonshineTiny", source: .app, now: t0 + 10)
        history.finish(id: b, text: "  second one  ", audioSeconds: 3, now: t0 + 15)
        let records = history.records(now: t0 + 20)
        XCTAssertEqual(records.map(\.text), ["second one", "first one"])
        XCTAssertEqual(records[1].engine, "moonshineTiny")
        XCTAssertEqual(records[1].source, .keyboard)
        XCTAssertEqual(records[1].createdAt, t0, "created when recording began, not when it finished")
    }

    func testEmptyResultsAreNotKept() {
        let id = UUID()
        history.begin(id: id, engine: "e", source: .app, now: t0)
        history.finish(id: id, text: "   ", audioSeconds: 1, now: t0 + 1)
        XCTAssertTrue(history.records(now: t0 + 2).isEmpty)
    }

    func testACutOffDictationKeepsEverythingSavedSoFar() {
        // The app is killed mid-dictation: begin and two progress saves, no finish.
        let id = UUID()
        history.begin(id: id, engine: "moonshineTiny", source: .keyboard, now: t0)
        history.saveProgress(id: id, text: "this is a long", audioSeconds: 3, now: t0 + 3)
        history.saveProgress(id: id, text: "this is a long dictation that got cut", audioSeconds: 8, now: t0 + 8)

        // A fresh process (the relaunched app) recovers it.
        let relaunched = TranscriptHistory(directory: directory)
        let recovered = relaunched.recoverCutOff(now: t0 + 120)
        XCTAssertEqual(recovered.map(\.text), ["this is a long dictation that got cut"])
        let record = relaunched.records(now: t0 + 121).first
        XCTAssertEqual(record?.status, .cutOff)
        XCTAssertEqual(record?.audioSeconds, 8)
        XCTAssertTrue(relaunched.recoverCutOff(now: t0 + 200).isEmpty, "recovered once only")
    }

    func testARecordingStillRunningIsNotRecovered() {
        let id = UUID()
        history.begin(id: id, engine: "e", source: .app, now: t0)
        history.saveProgress(id: id, text: "still talking", audioSeconds: 2, now: t0 + 2)
        XCTAssertTrue(history.recoverCutOff(now: t0 + 10).isEmpty)
        history.finish(id: id, text: "still talking, done", audioSeconds: 4, now: t0 + 12)
        XCTAssertEqual(history.records(now: t0 + 13).map(\.text), ["still talking, done"])
    }

    func testCancelKeepsNothing() {
        let id = UUID()
        history.begin(id: id, engine: "e", source: .app, now: t0)
        history.saveProgress(id: id, text: "never mind", audioSeconds: 1, now: t0 + 1)
        history.cancel(id: id)
        XCTAssertTrue(history.recoverCutOff(now: t0 + 600).isEmpty)
        XCTAssertTrue(history.records(now: t0 + 600).isEmpty)
    }

    func testMarkRecordsWhereItWentAndTakesNewStatuses() {
        let id = UUID()
        history.finish(id: id, text: "hello", audioSeconds: 1, status: .offered, engine: "e", source: .keyboard, now: t0)
        history.mark(id: id, status: .dismissed, now: t0 + 1)
        XCTAssertEqual(history.record(id: id)?.status, .dismissed)
        // A later part of Zone can add its own status and destination without a schema change.
        history.mark(id: id, status: TranscriptStatus(rawValue: "sentToMac"), destination: "MacBook Pro", now: t0 + 2)
        let reread = TranscriptHistory(directory: directory).record(id: id)
        XCTAssertEqual(reread?.status.rawValue, "sentToMac")
        XCTAssertEqual(reread?.destination, "MacBook Pro")
    }

    func testStatusLabelsCoverRemoteValuesAndLeaveUnknownOnesBlank() {
        XCTAssertEqual(TranscriptStatus(rawValue: "notDelivered").label, "Not delivered")
        XCTAssertEqual(TranscriptStatus.heldOnComputer.label, "Held on computer")
        XCTAssertEqual(TranscriptStatus.cutOff.label, "Cut off, saved")
        XCTAssertNil(TranscriptStatus.inserted.label)
        XCTAssertNil(TranscriptStatus(rawValue: "somethingNew").label)
    }

    func testRetentionPrunesByAge() {
        history.setRetention(.sevenDays, now: t0)
        let old = UUID(), fresh = UUID()
        history.finish(id: old, text: "old", audioSeconds: 1, engine: "e", source: .app, now: t0)
        history.finish(id: fresh, text: "fresh", audioSeconds: 1, engine: "e", source: .app, now: t0 + 6 * 86_400)
        XCTAssertEqual(history.records(now: t0 + 8 * 86_400).map(\.text), ["fresh"])
        history.purgeExpired(now: t0 + 8 * 86_400)
        XCTAssertNil(history.record(id: old), "Expired text must be removed from disk, not just hidden")
        history.setRetention(.untilDeleted, now: t0)
        XCTAssertEqual(history.retention, .untilDeleted)
    }

    func testTheDefaultKeepsDictationsUntilDeleted() {
        XCTAssertEqual(history.retention, .untilDeleted)
        let id = UUID()
        history.finish(id: id, text: "kept for good", audioSeconds: 1, engine: "e", source: .app, now: t0)
        history.purgeExpired(now: t0 + 400 * 86_400)
        XCTAssertEqual(history.records(now: t0 + 400 * 86_400).map(\.id), [id])
    }

    /// Through 1.0.1 a new history file was written with "thirtyDays" whether or not anyone chose
    /// it. Updating must not start deleting month-old dictations: that value becomes the new default.
    func testTheOldThirtyDayDefaultMigratesWithoutDeletingAnything() throws {
        let old = UUID()
        let json = #"{"retention":"thirtyDays","records":[{"id":"\#(old.uuidString)","updatedAt":"2027-01-15T08:00:00Z","createdAt":"2027-01-15T08:00:00Z","text":"from the old build","source":"app","status":"finished","audioSeconds":3,"engine":"e"}]}"#
        try Data(json.utf8).write(to: directory.appendingPathComponent("history.json"))
        let updated = TranscriptHistory(directory: directory)
        XCTAssertEqual(updated.retention, .untilDeleted)
        let muchLater = t0 + 365 * 86_400
        updated.finish(id: UUID(), text: "a new one", audioSeconds: 1, engine: "e", source: .app, now: muchLater)
        updated.purgeExpired(now: muchLater)
        XCTAssertNotNil(updated.record(id: old), "the first write after updating must not prune by the old default")
        XCTAssertEqual(TranscriptHistory(directory: directory).retention, .untilDeleted)
    }

    func testAChosenThirtyDaysIsKeptAndStillPrunes() {
        history.setRetention(.thirtyDays, now: t0)
        let relaunched = TranscriptHistory(directory: directory)
        XCTAssertEqual(relaunched.retention, .thirtyDays, "a deliberate choice survives the migration")
        relaunched.finish(id: UUID(), text: "kept a while", audioSeconds: 1, engine: "e", source: .app, now: t0)
        XCTAssertEqual(relaunched.records(now: t0 + 29 * 86_400).count, 1)
        XCTAssertEqual(relaunched.records(now: t0 + 31 * 86_400).count, 0)
    }

    func testOtherStoredRetentionsAreLeftAlone() throws {
        for (raw, expected) in [("off", HistoryRetention.off), ("sevenDays", .sevenDays), ("untilDeleted", .untilDeleted)] {
            try Data(#"{"retention":"\#(raw)","records":[]}"#.utf8).write(to: directory.appendingPathComponent("history.json"))
            XCTAssertEqual(TranscriptHistory(directory: directory).retention, expected, raw)
        }
    }

    /// History's retention and Delete All only ever rewrite history.json. Notes live in their own
    /// file (the app's notes.json, through LibraryNotesFile) and survive every one of them, even
    /// a note older than any retention and the history record of the dictation that made it.
    func testRetentionAndDeleteAllNeverTouchNotes() throws {
        let notesURL = directory.appendingPathComponent("notes.json")
        let note = LibraryNote(text: "a year-old note", createdAt: t0)
        try LibraryNotesFile.write([note], to: notesURL)
        let before = try Data(contentsOf: notesURL)
        history.finish(id: UUID(), text: "a year-old note", audioSeconds: 1, status: .note, engine: "e", source: .note, now: t0)
        let later = t0 + 365 * 86_400
        for retention in [HistoryRetention.sevenDays, .thirtyDays, .off] { history.setRetention(retention, now: later) }
        history.purgeExpired(now: later)
        history.deleteAll()
        XCTAssertTrue(history.records(now: later).isEmpty)
        XCTAssertEqual(try Data(contentsOf: notesURL), before)
        XCTAssertEqual(try LibraryNotesFile.read(at: notesURL), [note])
    }

    func testOffKeepsNothingFinishedButStillRescuesACutOff() {
        history.setRetention(.off, now: t0)
        history.finish(id: UUID(), text: "gone", audioSeconds: 1, engine: "e", source: .app, now: t0)
        XCTAssertTrue(history.records(now: t0).isEmpty)

        let id = UUID()
        history.begin(id: id, engine: "e", source: .keyboard, now: t0)
        history.saveProgress(id: id, text: "rescued anyway", audioSeconds: 2, now: t0 + 2)
        XCTAssertEqual(history.recoverCutOff(now: t0 + 100).map(\.text), ["rescued anyway"])
        XCTAssertEqual(history.recent(limit: 5, now: t0 + 101).map(\.id), [id])
        history.finish(id: UUID(), text: "normal result still discarded", audioSeconds: 1, now: t0 + 102)
        let relaunched = TranscriptHistory(directory: directory)
        XCTAssertEqual(relaunched.search("rescued", now: t0 + 103).map(\.id), [id])
        relaunched.mark(id: id, status: .inserted, now: t0 + 104)
        XCTAssertTrue(relaunched.records(now: t0 + 105).isEmpty)
    }

    func testRetentionNeverSilentlyDropsRecordsByCount() {
        // Through pruned() directly: a thousand full-file writes would take the suite 25 s.
        let many = (0..<(1_005)).reversed().map { i in
            TranscriptRecord(id: UUID(), text: "n\(i)", createdAt: t0 + Double(i), updatedAt: t0 + Double(i),
                             audioSeconds: 1, engine: "e", source: .app, status: .finished)
        }
        let kept = TranscriptHistory.pruned(many, retention: .thirtyDays, now: t0 + 5_000)
        XCTAssertEqual(TranscriptHistory.pruned(many, retention: .untilDeleted, now: t0 + 5_000).count, many.count, "Until I delete must not silently remove older transcripts")
        XCTAssertEqual(kept.count, many.count)
        XCTAssertEqual(kept.first?.text, "n\(1_004)", "the newest survive")
    }

    func testDeleteAndDeleteAllAndSearch() {
        let a = UUID(), b = UUID()
        history.finish(id: a, text: "Meet Priya at noon", audioSeconds: 1, engine: "e", source: .app, now: t0)
        history.finish(id: b, text: "Café order", audioSeconds: 1, engine: "e", source: .app, now: t0 + 1)
        XCTAssertEqual(history.search("priya", now: t0 + 2).map(\.id), [a])
        XCTAssertEqual(history.search("cafe", now: t0 + 2).map(\.id), [b])
        history.delete(id: a)
        XCTAssertEqual(history.records(now: t0 + 2).map(\.id), [b])
        history.deleteAll()
        XCTAssertTrue(history.records(now: t0 + 2).isEmpty)
    }
    func testFailedFinalWritePreservesRecoveryUntilRetryCommits() throws {
        let id = UUID()
        history.begin(id: id, engine: "e", source: .keyboard, now: t0)
        history.saveProgress(id: id, text: "saved progress", audioSeconds: 2, now: t0 + 2)
        let destination = directory.appendingPathComponent("history.json")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        history.finish(id: id, text: "completed text", audioSeconds: 3, now: t0 + 3)
        let recovery = directory.appendingPathComponent("inflight/\(id).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.path))
        try FileManager.default.removeItem(at: destination)
        history.finish(id: id, text: "completed text", audioSeconds: 3, now: t0 + 4)
        XCTAssertEqual(history.records(now: t0 + 5).map(\.text), ["completed text"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.path))
        XCTAssertTrue(history.recoverCutOff(now: t0 + 100).isEmpty)
    }

    func testFailedRecoveryWriteLeavesInflightForNextLaunch() throws {
        let id = UUID()
        history.begin(id: id, engine: "e", source: .keyboard, now: t0)
        history.saveProgress(id: id, text: "rescue me", audioSeconds: 2, now: t0 + 2)
        let destination = directory.appendingPathComponent("history.json")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        XCTAssertTrue(history.recoverCutOff(now: t0 + 100).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("inflight/\(id).json").path))
        try FileManager.default.removeItem(at: destination)
        let relaunched = TranscriptHistory(directory: directory)
        XCTAssertEqual(relaunched.recoverCutOff(now: t0 + 101).map(\.id), [id])
        XCTAssertEqual(relaunched.records(now: t0 + 102).map(\.text), ["rescue me"])
        XCTAssertTrue(relaunched.recoverCutOff(now: t0 + 103).isEmpty)
    }

    func testFailedFinalCommitCanRecoverFinalTextWithoutRetryingFinish() throws {
        let id = UUID()
        history.begin(id: id, engine: "e", source: .keyboard, now: t0)
        let destination = directory.appendingPathComponent("history.json")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        history.finish(id: id, text: "words only available after final flush", audioSeconds: 8, now: t0 + 8)
        try FileManager.default.removeItem(at: destination)
        let relaunched = TranscriptHistory(directory: directory)
        XCTAssertEqual(relaunched.recoverCutOff(now: t0 + 100).map(\.text), ["words only available after final flush"])
        XCTAssertEqual(relaunched.records(now: t0 + 101).count, 1)
    }

}
