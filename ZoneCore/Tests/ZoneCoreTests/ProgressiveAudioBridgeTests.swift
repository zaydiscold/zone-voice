// by zayd/cold @ zayd.wtf

import Foundation
import XCTest
@testable import ZoneCore

final class ProgressiveAudioBridgeTests: XCTestCase {
    func testEmptyKeyboardInboxDoesNotFlagABlockedPrimaryFolder() throws {
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: inbox) }
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let blocker = inbox.appendingPathComponent("blocked")
        try Data().write(to: blocker)
        let storage = AudioRecoveryStore(directory: blocker.appendingPathComponent("AudioRecovery"))
        XCTAssertNoThrow(try storage.importKeyboardAudio(from: inbox))
    }

    private final class Model: RecognitionSession, @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Float] = []
        private var queued = 0
        var availableAudioSamples: Int { lock.withLock { 160_000 - queued } }
        var received: [Float] { lock.withLock { samples } }
        var failure: Error? { nil }
        var textSoFar: String { "" }
        var audioSeconds: Double { 0 }
        func feed(_ block: [Float]) {
            lock.withLock {
                queued += block.count
                XCTAssertLessThanOrEqual(queued, 160_000)
                samples.append(contentsOf: block)
            }
        }
        func consume() { lock.withLock { queued = max(queued - 1024, 0) } }
        func finish() async throws -> String { "" }
        func cancel() {}
    }

    private func store() -> AudioRecoveryStore {
        AudioRecoveryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    func testThirtyFiveSecondsReachSlowModelAndDiskInOrder() async throws {
        let store = store(), id = UUID()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let writer = try store.begin(id: id, engine: "fixture", source: .note)
        let bridge = ProgressiveAudioBridge(writer: writer, url: store.audioURL(id))
        let expected = (0..<560_000).map { Float(($0 % 30_000) - 15_000) / 32_767 }
        for offset in stride(from: 0, to: expected.count, by: 1600) {
            let block = Array(expected[offset..<offset+1600])
            writer.append(block)
            bridge.feed(block)
            while writer.acceptedSamples - writer.flushedSamples > 32_000 { try await Task.sleep(for: .milliseconds(1)) }
        }
        try await writer.finish()
        let model = Model()
        let consumer = Task {
            while !Task.isCancelled { model.consume(); try await Task.sleep(for: .milliseconds(5)) }
        }
        defer { consumer.cancel() }
        bridge.attach(model)
        _ = try await Watchdog.run(what: "Replay", limit: 15) { try await bridge.finish() }
        XCTAssertTrue(model.received == expected)
        XCTAssertTrue(try Data(contentsOf: store.audioURL(id)) == PCM16.encode(expected))
    }

    func testConcurrentTapAtHandoff() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        for _ in 0..<50 {
            let id = UUID(), model = Model()
            let writer = try store.begin(id: id, engine: "test", source: .note)
            let bridge = ProgressiveAudioBridge(writer: writer, url: store.audioURL(id))
            let expected = (0..<12_288).map { Float($0) / 32_767 }
            let producer = Task.detached {
                for offset in stride(from: 0, to: expected.count, by: 256) {
                    let block = Array(expected[offset..<offset+256])
                    writer.append(block)
                    bridge.feed(block)
                    await Task.yield()
                }
            }
            bridge.attach(model)
            await producer.value
            try await writer.finish()
            _ = try await bridge.finish()
            XCTAssertTrue(model.received == expected)
        }
    }

    func testUnfinishedWriterSurvivesRelaunch() async throws {
        let store = store(), id = UUID()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let samples = Array(repeating: Float(0.25), count: 24_000)
        do {
            let writer = try store.begin(id: id, engine: "test", source: .note)
            writer.append(samples)
            while writer.flushedSamples < samples.count { try await Task.sleep(for: .milliseconds(1)) }
        }
        let fresh = AudioRecoveryStore(directory: store.directory)
        try fresh.recoverAbandoned()
        XCTAssertEqual(try fresh.records().first?.audioSeconds, 1.5)
        XCTAssertEqual(try Data(contentsOf: fresh.audioURL(id)), PCM16.encode(samples))
    }

    func testFallbackFileSurvivesRelaunchAndCanBeRetriedAndDeleted() async throws {
        let primary = store(), alternate = store(), id = UUID()
        try Data().write(to: primary.directory)
        defer {
            try? FileManager.default.removeItem(at: primary.directory)
            try? FileManager.default.removeItem(at: alternate.directory)
        }
        let storage = AudioRecoveryStore(directory: primary.directory, fallbackDirectory: alternate.directory)
        let writer = try storage.begin(id: id, engine: "test", source: .note)
        writer.append([0.25, 0.5])
        try await writer.finish()
        let fresh = AudioRecoveryStore(directory: primary.directory, fallbackDirectory: alternate.directory)
        try fresh.recoverAbandoned()
        let record = try XCTUnwrap(fresh.records().first)
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.audioBytes, 4)
        XCTAssertEqual(try Data(contentsOf: fresh.audioURL(id)), PCM16.encode([0.25, 0.5]))
        XCTAssertEqual(try fresh.beginRetry(id).state, .retrying)
        try fresh.discard(id)
        XCTAssertTrue(try fresh.records().isEmpty)
    }
}
