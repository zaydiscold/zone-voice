// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// Measures, with real files, how many bytes the history and the folder backup write per
/// dictation, before and after the backup's minimum interval and identical-file skipping.
/// MetricKit on the phone showed 3 to 19 GB a day, nearly all of it in
/// `LibraryBackupFiles.write`. The numbers print to the test log; the assertions guard the ratios.
final class BackupWriteVolumeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    // MARK: Byte counting

    /// Every regular file under `folder` by path: its inode, size and modification time.
    private func state(_ folder: URL) -> [String: (inode: Int, size: Int, modified: Date)] {
        var result: [String: (Int, Int, Date)] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        for case let url as URL in FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) ?? .init() {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { continue }
            result[url.path] = ((attributes[.systemFileNumber] as? Int) ?? 0, values.fileSize ?? 0,
                                values.contentModificationDate ?? .distantPast)
        }
        return result
    }

    /// Bytes written by `work` under `folder`: the size of every file created or replaced.
    private func bytesWritten(in folder: URL, _ work: () throws -> Void) rethrows -> Int {
        let before = state(folder)
        try work()
        return state(folder).reduce(0) { sum, entry in
            guard let old = before[entry.key] else { return sum + entry.value.size }
            let changed = old.inode != entry.value.inode || old.modified != entry.value.modified || old.size != entry.value.size
            return sum + (changed ? entry.value.size : 0)
        }
    }

    // MARK: A library the size of the phone's

    private let sentence = "Can you send the draft over today so I can look at it before the meeting, and let me know if the numbers changed since Friday. "

    private func makeLibrary() throws -> (TranscriptHistory, [LibraryNote], MeetingStore) {
        let history = TranscriptHistory(directory: root.appendingPathComponent("History"))
        struct File: Encodable { let retention = "untilDeleted"; let records: [TranscriptRecord] }
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let records = (0..<2_100).map { index in
            TranscriptRecord(id: UUID(), text: String(repeating: sentence, count: 2), createdAt: start.addingTimeInterval(Double(-index) * 600),
                             updatedAt: start, audioSeconds: 12, engine: "fluidMiniCPU", source: .keyboard, status: .inserted)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        _ = try history.importBackupData(encoder.encode(File(records: records)))
        let notes = (0..<150).map { LibraryNote(text: sentence, createdAt: start.addingTimeInterval(Double(-$0) * 3_600)) }
        return (history, notes, MeetingStore(directory: root.appendingPathComponent("Meetings")))
    }

    /// One dictation as the app and keyboard record it: begin, a progress save every few
    /// seconds, finish, then the keyboard marks where the text went. Returns the bytes each
    /// step wrote under the history directory (each step measured on its own, since the same
    /// file is replaced several times).
    @discardableResult
    private func dictate(_ history: TranscriptHistory, progressSaves: Int = 5) -> (inflight: Int, finish: Int, mark: Int) {
        let id = UUID()
        let folder = history.directory
        var inflight = bytesWritten(in: folder) { history.begin(id: id, engine: "fluidMiniCPU", source: .keyboard) }
        for step in 1...progressSaves {
            inflight += bytesWritten(in: folder) {
                history.saveProgress(id: id, text: String(sentence.prefix(step * 25)), audioSeconds: Double(step * 3))
            }
        }
        let finish = bytesWritten(in: folder) { history.finish(id: id, text: sentence, audioSeconds: 15) }
        let mark = bytesWritten(in: folder) { history.mark(id: id, status: .inserted) }
        return (inflight, finish, mark)
    }

    /// The manager's automatic save, without the app: snapshot and coordinated-folder write.
    private func backUp(_ history: TranscriptHistory, notes: [LibraryNote], meetings: MeetingStore, to package: URL) throws {
        let raw = try history.backupData()
        let snapshot = LibraryBackup(notes: notes, dictations: try TranscriptHistory.recordsInBackup(raw),
                                     meetings: try meetings.backupMeetings(), historyArchive: raw,
                                     historyRecoveryFiles: try history.backupRecoveryFiles())
        try LibraryBackupFiles.write(snapshot, to: package, meetingDirectory: meetings.directory, accumulate: true)
    }

    // MARK: Measurements

    func testHistoryBytesPerDictation() throws {
        let (history, _, _) = try makeLibrary()
        let fileSize = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: history.directory.appendingPathComponent("history.json").path)[.size] as? Int)
        let count = 10
        var inflight = 0, finish = 0, mark = 0
        for _ in 0..<count {
            let steps = dictate(history)
            inflight += steps.inflight; finish += steps.finish; mark += steps.mark
        }
        let perDictation = (inflight + finish + mark) / count
        print("[write-volume] history.json \(fileSize) bytes; per dictation: in-flight file \(inflight / count), finish \(finish / count), mark \(mark / count), total \(perDictation) bytes (\(String(format: "%.2f", Double(perDictation) / Double(fileSize))) x the file)")
        // finish and mark each rewrite the whole file; begin and progress only touch the small in-flight file.
        XCTAssertGreaterThan(perDictation, fileSize * 2 - fileSize / 10)
        XCTAssertLessThan(perDictation, fileSize * 2 + 50_000)
    }

    func testHistoryChangeThatChangesNothingDoesNotRewriteTheFile() throws {
        let (history, _, _) = try makeLibrary()
        var notified = 0
        let observer = NotificationCenter.default.addObserver(forName: .init("ZoneLibraryDidChange"), object: nil, queue: nil) { _ in notified += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        // The keyboard marking a dictation that retention already dropped.
        let bytes = bytesWritten(in: history.directory) { history.mark(id: UUID(), status: .inserted) }
        XCTAssertEqual(bytes, 0)
        XCTAssertEqual(notified, 0, "Nothing changed, so nothing asks for a backup")
        dictate(history)
        XCTAssertGreaterThan(notified, 0)
    }

    func testIdenticalBackupWritesNothing() throws {
        let (history, notes, meetings) = try makeLibrary()
        let package = root.appendingPathComponent("Backup/Zone library.zonebackup")
        let first = try bytesWritten(in: root.appendingPathComponent("Backup")) {
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try backUp(history, notes: notes, meetings: meetings, to: package)
        }
        // The first accumulating save normalizes the history archive's JSON; from then on an
        // unchanged library is byte-identical.
        let second = try bytesWritten(in: package) { try backUp(history, notes: notes, meetings: meetings, to: package) }
        let again = try bytesWritten(in: package) { try backUp(history, notes: notes, meetings: meetings, to: package) }
        print("[write-volume] full backup \(first) bytes; second save \(second) bytes; the same library again \(again) bytes")
        XCTAssertGreaterThan(first, 1_000_000)
        XCTAssertEqual(again, 0, "An unchanged library must not rewrite library.json or the text export")
        XCTAssertNoThrow(try LibraryBackupFiles.read(package))
    }

    /// 20 dictations, one every 20 seconds, the way this person dictates in a burst. Before:
    /// a save after each one (the debounced change save), as the shipped build did on top of
    /// its 30 second rewrites. After: the schedule's 5 minute minimum interval.
    func testBurstOfDictationsBeforeAndAfterTheInterval() throws {
        let count = 20
        func run(interval: TimeInterval?) throws -> (bytes: Int, saves: Int) {
            let (history, notes, meetings) = try makeLibrary()
            let folder = root.appendingPathComponent("Backup-\(UUID().uuidString)")
            let package = folder.appendingPathComponent("Zone library.zonebackup")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try backUp(history, notes: notes, meetings: meetings, to: package) // the launch save, not counted
            var schedule = LibraryBackupSchedule(minimumInterval: interval ?? 0)
            schedule.started(at: Date(timeIntervalSinceReferenceDate: 0))
            schedule.saved(through: schedule.change, signature: 0)
            var saves = 0
            var signature = 0
            var bytes = 0
            func attempt(at now: Date) throws {
                guard interval == nil || schedule.decide(.automatic, signature: signature, now: now) == .save else { return }
                schedule.started(at: now)
                let change = schedule.change
                bytes += try bytesWritten(in: folder) { try backUp(history, notes: notes, meetings: meetings, to: package) }
                schedule.saved(through: change, signature: signature)
                saves += 1
            }
            for index in 0..<count {
                let now = Date(timeIntervalSinceReferenceDate: Double(index) * 20 + 2)
                dictate(history)
                signature += 1
                schedule.noteChange()
                try attempt(at: now)
            }
            // The deferred save at the end of the interval picks up the last dictations.
            try attempt(at: Date(timeIntervalSinceReferenceDate: Double(count) * 20 + 300))
            XCTAssertTrue(try LibraryBackupFiles.read(package).dictations.count >= 2_100 + count, "Nothing may be dropped")
            return (bytes, saves)
        }
        let before = try run(interval: nil)
        let after = try run(interval: LibraryBackupSchedule.defaultMinimumInterval)
        let perSave = before.bytes / max(before.saves, 1)
        print("[write-volume] \(count) dictations 20 s apart: before \(before.saves) saves, \(before.bytes) bytes; after \(after.saves) saves, \(after.bytes) bytes; \(perSave) bytes per save")
        XCTAssertEqual(before.saves, count + 1)
        XCTAssertLessThanOrEqual(after.saves, 3)
        XCTAssertLessThan(after.bytes * 5, before.bytes)
    }
}
