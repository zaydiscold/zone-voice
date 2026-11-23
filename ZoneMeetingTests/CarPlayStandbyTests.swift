// by zayd/cold @ zayd.wtf

import AVFoundation
import UIKit
import XCTest
import ZoneCore
@testable import Zone

/// With CarPlay connected, holding the microphone moves the car's audio off its stereo media:
/// onto the car's mono call stream, or onto the phone's speaker beside the microphone
/// (`CarAudioRoute`). So in CarPlay Zone holds the microphone only while it records, unless the
/// person turned it on there. The production coordinator and the simulator's microphone; the car
/// is `carPlayRoute`, and recognition is a stand-in.
@MainActor
final class CarPlayStandbyTests: XCTestCase {
    private var coordinator: DictationCoordinator!
    private var engine: CarSpeechEngine!
    private var suite: String!
    private var settings: AppSettings!
    private var inCar = true

    override func setUpWithError() throws {
        suite = "carplay-standby-" + UUID().uuidString
        let reviews = ReviewPrompter(store: ReviewPromptStore(suiteName: suite), appVersion: "test")
        let store = UserDefaultsSharedStore(suiteName: suite)
        settings = AppSettings(defaults: UserDefaults(suiteName: suite)!, store: store)
        settings.soundsEnabled = false
        settings.startsSessionOnOpen = false
        engine = CarSpeechEngine()
        coordinator = DictationCoordinator(settings: settings, store: store, engine: engine, reviews: reviews,
                                           requestSessionPermission: { true },
                                           recordingLiveActivity: RecordingLiveActivity())
        inCar = true
        coordinator.carPlayRoute = { [unowned self] in self.inCar }
        coordinator.carReleaseDelay = .milliseconds(50)
    }

    override func tearDownWithError() throws {
        coordinator.cancelDictation(playsSound: false)
        coordinator.endSession(reason: .user)
        coordinator = nil
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    // MARK: Helpers

    private var isRecording: Bool {
        if case .recording = coordinator.activity { return true }
        return false
    }

    /// Arms as Zone itself does in the car (the keyboard's cold request, the Action Button), or as
    /// the person does with Turn on. Zone's own arm happens out of the car's sight and the car
    /// arrives after: the simulator posts its own route changes on activation, and in the car one
    /// of those starts the release this file tests, before the test could act.
    private func standby(chosenByPerson: Bool = false) async throws {
        let car = inCar
        if !chosenByPerson { inCar = false }
        await coordinator.prepareModelAndWait()
        try await coordinator.armSession(chosenByPerson: chosenByPerson)
        try await Task.sleep(for: .milliseconds(200))
        inCar = car
        XCTAssertTrue(coordinator.isArmed)
    }

    private func dictate(_ text: String) async throws {
        engine.text = text
        _ = try await ZoneIslandIntent(.dictate).perform()
        XCTAssertTrue(isRecording, "Dictate on standby must record: \(coordinator.activity)")
        _ = try await ZoneIslandIntent(.stop).perform()
        XCTAssertEqual(coordinator.lastResult?.text, text)
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool, seconds: Double = 3) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// Long enough for any release to have happened: several times `carReleaseDelay`.
    private func settle() async throws { try await Task.sleep(for: .milliseconds(400)) }

    private func postInterruption(began: Bool) {
        var info: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: began
            ? AVAudioSession.InterruptionType.began.rawValue : AVAudioSession.InterruptionType.ended.rawValue]
        if !began { info[AVAudioSessionInterruptionOptionKey] = AVAudioSession.InterruptionOptions.shouldResume.rawValue }
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
                                        object: AVAudioSession.sharedInstance(), userInfo: info)
    }

    // MARK: After a recording

    func testInCarPlayAFinishedDictationGivesTheCarItsAudioBack() async throws {
        try await standby()
        try await dictate("Turn left at the light.")
        try await waitUntil(!coordinator.isArmed)
        XCTAssertFalse(coordinator.isArmed, "The microphone must be released after a dictation in CarPlay")
        XCTAssertEqual(coordinator.lastResult?.text, "Turn left at the light.", "Releasing keeps the result")
    }

    func testInCarPlayACancelledDictationGivesTheCarItsAudioBack() async throws {
        try await standby()
        engine.text = "Never mind."
        _ = try await ZoneIslandIntent(.dictate).perform()
        XCTAssertTrue(isRecording)
        coordinator.cancelDictation(playsSound: false)
        try await waitUntil(!coordinator.isArmed)
        XCTAssertFalse(coordinator.isArmed)
    }

    /// The release waits, so a second dictation right after the first is not refused for want
    /// of a microphone, and the release follows the last one.
    func testADictationRightAfterTheLastKeepsTheMicrophone() async throws {
        coordinator.carReleaseDelay = .milliseconds(500)
        try await standby()
        try await dictate("First.")
        XCTAssertTrue(coordinator.isArmed, "Still waiting out the delay")
        try await dictate("Second.")
        XCTAssertEqual(engine.starts, 2)
        try await waitUntil(!coordinator.isArmed)
        XCTAssertFalse(coordinator.isArmed)
    }

    func testNothingIsReleasedWhileARecordingRuns() async throws {
        try await standby()
        engine.text = "A long thought."
        _ = try await ZoneIslandIntent(.dictate).perform()
        coordinator.releaseMicrophoneInCarSoon()
        try await settle()
        XCTAssertTrue(isRecording, "A recording in progress keeps the microphone")
        XCTAssertTrue(coordinator.isArmed)
        _ = try await ZoneIslandIntent(.stop).perform()
        try await waitUntil(!coordinator.isArmed)
        XCTAssertFalse(coordinator.isArmed)
    }

    // MARK: Who turned it on

    func testStandbyThePersonTurnedOnInCarPlayStays() async throws {
        try await standby(chosenByPerson: true)
        try await dictate("Keep listening.")
        try await settle()
        XCTAssertTrue(coordinator.isArmed, "Turned on in the car, standby stays on")
    }

    func testOutsideCarPlayStandbyStaysAfterARecording() async throws {
        inCar = false
        try await standby()
        try await dictate("At home.")
        try await settle()
        XCTAssertTrue(coordinator.isArmed, "AirPods, a car without CarPlay and the phone's speaker keep standby")
    }

    // MARK: Routes and the system

    func testCarPlayConnectingWhileZoneWaitsGivesTheCarItsAudio() async throws {
        inCar = false
        try await standby(chosenByPerson: true)
        try await settle()
        XCTAssertTrue(coordinator.isArmed)
        inCar = true
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance())
        try await waitUntil(!coordinator.isArmed)
        XCTAssertFalse(coordinator.isArmed, "Getting into the car with Zone waiting must not take the car's audio")
    }

    func testOpeningZoneInCarPlayLoadsTheModelButLeavesTheMicrophone() async throws {
        settings.startsSessionOnOpen = true
        settings.hasCompletedOnboarding = true
        coordinator.scenePhaseChanged(.background)
        coordinator.scenePhaseChanged(.active)
        try await waitUntil(coordinator.modelIsReady)
        try await settle()
        XCTAssertTrue(coordinator.modelIsReady, "The model still loads, so the first recording is quick")
        XCTAssertFalse(coordinator.isArmed, "Opening Zone in CarPlay must not hold the microphone")

        inCar = false
        coordinator.scenePhaseChanged(.background)
        coordinator.scenePhaseChanged(.active)
        try await waitUntil(coordinator.isArmed)
        XCTAssertTrue(coordinator.isArmed, "Out of the car, opening Zone arms as before")
    }

    func testAnInterruptionEndingInCarPlayDoesNotTakeTheMicrophoneBack() async throws {
        try await standby()
        postInterruption(began: true)
        try await waitUntil(!coordinator.isArmed)
        XCTAssertFalse(coordinator.isArmed)
        postInterruption(began: false)
        try await settle()
        XCTAssertFalse(coordinator.isArmed, "After a call or Siri in the car, the car's audio comes back, not standby")
        XCTAssertNil(coordinator.islandSession, "That standby is over")
    }

    func testAnInterruptionEndingOutsideCarPlayStillRearms() async throws {
        inCar = false
        try await standby()
        postInterruption(began: true)
        try await waitUntil(!coordinator.isArmed)
        postInterruption(began: false)
        try await waitUntil(coordinator.isArmed)
        XCTAssertTrue(coordinator.isArmed)
    }
}

// MARK: - The stand-in recognizer

private final class CarSpeechEngine: SpeechEngine {
    let kind: EngineKind = .fluidMiniCPU
    var isReady = true
    var text = "Car."
    var starts = 0
    func assetsPresent() -> Bool { true }
    func bytesOnDisk() -> Int64 { 0 }
    func removeAssets() throws {}
    func downloadAssets(progress: @escaping @Sendable (Double, String) -> Void) async throws {}
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {}
    func setContextHints(_ text: String) {}
    func beginUtterance() throws -> UtteranceSession {
        starts += 1
        return CarUtterance(textSoFar: text)
    }
    func unload() {}
}

private final class CarUtterance: UtteranceSession {
    let textSoFar: String
    var audioSeconds: Double { 0 }
    var failure: Error? { nil }
    var availableAudioSamples: Int { 0 }
    init(textSoFar: String) { self.textSoFar = textSoFar }
    func feed(_ samples: [Float]) {}
    func finish() async throws -> String { textSoFar }
    func cancel() {}
}
