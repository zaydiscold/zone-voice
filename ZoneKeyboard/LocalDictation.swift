// by zayd/cold @ zayd.wtf

import AudioToolbox
import AVFAudio
import Foundation
import Speech
import UIKit
import WebKit
import ZoneCore

/// What a dictation recorded in the keyboard reports, always with its id.
enum LocalDictationEvent: Equatable {
    /// The microphone is live; the first samples follow.
    case started
    /// Unamplified RMS from one microphone block, about 23 a second.
    case samples(rms: Float)
    case stuckMuted
    case held(Bool)
    /// The microphone is off (a stop, a limit, or iOS taking it away) and recognition began.
    case recognizing
    case savedForZone
    /// Recognized text, empty when nothing was said.
    case finished(text: String, audioSeconds: Double, module: String = "appleSpeech", doubts: [DoubtfulWord]? = nil)
    /// `beforeAudio`: the microphone never started.
    case failed(message: String, beforeAudio: Bool)
}

/// One dictation recorded and recognized inside the keyboard. `LocalDictation` is the real one;
/// tests drive `MicController` and `LocalDictationHost` with a fake.
@MainActor
protocol LocalDictating: AnyObject {
    var onEvent: ((UUID, LocalDictationEvent) -> Void)? { get set }
    /// True from `start` until the text is delivered, the dictation fails or it is cancelled.
    var isBusy: Bool { get }
    /// The web view's page is loaded, so a start has only the microphone left to open.
    var isPrepared: Bool { get }
    /// Builds the web view in `host` and loads its page. Safe to call again.
    func prepare(in host: UIView)
    func start(id: UUID, in host: UIView)
    func setPaused(_ paused: Bool)
    var startCueDuration: TimeInterval { get }
    func recoverInput()
    /// Ends the recording; `recognizing`, then `finished` or `failed`, follow.
    func stop()
    /// Removes the web view when no dictation needs it.
    func release()
    /// Drops the recording and anything recognized from it. No event follows.
    func cancel(discardAudio: Bool)
    /// A recording whose recognition failed, kept for one more try (`KeyboardCapture.retryName`).
    func keptRecording(excluding: Set<UUID>) -> UUID?
    func keptStart(id: UUID) -> Date?
    func saved(_ id: UUID, durable: Bool)
    /// Recognizes the kept recording once more: `finished`, or `failed` with the audio available in Zone.
    /// False when the file is in use or unreadable. Home can still recover it.
    @discardableResult func retryKept(id: UUID) -> Bool
}

struct KeyboardRecognitionResult: Sendable {
    let text: String
    let module: String
    var doubts: [DoubtfulWord]? = nil
    var fields: [String: String] = [:]
}

/// Owns one user-started recording. The original stays locked in the shared inbox until
/// the host acknowledges delivery. Home can import it if this process ends first.
@MainActor
final class LocalDictation: LocalDictating {
    static var systemSupports: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    static var microphoneGranted: Bool { AVAudioApplication.shared.recordPermission == .granted }

    /// How long the web view gets to deliver the microphone before the tap falls back.
    static let startLimit: Duration = .seconds(4)
    var onEvent: ((UUID, LocalDictationEvent) -> Void)?
    /// False while "Never use Apple's speech model" is on (`KeyboardPreferences.neverAppleSpeech`).
    var allowsAppleSpeech: () -> Bool = { true }

    private(set) var startCueDuration: TimeInterval = 0
    typealias ComputerRecognizer = @Sendable (URL, KeyboardVoiceRoute, TimeInterval, @Sendable () -> Void) async throws -> ComputerSpeechProvider.Transcript
    private let recognizeOnComputer: ComputerRecognizer

    init(recognizeOnComputer: @escaping ComputerRecognizer = { audio, route, timeout, submitted in
        try await ComputerSpeechProvider.recognize(audio, using: route, timeout: timeout, submitted: submitted)
    }) {
        self.recognizeOnComputer = recognizeOnComputer
    }

    private let cue = KeyboardRecordingCue()
    private let settings = KeyboardSettingReader.shared
    private var capture: WebMicrophone?
    private var file: KeyboardAudioFile?
    private var pending: [UUID: (url: URL, owner: AnyObject)] = [:]
    private var releaseRequested = false

    func saved(_ id: UUID, durable: Bool) {
        if #available(iOS 26, *) { ZoneModelSpeech.shared.recordingFinished(id) }
        guard let audio = pending.removeValue(forKey: id) else { return }
        if durable { try? FileManager.default.removeItem(at: audio.url) }
    }
    private var recording: UUID?
    private var requestedAt = Date()
    private var hasAudio = false
    private var isPaused = false
    /// The loudest block heard while not paused (`KeyboardCapture.isSilent`).
    private var peak: Float = 0
    private var startTimer: Task<Void, Never>?
    private var stopTimer: Task<Void, Never>?
    private var liveSampleSeconds: Double = 0
    private var sampleRate: Double = 0
    private var holds: Set<String> = []
    private var sessionObservers: [NSObjectProtocol] = []
    private var sessionPoll: Task<Void, Never>?
    private var otherAudio: Bool?
    private var secondaryAudio: Bool?
    private var recognition: Task<Void, Never>?

    var isBusy: Bool { recording != nil }
    var isPrepared: Bool { capture?.isLoaded ?? false }

    private static var directory: URL { KeyboardAudioFile.inbox ?? FileManager.default.temporaryDirectory }

    #if DEBUG && targetEnvironment(simulator)
    private var debugObservations: [DarwinObservation] = []
    private var playback: Task<Void, Never>?
    var fixtureForTesting: URL?
    private var fixture: URL? {
        if let fixtureForTesting { return fixtureForTesting }
        guard let file = KeyboardCapture.group?.appendingPathComponent("keyboard-worker-fixture.wav"),
              FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }

    /// The simulator supplies a known audio input at its native pace. It uses the production
    /// writer, meter, stop, recovery and delivery code without requesting microphone access.
    private func playFixture(_ source: URL, id: UUID) {
        playback = Task { [weak self] in
            guard let self else { return }
            do {
                let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatInt16, interleaved: true)
                let rate = input.processingFormat.sampleRate
                guard input.processingFormat.channelCount == 1,
                      let block = AVAudioPCMBuffer(pcmFormat: input.processingFormat,
                            frameCapacity: AVAudioFrameCount(rate / 20)) else { throw CocoaError(.fileReadCorruptFile) }
                self.handle(.started(sampleRate: rate, muted: false), id: id)
                while input.framePosition < input.length, self.recording == id {
                    try Task.checkCancellation()
                    try input.read(into: block)
                    let count = Int(block.frameLength)
                    guard count > 0, let samples = block.int16ChannelData?[0] else { break }
                    let energy = UnsafeBufferPointer(start: samples, count: count).reduce(Float.zero) {
                        let x = Float($1) / 32768
                        return $0 + x * x
                    }
                    self.handle(.samples(Data(bytes: samples, count: count * 2), rootMeanSquare: (energy / Float(count)).squareRoot()), id: id)
                    try await Task.sleep(for: .seconds(Double(count) / rate))
                }
                if !Task.isCancelled { self.playback = nil; self.handle(.ended("fixture"), id: id) }
            } catch is CancellationError { }
            catch { self.playback = nil; self.fail("The test recording could not be read.", id: id) }
        }
    }
    #endif

    private weak var recognitionHost: UIView?
    private var recordingRoute: KeyboardVoiceRoute?
    private var warmingSpeech: KeyboardWebSpeech?
    private var shouldWarmSpeech = false

    private func discardSpeechPage() {
        shouldWarmSpeech = false
        warmingSpeech?.cancel()
        warmingSpeech = nil
    }

    func prepare(in host: UIView) {
        recognitionHost = host
        #if DEBUG && targetEnvironment(simulator)
        if fixture != nil { return }
        #endif
        if let capture {
            capture.attach(to: host)
        } else {
            capture = WebMicrophone(host: host)
        }
        releaseRequested = false
        // Bring interrupted recordings from earlier releases into reach of Home.
        let old = FileManager.default.temporaryDirectory
        guard let inbox = KeyboardAudioFile.inbox else { return }
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        for item in (try? FileManager.default.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)) ?? []
            where KeyboardCapture.audioID(fromName: item.lastPathComponent) != nil {
            try? FileManager.default.moveItem(at: item, to: inbox.appendingPathComponent(item.lastPathComponent))
        }
    }

    func start(id: UUID, in host: UIView) {
        recognitionHost = host
        guard recording == nil else { return }
        prepare(in: host)
        recordingRoute = KeyboardVoiceRoute.load()
        shouldWarmSpeech = recordingRoute?.mode == .webView
        recording = id
        requestedAt = Date()
        hasAudio = false
        isPaused = false
        peak = 0
        // The microphone opens at once and the cue plays alongside it, as in the app
        // (`DictationSounds`): waiting up to 650 ms for the cue lost the first words of a
        // quick start, and Zone keeps early words over a cue that might bleed in.
        openMicrophone(id: id)
        let preferences = settings.current()
        startCueDuration = cue.play(start: true, preferences: preferences)
        KeyboardLog.journal?.log("keyboardStartCue", recording: id,
                                 ["enabled": String(preferences.soundsEnabled), "duration": JournalFormat.seconds(startCueDuration)])
    }

    private func openMicrophone(id: UUID) {
        observeSession(id: id)
        #if DEBUG && targetEnvironment(simulator)
        if let fixture {
            playFixture(fixture, id: id)
            return
        }
        #endif
        let preferBuiltIn = AudioSessionForCapture.prepare(id: id)
        capture?.onEvent = { [weak self] event in self?.handle(event, id: id) }
        capture?.start(preferBuiltIn: preferBuiltIn)
        startTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.startLimit)
            guard let self, !Task.isCancelled, self.recording == id, !self.hasAudio else { return }
            self.fail("The microphone did not start here.", id: id)
        }
    }

    /// While paused the microphone stays open and its samples are dropped, like the app's pause.
    func setPaused(_ paused: Bool) {
        isPaused = paused
    }

    func stop() {
        guard let id = recording, hasAudio, file != nil, stopTimer == nil else { return }
        #if DEBUG && targetEnvironment(simulator)
        if playback != nil {
            playback?.cancel()
            playback = nil
            recognize(id: id)
            return
        }
        #endif
        capture?.stop()
        // The page confirms within a frame or two. If it never does, what was written is recognized anyway.
        stopTimer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, !Task.isCancelled, self.recording == id else { return }
            self.recognize(id: id)
        }
    }

    func release() {
        releaseRequested = true
        guard file == nil, recording == nil || recognition != nil else { return }
        capture?.remove()
        capture = nil
    }

    func cancel(discardAudio: Bool) {
        guard let id = recording else { return }
        KeyboardLog.journal?.log("keyboardLocalCancel", recording: id)
        reset()
        saved(id, durable: discardAudio)
    }

    private func reset() {
        discardSpeechPage()
        if file != nil || !hasAudio { cue.cancel() }
        #if DEBUG && targetEnvironment(simulator)
        playback?.cancel()
        playback = nil
        #endif
        startTimer?.cancel()
        startTimer = nil
        stopTimer?.cancel()
        stopTimer = nil
        stopObservingSession()
        recognition?.cancel()
        recognition = nil
        capture?.onEvent = nil
        capture?.stop()
        if let recording { AudioSessionForCapture.release(id: recording) }
        file = nil
        recording = nil
        hasAudio = false
        isPaused = false
        peak = 0
    }

    private func handle(_ event: WebMicrophone.Event, id: UUID) {
        guard recording == id else { return }
        switch event {
        case .started(let sampleRate, let muted):
            startTimer?.cancel()
            do {
                let url = Self.directory.appendingPathComponent(KeyboardCapture.recordingName(id))
                let writer = try KeyboardAudioFile(url: url, sampleRate: sampleRate)
                file = writer
                pending[id] = (url, writer)
            } catch {
                fail("Could not save the recording.", id: id, detail: JournalFormat.error(error))
                return
            }
            self.sampleRate = sampleRate
            hasAudio = true
            var fields = MemoryFootprint.journalFields()
            fields["ms"] = String(Int(Date().timeIntervalSince(requestedAt) * 1000))
            fields["rate"] = String(Int(sampleRate))
            fields["muted"] = String(muted)
            KeyboardLog.journal?.log("keyboardLocalStarted", recording: id, fields)
            if #available(iOS 26, *), recordingRoute?.mode == .standard { ZoneModelSpeech.shared.recordingBegan(id) }
            if holds.contains("NativeInterruption") { capture?.setNativeHold(true) }
            onEvent?(id, .started)
            pollSession(id: id)
        case .samples(let data, let rootMeanSquare):
            guard hasAudio, stopTimer == nil else { return }
            if holds == ["NativeInterruption"], rootMeanSquare.isFinite, rootMeanSquare > 0, sampleRate > 0 {
                liveSampleSeconds += Double(data.count / 2) / sampleRate
                if liveSampleSeconds >= 1 { signal("NativeInterruption", active: false, id: id) }
            } else {
                liveSampleSeconds = 0
            }
            if !isPaused {
                file?.append(data)
                if shouldWarmSpeech {
                    shouldWarmSpeech = false
                    if let host = recognitionHost, let folder = file?.url.deletingLastPathComponent(),
                       FluidWebModel.ready, let model = FluidWebModel.directory {
                        let sealed = folder.appendingPathComponent(KeyboardCapture.handoffName(id))
                        let job = KeyboardWebSpeech(audio: sealed, model: model)
                        warmingSpeech = job
                        job.prepare(in: host)
                    }
                }
                if warmingSpeech != nil, let file, file.recordedSeconds > 40 { discardSpeechPage() }
                if rootMeanSquare.isFinite { peak = max(peak, rootMeanSquare) }
                if file?.writeFailed == true {
                    // The audio is no longer being saved (a full disk). Ending here is honest: the
                    // meter would keep moving while every later word was lost.
                    KeyboardLog.journal?.log("keyboardLocalWriteFailed", recording: id)
                    stop()
                    return
                }
            }
            onEvent?(id, .samples(rms: rootMeanSquare))
        case .stopped:
            recognize(id: id)
        case .muted:
            signal("TrackMute", active: true, id: id)
        case .unmuted:
            signal("TrackMute", active: false, id: id)
        case .webState(let source, let active):
            signal(source, active: active, id: id)
        case .beat:
            pollSession(id: id)
        case .ended(let reason):
            // iOS took the microphone away, or the page gave it up (an interruption, or no
            // heartbeat from here for three seconds). What was said so far is still worth recognizing.
            KeyboardLog.journal?.log("keyboardLocalTrackEnded", recording: id, ["audio": String(hasAudio), "reason": reason])
            // The capture is already over, so nothing waits for the page to confirm a stop.
            if hasAudio, reason == "stuck-muted" { onEvent?(id, .stuckMuted) }
            if hasAudio { recognize(id: id) } else { fail("The microphone did not start here.", id: id, detail: "ended \(reason)") }
        case .failed(let message):
            KeyboardLog.mic.error("keyboard capture failed: \(message, privacy: .public)")
            fail(hasAudio ? "The recording stopped." : "The microphone did not start here.", id: id,
                 detail: String(message.prefix(80)))
        case .processEnded:
            // The page reloads by itself; this recording's samples so far are on disk.
            if hasAudio {
                KeyboardLog.journal?.log("keyboardLocalProcessEnded", recording: id)
                recognize(id: id)
            } else {
                fail("The microphone did not start here.", id: id, detail: "web process ended")
            }
        }
    }

    private func observeSession(id: UUID) {
        #if DEBUG && targetEnvironment(simulator)
        debugObservations = [
            DarwinNotifier.observe(.debugKeyboardInterrupt) { [weak self] in self?.signal("DebugInterrupt", active: true, id: id) },
            DarwinNotifier.observe(.debugKeyboardResume) { [weak self] in self?.signal("DebugInterrupt", active: false, id: id) }
        ]
        #endif
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        sessionObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
            object: session, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let kind = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            let reason = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            if kind == .began, reason == AVAudioSession.InterruptionReason.appWasSuspended.rawValue { return }
            MainActor.assumeIsolated {
                guard let self, self.recording == id, !self.sessionObservers.isEmpty else { return }
                self.signal("NativeInterruption", active: kind == .began, id: id, fields: [
                    "reason": reason.map { String($0) } ?? "unspecified",
                    "shouldResume": String(AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume))
                ])
            }
        })
        sessionObservers.append(center.addObserver(forName: AVAudioSession.silenceSecondaryAudioHintNotification,
            object: session, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt
            MainActor.assumeIsolated {
                guard self?.recording == id else { return }
                KeyboardLog.journal?.log("keyboardLocalSecondaryHint", recording: id, ["value": String(describing: raw)])
            }
        })
    }

    // Playback hints are diagnostic. Only actual interruptions hold the recording.
    private func pollSession(id: UUID) {
        guard sessionPoll == nil else { return }
        sessionPoll = Task { [weak self] in
            let (other, secondary) = await Task.detached(priority: .utility) {
                let session = AVAudioSession.sharedInstance()
                return (session.isOtherAudioPlaying, session.secondaryAudioShouldBeSilencedHint)
            }.value
            guard let self, !Task.isCancelled, self.recording == id else { return }
            self.sessionPoll = nil
            self.recordAudioHints(other: other, secondary: secondary, id: id)
        }
    }

    private func recordAudioHints(other: Bool, secondary: Bool, id: UUID) {
        if other != otherAudio {
            otherAudio = other
            KeyboardLog.journal?.log("keyboardLocalOtherAudio", recording: id, ["active": String(other)])
        }
        if secondary != secondaryAudio {
            secondaryAudio = secondary
            KeyboardLog.journal?.log("keyboardLocalSecondaryAudio", recording: id, ["active": String(secondary)])
        }
    }

    private func signal(_ source: String, active: Bool, id: UUID, fields: [String: String] = [:]) {
        guard recording == id, !sessionObservers.isEmpty, stopTimer == nil else { return }
        liveSampleSeconds = 0
        let wasHeld = !holds.isEmpty
        if active { holds.insert(source) } else { holds.remove(source) }
        if source == "NativeInterruption" { capture?.setNativeHold(active) }
        var details = fields
        details["active"] = String(active)
        KeyboardLog.journal?.log("keyboardLocal" + source, recording: id, details)
        if wasHeld != !holds.isEmpty {
            KeyboardLog.journal?.log(active ? "keyboardLocalHeld" : "keyboardLocalResumed", recording: id)
            onEvent?(id, .held(active))
        }
    }

    func recoverInput() {
        guard let id = recording else { return }
        for source in holds { signal(source, active: false, id: id) }
        capture?.recover(manual: true)
    }

    private func stopObservingSession() {
        #if DEBUG && targetEnvironment(simulator)
        debugObservations.removeAll()
        #endif
        sessionObservers.forEach(NotificationCenter.default.removeObserver)
        sessionObservers.removeAll()
        sessionPoll?.cancel()
        sessionPoll = nil
        holds.removeAll()
        otherAudio = nil
        secondaryAudio = nil
    }

    private func recognize(id: UUID) {
        stopTimer?.cancel()
        let playStopCue = holds.isEmpty
        stopObservingSession()
        guard let file else { return }
        self.file = nil
        let url = file.url
        capture?.onEvent = nil
        capture?.stop()
        // Finish the audio handoff before another process can claim the microphone.
        cue.cancel()
        let cueCanMix = AudioSessionForCapture.release(id: id)
        onEvent?(id, .recognizing)
        if playStopCue && cueCanMix { cue.play(start: false, preferences: settings.current()) }
        let audioSeconds = file.finish()
        stopTimer = nil
        if releaseRequested { capture?.remove(); capture = nil }
        if KeyboardCapture.isSilent(peak: peak) {
            discardSpeechPage()
            recording = nil
            KeyboardLog.journal?.log("keyboardModelDecision", recording: id, ["decision": "skip", "reason": "silence", "audio": JournalFormat.seconds(audioSeconds)])
            onEvent?(id, .finished(text: "", audioSeconds: audioSeconds, module: "silence"))
            return
        }
        transcribe(url: url, id: id, audioSeconds: audioSeconds, retrying: false)
    }

    private func transcribe(url source: URL, id: UUID, audioSeconds: Double, retrying: Bool) {
        // Publish a recoverable intent before entering either speech model. The open writer
        // owns the inode across the rename. Zone can import only after that lock is released.
        let url: URL
        do {
            url = try KeyboardAudioFile.sealForHandoff(source, id: id)
            pending[id]?.url = url
        } catch {
            KeyboardLog.journal?.log("keyboardAudioSealFailed", recording: id, ["code": JournalFormat.error(error)])
            reset()
            saved(id, durable: false)
            onEvent?(id, .savedForZone)
            return
        }
        guard #available(iOS 26.0, *) else {
            fail("This iPhone cannot recognize speech here.", id: id)
            return
        }
        func stamp(_ action: String, _ update: () throws -> Void) {
            do { try update() }
            catch {
                KeyboardLog.journal?.log("keyboardAudioAttemptStampFailed", recording: id,
                                         ["action": action, "error": JournalFormat.error(error)])
            }
        }
        let attempt = KeyboardRecognitionAttempt(wav: url, retry: retrying)
        let submitted: @Sendable () -> Void = {
            do { try attempt.submit() }
            catch { KeyboardLog.journal?.log("keyboardAudioAttemptStampFailed", recording: id,
                                             ["action": "begin", "error": JournalFormat.error(error)]) }
        }
        let stoppedAt = Date()
        let limit = KeyboardCapture.recognitionLimit(audioSeconds: audioSeconds)
        let allowsApple = allowsAppleSpeech
        let recognizeOnComputer = self.recognizeOnComputer
        let configured = KeyboardVoiceRoute.load()
        // A previously kept recording has no consent to send it to a newly selected computer.
        // Changing endpoints or turning the mode off during a recording also keeps it on iPhone.
        let route = configured.forRecording(startedWith: recordingRoute, retrying: retrying)
        let host = recognitionHost
        if route.mode != .webView || audioSeconds > 40 { discardSpeechPage() }
        let prepared = warmingSpeech
        warmingSpeech = nil
        recognition = Task { [weak self] in
            defer { prepared?.cancel() }
            let outcome: Result<LocalSpeech.Heard, Error>
            do {
                // Both models share this deadline, including startup.
                let file = url
                outcome = .success(try await Watchdog.run(what: "Keyboard dictation", limit: limit) {
                    if route.mode != .standard {
                        do {
                            let result = try await Watchdog.run(what: "Keyboard recognition provider", limit: min(limit * 0.65, 50)) {
                                try await Self.alternate(route, url: file, seconds: audioSeconds, host: host, limit: limit * 0.6, prepared: prepared, recognizeOnComputer: recognizeOnComputer, submitted: submitted)
                            }
                            if !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return result }
                            try Task.checkCancellation()
                            KeyboardLog.journal?.log("keyboardRecognitionRouteFallback", recording: id,
                                                     ["route": route.mode.rawValue, "reason": "emptyTranscript"])
                        } catch is CancellationError { throw CancellationError() }
                        catch {
                            try Task.checkCancellation()
                            KeyboardLog.journal?.log("keyboardRecognitionRouteFallback", recording: id,
                                                     ["route": route.mode.rawValue, "reason": JournalFormat.error(error)])
                        }
                    }
                    return try await LocalSpeech.preferred(recording: id, allowsApple: allowsApple) {
                        try await ZoneModelSpeech.shared.recognize(url: file, id: id, limit: limit, submitted: submitted)
                    } apple: {
                        #if DEBUG && targetEnvironment(simulator)
                        if let scripted = LocalSpeech.scriptedText() {
                            submitted()
                            return LocalSpeech.Heard(text: scripted, module: "scripted")
                        }
                        #endif
                        return try await LocalSpeech.transcribe(file, submitted: submitted)
                    }
                })
            } catch {
                outcome = .failure(error)
            }
            guard let self, !Task.isCancelled, self.recording == id else {
                return
            }
            self.recognition = nil
            switch outcome {
            case .success(let heard):
                let text = heard.text
                stamp("finish") {
                    let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    try attempt.finish(empty ? .noWords : .transcribed)
                }
                var fields = MemoryFootprint.journalFields()
                fields["ms"] = String(Int(Date().timeIntervalSince(stoppedAt) * 1000))
                fields["audio"] = JournalFormat.seconds(audioSeconds)
                fields["words"] = JournalFormat.words(text)
                fields["retry"] = String(retrying)
                fields.merge(heard.fields) { _, worker in worker }
                fields["module"] = heard.module
                KeyboardLog.journal?.log("keyboardLocalRecognized", recording: id, fields)
                self.recording = nil
                self.onEvent?(id, .finished(text: text, audioSeconds: audioSeconds, module: heard.module, doubts: heard.doubts))
                // The hidden lab, only with its file in the App Group: after the words are written.
                OwnModelLabRunner.afterDictation(recording: id)
            case .failure(let failure):
                stamp("failure") { try attempt.finish(.modelFailed) }
                let fallback = failure as? LocalSpeech.FallbackFailed
                KeyboardLog.journal?.log("keyboardAudioForZone", recording: id, fallback?.fields ?? [:])
                self.reset()
                self.saved(id, durable: false)
                self.onEvent?(id, .savedForZone)
            }
        }
    }

    @available(iOS 26, *)
    private static func alternate(_ route: KeyboardVoiceRoute, url: URL, seconds: Double,
                                  host: UIView?, limit: Double, prepared: KeyboardWebSpeech?, recognizeOnComputer: ComputerRecognizer,
                                  submitted: @escaping @Sendable () -> Void) async throws -> LocalSpeech.Heard {
        switch route.mode {
        case .standard: throw URLError(.unsupportedURL)
        case .webView:
            guard seconds <= 40, FluidWebModel.ready, let model = FluidWebModel.directory, let host else {
                throw URLError(.resourceUnavailable)
            }
            let job = prepared ?? KeyboardWebSpeech(audio: url, model: model)
            return try await job.recognize(in: host, submitted: submitted)
        case .computer:
            let heard = try await recognizeOnComputer(url, route, limit, submitted)
            let words = (heard.words ?? []).compactMap { word -> DoubtfulWord? in
                guard let probability = word.probability, probability.isFinite, (0...1).contains(probability) else { return nil }
                return DoubtfulWord(word: word.word.trimmingCharacters(in: .whitespacesAndNewlines), confidence: probability)
            }
            return .init(text: SegmentText.cleaned(heard.text), module: "zoneLinkGPU", doubts: DoubtfulWords.candidates(words))
        }
    }

    func keptStart(id: UUID) -> Date? {
        Self.keptStart(id: id, inbox: KeyboardAudioFile.inbox, temporary: FileManager.default.temporaryDirectory)
    }

    static func keptStart(id: UUID, inbox: URL?, temporary: URL) -> Date? {
        for directory in [inbox, temporary].compactMap({ $0 }) {
            for name in [KeyboardCapture.retryName(id), KeyboardCapture.recordingName(id)] {
                if let start = try? directory.appendingPathComponent(name).resourceValues(forKeys: [.creationDateKey]).creationDate {
                    return start
                }
            }
        }
        return nil
    }

    func keptRecording(excluding: Set<UUID>) -> UUID? {
        guard recording == nil,
              let files = try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let now = Date()
        return files.compactMap { file -> (id: UUID, modified: Date)? in
            guard let id = KeyboardCapture.retryID(fromName: file.lastPathComponent),
                  !excluding.contains(id), pending[id] == nil,
                  let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  (0..<KeyboardCapture.retryKeptFor).contains(now.timeIntervalSince(modified)) else { return nil }
            return (id, modified)
        }.max { $0.modified < $1.modified }?.id
    }

    @discardableResult
    func retryKept(id: UUID) -> Bool {
        guard recording == nil else { return false }
        let url = Self.directory.appendingPathComponent(KeyboardCapture.retryName(id))
        guard let lease = KeyboardAudioFile.lock(url), let seconds = PCMFile.duration(of: url) else { return false }
        pending[id] = (url, lease)
        recording = id
        hasAudio = true
        KeyboardLog.journal?.log("keyboardLocalRetry", recording: id, ["audio": JournalFormat.seconds(seconds)])
        transcribe(url: url, id: id, audioSeconds: seconds, retrying: true)
        return true
    }

    private func fail(_ message: String, id: UUID, detail: String? = nil, fields extra: [String: String] = [:]) {
        guard recording == id else { return }
        let beforeAudio = !hasAudio
        var fields = MemoryFootprint.journalFields()
        fields.merge(extra) { _, value in value }
        fields["beforeAudio"] = String(beforeAudio)
        if let detail { fields["detail"] = detail }
        KeyboardLog.journal?.log("keyboardLocalFailed", recording: id, fields)
        reset()
        saved(id, durable: false)
        onEvent?(id, .failed(message: message, beforeAudio: beforeAudio))
    }
}

/// WKWebView captures the samples. Only a real press prepares the extension's audio
/// session; loading the page or transcribing saved audio must leave other playback alone.
@MainActor
enum AudioSessionForCapture {
    private(set) static var owner: UUID?

    static let recordingOptions: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP, .defaultToSpeaker]

    /// Keep CarPlay on the car's mic. A rejected native session remains eligible for
    /// WebKit capture so the person can still record on routes that disallow interruption.
    static func prepare(id: UUID) -> Bool {
        let session = AVAudioSession.sharedInstance()
        let inCar = session.currentRoute.outputs.contains { $0.portType == .carAudio }
        owner = id
        do {
            let requested = recordingOptions
            if session.category != .playAndRecord || session.mode != .measurement || session.categoryOptions != requested {
                try session.setCategory(.playAndRecord, mode: .measurement, options: requested)
            }
            do { try session.setActive(true) }
            catch {
                // Higher-priority audio can refuse the interruption. Preserve a capture
                // WebKit can still start on a mixing session.
                KeyboardLog.journal?.log("keyboardMusicPauseFailed", ["error": JournalFormat.error(error)])
                try session.setCategory(.playAndRecord, mode: .measurement, options: requested.union(.mixWithOthers))
            }
            try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            if !inCar, session.preferredInput?.portType != .builtInMic,
               let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try session.setPreferredInput(builtIn)
            }
        } catch {
            KeyboardLog.journal?.log("keyboardLocalSession", ["error": JournalFormat.error(error)])
        }
        return !inCar
    }

    @discardableResult
    static func release(id: UUID) -> Bool {
        guard owner == id else { return false }
        owner = nil
        let session = AVAudioSession.sharedInstance()
        do { try session.setActive(false, options: .notifyOthersOnDeactivation) }
        catch { KeyboardLog.journal?.log("keyboardAudioReleaseFailed", ["error": JournalFormat.error(error)]) }
        // A stop cue may activate audio again. Make that cue mix with the player
        // that iOS just invited to resume.
        do {
            try session.setCategory(.ambient)
            return true
        } catch {
            KeyboardLog.journal?.log("keyboardCueCategoryFailed", ["error": JournalFormat.error(error)])
            return false
        }
    }
}

/// The 16-bit mono samples the page posts, written as a WAV.
@MainActor
private enum PCMFile {
    /// Seconds in a WAV written earlier, nil when it cannot be read.
    static func duration(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0, file.length > 0 else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}

/// The hidden web view whose page (`KeyboardCapturePage`) holds the microphone.
@MainActor
private final class WebMicrophone: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    enum Event {
        case started(sampleRate: Double, muted: Bool)
        case samples(Data, rootMeanSquare: Float)
        case stopped
        case muted
        case unmuted
        case webState(String, Bool)
        case beat
        /// The capture is over without a stop from here; the reason is the page's.
        case ended(String)
        case failed(String)
        case processEnded
    }

    var onEvent: ((Event) -> Void)?
    private let webView: WKWebView
    private(set) var isLoaded = false
    /// The page stops the microphone by itself when these stop coming (`KeyboardCapturePage`).
    private var beat: Task<Void, Never>?
    private var startWhenLoaded = false
    private var preferBuiltIn = true
    /// The capture the page is asked to run; every message it posts echoes it, and anything
    /// from an older one is dropped.
    private var epoch = 0

    init(host: UIView) {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // The page is inline and keeps nothing: no cookies, caches or storage written for it.
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: configuration)
        super.init()
        configuration.userContentController.add(WeakHandler(self), name: KeyboardCapturePage.handler)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isUserInteractionEnabled = false
        webView.isAccessibilityElement = false
        webView.accessibilityElementsHidden = true
        // WebKit does not run media in a view that is hidden or off screen, so it stays in the
        // keyboard's view, two points square and all but transparent.
        webView.alpha = 0.02
        host.addSubview(webView)
        load()
    }

    private func load() {
        isLoaded = false
        webView.loadHTMLString(KeyboardCapturePage.html, baseURL: URL(string: "https://\(KeyboardCapturePage.host)/"))
    }

    /// A new keyboard controller has a new view: the web view moves into it.
    func attach(to host: UIView) {
        guard webView.superview !== host else { return }
        webView.removeFromSuperview()
        host.addSubview(webView)
    }

    /// Takes the web view out of the keyboard, which lets WebKit end its helper processes.
    func remove() {
        onEvent = nil
        beat?.cancel()
        beat = nil
        webView.stopLoading()
        webView.removeFromSuperview()
    }

    func start(preferBuiltIn: Bool) {
        epoch += 1
        self.preferBuiltIn = preferBuiltIn
        startBeat()
        guard isLoaded else {
            startWhenLoaded = true
            return
        }
        webView.evaluateJavaScript("zoneStart(\(epoch), \(preferBuiltIn))")
    }

    func setNativeHold(_ held: Bool) {
        if isLoaded { webView.evaluateJavaScript("zoneNativeHold(\(epoch), \(held)); 0") }
    }

    func recover(manual: Bool = false) {
        if isLoaded { webView.evaluateJavaScript("zoneRecover(\(epoch), \(manual)); 0") }
    }

    func stop() {
        startWhenLoaded = false
        beat?.cancel()
        beat = nil
        guard isLoaded else { return }
        webView.evaluateJavaScript("zoneStop(\(epoch))")
    }

    /// One sign of life a second for the capture just asked for. A keyboard that iOS suspends
    /// or ends stops sending them, and the page then closes the microphone itself.
    private func startBeat() {
        beat?.cancel()
        let epoch = epoch
        beat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(KeyboardCapturePage.beatEvery))
                guard let self, !Task.isCancelled, self.epoch == epoch else { return }
                if self.isLoaded { self.webView.evaluateJavaScript("zoneBeat(\(epoch)); 0", completionHandler: nil) }
                self.onEvent?(.beat)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        if startWhenLoaded {
            startWhenLoaded = false
            webView.evaluateJavaScript("zoneStart(\(epoch), \(preferBuiltIn))")
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onEvent?(.failed("page \(JournalFormat.error(error))"))
    }

    /// The page may leave for nothing: only its own inline document loads.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.request.url?.host == KeyboardCapturePage.host || navigationAction.request.url?.scheme == "about" ? .allow : .cancel
    }

    /// Answers the page's request for the microphone, so no web permission sheet appears. iOS
    /// still requires that the person allowed the microphone for Zone.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        decisionHandler(type == .microphone && origin.host == KeyboardCapturePage.host ? .grant : .deny)
    }

    /// The page's process died, idle or not. It is loaded again at once, so the next start
    /// finds a working page instead of waiting for a load that never comes.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        startWhenLoaded = false
        beat?.cancel()
        beat = nil
        load()
        onEvent?(.processEnded)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String,
              (body["epoch"] as? NSNumber)?.intValue == epoch else { return }
        switch type {
        case "started":
            onEvent?(.started(sampleRate: (body["rate"] as? Double) ?? 48_000, muted: (body["muted"] as? Bool) ?? false))
        case "pcm":
            guard let encoded = body["data"] as? String, let data = Data(base64Encoded: encoded) else { return }
            onEvent?(.samples(data, rootMeanSquare: Float((body["rms"] as? Double) ?? 0)))
        case "stopped":
            onEvent?(.stopped)
        case "muted":
            onEvent?(.muted)
        case "unmuted":
            onEvent?(.unmuted)
        case "context", "session":
            guard let held = body["held"] as? Bool else { return }
            onEvent?(.webState(type == "context" ? "WebContext" : "WebSession", held))
        case "ended":
            onEvent?(.ended((body["reason"] as? String) ?? "track"))
        case "error":
            onEvent?(.failed((body["message"] as? String) ?? "unknown"))
        default:
            break
        }
    }
}

/// A user content controller retains its handler; this breaks the cycle with the web view's owner.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Apple's on-device recognizer over a finished recording. The model runs outside the
/// keyboard's process, which is what lets a keyboard use it at all: Zone's own model is 253 MB.
@available(iOS 26.0, *)
enum LocalSpeech {
    enum Failure: Error {
        case noLocale, assetsMissing, tooSlow, zoneModelOnly

        var message: String {
            switch self {
            case .zoneModelOnly: "Zone's speech model could not finish here."
            case .noLocale: "Apple's speech model does not support English here."
            case .assetsMissing: "Apple's speech model is not on this iPhone yet. Open Zone once."
            case .tooSlow: "Recognizing took too long."
            }
        }
    }

    #if DEBUG && targetEnvironment(simulator)
    /// Simulator Debug builds only. The simulator cannot subscribe to Apple's speech asset
    /// ("is not subscribed to transcription.en"), so `keyboard-local-speech.txt` in the App Group
    /// container stands in for the recognizer and the rest of the path runs for real: the web
    /// view's microphone, the result, the insert and History.
    static func scriptedText() -> String? {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ZoneContract.appGroup)?
            .appendingPathComponent("keyboard-local-speech.txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    #endif

    typealias Heard = KeyboardRecognitionResult

    struct FallbackFailed: Error {
        let apple: Error
        let fields: [String: String]
    }

    static func preferred(recording: UUID? = nil, allowsApple: @MainActor () -> Bool = { true },
                          worker: () async throws -> Heard, apple: () async throws -> Heard) async throws -> Heard {
        let start = ProcessInfo.processInfo.systemUptime
        do { return try await worker() }
        catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            let issue = KeyboardWorkerIssue.describe(error)
            var fields = MemoryFootprint.journalFields()
            fields.merge(issue.fields) { _, value in value }
            let mayUseApple = await allowsApple()
            fields["decision"] = mayUseApple ? "appleFallback" : "noAppleByChoice"
            fields["workerElapsedMs"] = String(Int((ProcessInfo.processInfo.systemUptime - start) * 1000))
            KeyboardLog.journal?.log("keyboardModelFallback", recording: recording, fields)
            KeyboardLog.journal?.flush()
            // The person chose never to use Apple's speech model: the audio is kept for Zone.
            guard mayUseApple else { throw FallbackFailed(apple: Failure.zoneModelOnly, fields: fields) }
            do {
                var result = try await apple()
                result.fields.merge(fields) { _, value in value }
                return result
            } catch is CancellationError { throw CancellationError() }
            catch { throw FallbackFailed(apple: error, fields: fields) }
        }
    }

    /// Apple's two on-device recognizers, in the order the keyboard tries them.
    /// `SpeechTranscriber` is the one Zone's app uses and the better of the two; it does not
    /// exist on every iPhone (the A13 models have none), and its asset can refuse to install in
    /// a keyboard even when the app has it. `DictationTranscriber`, the system dictation model,
    /// is then tried with the same recording, so one refusal does not cost the words
    /// (anomalyco/hex #2048 and #2090, from its testers' iPhones).
    enum Module: String, CaseIterable, Sendable {
        case speech, dictation
    }

    private static let english = Locale(identifier: "en-US")

    /// The same locale the app's Apple engine asks for, so both use one installed asset.
    static func locale(for module: Module) async -> Locale? {
        switch module {
        case .speech:
            guard SpeechTranscriber.isAvailable else { return nil }
            return await SpeechTranscriber.supportedLocale(equivalentTo: english)
        case .dictation:
            return await DictationTranscriber.supportedLocale(equivalentTo: english)
        }
    }

    static func transcribe(_ url: URL, submitted: @escaping @Sendable () -> Void = {}) async throws -> Heard {
        var last: Error = Failure.noLocale
        for module in Module.allCases {
            guard let locale = await locale(for: module) else { continue }
            do {
                return Heard(text: try await transcribe(url, module: module, locale: locale, submitted: submitted), module: module.rawValue)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                // The next recognizer gets the same recording.
                KeyboardLog.journal?.log("keyboardLocalModuleFailed", ["module": module.rawValue, "error": JournalFormat.error(error)])
                last = error
            }
        }
        throw last
    }

    /// Each bundle holds its own reservation of a locale's assets, the keyboard apart from the
    /// app: without one the system answers "not subscribed" for an asset the app already
    /// installed. Reservations are limited (`maximumReservedLocales`, fewer on a full iPhone),
    /// so an existing reservation stays in place when there is no room for another.
    private static func reserve(_ locale: Locale) async {
        let wanted = locale.identifier(.bcp47)
        let reserved = await AssetInventory.reservedLocales
        guard !reserved.contains(where: { $0.identifier(.bcp47) == wanted }),
              reserved.count < AssetInventory.maximumReservedLocales else { return }
        do {
            _ = try await AssetInventory.reserve(locale: locale)
        } catch {
            KeyboardLog.journal?.log("keyboardLocalReserve", ["error": JournalFormat.error(error)])
        }
    }

    private static func modules(for module: Module, locale: Locale) -> [any SpeechModule] {
        switch module {
        case .speech: return [SpeechTranscriber(locale: locale, preset: .transcription)]
        case .dictation:
            return [DictationTranscriber(locale: locale, contentHints: [.shortForm], transcriptionOptions: [.punctuation],
                                        reportingOptions: [], attributeOptions: [])]
        }
    }

    private static func transcribe(_ url: URL, module: Module, locale: Locale, submitted: @Sendable () -> Void) async throws -> String {
        let modules = modules(for: module, locale: locale)
        await reserve(locale)
        guard await AssetInventory.status(forModules: modules) == .installed else { throw Failure.assetsMissing }
        let speech = modules.first as? SpeechTranscriber
        let dictation = modules.first as? DictationTranscriber
        try Task.checkCancellation()
        let analyzer = SpeechAnalyzer(modules: modules,
                                      options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse))
        let file = try AVAudioFile(forReading: url)
        // A time limit cancels this task; the analyzer is told to stop at once rather than
        // finishing a file nobody is waiting for.
        return try await withTaskCancellationHandler {
            submitted()
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            var parts: [String] = []
            if let speech {
                for try await result in speech.results where result.isFinal {
                    parts.append(String(result.text.characters))
                }
            } else if let dictation {
                for try await result in dictation.results where result.isFinal {
                    parts.append(String(result.text.characters))
                }
            }
            return SegmentText.join(parts).trimmingCharacters(in: .whitespacesAndNewlines)
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}
