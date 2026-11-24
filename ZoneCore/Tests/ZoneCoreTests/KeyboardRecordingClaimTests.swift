// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class KeyboardRecordingClaimTests: XCTestCase {
    func testConcurrentOwnersOfOneTapHaveOneWinner() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let winners = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<32 { group.addTask { KeyboardTapOwner.take(id, directory: dir) } }
            var total = 0
            for await won in group where won { total += 1 }
            return total
        }
        XCTAssertEqual(winners, 1)
        XCTAssertFalse(KeyboardTapOwner.take(id, directory: dir))
        XCTAssertTrue(KeyboardTapOwner.take(UUID(), directory: dir))
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAppLockMovesUnderApplicationSupportAndRespectsALiveOldOwner() throws {
        let group = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: group) }
        let locks = MicrophoneOwnership(group: group)
        let oldFile = group.appendingPathComponent("microphone.lock")
        let newFile = group.appendingPathComponent("Library/Application Support/microphone.lock")
        var errors: [Int32] = []
        var first = locks.reserveForApp { _, code in errors.append(code) }
        XCTAssertNotNil(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newFile.path))
        XCTAssertNil(locks.reserveForApp { _, code in errors.append(code) })
        XCTAssertFalse(locks.reserveForKeyboard(recordingID: UUID(), report: { _, code in XCTFail("Unexpected microphone lock error \(code)") }), "Both processes must yield at the canonical lock")
        first = nil

        var previous = MicrophoneLease(at: oldFile)
        XCTAssertNotNil(previous)
        XCTAssertNil(locks.reserveForApp { _, code in errors.append(code) })
        previous = nil
        let app = try XCTUnwrap(locks.reserveForApp { _, code in errors.append(code) })
        withExtendedLifetime(app) {
            XCTAssertTrue(app.holdsPeerLock)
            XCTAssertNil(MicrophoneLease(at: oldFile))
            XCTAssertNil(MicrophoneLease(at: newFile))
        }
        XCTAssertTrue(errors.isEmpty, "Actual contention must not be reported as a file error")
    }

    func testLockPathErrorPreservesErrnoAndDoesNotClaimOwnership() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: path) }
        let locks = MicrophoneOwnership(file: path)
        var errors: [Int32] = []
        let app = try XCTUnwrap(locks.reserveForApp { operation, code in
            XCTAssertEqual(operation, "open")
            errors.append(code)
        })
        XCTAssertFalse(app.holdsPeerLock)
        XCTAssertEqual(errors, [EISDIR])
        let id = UUID()
        XCTAssertTrue(locks.reserveForKeyboard(recordingID: id) { operation, code in
            XCTAssertEqual(operation, "open")
            errors.append(code)
        })
        locks.keyboardStopped(recordingID: id)
        XCTAssertEqual(errors, [EISDIR, EISDIR])
    }

    func testFinishingAnOlderRecordingCannotReleaseANewerLeaseAfterTheClaimVanished() throws {
        let suite = "lease-by-id-" + UUID().uuidString
        let host = UserDefaultsSharedStore(suiteName: suite)
        let peer = UserDefaultsSharedStore(suiteName: suite)
        defer {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            if let path = host.microphoneOwnership.file { try? FileManager.default.removeItem(at: path) }
        }
        let first = UUID(), next = UUID()
        let lease = host.microphoneOwnership
        XCTAssertTrue(lease.reserveForKeyboard(recordingID: first, report: { _, code in XCTFail("Unexpected microphone lock error \(code)") }))
        host.keyboardRecordingClaim = claim(heartbeatAge: 0, id: first)
        peer.keyboardRecordingClaim = nil
        XCTAssertNil(host.keyboardRecordingClaim)
        XCTAssertNil(peer.microphoneOwnership.reserveForApp { _, _ in XCTFail("Unexpected file error") })
        lease.keyboardStopped(recordingID: first)
        XCTAssertTrue(lease.reserveForKeyboard(recordingID: next, report: { _, code in XCTFail("Unexpected microphone lock error \(code)") }))
        lease.keyboardStopped(recordingID: first)
        XCTAssertNil(peer.microphoneOwnership.reserveForApp { _, _ in XCTFail("Unexpected file error") })
        lease.keyboardStopped(recordingID: next)
        XCTAssertNotNil(peer.microphoneOwnership.reserveForApp { _, _ in XCTFail("Unexpected file error") })
    }

    private func claim(heartbeatAge: TimeInterval, id: UUID = UUID()) -> KeyboardRecordingClaim {
        KeyboardRecordingClaim(requestID: id, since: now.addingTimeInterval(-30), heartbeat: now.addingTimeInterval(-heartbeatAge))
    }

    func testAFreshHeartbeatIsALiveRecording() {
        XCTAssertTrue(claim(heartbeatAge: 0).isLive(now: now))
        XCTAssertTrue(claim(heartbeatAge: 1).isLive(now: now))
        XCTAssertTrue(claim(heartbeatAge: 8).isLive(now: now))
    }

    /// iOS can end a keyboard mid-recording without a word. Its claim must not block the
    /// Action Button for more than a few seconds.
    func testAQuietHeartbeatIsADeadKeyboard() {
        XCTAssertFalse(claim(heartbeatAge: 8.1).isLive(now: now))
        XCTAssertFalse(claim(heartbeatAge: 3600).isLive(now: now))
        XCTAssertEqual(KeyboardRecordingClaim.verdict(claim(heartbeatAge: 9), now: now), .stale)
    }

    func testAClockMovedBackDoesNotKeepADeadClaimAlive() {
        XCTAssertTrue(claim(heartbeatAge: -2).isLive(now: now))
        XCTAssertFalse(claim(heartbeatAge: -60).isLive(now: now))
    }

    func testAStartPressIsRefusedOnlyWhileTheKeyboardRecords() {
        let id = UUID()
        XCTAssertEqual(KeyboardRecordingClaim.verdict(nil, now: now), .clear)
        XCTAssertEqual(KeyboardRecordingClaim.verdict(claim(heartbeatAge: 1, id: id), now: now), .keyboardRecording(id))
        XCTAssertEqual(KeyboardRecordingClaim.verdict(claim(heartbeatAge: 1, id: id), now: now, forRequest: UUID()), .keyboardRecording(id))
        XCTAssertEqual(KeyboardRecordingClaim.verdict(claim(heartbeatAge: 1, id: id), now: now, forRequest: id), .clear,
                       "the keyboard's own request is never refused by its own claim")
    }

    func testTheRefusalsAreOnePlainSentenceEach() {
        for message in [KeyboardRecordingClaim.pressRefusal, KeyboardRecordingClaim.appRefusal] {
            XCTAssertEqual(message, RecordingRefusal.keyboard)
            XCTAssertEqual(message.filter { $0 == "." }.count, 1)
            XCTAssertFalse(message.contains("\u{2014}"))
        }
    }

    func testTheClaimTravelsThroughTheAppGroup() {
        let suite = "KeyboardRecordingClaimTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let keyboard = UserDefaultsSharedStore(suiteName: suite)
        let app = UserDefaultsSharedStore(suiteName: suite)
        XCTAssertNil(app.keyboardRecordingClaim)
        let written = KeyboardRecordingClaim(requestID: UUID(), since: Date(), heartbeat: Date())
        keyboard.keyboardRecordingClaim = written
        XCTAssertEqual(app.keyboardRecordingClaim?.requestID, written.requestID)
        XCTAssertEqual(app.keyboardRecordingClaim.map { KeyboardRecordingClaim.verdict($0, now: Date()) },
                       .keyboardRecording(written.requestID))
        app.keyboardRecordingClaim = nil
        XCTAssertNil(keyboard.keyboardRecordingClaim)
    }
}
