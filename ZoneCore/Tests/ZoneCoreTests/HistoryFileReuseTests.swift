// by zayd/cold @ zayd.wtf

import Foundation
import XCTest
@testable import ZoneCore

/// The history file is decoded once per version on disk and written only when something changed
/// (docs/research/2026-11-18-lexicon-and-history-perf.md). The file's format is unchanged.
final class HistoryFileReuseTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("history.json") }
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-reuse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        try? FileManager.default.removeItem(at: directory)
    }

    private func inode() throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: fileURL.path)[.systemFileNumber] as? Int
    }

    private func record(_ text: String, at date: Date, id: UUID = UUID()) -> TranscriptRecord {
        TranscriptRecord(id: id, text: text, createdAt: date, updatedAt: date, audioSeconds: 2.5,
                         engine: "e", source: .keyboard, status: .inserted)
    }

    /// Another process's encoder orders the keys its own way (the order changes with every
    /// launch). The bytes then never matched this process's, so a purge with nothing to purge,
    /// run at every app launch, rewrote the whole library and announced a change.
    func testAnUnchangedLibraryWrittenByAnotherProcessIsNotRewritten() throws {
        var file = TranscriptHistory.File()
        file.retention = .untilDeleted
        file.retentionChosen = true
        file.records = (0..<50).map { record("dictation \($0)", at: t0 - Double($0) * 60) }
        let other = JSONEncoder()
        other.dateEncodingStrategy = .iso8601
        other.outputFormatting = [.sortedKeys]
        let written = try other.encode(file)
        try written.write(to: fileURL)
        let before = try inode()

        var notified = 0
        let observer = NotificationCenter.default.addObserver(forName: .init("ZoneLibraryDidChange"), object: nil, queue: nil) { _ in notified += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        for keeps in [true, false] {
            let history = TranscriptHistory(directory: directory, keepsDecodedFile: keeps)
            history.purgeExpired(now: t0)
            history.mark(id: UUID(), status: .inserted, now: t0) // a record retention already dropped
            history.setRetention(.untilDeleted, now: t0)
        }
        XCTAssertEqual(try inode(), before, "nothing changed, so the file is not replaced")
        XCTAssertEqual(try Data(contentsOf: fileURL), written)
        XCTAssertEqual(notified, 0, "nothing changed, so nothing asks for a sync or a backup")

        // A real change still writes and announces.
        TranscriptHistory(directory: directory).mark(id: file.records[0].id, status: .dismissed, now: t0 + 1)
        XCTAssertNotEqual(try inode(), before)
        XCTAssertEqual(notified, 1)
        XCTAssertEqual(TranscriptHistory(directory: directory).record(id: file.records[0].id)?.status, .dismissed)
    }

    /// The old thirty-day default is moved to Until I delete when read; the next save still
    /// writes that down, as before, even when the save itself changes nothing.
    func testTheOldThirtyDayDefaultIsStillWrittenOnTheNextSave() throws {
        let json = #"{"retention":"thirtyDays","records":[]}"#
        try Data(json.utf8).write(to: fileURL)
        TranscriptHistory(directory: directory).purgeExpired(now: t0)
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        XCTAssertEqual(raw?["retention"] as? String, "untilDeleted")
    }

    /// Two processes on one file: each sees the other's writes at once, with or without a kept decode.
    func testAWriteByTheOtherProcessIsReadBack() throws {
        let app = TranscriptHistory(directory: directory, keepsDecodedFile: true)
        let keyboard = TranscriptHistory(directory: directory, keepsDecodedFile: false)
        let first = UUID(), second = UUID()
        XCTAssertTrue(app.finish(id: first, text: "from the app", audioSeconds: 1, engine: "e", source: .keyboard, now: t0))
        XCTAssertEqual(app.records(now: t0).map(\.id), [first])
        XCTAssertTrue(app.hasSnapshot)
        keyboard.mark(id: first, status: .inserted, now: t0 + 1)
        XCTAssertEqual(app.record(id: first)?.status, .inserted, "the keyboard's mark replaced the file the app had decoded")
        XCTAssertTrue(keyboard.finish(id: second, text: "from the keyboard side", audioSeconds: 1, engine: "e", source: .keyboard, now: t0 + 2))
        XCTAssertEqual(app.records(now: t0 + 3).map(\.id), [second, first])
        app.delete(id: second)
        XCTAssertEqual(keyboard.records(now: t0 + 3).map(\.id), [first])
        XCTAssertFalse(keyboard.hasSnapshot, "an extension keeps nothing between reads")
        // Written in place by something else, same inode: still seen.
        let handle = try FileHandle(forWritingTo: fileURL)
        var raw = TranscriptHistory.File()
        raw.records = [record("rewritten in place", at: t0)]
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: try raw.encoded())
        try handle.close()
        XCTAssertEqual(app.records(now: t0 + 4).map(\.text), ["rewritten in place"])
    }

    /// The file keeps dates to the second. A save never hands back its own in-memory copy, so a
    /// read after it is exactly what a fresh process would read.
    func testReadsAfterASaveMatchAFreshProcess() throws {
        let history = TranscriptHistory(directory: directory)
        let now = Date(timeIntervalSince1970: 1_800_000_000.734)
        let id = UUID()
        history.begin(id: id, engine: "e", source: .keyboard, now: now)
        history.saveProgress(id: id, text: "partial", audioSeconds: 1.25, now: now + 0.5)
        XCTAssertTrue(history.finish(id: id, text: "the final words", audioSeconds: 1.75, now: now + 1.1))
        history.mark(id: id, status: .offered, destination: "Notes", now: now + 2.2)
        let kept = history.records(now: now + 3)
        XCTAssertTrue(history.hasSnapshot)
        XCTAssertEqual(kept, TranscriptHistory(directory: directory, keepsDecodedFile: false).records(now: now + 3))
        XCTAssertEqual(history.records(now: now + 3), kept)
    }

    /// A file that is there but cannot be read right now must not be replaced by a file holding
    /// only the new dictation; the in-flight copy waits for a retry.
    func testAHistoryFileThatCannotBeReadIsNeverReplaced() throws {
        let history = TranscriptHistory(directory: directory)
        let kept = UUID()
        XCTAssertTrue(history.finish(id: kept, text: "the only copy", audioSeconds: 1, now: t0))
        let saved = try Data(contentsOf: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
        let id = UUID()
        history.begin(id: id, engine: "e", source: .keyboard, now: t0 + 1)
        XCTAssertFalse(history.finish(id: id, text: "new words", audioSeconds: 1, now: t0 + 2))
        history.purgeExpired(now: t0 + 3)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        XCTAssertEqual(try Data(contentsOf: fileURL), saved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("inflight/\(id.uuidString).json").path))
        XCTAssertEqual(history.recoverCutOff(now: t0 + 100).map(\.text), ["new words"])
        XCTAssertEqual(Set(history.records(now: t0 + 100).map(\.id)), [kept, id])
    }

    /// Record-at-a-time encoding decodes to exactly what `JSONEncoder` on the whole file does,
    /// for text that needs escaping, every retention, and entries this build cannot read.
    func testRecordAtATimeEncodingDecodesToTheSameFile() throws {
        let texts = ["plain", "quote \" backslash \\ slash / tab \t newline \n return \r", "emoji 👩🏽‍💻 and accents é ñ ü",
                     "control \u{0001}\u{001F} and separators \u{2028}\u{2029}", "", String(repeating: "long ", count: 2_000),
                     "{\"id\":\"not a record\",\"records\":[1,2]}"]
        let unreadable: [HistoryJSON] = [
            .object(["id": .string("A1B2C3D4-0000-4000-8000-000000000001"), "createdAt": .string("2027-01-15T08:00:00Z"),
                     "source": .string("watch"), "n": .number(3), "nested": .array([.null, .bool(true), .number(1.5)])]),
            .string("a bare string"), .number(42), .null,
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let whole = JSONEncoder()
        whole.dateEncodingStrategy = .iso8601
        for retention in HistoryRetention.allCases {
            for chosen in [false, true] {
                var file = TranscriptHistory.File()
                file.retention = retention
                file.retentionChosen = chosen
                file.records = texts.enumerated().map { index, text in
                    TranscriptRecord(id: UUID(), text: text, createdAt: t0 - Double(index), updatedAt: t0 + 0.5,
                                     audioSeconds: [0, 1.5, 1e-5, 12_345.678, 0.1][index % 5], engine: "e\(index)",
                                     source: [.keyboard, .app, .note, .remote][index % 4],
                                     status: TranscriptStatus(rawValue: index == 3 ? "someFutureStatus" : "inserted"),
                                     destination: index % 2 == 0 ? nil : "Mac \"mini\"", recoveredFrom: index == 1 ? t0 - 100 : nil,
                                     interruptions: index == 2 ? 3 : nil)
                }
                file.unreadable = unreadable
                let ours = try file.encoded()
                XCTAssertNoThrow(try JSONSerialization.jsonObject(with: ours))
                let expected = try decoder.decode(TranscriptHistory.File.self, from: whole.encode(file))
                XCTAssertEqual(try decoder.decode(TranscriptHistory.File.self, from: ours), expected, "\(retention) chosen \(chosen)")
                XCTAssertEqual(expected.unreadable, unreadable)
            }
        }
        XCTAssertEqual(String(decoding: try TranscriptHistory.File().encoded(), as: UTF8.self),
                       #"{"retention":"untilDeleted","retentionChosen":false,"records":[]}"#)
    }

    func testAKeptDecodeIsDroppedByASaveAndMadeAgainByTheNextRead() throws {
        let history = TranscriptHistory(directory: directory)
        XCTAssertTrue(history.finish(id: UUID(), text: "one", audioSeconds: 1, now: t0))
        XCTAssertFalse(history.hasSnapshot)
        XCTAssertEqual(history.retention, .untilDeleted)
        XCTAssertTrue(history.hasSnapshot)
        history.forgetSnapshot()
        XCTAssertEqual(history.records(now: t0).map(\.text), ["one"])
        XCTAssertTrue(history.hasSnapshot)
        XCTAssertTrue(history.finish(id: UUID(), text: "two", audioSeconds: 1, now: t0 + 1))
        XCTAssertFalse(history.hasSnapshot)
        XCTAssertEqual(history.records(now: t0 + 1).map(\.text), ["two", "one"])
    }
}
