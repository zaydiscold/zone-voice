// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// Privacy policy: what the user said or typed leaves the App Group store once it is used.
final class PayloadCleanupTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func seeded(id: UUID = UUID(), at time: Date? = nil) -> (InMemorySharedStore, UUID) {
        let store = InMemorySharedStore()
        let created = time ?? t0
        store.request = DictationRequest(id: id, generation: 1, createdAt: created, inputSession: "s", contextBefore: "Hello there ")
        store.result = DictationResult(requestID: id, generation: 1, text: "meet at noon", audioSeconds: 2, createdAt: created, inputSession: "s")
        return (store, id)
    }

    func testInsertOrDismissClearsTextAndContextButKeepsTheRequestAndLedger() {
        let (store, id) = seeded()
        store.ledger = InsertionLedger(consumedResultID: id)
        store.clearPayloads(for: id)
        XCTAssertNil(store.result)
        XCTAssertEqual(store.request?.id, id)
        XCTAssertNil(store.request?.contextBefore)
        XCTAssertEqual(store.ledger.consumedResultID, id, "replay prevention survives")
    }

    func testAnotherRequestsPayloadIsLeftAlone() {
        let (store, _) = seeded()
        store.clearPayloads(for: UUID())
        XCTAssertNotNil(store.result)
        XCTAssertEqual(store.request?.contextBefore, "Hello there ")
    }

    func testAFreshUnconsumedResultSurvivesThePurge() {
        // The cold path offers it on return; it must still be there.
        let (store, _) = seeded()
        store.purgeStalePayloads(now: t0 + 60)
        XCTAssertNotNil(store.result)
        XCTAssertEqual(store.request?.contextBefore, "Hello there ")
    }

    func testThePurgeClearsWhatACrashLeftAfterConsumption() {
        let (store, id) = seeded()
        store.ledger = InsertionLedger(consumedResultID: id)
        store.purgeStalePayloads(now: t0 + 60)
        XCTAssertNil(store.result)
        XCTAssertNil(store.request?.contextBefore)
    }

    func testThePurgeClearsAnythingPastTheOfferWindow() {
        let (store, _) = seeded()
        store.purgeStalePayloads(now: t0 + InsertionDecider.maxAge + 1)
        XCTAssertNil(store.result)
        XCTAssertNil(store.request?.contextBefore)
    }
}
