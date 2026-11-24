// by zayd/cold @ zayd.wtf

import AVFAudio
import FluidAudio
import Foundation
import Observation
import UIKit
import ZoneCore

/// One run of voice setup (`VoiceSetup`): records each part through the dictation microphone
/// path, counts speech as it arrives, chimes when a part has enough, and turns each part into a
/// voice print with the meeting speaker model. Only the prints are saved (`VoiceProfileStore`);
/// the audio is dropped as soon as its part is embedded, and never written to disk.
@MainActor
@Observable
final class VoiceSetupSession {
    enum Stage: Equatable {
        case intro
        case step(VoiceSetup.Part)
        /// Every part recorded or skipped; the prints are being made and can be saved.
        case review
        /// Saved.
        case finished
    }

    enum Recorder: Equatable {
        case idle
        case countdown(Int)
        case recording
        /// A call or Siri took the microphone; what was heard so far is kept.
        case interrupted
    }

    enum PrintState: Equatable {
        case waiting
        case working
        case ready
        case failed(String)
    }

    private(set) var stage: Stage = .intro
    private(set) var recorder: Recorder = .idle
    /// Seconds of speech heard per part.
    private(set) var speech: [VoiceSetup.Part: Double] = [:]
    /// Parts finished (enough speech, or stopped past the minimum).
    private(set) var finished: Set<VoiceSetup.Part> = []
    private(set) var skipped: Set<VoiceSetup.Part> = []
    private(set) var prints: [VoiceSetup.Part: VoiceProfile.Print] = [:]
    private(set) var printStates: [VoiceSetup.Part: PrintState] = [:]
    /// The last 36 levels for the wave, 0...1.
    private(set) var recentLevels: [Float] = Array(repeating: 0, count: 36)
    /// True for the latest frame: the person is being heard right now.
    private(set) var hearing = false
    private(set) var message: String?
    private(set) var saving = false
    /// After saving: earlier meetings where Zone now hears the person (`MeetingKnownVoices.findMe`).
    private(set) var earlierMeetings: [MeetingKnownVoices.MeMatch] = []
    private(set) var markedEarlier = false

    private let dictation: DictationCoordinator
    private let meetings: MeetingCoordinator
    private let store: VoiceProfileStore
    @ObservationIgnored private var meters: [VoiceSetup.Part: VoiceSetupMeter] = [:]
    @ObservationIgnored private var audio: [VoiceSetup.Part: [Float]] = [:]
    @ObservationIgnored private var framer = LevelFramer()
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var models: Task<OfflineDiarizerModels, Error>?
    /// Bumped per recording, so a level posted by a stopped recording is never counted in the next.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var printTasks: [VoiceSetup.Part: Task<Void, Never>] = [:]
    @ObservationIgnored private var recordingPart: VoiceSetup.Part?
    @ObservationIgnored private var stopping = false
    /// Set the moment a part has enough (or Done is tapped): later frames, the chime among
    /// them, are not counted.
    @ObservationIgnored private var closing = false

    init(dictation: DictationCoordinator, meetings: MeetingCoordinator, store: VoiceProfileStore = .default) {
        self.dictation = dictation
        self.meetings = meetings
        self.store = store
        dictation.onVoiceSetupInterruption = { [weak self] interruption in
            guard let self, case .began = interruption, self.recorder == .recording else { return }
            Task { await self.pause(interrupted: true) }
        }
    }

    // MARK: Flow

    var steps: [VoiceSetup.Step] { VoiceSetup.steps }

    var currentStep: VoiceSetup.Step? {
        if case .step(let part) = stage { return VoiceSetup.step(part) }
        return nil
    }

    /// 0...1 toward the current part's target.
    func progress(_ part: VoiceSetup.Part) -> Double {
        min(1, speech[part, default: 0] / VoiceSetup.step(part).target)
    }

    var canSave: Bool {
        let heard = Dictionary(uniqueKeysWithValues: finished.map { ($0, speech[$0, default: 0]) })
        return VoiceSetup.canSave(heard)
    }

    func begin() {
        message = nil
        meetings.prefetchSpeakerModel()
        stage = .step(.read)
    }

    /// The next part after `part` that is not done, or the end.
    func advance(from part: VoiceSetup.Part) {
        let order = VoiceSetup.Part.allCases
        guard let index = order.firstIndex(of: part) else { return }
        for next in order[(index + 1)...] where !finished.contains(next) && !skipped.contains(next) {
            stage = .step(next)
            message = nil
            return
        }
        stage = .review
    }

    /// Read step's way out: talk freely instead of reading.
    func talkInstead() {
        skipped.insert(.read)
        discard(.read)
        stage = .step(.talk)
    }

    func skip(_ part: VoiceSetup.Part) {
        cancelCountdown()
        Task {
            if recordingPart == part { await stopRecording(keep: false) }
            skipped.insert(part)
            discard(part)
            advance(from: part)
        }
    }

    /// Records the part again from nothing.
    func redo(_ part: VoiceSetup.Part) {
        discard(part)
        stage = .step(part)
    }

    private func discard(_ part: VoiceSetup.Part) {
        printTasks[part]?.cancel()
        printTasks[part] = nil
        finished.remove(part)
        speech[part] = nil
        meters[part] = nil
        audio[part] = nil
        prints[part] = nil
        printStates[part] = nil
    }

    // MARK: Recording

    func start(_ part: VoiceSetup.Part) {
        guard recorder == .idle || recorder == .interrupted, recordingPart == nil || recordingPart == part else { return }
        message = nil
        skipped.remove(part)
        let countdown = recorder == .interrupted ? 0 : VoiceSetup.step(part).countdown
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            guard let self else { return }
            if countdown > 0 {
                for left in stride(from: countdown, to: 0, by: -1) {
                    self.recorder = .countdown(left)
                    Haptics.tap()
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { self.recorder = .idle; return }
                }
                // The phone is across the room: a sound, since a haptic cannot be felt from there.
                await self.dictation.playVoiceSetupStartCue()
                if Task.isCancelled { self.recorder = .idle; return }
            }
            await self.record(part)
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        if case .countdown = recorder { recorder = .idle }
    }

    private func record(_ part: VoiceSetup.Part) async {
        if AVAudioApplication.shared.recordPermission != .granted, !(await dictation.requestMicrophonePermission()) {
            recorder = .idle
            message = "Zone needs the microphone for this. Turn it on in Settings."
            return
        }
        framer = LevelFramer()
        let framer = framer
        generation += 1
        let generation = generation
        do {
            try await dictation.startClipCapture(purpose: .voiceSetup) { [weak self] chunk in
                let levels = framer.add(chunk)
                guard !levels.isEmpty else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.heard(levels, part: part, generation: generation) }
                }
            }
        } catch {
            recorder = .idle
            message = error.localizedDescription
            return
        }
        recordingPart = part
        closing = false
        recorder = .recording
        Haptics.start()
    }

    private func heard(_ levels: [Float], part: VoiceSetup.Part, generation: Int) {
        guard generation == self.generation, recordingPart == part, recorder == .recording, !stopping, !closing else { return }
        var meter = meters[part] ?? VoiceSetupMeter()
        var next = recentLevels
        for level in levels {
            hearing = meter.add(level)
            next.removeFirst()
            next.append(VoiceSetupMeter.display(level))
        }
        meters[part] = meter
        recentLevels = next
        speech[part] = meter.speechSeconds
        if meter.speechSeconds >= VoiceSetup.step(part).target {
            closing = true
            Task { await finishPart(part) }
        }
    }

    /// The person tapped Done (or Use what I recorded): keeps the part when it has the minimum,
    /// else keeps listening.
    func done(_ part: VoiceSetup.Part) {
        guard !closing, !finished.contains(part), recordingPart == nil || recordingPart == part else { return }
        if speech[part, default: 0] >= VoiceSetup.step(part).minimum {
            if recordingPart == nil {
                // Nothing is recording: the part is kept as it stands.
                recorder = .idle
                finished.insert(part)
                makePrint(part)
                if part != .far { advance(from: part) }
                return
            }
            closing = true
            Task { await finishPart(part) }
        } else {
            message = "A little more. Zone needs about \(Int(VoiceSetup.step(part).minimum)) seconds of speech for this part."
        }
    }

    /// Stops recording and keeps what was heard; `start` continues the same part.
    func pause(interrupted: Bool = false) async {
        guard recordingPart != nil else { return }
        await stopRecording(keep: true)
        recorder = interrupted ? .interrupted : .idle
        if interrupted { message = "Recording paused for the call. Tap Continue when you're ready." }
    }

    private func finishPart(_ part: VoiceSetup.Part) async {
        guard recordingPart == part, !stopping else { return }
        closing = true
        Haptics.success()
        // The cue plays while the microphone is still open; the frames it adds are cut below.
        await dictation.playVoiceSetupCue()
        await stopRecording(keep: true)
        recorder = .idle
        finished.insert(part)
        makePrint(part)
        // The far part ends with the phone across the room: the chime says so, and the screen
        // waits for the person to come back instead of moving on by itself.
        if part != .far { advance(from: part) }
    }

    private func stopRecording(keep: Bool) async {
        guard let part = recordingPart, !stopping else { return }
        stopping = true
        defer { stopping = false }
        let samples = dictation.stopClipCapture()
        recordingPart = nil
        hearing = false
        recentLevels = Array(repeating: 0, count: 36)
        guard keep else { return }
        // Only whole frames the meter saw, so the meter's spans line up with the audio.
        let counted = meters[part]?.frames ?? 0
        let earlier = audio[part]?.count ?? 0
        let wanted = max(0, counted * LevelFramer.frameSamples - earlier)
        var kept = audio[part] ?? []
        kept.append(contentsOf: samples.prefix(wanted))
        if kept.count < counted * LevelFramer.frameSamples {
            kept.append(contentsOf: repeatElement(0, count: counted * LevelFramer.frameSamples - kept.count))
        }
        audio[part] = kept
    }

    /// Leaving the screen or the app: nothing half-recorded keeps the microphone.
    func stopEverything() {
        cancelCountdown()
        guard recordingPart != nil else { return }
        Task { await pause() }
    }

    // MARK: Prints

    private func makePrint(_ part: VoiceSetup.Part) {
        guard let samples = audio[part], let meter = meters[part] else { return }
        printStates[part] = .working
        let spans = meter.spans()
        let seconds = meter.speechSeconds
        printTasks[part]?.cancel()
        printTasks[part] = Task { [weak self] in
            guard let self else { return }
            do {
                let models = try await self.loadModels()
                let vectors = try await MeetingDiarizer.voicePrints(samples: samples, spans: spans, models: models)
                try Task.checkCancellation()
                guard let voice = VoiceSetup.print(of: vectors, seconds: spans.map { $0.upperBound - $0.lowerBound }) else {
                    throw SpeechEngineError.unavailable("Zone couldn't hear a steady voice in that part. Try it again somewhere quieter.")
                }
                self.prints[part] = VoiceProfile.Print(part: part, voice: voice, seconds: seconds, recordedAt: Date())
                self.printStates[part] = .ready
                self.audio[part] = nil
                ZoneLog.coordinator.info("voice setup: \(part.rawValue, privacy: .public) print from \(spans.count) pieces, \(Int(seconds)) s")
            } catch is CancellationError {
                return
            } catch {
                self.printStates[part] = .failed(error.localizedDescription)
                ZoneLog.coordinator.error("voice setup print failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The speaker model, loaded once for the whole setup. A missing model downloads through
    /// the meetings' own download (21.6 MB), so two downloads never write the same files.
    private func loadModels() async throws -> OfflineDiarizerModels {
        if let models { return try await models.value }
        let meetings = meetings
        let task = Task { @MainActor in
            if !MeetingDiarizer.modelsPresent() {
                meetings.prefetchSpeakerModel()
                let began = Date()
                while !MeetingDiarizer.modelsPresent() {
                    if case .failed(let reason) = meetings.speakerModel { throw SpeechEngineError.unavailable(reason) }
                    if meetings.speakerModel == .absent, Date().timeIntervalSince(began) > 5 {
                        throw SpeechEngineError.unavailable("The speaker model didn't download. Check your connection and tap Retry.")
                    }
                    if Date().timeIntervalSince(began) > 600 {
                        throw SpeechEngineError.unavailable("The speaker model is taking too long to download. Tap Retry.")
                    }
                    try await Task.sleep(for: .milliseconds(500))
                }
            }
            // The CPU: a few minutes of setup speech embed in about a second, in any app state.
            return try await MeetingDiarizer.loadModels(neuralEngine: false) { _ in }
        }
        models = task
        do { return try await task.value } catch { models = nil; throw error }
    }

    func retryPrint(_ part: VoiceSetup.Part) { makePrint(part) }

    /// Parts that sound like a different person from the rest (`VoiceProfile.strangers`).
    var soundsLikeSomeoneElse: Set<VoiceSetup.Part> {
        VoiceProfile.strangers(in: VoiceSetup.Part.allCases.compactMap { prints[$0] })
    }

    /// Every finished part has its print, or failed.
    var printsSettled: Bool {
        finished.allSatisfy { part in
            switch printStates[part] { case .ready, .failed: return true; default: return false }
        }
    }

    // MARK: Saving

    func save() async {
        guard canSave, !saving else { return }
        saving = true
        defer { saving = false }
        for task in printTasks.values { await task.value }
        // A part that sounds like someone else is left out, so a stranger can never be "me".
        let doubtful = soundsLikeSomeoneElse
        let ready = VoiceSetup.Part.allCases.compactMap { prints[$0] }.filter { !doubtful.contains($0.part) }
        let voiced = ready.filter { $0.part == .read || $0.part == .talk }.reduce(0) { $0 + $1.seconds }
        guard voiced >= VoiceSetup.minimumVoiced else {
            message = doubtful.isEmpty
                ? "Zone couldn't make your voice print. Record the reading or the talking part again."
                : "Your parts sound like different people. Redo the reading and the talking, just you, somewhere quiet."
            return
        }
        let profile = VoiceProfile(model: MeetingDiarizer.modelName, prints: ready, createdAt: Date())
        do {
            try store.save(profile)
        } catch {
            message = "Your voice wasn't saved: \(error.localizedDescription)"
            return
        }
        models = nil
        audio = [:]
        ZoneLog.coordinator.info("voice setup saved: \(ready.map(\.part.rawValue).joined(separator: ","), privacy: .public)")
        earlierMeetings = await meetings.findMe(profile: profile)
        stage = .finished
    }

    func markEarlier() {
        meetings.markRecognizedMe(earlierMeetings)
        markedEarlier = true
        Haptics.success()
    }
}

#if DEBUG
extension VoiceSetupSession {
    /// Simulator dogfooding: `-zoneVoiceSetupAutorun` records every part from `ZONE_SIM_CLIP`
    /// (each recording hears the clip from its start), makes the prints, saves the profile and
    /// looks for the person in earlier meetings, logging each step ("voice setup autorun").
    func autorun() async {
        let log = ZoneLog.coordinator
        log.info("voice setup autorun: begin")
        begin()
        while case .step(let part) = stage {
            let began = Date()
            start(part)
            while !finished.contains(part), Date().timeIntervalSince(began) < 120 {
                if case .failed(let reason) = printStates[part] { log.error("voice setup autorun: \(reason, privacy: .public)") }
                if let message, recorder == .idle { log.error("voice setup autorun: \(part.rawValue, privacy: .public): \(message, privacy: .public)"); break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            log.info("voice setup autorun: \(part.rawValue, privacy: .public) heard \(self.speech[part, default: 0], format: .fixed(precision: 1)) s in \(Date().timeIntervalSince(began), format: .fixed(precision: 1)) s, finished \(self.finished.contains(part))")
            if !finished.contains(part) { skip(part); try? await Task.sleep(for: .milliseconds(500)) }
            if part == .far, finished.contains(part) { advance(from: part) }
        }
        await save()
        let parts = VoiceProfileStore.default.load()?.parts.map(\.rawValue).joined(separator: ",") ?? "none"
        log.info("voice setup autorun: saved parts=\(parts, privacy: .public) earlier=\(self.earlierMeetings.count) message=\(self.message ?? "", privacy: .public)")
    }
}
#endif

/// The capture stream's 100 ms frame levels (`VoiceSetupLevels`), from the audio thread.
final class LevelFramer: @unchecked Sendable {
    static let frameSamples = VoiceSetupLevels.frameSamples
    private let lock = NSLock()
    private var levels = VoiceSetupLevels()

    func add(_ chunk: [Float]) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return levels.add(chunk)
    }
}
