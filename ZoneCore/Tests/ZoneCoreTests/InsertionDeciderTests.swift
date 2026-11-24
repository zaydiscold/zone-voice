// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class InsertionDeciderTests: XCTestCase {
    private let id = UUID()

    private func result(generation: Int = 2, session: String? = "S1") -> DictationResult {
        DictationResult(requestID: id, generation: generation, text: "hello", audioSeconds: 1, createdAt: Date(), inputSession: session)
    }

    private func request(session: String? = "S1") -> DictationRequest {
        DictationRequest(id: id, generation: 2, createdAt: Date(), inputSession: session, contextBefore: nil)
    }

    func testAlreadyConsumedIsIgnored() {
        var ledger = InsertionLedger()
        ledger.consumedResultID = id
        let decision = InsertionDecider.decide(result: result(), request: request(), ledger: ledger, currentInputSession: "S1", ownsRequest: true)
        XCTAssertEqual(decision, .ignore(reason: "already inserted"))
    }

    func testCancelledGenerationIsIgnoredEvenWhenEverythingElseMatches() {
        var ledger = InsertionLedger()
        ledger.droppedGeneration = 2
        let decision = InsertionDecider.decide(result: result(generation: 2), request: request(), ledger: ledger, currentInputSession: "S1", ownsRequest: true)
        XCTAssertEqual(decision, .ignore(reason: "cancelled"))
    }

    func testNewerGenerationSurvivesAnOlderCancel() {
        var ledger = InsertionLedger()
        ledger.droppedGeneration = 1
        let decision = InsertionDecider.decide(result: result(generation: 2), request: request(), ledger: ledger, currentInputSession: "S1", ownsRequest: true)
        XCTAssertEqual(decision, .insertNow)
    }

    func testClaimedButNotConsumedOffersRecovery() {
        var ledger = InsertionLedger()
        ledger.claimedResultID = id
        ledger.claimedAt = Date()
        let decision = InsertionDecider.decide(result: result(), request: request(), ledger: ledger, currentInputSession: "S1", ownsRequest: true)
        XCTAssertEqual(decision, .offerRecovery)
    }

    func testSameInputSessionInsertsNow() {
        let decision = InsertionDecider.decide(result: result(), request: request(), ledger: InsertionLedger(), currentInputSession: "S1", ownsRequest: true)
        XCTAssertEqual(decision, .insertNow)
    }

    func testDifferentInputSessionOffersInsert() {
        let decision = InsertionDecider.decide(result: result(session: "S1"), request: request(session: "S1"), ledger: InsertionLedger(), currentInputSession: "S2", ownsRequest: true)
        XCTAssertEqual(decision, .offerInsert(reason: "field changed"))
    }

    func testUnknownSessionsInsertOnlyWhenThisKeyboardMadeTheRequest() {
        let owned = InsertionDecider.decide(result: result(session: nil), request: request(session: nil), ledger: InsertionLedger(), currentInputSession: nil, ownsRequest: true)
        XCTAssertEqual(owned, .insertNow)
        let foreign = InsertionDecider.decide(result: result(session: nil), request: request(session: nil), ledger: InsertionLedger(), currentInputSession: nil, ownsRequest: false)
        XCTAssertEqual(foreign, .offerInsert(reason: "came from another keyboard session"))
    }

    func testAnotherInstanceNeverInsertsOnItsOwnEvenWhenSessionsMatch() {
        let decision = InsertionDecider.decide(result: result(session: "S1"), request: request(session: "S1"), ledger: InsertionLedger(), currentInputSession: "S1", ownsRequest: false)
        XCTAssertEqual(decision, .offerInsert(reason: "field changed"))
    }

    func testWithoutSessionIdsTheContextMustStillMatch() {
        let req = DictationRequest(id: id, generation: 2, createdAt: Date(), inputSession: nil, contextBefore: "Hi there")
        let same = InsertionDecider.decide(result: result(session: nil), request: req, ledger: InsertionLedger(), currentInputSession: nil, currentContextBefore: "Well. Hi there", ownsRequest: true)
        XCTAssertEqual(same, .insertNow)
        let moved = InsertionDecider.decide(result: result(session: nil), request: req, ledger: InsertionLedger(), currentInputSession: nil, currentContextBefore: "Something else", ownsRequest: true)
        XCTAssertEqual(moved, .offerInsert(reason: "field changed"))
    }

    func testOriginallyEmptyAnonymousFieldMustStillBeEmpty() {
        func decision(_ current: String?, original: String? = "") -> InsertionDecision {
            let blank = DictationRequest(id: id, generation: 2, createdAt: Date(), inputSession: nil, contextBefore: original)
            return InsertionDecider.decide(result: result(session: nil), request: blank, ledger: InsertionLedger(),
                                           currentInputSession: nil, currentContextBefore: current, ownsRequest: true)
        }
        XCTAssertEqual(decision("a different draft"), .offerInsert(reason: "field changed"))
        XCTAssertEqual(decision(" "), .offerInsert(reason: "field changed"))
        XCTAssertEqual(decision("a different draft", original: nil), .offerInsert(reason: "field changed"))
        XCTAssertEqual(decision(""), .insertNow)
        XCTAssertEqual(decision(nil), .insertNow)
    }

    func testOldResultsAreIgnored() {
        let old = DictationResult(requestID: id, generation: 2, text: "hello", audioSeconds: 1, createdAt: Date().addingTimeInterval(-20 * 60), inputSession: "S1")
        let decision = InsertionDecider.decide(result: old, request: request(), ledger: InsertionLedger(), currentInputSession: "S1", ownsRequest: true)
        XCTAssertEqual(decision, .ignore(reason: "stale"))
    }

    func testColdPathReturnOffersInsert() {
        // Keyboard was dismissed, app recorded, user came back: new controller, new input session.
        let decision = InsertionDecider.decide(result: result(session: "S1"), request: request(session: "S1"), ledger: InsertionLedger(), currentInputSession: "S9", ownsRequest: false)
        XCTAssertEqual(decision, .offerInsert(reason: "field changed"))
    }

    func testEmptyTextIsIgnored() {
        let empty = DictationResult(requestID: id, generation: 2, text: "   ", audioSeconds: 1, createdAt: Date(), inputSession: "S1")
        let decision = InsertionDecider.decide(result: empty, request: request(), ledger: InsertionLedger(), currentInputSession: "S1", ownsRequest: true)
        XCTAssertEqual(decision, .ignore(reason: "no speech"))
    }
}
