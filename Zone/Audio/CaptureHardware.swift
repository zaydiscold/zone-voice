// by zayd/cold @ zayd.wtf

import AVFoundation
import Foundation
import ZoneCore

/// The one serial queue for calls that reach the audio daemons: activating and deactivating
/// the session, building and starting the engine graph, preparing and playing the cues.
///
/// Each of these is a synchronous XPC that can take 100 ms to over a second. On the main thread
/// they were Zone's hangs (20 reports on build 1.0.2 (2026110813), up to 1.3 s, mostly
/// `setActive(true)` and `AVAudioEngine.start()` while arming at launch). One serial queue
/// keeps their order: a deactivation queued after an activation always lands after it.
enum AudioHardwareQueue {
    static let queue = DispatchQueue(label: "wtf.zayd.zone.audio-hardware", qos: .userInitiated)
    private static let marker = DispatchSpecificKey<Bool>()
    private static let marked: Void = queue.setSpecific(key: marker, value: true)

    static var isCurrent: Bool {
        _ = marked
        return DispatchQueue.getSpecific(key: marker) == true
    }

    /// Runs `body` on the queue and waits for it. Blocks the caller for as long as the work
    /// already queued takes, so only paths that must finish before they return use it (a
    /// shortcut releasing its audio before the intent returns).
    static func sync<T>(_ body: () throws -> T) rethrows -> T {
        if isCurrent { return try body() }
        return try queue.sync(execute: body)
    }

    static func async(_ body: @escaping @Sendable () -> Void) {
        _ = marked
        queue.async(execute: body)
    }

    /// Runs `body` on the queue without blocking the caller's thread.
    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        _ = marked
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }

    /// Returns once everything queued before it has run.
    static func drain() async {
        _ = marked
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}

/// An Objective-C exception raised by an AVAudioEngine call, caught by `ZoneExceptionCatcher`.
struct AudioEngineException: LocalizedError {
    /// Which call raised: "inputFormat", "installTap", "prepare", "start", "removeTap" or "stop".
    let step: String
    let name: String
    let reason: String

    var errorDescription: String? { "The microphone could not start. Try again." }

    /// Runs `body`, turning an exception it raises into a thrown `AudioEngineException`.
    /// Swift frames inside `body` are unwound without cleanup, so keep the bodies to the single
    /// engine call: at worst the exception leaks what that call retained.
    static func catching<T>(_ step: String, _ body: () throws -> T) throws -> T {
        var result: Result<T, Error>?
        do {
            try ZoneExceptionCatcher.catchException(in: { result = Result { try body() } })
        } catch let error as NSError where error.domain == ZoneExceptionErrorDomain {
            throw AudioEngineException(step: step, name: error.userInfo[ZoneExceptionNameKey] as? String ?? "unknown",
                                       reason: error.userInfo[NSLocalizedFailureReasonErrorKey] as? String ?? "")
        }
        guard let result else { throw AudioEngineException(step: step, name: "unknown", reason: "no result") }
        return try result.get()
    }
}

/// The audio hardware the capture engine drives. Every member is called on
/// `AudioHardwareQueue` only. Tests substitute a fake so arming, cancellation and recovery can
/// be exercised without a microphone.
protocol CaptureHardware: AnyObject, Sendable {
    /// Sets the category, then activates the session.
    func activateSession(mixing: Bool) throws
    func deactivateSession() throws
    /// The input node's output format. May raise; call through `AudioEngineException.catching`.
    func inputFormat() -> AVAudioFormat
    func installTap(bufferSize: AVAudioFrameCount, block: @escaping AVAudioNodeTapBlock)
    func removeTap()
    func prepare()
    func start() throws
    func stop()
    var isRunning: Bool { get }
    /// Throws the current engine away and builds a fresh one. The way out of an engine whose
    /// input node is stuck on a stale format or tap after route and category changes.
    func replaceEngine()
    /// Logs the route after a configuration change.
    func routeChanged()
    /// Called on an arbitrary thread when the current engine reports a configuration change.
    var onConfigurationChange: (@Sendable () -> Void)? { get set }
}

/// The real thing: `AVAudioSession.sharedInstance()` and one replaceable `AVAudioEngine`.
final class LiveCaptureHardware: CaptureHardware, @unchecked Sendable {
    // Queue only, except `onConfigurationChange`, which the lock guards.
    private var engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    private let callback = Locked<(@Sendable () -> Void)?>(nil)

    var onConfigurationChange: (@Sendable () -> Void)? {
        get { callback.withLock { $0 } }
        set { callback.withLock { $0 = newValue } }
    }

    init() {
        observe(engine)
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func observe(_ engine: AVAudioEngine) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: nil) { [callback] _ in
            callback.withLock { $0 }?()
        }
    }

    func activateSession(mixing: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord, mode: .default,
            // A2DP keeps music and Zone's cues on AirPods while the phone's mic records, instead
            // of yanking playback to the speaker when a session arms.
            options: mixing ? [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP] : [.defaultToSpeaker, .allowBluetoothA2DP])
        // An armed session counts as recording, and by default iOS mutes haptics and system
        // sounds while an app records. Zone discards every armed buffer and the keys are hidden
        // while it really records, so a key tap's vibration never reaches a transcript.
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        // No input is chosen here: the system's choice is the only one that keeps a car's audio
        // in the car. See `CarAudioRoute` for what an input preference did in CarPlay.
        try session.setActive(true)
        Self.logRoute(session, after: "arm")
    }

    func deactivateSession() throws {
        let session = AVAudioSession.sharedInstance()
        do { try session.setActive(false, options: .notifyOthersOnDeactivation) }
        catch let error as NSError where error.domain == NSOSStatusErrorDomain && error.code == AVAudioSession.ErrorCode.isBusy.rawValue {
            // Apple documents that a busy deactivation stops running audio objects and
            // still deactivates. The next standby or cue must use a mixable category.
        }
        if session.category == .playAndRecord, !session.categoryOptions.contains(.mixWithOthers) {
            try session.setCategory(.ambient)
        }
    }

    func inputFormat() -> AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }

    func installTap(bufferSize: AVAudioFrameCount, block: @escaping AVAudioNodeTapBlock) {
        // The tap observes the output bus. Let the engine supply its current format instead
        // of forcing a hardware-format snapshot that can go stale during a route change.
        // convert() rebuilds its converter from each buffer's actual format when needed.
        engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: nil, block: block)
    }

    func removeTap() { engine.inputNode.removeTap(onBus: 0) }
    func prepare() { engine.prepare() }
    func start() throws { try engine.start() }
    func stop() { engine.stop() }
    var isRunning: Bool { engine.isRunning }

    func replaceEngine() {
        let old = engine
        try? AudioEngineException.catching("stop") { if old.isRunning { old.stop() } }
        engine = AVAudioEngine()
        observe(engine)
    }

    func routeChanged() {
        Self.logRoute(AVAudioSession.sharedInstance(), after: "configuration change")
    }

    /// One line per activation so the car test can show which ports iOS actually chose.
    private static func logRoute(_ session: AVAudioSession, after context: String) {
        func describe(_ ports: [AVAudioSessionPortDescription]) -> String {
            ports.map { "\($0.portType.rawValue)/\($0.channels?.count ?? 0)ch" }.joined(separator: ",")
        }
        let route = session.currentRoute
        ZoneLog.audio.info("route after \(context, privacy: .public): in=[\(describe(route.inputs), privacy: .public)] out=[\(describe(route.outputs), privacy: .public)]")
        Journal.log("route", ["after": context, "in": describe(route.inputs), "out": describe(route.outputs)])
    }
}

/// What holding the microphone does to a car's audio, from a phone's journal in a Toyota over
/// CarPlay (November 10 to 16, 2026: 18 car routes):
///
/// - Every arm came up `CarAudio/1ch` in and out: the car's one-channel call stream, so its
///   audio played in mono from the driver's side.
/// - Zone used to prefer the iPhone's microphone in a car. Set before activation it did nothing
///   (Apple applies an input preference only after activation). Re-applied after a configuration
///   change it took effect, and the route became `MicrophoneBuiltIn/1ch` in and `Speaker/2ch` out:
///   the audiobook moved to the phone's speaker, beside the microphone recording it, and the
///   engine restart failed (-10868).
///
/// Neither route keeps CarPlay's stereo media, so Zone does not hold the microphone between
/// recordings while CarPlay is connected (`DictationCoordinator.releaseMicrophoneInCarSoon`), and
/// chooses no input: during a recording the car's own microphone and call stream are the lesser
/// cost, since the phone's speaker would play the audio straight into the phone's microphone.
/// A2DP output (AirPods, a car without CarPlay) records from the iPhone's microphone and keeps
/// stereo (`MicrophoneBuiltIn/1ch`, `BluetoothA2DPOutput/2ch` in the same journal), so standby
/// stays there.
enum CarAudioRoute {
    static func isCarPlay(_ route: AVAudioSessionRouteDescription) -> Bool {
        route.outputs.contains { $0.portType == .carAudio }
    }
}
