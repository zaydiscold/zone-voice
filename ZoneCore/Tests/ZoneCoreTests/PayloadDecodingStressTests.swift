// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// What the app and the keyboard read from each other and from disk, when it is old, new,
/// damaged or hostile: nothing crashes, nothing unrelated is reset, nothing is overwritten.
final class PayloadDecodingStressTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var directories: [URL] = []

    override func setUp() {
        super.setUp()
        suite = "test.zone.stress.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        for url in directories { try? FileManager.default.removeItem(at: url) }
        super.tearDown()
    }

    private let keys = ["zone.request", "zone.status", "zone.result", "zone.control", "zone.session", "zone.ledger",
                        "zone.keyboardPresence", "zone.level", "zone.textStyle", "zone.keyboardPreferences",
                        "zone.textStylePickedAt", "zone.dictationsInserted", "zone.defaultTextStyle", "zone.keyboardMode"]

    // MARK: Shared store

    func testGarbageInEveryKeyReadsAsNothingOrTheDefault() {
        var rng = StressRNG(seed: 0xDEC0DE)
        let store = UserDefaultsSharedStore(suiteName: suite)
        let shapes: [() -> Any] = [
            { Data((0..<Int.random(in: 0...64, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }) },
            { "not json" }, { 42 }, { -1.5 }, { true }, { ["a", "b"] }, { ["k": "v"] }, { Date() },
            { Data("{}".utf8) }, { Data("[]".utf8) }, { Data("null".utf8) }, { Data("{\"id\": 3}".utf8) },
            { Data(String(repeating: "[", count: 10_000).utf8) },
        ]
        for _ in 0..<Stress.iterations(300, heavy: 5_000) {
            for key in keys where rng.chance(0.6) { defaults.set(rng.pick(shapes)(), forKey: key) }
            _ = store.request; _ = store.status; _ = store.result; _ = store.control; _ = store.session
            _ = store.keyboardPresence; _ = store.level; _ = store.textStylePickedAt; _ = store.dictationsInserted
            XCTAssertTrue(TextStyle.allCases.contains(store.textStyle))
            XCTAssertTrue(TextStyle.allCases.contains(store.defaultTextStyle))
            XCTAssertTrue(KeyboardMode.allCases.contains(store.keyboardMode))
            _ = store.keyboardPreferences
            let ledger = store.ledger
            XCTAssertGreaterThanOrEqual(ledger.droppedGeneration, Int.min)
            _ = store.effectiveTextStyle()
        }
    }

    func testOlderPayloadsStillDecode() throws {
        let store = UserDefaultsSharedStore(suiteName: suite)
        let id = UUID().uuidString
        // Status before `paused` existed.
        defaults.set(Data("""
        {"requestID":"\(id)","generation":3,"phase":"recording","updatedAt":"2026-10-27T10:00:00Z","message":null}
        """.utf8), forKey: "zone.status")
        XCTAssertEqual(store.status?.phase, .recording)
        XCTAssertNil(store.status?.paused)
        // Preferences from the first build (no suggestions, no meter style).
        defaults.set(Data(#"{"autocorrectEnabled":false,"hapticsEnabled":false}"#.utf8), forKey: "zone.keyboardPreferences")
        XCTAssertEqual(store.keyboardPreferences, KeyboardPreferences(autocorrectEnabled: false, hapticsEnabled: false))
        // Ledger without a claim.
        defaults.set(Data(#"{"droppedGeneration":7}"#.utf8), forKey: "zone.ledger")
        XCTAssertEqual(store.ledger, InsertionLedger(droppedGeneration: 7))
        // Session without an end date.
        defaults.set(Data(#"{"isArmed":true,"modelReady":true,"heartbeat":"2026-10-27T10:00:00Z"}"#.utf8), forKey: "zone.session")
        XCTAssertEqual(store.session?.armedUntil, nil)
        XCTAssertEqual(store.session?.isArmed, true)
    }

    /// A newer build's preference value used to fail the whole record, resetting autocorrect
    /// (and every other switch) to on.
    func testOneUnreadablePreferenceDoesNotResetTheOthers() {
        let store = UserDefaultsSharedStore(suiteName: suite)
        defaults.set(Data(#"{"autocorrectEnabled":false,"hapticsEnabled":false,"showSuggestions":true,"meterStyle":"a-style-from-a-newer-build"}"#.utf8),
                     forKey: "zone.keyboardPreferences")
        XCTAssertEqual(store.keyboardPreferences,
                       KeyboardPreferences(autocorrectEnabled: false, hapticsEnabled: false, showSuggestions: true, meterStyle: .wave))
        defaults.set(Data(#"{"autocorrectEnabled":"no","hapticsEnabled":false}"#.utf8), forKey: "zone.keyboardPreferences")
        XCTAssertEqual(store.keyboardPreferences.hapticsEnabled, false)
        XCTAssertEqual(store.keyboardPreferences.autocorrectEnabled, true)
    }

    /// An unknown phase is a whole unreadable status: the keyboard sees no status rather than a
    /// wrong one. The app and keyboard ship in one bundle, so this only happens across builds.
    func testUnknownPhaseReadsAsNoStatus() {
        let store = UserDefaultsSharedStore(suiteName: suite)
        defaults.set(Data("""
        {"requestID":"\(UUID().uuidString)","generation":1,"phase":"queued","updatedAt":"2026-10-27T10:00:00Z"}
        """.utf8), forKey: "zone.status")
        XCTAssertNil(store.status)
    }

    func testHugeAndHostileValuesRoundTrip() {
        let store = UserDefaultsSharedStore(suiteName: suite)
        let context = String(repeating: "👨‍👩‍👧‍👦\u{0}\u{202E}\"\\", count: 20_000)
        let request = DictationRequest(id: UUID(), generation: .max, createdAt: Date(timeIntervalSince1970: 0),
                                       inputSession: String(repeating: "x", count: 100_000), contextBefore: context)
        store.request = request
        XCTAssertEqual(store.request, request)
        store.ledger = InsertionLedger(droppedGeneration: .min)
        XCTAssertEqual(store.ledger.droppedGeneration, .min)
        store.level = .nan
        XCTAssertTrue(store.level.isNaN)
        store.request = nil
        XCTAssertNil(store.request)
    }

    // MARK: Session and ledger edges

    /// A heartbeat ahead of the clock (the clock moved back after the app died) used to look
    /// alive until the clock caught up.
    func testFutureHeartbeatIsNotAlive() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func session(_ offset: TimeInterval) -> SessionState {
            SessionState(isArmed: true, armedUntil: nil, modelReady: true, heartbeat: now.addingTimeInterval(offset))
        }
        XCTAssertTrue(session(0).isAlive(now: now))
        XCTAssertTrue(session(-8).isAlive(now: now))
        XCTAssertFalse(session(-8.5).isAlive(now: now))
        XCTAssertTrue(session(3).isAlive(now: now), "a little ahead is jitter, not a dead app")
        XCTAssertFalse(session(3_600).isAlive(now: now))
        XCTAssertFalse(SessionState(isArmed: false, armedUntil: nil, modelReady: true, heartbeat: now).isAlive(now: now))
    }

    func testLedgerEdgesNeverInsertTwiceOrInsertCancelled() {
        var rng = StressRNG(seed: 0x1ED6E)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for _ in 0..<Stress.iterations(3_000, heavy: 50_000) {
            let id = UUID(), other = UUID()
            let generation = rng.pick([Int.min, -1, 0, 1, 2, 1_000, Int.max])
            let result = DictationResult(requestID: id, generation: generation, text: rng.pick(["", " ", "\n", "hi", "a b"]),
                                         audioSeconds: 1, createdAt: now.addingTimeInterval(Double(rng.int(-2_000...2_000))),
                                         inputSession: rng.pick([nil, "A", "B"]))
            let ledger = InsertionLedger(claimedResultID: rng.pick([nil, id, other]), claimedAt: nil,
                                         consumedResultID: rng.pick([nil, id, other]),
                                         droppedGeneration: rng.pick([Int.min, 0, 1, Int.max]))
            let request = rng.chance(0.5) ? DictationRequest(id: id, generation: generation, createdAt: now, inputSession: result.inputSession,
                                                              contextBefore: rng.pick([nil, "", "hello "])) : nil
            let decision = InsertionDecider.decide(result: result, request: request, ledger: ledger,
                                                   currentInputSession: rng.pick([nil, "A", "B"]),
                                                   currentContextBefore: rng.pick([nil, "", "hello ", "x hello "]),
                                                   ownsRequest: rng.chance(0.5), now: now)
            if ledger.consumedResultID == id { XCTAssertEqual(decision, .ignore(reason: "already inserted")) }
            else if generation <= ledger.droppedGeneration { XCTAssertEqual(decision, .ignore(reason: "cancelled")) }
            else if result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { XCTAssertEqual(decision, .ignore(reason: "no speech")) }
            if case .insertNow = decision {
                XCTAssertNotEqual(ledger.claimedResultID, id, "a claimed result is recovered, never inserted blindly")
                XCTAssertLessThanOrEqual(now.timeIntervalSince(result.createdAt), InsertionDecider.maxAge)
            }
        }
    }

    func testDictateURLParsingSurvivesHostileURLs() {
        var rng = StressRNG(seed: 0x0A11)
        let id = UUID()
        XCTAssertEqual(ZoneContract.requestID(from: ZoneContract.dictateURL(requestID: id)), id)
        XCTAssertEqual(ZoneContract.requestID(from: URL(string: "ZONE://DICTATE?request=\(id.uuidString)")!), id)
        let pieces = ["zone", "://", "dictate", "?", "request=", id.uuidString, "&", "request=x", "#", "%00", "%", "home", "http", "/", "..", " "]
        for _ in 0..<Stress.iterations(2_000, heavy: 50_000) {
            let raw = (0..<rng.int(1...8)).map { _ in rng.pick(pieces) }.joined()
            guard let url = URL(string: raw) else { continue }
            if let parsed = ZoneContract.requestID(from: url) { XCTAssertEqual(parsed, id) }
        }
    }

    // MARK: History on disk

    private func historyDirectory() -> URL {
        let url = Stress.temporaryDirectory("history")
        directories.append(url)
        return url
    }

    /// One record a build cannot read (a newer source value) used to make the whole file read as
    /// empty, and the next dictation's save replaced every record with just itself.
    func testOneUnreadableRecordNoLongerWipesTheHistory() throws {
        let directory = historyDirectory()
        let history = TranscriptHistory(directory: directory)
        let now = Date()
        for index in 0..<5 {
            history.finish(id: UUID(), text: "dictation \(index)", audioSeconds: 1, engine: "test", source: .app, now: now)
        }
        // A newer build wrote a record with a source this build does not know.
        let file = directory.appendingPathComponent("history.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var records = try XCTUnwrap(json["records"] as? [[String: Any]])
        let futureID = UUID()
        var future = records[0]
        future["id"] = futureID.uuidString
        future["source"] = "meeting"
        future["text"] = "from a newer build"
        records.insert(future, at: 0)
        json["records"] = records
        try JSONSerialization.data(withJSONObject: json).write(to: file)

        XCTAssertEqual(history.records(now: now).count, 5)
        history.finish(id: UUID(), text: "after the downgrade", audioSeconds: 1, engine: "test", source: .app, now: now)
        XCTAssertEqual(history.records(now: now).count, 6, "earlier records survive the next save")
        let raw = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(raw.contains("from a newer build"), "the unreadable record is carried through")
        // Delete removes it by id; Delete All removes everything.
        history.delete(id: futureID)
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("from a newer build"))
        history.deleteAll()
        XCTAssertEqual(history.records(now: now), [])
    }

    func testUnreadableHistoryFileIsSetAsideNotOverwritten() throws {
        let directory = historyDirectory()
        let history = TranscriptHistory(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let garbage = Data("{\"retention\": \"thirtyDays\", \"records\": [ {\"id\": tor".utf8)
        try garbage.write(to: directory.appendingPathComponent("history.json"))
        XCTAssertTrue(history.finish(id: UUID(), text: "new", audioSeconds: 1, engine: "test", source: .app))
        let aside = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("history.unreadable-") }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(aside[0])), garbage)
        XCTAssertEqual(history.records().map(\.text), ["new"])
    }

    func testRetentionAppliesToUnreadableRecords() throws {
        let directory = historyDirectory()
        let history = TranscriptHistory(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = "2020-01-01T00:00:00Z", recent = ISO8601DateFormatter().string(from: Date())
        let json = """
        {"retention":"sevenDays","records":[
          {"id":"\(UUID().uuidString)","text":"old","createdAt":"\(old)","source":"meeting"},
          {"id":"\(UUID().uuidString)","text":"recent","createdAt":"\(recent)","source":"meeting"}]}
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("history.json"))
        history.purgeExpired()
        let raw = try String(contentsOf: directory.appendingPathComponent("history.json"), encoding: .utf8)
        XCTAssertFalse(raw.contains("\"old\""))
        XCTAssertTrue(raw.contains("\"recent\""))
        XCTAssertEqual(history.retention, .sevenDays)
        history.setRetention(.off)
        XCTAssertFalse(try String(contentsOf: directory.appendingPathComponent("history.json"), encoding: .utf8).contains("recent"))
    }

    func testRandomHistoryDamageNeverCrashesOrLosesReadableRecords() throws {
        var rng = StressRNG(seed: 0x415_7041)
        for _ in 0..<Stress.iterations(30, heavy: 500) {
            let directory = historyDirectory()
            let history = TranscriptHistory(directory: directory)
            let now = Date()
            let count = rng.int(1...8)
            for index in 0..<count { history.finish(id: UUID(), text: "r\(index)", audioSeconds: 1, engine: "e", source: .keyboard, now: now) }
            let file = directory.appendingPathComponent("history.json")
            var data = try Data(contentsOf: file)
            // Flip some bytes, truncate, or append junk.
            switch rng.int(0...2) {
            case 0: for _ in 0..<rng.int(1...4) { data[rng.int(0...(data.count - 1))] = UInt8.random(in: 0...255, using: &rng) }
            case 1: data = data.prefix(rng.int(0...data.count))
            default: data.append(contentsOf: Array("garbage".utf8))
            }
            try data.write(to: file)
            let before = history.records(now: now).count
            XCTAssertLessThanOrEqual(before, count)
            XCTAssertTrue(history.finish(id: UUID(), text: "next", audioSeconds: 1, engine: "e", source: .app, now: now))
            let after = history.records(now: now)
            XCTAssertGreaterThanOrEqual(after.count, before + 1, "a readable record was lost by the next save")
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            if before == 0, data.count > 0 { XCTAssertTrue(files.contains { $0.hasPrefix("history.unreadable-") } || !after.isEmpty) }
        }
    }

    // MARK: Vocabulary on disk

    func testDamagedVocabularyIsNeverOverwritten() throws {
        let directory = historyDirectory()
        let url = directory.appendingPathComponent("words.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for content in ["{garbage", #"{"version":2,"words":["Zayd"]}"#, #"{"version":1}"#, ""] {
            try Data(content.utf8).write(to: url)
            let vocabulary = PersonalVocabulary(fileURL: url)
            XCTAssertThrowsError(try vocabulary.add(["Dahlsson"]), content)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), content, "a write must not replace what it could not read")
        }
    }
}
