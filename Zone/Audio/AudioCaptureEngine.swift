// by zayd/cold @ zayd.wtf

import AVFoundation
import Foundation
import UIKit
import ZoneCore

enum CaptureError: LocalizedError {
    case noInputAvailable
    case converterUnavailable
    /// A call, Siri or another app took the microphone while Zone was still arming.
    case interrupted

    var errorDescription: String? {
        switch self {
        case .noInputAvailable: return "No microphone input is available."
        case .converterUnavailable: return "The microphone format cannot be converted for recognition."
        case .interrupted: return "Something else took the microphone. Try again when it is free."
        }
    }
}

/// Owns the microphone for the app.
///
/// Three states. `stopped`: nothing active. `armed`: the audio session is active and the
/// engine runs with a tap installed, but every buffer is discarded; this is what keeps the
/// process alive in the background under `UIBackgroundModes: audio`, and it is the only reason
/// the keyboard's warm path can start a recording without opening the app. `recording`: the
/// same tap now forwards 16 kHz mono Float32 samples to `onSamples`.
///
/// Arming must happen in the foreground: iOS refuses to activate a recording session from the
/// background. Once armed, start/stop are flag flips and work from anywhere.
///
/// `state` lives on the main actor. Everything that reaches the audio daemons (session
/// activation, the engine graph) runs on `AudioHardwareQueue`, so the main thread never waits
/// on it except in `disarm()`, which must leave the session inactive before it returns.
@MainActor
final class AudioCaptureEngine {
    enum State: Equatable {
        case stopped
        case armed
        case recording
    }

    enum Interruption {
        /// iOS took the microphone, or the engine stopped and could not be restarted. `reason`
        /// is for the recording log: iOS's interruption reason, "restartFailed" or "inputStalled".
        case began(reason: String)
        case ended(shouldResume: Bool)
        case mediaServicesReset
    }

    private(set) var state: State = .stopped
    /// True while an `arm()` is under way: `state` is still `stopped`, but the session may be
    /// activating on the hardware queue.
    var isArming: Bool { pendingArm != nil }
    /// Current input level, 0...1, updated on the main thread about 20 times a second while recording.
    private(set) var level: Float = 0

    /// Receives converted samples on the audio queue. Set before `startRecording()`.
    var onSamples: (([Float]) -> Void)? {
        didSet { shared.withLock { $0.sink = onSamples } }
    }
    var onInterruption: ((Interruption) -> Void)?
    /// Main-thread level updates, about ten a second while recording.
    var onLevel: ((Float) -> Void)?
    /// Fires on the main thread every ~3 s while armed and every ~1 s while recording.
    var onHeartbeat: ((Date) -> Void)?

    /// Touched only on `AudioHardwareQueue`.
    nonisolated let hardware: CaptureHardware
    private var observers: [NSObjectProtocol] = []

    /// Bumped by every arm, disarm and interruption. An arm whose generation is no longer
    /// current was superseded: it must not mark the engine armed, and its hardware work undoes
    /// itself. `hardwareGeneration` mirrors it for the hardware queue.
    private var generation: UInt64 = 0
    nonisolated private let hardwareGeneration = Locked<UInt64>(0)
    private var pendingArm: (generation: UInt64, task: Task<Void, Error>)?
    /// Why the pending arm was superseded, when that was not a disarm.
    private var armSupersededBy: Error?
    /// Hardware queue only: true from a successful arm until the engine is torn down, so a
    /// configuration change restarts only an engine that is meant to run.
    nonisolated(unsafe) private var engineWanted = false

    // Scalars crossing the audio/main boundary need synchronization too. Snapshot only;
    // conversion, signal processing and sink callbacks must run outside this lock.
    private struct SharedWithAudioThread {
        var recording = false
        var lastBufferUptime: TimeInterval = 0
        /// Buffers the tap has delivered, so the stall watch can tell real audio from its own
        /// reset of `lastBufferUptime`.
        var buffersDelivered: UInt64 = 0
        var sink: (([Float]) -> Void)?
        var converter: AVAudioConverter?
    }
    private let shared = Locked(SharedWithAudioThread())
    #if targetEnvironment(simulator)
    /// Simulator only. With `ZONE_SIM_CLIP=1` in the launch environment the microphone's samples
    /// are replaced by the bundled test clip, played once from the start of each recording and
    /// followed by silence, so the listening and insertion states can be driven on a Mac whose
    /// microphone feeds the simulator nothing. `ZONE_SIM_CLIP=/path/to/clip.wav` plays that 16 kHz
    /// WAV instead (long-dictation tests). Compiled out of device builds.
    private let simulatorClip = Locked<(samples: [Float], cursor: Int)?>(
        ProcessInfo.processInfo.environment["ZONE_SIM_CLIP"].flatMap { value in
            (try? value == "1" ? TestClip.samples() : TestClip.samples(from: URL(fileURLWithPath: value))).map { ($0, 0) }
        })
    #endif
    nonisolated(unsafe) private var lastHeartbeat: TimeInterval = 0
    private var stallWatch: Task<Void, Never>?
    private var stallRestarts = 0
    /// `buffersDelivered` when the stall watch last restarted the engine.
    private var buffersAtStallRestart: UInt64 = 0
    nonisolated(unsafe) private var lastLevelPost: TimeInterval = 0
    nonisolated(unsafe) private var levelPeak: Float = 0
    nonisolated(unsafe) private var levelScale = AdaptiveLevelScale()

    nonisolated private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    init(hardware: CaptureHardware = LiveCaptureHardware()) {
        self.hardware = hardware
        registerObservers()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: Lifecycle

    /// Activates the session and starts the engine in the discarding state. Foreground only.
    ///
    /// The hardware work runs on `AudioHardwareQueue`; `state` becomes `armed` on the main
    /// actor before this returns. Calls made while an arm is under way share it. A `disarm()`
    /// meanwhile wins: this throws `CancellationError` and the session ends inactive. An
    /// interruption meanwhile throws `CaptureError.interrupted`.
    func arm() async throws {
        guard state == .stopped else { return }
        if let pendingArm { return try await pendingArm.task.value }
        let generation = advanceGeneration()
        armSupersededBy = nil
        let appState = Self.appStateName()
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            defer { if self.pendingArm?.generation == generation { self.pendingArm = nil } }
            do {
                try await AudioHardwareQueue.run { try self.armHardware(generation: generation, appState: appState) }
            } catch {
                if generation != self.generation, let reason = self.armSupersededBy { throw reason }
                throw error
            }
            guard generation == self.generation, self.state == .stopped else {
                throw self.armSupersededBy ?? CancellationError()
            }
            self.state = .armed
            self.startStallWatch()
        }
        pendingArm = (generation, task)
        try await task.value
    }

    func startRecording() {
        guard state == .armed else { return }
        stallRestarts = 0
        shared.withLock { $0.recording = true }
        #if targetEnvironment(simulator)
        simulatorClip.withLock { $0?.cursor = 0 }
        #endif
        state = .recording
    }

    func stopRecording() {
        guard state == .recording else { return }
        shared.withLock { $0.recording = false }
        state = .armed
        level = 0
    }

    /// Stops the engine and deactivates the session. Safe to call in any state.
    ///
    /// Synchronous on purpose: End session and a recording shortcut returning rely on the
    /// session being inactive when this returns (iOS ends an AudioRecordingIntent's process if
    /// it returns with active audio and no Live Activity). An arm under way on the hardware
    /// queue finishes first and is then undone; that is the one case where this waits.
    func disarm() {
        stallWatch?.cancel()
        stallWatch = nil
        _ = advanceGeneration()
        pendingArm = nil
        shared.withLock {
            $0.recording = false
            $0.converter = nil
        }
        state = .stopped
        level = 0
        AudioHardwareQueue.sync {
            teardownEngine()
            try? hardware.deactivateSession()
        }
    }

    private func advanceGeneration() -> UInt64 {
        generation &+= 1
        let current = generation
        hardwareGeneration.withLock { $0 = current }
        return current
    }

    /// An interruption or a media server reset during an arm: the arm throws `reason`, and the
    /// hardware it may already have started is released behind it.
    private func cancelPendingArm(_ reason: Error) {
        guard pendingArm != nil else { return }
        _ = advanceGeneration()
        armSupersededBy = reason
        pendingArm = nil
        AudioHardwareQueue.async { [self] in
            teardownEngine()
            try? hardware.deactivateSession()
        }
    }

    // MARK: Hardware queue

    nonisolated private func isCurrent(_ generation: UInt64) -> Bool {
        hardwareGeneration.withLock { $0 } == generation
    }

    nonisolated private func armHardware(generation: UInt64, appState: String) throws {
        guard isCurrent(generation) else { throw CancellationError() }
        do {
            try hardware.activateSession()
        } catch {
            Journal.log("micArmFailed", ["error": JournalFormat.error(error), "step": "setActive", "appState": appState])
            throw error
        }
        do {
            try startEngine(arming: true, appState: appState)
        } catch {
            if !(error is AudioEngineException) {
                Journal.log("micArmFailed", ["error": JournalFormat.error(error), "step": "engineStart", "appState": appState])
            }
            try? hardware.deactivateSession()
            throw error
        }
        shared.withLock { $0.lastBufferUptime = ProcessInfo.processInfo.systemUptime }
        engineWanted = true
        // A disarm or an interruption landed while this ran. Its own teardown may have run
        // before this block (it was queued first), so undo the work here as well.
        guard isCurrent(generation) else {
            teardownEngine()
            try? hardware.deactivateSession()
            throw CancellationError()
        }
    }

    /// Installs the tap and starts the engine. An Objective-C exception from the engine (the
    /// 2026-11-10 crash raised in installTap after 3.5 hours of route and category changes)
    /// means its graph is stale: build a fresh engine and try once more.
    nonisolated private func startEngine(arming: Bool, appState: String) throws {
        do {
            try installTapAndStart(arming: arming)
        } catch let exception as AudioEngineException {
            let event = arming ? "micArmFailed" : "micRestartFailed"
            ZoneLog.audio.error("engine raised \(exception.name, privacy: .public) in \(exception.step, privacy: .public): \(exception.reason, privacy: .public); retrying on a fresh engine")
            Journal.log(event, ["step": exception.step, "exception": exception.name, "reason": exception.reason,
                                "recovery": "freshEngine", "appState": appState])
            hardware.replaceEngine()
            do {
                try installTapAndStart(arming: arming)
            } catch let again as AudioEngineException {
                Journal.log(event, ["step": again.step, "exception": again.name, "reason": again.reason,
                                    "recovery": "failed", "appState": appState])
                teardownEngine()
                throw again
            }
            Journal.log("micRecovered", ["step": exception.step, "appState": appState])
        } catch let error where Self.freshEngineMayHelp(error) {
            // The phone's log, November 5 to 10: an engine that last ran on the phone's own
            // microphone failed to start on the car's route (-10868) on 15 of 23 arms and kept
            // failing until Zone was relaunched, where a new engine started on the same route
            // seconds later. A used engine keeps the old route's format, so start a new one.
            let event = arming ? "micArmFailed" : "micRestartFailed"
            ZoneLog.audio.error("engine start failed: \(error.localizedDescription, privacy: .public); retrying on a fresh engine")
            Journal.log(event, ["error": JournalFormat.error(error), "step": "engineStart",
                                "recovery": "freshEngine", "appState": appState])
            hardware.replaceEngine()
            do {
                try installTapAndStart(arming: arming)
            } catch {
                teardownEngine()
                throw error
            }
            Journal.log("micRecovered", ["step": "engineStart", "appState": appState])
        }
    }

    /// Zone's own refusals (no input yet, no converter) and a cancelled arm are not the
    /// engine's fault; everything else the engine throws on start is worth one new engine.
    nonisolated private static func freshEngineMayHelp(_ error: Error) -> Bool {
        !(error is CaptureError) && !(error is CancellationError)
    }

    nonisolated private func installTapAndStart(arming: Bool) throws {
        let hardware = self.hardware
        // The hardware format may have changed; a tap installed for the old format can raise.
        try AudioEngineException.catching("removeTap") { hardware.removeTap() }
        let format = try AudioEngineException.catching("inputFormat") { hardware.inputFormat() }
        // Mid-switch (AirPods connecting, CarPlay) the input can report 0 Hz for a moment, and
        // installing a tap with that format raises.
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInputAvailable }
        if arming {
            let built = AVAudioConverter(from: format, to: Self.targetFormat)
            shared.withLock { $0.converter = built }
            guard built != nil else { throw CaptureError.converterUnavailable }
        } else {
            // convert() rebuilds its converter from each buffer's actual format.
            shared.withLock { $0.converter = nil }
        }
        try AudioEngineException.catching("installTap") {
            hardware.installTap(bufferSize: 2048) { [weak self] buffer, _ in
                self?.process(buffer)
            }
        }
        try AudioEngineException.catching("prepare") { hardware.prepare() }
        do {
            try AudioEngineException.catching("start") { try hardware.start() }
        } catch let error where !(error is AudioEngineException) {
            try? AudioEngineException.catching("removeTap") { hardware.removeTap() }
            throw error
        }
    }

    /// Removes the tap and stops the engine. Never raises out.
    nonisolated private func teardownEngine() {
        engineWanted = false
        let hardware = self.hardware
        try? AudioEngineException.catching("removeTap") { hardware.removeTap() }
        if hardware.isRunning {
            try? AudioEngineException.catching("stop") { hardware.stop() }
        }
    }

    // MARK: Audio thread

    nonisolated private func process(_ buffer: AVAudioPCMBuffer) {
        let now = Date().timeIntervalSinceReferenceDate
        let (recording, sink) = shared.withLock { box in
            box.lastBufferUptime = ProcessInfo.processInfo.systemUptime
            box.buffersDelivered &+= 1
            return (box.recording, box.sink)
        }

        let heartbeatInterval: TimeInterval = recording ? 1 : 3
        if now - lastHeartbeat >= heartbeatInterval {
            lastHeartbeat = now
            let stamp = Date()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.state != .stopped else { return }
                    self.onHeartbeat?(stamp)
                }
            }
        }

        guard recording, let sink else { return }
        guard let converted = convert(buffer) else { return }
        let samples = substituteClipIfRequested(converted)

        // Every buffer counts toward the next post: the loudest one since the last post wins,
        // so a syllable between posts is never skipped.
        levelPeak = max(levelPeak, Self.rootMeanSquare(samples))
        if now - lastLevelPost >= 0.05 {
            let elapsed = min(now - lastLevelPost, 0.5)
            lastLevelPost = now
            let decibels = 20 * log10(max(levelPeak, 1e-6))
            levelPeak = 0
            let mapped = levelScale.map(decibels: decibels, elapsed: elapsed)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.state == .recording else { return }
                    self.level = mapped
                    self.onLevel?(mapped)
                }
            }
        }
        sink(samples)
    }

    /// On a device this returns the microphone samples unchanged.
    nonisolated private func substituteClipIfRequested(_ samples: [Float]) -> [Float] {
        #if targetEnvironment(simulator)
        return simulatorClip.withLock { clip in
            guard var feed = clip else { return samples }
            let end = min(feed.cursor + samples.count, feed.samples.count)
            var out = Array(feed.samples[feed.cursor..<end])
            feed.cursor = end
            if out.count < samples.count {
                out += [Float](repeating: 0, count: samples.count - out.count)
            }
            clip = feed
            return out
        }
        #else
        return samples
        #endif
    }

    nonisolated private func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let currentConverter = converterMatching(buffer.format) else { return nil }
        let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else {
            return nil
        }
        var consumed = false
        var conversionError: NSError?
        let status = currentConverter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil, let channel = output.floatChannelData else {
            return nil
        }
        let count = Int(output.frameLength)
        guard count > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: channel[0], count: count))
    }

    /// The hardware format can change under us (route change, call). Rebuild the converter when it does.
    nonisolated private func converterMatching(_ format: AVAudioFormat) -> AVAudioConverter? {
        shared.withLock { box in
            if let existing = box.converter, existing.inputFormat == format {
                return existing
            }
            let fresh = AVAudioConverter(from: format, to: Self.targetFormat)
            box.converter = fresh
            return fresh
        }
    }

    nonisolated private static func rootMeanSquare(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return (sum / Float(samples.count)).squareRoot()
    }

    // MARK: System notifications

    private func registerObservers() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.handleInterruption(note) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMediaServicesReset() }
        })
        // Follows the engine when a recovery replaces it.
        hardware.onConfigurationChange = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleConfigurationChange() }
            }
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            let reasonRaw = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            let reason = reasonRaw.flatMap(AVAudioSession.InterruptionReason.init(rawValue:)).map(Self.name) ?? "none"
            Journal.log("interruptionBegan", ["reason": reason, "mic": String(describing: state), "arming": String(isArming),
                                              "engineRunning": String(hardware.isRunning), "appState": Self.appStateName()])
            cancelPendingArm(CaptureError.interrupted)
            guard state != .stopped else { return }
            stopForInterruption()
            onInterruption?(.began(reason: reason))
        case .ended:
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            Journal.log("interruptionEnded", ["shouldResume": String(options.contains(.shouldResume)),
                                              "mic": String(describing: state), "appState": Self.appStateName()])
            onInterruption?(.ended(shouldResume: options.contains(.shouldResume)))
        @unknown default:
            break
        }
    }

    /// The microphone is gone until something arms it again; the recording side decides whether
    /// that is a hold or the end of a standby.
    private func stopForInterruption() {
        stallWatch?.cancel()
        stallWatch = nil
        _ = advanceGeneration()
        shared.withLock { $0.recording = false }
        state = .stopped
        level = 0
        // iOS already took the session; stopping the engine need not hold up the main thread.
        AudioHardwareQueue.async { [self] in teardownEngine() }
    }

    private func handleMediaServicesReset() {
        Journal.log("mediaServicesReset", ["mic": String(describing: state), "arming": String(isArming),
                                           "appState": Self.appStateName()])
        stallWatch?.cancel()
        stallWatch = nil
        cancelPendingArm(CaptureError.interrupted)
        // Every engine built before the media server restarted is dead; the next arm builds on
        // a fresh one.
        AudioHardwareQueue.async { [self] in
            engineWanted = false
            hardware.replaceEngine()
        }
        guard state != .stopped else { return }
        _ = advanceGeneration()
        shared.withLock { $0.recording = false }
        state = .stopped
        level = 0
        shared.withLock { $0.converter = nil }
        onInterruption?(.mediaServicesReset)
    }

    /// A route or format change stops the engine; restart it so an armed session stays armed.
    private func handleConfigurationChange() {
        ZoneLog.audio.info("engine configuration change; state=\(String(describing: self.state), privacy: .public) arming=\(self.isArming)")
        restartEngine(stoppingFirst: false)
    }

    /// Restarts the engine on the hardware queue if it is meant to run and has stopped. Also
    /// re-applies the car's input preference, which needs no running engine.
    private func restartEngine(stoppingFirst: Bool) {
        let generation = self.generation
        let appState = Self.appStateName()
        AudioHardwareQueue.async { [self] in
            hardware.routeChanged()
            guard engineWanted, isCurrent(generation) else { return }
            if stoppingFirst, hardware.isRunning {
                let hardware = self.hardware
                try? AudioEngineException.catching("stop") { hardware.stop() }
            }
            guard !hardware.isRunning else { return }
            do {
                try startEngine(arming: false, appState: appState)
                shared.withLock { $0.lastBufferUptime = ProcessInfo.processInfo.systemUptime }
            } catch CaptureError.noInputAvailable {
                ZoneLog.audio.info("input format not ready after route change; retrying")
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120)) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.generation == generation, self.state != .stopped else { return }
                        self.handleConfigurationChange()
                    }
                }
            } catch {
                ZoneLog.audio.error("engine restart failed: \(error.localizedDescription, privacy: .public)")
                if !(error is AudioEngineException) {
                    Journal.log("micRestartFailed", ["error": JournalFormat.error(error), "appState": appState])
                }
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.generation == generation, self.state != .stopped else { return }
                        self.stopForInterruption()
                        self.onInterruption?(.began(reason: "restartFailed"))
                    }
                }
            }
        }
    }

    // MARK: Stall watchdog

    /// The tap delivers a buffer every ~43 ms while the engine runs, armed or recording. When
    /// buffers stop with no notification (seen with route changes), a recording would sit on
    /// "Listening" hearing nothing: restart the engine, and after three restarts that bring
    /// nothing back, hand the recording to the interruption path so it is held, not lost.
    private func startStallWatch() {
        stallWatch?.cancel()
        stallWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.state != .stopped else { return }
                let (last, delivered) = self.shared.withLock { ($0.lastBufferUptime, $0.buffersDelivered) }
                let age = ProcessInfo.processInfo.systemUptime - last
                guard InterruptionPolicy.inputStalled(lastBufferAge: age) else {
                    // Recovered only when audio arrived after the restart. The restart resets the
                    // clock itself, so a young age alone was read as recovery one poll later, the
                    // count went back to zero, and a dead input restarted every two seconds
                    // forever instead of reaching the interruption path.
                    if self.stallRestarts > 0, delivered != self.buffersAtStallRestart {
                        Journal.log("inputRecovered", ["restarts": String(self.stallRestarts)])
                        self.stallRestarts = 0
                    }
                    continue
                }
                self.stallRestarts += 1
                Journal.log("inputStalled", ["seconds": JournalFormat.seconds(age), "mic": String(describing: self.state),
                                             "engineRunning": String(self.hardware.isRunning), "attempt": String(self.stallRestarts),
                                             "appState": Self.appStateName()])
                if self.stallRestarts > 3 {
                    // Standby too: stopping silently left the coordinator "armed" with no capture,
                    // so the keyboard was told to open Zone and opening Zone re-armed nothing.
                    // The interruption path stands the session down, and the next open arms again.
                    self.stopForInterruption()
                    self.onInterruption?(.began(reason: "inputStalled"))
                    return
                }
                self.buffersAtStallRestart = delivered
                self.shared.withLock { $0.lastBufferUptime = ProcessInfo.processInfo.systemUptime }
                self.restartEngine(stoppingFirst: true)
            }
        }
    }

    private static func appStateName() -> String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    private static func name(_ reason: AVAudioSession.InterruptionReason) -> String {
        switch reason {
        case .default: return "default"
        case .builtInMicMuted: return "builtInMicMuted"
        case .routeDisconnected: return "routeDisconnected"
        default: return "raw\(reason.rawValue)"
        }
    }
}


/// A tiny mutex box for state shared between the audio thread and the main actor.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
