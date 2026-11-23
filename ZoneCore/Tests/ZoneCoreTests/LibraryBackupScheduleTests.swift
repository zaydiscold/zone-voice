// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class LibraryBackupScheduleTests: XCTestCase {
    /// Stands in for the app: debounced change saves, the 30 second check and Back up now,
    /// on a simulated clock, counting the writes the schedule lets through.
    private struct Harness {
        var schedule: LibraryBackupSchedule
        var signature = 7
        var writes = 0
        var failNext = false
        var now = Date(timeIntervalSinceReferenceDate: 0)
        var waitingUntil: Date?

        init(interval: TimeInterval = 0) { schedule = LibraryBackupSchedule(minimumInterval: interval) }

        mutating func attempt(manual: Bool = false) {
            switch schedule.decide(manual ? .manual : .automatic, signature: signature, now: now) {
            case .skip: return
            case .wait(let until): waitingUntil = until; return
            case .save: break
            }
            waitingUntil = nil
            schedule.started(at: now)
            let change = schedule.change
            writes += 1
            if failNext { failNext = false; schedule.failed() } else { schedule.saved(through: change, signature: signature) }
        }

        /// A burst of change notifications: every one schedules a debounced save, and each
        /// debounced save only runs if no newer change arrived before it fired.
        mutating func burst(_ count: Int, prompt: Bool = false) {
            let tokens = (0..<count).map { index in schedule.noteChange(prompt: prompt && index == count - 1) }
            for token in tokens where schedule.isLatest(token) { attempt() }
        }

        /// Advances the clock in 30 second checks, firing a deferred save when it comes due.
        mutating func pass(_ seconds: TimeInterval) {
            let end = now.addingTimeInterval(seconds)
            while now < end {
                now = min(now.addingTimeInterval(30), end)
                if let waitingUntil, waitingUntil <= now { attempt() }
                attempt()
            }
        }
    }

    func testFirstCheckAfterLaunchSaves() {
        var harness = Harness()
        XCTAssertTrue(harness.schedule.isDirty)
        harness.attempt()
        XCTAssertEqual(harness.writes, 1)
        XCTAssertFalse(harness.schedule.isDirty)
    }

    func testPeriodicCheckIsANoOpWhileClean() {
        var harness = Harness()
        harness.attempt()
        for _ in 0..<20 { harness.attempt() }
        XCTAssertEqual(harness.writes, 1, "Ten minutes of 30 second checks with no change must not write")
    }

    func testBurstOfChangesWritesOnce() {
        var harness = Harness()
        harness.attempt()
        harness.burst(12)
        XCTAssertEqual(harness.writes, 2)
        harness.attempt()
        XCTAssertEqual(harness.writes, 2, "The periodic check after the burst has nothing left to save")
    }

    func testChangedSourceFilesSaveWithoutANotification() {
        var harness = Harness()
        harness.attempt()
        harness.signature = 8 // a keyboard history write, or a meeting renamed
        harness.attempt()
        harness.attempt()
        XCTAssertEqual(harness.writes, 2)
    }

    func testFailureRetriesUntilASaveSucceeds() {
        var harness = Harness()
        harness.failNext = true
        harness.attempt()
        XCTAssertTrue(harness.schedule.lastAttemptFailed)
        XCTAssertTrue(harness.schedule.isDirty)
        harness.failNext = true
        harness.attempt()
        harness.attempt()
        XCTAssertEqual(harness.writes, 3)
        XCTAssertFalse(harness.schedule.lastAttemptFailed)
        harness.attempt()
        XCTAssertEqual(harness.writes, 3, "Retries stop once a save lands")
    }

    func testFailureAfterACleanStateStillRetries() {
        var harness = Harness()
        harness.attempt()
        harness.failNext = true
        harness.attempt(manual: true)
        harness.attempt()
        XCTAssertEqual(harness.writes, 3)
    }

    func testManualSaveAlwaysWrites() {
        var harness = Harness()
        harness.attempt()
        harness.attempt(manual: true)
        harness.attempt(manual: true)
        XCTAssertEqual(harness.writes, 3)
    }

    func testChangeDuringASaveLeavesTheScheduleDirty() {
        var schedule = LibraryBackupSchedule()
        let started = schedule.change
        schedule.noteChange() // a note saved while the backup was being written
        schedule.saved(through: started, signature: 1)
        XCTAssertTrue(schedule.isDirty)
        XCTAssertEqual(schedule.decide(.automatic, signature: 1, now: Date()), .save)
    }

    // MARK: Minimum interval

    func testChangesKeepComingAndSavesStaySpacedByTheInterval() {
        var harness = Harness(interval: 300)
        harness.attempt() // launch
        // A dictation every 20 seconds for an hour.
        for _ in 0..<180 {
            harness.burst(1)
            harness.now.addTimeInterval(20)
            if let until = harness.waitingUntil, until <= harness.now { harness.attempt() }
        }
        // 1 launch save, then at most one per 5 minutes over the hour: 12 more.
        XCTAssertLessThanOrEqual(harness.writes, 13)
        XCTAssertGreaterThanOrEqual(harness.writes, 12)
    }

    func testFirstChangeAfterAQuietPeriodSavesRightAway() {
        var harness = Harness(interval: 300)
        harness.attempt()
        harness.now.addTimeInterval(301)
        harness.burst(1)
        XCTAssertEqual(harness.writes, 2, "No wait after a quiet period beyond the debounce")
    }

    func testPendingChangeIsNeverDroppedAndSavesWhenTheIntervalEnds() {
        var harness = Harness(interval: 300)
        harness.attempt()
        harness.now.addTimeInterval(10)
        harness.burst(1)
        XCTAssertEqual(harness.writes, 1)
        XCTAssertEqual(harness.waitingUntil, Date(timeIntervalSinceReferenceDate: 300))
        harness.pass(240)
        XCTAssertEqual(harness.writes, 1, "Still inside the interval")
        harness.pass(60)
        XCTAssertEqual(harness.writes, 2, "The pending change saves once the interval ends")
        harness.pass(600)
        XCTAssertEqual(harness.writes, 2, "And nothing more while clean")
    }

    func testBackUpNowIsNeverDelayed() {
        var harness = Harness(interval: 300)
        harness.attempt()
        harness.now.addTimeInterval(5)
        harness.attempt(manual: true)
        harness.now.addTimeInterval(5)
        harness.attempt(manual: true)
        XCTAssertEqual(harness.writes, 3)
    }

    func testMeetingEndingSkipsTheInterval() {
        var harness = Harness(interval: 300)
        harness.attempt()
        harness.now.addTimeInterval(10)
        harness.burst(3, prompt: true)
        XCTAssertEqual(harness.writes, 2, "A finished meeting is backed up promptly")
        harness.now.addTimeInterval(10)
        harness.burst(1)
        XCTAssertEqual(harness.writes, 2, "Ordinary changes after it wait again")
    }

    func testFailedPromptSaveWaitsForTheIntervalBeforeRetrying() {
        var harness = Harness(interval: 300)
        harness.attempt()
        harness.now.addTimeInterval(400)
        harness.schedule.noteChange(prompt: true)
        harness.failNext = true
        harness.attempt()
        XCTAssertEqual(harness.writes, 2)
        harness.pass(270)
        XCTAssertEqual(harness.writes, 2, "A failing folder is not retried every 30 seconds")
        harness.pass(60)
        XCTAssertEqual(harness.writes, 3)
        XCTAssertFalse(harness.schedule.isDirty)
    }

    func testSignatureFollowsSizeAndModificationOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Meetings/A"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = root.appendingPathComponent("notes.json")
        let meeting = root.appendingPathComponent("Meetings/A/meeting.json")
        try Data("[]".utf8).write(to: notes)
        try Data("{}".utf8).write(to: meeting)
        let sources = [notes, root.appendingPathComponent("Meetings"), root.appendingPathComponent("History")]
        let first = LibraryBackupSignature.of(sources)
        XCTAssertEqual(first, LibraryBackupSignature.of(sources), "Reading must not change the signature")

        try Data("{\"title\":\"Renamed\"}".utf8).write(to: meeting, options: .atomic)
        let renamed = LibraryBackupSignature.of(sources)
        XCTAssertNotEqual(first, renamed)

        try FileManager.default.createDirectory(at: root.appendingPathComponent("History"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("History/history.json"))
        XCTAssertNotEqual(renamed, LibraryBackupSignature.of(sources), "A file the keyboard creates counts")
    }
}
