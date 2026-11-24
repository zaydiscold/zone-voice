// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class DictationMailboxTests: XCTestCase {
    private let suite = "dictation-mailbox-" + UUID().uuidString

    override func tearDownWithError() throws {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func request(_ generation: Int) -> DictationRequest {
        DictationRequest(id: UUID(), generation: generation, createdAt: Date(), inputSession: "field", contextBefore: "test")
    }

    private func final(_ request: DictationRequest) -> DictationResult {
        DictationResult(requestID: request.id, generation: request.generation, text: "fixture",
                        audioSeconds: 1, createdAt: Date(), inputSession: request.inputSession)
    }

    func testLateCompletionCannotOverwriteOrWithdrawANewerHandoff() throws {
        let slow = UserDefaultsSharedStore(suiteName: suite)
        let current = UserDefaultsSharedStore(suiteName: suite)
        let old = request(1)
        let new = DictationRequest(id: UUID(), generation: 1, createdAt: old.createdAt.addingTimeInterval(1),
                                   inputSession: "another field", contextBefore: "current")
        slow.request = old
        current.request = new
        let status = DictationStatus(requestID: new.id, generation: new.generation, phase: .ready, updatedAt: Date(), message: nil)
        current.status = status
        let text = final(new)
        XCTAssertTrue(current.publishFinal(text, for: new))
        // This is the deterministic delayed publisher schedule, including a stale clean-up.
        let staleStatus = DictationStatus(requestID: old.id, generation: old.generation, phase: .requested, updatedAt: Date(), message: nil)
        XCTAssertFalse(slow.admitRequest(old, initialStatus: staleStatus))
        slow.request = old
        XCTAssertFalse(slow.publishFinal(final(old), for: old))
        slow.status = DictationStatus(requestID: old.id, generation: 1, phase: .failed, updatedAt: Date(), message: nil)
        slow.result = final(old)
        slow.withdraw(old.id)
        slow.clearPayloads(for: old.id)
        let reopened = UserDefaultsSharedStore(suiteName: suite)
        XCTAssertEqual(reopened.request, new)
        XCTAssertEqual(reopened.status, status)
        XCTAssertEqual(reopened.result, text)
    }

    func testOnlyOneConcurrentKeyboardCanClaimAnAutomaticInsertion() throws {
        let req = request(1), result = final(req), suite = self.suite
        let before = UserDefaultsSharedStore(suiteName: suite)
        before.request = req
        XCTAssertTrue(before.publishFinal(result, for: req))
        let successes = DispatchSemaphore(value: 0)
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let store = UserDefaultsSharedStore(suiteName: suite)
            if store.claimInsertion(req.id, explicitlyRequested: false, now: Date()) {
                successes.signal()
            }
        }
        XCTAssertEqual(successes.wait(timeout: .now()), .success)
        XCTAssertEqual(successes.wait(timeout: .now()), .timedOut)
    }

    func testOlderGenerationOfTheCurrentIDCannotReplaceItsResult() throws {
        let first = request(1)
        let newer = DictationRequest(id: first.id, generation: 2, createdAt: first.createdAt,
                                     inputSession: first.inputSession, contextBefore: nil)
        let store = UserDefaultsSharedStore(suiteName: suite)
        store.request = newer
        XCTAssertTrue(store.publishFinal(final(newer), for: newer))
        XCTAssertFalse(store.publishFinal(final(first), for: first))
        store.status = DictationStatus(requestID: first.id, generation: 1, phase: .failed, updatedAt: Date(), message: nil)
        XCTAssertNil(store.status)
        XCTAssertEqual(store.result?.generation, 2)
    }

    func testTransferredAppGenerationCannotOverwriteTheKeyboardResult() {
        let app = UserDefaultsSharedStore(suiteName: suite)
        let keyboard = UserDefaultsSharedStore(suiteName: suite)
        let original = request(1)
        app.request = original
        XCTAssertTrue(keyboard.transferRequestToKeyboard(original))
        XCTAssertNil(app.request)
        app.status = DictationStatus(requestID: original.id, generation: original.generation, phase: .failed,
                                     updatedAt: Date(), message: nil)
        app.result = final(original)
        XCTAssertNil(keyboard.status)
        XCTAssertNil(keyboard.result)
        let generation = KeyboardCapture.publishedGeneration(of: original, ledger: keyboard.ledger)
        let completed = DictationRequest(id: original.id, generation: generation, createdAt: original.tappedAt,
                                         inputSession: original.inputSession, contextBefore: original.contextBefore)
        XCTAssertTrue(keyboard.publishFinal(final(completed), for: completed))
        app.result = final(original)
        XCTAssertEqual(app.result?.generation, generation)
        XCTAssertTrue(keyboard.claimInsertion(original.id, explicitlyRequested: false, now: Date()))
        keyboard.acknowledgeInsertion(original.id)
        XCTAssertEqual(app.ledger.consumedResultID, original.id)
        XCTAssertNil(app.result)
    }

    func testCompletionAfterWithdrawalCannotReviveTheSameRecording() {
        let first = UserDefaultsSharedStore(suiteName: suite)
        let late = UserDefaultsSharedStore(suiteName: suite)
        let req = request(1)
        let initial = DictationStatus(requestID: req.id, generation: req.generation, phase: .requested,
                                      updatedAt: req.tappedAt, message: nil)
        XCTAssertTrue(first.admitRequest(req, initialStatus: initial))
        first.withdraw(req.id)
        XCTAssertFalse(late.publishFinal(final(req), for: req))
        late.status = initial
        XCTAssertFalse(late.claimInsertion(req.id, explicitlyRequested: true, now: Date()))
        XCTAssertNil(first.status)
        XCTAssertNil(first.result)
        XCTAssertNil(first.request)
    }

    func testCachedOfferCannotClaimAnExpiredCancelledOrClearedResult() {
        for store: any SharedStore in [UserDefaultsSharedStore(suiteName: suite), InMemorySharedStore()] {
            let req = request(1)
            let offered = final(req)
            XCTAssertTrue(store.publishFinal(offered, for: req))
            let expired = offered.createdAt.addingTimeInterval(InsertionDecider.maxAge + 1)
            XCTAssertFalse(store.claimInsertion(req.id, explicitlyRequested: true, now: expired))
            store.updateLedger(for: req.id) { $0.droppedGeneration = req.generation }
            XCTAssertFalse(store.claimInsertion(req.id, explicitlyRequested: true, now: offered.createdAt))
            store.resetHandoff(at: expired)
            XCTAssertFalse(store.claimInsertion(req.id, explicitlyRequested: true, now: expired))
            XCTAssertNil(store.ledger.claimedResultID)
        }
    }

    func testCachedResultCannotClaimAReplacementWithTheSameRequestID() {
        for store: any SharedStore in [UserDefaultsSharedStore(suiteName: suite), InMemorySharedStore()] {
            let req = request(1)
            let first = final(req)
            let replacement = DictationResult(requestID: req.id, generation: req.generation, text: "replacement",
                                              audioSeconds: 2, createdAt: Date(), inputSession: req.inputSession)
            XCTAssertTrue(store.publishFinal(first, for: req))
            XCTAssertTrue(store.publishFinal(replacement, for: req))
            XCTAssertFalse(store.dismissResult(first))
            XCTAssertEqual(store.result, replacement)
            XCTAssertFalse(store.claimInsertion(first, explicitlyRequested: true, now: Date()))
            XCTAssertTrue(store.claimInsertion(replacement, explicitlyRequested: true, now: Date()))
            store.acknowledgeInsertion(req.id)
            XCTAssertNil(store.result)
        }
    }

    func testDeathAfterInsertBeforeAcknowledgementRequiresExplicitRecovery() throws {
        let req = request(1), result = final(req)
        let before = UserDefaultsSharedStore(suiteName: suite)
        before.request = req
        XCTAssertTrue(before.publishFinal(result, for: req))
        XCTAssertTrue(before.claimInsertion(req.id, explicitlyRequested: false, now: Date()))
        // The host accepted text here and this keyboard process ended before acknowledging.
        let after = UserDefaultsSharedStore(suiteName: suite)
        let recovered = try XCTUnwrap(after.result)
        XCTAssertEqual(InsertionDecider.decide(result: recovered, request: after.request, ledger: after.ledger,
                                               currentInputSession: req.inputSession, ownsRequest: true), .offerRecovery)
        XCTAssertFalse(after.claimInsertion(req.id, explicitlyRequested: false, now: Date()))
        XCTAssertTrue(after.claimInsertion(req.id, explicitlyRequested: true, now: Date()))
        after.acknowledgeInsertion(req.id)
        XCTAssertNil(before.result)
        XCTAssertNil(before.request?.contextBefore)
        XCTAssertEqual(before.ledger.consumedResultID, req.id)
    }

    func testClearingTheHandoffCannotBringBackAnEarlierCompletion() {
        let old = request(1), store = UserDefaultsSharedStore(suiteName: suite)
        let status = DictationStatus(requestID: old.id, generation: old.generation, phase: .requested, updatedAt: Date(), message: nil)
        XCTAssertTrue(store.admitRequest(old, initialStatus: status))
        XCTAssertEqual(store.status, status)
        store.resetHandoff(at: old.tappedAt.addingTimeInterval(1))
        XCTAssertFalse(store.admitRequest(old, initialStatus: status))
        XCTAssertFalse(store.publishFinal(final(old), for: old))
        XCTAssertNil(store.result)
        XCTAssertNil(store.request)
    }

    func testLegacyPayloadIsAdoptedAndItsPrivateTextClearedOnAcknowledgement() throws {
        let req = request(1)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(try encoder.encode(req), forKey: "zone.request")
        defaults.set(try encoder.encode(final(req)), forKey: "zone.result")
        let store = UserDefaultsSharedStore(suiteName: suite)
        XCTAssertEqual(store.result?.requestID, req.id)
        XCTAssertTrue(store.claimInsertion(req.id, explicitlyRequested: true, now: Date()))
        store.acknowledgeInsertion(req.id)
        XCTAssertNil(defaults.data(forKey: "zone.result"))
        XCTAssertNil(defaults.data(forKey: "zone.request"))
        XCTAssertNil(UserDefaultsSharedStore(suiteName: suite).result)
    }
}
