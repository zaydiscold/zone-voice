// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class CleanupArchiveTests: XCTestCase {
    /// Your data > Delete everything, and its dated deletes, take the saved cleanups too. Before
    /// 1.0.5 they stayed on disk: an original and its cleaned text for every cleanup ever run.
    func testDeletingARangeRemovesOnlyTheCleanupsMadeInItAndEverythingRemovesAll() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CleanupArchive(directory: root)
        XCTAssertEqual(try store.delete(createdIn: Date.distantPast...Date.distantFuture), 0, "no folder yet is not an error")
        let now = Date()
        let old = CleanupArchive.Entry(original: "um an old one", cleaned: nil, createdAt: now.addingTimeInterval(-40 * 86_400))
        var recent = CleanupArchive.Entry(original: "um a new one", createdAt: now.addingTimeInterval(-3600))
        try store.save(old)
        try store.save(recent)
        try Data("not json".utf8).write(to: root.appendingPathComponent("\(UUID().uuidString).json"))
        try Data("kept".utf8).write(to: root.appendingPathComponent("notes.txt"))

        XCTAssertEqual(try store.delete(createdIn: Date.distantPast...now.addingTimeInterval(-30 * 86_400)), 1)
        XCTAssertEqual(try store.entries().map(\.id), [recent.id], "only the cleanup older than 30 days went")

        XCTAssertEqual(try store.delete(createdIn: Date.distantPast...Date.distantFuture), 2, "the rest, unreadable file included")
        XCTAssertTrue(try store.entries().isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["notes.txt"], "only cleanup files are touched")
        // A cleanup that was still running when everything was deleted cannot bring its text back.
        recent.cleaned = "A new one."
        XCTAssertThrowsError(try store.save(recent))
        XCTAssertTrue(try store.entries().isEmpty)
    }

    func testLateCandidateCannotResurrectDeletedOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CleanupArchive(directory: root)
        var entry = CleanupArchive.Entry(original: "um keep this")
        try store.save(entry)
        try store.delete(entry.id)
        entry.cleaned = "Keep this."
        XCTAssertThrowsError(try store.save(entry))
        XCTAssertTrue(try store.entries().isEmpty)
    }

    func testOriginalSurvivesUpdatesAndUnrelatedCorruption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CleanupArchive(directory: root)
        var entry = CleanupArchive.Entry(original: "um keep the original")
        try store.save(entry)
        entry.cleaned = "Keep the original."
        try store.save(entry)
        try Data("broken".utf8).write(to: root.appendingPathComponent("unrelated.json"))
        XCTAssertEqual(try store.entries(), [entry])
        let overwritten = CleanupArchive.Entry(id: entry.id, original: "lost original")
        XCTAssertThrowsError(try store.save(overwritten))
        XCTAssertEqual(try store.entries().first?.original, entry.original)
    }

    func testWriteFailureDoesNotPretendOriginalWasSaved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("blocked".utf8).write(to: root)
        XCTAssertThrowsError(try CleanupArchive(directory: root).save(.init(original: "keep me")))
        XCTAssertEqual(try String(contentsOf: root), "blocked")
    }
}
