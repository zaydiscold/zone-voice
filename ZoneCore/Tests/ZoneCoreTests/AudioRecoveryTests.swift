// by zayd/cold @ zayd.wtf

import AVFoundation
import XCTest
@testable import ZoneCore

final class AudioRecoveryTests: XCTestCase {
    func testReplayedCompletionPreservesReleasedDurationAndSavedWords() async throws {
        let recovery = store(), id = UUID()
        defer { try? FileManager.default.removeItem(at: recovery.directory) }
        let writer = try recovery.begin(id: id, engine: "fixture", source: .app)
        writer.append([Float](repeating: 0.2, count: 24_000))
        try await writer.finish()
        try recovery.complete(id, text: "A saved phrase.")
        let reopened = AudioRecoveryStore(directory: recovery.directory)
        try reopened.complete(id, text: "A saved phrase.")
        XCTAssertEqual(try reopened.records().first?.audioSeconds, 1.5)
        for stale in ["", "A different callback."] {
            try reopened.complete(id, text: stale, discardShortEmpty: true)
            try reopened.consumeTextReceipt(id, matching: stale)
        }
        try reopened.markFailed(id, text: "Partial callback", message: "Interrupted")
        try reopened.expire(now: .distantFuture)
        let record = try XCTUnwrap(reopened.records().first)
        XCTAssertEqual(record.text, "A saved phrase.")
        XCTAssertEqual(record.state, .textReady)
        XCTAssertEqual(record.audioSeconds, 1.5)
        try reopened.consumeTextReceipt(id, matching: "A saved phrase.")
        XCTAssertTrue(try reopened.records().isEmpty)
    }

    func testDiscardRemovesKeyboardOriginalWhenReceiptIsInFallback() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let primary = root.appendingPathComponent("shared")
        let fallback = root.appendingPathComponent("local")
        let inbox = root.appendingPathComponent("inbox")
        try Data().write(to: primary) // The shared directory is unavailable at capture start.
        let store = AudioRecoveryStore(directory: primary, fallbackDirectory: fallback)
        let id = UUID()
        let writer = try store.begin(id: id, engine: "fixture", source: .keyboard)
        writer.append([Float](repeating: 0.2, count: 16_000))
        try await writer.finish()
        let otherID = UUID()
        let otherWriter = try store.begin(id: otherID, engine: "fixture", source: .app)
        try await otherWriter.finish()
        try store.discard(otherID) // The primary directory is still unavailable.
        try fm.removeItem(at: primary)
        let wav = inbox.appendingPathComponent(KeyboardCapture.handoffName(id))
        var handoff: KeyboardAudioFile? = try KeyboardAudioFile(url: wav, sampleRate: 16_000)
        handoff?.append(Data(repeating: 1, count: 32_000))
        _ = handoff?.finish()
        handoff = nil
        try store.importKeyboardAudio(from: inbox)
        let original = primary.appendingPathComponent(id.uuidString + ".wav")
        XCTAssertTrue(fm.fileExists(atPath: original.path))
        let unrelated = primary.appendingPathComponent(UUID().uuidString + ".wav")
        try Data([1, 2]).write(to: unrelated)
        let reopened = AudioRecoveryStore(directory: primary, fallbackDirectory: fallback)
        try reopened.complete(id, text: "Retain the keyboard original.")
        try reopened.consumeTextReceipt(id, matching: "Retain the keyboard original.")
        XCTAssertTrue(fm.fileExists(atPath: original.path))
        XCTAssertEqual(try reopened.records().first?.audioBytes, 32_000)
        try reopened.discard(id)
        XCTAssertFalse(fm.fileExists(atPath: original.path))
        try reopened.discard(id)
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: fallback.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: unrelated), Data([1, 2]))
        XCTAssertTrue(try reopened.records().isEmpty)
    }

    func testKeyboardHandoffRestoresEmptyOrReleasedPCMBeforeRemovingInboxFile() async throws {
        let recovery = store()
        let inbox = recovery.directory.appendingPathComponent("inbox")
        defer { try? FileManager.default.removeItem(at: recovery.directory) }
        for hadText in [false, true] {
            let id = UUID()
            let writer = try recovery.begin(id: id, engine: "fixture", source: .keyboard)
            try await writer.finish()
            if hadText { try recovery.complete(id, text: "Already saved.") }
            let wav = inbox.appendingPathComponent(KeyboardCapture.handoffName(id))
            var handoff: KeyboardAudioFile? = try KeyboardAudioFile(url: wav, sampleRate: 16_000)
            handoff?.append(PCM16.encode([Float](repeating: 0.2, count: 16_000)))
            _ = handoff?.finish()
            handoff = nil
            try recovery.importKeyboardAudio(from: inbox)
            let record = try XCTUnwrap(recovery.records().first { $0.id == id })
            XCTAssertEqual(record.keyboardHandoff, true)
            XCTAssertEqual(record.audioBytes, 32_000)
            XCTAssertEqual(record.state, hadText ? .textReady : .available)
            XCTAssertEqual(record.text, hadText ? "Already saved." : "")
            XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path))
        }
    }

    func testSavedTextKeepsOriginalDurationAfterAudioIsReleased() async throws {
        let recovery = store(), id = UUID()
        defer { try? FileManager.default.removeItem(at: recovery.directory) }
        let writer = try recovery.begin(id: id, engine: "fixture", source: .app)
        writer.append([Float](repeating: 0.2, count: 24_000))
        try await writer.finish()
        try recovery.complete(id, text: "A synthetic receipt.")
        let reopened = AudioRecoveryStore(directory: recovery.directory)
        let record = try XCTUnwrap(reopened.records().first)
        XCTAssertEqual(record.audioBytes, 0)
        XCTAssertEqual(record.audioSeconds, 1.5)
        try reopened.discard(id)
        XCTAssertTrue(try reopened.records().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: reopened.directory.path).isEmpty)
    }

    func testKeyboardImportWaitsForLiveOwnerAndRepairsAnUnfinishedHeader() throws {
        let recovery = store(), id = UUID()
        let root = recovery.directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: recovery.directory); try? FileManager.default.removeItem(at: root) }
        let wav = root.appendingPathComponent(KeyboardCapture.recordingName(id))
        var writer: KeyboardAudioFile? = try KeyboardAudioFile(url: wav, sampleRate: 16_000)
        let samples = PCM16.encode([Float](repeating: 0.2, count: 20_000))
        writer?.append(Data(samples.prefix(32_000)))
        writer?.append(Data(samples.dropFirst(32_000)))
        try recovery.importKeyboardAudio(from: root)
        XCTAssertTrue(try recovery.records().isEmpty)
        writer = nil // Abrupt end without finish. The header covers only the checkpoint.
        let partial = try FileHandle(forWritingTo: wav)
        try partial.seekToEnd()
        try partial.write(contentsOf: Data([0xff]))
        try partial.close()
        try recovery.importKeyboardAudio(from: root)
        let record = try XCTUnwrap(recovery.records().first)
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.state, .available)
        XCTAssertEqual(record.source, .keyboard)
        XCTAssertEqual(record.attempts, AudioAttempts(count: 0, earlierUnknown: false))
        XCTAssertEqual(try Data(contentsOf: recovery.audioURL(id)), samples)
        XCTAssertEqual(try XCTUnwrap(record.expiresAt).timeIntervalSince(record.updatedAt), 604_800, accuracy: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path))
        try recovery.importKeyboardAudio(from: root)
        XCTAssertEqual(try recovery.records().count, 1)
    }

    func testKeyboardHandoffKeepsFinishedWordsAndOriginalAudioAcrossAppLaunches() throws {
        let recovery = store()
        defer { try? FileManager.default.removeItem(at: recovery.directory) }
        let inbox = recovery.directory.appendingPathComponent("inbox")
        let history = TranscriptHistory(directory: recovery.directory.appendingPathComponent("history"))
        let completeID = UUID(), interruptedID = UUID()
        for id in [completeID, interruptedID] {
            let wav = inbox.appendingPathComponent(KeyboardCapture.handoffName(id))
            var writer: KeyboardAudioFile? = try KeyboardAudioFile(url: wav, sampleRate: 16_000)
            writer?.append(Data(repeating: 1, count: 32_000))
            _ = writer?.finish()
            writer = nil
        }
        try recovery.importKeyboardAudio(from: inbox)
        XCTAssertTrue(history.finish(id: completeID, text: "Keep these words.", audioSeconds: 1,
                                     status: .inserted, engine: "fluidMiniWeb", source: .keyboard))
        XCTAssertTrue(history.finish(id: interruptedID, text: "partial", audioSeconds: 1,
                                     status: .cutOff, engine: "fluidMiniWeb", source: .keyboard))
        try recovery.reconcileKeyboardHandoffs(with: history)
        // Earlier builds imported the finished text but retained the default recognizer name.
        let metadata = recovery.directory.appendingPathComponent(completeID.uuidString + ".json")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        legacy["engine"] = "zoneMini"
        try JSONSerialization.data(withJSONObject: legacy).write(to: metadata, options: .atomic)
        try recovery.reconcileKeyboardHandoffs(with: history)
        let records = try recovery.records()
        let done = try XCTUnwrap(records.first { $0.id == completeID })
        XCTAssertEqual(done.state, .textReady)
        XCTAssertEqual(done.text, "Keep these words.")
        XCTAssertEqual(done.engine, "fluidMiniWeb")
        XCTAssertEqual(done.attempts?.count, 0)
        XCTAssertEqual(history.record(id: completeID)?.engine, "fluidMiniWeb")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.audioURL(completeID).path))
        XCTAssertEqual(records.first { $0.id == interruptedID }?.state, .available)
    }

    func testHandoffRetainsOriginalAcrossImportFailureRetryAndDeliveryUntilDeleted() throws {
        let recovery = store(), id = UUID()
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: recovery.directory); try? FileManager.default.removeItem(at: inbox) }
        let source = inbox.appendingPathComponent(KeyboardCapture.recordingName(id))
        var writer: KeyboardAudioFile? = try KeyboardAudioFile(url: source, sampleRate: 16_000)
        writer?.append(PCM16.encode([Float](repeating: 0.2, count: 16_000)))
        _ = writer?.finish()
        let wav = try KeyboardAudioFile.sealForHandoff(source, id: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try KeyboardAudioFile.sealForHandoff(wav, id: id), wav)
        let lastTry = Date(timeIntervalSince1970: 1_735_000_000)
        try KeyboardAudioAttempts.begin(on: wav, retry: false, now: lastTry.addingTimeInterval(-10))
        try KeyboardAudioAttempts.finish(on: wav, outcome: .modelFailed)
        try KeyboardAudioAttempts.begin(on: wav, retry: true, now: lastTry)
        try KeyboardAudioAttempts.finish(on: wav, outcome: .noWords)
        try recovery.importKeyboardAudio(from: inbox)
        XCTAssertTrue(try recovery.records().isEmpty)
        writer = nil
        let original = try Data(contentsOf: wav)
        try recovery.importKeyboardAudio(from: inbox)
        try recovery.importKeyboardAudio(from: inbox)
        let record = try XCTUnwrap(recovery.records().first)
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.keyboardHandoff, true)
        XCTAssertEqual(record.attempts?.count, 2)
        XCTAssertEqual(record.attempts?.lastTry, lastTry)
        XCTAssertEqual(record.attempts?.outcome, .noWords)
        XCTAssertEqual(record.attempts?.earlierUnknown, false)
        XCTAssertNil(record.expiresAt)
        try recovery.markFailed(id, text: "", message: "test")
        try recovery.expire(now: .distantFuture)
        XCTAssertEqual(try recovery.prepareRetry(id).attempts?.count, 2)
        _ = try recovery.beginRetry(id)
        XCTAssertEqual(try recovery.records().first?.attempts?.count, 3)
        try recovery.complete(id, text: "test words")
        try recovery.consumeTextReceipt(id)
        try recovery.expire(now: .distantFuture)
        let preserved = recovery.directory.appendingPathComponent(id.uuidString + ".wav")
        XCTAssertEqual(try Data(contentsOf: preserved), original)
        XCTAssertEqual(try recovery.records().map(\.state), [.textReady])
        try recovery.discard(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preserved.path))
    }

    #if os(macOS)
    func testKilledKeyboardAudioWriterCanBeRecoveredByAnotherProcess() throws {
        let command = ProcessInfo.processInfo.environment
        let id = UUID(uuidString: "A76E7E1F-5113-4C31-A3D4-57F94E0E0572")!
        if let directory = command["ZONE_TEST_KILLED_WRITER"] {
            let wav = URL(fileURLWithPath: directory).appendingPathComponent(KeyboardCapture.recordingName(id))
            let writer = try KeyboardAudioFile(url: wav, sampleRate: 16_000)
            writer.append(PCM16.encode([Float](repeating: 0.1, count: 16_000)))
            writer.append(PCM16.encode([Float](repeating: -0.1, count: 4_000)))
            _ = withExtendedLifetime(writer) { kill(getpid(), SIGKILL) }
            return
        }

        let recovery = store()
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: inbox); try? FileManager.default.removeItem(at: recovery.directory) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "ZoneCoreTests.AudioRecoveryTests/testKilledKeyboardAudioWriterCanBeRecoveredByAnotherProcess",
                           Bundle(for: AudioRecoveryTests.self).bundlePath]
        child.environment = command.merging(["ZONE_TEST_KILLED_WRITER": inbox.path]) { _, new in new }
        child.standardOutput = FileHandle.nullDevice
        try child.run()
        child.waitUntilExit()
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.terminationStatus, SIGKILL)
        try recovery.importKeyboardAudio(from: inbox)
        XCTAssertEqual(try recovery.records().first?.id, id)
        var expected = PCM16.encode([Float](repeating: 0.1, count: 16_000))
        expected += PCM16.encode([Float](repeating: -0.1, count: 4_000))
        XCTAssertEqual(try Data(contentsOf: recovery.audioURL(id)), expected)
    }
    #endif

    func testEraseRejectsDelayedWritesAfterKeyboardAcknowledgesIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let epoch = KeyboardCapture.eraseEpoch(in: dir)
        XCTAssertTrue(KeyboardCapture.whileLibraryCurrent(in: dir, epoch: epoch) { true })
        try KeyboardCapture.requestAudioErase(in: dir)
        try KeyboardCapture.finishAudioErase(in: dir, temporary: dir) {}
        XCTAssertFalse(KeyboardCapture.whileLibraryCurrent(in: dir, epoch: epoch) { XCTFail("Late write"); return true })
        XCTAssertTrue(KeyboardCapture.whileLibraryCurrent(in: dir, epoch: KeyboardCapture.eraseEpoch(in: dir)) { true })
    }

    private func store() -> AudioRecoveryStore {
        AudioRecoveryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    func testOnlySubmittingAudioCountsAKeyboardAttemptAcrossFallbacks() throws {
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([0, 1]).write(to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }
        try KeyboardAudioAttempts.initializeNewFile(wav)

        let unavailable = KeyboardRecognitionAttempt(wav: wav, retry: false)
        try unavailable.finish(.modelFailed)
        try unavailable.submit()
        XCTAssertEqual(try KeyboardAudioAttempts.read(from: wav)?.count, 0)

        let pass = KeyboardRecognitionAttempt(wav: wav, retry: true)
        try pass.submit()
        try pass.submit()
        try pass.finish(.transcribed)
        try pass.finish(.modelFailed)
        let receipt = try XCTUnwrap(KeyboardAudioAttempts.read(from: wav))
        XCTAssertEqual(receipt.count, 1)
        XCTAssertEqual(receipt.outcome, .transcribed)
    }

    func testKeyboardAttemptsFollowTheWavAndAHomeScanDoesNotAddATry() async throws {
        let recovery = store(), folder = recovery.directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let wav = folder.appendingPathComponent("recording.wav"), retry = folder.appendingPathComponent("retry.wav")
        try Data([1, 0]).write(to: wav)
        XCTAssertNil(try KeyboardAudioAttempts.read(from: wav))
        try KeyboardAudioAttempts.begin(on: wav, retry: false)
        try KeyboardAudioAttempts.finish(on: wav, outcome: .modelFailed)
        try FileManager.default.moveItem(at: wav, to: retry)
        XCTAssertEqual(try KeyboardAudioAttempts.read(from: retry)?.count, 1)
        let now = Date(timeIntervalSince1970: 1234)
        try KeyboardAudioAttempts.begin(on: retry, retry: true, now: now)
        let tries = try XCTUnwrap(KeyboardAudioAttempts.read(from: retry))
        XCTAssertEqual(tries, .init(count: 2, lastTry: now, outcome: .interrupted, earlierUnknown: false))
        XCTAssertEqual(try KeyboardAudioAttempts.read(from: retry), tries)

        let id = UUID(), writer = try recovery.begin(id: id, engine: "test", source: .keyboard)
        writer.append([0.5, -0.5])
        try await writer.finish()
        var record = try XCTUnwrap(recovery.records().first { $0.id == id })
        record.attempts = try KeyboardAudioAttempts.read(from: retry)
        try JSONEncoder().encode(record).write(to: folder.appendingPathComponent(id.uuidString + ".json"), options: .atomic)
        for _ in 0..<2 { XCTAssertEqual(try recovery.records().first { $0.id == id }?.attempts, tries) }
        let homeRetry = try recovery.beginRetry(id, now: now.addingTimeInterval(10))
        XCTAssertEqual(homeRetry.attempts?.count, 3)
        XCTAssertEqual(homeRetry.attempts?.earlierUnknown, false)
    }

    func testRetryOfAnUnstampedKeyboardFileDoesNotInventEarlierTries() throws {
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data([1, 0]).write(to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }
        try KeyboardAudioAttempts.begin(on: wav, retry: true)
        try KeyboardAudioAttempts.finish(on: wav, outcome: .noWords)
        let tries = try XCTUnwrap(KeyboardAudioAttempts.read(from: wav))
        XCTAssertEqual(tries.count, 1)
        XCTAssertTrue(tries.earlierUnknown)
        XCTAssertEqual(tries.outcome, .noWords)
    }

    func testEraseReportsAnUnreadableRecordingFolderEvenIfTheFallbackIsReadable() throws {
        let fm = FileManager.default, primary = store().directory, fallback = store().directory
        try fm.createDirectory(at: primary, withIntermediateDirectories: true)
        try fm.createDirectory(at: fallback, withIntermediateDirectories: true)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: primary.path)
            try? fm.removeItem(at: primary)
            try? fm.removeItem(at: fallback)
        }
        let retained = primary.appendingPathComponent(UUID().uuidString + ".json")
        try Data().write(to: retained)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: primary.path)
        let storage = AudioRecoveryStore(directory: primary, fallbackDirectory: fallback)
        XCTAssertThrowsError(try storage.eraseRecordings())
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: primary.path)
        try storage.eraseRecordings()
        XCTAssertFalse(fm.fileExists(atPath: retained.path))
    }

    func testEraseBeforeLoadingRecoveryAlsoRemovesUnreadableMetadata() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let url = store.directory.appendingPathComponent(UUID().uuidString + ".json")
        try Data("damaged record".utf8).write(to: url)
        try store.eraseRecordings()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
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
        let wave = try store.exportWave(id)
        defer { try? FileManager.default.removeItem(at: wave) }
        let exported = try AVAudioFile(forReading: wave)
        XCTAssertEqual(exported.length, 5)
        XCTAssertEqual(exported.processingFormat.sampleRate, 16_000)
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
    /// A five second note the model heard no words in keeps its audio: a note is meant to be
    /// kept, even when the microphone received only a single sample.
    func testAShortNoteWithNoWordsKeepsItsAudio() async throws {
        let store = store(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let note = UUID()
        var writer = try store.begin(id: note, engine: "test", source: .note)
        writer.append([Float](repeating: 0.1, count: 16_000 * 5)); try await writer.finish()
        XCTAssertNoThrow(try store.complete(note, text: "", discardShortEmpty: true, shortUnder: AudioRecoveryStore.minimumNoteSeconds))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(note).path))
        XCTAssertEqual(try store.records().first?.state, .noWords)
        let brief = UUID()
        writer = try store.begin(id: brief, engine: "test", source: .note)
        writer.append([Float](repeating: 0.1, count: 8_000)); try await writer.finish()
        XCTAssertNoThrow(try store.complete(brief, text: "", discardShortEmpty: true, shortUnder: AudioRecoveryStore.minimumNoteSeconds))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(brief).path))
        let slip = UUID()
        writer = try store.begin(id: slip, engine: "test", source: .note)
        writer.append([0.1]); try await writer.finish()
        XCTAssertNoThrow(try store.complete(slip, text: "", discardShortEmpty: true, shortUnder: AudioRecoveryStore.minimumNoteSeconds))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(slip).path))
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

extension AudioRecoveryTests {
    func testFirstSubmissionCountsOnceAndLoadingRetryKeepsPastOutcome() async throws {
        let store = store(), id = UUID()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let writer = try store.begin(id: id, engine: "test", source: .note)
        writer.append([0.2])
        XCTAssertEqual(try store.records().first?.attempts?.count, 0)
        try writer.submission.record()
        try writer.submission.record()
        try await writer.finish()
        XCTAssertEqual(try store.records().first?.attempts?.count, 1)
        try store.markFailed(id, text: "", message: "test")
        XCTAssertEqual(try store.prepareRetry(id).attempts?.outcome, .modelFailed)
        try store.recoverAbandoned()
        XCTAssertEqual(try store.records().first?.attempts?.count, 1)
        XCTAssertEqual(try store.records().first?.attempts?.outcome, .modelFailed)
    }

    func testLiveTryRetryAndRelaunchCountOnlyActualTries() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let id = UUID(), first = Date(), second = first.addingTimeInterval(5)
        let writer = try store.begin(id: id, engine: "test", source: .keyboard, attempting: true, now: first)
        writer.append([0, 0])
        try await writer.finish()
        XCTAssertThrowsError(try store.complete(id, text: ""))
        var history = try XCTUnwrap(store.records().first?.attempts)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.outcome, .noWords)
        XCTAssertEqual(history.lastTry, first)
        _ = try store.beginRetry(id, now: second)
        try store.recoverAbandoned(now: second)
        try store.recoverAbandoned(now: second)
        history = try XCTUnwrap(store.records().first?.attempts)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.outcome, .interrupted)
        XCTAssertEqual(history.lastTry, second)
    }

    func testOlderRecordingKeepsUnknownHistoryDuringAnalysisAndRetry() async throws {
        let store = store(), id = UUID()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let writer = try store.begin(id: id, engine: "test", source: .app)
        writer.append([Float](repeating: 0, count: 5001))
        try await writer.finish()
        let url = store.directory.appendingPathComponent(id.uuidString + ".json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object.removeValue(forKey: "attempts")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        try store.recoverAbandoned()
        try store.fillLevels(id)
        let record = try XCTUnwrap(store.records().first)
        XCTAssertNil(record.attempts)
        XCTAssertEqual(record.levels?.samples, 5001)
        XCTAssertEqual(record.levels?.activeSeconds, 0)
        let retried = try store.beginRetry(id)
        XCTAssertEqual(retried.attempts?.count, 1)
        XCTAssertEqual(retried.attempts?.earlierUnknown, true)
    }

    func testLevelsOnBundledSpeechQuietSpeechSilenceAndMusic() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Zone/Resources")
        for (name, gain, seconds, average) in [
            ("test-clip.wav", 1.0, 5.46, -16.29), ("test-clip.wav", 0.0631, 3.88, -40.29),
            ("Sounds/island-relay-silence.caf", 1.0, 0, -120),
            ("Sounds/dictation-stop-kalimba.caf", 1.0, 0.39, -18.20)
        ] {
            let audio = try AVAudioFile(forReading: resources.appendingPathComponent(name))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)))
            try audio.read(into: buffer)
            let source = try XCTUnwrap(buffer.floatChannelData?[0])
            let rate = buffer.format.sampleRate
            let frames = Int((Double(buffer.frameLength) * 16_000 / rate).rounded(.down))
            let samples = (0..<frames).map { source[Int(Double($0) * rate / 16_000)] * Float(gain) }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: url) }
            try PCM16.encode(samples).write(to: url)
            let result = try RecoveryLevels.measure(url)
            XCTAssertEqual(result.activeSeconds, seconds, accuracy: 0.03, name)
            XCTAssertEqual(result.averageDB, average, accuracy: 0.1, name)
            XCTAssertGreaterThanOrEqual(result.peakDB, result.averageDB)
            XCTAssertEqual(result.soundsLikeSpeech, seconds > 0)
        }
    }
}
