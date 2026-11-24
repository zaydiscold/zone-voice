// by zayd/cold @ zayd.wtf

import AVFoundation
import XCTest
import ZoneCore
@testable import Zone

/// The capture engine's arming, cancellation and recovery, on a fake hardware layer so the
/// timing and the failures can be forced without a microphone.
@MainActor
final class AudioCaptureEngineTests: XCTestCase {
    func testWarmDictationInterruptsPlaybackThenReleasesBeforeRearmingStandby() async throws {
        let hardware = FakeCaptureHardware()
        let capture = AudioCaptureEngine(hardware: hardware)
        try await capture.arm()
        defer { capture.disarm() }
        XCTAssertEqual(hardware.snapshot.events, ["activate"])
        capture.startRecording(pausingMusic: true)
        await AudioHardwareQueue.drain()
        XCTAssertEqual(hardware.snapshot.events.last, "interruptPlayback")
        capture.stopRecording()
        await AudioHardwareQueue.drain()
        XCTAssertEqual(Array(hardware.snapshot.events.suffix(2)), ["deactivate", "activate"])
        XCTAssertTrue(hardware.isRunning)
    }

    func testCancelledColdPressReleasesMusicButOrdinaryStandbyAndMeetingsMix() async throws {
        let hardware = FakeCaptureHardware()
        let capture = AudioCaptureEngine(hardware: hardware)
        capture.recordOnArm { _ in }
        try await capture.arm()
        defer { capture.disarm() }
        XCTAssertEqual(hardware.snapshot.events.first, "interruptPlayback")
        capture.cancelRecordingOnArm()
        await AudioHardwareQueue.drain()
        capture.startRecording()
        capture.stopRecording()
        await AudioHardwareQueue.drain()
        XCTAssertEqual(hardware.snapshot.events, ["interruptPlayback", "deactivate", "activate"])
    }

    func testEndingStandbyWhilePlaybackReleaseIsQueuedCannotRearmTheMic() async throws {
        let hardware = FakeCaptureHardware()
        let capture = AudioCaptureEngine(hardware: hardware)
        try await capture.arm()
        capture.startRecording(pausingMusic: true)
        await AudioHardwareQueue.drain()
        AudioHardwareQueue.async { Thread.sleep(forTimeInterval: 0.05) }
        capture.stopRecording()
        capture.disarm()
        await AudioHardwareQueue.drain()
        XCTAssertFalse(hardware.isRunning)
        XCTAssertEqual(hardware.snapshot.events, ["activate", "interruptPlayback", "deactivate"])
    }

    func testColdDictationCanStillRecordWhenIOSRefusesAnInterruption() async throws {
        let hardware = FakeCaptureHardware()
        hardware.refusesMusicInterruption = true
        let capture = AudioCaptureEngine(hardware: hardware)
        capture.recordOnArm { _ in }
        try await capture.arm()
        defer { capture.disarm() }
        XCTAssertTrue(hardware.isRunning)
        XCTAssertEqual(hardware.snapshot.events, ["activate"])
        capture.cancelRecordingOnArm()
        await AudioHardwareQueue.drain()
        XCTAssertEqual(hardware.snapshot.events, ["activate", "deactivate", "activate"])
    }

    func testConcurrentArmsShareOneActivationOffTheMainThread() async throws {
        let hardware = FakeCaptureHardware()
        hardware.activationDelay = 0.2
        let capture = AudioCaptureEngine(hardware: hardware)
        defer { capture.disarm() }
        let first = Task { try await capture.arm() }
        let second = Task { try await capture.arm() }
        try await waitUntil { hardware.activationStarted }
        // The main actor runs while the session activates: arming no longer blocks it.
        XCTAssertTrue(capture.isArming)
        XCTAssertEqual(capture.state, .stopped)
        try await first.value
        try await second.value
        try await capture.arm() // Already armed: nothing to do.
        XCTAssertEqual(capture.state, .armed)
        XCTAssertFalse(capture.isArming)
        XCTAssertEqual(hardware.snapshot.activations, 1)
        XCTAssertEqual(hardware.snapshot.starts, 1)
        XCTAssertTrue(hardware.snapshot.sessionActive)
        XCTAssertFalse(hardware.activatedOnMainThread)
    }

    func testDisarmDuringArmWinsAndLeavesTheSessionInactive() async throws {
        let hardware = FakeCaptureHardware()
        hardware.activationDelay = 0.3
        let capture = AudioCaptureEngine(hardware: hardware)
        let arm = Task { try await capture.arm() }
        try await waitUntil { hardware.activationStarted }
        capture.disarm()
        // Synchronous: by the time disarm returns, the arm's activation has been undone.
        XCTAssertFalse(hardware.snapshot.sessionActive)
        XCTAssertFalse(hardware.isRunning)
        XCTAssertEqual(capture.state, .stopped)
        do { try await arm.value; XCTFail("A disarmed arm must not report success") }
        catch is CancellationError {}
        XCTAssertEqual(capture.state, .stopped)
        await AudioHardwareQueue.drain()
        XCTAssertFalse(hardware.snapshot.sessionActive, "Nothing may reactivate the session after the disarm")
        XCTAssertEqual(hardware.snapshot.events.last, "deactivate")
    }

    func testDisarmBeforeTheArmReachesTheHardwareActivatesNothing() async throws {
        let hardware = FakeCaptureHardware()
        let capture = AudioCaptureEngine(hardware: hardware)
        // Earlier audio work holds the queue, so the arm is still waiting when Off arrives.
        AudioHardwareQueue.async { Thread.sleep(forTimeInterval: 0.2) }
        let arm = Task { try await capture.arm() }
        try await waitUntil { capture.isArming }
        capture.disarm()
        do { try await arm.value; XCTFail("A disarmed arm must not report success") }
        catch is CancellationError {}
        await AudioHardwareQueue.drain()
        XCTAssertEqual(hardware.snapshot.activations, 0)
        XCTAssertFalse(hardware.snapshot.sessionActive)
        XCTAssertEqual(capture.state, .stopped)
        // And the engine arms normally afterwards.
        try await capture.arm()
        XCTAssertEqual(capture.state, .armed)
        capture.disarm()
    }

    func testInterruptionDuringArmFailsItAndReleasesTheSession() async throws {
        let hardware = FakeCaptureHardware()
        hardware.activationDelay = 0.2
        let capture = AudioCaptureEngine(hardware: hardware)
        defer { capture.disarm() }
        var interruptions = 0
        capture.onInterruption = { _ in interruptions += 1 }
        let arm = Task { try await capture.arm() }
        try await waitUntil { hardware.activationStarted }
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
                                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        do { try await arm.value; XCTFail("An interrupted arm must fail") }
        catch CaptureError.interrupted {}
        await AudioHardwareQueue.drain()
        XCTAssertEqual(capture.state, .stopped)
        XCTAssertFalse(hardware.snapshot.sessionActive)
        XCTAssertFalse(hardware.isRunning)
        XCTAssertEqual(interruptions, 0, "Nothing was armed, so there is no recording to hold")
    }

    func testTapExceptionIsCaughtAndArmRetriesOnAFreshEngine() async throws {
        let hardware = FakeCaptureHardware()
        hardware.installExceptions = 1
        let capture = AudioCaptureEngine(hardware: hardware)
        defer { capture.disarm() }
        try await capture.arm()
        XCTAssertEqual(capture.state, .armed)
        XCTAssertEqual(hardware.snapshot.replacements, 1)
        XCTAssertEqual(hardware.snapshot.installs, 2)
        XCTAssertTrue(hardware.isRunning)
        // Samples flow through the tap installed on the fresh engine.
        let received = expectation(description: "samples after recovery")
        let once = Locked(false)
        capture.onSamples = { samples in
            guard !samples.isEmpty, once.withLock({ sent in defer { sent = true }; return !sent }) else { return }
            received.fulfill()
        }
        capture.startRecording()
        hardware.deliverBuffer()
        await fulfillment(of: [received], timeout: 2)
    }

    /// In the car, `engine.start()` threw -10868 on a used engine until Zone was relaunched.
    func testStartErrorRetriesOnAFreshEngine() async throws {
        let hardware = FakeCaptureHardware()
        hardware.startErrors = 1
        let capture = AudioCaptureEngine(hardware: hardware)
        defer { capture.disarm() }
        try await capture.arm()
        XCTAssertEqual(capture.state, .armed)
        XCTAssertEqual(hardware.snapshot.replacements, 1)
        XCTAssertEqual(hardware.snapshot.starts, 2)
        XCTAssertTrue(hardware.isRunning)
    }

    func testRepeatedStartErrorFailsTheArmAndReleasesTheSession() async throws {
        let hardware = FakeCaptureHardware()
        hardware.startErrors = 2
        let capture = AudioCaptureEngine(hardware: hardware)
        do {
            try await capture.arm()
            XCTFail("Two engines that cannot start must fail the arm")
        } catch let error as NSError {
            XCTAssertEqual(error.code, -10868)
        }
        XCTAssertEqual(capture.state, .stopped)
        XCTAssertEqual(hardware.snapshot.replacements, 1)
        XCTAssertFalse(hardware.snapshot.sessionActive)
        XCTAssertFalse(hardware.isRunning)
        try await capture.arm()
        XCTAssertEqual(capture.state, .armed)
        capture.disarm()
    }

    func testRepeatedTapExceptionFailsTheArmWithoutCrashingAndReleasesTheSession() async throws {
        let hardware = FakeCaptureHardware()
        hardware.installExceptions = 2
        let capture = AudioCaptureEngine(hardware: hardware)
        do {
            try await capture.arm()
            XCTFail("Two raising engines must fail the arm")
        } catch let error as AudioEngineException {
            XCTAssertEqual(error.step, "installTap")
            XCTAssertEqual(error.name, FakeCaptureHardware.exceptionName)
            XCTAssertTrue(error.reason.contains("Tap()"))
        }
        XCTAssertEqual(capture.state, .stopped)
        XCTAssertEqual(hardware.snapshot.replacements, 1)
        XCTAssertFalse(hardware.snapshot.sessionActive)
        XCTAssertFalse(hardware.isRunning)
        // A later arm, with the engine behaving again, works.
        try await capture.arm()
        XCTAssertEqual(capture.state, .armed)
        capture.disarm()
        XCTAssertFalse(hardware.snapshot.sessionActive)
    }

    func testConfigurationChangeRestartSurvivesAnExceptionOnAFreshEngine() async throws {
        let hardware = FakeCaptureHardware()
        let capture = AudioCaptureEngine(hardware: hardware)
        defer { capture.disarm() }
        var interruptions: [String] = []
        capture.onInterruption = { if case .began(let reason) = $0 { interruptions.append(reason) } }
        try await capture.arm()
        hardware.simulateRouteChange(installExceptions: 1)
        try await waitUntil { hardware.isRunning && hardware.snapshot.replacements == 1 }
        XCTAssertEqual(capture.state, .armed)
        XCTAssertEqual(interruptions, [])
        // Two raising engines in a row: the restart gives up and reports it, without crashing.
        hardware.simulateRouteChange(installExceptions: 2)
        try await waitUntil { capture.state == .stopped }
        XCTAssertEqual(interruptions, ["restartFailed"])
        XCTAssertEqual(hardware.snapshot.replacements, 2)
    }

    /// A standby whose input stops and three restarts bring nothing back reports it, so the
    /// coordinator stands the session down instead of staying "armed" with no capture. It used to
    /// stop silently unless a recording was under way. Real time: about four stall windows.
    func testAStalledStandbyReportsAnInterruption() async throws {
        let hardware = FakeCaptureHardware()
        let capture = AudioCaptureEngine(hardware: hardware)
        defer { capture.disarm() }
        var reasons: [String] = []
        capture.onInterruption = { interruption in
            if case .began(let reason) = interruption { reasons.append(reason) }
        }
        try await capture.arm()
        XCTAssertEqual(capture.state, .armed)
        // The fake delivers no buffers unless asked: the input has stalled.
        try await waitUntil(timeout: 30) { !reasons.isEmpty }
        XCTAssertEqual(reasons, ["inputStalled"])
        XCTAssertEqual(capture.state, .stopped)
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Records what the capture engine asked of the hardware. Called on `AudioHardwareQueue`,
/// read from the test on the main actor, so everything is behind one lock.
final class FakeCaptureHardware: CaptureHardware, @unchecked Sendable {
    static let exceptionName = "com.apple.coreaudio.avfaudio"

    struct Snapshot {
        var activations = 0
        var starts = 0
        var installs = 0
        var replacements = 0
        var sessionActive = false
        var running = false
        var events: [String] = []
    }

    private let state = Locked(Snapshot())
    private let settings = Locked((delay: TimeInterval(0), exceptions: 0, started: false, onMain: false))
    private let failingStarts = Locked(0)
    var refusesMusicInterruption = false
    /// How many `start` calls throw -10868 before one succeeds.
    var startErrors: Int {
        get { failingStarts.withLock { $0 } }
        set { failingStarts.withLock { $0 = newValue } }
    }
    private let tap = Locked<AVAudioNodeTapBlock?>(nil)
    private let callback = Locked<(@Sendable () -> Void)?>(nil)
    private let format: AVAudioFormat
    init(sampleRate: Double = 48_000) {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    }

    var snapshot: Snapshot { state.withLock { $0 } }
    var activationDelay: TimeInterval {
        get { settings.withLock { $0.delay } }
        set { settings.withLock { $0.delay = newValue } }
    }
    /// How many `installTap` calls raise before one succeeds.
    var installExceptions: Int {
        get { settings.withLock { $0.exceptions } }
        set { settings.withLock { $0.exceptions = newValue } }
    }
    var activationStarted: Bool { settings.withLock { $0.started } }
    var activatedOnMainThread: Bool { settings.withLock { $0.onMain } }

    var onConfigurationChange: (@Sendable () -> Void)? {
        get { callback.withLock { $0 } }
        set { callback.withLock { $0 = newValue } }
    }

    func activateSession(mixing: Bool) throws {
        if !mixing, refusesMusicInterruption { throw NSError(domain: NSOSStatusErrorDomain, code: -1) }
        let delay = settings.withLock { value -> TimeInterval in
            value.started = true
            value.onMain = Thread.isMainThread
            return value.delay
        }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        state.withLock {
            $0.activations += 1
            $0.sessionActive = true
            $0.events.append(mixing ? "activate" : "interruptPlayback")
        }
    }

    func deactivateSession() throws {
        state.withLock {
            $0.sessionActive = false
            $0.events.append("deactivate")
        }
    }

    func inputFormat() -> AVAudioFormat { format }

    func installTap(bufferSize: AVAudioFrameCount, block: @escaping AVAudioNodeTapBlock) {
        state.withLock { $0.installs += 1 }
        let raises = settings.withLock { value -> Bool in
            guard value.exceptions > 0 else { return false }
            value.exceptions -= 1
            return true
        }
        if raises {
            // What AVAudioEngineGraph::InstallTapOnNode raised in the 2026-11-10 crash.
            NSException(name: NSExceptionName(Self.exceptionName),
                        reason: "required condition is false: nullptr == Tap()", userInfo: nil).raise()
        }
        tap.withLock { $0 = block }
    }

    func removeTap() { tap.withLock { $0 = nil } }
    func prepare() {}

    var deliverFirstBufferOnStart = false
    func start() throws {
        state.withLock { $0.starts += 1 }
        let fails = failingStarts.withLock { left -> Bool in
            guard left > 0 else { return false }
            left -= 1
            return true
        }
        if fails { throw NSError(domain: "com.apple.coreaudio.avfaudio", code: -10868) }
        state.withLock { $0.running = true }
        if deliverFirstBufferOnStart { deliverBuffer(value: 0.25, synchronous: true) }
    }

    func stop() { state.withLock { $0.running = false } }
    var isRunning: Bool { state.withLock { $0.running } }

    func replaceEngine() {
        tap.withLock { $0 = nil }
        state.withLock {
            $0.replacements += 1
            $0.running = false
            $0.events.append("replaceEngine")
        }
    }

    func routeChanged() {}

    /// iOS stops the engine on a route change, then posts the configuration change.
    func simulateRouteChange(installExceptions: Int) {
        self.installExceptions = installExceptions
        state.withLock { $0.running = false }
        onConfigurationChange?()
    }

    /// One 2048-frame buffer of a quiet tone through the installed tap.
    func deliverBuffer(value: Float? = nil, synchronous: Bool = false) {
        guard let block = tap.withLock({ $0 }),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048) else { return }
        buffer.frameLength = 2048
        for index in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][index] = value ?? (0.1 * sin(Float(index) * 0.05))
        }
        if synchronous { block(buffer, AVAudioTime(hostTime: 0)) }
        else { AudioHardwareQueue.async { block(buffer, AVAudioTime(hostTime: 0)) } }
    }
}
