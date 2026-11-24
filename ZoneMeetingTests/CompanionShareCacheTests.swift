// by zayd/cold @ zayd.wtf

import XCTest
@testable import Zone

final class CompanionShareCacheTests: XCTestCase {
    func testWatchInboxWipePreservesUnreadableBytesAndNewerNotes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let damaged = Data("unreadable inbox".utf8)
        try damaged.write(to: url)
        let cutoff = Date()
        XCTAssertThrowsError(try PhoneNoteBridge.clearInbox(at: url, through: cutoff))
        XCTAssertEqual(try Data(contentsOf: url), damaged)
        let old = try CompanionNoteEnvelope(text: "before", createdAt: cutoff)
        let new = try CompanionNoteEnvelope(text: "after", createdAt: cutoff.addingTimeInterval(1))
        try JSONEncoder().encode([old, new]).write(to: url)
        XCTAssertEqual(try PhoneNoteBridge.clearInbox(at: url, through: cutoff).map(\.id), [new.id])
        XCTAssertEqual(try JSONDecoder().decode([CompanionNoteEnvelope].self, from: Data(contentsOf: url)).map(\.id), [new.id])
    }

    func testWatchEraseKeepsNotesMadeAfterThePhoneWipe() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let cutoff = Date()
        let ledger = try WatchNoteLedger(url: url)
        let old = try CompanionNoteEnvelope(text: "old", createdAt: cutoff)
        let new = try CompanionNoteEnvelope(text: "new", createdAt: cutoff.addingTimeInterval(1))
        try ledger.save(old)
        try ledger.save(new)
        try ledger.erase(through: cutoff)
        XCTAssertEqual(try WatchNoteLedger(url: url).notes.map(\.id), [new.id])
    }

    @MainActor
    func testWipeInvalidatesObservedRefreshAndDrainsThePriorWrite() async throws {
        let bridge = PhoneNoteBridge()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var exports = 0
        bridge.observeMessages(at: url) {
            exports += 1
            return [CompanionShareItem(id: UUID(), text: "pending export", createdAt: Date())]
        }
        bridge.publishCache()
        NotificationCenter.default.post(name: Notification.Name("ZoneLibraryDidChange"), object: nil)
        try bridge.clearMessagesCache(at: url)
        await Task { @MainActor in }.value
        XCTAssertEqual(exports, 1, "The queued notification must not export again after clearing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testClearRemovesExistingMessagesFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("saved words".utf8).write(to: url)
        try PhoneNoteBridge.clearCache(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testBackupFlagOnLegacyCacheAndEveryAtomicWrite() throws {
        let root = try XCTUnwrap(CompanionShareCache.url).deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("messages-notes.json")
        try Data("legacy".utf8).write(to: url)
        func excluded() throws -> Bool? {
            try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        }
        XCTAssertNotEqual(try excluded(), true, "The simulated legacy file must be eligible before migration.")
        try CompanionShareCache.excludeFromBackup(at: url)
        XCTAssertEqual(try excluded(), true)
        XCTAssertEqual(try Data(contentsOf: url), Data("legacy".utf8))
        try FileManager.default.removeItem(at: url)
        for text in ["first", "replacement"] {
            let item = CompanionShareItem(id: UUID(), text: text, createdAt: Date())
            try CompanionShareCache(updatedAt: Date(), items: [item], omittedCount: 0).write(to: url)
            XCTAssertEqual(try excluded(), true)
            XCTAssertEqual(try CompanionShareCache.read(from: url).items, [item])
        }
    }
}
