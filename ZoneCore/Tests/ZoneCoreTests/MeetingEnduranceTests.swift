// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class MeetingEnduranceTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func sparseAudio(hours: Int) throws -> MeetingAudio {
        let url = directory.appendingPathComponent("long.pcm")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(hours * 3_600 * 32_000))
        try handle.seek(toOffset: UInt64(hours * 3_600 * 32_000 - 2))
        try handle.write(contentsOf: Data([0xff, 0x3f]))
        try handle.close()
        return try MeetingAudio(urls: [url])
    }

    func testSixTenAndFifteenHourFilesKeepDurationAndTailSamples() throws {
        for hours in [6, 10, 15] {
            let audio = try sparseAudio(hours: hours)
            XCTAssertEqual(audio.duration, Double(hours * 3_600))
            XCTAssertEqual(try audio.read(offset: audio.sampleCount - 1, count: 1)[0], 0.5, accuracy: 0.0001)
            let levels = [Float](repeating: 0.2, count: hours * 36_000)
            let chunks = MeetingChunkPlanner.plan(turns: [], levels: levels, from: 0, to: audio.duration)
            XCTAssertEqual(chunks.first?.start, 0)
            XCTAssertEqual(chunks.last?.end, audio.duration)
            XCTAssertTrue(chunks.allSatisfy { $0.duration <= 28.001 })
            for pair in zip(chunks, chunks.dropFirst()) { XCTAssertEqual(pair.0.end, pair.1.start) }
            print("ENDURANCE: \(hours) h, \(audio.sampleCount * 2) bytes, \(chunks.count) bounded speech chunks")
        }
    }

    func testSixHourInterruptedRecordingRecoversFromAudioBytes() async throws {
        let folder = directory.appendingPathComponent("recovery")
        let store = MeetingStore(directory: folder)
        let (meeting, writer) = try store.beginRecording()
        try await writer.finish()
        let handle = try FileHandle(forWritingTo: writer.url)
        // Simulate durable audio with metadata not yet updated when the process disappears.
        try handle.truncate(atOffset: 691_200_000)
        try handle.seek(toOffset: 691_199_998)
        try handle.write(contentsOf: Data([0xff, 0x3f]))
        try handle.close()
        let reopened = MeetingStore(directory: folder)
        XCTAssertEqual(reopened.recoverInterrupted(), [meeting.id])
        let recovered = try reopened.meeting(meeting.id)
        XCTAssertEqual(recovered.status, .recorded)
        XCTAssertEqual(recovered.duration, 21_600)
        let audio = try MeetingAudio(urls: reopened.audioURLs(recovered))
        XCTAssertEqual(audio.sampleCount, 345_600_000)
        XCTAssertEqual(try audio.read(offset: audio.sampleCount - 1, count: 1)[0], 0.5, accuracy: 0.0001)
        XCTAssertTrue(reopened.recoverInterrupted().isEmpty)
    }

    /// An accelerated full writer pass, opt-in because it writes 691 MB. It does not simulate
    /// six hours of battery, heat, interruptions or background execution on an iPhone.
    func testSixHourDefaultCaptureCeilingWithRealWriter() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ZONE_RUN_SIX_HOUR_CAPTURE"] == "1")
        let writer = try MeetingAudioWriter(url: directory.appendingPathComponent("six-hours.pcm"))
        let capture = MeetingCaptureProgress()
        let chunk = [Float](repeating: 0.2, count: 16_001)
        while !capture.reachedLimit {
            if let failure = writer.failure { throw failure }
            while capture.sampleCount - writer.writtenSamples > 320_000 {
                if let failure = writer.failure { throw failure }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            capture.append(chunk, to: writer)
        }
        XCTAssertEqual(capture.sampleCount, 345_600_000)
        capture.append(chunk, to: writer)
        capture.close()
        try await writer.finish()
        XCTAssertEqual(writer.writtenSamples, 345_600_000)
        XCTAssertEqual(writer.droppedSamples, 0)
        XCTAssertEqual(try MeetingAudio(urls: [writer.url]).duration, 21_600)
    }

    func testCancelledLevelScanDoesNotReadFifteenHours() async throws {
        let audio = try sparseAudio(hours: 15)
        let gate = TestGate()
        let task = Task {
            await gate.wait()
            return try audio.levels()
        }
        task.cancel()
        await gate.open()
        do { _ = try await task.value; XCTFail("cancelled scan must stop before reading the file") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testTruncatedAudioIsAnErrorInsteadOfFabricatedSilence() throws {
        let audio = try sparseAudio(hours: 10)
        let handle = try FileHandle(forWritingTo: directory.appendingPathComponent("long.pcm"))
        try handle.truncate(atOffset: 0)
        try handle.close()
        XCTAssertThrowsError(try audio.read(offset: audio.sampleCount - 16_000, count: 16_000))
    }

    func testCaptureCeilingPauseAndStaleCallbacksKeepOnlyAcceptedAudio() async throws {
        let writer = try MeetingAudioWriter(url: directory.appendingPathComponent("cap.pcm"))
        let capture = MeetingCaptureProgress(maximumSamples: 16_000)
        capture.setPaused(true)
        capture.append([Float](repeating: 0.2, count: 8_000), to: writer)
        XCTAssertEqual(capture.sampleCount, 0)
        capture.setPaused(false)
        for _ in 0..<8 { capture.append([Float](repeating: 0.3, count: 3_000), to: writer) }
        XCTAssertTrue(capture.reachedLimit)
        XCTAssertEqual(capture.sampleCount, 16_000)
        capture.close()
        capture.append([Float](repeating: 0.4, count: 3_000), to: writer)
        try await writer.finish()
        XCTAssertEqual(writer.writtenSamples, 16_000)
        XCTAssertEqual(writer.droppedSamples, 0)
        XCTAssertEqual(try MeetingAudio(urls: [writer.url]).duration, 1)
    }

    func testRejectedWriterBuffersNeverAdvanceRecordedClock() async throws {
        let writer = try MeetingAudioWriter(url: directory.appendingPathComponent("drop.pcm"), maxQueuedSamples: 100)
        let capture = MeetingCaptureProgress()
        capture.append([Float](repeating: 0.2, count: 101), to: writer)
        XCTAssertEqual(capture.sampleCount, 0)
        XCTAssertEqual(writer.droppedSamples, 101)
        try await writer.finish()
    }

    func testStorageReserveAndSpeakerDurationBoundaries() {
        XCTAssertTrue(MeetingRecordingSafety.shouldStop(availableBytes: 99_999_999))
        XCTAssertTrue(MeetingRecordingSafety.shouldStop(availableBytes: 100_000_000))
        XCTAssertFalse(MeetingRecordingSafety.shouldStop(availableBytes: 100_000_001))
        XCTAssertFalse(MeetingRecordingSafety.shouldStop(availableBytes: nil))
        XCTAssertEqual(MeetingRecordingSafety.maximumSeconds, 21_600)
        XCTAssertEqual(MeetingRecordingSafety.maximumSpeakerSeconds, 7_200)
        XCTAssertEqual(MeetingRecordingSafety.maximumLabel, "6 hours")
        XCTAssertEqual(MeetingRecordingSafety.speakerLabel, "2 hours")
    }

    func testStorageShorterThanCeilingIsReportedInMinutes() {
        XCTAssertNil(MeetingRecordingSafety.storageMinutes(hoursOfSpace: nil))
        XCTAssertNil(MeetingRecordingSafety.storageMinutes(hoursOfSpace: 6))
        XCTAssertNil(MeetingRecordingSafety.storageMinutes(hoursOfSpace: 200))
        XCTAssertEqual(MeetingRecordingSafety.storageMinutes(hoursOfSpace: 0.75), 45)
        XCTAssertEqual(MeetingRecordingSafety.storageMinutes(hoursOfSpace: 5.99), 359)
        XCTAssertEqual(MeetingRecordingSafety.storageMinutes(hoursOfSpace: 0), 0)
    }

    func testSafetyNoticeSurvivesTranscriptionResetAndExport() async throws {
        let store = MeetingStore(directory: directory.appendingPathComponent("store"))
        let (meeting, writer) = try store.beginRecording()
        writer.append([Float](repeating: 0.2, count: 32_000))
        try await writer.finish()
        try store.finishRecording(meeting.id, recordingNotice: MeetingRecordingSafety.storageMessage)
        try store.update(meeting.id) { $0.status = .done }
        try store.resetTranscript(meeting.id)
        let restored = try store.meeting(meeting.id)
        XCTAssertEqual(restored.recordingNotice, MeetingRecordingSafety.storageMessage)
        XCTAssertTrue(MeetingExport.text(restored).contains(MeetingRecordingSafety.storageMessage))
    }

    @MainActor
    func testRecordingSuspendsProcessingAndResumesTheInterruptedJobOnce() async {
        let entered = expectation(description: "first processing entered")
        let gate = TestGate()
        let a = UUID(), b = UUID()
        var runs: [UUID] = []
        let queue = MeetingWorkQueue { id in
            runs.append(id)
            if runs.count == 1 { entered.fulfill(); await gate.wait() }
        }
        queue.enqueue(a)
        await fulfillment(of: [entered], timeout: 2)
        queue.suspend()
        for _ in 0..<8 { queue.enqueue(a); queue.enqueue(b) }
        await gate.open()
        await queue.drain()
        XCTAssertEqual(runs, [a])
        XCTAssertNil(queue.active)
        XCTAssertEqual(queue.pending, [a, b])
        queue.resume()
        await queue.drain()
        XCTAssertEqual(runs, [a, a, b])
    }

    @MainActor
    func testExplicitPauseWhileRecordingRemovesAutomaticResume() async {
        let entered = expectation(description: "processing entered")
        let gate = TestGate()
        let a = UUID()
        var runs = 0
        let queue = MeetingWorkQueue { _ in runs += 1; entered.fulfill(); await gate.wait() }
        queue.enqueue(a)
        await fulfillment(of: [entered], timeout: 2)
        queue.suspend()
        queue.cancel(a)
        await gate.open()
        await queue.drain()
        queue.resume()
        await queue.drain()
        XCTAssertEqual(runs, 1)
        XCTAssertTrue(queue.pending.isEmpty)
    }

    @MainActor
    func testEightImmediateDuplicateRequestsHaveOneOwnerAndOneExecution() async {
        let done = expectation(description: "two jobs")
        done.expectedFulfillmentCount = 2
        var runs: [UUID] = []
        let queue = MeetingWorkQueue { id in runs.append(id); done.fulfill() }
        let a = UUID(), b = UUID()
        for _ in 0..<8 { queue.enqueue(a); queue.enqueue(b) }
        XCTAssertEqual(queue.active, a, "reservation must precede the first task hop")
        XCTAssertEqual(queue.pending, [b])
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(runs, [a, b])
    }

    @MainActor
    func testCancellationBeforeTaskStartsSkipsWorkAndAdvancesQueue() async {
        let done = expectation(description: "second runs")
        let a = UUID(), b = UUID()
        var runs: [UUID] = []
        let queue = MeetingWorkQueue { id in runs.append(id); done.fulfill() }
        queue.enqueue(a)
        queue.enqueue(b)
        queue.cancel(a)
        XCTAssertEqual(queue.active, a, "retain ownership until cancelled task exits")
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(runs, [b])
    }

    @MainActor
    func testCancellationIgnoringJobCannotOverlapTheNextMeeting() async {
        let entered = expectation(description: "first entered")
        let done = expectation(description: "second finished")
        let gate = TestGate()
        let a = UUID(), b = UUID()
        var runs: [UUID] = []
        let queue = MeetingWorkQueue { id in
            runs.append(id)
            if id == a { entered.fulfill(); await gate.wait() } else { done.fulfill() }
        }
        queue.enqueue(a)
        await fulfillment(of: [entered], timeout: 2)
        queue.cancel(a)
        for _ in 0..<8 { queue.enqueue(b) }
        XCTAssertEqual(queue.active, a)
        XCTAssertEqual(runs, [a])
        await gate.open()
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(runs, [a, b])
    }

    func testTimedOutNativeWorkRetainsOwnershipUntilItActuallyFinishes() async throws {
        let lane = ExclusiveModelWork()
        let gate = TestGate()
        let entered = expectation(description: "native entered")
        let exited = expectation(description: "native exited")
        let caller = Task {
            try await Watchdog.run(what: "speakers", limit: 0.1, checkEvery: 0.01) {
                try await lane.run {
                    entered.fulfill()
                    await gate.wait() // Deliberately ignores cancellation, like a native call.
                    exited.fulfill()
                    return 1
                }
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        do { _ = try await caller.value; XCTFail("must time out") }
        catch { XCTAssertTrue(error is Watchdog.Stalled) }
        for _ in 0..<8 {
            do { _ = try await lane.run { 2 }; XCTFail("old work still owns the lane") }
            catch { XCTAssertTrue(error is ExclusiveModelWork.Busy) }
        }
        await gate.open()
        await fulfillment(of: [exited], timeout: 2)
        // Join the native task's unwind via a bounded yield, rather than sleep timing.
        var recovered = false
        for _ in 0..<1_000 {
            if (try? await lane.run { 3 }) == 3 { recovered = true; break }
            await Task.yield()
        }
        XCTAssertTrue(recovered)
    }
}

private actor TestGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
