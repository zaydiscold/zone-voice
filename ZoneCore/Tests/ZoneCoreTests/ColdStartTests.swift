// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// The phone's journal, November 5 to 10: in 45 of 50 taps that launched Zone, the keyboard's
/// first status for its new request was "interrupted", written by the launch itself.
final class ColdStartTests: XCTestCase {
    private let now = Date()

    private func tap(generation: Int = 3, age: TimeInterval = 0.3) -> (DictationRequest, DictationStatus) {
        let written = now.addingTimeInterval(-age)
        let request = DictationRequest(id: UUID(), generation: generation, createdAt: written, inputSession: "field", contextBefore: nil)
        let status = DictationStatus(requestID: request.id, generation: generation, phase: .requested, updatedAt: written, message: nil)
        return (request, status)
    }

    func testFreshRequestedTapIsKeptForTheLaunchToServe() {
        let (request, status) = tap()
        XCTAssertFalse(ColdStart.launchTerminalizes(status: status, request: request, ledger: .init(droppedGeneration: 2), now: now))
        // The shared store keeps dates to the whole second, and iOS has taken 5 s to launch Zone.
        let (slow, slowStatus) = tap(age: 5.9)
        XCTAssertFalse(ColdStart.launchTerminalizes(status: slowStatus, request: slow, ledger: .init(), now: now))
        let (edge, edgeStatus) = tap(age: ColdStart.requestWindow)
        XCTAssertFalse(ColdStart.launchTerminalizes(status: edgeStatus, request: edge, ledger: .init(), now: now))
    }

    func testOldRequestedTapIsTerminalized() {
        let (request, status) = tap(age: ColdStart.requestWindow + 1)
        XCTAssertTrue(ColdStart.launchTerminalizes(status: status, request: request, ledger: .init(), now: now))
        let (hours, hoursStatus) = tap(age: 3 * 3600)
        XCTAssertTrue(ColdStart.launchTerminalizes(status: hoursStatus, request: hours, ledger: .init(), now: now))
        // Written under a clock that later moved back: it cannot stay live until the clock catches up.
        let (future, futureStatus) = tap(age: -(ColdStart.requestWindow + 1))
        XCTAssertTrue(ColdStart.launchTerminalizes(status: futureStatus, request: future, ledger: .init(), now: now))
    }

    func testRequestedForAnotherOrMissingRequestIsTerminalized() {
        let (request, status) = tap()
        XCTAssertTrue(ColdStart.launchTerminalizes(status: status, request: nil, ledger: .init(), now: now))
        let (other, _) = tap()
        XCTAssertTrue(ColdStart.launchTerminalizes(status: status, request: other, ledger: .init(), now: now))
        let regenerated = DictationRequest(id: request.id, generation: request.generation + 1, createdAt: request.createdAt,
                                           inputSession: nil, contextBefore: nil)
        XCTAssertTrue(ColdStart.launchTerminalizes(status: status, request: regenerated, ledger: .init(), now: now))
    }

    func testDroppedRequestedTapIsTerminalized() {
        let (request, status) = tap(generation: 3)
        XCTAssertTrue(ColdStart.launchTerminalizes(status: status, request: request, ledger: .init(droppedGeneration: 3), now: now))
        XCTAssertTrue(ColdStart.launchTerminalizes(status: status, request: request, ledger: .init(droppedGeneration: 9), now: now))
    }

    func testAppPhasesFromADeadProcessAreTerminalizedHoweverRecent() {
        let (request, _) = tap()
        for phase in [DictationPhase.starting, .recording, .transcribing] {
            let status = DictationStatus(requestID: request.id, generation: request.generation, phase: phase, updatedAt: now, message: nil)
            XCTAssertTrue(ColdStart.launchTerminalizes(status: status, request: request, ledger: .init(), now: now), "\(phase)")
        }
    }

    func testTerminalPhasesAndNothingStoredAreLeftAlone() {
        XCTAssertFalse(ColdStart.launchTerminalizes(status: nil, request: nil, ledger: .init(), now: now))
        let (request, _) = tap()
        XCTAssertFalse(ColdStart.launchTerminalizes(status: nil, request: request, ledger: .init(), now: now))
        for phase in [DictationPhase.ready, .cancelled, .failed, .interrupted, .needsApp] {
            let status = DictationStatus(requestID: request.id, generation: request.generation, phase: phase,
                                         updatedAt: now.addingTimeInterval(-3600), message: nil)
            XCTAssertFalse(ColdStart.launchTerminalizes(status: status, request: request, ledger: .init(), now: now), "\(phase)")
        }
    }

    func testKeyboardWaitsWhileTheTapIsRecentOrZoneAnswered() {
        let (request, status) = tap(age: 2)
        XCTAssertFalse(ColdStart.keyboardGivesUp(ownedID: request.id, request: request, status: status, now: now))
        let (old, oldStatus) = tap(age: 30)
        for phase in [DictationPhase.starting, .recording, .transcribing, .ready, .failed, .cancelled, .interrupted] {
            let answered = DictationStatus(requestID: old.id, generation: old.generation, phase: phase, updatedAt: now, message: nil)
            XCTAssertFalse(ColdStart.keyboardGivesUp(ownedID: old.id, request: old, status: answered, now: now), "\(phase)")
        }
        // A newer request (another keyboard, a Shortcut) replaced this one: it is not ours to drop.
        XCTAssertFalse(ColdStart.keyboardGivesUp(ownedID: UUID(), request: old, status: oldStatus, now: now))
    }

    func testKeyboardGivesUpOnATapZoneNeverPickedUp() {
        let (request, status) = tap(age: ColdStart.requestWindow + 0.5)
        XCTAssertTrue(ColdStart.keyboardGivesUp(ownedID: request.id, request: request, status: status, now: now))
        XCTAssertTrue(ColdStart.keyboardGivesUp(ownedID: request.id, request: request, status: nil, now: now))
        let needsApp = DictationStatus(requestID: request.id, generation: request.generation, phase: .needsApp, updatedAt: now, message: nil)
        XCTAssertTrue(ColdStart.keyboardGivesUp(ownedID: request.id, request: request, status: needsApp, now: now))
        let (_, otherStatus) = tap()
        XCTAssertTrue(ColdStart.keyboardGivesUp(ownedID: request.id, request: request, status: otherStatus, now: now))
    }

    /// One tap, Zone already recording it: the keyboard's second open is not sent. Anything
    /// short of that (Zone has not answered, asked to be opened, or is on another request)
    /// still opens Zone, so a tap is never left unanswered.
    func testSecondOpenIsSkippedOnlyOnceZoneRecordsThisTap() {
        let id = UUID()
        func status(_ phase: DictationPhase, for request: UUID = id) -> DictationStatus {
            DictationStatus(requestID: request, generation: 1, phase: phase, updatedAt: Date(), message: nil)
        }
        XCTAssertFalse(ColdStart.secondOpenStillNeeded(status: status(.recording), requestID: id))
        XCTAssertFalse(ColdStart.secondOpenStillNeeded(status: status(.transcribing), requestID: id))
        for phase in [DictationPhase.requested, .starting, .needsApp, .failed, .interrupted, .cancelled] {
            XCTAssertTrue(ColdStart.secondOpenStillNeeded(status: status(phase), requestID: id), "\(phase)")
        }
        XCTAssertTrue(ColdStart.secondOpenStillNeeded(status: status(.recording, for: UUID()), requestID: id), "Another request's recording")
        XCTAssertTrue(ColdStart.secondOpenStillNeeded(status: nil, requestID: id))
        XCTAssertTrue(ColdStart.secondOpenStillNeeded(status: status(.recording), requestID: nil), "Opening Zone's home, not a tap")
    }
}
