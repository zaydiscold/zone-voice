// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class DictationModelsTests: XCTestCase {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private func roundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try encoder.encode(value)
        let back = try decoder.decode(T.self, from: data)
        XCTAssertEqual(value, back, file: file, line: line)
    }

    func testRequestRoundTrips() throws {
        let request = DictationRequest(
            id: UUID(), generation: 3, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            inputSession: "ABC", contextBefore: "Hello there.")
        XCTAssertEqual(request.schema, ZoneContract.schemaVersion)
        try roundTrip(request)
    }

    func testStatusResultControlRoundTrip() throws {
        let id = UUID()
        try roundTrip(DictationStatus(requestID: id, generation: 1, phase: .recording, updatedAt: Date(timeIntervalSince1970: 1), message: nil))
        try roundTrip(DictationResult(requestID: id, generation: 1, text: "hi", audioSeconds: 2.5, createdAt: Date(timeIntervalSince1970: 2), inputSession: nil))
        try roundTrip(DictationControl(requestID: id, generation: 1, action: .cancel, issuedAt: Date(timeIntervalSince1970: 3)))
    }

    func testSessionStateAliveness() {
        let now = Date(timeIntervalSince1970: 1_000)
        let fresh = SessionState(isArmed: true, armedUntil: now.addingTimeInterval(300), modelReady: true, heartbeat: now.addingTimeInterval(-2))
        let stale = SessionState(isArmed: true, armedUntil: now.addingTimeInterval(300), modelReady: true, heartbeat: now.addingTimeInterval(-9))
        XCTAssertTrue(fresh.isAlive(now: now))
        XCTAssertFalse(stale.isAlive(now: now))
        XCTAssertFalse(SessionState(isArmed: false, armedUntil: nil, modelReady: true, heartbeat: now).isAlive(now: now),
                       "an unarmed session is never alive for dictation purposes")
    }

    func testLedgerDefaultsAreEmpty() {
        let ledger = InsertionLedger()
        XCTAssertNil(ledger.claimedResultID)
        XCTAssertNil(ledger.consumedResultID)
        XCTAssertEqual(ledger.droppedGeneration, 0)
    }

    func testDictateURLRoundTrips() {
        let id = UUID()
        let url = ZoneContract.dictateURL(requestID: id)
        XCTAssertEqual(url.scheme, "zone")
        XCTAssertEqual(url.host, "dictate")
        XCTAssertEqual(ZoneContract.requestID(from: url), id)
        XCTAssertNil(ZoneContract.requestID(from: URL(string: "zone://settings")!))
        XCTAssertNil(ZoneContract.requestID(from: URL(string: "zone://dictate?request=nope")!))
    }

    func testDarwinNamesArePrefixed() {
        for name in DarwinName.allCases {
            XCTAssertTrue((name.cfName as String).hasPrefix("wtf.zayd.zone."), "\(name)")
        }
    }
}
