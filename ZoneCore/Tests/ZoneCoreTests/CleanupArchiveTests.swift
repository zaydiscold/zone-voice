// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class CleanupArchiveTests: XCTestCase {
    func testDatedAndAllTimeDeletionOfLegacyFiles() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let archive = CleanupArchive(directory: root)
        let allTime = Date.distantPast...Date.distantFuture
        XCTAssertEqual(try archive.delete(createdIn: allTime), 0)

        try files.createDirectory(at: root, withIntermediateDirectories: true)
        // Literal old-format files keep this test independent of the removed writer.
        func legacyFile(at seconds: Int) throws -> URL {
            let id = UUID()
            let file = root.appendingPathComponent(id.uuidString + ".json")
            let data = try JSONSerialization.data(withJSONObject: [
                "id": id.uuidString, "original": "um hello", "cleaned": "Hello.", "createdAt": seconds
            ])
            try data.write(to: file)
            return file
        }
        let old = try legacyFile(at: 100)
        let recent = try legacyFile(at: 300)
        let unreadable = root.appendingPathComponent("damaged.json")
        try Data("invalid".utf8).write(to: unreadable)
        let incomplete = root.appendingPathComponent("incomplete.json")
        try Data(#"{"createdAt":100}"#.utf8).write(to: incomplete)
        try Data().write(to: root.appendingPathComponent("notes.txt"))

        XCTAssertEqual(try archive.delete(createdIn: .distantPast...Date(timeIntervalSinceReferenceDate: 200)), 1)
        XCTAssertFalse(files.fileExists(atPath: old.path))
        XCTAssertTrue(files.fileExists(atPath: recent.path))
        XCTAssertTrue(files.fileExists(atPath: unreadable.path))
        XCTAssertTrue(files.fileExists(atPath: incomplete.path))
        XCTAssertEqual(try archive.delete(createdIn: allTime), 3)
        XCTAssertEqual(try files.contentsOfDirectory(atPath: root.path), ["notes.txt"])
        XCTAssertEqual(try archive.delete(createdIn: allTime), 0)
    }
}
