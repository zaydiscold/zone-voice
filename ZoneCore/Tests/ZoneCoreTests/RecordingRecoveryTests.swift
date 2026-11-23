// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class RecordingRecoveryTests: XCTestCase {
    func testLongRecordingReattachesFromLiveMatchingStatus() {
        let now = Date()
        let request = DictationRequest(id: UUID(), generation: 4, createdAt: now.addingTimeInterval(-3600), inputSession: "old field", contextBefore: "Hi")
        let session = SessionState(isArmed: true, armedUntil: nil, modelReady: true, heartbeat: now)
        for phase in [DictationPhase.recording, .transcribing] {
            let status = DictationStatus(requestID: request.id, generation: 4, phase: phase, updatedAt: request.createdAt, message: nil)
            XCTAssertEqual(RecordingRecovery.activeRequest(request: request, status: status, ledger: .init(), session: session, now: now), request)
        }
    }
    func testOldStatusNeedsAnOldHeartbeatAndAnUnheldRecordingToLoseContact() {
        let now = Date(), old = now.addingTimeInterval(-60)
        let live = SessionState(isArmed: true, armedUntil: nil, modelReady: true, heartbeat: now)
        let gone = SessionState(isArmed: true, armedUntil: nil, modelReady: true, heartbeat: old)
        for phase in [DictationPhase.recording, .transcribing] {
            let status = DictationStatus(requestID: UUID(), generation: 1, phase: phase, updatedAt: old, message: nil)
            XCTAssertTrue(RecordingRecovery.lostContact(status: status, session: gone, now: now))
            XCTAssertFalse(RecordingRecovery.lostContact(status: status, session: live, now: now))
            XCTAssertFalse(RecordingRecovery.lostContact(status: status, session: nil, now: old))
        }
        let held = DictationStatus(requestID: UUID(), generation: 1, phase: .recording, updatedAt: old, message: nil, paused: true)
        XCTAssertFalse(RecordingRecovery.lostContact(status: held, session: gone, now: now))
    }

    func testCancelledConsumedDeadOrUnrelatedRequestCannotReattach() {
        let now = Date()
        let request = DictationRequest(id: UUID(), generation: 4, createdAt: now, inputSession: nil, contextBefore: nil)
        let live = SessionState(isArmed: true, armedUntil: nil, modelReady: true, heartbeat: now)
        let status = DictationStatus(requestID: request.id, generation: 4, phase: .recording, updatedAt: now, message: nil)
        XCTAssertNil(RecordingRecovery.activeRequest(request: request, status: status, ledger: .init(droppedGeneration: 4), session: live, now: now))
        XCTAssertNil(RecordingRecovery.activeRequest(request: request, status: status, ledger: .init(consumedResultID: request.id), session: live, now: now))
        XCTAssertNil(RecordingRecovery.activeRequest(request: request, status: status, ledger: .init(), session: live, now: now.addingTimeInterval(9)))
        let other = DictationStatus(requestID: UUID(), generation: 4, phase: .recording, updatedAt: now, message: nil)
        XCTAssertNil(RecordingRecovery.activeRequest(request: request, status: other, ledger: .init(), session: live, now: now))
        for phase in [DictationPhase.cancelled, .ready, .failed, .interrupted, .needsApp] {
            let terminal = DictationStatus(requestID: request.id, generation: 4, phase: phase, updatedAt: now, message: nil)
            XCTAssertNil(RecordingRecovery.activeRequest(request: request, status: terminal, ledger: .init(), session: live, now: now))
        }
    }
}
