// by zayd/cold @ zayd.wtf

import AVFoundation
import UIKit
import UserNotifications
import XCTest
import ZoneCore
@testable import Zone

/// The "Zone is off" notice is a dead man's switch for standby (`StandbyStoppedNotice`): it waits
/// `lead` seconds ahead while Zone is ready, and fires only if Zone stops without being turned off.
/// The production coordinator, the simulator's microphone and its real notification center.
@MainActor
final class StandbyStoppedNoticeTests: XCTestCase {
    private var coordinator: DictationCoordinator!
    private var engine: NoticeSpeechEngine!
    private var suite: String!
    private var settings: AppSettings!

    override func setUp() async throws {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if status == .denied { throw XCTSkip("Notifications are turned off for Zone on this simulator") }
        suite = "standby-notice-" + UUID().uuidString
        let reviews = ReviewPrompter(store: ReviewPromptStore(suiteName: suite), appVersion: "test")
        let store = UserDefaultsSharedStore(suiteName: suite)
        settings = AppSettings(defaults: UserDefaults(suiteName: suite)!, store: store)
        settings.soundsEnabled = false
        settings.startsSessionOnOpen = false
        engine = NoticeSpeechEngine()
        coordinator = DictationCoordinator(settings: settings, store: store, engine: engine, reviews: reviews,
                                           requestSessionPermission: { true },
                                           recordingLiveActivity: RecordingLiveActivity())
        coordinator.carPlayRoute = { false }
    }

    override func tearDown() async throws {
        coordinator?.cancelDictation(playsSound: false)
        coordinator?.endSession(reason: .user)
        coordinator = nil
        if let suite { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }

    // MARK: Helpers

    /// Seconds until the pending notice fires, or nil when none is pending.
    private func pendingDelay() async -> TimeInterval? {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let notice = requests.first { $0.identifier == StandbyStoppedNotice.identifier }
        return (notice?.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval
    }

    private func waitForDelay(_ matches: @escaping (TimeInterval?) -> Bool, seconds: Double = 8) async throws -> TimeInterval? {
        let deadline = Date().addingTimeInterval(seconds)
        var delay = await pendingDelay()
        while !matches(delay), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            delay = await pendingDelay()
        }
        return delay
    }

    private func standby() async throws {
        await coordinator.prepareModelAndWait()
        try await coordinator.armSession()
        XCTAssertTrue(coordinator.isArmed)
    }

    private func postInterruption(began: Bool) {
        var info: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: began
            ? AVAudioSession.InterruptionType.began.rawValue : AVAudioSession.InterruptionType.ended.rawValue]
        if !began { info[AVAudioSessionInterruptionOptionKey] = AVAudioSession.InterruptionOptions.shouldResume.rawValue }
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
                                        object: AVAudioSession.sharedInstance(), userInfo: info)
    }

    // MARK: Tests

    func testReadyZoneKeepsTheNoticeAheadAndTurningOffWithdrawsIt() async throws {
        try await standby()
        let delay = try await waitForDelay { $0 != nil }
        XCTAssertEqual(delay, StandbyStoppedNotice.lead, "Ready, the notice waits one lead ahead")
        coordinator.endSession(reason: .user)
        let after = try await waitForDelay { $0 == nil }
        XCTAssertNil(after, "Turning Zone off on purpose never leaves a notice behind")
    }

    func testStandbysOwnTimeoutWithdrawsIt() async throws {
        try await standby()
        _ = try await waitForDelay { $0 != nil }
        coordinator.endSession(reason: .timeout)
        let after = try await waitForDelay { $0 == nil }
        XCTAssertNil(after, "A timeout the person chose is not Zone stopping")
    }

    /// A recording owns the microphone and has its own notice; standby's comes back after it.
    func testARecordingTakesTheNoticeAwayAndStandbyBringsItBack() async throws {
        try await standby()
        _ = try await waitForDelay { $0 != nil }
        engine.text = "While recording."
        _ = try await ZoneIslandIntent(.dictate).perform()
        let during = try await waitForDelay({ $0 == nil }, seconds: 4)
        XCTAssertNil(during, "No standby notice while recording")
        _ = try await ZoneIslandIntent(.stop).perform()
        XCTAssertTrue(coordinator.isArmed)
        let after = try await waitForDelay { $0 != nil }
        XCTAssertEqual(after, StandbyStoppedNotice.lead, "Back to waiting, the notice is back")
    }

    /// A call or Siri takes the microphone: the notice waits as long as the island holds the card,
    /// and standby coming back puts it one lead ahead again.
    func testAnInterruptionHoldsTheNoticeAndStandbyComingBackResetsIt() async throws {
        try await standby()
        _ = try await waitForDelay { $0 != nil }
        postInterruption(began: true)
        let held = try await waitForDelay { ($0 ?? 0) > StandbyStoppedNotice.lead }
        XCTAssertEqual(held, InterruptionPolicy.holdLimit + StandbyStoppedNotice.lead)
        postInterruption(began: false)
        let back = try await waitForDelay { $0 == StandbyStoppedNotice.lead }
        XCTAssertTrue(coordinator.isArmed, "iOS handed the microphone back")
        XCTAssertEqual(back, StandbyStoppedNotice.lead)
    }

    func testCarPlayGivingTheCarItsAudioWithdrawsIt() async throws {
        coordinator.carReleaseDelay = .milliseconds(50)
        try await standby()
        _ = try await waitForDelay { $0 != nil }
        coordinator.carPlayRoute = { true }
        coordinator.releaseMicrophoneInCarSoon()
        let after = try await waitForDelay { $0 == nil }
        XCTAssertFalse(coordinator.isArmed)
        XCTAssertNil(after, "Zone turning itself off for the car is on purpose")
    }

    func testKeepAliveReschedulesAtMostEveryRefresh() {
        let start = Date()
        StandbyStoppedNotice.schedule(after: StandbyStoppedNotice.lead, now: start)
        XCTAssertTrue(StandbyStoppedNotice.isScheduled)
        StandbyStoppedNotice.keepAlive(now: start.addingTimeInterval(5))
        StandbyStoppedNotice.keepAlive(now: start.addingTimeInterval(StandbyStoppedNotice.refresh + 1))
        StandbyStoppedNotice.withdraw()
        XCTAssertFalse(StandbyStoppedNotice.isScheduled)
        StandbyStoppedNotice.withdraw() // a second withdraw is a no-op
        XCTAssertFalse(StandbyStoppedNotice.isScheduled)
    }
}

// MARK: - The stand-in recognizer

private final class NoticeSpeechEngine: SpeechEngine {
    let kind: EngineKind = .fluidMiniCPU
    var isReady = true
    var text = "Notice."
    func assetsPresent() -> Bool { true }
    func bytesOnDisk() -> Int64 { 0 }
    func removeAssets() throws {}
    func downloadAssets(progress: @escaping @Sendable (Double, String) -> Void) async throws {}
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {}
    func setContextHints(_ text: String) {}
    func beginUtterance() throws -> UtteranceSession { NoticeUtterance(textSoFar: text) }
    func unload() {}
}

private final class NoticeUtterance: UtteranceSession {
    let textSoFar: String
    var audioSeconds: Double { 0 }
    var failure: Error? { nil }
    var availableAudioSamples: Int { 0 }
    init(textSoFar: String) { self.textSoFar = textSoFar }
    func feed(_ samples: [Float]) {}
    func finish() async throws -> String { textSoFar }
    func cancel() {}
}
