// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// What happens to a recording when iOS takes the microphone (2026-11-03: a snoozed alarm every
/// nine minutes during a meeting). The policy, the segmented recognizer that keeps one
/// recording across the gaps, History's paused in-flight file and the recovery checkpoint.
final class InterruptionPolicyTests: XCTestCase {
    func testARecordingIsHeldNeverEnded() {
        XCTAssertEqual(InterruptionPolicy.began(.recording), .hold)
        XCTAssertEqual(InterruptionPolicy.began(.held), .nothing, "a second interruption during a hold changes nothing")
        XCTAssertEqual(InterruptionPolicy.began(.standingBy), .standDown)
        XCTAssertEqual(InterruptionPolicy.began(.off), .nothing)
    }

    func testTheMeetingCaseResumesFromTheLockedScreen() {
        // 11:51:35 alarm, 11:51:37 resumable end, Zone in front with the screen off: iOS
        // reports that as not active, and shouldResume is what lets it continue.
        XCTAssertEqual(InterruptionPolicy.ended(.held, wasStandingBy: false, shouldResume: true, appActive: false), .resume)
    }

    func testWithoutTheHintAHeldRecordingWaitsUnlessZoneIsOnScreen() {
        XCTAssertEqual(InterruptionPolicy.ended(.held, wasStandingBy: false, shouldResume: false, appActive: false), .waitForApp)
        XCTAssertEqual(InterruptionPolicy.ended(.held, wasStandingBy: false, shouldResume: false, appActive: true), .resume)
    }

    func testAStandbyComesBackOnlyWithTheHint() {
        XCTAssertEqual(InterruptionPolicy.ended(.off, wasStandingBy: true, shouldResume: true, appActive: false), .rearm)
        XCTAssertEqual(InterruptionPolicy.ended(.off, wasStandingBy: true, shouldResume: false, appActive: true), .nothing)
        XCTAssertEqual(InterruptionPolicy.ended(.off, wasStandingBy: false, shouldResume: true, appActive: true), .nothing)
    }

    func testAnEndWithNoHoldDoesNothing() {
        XCTAssertEqual(InterruptionPolicy.ended(.recording, wasStandingBy: false, shouldResume: true, appActive: true), .nothing)
        XCTAssertEqual(InterruptionPolicy.ended(.standingBy, wasStandingBy: true, shouldResume: true, appActive: true), .nothing)
    }

    func testForegroundResumesUntilTheHoldLimitThenFinishes() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(InterruptionPolicy.foreground(heldSince: nil, now: start), .nothing)
        XCTAssertEqual(InterruptionPolicy.foreground(heldSince: start, now: start + 5), .resume)
        XCTAssertEqual(InterruptionPolicy.foreground(heldSince: start, now: start + InterruptionPolicy.holdLimit - 1), .resume)
        XCTAssertEqual(InterruptionPolicy.foreground(heldSince: start, now: start + InterruptionPolicy.holdLimit), .finish)
        XCTAssertFalse(InterruptionPolicy.holdExpired(heldSince: start, now: start + 60))
        XCTAssertTrue(InterruptionPolicy.holdExpired(heldSince: start, now: start + InterruptionPolicy.holdLimit + 1))
    }

    func testInputStallThreshold() {
        XCTAssertFalse(InterruptionPolicy.inputStalled(lastBufferAge: 0.05))
        XCTAssertFalse(InterruptionPolicy.inputStalled(lastBufferAge: 1.9))
        XCTAssertTrue(InterruptionPolicy.inputStalled(lastBufferAge: 2))
    }

    func testSegmentTextJoinsWithOneSpaceAndSkipsEmptyRuns() {
        XCTAssertEqual(SegmentText.join("", ""), "")
        XCTAssertEqual(SegmentText.join("Hello there.", ""), "Hello there.")
        XCTAssertEqual(SegmentText.join("", " And then "), "And then")
        XCTAssertEqual(SegmentText.join("Hello there. ", " And then"), "Hello there. And then")
    }
}

/// A recognizer run that records what it was fed and returns "w<n>" for every 16 000 samples.
private final class FakeRun: RecognitionSession, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var fed: [Float] = []
    let name: String
    var finishDelay: Duration = .zero
    var finishError: Error?
    var capacity = Int.max
    private(set) var finished = false
    private(set) var cancelled = false

    init(_ name: String) { self.name = name }

    var audioSeconds: Double { lock.withLock { Double(fed.count) / 16_000 } }
    var textSoFar: String {
        lock.withLock { (0..<(fed.count / 16_000)).map { "\(name)\($0)" }.joined(separator: " ") }
    }
    var failure: Error? { nil }
    var availableAudioSamples: Int { capacity }
    func feed(_ samples: [Float]) { lock.withLock { fed += samples } }
    func finish() async throws -> String {
        if finishDelay != .zero { try await Task.sleep(for: finishDelay) }
        lock.withLock { finished = true }
        if let finishError { throw finishError }
        return textSoFar
    }
    func cancel() { lock.withLock { cancelled = true } }
}

private struct Boom: Error {}

final class SegmentedRecognitionTests: XCTestCase {
    private let second = [Float](repeating: 0.1, count: 16_000)

    func testOneRunBehavesLikeThePlainSession() async throws {
        let run = FakeRun("a")
        let recording = SegmentedRecognition(first: run)
        recording.feed(second); recording.feed(second)
        XCTAssertEqual(recording.textSoFar, "a0 a1")
        XCTAssertEqual(recording.audioSeconds, 2, accuracy: 0.001)
        let text = try await recording.finish()
        XCTAssertEqual(text, "a0 a1")
        XCTAssertTrue(run.finished)
        XCTAssertEqual(recording.summary.segments, 1)
    }

    func testAnInterruptionClosesTheRunAndTheResumeContinuesTheSameRecording() async throws {
        let first = FakeRun("a"), next = FakeRun("b")
        let recording = SegmentedRecognition(first: first)
        recording.feed(second); recording.feed(second)
        await recording.closeSegment()
        XCTAssertTrue(first.finished, "everything heard before the alarm is recognized to the end")
        XCTAssertTrue(recording.isSettled)
        XCTAssertEqual(recording.textSoFar, "a0 a1")
        try await recording.openSegment { next }
        recording.feed(second)
        XCTAssertEqual(recording.textSoFar, "a0 a1 b0")
        let text = try await recording.finish()
        XCTAssertEqual(text, "a0 a1 b0")
        XCTAssertEqual(recording.audioSeconds, 3, accuracy: 0.001)
        XCTAssertEqual(recording.summary.segments, 2)
    }

    func testAudioThatArrivesBeforeTheNextRunOpensIsFedFirstAndInOrder() async throws {
        let first = FakeRun("a"), next = FakeRun("b")
        first.finishDelay = .milliseconds(150)
        let recording = SegmentedRecognition(first: first)
        recording.feed(second)
        let closing = Task { await recording.closeSegment() }
        try await Task.sleep(for: .milliseconds(20))
        // The microphone is back while the first run is still decoding.
        let marked = (0..<16_000).map { Float($0) / 16_000 }
        recording.feed(marked)
        let opening = Task { try await recording.openSegment { next } }
        try await Task.sleep(for: .milliseconds(20))
        recording.feed(second)
        await closing.value
        try await opening.value
        recording.feed(second)
        XCTAssertEqual(next.fed.count, 48_000)
        XCTAssertEqual(Array(next.fed.prefix(16_000)), marked, "waiting audio goes first, in order")
        let text = try await recording.finish()
        XCTAssertEqual(text, "a0 b0 b1 b2")
    }

    func testTheWaitingAudioRespectsTheNextRunsCapacity() async throws {
        let first = FakeRun("a"), next = FakeRun("b")
        next.capacity = 4_096
        let recording = SegmentedRecognition(first: first)
        await recording.closeSegment()
        recording.feed([Float](repeating: 0.2, count: 40_000)) // no run open yet
        try await recording.openSegment { next }
        XCTAssertEqual(next.fed.count, 40_000)
    }

    func testAFailedCloseKeepsWhatWasRecognizedAndIsCounted() async throws {
        let first = FakeRun("a"), next = FakeRun("b")
        first.finishError = Boom()
        let recording = SegmentedRecognition(first: first)
        recording.feed(second)
        await recording.closeSegment()
        XCTAssertEqual(recording.summary.failedSegments, 1)
        XCTAssertEqual(recording.textSoFar, "a0")
        try await recording.openSegment { next }
        recording.feed(second)
        let text = try await recording.finish()
        XCTAssertEqual(text, "a0 b0")
    }

    func testStopWhileHeldReturnsTheClosedTextWithoutAnEngine() async throws {
        let first = FakeRun("a")
        let recording = SegmentedRecognition(first: first)
        recording.feed(second)
        await recording.closeSegment()
        let text = try await recording.finish()
        XCTAssertEqual(text, "a0")
    }

    func testStopDuringTheCloseWaitsForIt() async throws {
        let first = FakeRun("a")
        first.finishDelay = .milliseconds(100)
        let recording = SegmentedRecognition(first: first)
        recording.feed(second)
        let closing = Task { await recording.closeSegment() }
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(recording.textSoFar, "a0", "the closing run still counts while it decodes")
        let text = try await recording.finish()
        await closing.value
        XCTAssertEqual(text, "a0")
    }

    func testAFinalFailureLeavesThePartialWordsForTheCaller() async throws {
        let first = FakeRun("a"), next = FakeRun("b")
        let recording = SegmentedRecognition(first: first)
        recording.feed(second)
        await recording.closeSegment()
        next.finishError = Boom()
        try await recording.openSegment { next }
        recording.feed(second)
        do {
            _ = try await recording.finish()
            XCTFail("expected the final run's failure")
        } catch {
            XCTAssertEqual(recording.textSoFar, "a0 b0")
        }
    }

    func testCancelReachesEveryRun() async throws {
        let first = FakeRun("a")
        let recording = SegmentedRecognition(first: first)
        recording.feed(second)
        recording.cancel()
        XCTAssertTrue(first.cancelled)
        recording.feed(second)
        XCTAssertEqual(first.fed.count, 16_000, "nothing reaches a cancelled recording")
    }

    func testWaitingAudioPastTheLimitIsDroppedAndCounted() async {
        let recording = SegmentedRecognition(first: FakeRun("a"))
        await recording.closeSegment()
        recording.feed([Float](repeating: 0, count: SegmentedRecognition.pendingLimit))
        recording.feed(second)
        XCTAssertEqual(recording.summary.droppedSeconds, 1, accuracy: 0.001)
    }
}

final class HeldRecordingStorageTests: XCTestCase {
    private var directory: URL!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("held-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTheKeyboardLeavesAPausedRecordingAloneWhileItIsHeld() {
        let history = TranscriptHistory(directory: directory)
        let id = UUID()
        history.begin(id: id, engine: "test", source: .app, now: t0)
        history.saveProgress(id: id, text: "words before the alarm", audioSeconds: 475, status: .paused, interruptions: 1, now: t0 + 480)
        // Zone is suspended for the hold; the keyboard appears ten minutes later.
        XCTAssertTrue(history.recoverCutOff(now: t0 + 1_080).isEmpty)
        // The resume and the stop then finish it normally, with the count.
        history.saveProgress(id: id, text: "words before the alarm and after", audioSeconds: 600, status: .recording, now: t0 + 1_090)
        history.finish(id: id, text: "words before the alarm and after", audioSeconds: 600, now: t0 + 1_100)
        let record = history.records(now: t0 + 1_101).first
        XCTAssertEqual(record?.status, .finished)
        XCTAssertEqual(record?.interruptions, 1)
        XCTAssertEqual(record?.createdAt, t0)
    }

    func testAPausedRecordingIsCutOffWhenTheHoldIsLongOverOrAtLaunch() {
        let history = TranscriptHistory(directory: directory)
        let a = UUID(), b = UUID()
        history.begin(id: a, engine: "test", source: .app, now: t0)
        history.saveProgress(id: a, text: "held", audioSeconds: 10, status: .paused, now: t0)
        XCTAssertEqual(history.recoverCutOff(now: t0 + InterruptionPolicy.holdLimit + 120).map(\.id), [a])
        history.begin(id: b, engine: "test", source: .app, now: t0)
        history.saveProgress(id: b, text: "held too", audioSeconds: 10, status: .paused, now: t0)
        // A new app process holds nothing.
        XCTAssertEqual(history.recoverCutOff(now: t0 + 1, activeWindow: 0, pausedWindow: 0).map(\.id), [b])
        XCTAssertEqual(history.record(id: b)?.status, .cutOff)
    }

    func testOlderRecordsWithoutTheCountStillDecode() throws {
        let json = #"{"retention":"thirtyDays","records":[{"id":"552EBF3C-12F3-47E0-B36C-30A77DA2AEEC","updatedAt":"2026-11-03T20:47:09Z","createdAt":"2026-11-03T20:47:09Z","text":"Next week","source":"app","status":"finished","audioSeconds":474.9,"engine":"fluidMiniCPU"}]}"#
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: directory.appendingPathComponent("history.json"))
        let history = TranscriptHistory(directory: directory)
        let record = history.record(id: UUID(uuidString: "552EBF3C-12F3-47E0-B36C-30A77DA2AEEC")!)
        XCTAssertEqual(record?.text, "Next week")
        XCTAssertNil(record?.interruptions)
    }

    func testTheRecoveryCheckpointKeepsTheWordsThroughAKill() async throws {
        let store = AudioRecoveryStore(directory: directory)
        let id = UUID()
        let writer = try store.begin(id: id, engine: "test", source: .app)
        writer.append([Float](repeating: 0.1, count: 16_000))
        try store.checkpoint(id, text: "words before the alarm")
        XCTAssertEqual(try store.records().first?.state, .recording, "a checkpoint does not end the recording")
        try await writer.finish()
        // Killed while held: the next launch.
        let relaunched = AudioRecoveryStore(directory: directory)
        try relaunched.recoverAbandoned()
        let record = try XCTUnwrap(try relaunched.records().first)
        XCTAssertEqual(record.state, .failed)
        XCTAssertEqual(record.text, "words before the alarm")
        XCTAssertEqual(record.message, AudioRecoveryStore.closedWithTextMessage)
    }

    func testAKillWithNoSavedWordsSaysSo() async throws {
        let store = AudioRecoveryStore(directory: directory)
        let id = UUID()
        let writer = try store.begin(id: id, engine: "test", source: .keyboard)
        writer.append([Float](repeating: 0.1, count: 16_000))
        try await writer.finish()
        let relaunched = AudioRecoveryStore(directory: directory)
        try relaunched.recoverAbandoned()
        XCTAssertEqual(try relaunched.records().first?.message, AudioRecoveryStore.closedMessage)
    }
}

final class RecordingJournalTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testEventsFromBothProcessesReadBackInTimeOrder() {
        let app = RecordingJournal(directory: directory, process: "app")
        let keyboard = RecordingJournal(directory: directory, process: "keyboard")
        let id = UUID()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        app.log("recordingStarted", recording: id, ["origin": "app"], at: t0)
        keyboard.log("statusSeen", recording: id, ["phase": "recording"], at: t0 + 0.5)
        app.log("recordingHeld", recording: id, ["cause": "default", "audio": "475.0"], at: t0 + 475)
        app.flush(); keyboard.flush()
        let events = app.events()
        XCTAssertEqual(events.map(\.name), ["recordingStarted", "statusSeen", "recordingHeld"])
        XCTAssertEqual(events.map(\.p), ["app", "keyboard", "app"])
        XCTAssertEqual(events[2].r, String(id.uuidString.prefix(8)))
        XCTAssertEqual(events[2].f["cause"], "default")
        XCTAssertEqual(events[2].date.timeIntervalSince1970, t0.timeIntervalSince1970 + 475, accuracy: 0.001)
        XCTAssertEqual(app.events(since: t0 + 1).map(\.name), ["recordingHeld"])
    }

    func testTheFileStaysUnderItsCapAndKeepsTheNewestWholeLines() throws {
        let journal = RecordingJournal(directory: directory, process: "app")
        let padding = String(repeating: "x", count: 400)
        let now = Date()
        for index in 0..<3_000 {
            journal.log("tick", ["n": String(index), "pad": padding], at: now)
        }
        journal.flush()
        let size = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("app.jsonl").path)[.size] as? Int ?? 0
        XCTAssertLessThanOrEqual(size, RecordingJournal.maxBytes)
        let events = journal.events()
        XCTAssertEqual(events.last?.f["n"], "2999")
        XCTAssertGreaterThan(events.count, 1_000)
        // Every line still decodes: the cut is on a line boundary.
        let lines = try String(contentsOf: directory.appendingPathComponent("app.jsonl"), encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, events.count)
    }

    func testOldLinesGoAtTheNextTrim() {
        let journal = RecordingJournal(directory: directory, process: "app")
        let now = Date()
        journal.log("old", at: now - RecordingJournal.retention - 3_600)
        let padding = String(repeating: "x", count: 400)
        for index in 0..<2_600 { journal.log("new", ["n": String(index), "pad": padding], at: now) }
        journal.flush()
        XCTAssertFalse(journal.events().contains { $0.name == "old" })
    }

    func testExportIsOneFileInTimeOrder() throws {
        let app = RecordingJournal(directory: directory, process: "app")
        let keyboard = RecordingJournal(directory: directory, process: "keyboard")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        keyboard.log("b", at: t0 + 1)
        app.log("a", at: t0)
        app.flush(); keyboard.flush()
        let out = directory.appendingPathComponent("export.txt")
        try app.exportFile(to: out)
        let names = try String(contentsOf: out, encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(JournalEvent.self, from: Data($0.utf8)).name }
        XCTAssertEqual(names, ["a", "b"])
    }

    func testErrorsAreLoggedByDomainAndCodeOnly() {
        let error = NSError(domain: NSOSStatusErrorDomain, code: 561_017_449,
                            userInfo: [NSLocalizedDescriptionKey: "something with the user's words in it"])
        XCTAssertEqual(JournalFormat.error(error), "NSOSStatusErrorDomain#561017449")
        XCTAssertEqual(JournalFormat.words("one two  three\nfour"), "4")
    }
}
