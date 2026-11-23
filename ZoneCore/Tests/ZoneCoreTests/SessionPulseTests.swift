// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// The session heartbeat travels in a notify state word; the defaults record is rewritten only
/// when the session itself changes or once a minute (`UserDefaultsSharedStore.session`).
final class SessionPulseTests: XCTestCase {
    private var suite: String!
    private var writer: UserDefaultsSharedStore!
    /// A second store on the same suite, as the keyboard is to the app.
    private var reader: UserDefaultsSharedStore!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        suite = "test.zone.pulse.\(UUID().uuidString)"
        writer = UserDefaultsSharedStore(suiteName: suite)
        reader = UserDefaultsSharedStore(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private var rawRecord: Data? { UserDefaults(suiteName: suite)?.data(forKey: "zone.session") }

    private func armed(_ heartbeat: Date, until: Date? = nil, ready: Bool = true) -> SessionState {
        SessionState(isArmed: true, armedUntil: until ?? start.addingTimeInterval(1_800), modelReady: ready, heartbeat: heartbeat)
    }

    func testAPulseCarriesMillisecondsAndAnUnusedNameHasNone() {
        let pulse = SessionPulse(name: suite + ".a")
        XCTAssertNil(pulse.last)
        let when = Date(timeIntervalSince1970: 1_800_000_000.123)
        XCTAssertTrue(pulse.beat(when))
        XCTAssertEqual(pulse.last!.timeIntervalSince1970, when.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(SessionPulse(name: suite + ".a").last!.timeIntervalSince1970, when.timeIntervalSince1970, accuracy: 0.001,
                       "another holder of the name reads the same state")
    }

    func testHeartbeatsAloneDoNotRewriteTheRecordButReadersSeeThem() throws {
        writer.session = armed(start)
        let first = try XCTUnwrap(rawRecord)
        for second in stride(from: 3.0, through: 57, by: 3) {
            writer.session = armed(start.addingTimeInterval(second))
        }
        XCTAssertEqual(rawRecord, first, "19 heartbeats in standby wrote nothing to defaults")
        let seen = try XCTUnwrap(reader.session)
        XCTAssertEqual(seen.heartbeat.timeIntervalSince(start), 57, accuracy: 0.001)
        XCTAssertTrue(seen.isAlive(now: start.addingTimeInterval(60)))
        XCTAssertFalse(seen.isAlive(now: start.addingTimeInterval(66)), "a pulse that stops goes stale like a record did")
    }

    func testAnyChangeApartFromTheHeartbeatIsWrittenAtOnce() throws {
        writer.session = armed(start)
        let first = try XCTUnwrap(rawRecord)
        writer.session = armed(start.addingTimeInterval(3), until: start.addingTimeInterval(3_600))
        XCTAssertNotEqual(rawRecord, first, "a longer standby is written")
        let second = try XCTUnwrap(rawRecord)
        writer.session = armed(start.addingTimeInterval(6), until: start.addingTimeInterval(3_600), ready: false)
        XCTAssertNotEqual(rawRecord, second, "the model going away is written")
        writer.session = SessionState(isArmed: false, armedUntil: nil, modelReady: false, heartbeat: start.addingTimeInterval(9))
        XCTAssertEqual(reader.session?.isArmed, false)
        XCTAssertFalse(reader.session!.isAlive(now: start.addingTimeInterval(9)))
    }

    func testSubSecondDifferencesInTheEndOfStandbyAreNotAChange() throws {
        let until = Date(timeIntervalSince1970: 1_800_001_800.4)
        writer.session = armed(start, until: until)
        let first = try XCTUnwrap(rawRecord)
        writer.session = armed(start.addingTimeInterval(3), until: until)
        XCTAssertEqual(rawRecord, first, "the record keeps whole seconds, so the same moment must compare equal")
    }

    func testTheRecordIsRefreshedOnceAMinute() throws {
        writer.session = armed(start)
        let first = try XCTUnwrap(rawRecord)
        writer.session = armed(start.addingTimeInterval(59))
        XCTAssertEqual(rawRecord, first)
        writer.session = armed(start.addingTimeInterval(UserDefaultsSharedStore.sessionRecordRefresh))
        XCTAssertNotEqual(rawRecord, first)
    }

    func testAReaderWithoutThePulseStillSeesALiveSessionWithinTheRefresh() throws {
        writer.session = armed(start)
        writer.session = armed(start.addingTimeInterval(60))
        // The defaults record alone, as an older keyboard or a failed notify registration would read it.
        let data = try XCTUnwrap(rawRecord)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(SessionState.self, from: data)
        XCTAssertEqual(record.heartbeat.timeIntervalSince(start), 60, accuracy: 1)
    }

    func testAClockThatMovedBackRewritesTheRecord() throws {
        writer.session = armed(start)
        let first = try XCTUnwrap(rawRecord)
        let earlier = start.addingTimeInterval(-3_600)
        writer.session = armed(earlier)
        XCTAssertNotEqual(rawRecord, first)
        XCTAssertEqual(reader.session!.heartbeat.timeIntervalSince(earlier), 0, accuracy: 0.001,
                       "the reader must not keep the future heartbeat")
        XCTAssertTrue(reader.session!.isAlive(now: earlier.addingTimeInterval(2)))
    }

    func testClearingTheSessionHidesThePulse() {
        writer.session = armed(start)
        writer.session = nil
        XCTAssertNil(rawRecord)
        XCTAssertNil(reader.session)
    }

    func testAStaleRecordIsNotRevivedByAnOlderPulse() throws {
        // A pulse from before the record (an earlier process) never makes the record older.
        SessionPulse(name: suite + ".session-pulse").beat(start.addingTimeInterval(-100))
        writer.session = armed(start)
        XCTAssertEqual(reader.session!.heartbeat.timeIntervalSince(start), 0, accuracy: 1)
    }
}
