// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class ShortcutActionQueueTests: XCTestCase {
    @MainActor
    func testEarlyStopWaitsForSuspendedStartAndReturnsAfterStopping() async throws {
        let queue = ShortcutActionQueue()
        var events: [String] = []
        var resumeStart: CheckedContinuation<Void, Never>?
        let preparing = expectation(description: "start suspended in preparation")
        let start = queue.enqueue {
            events.append("preparing")
            await withCheckedContinuation { continuation in
                resumeStart = continuation
                preparing.fulfill()
            }
            events.append("recording")
        }
        await fulfillment(of: [preparing], timeout: 2)
        // Both requests are accepted while the first is suspended, with no sleeps or
        // assumptions about which task the executor happens to schedule next.
        let stop = queue.enqueue { events.append("stopped") }
        let next = queue.enqueue { events.append("next recording") }
        resumeStart?.resume()
        try await start.value
        try await stop.value
        try await next.value
        XCTAssertEqual(events, ["preparing", "recording", "stopped", "next recording"])
    }

    @MainActor
    func testFailedStartDoesNotBlockNextAcceptedAction() async throws {
        enum Failure: Error { case denied }
        let queue = ShortcutActionQueue()
        let start = queue.enqueue { throw Failure.denied }
        var ran = false
        let next = queue.enqueue { ran = true }
        do { try await start.value; XCTFail("start should fail") } catch {}
        try await next.value
        XCTAssertTrue(ran)
    }
    @MainActor
    func testFailedStartThenOffDoesNotStartAnotherRecording() async throws {
        enum Failure: Error { case denied }
        let queue = ShortcutActionQueue()
        var state = NoteActionPolicy.State.idle
        let start = queue.enqueue { throw Failure.denied }
        var action: NoteActionPolicy.Action?
        let stop = queue.enqueue {
            action = NoteActionPolicy.action(for: state, desiredState: false)
            if action == .start { state = .recordingNote }
        }
        _ = await start.result
        try await stop.value
        XCTAssertEqual(action, .ignore)
    }
    @MainActor
    func testDelayedForegroundRecoveryCannotReplayOnAfterOff() async throws {
        enum Failure: Error { case denied }
        let queue = ShortcutActionQueue()
        let onToken = queue.acceptRequest()
        let start = queue.enqueue { throw Failure.denied }
        _ = await start.result
        _ = queue.acceptRequest() // Off is accepted even if the app is already idle.
        try await queue.enqueue {}.value
        var restarted = false
        try await queue.enqueueRecovery(for: onToken) { restarted = true }.value
        XCTAssertFalse(restarted)
    }

    @MainActor
    func testRecoveryRechecksSupersessionAfterPreparationAwait() async throws {
        let queue = ShortcutActionQueue()
        let onToken = queue.acceptRequest()
        let preparing = expectation(description: "recovery preparing")
        var resume: CheckedContinuation<Void, Never>?
        var restarted = false
        let recovery = queue.enqueueRecovery(for: onToken) {
            await withCheckedContinuation { resume = $0; preparing.fulfill() }
            guard queue.isCurrent(onToken) else { return }
            restarted = true
        }
        await fulfillment(of: [preparing], timeout: 2)
        _ = queue.acceptRequest()
        let off = queue.enqueue {}
        resume?.resume()
        try await recovery.value
        try await off.value
        XCTAssertFalse(restarted)
    }

}
