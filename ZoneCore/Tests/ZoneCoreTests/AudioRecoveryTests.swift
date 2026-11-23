// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class AudioRecoveryTests: XCTestCase {
    private func store() -> AudioRecoveryStore {
        AudioRecoveryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }
    func testIncrementalPCMAndTruncatedFrameCanBeRecoveredAfterRelaunch() async throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let id = UUID()
        let writer = try store.begin(id: id, engine: "test", source: .keyboard)
        writer.append([0, 0.5, -0.5, 1, -1])
        try await writer.finish()
        let handle = try FileHandle(forWritingTo: store.audioURL(id))
        try handle.seekToEnd(); try handle.write(contentsOf: Data([255])); try handle.close()
        let decoded = PCM16.decode(try Data(contentsOf: store.audioURL(id)))
        XCTAssertEqual(decoded.count, 5)
        XCTAssertEqual(decoded[1], 0.5, accuracy: 0.00004)
        let reopened = AudioRecoveryStore(directory: store.directory)
        try reopened.recoverAbandoned()
        XCTAssertEqual(try reopened.records().first?.state, .failed)
        XCTAssertEqual(try reopened.records().first?.source, .keyboard)
    }
    func testFinalTextReceiptPrecedesAudioRemovalAndEmptyTextRetainsAudio() async throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let id = UUID()
        let writer = try store.begin(id: id, engine: "test", source: .note)
        writer.append([Float](repeating: 0.1, count: 16_000 * 9)); try await writer.finish()
        XCTAssertThrowsError(try store.complete(id, text: ""))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(id).path))
        try store.complete(id, text: "Recovered words")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audioURL(id).path))
        XCTAssertEqual(try AudioRecoveryStore(directory: store.directory).records().first?.text, "Recovered words")
        try store.consumeTextReceipt(id)
        XCTAssertTrue(try store.records().isEmpty)
    }
    func testEmptyTextFromShortRecordingLeavesNothingToRecover() async throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let id = UUID()
        let writer = try store.begin(id: id, engine: "test", source: .keyboard)
        writer.append([Float](repeating: 0, count: 16_000)); try await writer.finish()
        XCTAssertNoThrow(try store.complete(id, text: "  ", discardShortEmpty: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audioURL(id).path))
        XCTAssertTrue(try store.records().isEmpty)
    }
    func testRetryOfShortRecordingKeepsItsAudioWhenEmpty() async throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let id = UUID()
        let writer = try store.begin(id: id, engine: "test", source: .keyboard)
        writer.append([Float](repeating: 0.1, count: 16_000 * 3)); try await writer.finish()
        XCTAssertThrowsError(try store.complete(id, text: ""))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(id).path))
    }
    func testFailedAudioIsKeptForAWeek() {
        XCTAssertEqual(AudioRecoveryStore.failedRetention, 604_800)
    }
    func testFailureToSaveFinalReceiptNeverDeletesAudio() async throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let id = UUID()
        let writer = try store.begin(id: id, engine: "test", source: .app)
        writer.append([0.3]); try await writer.finish()
        let metadata = store.directory.appendingPathComponent(id.uuidString + ".json")
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.complete(id, text: "Recognized"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(id).path))
        // Even missing/corrupt metadata must not hide the complete PCM prefix.
        XCTAssertEqual(try store.records().first?.id, id)
    }
    func testExpiryProtectsActiveRetryAndRecognizedFailureText() async throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let start = Date(timeIntervalSince1970: 1000)
        let id = UUID()
        let writer = try store.begin(id: id, engine: "test", source: .app, now: start)
        writer.append([0.3]); try await writer.finish()
        try store.expire(now: start.addingTimeInterval(10_000))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(id).path))
        try store.markFailed(id, text: "Partial", message: "Interrupted", now: start)
        _ = try store.beginRetry(id, now: start.addingTimeInterval(20))
        try store.expire(now: start.addingTimeInterval(10_000))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(id).path))
        try store.markFailed(id, text: "Partial", message: "Retry cancelled", now: start)
        try store.expire(now: start.addingTimeInterval(AudioRecoveryStore.failedRetention + 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audioURL(id).path))
        XCTAssertEqual(try store.records().first?.text, "Partial")
        XCTAssertEqual(try store.records().first?.state, .textReady)
    }
    func testRelaunchRemovesResidualAudioAfterCommittedTextReceipt() async throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let id = UUID()
        let writer = try store.begin(id: id, engine: "test", source: .keyboard)
        writer.append([0.2, -0.2]); try await writer.finish()
        let pcm = try Data(contentsOf: store.audioURL(id))
        try store.complete(id, text: "Durable words")
        // Simulate a process dying after the receipt committed but before PCM was unlinked.
        try pcm.write(to: store.audioURL(id))
        let reopened = AudioRecoveryStore(directory: store.directory)
        try reopened.recoverAbandoned()
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.audioURL(id).path))
        XCTAssertEqual(try reopened.records().first?.text, "Durable words")
    }
    func testWriterRejectsUnboundedPendingAudioAndKeepsExistingPrefix() async throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let id = UUID()
        let writer = try store.begin(id: id, engine: "test", source: .app)
        writer.append([0.25, -0.25])
        writer.append(Array(repeating: 0, count: writer.maxQueuedSamples + 1))
        XCTAssertNotNil(writer.failure)
        do { try await writer.finish(); XCTFail("Expected overload") } catch {}
        XCTAssertEqual(PCM16.decode(try Data(contentsOf: store.audioURL(id))).count, 2)
    }
}
