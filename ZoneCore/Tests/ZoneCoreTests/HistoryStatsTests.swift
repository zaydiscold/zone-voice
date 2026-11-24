import XCTest
@testable import ZoneCore

final class HistoryStatsTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let start = Date(timeIntervalSince1970: 1_000_000.25)
    private var app: TranscriptHistory { TranscriptHistory(directory: root) }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    func testTransferBeforeImportKeepsNewKeyboardReceiptsAndResetClearsCache() throws {
        let suite = "stats-transfer-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func phone(_ name: String) -> TranscriptHistory {
            TranscriptHistory(directory: root.appendingPathComponent(name), transferDefaults: defaults)
        }
        let old = phone("old")
        _ = old.stats(legacyWords: 50, legacySeconds: 10, since: nil)
        let id = UUID()
        XCTAssertTrue(old.finish(id: id, text: "one two three", audioSeconds: 4, statsStartedAt: start))
        old.confirmKept(id: id, words: 2)
        let original = try XCTUnwrap(old.stats(legacyWords: 0, legacySeconds: 0, since: nil)).0
        let backup = try old.backupData()
        let transferred = phone("new")
        for offset in 1...2 {
            XCTAssertTrue(transferred.finish(id: UUID(), text: "four five", audioSeconds: 3,
                                             statsStartedAt: start + Double(offset)))
        }
        var expected = original
        expected.count += 2
        expected.words += 4
        expected.seconds += 6
        expected.measuredSeconds += 6
        for _ in 0..<2 {
            try phone("new").importBackupData(backup)
            XCTAssertEqual(phone("new").stats(legacyWords: 0, legacySeconds: 0, since: nil)?.0, expected)
        }
        XCTAssertTrue(transferred.resetStats())
        XCTAssertEqual(phone("reset-transfer").stats(legacyWords: 0, legacySeconds: 0, since: nil)?.0, DictationTotals())
    }

    func testTransferOfAnAlreadyTransferredPhoneCanImportBothBackups() throws {
        let original = app
        XCTAssertTrue(original.finish(id: UUID(), text: "one two three", audioSeconds: 4, statsStartedAt: start))
        let seed = try XCTUnwrap(original.stats(legacyWords: 0, legacySeconds: 0, since: nil)).0
        let second = TranscriptHistory(directory: root.appendingPathComponent("second"))
        XCTAssertEqual(second.stats(legacyWords: 0, legacySeconds: 0, since: nil, transferred: seed)?.0, seed)
        XCTAssertTrue(second.finish(id: UUID(), text: "four five", audioSeconds: 3, statsStartedAt: start + 10))
        let expected = try XCTUnwrap(second.stats(legacyWords: 0, legacySeconds: 0, since: nil)).0
        let third = TranscriptHistory(directory: root.appendingPathComponent("third"))
        XCTAssertEqual(third.stats(legacyWords: 0, legacySeconds: 0, since: nil, transferred: expected)?.0, expected)
        for source in [second, second, original, original, second] {
            try third.importBackupData(source.backupData())
            XCTAssertEqual(third.stats(legacyWords: 0, legacySeconds: 0, since: nil)?.0, expected)
        }
    }

    func testExistingReceiptsAndExistingZeroBaselineIgnoreTransferCache() throws {
        var stale = DictationTotals()
        stale.words = 1000
        let history = app
        XCTAssertTrue(history.finish(id: UUID(), text: "already here", audioSeconds: 3, statsStartedAt: start))
        XCTAssertEqual(history.stats(legacyWords: 0, legacySeconds: 0, since: nil, transferred: stale)?.0.words, 2)
        XCTAssertTrue(history.resetStats())
        XCTAssertEqual(history.stats(legacyWords: 0, legacySeconds: 0, since: nil, transferred: stale)?.0, DictationTotals())
    }

    func testPartialBackupReconcilesEachTransferredFieldIndependently() throws {
        var cached = DictationTotals()
        cached.words = 2
        cached.count = 2
        cached.seconds = 10
        cached.kept = 2
        cached.measuredSeconds = 9
        let dest = app
        XCTAssertEqual(dest.stats(legacyWords: 0, legacySeconds: 0, since: nil, transferred: cached)?.0, cached)
        let source = TranscriptHistory(directory: root.appendingPathComponent("backup"))
        XCTAssertTrue(source.finish(id: UUID(), text: "one two three", audioSeconds: 4, statsStartedAt: start))
        let backup = try source.backupData()
        for _ in 0..<2 {
            try dest.importBackupData(backup)
            let total = try XCTUnwrap(app.stats(legacyWords: 0, legacySeconds: 0, since: nil)).0
            XCTAssertEqual(total.words, 3)
            XCTAssertEqual(total.count, 2)
            XCTAssertEqual(total.kept, 2)
            XCTAssertEqual(total.seconds, 10)
            XCTAssertEqual(total.measuredSeconds, 9)
        }
    }

    func testConcurrentRecordersReplayAndLateDelivery() throws {
        let ids = (0..<12).map { _ in UUID() }
        let writers = [app, TranscriptHistory(directory: root, keepsDecodedFile: false)]
        DispatchQueue.concurrentPerform(iterations: ids.count) { index in
            let store = writers[index % writers.count], date = start.addingTimeInterval(Double(index))
            for _ in 0..<2 {
                XCTAssertTrue(store.finish(id: ids[index], text: "one two three", audioSeconds: 4.25,
                                           source: index.isMultiple(of: 2) ? .app : .keyboard, statsStartedAt: date, now: date))
            }
            store.mark(id: ids[index], status: .offered)
        }
        let cutoff = start.addingTimeInterval(6)
        let initial = try XCTUnwrap(app.stats(legacyWords: 0, legacySeconds: 0, since: cutoff))
        XCTAssertEqual(initial.0.count, 12); XCTAssertEqual(initial.0.words, 36); XCTAssertEqual(initial.0.kept, 0)
        XCTAssertEqual(initial.0.measuredSeconds, 51); XCTAssertEqual(initial.1.count, 6)
        let keyboard = writers[1], id = ids[9]
        for _ in 0..<2 { keyboard.mark(id: id, status: .inserted, keptWords: 2) }
        XCTAssertEqual(app.stats(legacyWords: 0, legacySeconds: 0, since: cutoff)?.1.kept, 2)
        keyboard.mark(id: id, status: .dismissed, keptWords: 0)
        XCTAssertEqual(app.stats(legacyWords: 0, legacySeconds: 0, since: cutoff)?.0.kept, 0)
        keyboard.mark(id: id, status: .inserted, keptWords: 200)
        XCTAssertEqual(app.stats(legacyWords: 0, legacySeconds: 0, since: cutoff)?.0.kept, 3)
        app.confirmKept(id: id, words: 2)
        keyboard.mark(id: id, status: .dismissed, keptWords: 0)
        XCTAssertEqual(app.stats(legacyWords: 0, legacySeconds: 0, since: cutoff)?.0.kept, 2)
        XCTAssertEqual(app.stats(legacyWords: 0, legacySeconds: 0, since: start + 20)?.1.count, 0)
    }

    func testUpgradePreservesOpaqueRemainderAndReplacesDurationRecord() throws {
        let history = app, long = UUID(), verbose = UUID()
        history.finish(id: long, text: "one", audioSeconds: 600, now: start)
        history.finish(id: verbose, text: "one two three four", audioSeconds: 8, now: start + 10)
        let initial = try XCTUnwrap(history.stats(legacyWords: 105, legacySeconds: 780, since: nil)).0
        XCTAssertEqual(initial.words, 105); XCTAssertEqual(initial.seconds, 780); XCTAssertEqual(initial.kept, 0)
        XCTAssertEqual(initial.measuredSeconds, 0); XCTAssertEqual(initial.longest?.words, 4)
        XCTAssertTrue(app.delete(id: verbose))
        let after = try XCTUnwrap(app.stats(legacyWords: 105, legacySeconds: 780, since: nil)).0
        XCTAssertEqual(after, initial)
    }

    func testOldResetCannotBackfillFromOlderHistory() throws {
        let history = app
        history.finish(id: UUID(), text: "still in history", audioSeconds: 10, now: start)
        let stats = try XCTUnwrap(history.stats(legacyWords: 0, legacySeconds: 0, since: nil)).0
        XCTAssertEqual(stats, DictationTotals()); XCTAssertEqual(history.records().count, 1)
    }

    func testLargeLibraryMigrationKeepsNumericArchiveCompactAndIdempotent() throws {
        let history = app, count = 2_556
        var old = TranscriptHistory.File()
        let text = Array(repeating: "word", count: 20).joined(separator: " ")
        for index in 0..<count {
            let date = start + Double(index)
            old.records.append(TranscriptRecord(id: UUID(), text: text, createdAt: date, updatedAt: date,
                                                audioSeconds: 12, engine: "test", source: .app, status: .finished))
        }
        XCTAssertEqual(try history.importBackupData(old.encoded()), count)
        let before = try history.backupData().count
        let migrated = try XCTUnwrap(history.stats(legacyWords: count * 20, legacySeconds: Double(count * 12), since: nil))
        XCTAssertEqual(migrated.0.count, count)
        XCTAssertEqual(migrated.0.words, count * 20)
        XCTAssertEqual(migrated.0.kept, 0)
        let archive = try history.backupData()
        let added = archive.count - before
        XCTAssertGreaterThan(added, 0)
        XCTAssertLessThan(added, count * 192)
        XCTAssertEqual(app.stats(legacyWords: 0, legacySeconds: 0, since: nil)?.0, migrated.0)
        XCTAssertEqual(try history.backupData(), archive)
        print("[stats-index] \(count) synthetic rows: \(before) bytes before, \(archive.count) after, \(added) added")
    }

    func testOldKeyboardHistoryCanSetRecordWithoutInventingLegacyCounterMembership() throws {
        let history = app, id = UUID()
        history.finish(id: UUID(), text: "old app", audioSeconds: 600, now: start)
        history.finish(id: id, text: "a longer keyboard dictation", audioSeconds: 3, engine: "zoneMini", source: .keyboard, now: start + 10)
        let before = try XCTUnwrap(history.stats(legacyWords: 2, legacySeconds: 600, since: nil)).0
        XCTAssertEqual(before.words, 2); XCTAssertEqual(before.longest?.words, 4)
        XCTAssertTrue(history.delete(id: id))
        let after = try XCTUnwrap(history.stats(legacyWords: 2, legacySeconds: 600, since: nil)).0
        XCTAssertEqual(after, before)
    }

    func testHistoryOffStillCountsOneRequestAcrossHistoryDeletion() throws {
        let history = app, id = UUID()
        history.setRetention(.off)
        for _ in 0..<2 {
            XCTAssertFalse(history.finish(id: id, text: "one two", audioSeconds: 5, statsStartedAt: start, now: start))
        }
        XCTAssertTrue(history.records().isEmpty)
        history.confirmKept(id: id, words: 2)
        XCTAssertEqual(history.stats(legacyWords: 0, legacySeconds: 0, since: start)?.0.kept, 2)
        XCTAssertTrue(history.delete(createdIn: (start - 1)...(start + 1)))
        XCTAssertEqual(app.stats(legacyWords: 0, legacySeconds: 0, since: start)?.0.kept, 2)
        XCTAssertTrue(history.deleteAllWithRecovery(clearingStats: false))
        XCTAssertEqual(app.stats(legacyWords: 0, legacySeconds: 0, since: start)?.0.words, 2)
    }

    func testMalformedReceiptAndFieldsLeaveOtherReceiptsAndResetIntact() throws {
        let id = UUID()
        let valid: [String: Any] = ["words": 4, "start": 101, "seconds": 8, "kept": 3]
        let stats: [String: Any] = ["entries": [id.uuidString.lowercased(): valid, UUID().uuidString: ["words": "bad"]],
                                    "unmatchedWords": 12, "unmatchedSeconds": "bad", "reset": 100]
        let data = try JSONSerialization.data(withJSONObject: ["stats": stats, "records": []])
        try app.importBackupData(data)
        app.finish(id: UUID(), text: "before reset", audioSeconds: 2, statsStartedAt: Date(timeIntervalSince1970: 99))
        let totals = try XCTUnwrap(app.stats(legacyWords: 0, legacySeconds: 0, since: nil)).0
        XCTAssertEqual(totals.words, 16)
        XCTAssertEqual(totals.kept, 3)
        XCTAssertEqual(totals.seconds, 8)
    }

    func testMalformedUnmatchedWordsCannotRestartMigration() throws {
        let stats: [String: Any] = ["unmatchedWords": "bad", "entries": [
            UUID().uuidString: ["words": 4, "seconds": 8, "start": 101]
        ]]
        let archive = try JSONSerialization.data(withJSONObject: ["stats": stats, "records": []])
        _ = try app.importBackupData(archive)
        let all = try XCTUnwrap(app.stats(legacyWords: 4, legacySeconds: 8, since: nil)).0
        XCTAssertEqual(all.words, 4)
        XCTAssertEqual(all.seconds, 8)
    }

    func testAccumulatingOverPreStatsFolderDropsThePhoneReset() throws {
        let previous = LibraryBackup(notes: [], dictations: [], meetings: [], historyArchive: Data(#"{"records":[]}"#.utf8))
        XCTAssertTrue(app.resetStats(now: start))
        let current = LibraryBackup(notes: [], dictations: [], meetings: [], historyArchive: try app.backupData())
        let destination = TranscriptHistory(directory: root.appendingPathComponent("destination"))
        _ = try destination.importBackupData(XCTUnwrap(current.accumulating(previous).historyArchive))
        destination.finish(id: UUID(), text: "older import", audioSeconds: 2, statsStartedAt: start - 1)
        XCTAssertEqual(destination.stats(legacyWords: 0, legacySeconds: 0, since: nil)?.0.words, 2)
    }

    func testPartialRetryReplacesTheSameMeasurementAndFailedNoteHasNoSavingsCost() throws {
        let id = UUID(), note = UUID()
        app.finish(id: id, text: "partial", audioSeconds: 9, statsStartedAt: start)
        app.finish(id: id, text: "all three words", audioSeconds: 12, recoveredFrom: start, statsStartedAt: start)
        app.confirmKept(id: id, words: 3)
        app.finish(id: note, text: "unsaved note", audioSeconds: 30, status: .note, statsStartedAt: start)
        app.finish(id: note, text: "unsaved note", audioSeconds: 30, status: .cutOff)
        let totals = try XCTUnwrap(app.stats(legacyWords: 0, legacySeconds: 0, since: nil)).0
        XCTAssertEqual(totals.count, 2)
        XCTAssertEqual(totals.words, 5)
        XCTAssertEqual(totals.seconds, 42)
        XCTAssertEqual(totals.kept, 3)
        XCTAssertEqual(totals.measuredSeconds, 12)
    }

    func testAccumulationAcrossPhoneResetAndAdditiveLegacyRestore() throws {
        func snapshot() throws -> LibraryBackup {
            LibraryBackup(notes: [], dictations: [], meetings: [], historyArchive: try app.backupData())
        }
        _ = app.stats(legacyWords: 77, legacySeconds: 90, since: nil)
        let id = UUID()
        app.finish(id: id, text: "first pair", audioSeconds: 2, statsStartedAt: start)
        app.mark(id: id, status: .inserted, keptWords: 2)
        let before = try snapshot()
        app.mark(id: id, status: .dismissed, keptWords: 0)
        app.confirmKept(id: id, words: 1)
        let folder = try snapshot().accumulating(before)
        XCTAssertTrue(app.resetStats(now: start + 1))
        app.finish(id: UUID(), text: "second", audioSeconds: 4, statsStartedAt: start + 3)
        let archive = try XCTUnwrap(snapshot().accumulating(folder).historyArchive)
        let destination = TranscriptHistory(directory: root.appendingPathComponent("onboarding"))
        destination.finish(id: UUID(), text: "onboarding", audioSeconds: 3, statsStartedAt: start)
        for _ in 0..<2 { _ = try destination.importBackupData(archive) }
        let totals = try XCTUnwrap(destination.stats(legacyWords: 0, legacySeconds: 0, since: nil)).0
        XCTAssertEqual(totals.count, 3)
        XCTAssertEqual(totals.words, 81)
        XCTAssertEqual(totals.seconds, 99)
        XCTAssertEqual(totals.kept, 2)
    }

    func testRetentionOffKeepsReceiptsAndDeduplicatesOlderSnapshots() throws {
        app.setRetention(.off, now: start)
        let id = UUID()
        _ = app.stats(legacyWords: 0, legacySeconds: 0, since: nil)
        app.finish(id: id, text: "first pair", audioSeconds: 5, statsStartedAt: start, now: start)
        app.confirmKept(id: id, words: 2)
        let before = try app.backupData()
        let tomorrow = start + AudioRecoveryStore.failedRetention + 1
        app.finish(id: UUID(), text: "new", audioSeconds: 1, statsStartedAt: tomorrow, now: tomorrow)
        let after = try app.backupData()
        XCTAssertTrue(String(decoding: after, as: UTF8.self).contains(id.uuidString))
        let reference = try XCTUnwrap(app.stats(legacyWords: 0, legacySeconds: 0, since: tomorrow))
        XCTAssertEqual(reference.1.words, 1)
        XCTAssertEqual(reference.0.words, 3)
        XCTAssertEqual(reference.0.longest?.words, 2)
        XCTAssertEqual(reference.0.kept, 2)
        XCTAssertEqual(reference.0.measuredSeconds, 6)
        for archives in [[before, after, after], [after, before, before]] {
            let restored = TranscriptHistory(directory: root.appendingPathComponent(UUID().uuidString))
            for archive in archives { _ = try restored.importBackupData(archive) }
            XCTAssertEqual(restored.stats(legacyWords: 0, legacySeconds: 0, since: nil)?.0, reference.0)
        }
    }

    func testResetBetweenTwoExpiredReceiptsKeepsTheLaterOneOnImport() throws {
        app.setRetention(.off, now: start)
        _ = app.stats(legacyWords: 0, legacySeconds: 0, since: nil)
        app.finish(id: UUID(), text: "old", audioSeconds: 8, statsStartedAt: start, now: start)
        let later = start + 2
        let id = UUID()
        app.finish(id: id, text: "after reset", audioSeconds: 6, statsStartedAt: later, now: later)
        app.confirmKept(id: id, words: 2)
        // In a compacting build, this finish collapsed both older IDs into a single range.
        let recent = later + AudioRecoveryStore.failedRetention + 1
        app.finish(id: UUID(), text: "recent", audioSeconds: 3, statsStartedAt: recent, now: recent)
        let restored = TranscriptHistory(directory: root.appendingPathComponent("reset"))
        XCTAssertTrue(restored.resetStats(now: start + 1))
        let archive = try app.backupData()
        for _ in 0..<2 { _ = try restored.importBackupData(archive) }
        let all = try XCTUnwrap(restored.stats(legacyWords: 0, legacySeconds: 0, since: nil)).0
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.words, 3)
        XCTAssertEqual(all.kept, 2)
        XCTAssertEqual(all.seconds, 9)
    }

    func testLegacyAggregatesFoldOnceAndRejectInvalidLongest() throws {
        let valid = ["words": 4, "seconds": 8, "start": 100]
        let invalid = ["words": 100_000_000, "seconds": 8, "start": 100]
        func aggregate(_ best: [String: Int]) -> [String: Any] {
            ["first": 100, "through": 200, "words": 4, "seconds": 8,
             "count": 1, "kept": 3, "measuredSeconds": 8, "longest": best]
        }
        let stats: [String: Any] = ["prefixes": [UUID().uuidString: aggregate(valid),
                                                  UUID().uuidString: aggregate(invalid)]]
        let old = try JSONSerialization.data(withJSONObject: ["stats": stats, "records": []])
        // A test build left the compacted archive on disk. Refresh upgrades the file.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try old.write(to: root.appendingPathComponent("history.json"))
        _ = try XCTUnwrap(app.stats(legacyWords: 999, legacySeconds: 999, since: nil))
        let archive = try app.backupData()
        XCTAssertFalse(String(decoding: archive, as: UTF8.self).contains("prefixes"))
        _ = try app.importBackupData(archive)
        _ = try app.importBackupData(old)
        let (all, session) = try XCTUnwrap(app.stats(legacyWords: 999, legacySeconds: 999, since: .distantPast))
        XCTAssertEqual(all.words, 8)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.seconds, 16)
        XCTAssertEqual(all.kept, 6)
        XCTAssertEqual(all.measuredSeconds, 16)
        XCTAssertEqual(all.longest?.words, 4)
        XCTAssertEqual(session, DictationTotals())
    }

    func testNewerRecoveryWinsInEitherImportOrder() throws {
        let id = UUID()
        app.finish(id: id, text: "partial", audioSeconds: 2, statsStartedAt: start, now: start)
        app.confirmKept(id: id, words: 1)
        let partial = try app.backupData()
        app.finish(id: id, text: "full three words", audioSeconds: 8, recoveredFrom: start,
                   statsStartedAt: start, now: start + 10)
        app.mark(id: id, status: .inserted, keptWords: 3)
        let full = try app.backupData()
        for order in [[partial, full], [full, partial]] {
            let restored = TranscriptHistory(directory: root.appendingPathComponent(UUID().uuidString))
            for archive in order { _ = try restored.importBackupData(archive) }
            let all = try XCTUnwrap(restored.stats(legacyWords: 0, legacySeconds: 0, since: nil)).0
            XCTAssertEqual(all.words, 3)
            XCTAssertEqual(all.seconds, 8)
            XCTAssertEqual(all.kept, 3)
            XCTAssertEqual(all.count, 1)
        }
    }

    func testHistoryOffReportsACommittedReceiptAndAWriteFailureSeparately() throws {
        let history = app
        history.setRetention(.off)
        XCTAssertEqual(history.finishOutcome(id: UUID(), text: "saved", audioSeconds: 2, statsStartedAt: start, now: start), .retentionOff)
        let archive = root.appendingPathComponent("history.json")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: archive.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path) }
        XCTAssertEqual(app.finishOutcome(id: UUID(), text: "blocked", audioSeconds: 2, statsStartedAt: start, now: start), .failed)
    }

    func testBackupExportRestoreResetBarrierAndWipe() throws {
        let history = app, id = UUID()
        history.finish(id: id, text: "one two", audioSeconds: 8, statsStartedAt: start, now: start)
        history.confirmKept(id: id, words: 1)
        let original = try XCTUnwrap(history.stats(legacyWords: 10, legacySeconds: 60, since: nil)).0
        let archive = try history.backupData()
        let backup = LibraryBackup(notes: [], dictations: try TranscriptHistory.recordsInBackup(archive), meetings: [], historyArchive: archive)
        let portable = try XCTUnwrap(LibraryBackup.decode(LibraryBackup.encoder.encode(backup)).historyArchive)
        let destination = TranscriptHistory(directory: root.appendingPathComponent("restored"))
        _ = destination.stats(legacyWords: 0, legacySeconds: 0, since: nil)
        for _ in 0..<2 { _ = try destination.importBackupData(portable) }
        XCTAssertEqual(destination.stats(legacyWords: 0, legacySeconds: 0, since: nil)?.0, original)
        XCTAssertTrue(destination.resetStats(now: start + 1))
        XCTAssertEqual(destination.records().count, 1)
        destination.finish(id: id, text: "late retry", audioSeconds: 9, statsStartedAt: start, now: start + 2)
        destination.confirmKept(id: id, words: 2)
        _ = try destination.importBackupData(portable)
        XCTAssertEqual(destination.stats(legacyWords: 10, legacySeconds: 60, since: nil)?.0, DictationTotals())
        destination.finish(id: UUID(), text: "after reset", audioSeconds: 3, statsStartedAt: start + 3)
        XCTAssertEqual(destination.stats(legacyWords: 10, legacySeconds: 60, since: nil)?.0.words, 2)
        XCTAssertTrue(destination.deleteAllWithRecovery(clearingStats: true))
        XCTAssertTrue(destination.records().isEmpty)
        XCTAssertEqual(destination.stats(legacyWords: 10, legacySeconds: 60, since: nil)?.0, DictationTotals())
        XCTAssertFalse(String(decoding: try destination.backupData(), as: UTF8.self).contains(id.uuidString))
    }
}
