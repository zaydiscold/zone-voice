// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class LibraryBackupTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testFullLibrarySurvivesExportImportWithoutOverwritingExistingRecords() async throws {
        let source = MeetingStore(directory: root.appendingPathComponent("source"))
        let (meeting, writer) = try source.beginRecording(title: "Design meeting")
        writer.append(Array(repeating: 0.2, count: 16_000))
        try await writer.finish()
        _ = try source.finishRecording(meeting.id)
        _ = try source.update(meeting.id) {
            $0.status = .done
            $0.speakers = [.init(id: "S1", name: "Zayd", isMe: true)]
            $0.segments = [.init(start: 0, end: 1, speaker: "S1", text: "Keep all my notes.")]
        }
        let note = LibraryNote(text: "An edited note", editedAt: Date(timeIntervalSince1970: 1_700_000_100))
        let snapshot = LibraryBackup(notes: [note], dictations: [], meetings: source.all())
        let package = root.appendingPathComponent("library.zonebackup")
        try LibraryBackupFiles.write(snapshot, to: package, meetingDirectory: source.directory)
        let decoded = try LibraryBackupFiles.read(package)
        XCTAssertEqual(decoded.notes, [note])
        XCTAssertEqual(decoded.meetings.first?.speakers.first?.name, "Zayd")
        XCTAssertTrue(decoded.readableText.contains("Keep all my notes."))
        let destination = MeetingStore(directory: root.appendingPathComponent("restored"))
        XCTAssertEqual(try LibraryBackupFiles.restoreMeetings(decoded, from: package, into: destination), 1)
        XCTAssertEqual(try Data(contentsOf: source.audioURLs(source.all()[0])[0]),
                       try Data(contentsOf: destination.audioURLs(destination.all()[0])[0]))
        try destination.rename(meeting.id, to: "My newer title")
        XCTAssertEqual(try LibraryBackupFiles.restoreMeetings(decoded, from: package, into: destination), 0)
        XCTAssertEqual(destination.all().first?.title, "My newer title")
    }

    func testMissingAudioAndPathTraversalAreRejectedBeforeImport() async throws {
        let source = MeetingStore(directory: root.appendingPathComponent("source"))
        let (meeting, writer) = try source.beginRecording()
        writer.append([0.1, 0.2])
        try await writer.finish()
        _ = try source.finishRecording(meeting.id)
        let snapshot = LibraryBackup(notes: [], dictations: [], meetings: source.all())
        let package = root.appendingPathComponent("test.zonebackup")
        try LibraryBackupFiles.write(snapshot, to: package, meetingDirectory: source.directory)
        let audio = package.appendingPathComponent("Meetings/\(meeting.id.uuidString)/part-1.pcm")
        try FileManager.default.removeItem(at: audio)
        XCTAssertThrowsError(try LibraryBackupFiles.read(package))
        var corrupt = snapshot
        corrupt.meetings[0].parts[0].fileName = "../../notes.pcm"
        XCTAssertThrowsError(try LibraryBackup.decode(LibraryBackup.encoder.encode(corrupt)))
        corrupt = snapshot
        corrupt.meetings[0].parts[0].fileName = "..\\notes.pcm"
        XCTAssertThrowsError(try LibraryBackup.decode(LibraryBackup.encoder.encode(corrupt)))
    }

    func testSymbolicLinksCannotReadFilesOutsideBackup() async throws {
        let source = MeetingStore(directory: root.appendingPathComponent("source"))
        let (meeting, writer) = try source.beginRecording()
        writer.append([0.1, 0.2])
        try await writer.finish()
        _ = try source.finishRecording(meeting.id)
        let package = root.appendingPathComponent("test.zonebackup")
        try LibraryBackupFiles.write(.init(notes: [], dictations: [], meetings: source.all()), to: package, meetingDirectory: source.directory)
        let audio = package.appendingPathComponent("Meetings/\(meeting.id.uuidString)/part-1.pcm")
        try FileManager.default.removeItem(at: audio)
        try FileManager.default.createSymbolicLink(at: audio, withDestinationURL: source.audioURLs(source.all()[0])[0])
        XCTAssertThrowsError(try LibraryBackupFiles.read(package))
    }

    func testAutomaticBackupRetainsDeletedRecordsAndNewerEdits() throws {
        let note = LibraryNote(text: "Original")
        let previous = LibraryBackup(notes: [note], dictations: [], meetings: [])
        let empty = LibraryBackup(notes: [], dictations: [], meetings: [])
        XCTAssertEqual(empty.accumulating(previous).notes, [note])
        var edited = note
        edited.text = "Edited"
        let current = LibraryBackup(notes: [edited], dictations: [], meetings: [])
        XCTAssertEqual(current.accumulating(previous).notes, [edited])
    }

    func testRestoreKeepsOldHistoryAndUnknownEntriesAndIsIdempotent() throws {
        let history = TranscriptHistory(directory: root.appendingPathComponent("history"))
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let record = TranscriptRecord(id: UUID(), text: "Old but wanted", createdAt: old, updatedAt: old,
                                      audioSeconds: 2, engine: "test", source: .note, status: .note)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let recordData = try encoder.encode(record)
        let raw = try JSONSerialization.jsonObject(with: recordData)
        let unknownID = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: ["retention": "thirtyDays", "records": [raw, ["id": unknownID, "source": "futureSource", "text": "Keep unknown schema too"]]])
        XCTAssertEqual(try history.importBackupData(data), 2)
        XCTAssertEqual(history.retention, .untilDeleted)
        XCTAssertEqual(history.records().first?.text, "Old but wanted")
        XCTAssertEqual(try history.importBackupData(data), 0)
        let saved = try XCTUnwrap(try JSONSerialization.jsonObject(with: history.backupData()) as? [String: Any])
        let rows = try XCTUnwrap(saved["records"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.contains { $0["id"] as? String == unknownID })
    }

    func testLiveRecordingCannotProduceASuccessfulBackup() throws {
        let meeting = Meeting(title: "Still recording", createdAt: Date())
        let snapshot = LibraryBackup(notes: [], dictations: [], meetings: [meeting])
        XCTAssertThrowsError(try LibraryBackupFiles.write(snapshot, to: root.appendingPathComponent("active.zonebackup"), meetingDirectory: root))
    }

    func testBadNotesFileCannotBeOverwrittenByANewNote() throws {
        let url = root.appendingPathComponent("notes.json")
        let raw = Data("[{\"text\":\"my precious old notes\"},".utf8)
        try raw.write(to: url)
        XCTAssertThrowsError(try LibraryNotesFile.read(at: url))
        XCTAssertThrowsError(try LibraryNotesFile.write([.init(text: "new note")], to: url))
        XCTAssertEqual(try Data(contentsOf: url), raw)
    }

    func testFolderBackupRetainsUnknownIdlessHistoryAndNormalizesUUIDCase() throws {
        let id = UUID().uuidString
        var previous = LibraryBackup(notes: [], dictations: [], meetings: [])
        previous.historyArchive = try JSONSerialization.data(withJSONObject: ["records": [["id": id.lowercased(), "text": "older"], ["text": "unknown without ID"], NSNull()]])
        var current = LibraryBackup(notes: [], dictations: [], meetings: [])
        current.historyArchive = try JSONSerialization.data(withJSONObject: ["records": [["id": id, "text": "newer"]]])
        let combined = current.accumulating(previous)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(combined.historyArchive)) as? [String: Any])
        let records = try XCTUnwrap(object["records"] as? [Any])
        XCTAssertEqual(records.count, 3)
        XCTAssertTrue(records.contains { (($0 as? [String: Any])?["text"] as? String) == "unknown without ID" })
        let again = combined.accumulating(previous)
        let repeated = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(again.historyArchive)) as? [String: Any])
        XCTAssertEqual((repeated["records"] as? [Any])?.count, 3)
    }

    func testIncompleteArchiveAndOutputSymlinkCannotSucceed() throws {
        var backup = LibraryBackup(notes: [], dictations: [.init(id: UUID(), text: "Must not vanish", createdAt: Date(), updatedAt: Date(), audioSeconds: 1, engine: "test", source: .app, status: .finished)], meetings: [])
        backup.historyArchive = Data("{\"retention\":\"untilDeleted\",\"records\":[]}".utf8)
        XCTAssertThrowsError(try LibraryBackup.decode(LibraryBackup.encoder.encode(backup)))
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link.zonebackup")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try LibraryBackupFiles.write(.init(notes: [], dictations: [], meetings: []), to: link, meetingDirectory: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("library.json").path))
    }

    func testDamagedMeetingMetadataMakesFullBackupFailClearly() throws {
        let store = MeetingStore(directory: root.appendingPathComponent("meetings"))
        let folder = store.folder(UUID())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("broken metadata".utf8).write(to: folder.appendingPathComponent("meeting.json"))
        try Data([0, 1]).write(to: folder.appendingPathComponent("part-1.pcm"))
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertThrowsError(try store.backupMeetings())
    }

    func testInflightAndQuarantinedTextSurviveBackupWithoutChangingLiveRecording() throws {
        let source = TranscriptHistory(directory: root.appendingPathComponent("source-history"))
        let id = UUID()
        source.begin(id: id, engine: "test", source: .note)
        source.saveProgress(id: id, text: "Still recording, keep these words", audioSeconds: 2)
        let inflightURL = source.directory.appendingPathComponent("inflight/\(id.uuidString).json")
        let originalInflight = try Data(contentsOf: inflightURL)
        let bad = Data("unreadable but precious".utf8)
        try bad.write(to: source.directory.appendingPathComponent("history.unreadable-123.json"))
        let files = try source.backupRecoveryFiles()
        XCTAssertEqual(files.count, 2)
        let target = TranscriptHistory(directory: root.appendingPathComponent("target-history"))
        try target.importRecoveryFiles(files)
        XCTAssertEqual(try target.importInFlightText(files), 1)
        XCTAssertEqual(try target.importInFlightText(files), 0)
        XCTAssertEqual(target.record(id: id)?.status, .cutOff)
        XCTAssertEqual(target.record(id: id)?.text, "Still recording, keep these words")
        XCTAssertEqual(try Data(contentsOf: inflightURL), originalInflight)
        try target.importRecoveryFiles(files)
        XCTAssertEqual(try target.backupRecoveryFiles().count, 2)
    }
}
