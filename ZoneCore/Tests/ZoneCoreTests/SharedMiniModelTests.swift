import Foundation
import XCTest
@testable import ZoneCore

final class SharedMiniModelTests: XCTestCase {
    func testLaunchCannotOverlapAHostOrAnOrphanedWorker() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = try XCTUnwrap(WorkerStorage.hostLease(in: folder))
        XCTAssertNil(try WorkerStorage.hostLease(in: folder))
        let worker = try XCTUnwrap(WorkerStorage.lease("worker.lock", in: folder))
        try host.close()
        XCTAssertNil(try WorkerStorage.hostLease(in: folder))
        try worker.close()
        let next = try XCTUnwrap(WorkerStorage.hostLease(in: folder))
        defer { try? next.close() }
        let recording = UUID()
        XCTAssertTrue(try WorkerStorage.reserveLaunch(for: recording, in: folder))
        XCTAssertTrue(try WorkerStorage.reserveLaunch(for: recording, in: folder))
        XCTAssertFalse(try WorkerStorage.reserveLaunch(for: recording, in: folder))
    }

    func testSweepRemovesOnlyTemporaryProgramsAlongsideTheFinishedProgram() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = root.appendingPathComponent("build/key")
        let keep = ["A0B1.bundle", "other.tmp.bundle"]
        for name in keep + ["A0B1.tmp.123_876.bundle", "A0B1.tmp.345_211.bundle"] {
            let folder = key.appendingPathComponent(name + "/H16.bundle/main/main_bnns")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data([1]).write(to: folder.appendingPathComponent("bnns_program.bnnsir"))
        }
        XCTAssertEqual(try WorkerStorage.sweepTemporaryPrograms(in: root), 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: key.path).sorted(), keep)
        XCTAssertEqual(try WorkerStorage.sweepTemporaryPrograms(in: root), 0)
    }

    func testColdWorkerRequiresTheSameMarginAsTheApp() {
        let minimum = WorkerStorage.requiredRoom(WorkerStorage.preparedBytes)
        XCTAssertEqual(minimum, 1_560_000_000)
        XCTAssertThrowsError(try WorkerStorage.checkRoom(prepared: false, free: minimum - 1)) { error in
            XCTAssertTrue(error.localizedDescription.contains("space"))
        }
        XCTAssertNoThrow(try WorkerStorage.checkRoom(prepared: false, free: minimum))
        XCTAssertNoThrow(try WorkerStorage.checkRoom(prepared: true, free: 0))
        XCTAssertNoThrow(try WorkerStorage.checkRoom(prepared: false, free: nil))
    }

    func testOneByteCacheCannotBypassFreeSpaceCheck() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        let build = cache.appendingPathComponent("test")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        let file = build.appendingPathComponent("program")
        try Data([1]).write(to: file)
        XCTAssertFalse(WorkerStorage.cacheIsPrepared(root: cache, build: "test"))
        WorkerStorage.rememberPrepared(root: cache, build: "test")
        XCTAssertTrue(WorkerStorage.cacheIsPrepared(root: cache, build: "test"))
        try Data().write(to: file)
        XCTAssertFalse(WorkerStorage.cacheIsPrepared(root: cache, build: "test"))
    }

    func testSweepRemovesOnlyOldStagedWavs() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let old = root.appendingPathComponent(UUID().uuidString + ".wav")
        let fresh = root.appendingPathComponent(UUID().uuidString + ".wav")
        let other = root.appendingPathComponent("keep.wav")
        for file in [old, fresh, other] { try Data().write(to: file) }
        for file in [old, other] {
            try fm.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: file.path)
        }
        SharedMiniModel.sweepRecordings(in: root)
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertTrue(fm.fileExists(atPath: fresh.path))
        XCTAssertTrue(fm.fileExists(atPath: other.path))
    }

    func testSweepKeepsAnActiveCopyAndTheExactAgeBoundary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(UUID().uuidString + ".wav")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try Data([1, 2, 3]).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-600)], ofItemAtPath: file.path)
        SharedMiniModel.sweepRecordings(in: root, now: now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let held = try XCTUnwrap(KeyboardAudioFile.lock(file))
        SharedMiniModel.sweepRecordings(in: root, now: now.addingTimeInterval(1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try held.close()
        SharedMiniModel.sweepRecordings(in: root, now: now.addingTimeInterval(1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testACompletePrivateModelIsVerifiedOnlyOnceWhenMoved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old")
        let shared = root.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        var inspected: [URL] = []
        XCTAssertTrue(try SharedMiniModel.prepareShared(from: old, to: shared, published: false, isComplete: { _ in true }) {
            inspected.append($0)
            return true
        })
        XCTAssertEqual(inspected, [old])
        XCTAssertTrue(try SharedMiniModel.prepareShared(from: old, to: shared, published: true, isComplete: { _ in true }) { _ in
            XCTFail("A verified shared download should not be hashed again")
            return false
        })
    }

    func testDamagedPublishedModelUsesPrivateModelAndCleansDuplicates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old"), shared = root.appendingPathComponent("shared")
        func complete(_ url: URL) -> Bool { (try? Data(contentsOf: url.appendingPathComponent("weights"))) == Data([7]) }
        for dir in [old, shared] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try Data([7]).write(to: old.appendingPathComponent("weights"))
        XCTAssertTrue(try SharedMiniModel.prepareShared(from: old, to: shared, published: true, isComplete: complete, verify: complete))
        XCTAssertTrue(complete(shared))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        try FileManager.default.copyItem(at: shared, to: old)
        XCTAssertTrue(try SharedMiniModel.prepareShared(from: old, to: shared, published: true, isComplete: complete, verify: complete))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    func testRemovalVisitsBothExactPathsEvenIfOneFails() throws {
        let root = FileManager.default.temporaryDirectory
        let paths = [root.appendingPathComponent("private"), root.appendingPathComponent("shared")]
        var visited: [URL] = []
        XCTAssertThrowsError(try SharedMiniModel.removeCopies(paths) { url in
            visited.append(url)
            if url == paths.first { throw CocoaError(.fileWriteNoPermission) }
        })
        XCTAssertEqual(visited, paths)
    }

    func testRestartBetweenMoveAndPublication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("private")
        let new = root.appendingPathComponent("group/model")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let speech = Data([1, 2, 3])
        try speech.write(to: old.appendingPathComponent("weights"))
        XCTAssertEqual(try SharedMiniModel.migrate(from: old, to: new) { _ in false }, old)
        XCTAssertEqual(try SharedMiniModel.migrate(from: old, to: new) {
            try Data(contentsOf: $0.appendingPathComponent("weights")) == speech
        }, new)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(try SharedMiniModel.migrate(from: old, to: new) { _ in false }, new)
        XCTAssertEqual(try Data(contentsOf: new.appendingPathComponent("weights")), speech)
    }
}
