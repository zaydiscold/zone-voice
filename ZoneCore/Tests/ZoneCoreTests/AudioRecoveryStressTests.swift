// by zayd/cold @ zayd.wtf

import Darwin
import XCTest
@testable import ZoneCore

/// Audio recovery under the conditions it exists for: several writers at once, a reader sweeping
/// while they write, kills between the metadata and the PCM, torn files, a full disk, clocks
/// that jump, and recordings hours long.
final class AudioRecoveryStressTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for url in directories {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        directories = []
        super.tearDown()
    }

    private func makeStore() -> AudioRecoveryStore {
        let url = Stress.temporaryDirectory("recovery")
        directories.append(url)
        return AudioRecoveryStore(directory: url)
    }

    // MARK: Concurrency

    func testConcurrentWritersAndASweepingReaderNeverCorruptOrLoseAudio() async throws {
        let store = makeStore()
        let writers = Stress.iterations(6, heavy: 24)
        let buffers = Stress.iterations(60, heavy: 600)
        let ids = (0..<writers).map { _ in UUID() }
        let handles = try ids.map { try store.begin(id: $0, engine: "stress", source: .keyboard) }
        let done = ManagedFlag()
        // A reader that keeps listing, recovering (with every id active) and expiring meanwhile.
        let reader = Task.detached {
            var sweeps = 0
            while !done.value {
                _ = try store.records()
                try store.recoverAbandoned(activeIDs: Set(ids))
                try store.expire(activeIDs: Set(ids))
                sweeps += 1
            }
            return sweeps
        }
        DispatchQueue.concurrentPerform(iterations: writers) { index in
            // Each recording has its own constant so interleaving would show as wrong samples.
            let value = Float(index + 1) / Float(writers + 1)
            for _ in 0..<buffers { handles[index].append([Float](repeating: value, count: 1_600)) }
        }
        // Audio arrives far faster than real time here. The heavy run (24 writers) can outrun
        // the bounded queue, which must then refuse cleanly: whole buffers, no foreign samples.
        for writer in handles {
            do { try await writer.finish() } catch AudioRecoveryError.writerOverloaded { XCTAssertTrue(Stress.enabled) }
        }
        done.value = true
        let sweeps = try await reader.value
        XCTAssertGreaterThan(sweeps, 0)

        let records = try store.records()
        XCTAssertEqual(records.count, writers)
        for (index, id) in ids.enumerated() {
            let record = try XCTUnwrap(records.first { $0.id == id })
            if handles[index].failure == nil {
                XCTAssertEqual(record.audioBytes, Int64(buffers * 1_600 * 2))
            } else {
                XCTAssertLessThanOrEqual(record.audioBytes, Int64(buffers * 1_600 * 2))
                XCTAssertEqual(record.audioBytes % 3_200, 0, "an overloaded writer keeps whole buffers")
            }
            XCTAssertEqual(record.state, .recording)
            let samples = PCM16.decode(try Data(contentsOf: store.audioURL(id)))
            let expected = Float(index + 1) / Float(writers + 1)
            XCTAssertTrue(samples.allSatisfy { abs($0 - expected) < 0.0001 }, "recording \(index) has foreign samples")
        }
    }

    func testFinishIsIdempotentAndAppendsAfterFinishAreIgnored() async throws {
        let store = makeStore()
        let id = UUID()
        let writer = try store.begin(id: id, engine: "stress", source: .app)
        writer.append([Float](repeating: 0.2, count: 4_000))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { try await writer.finish() } }
            try await group.waitForAll()
        }
        writer.append([Float](repeating: 0.9, count: 4_000))
        try await writer.finish()
        XCTAssertEqual(try store.records().first?.audioBytes, 8_000)
    }

    // MARK: Torn state after a kill

    func testKillBetweenMetadataAndFirstAudioLeavesNoDeadCard() throws {
        let store = makeStore()
        let id = UUID()
        _ = try store.begin(id: id, engine: "stress", source: .keyboard)
        // The PCM file exists but never received a byte (killed in the first buffer).
        try store.recoverAbandoned()
        XCTAssertEqual(try store.records(), [], "an interrupted recording with no audio and no text was kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audioURL(id).path))
    }

    func testKillAfterAudioButWithTornMetadataIsStillRecoverable() async throws {
        let store = makeStore()
        let id = UUID()
        let writer = try store.begin(id: id, engine: "stress", source: .keyboard)
        writer.append([Float](repeating: 0.3, count: 48_000))
        try await writer.finish()
        // A torn metadata file (half of the JSON) and a torn final PCM byte.
        let metadata = store.directory.appendingPathComponent(id.uuidString + ".json")
        let json = try Data(contentsOf: metadata)
        try json.prefix(json.count / 2).write(to: metadata)
        let handle = try FileHandle(forWritingTo: store.audioURL(id))
        try handle.seekToEnd(); try handle.write(contentsOf: Data([0x7F])); try handle.close()

        let relaunched = AudioRecoveryStore(directory: store.directory)
        try relaunched.recoverAbandoned()
        let record = try XCTUnwrap(relaunched.records().first)
        XCTAssertEqual(record.state, .failed)
        XCTAssertEqual(record.audioSeconds, 3, accuracy: 0.0001)
        let retry = try relaunched.beginRetry(id)
        XCTAssertEqual(retry.state, .retrying)
        let reader = try AudioRecoveryReader(url: relaunched.audioURL(id))
        var total = 0
        while case let chunk = try reader.read(maxSamples: 4_096), !chunk.isEmpty { total += chunk.count }
        XCTAssertEqual(total, 48_000, "the torn byte must not become a sample")
    }

    func testGarbageMetadataWithoutAudioIsCleanedUp() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let id = UUID()
        try Data("{\"id\": 12, garbage".utf8).write(to: store.directory.appendingPathComponent(id.uuidString + ".json"))
        try Data("not a uuid".utf8).write(to: store.directory.appendingPathComponent("notes.json"))
        XCTAssertEqual(try store.records(), [])
        try store.recoverAbandoned()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(id.uuidString + ".json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("notes.json").path),
                      "files that are not recovery records are not ours to delete")
    }

    func testRandomTruncationsNeverCrashAndNeverInventSamples() async throws {
        var rng = StressRNG(seed: 0xA0D10)
        let store = makeStore()
        for _ in 0..<Stress.iterations(25, heavy: 300) {
            let id = UUID()
            let writer = try store.begin(id: id, engine: "stress", source: .app)
            let samples = rng.int(0...20_000)
            if samples > 0 { writer.append([Float](repeating: 0.5, count: samples)) }
            try await writer.finish()
            let cut = rng.int(0...(samples * 2))
            let handle = try FileHandle(forWritingTo: store.audioURL(id))
            try handle.truncate(atOffset: UInt64(cut)); try handle.close()
            if rng.chance(0.3) { try Data().write(to: store.directory.appendingPathComponent(id.uuidString + ".json")) }
            let record = try store.records().first { $0.id == id }
            if cut >= 2 {
                XCTAssertEqual(record?.audioBytes, Int64(cut))
                XCTAssertEqual(PCM16.decode(try Data(contentsOf: store.audioURL(id))).count, cut / 2)
            }
        }
        try store.recoverAbandoned()
        for record in try store.records() {
            XCTAssertEqual(record.state, .failed)
            XCTAssertGreaterThanOrEqual(record.audioBytes, 2)
        }
    }

    // MARK: Clocks

    /// A failed recording is never deleted before a week of real time, whichever way the clock jumped.
    func testClockJumpsNeverDeleteAudioEarly() async throws {
        let store = makeStore()
        let real = Date(timeIntervalSince1970: 1_800_000_000)
        let id = UUID()
        let writer = try store.begin(id: id, engine: "stress", source: .app, now: real)
        writer.append([Float](repeating: 0.1, count: 16_000))
        try await writer.finish()
        try store.markFailed(id, text: "", message: "engine failed", now: real)
        // The clock went back a year (a dead battery before network time), then forward again.
        try store.expire(now: real.addingTimeInterval(-365 * 86_400))
        try store.expire(now: real.addingTimeInterval(86_400))
        XCTAssertEqual(try store.records().count, 1)
        try store.expire(now: real.addingTimeInterval(AudioRecoveryStore.failedRetention + 1))
        XCTAssertEqual(try store.records().count, 0)

        // Failed while the clock ran a year ahead: kept (visible, deletable) rather than lost.
        let ahead = UUID()
        let second = try store.begin(id: ahead, engine: "stress", source: .app, now: real)
        second.append([Float](repeating: 0.1, count: 16_000))
        try await second.finish()
        try store.markFailed(ahead, text: "partial words", message: "engine failed", now: real.addingTimeInterval(365 * 86_400))
        try store.expire(now: real.addingTimeInterval(30 * 86_400))
        XCTAssertEqual(try store.records().first?.state, .failed)
        // When it does expire, its recognized text survives as a receipt.
        try store.expire(now: real.addingTimeInterval(400 * 86_400))
        XCTAssertEqual(try store.records().first?.state, .textReady)
        XCTAssertEqual(try store.records().first?.text, "partial words")
    }

    // MARK: Disk full

    /// The process file-size limit makes every write past 64 KB fail with EFBIG, the same path
    /// as ENOSPC: the writer must stop cleanly, report it, and keep every byte it did write.
    func testFullDiskStopsTheWriterAndKeepsWhatReachedTheDisk() async throws {
        let store = makeStore()
        let id = UUID()
        let writer = try store.begin(id: id, engine: "stress", source: .keyboard)
        var original = rlimit()
        getrlimit(RLIMIT_FSIZE, &original)
        let previousHandler = signal(SIGXFSZ, SIG_IGN)
        var limited = rlimit(rlim_cur: 64_000, rlim_max: original.rlim_max)
        setrlimit(RLIMIT_FSIZE, &limited)
        for _ in 0..<60 { writer.append([Float](repeating: 0.25, count: 1_600)) }
        let result: Result<Void, Error>
        do { try await writer.finish(); result = .success(()) } catch { result = .failure(error) }
        setrlimit(RLIMIT_FSIZE, &original)
        signal(SIGXFSZ, previousHandler)

        guard case .failure = result else { return XCTFail("a full disk must surface as a failure") }
        XCTAssertNotNil(writer.failure)
        let record = try XCTUnwrap(store.records().first)
        XCTAssertGreaterThan(record.audioBytes, 0)
        XCTAssertLessThanOrEqual(record.audioBytes, 64_000)
        XCTAssertEqual(record.audioBytes % 2, 0, "only whole samples are written in full")
        // The audio that made it is retryable once space is back.
        try store.recoverAbandoned()
        XCTAssertEqual(try store.beginRetry(id).state, .retrying)
    }

    /// A metadata refresh that fails (the folder became read-only, or the disk filled between
    /// the PCM write and the JSON) used to stop the PCM too. The PCM is the safety net; it goes on.
    func testFailedMetadataRefreshDoesNotStopTheAudio() async throws {
        let store = makeStore()
        let id = UUID()
        let writer = try store.begin(id: id, engine: "stress", source: .keyboard)
        writer.append([Float](repeating: 0.4, count: 8_000))
        // Wait for the first buffer to land, then make the folder read-only: atomic JSON writes
        // (a new temporary file, then a rename) fail, appends to the open PCM handle still work.
        while (try? store.records().first?.audioBytes) ?? 0 < 16_000 { await Task.yield() }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: store.directory.path)
        for _ in 0..<20 { writer.append([Float](repeating: 0.4, count: 4_000)) }
        try await writer.finish()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.directory.path)
        XCTAssertNil(writer.failure)
        XCTAssertEqual(try store.records().first?.audioBytes, Int64((8_000 + 80_000) * 2))
    }

    func testOverloadedWriterRefusesInsteadOfGrowingMemory() {
        let store = makeStore()
        let writer = try? store.begin(id: UUID(), engine: "stress", source: .app)
        // One buffer larger than the whole queue is refused outright.
        writer?.append([Float](repeating: 0, count: 200_000))
        XCTAssertNotNil(writer?.failure)
    }

    // MARK: Hours of audio

    /// Ten hours of PCM16 is 1.15 GB. A sparse file stands in for it: sizes, seconds and reads
    /// from the far end must all work without loading the file.
    func testTenHourRecordingIsMeasuredAndReadWithoutLoadingIt() async throws {
        let store = makeStore()
        let id = UUID()
        let writer = try store.begin(id: id, engine: "stress", source: .app)
        try await writer.finish()
        let tenHours: UInt64 = 10 * 3_600 * 16_000 * 2
        let handle = try FileHandle(forWritingTo: store.audioURL(id))
        try handle.truncate(atOffset: tenHours - 4)
        try handle.seekToEnd()
        try handle.write(contentsOf: PCM16.encode([0.5, -0.5]))
        try handle.close()

        let record = try XCTUnwrap(store.records().first)
        XCTAssertEqual(record.audioBytes, Int64(tenHours))
        XCTAssertEqual(record.audioSeconds, 36_000, accuracy: 0.001)
        let reader = try AudioRecoveryReader(url: store.audioURL(id))
        XCTAssertEqual(try reader.read(maxSamples: 1_000_000).count, 4_096, "reads are bounded to 4,096 samples")
        let file = try FileHandle(forReadingFrom: store.audioURL(id))
        try file.seek(toOffset: tenHours - 4)
        XCTAssertEqual(PCM16.decode(try file.readToEnd() ?? Data()), [0.5, -0.5].map { Float(Int16(($0 * 32_767).rounded())) / 32_767 })
        try file.close()
        try store.recoverAbandoned()
        XCTAssertEqual(try store.records().first?.state, .failed)
    }
}

/// A flag two tasks share without data races.
final class ManagedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
