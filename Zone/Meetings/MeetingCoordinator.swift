// by zayd/cold @ zayd.wtf

import AVFoundation
import Foundation
import Observation
import UIKit
import ZoneCore

/// Meeting mode: record up to six hours with the phone on the table, then transcribe it, with
/// speakers labeled when the speaker model is on the phone.
///
/// Recording borrows dictation's capture path (`DictationCoordinator.startMeetingCapture`), so
/// it is the same microphone tap and 16 kHz conversion, and the two never run together. Audio
/// goes straight to disk in PCM parts synced every 5 s; the meeting's metadata says
/// "recording" until it stops, so a crash or a dead battery leaves a recorded meeting that the
/// next launch recovers and transcribes. Transcription runs after the stop, one chunk at a
/// time on the resident speech engine, saving after every chunk, and always yields to
/// dictation: a keyboard tap never waits for a meeting.
@MainActor
@Observable
final class MeetingCoordinator {
    struct Recording: Equatable {
        let id: UUID
        var title: String
        let startedAt: Date
    }

    private(set) var meetings: [Meeting] = []
    private(set) var recording: Recording?
    /// Seconds of audio captured in the current recording (pauses excluded).
    private(set) var recordedSeconds: Double = 0
    /// Recent levels for the wave, oldest first, twenty a second.
    private(set) var levels: [Float] = Array(repeating: 0, count: 48)
    private(set) var isPaused = false
    /// A call or another app took the microphone; recording resumes when it is given back.
    private(set) var isInterrupted = false
    private(set) var recordingWarning: String?
    /// Storage estimate, separate from the recording duration ceiling.
    private(set) var hoursOfSpaceLeft: Double?
    /// 16 kHz mono PCM16: 32,000 bytes a second, about 1.92 MB a minute.
    static let bytesPerSecond: Double = 32_000
    var lastError: String?
    var showsRecorder = false

    /// The meeting being transcribed, what it is doing and how far along it is.
    var transcribingID: UUID? { workQueue.active }
    private(set) var phase = ""
    private(set) var progress: Double = 0 {
        didSet { if let id = transcribingID { continuedProcessing.report(meeting: id, phase: phase, fraction: progress) } }
    }
    var queued: [UUID] { workQueue.pending }

    /// What the transcriber says while it waits for the speaker model download.
    static let downloadPhase = "Downloading the speaker model"

    /// The speaker model on this iPhone.
    enum SpeakerModelState: Equatable {
        case absent
        /// 0...1 of the 21.6 MB.
        case downloading(Double)
        case ready
        case failed(String)
    }
    private(set) var speakerModel: SpeakerModelState = MeetingDiarizer.modelsPresent() ? .ready : .absent
    /// One download, shared by the Meetings screen, the toggle and any transcription waiting on it.
    private let speakerDownload = SingleFlight()
    private var speakerDownloadMovedAt = Date()

    /// 0...1 while the speaker model downloads.
    var speakerModelDownload: Double? {
        if case .downloading(let fraction) = speakerModel { return fraction }
        return nil
    }

    /// True while a transcription is held up by the speaker model download.
    var transcriptionWaitsForSpeakerModel: Bool { transcribingID != nil && phase == Self.downloadPhase }

    /// Label speakers after recording. On by default. Turning it on starts the 21.6 MB download
    /// at once (not at the first transcription); turning it off cancels the download, keeping
    /// what arrived so turning it on again resumes.
    var labelsSpeakers: Bool {
        get { access(keyPath: \.labelsSpeakers); return UserDefaults.standard.object(forKey: Self.labelKey) as? Bool ?? true }
        set {
            withMutation(keyPath: \.labelsSpeakers) { UserDefaults.standard.set(newValue, forKey: Self.labelKey) }
            if newValue { prefetchSpeakerModel() } else { cancelSpeakerModelDownload() }
        }
    }
    private static let labelKey = "zone.meetings.labelSpeakers"

    let store: MeetingStore
    /// Told the id of a meeting the person deleted, or that a merge absorbed. Zone Link uses it
    /// to delete the same meeting on a paired computer. Not called for a recording that was
    /// discarded before it became a meeting.
    @ObservationIgnored var onDelete: ((UUID) -> Void)?
    private let dictation: DictationCoordinator
    @ObservationIgnored private let recover: @Sendable (MeetingStore) async -> Void
    @ObservationIgnored private let requestPermission: @MainActor () async -> Bool
    @ObservationIgnored private let startCapture: @MainActor (@escaping ([Float]) -> Void) async throws -> Void
    @ObservationIgnored private let stopCapture: @MainActor () -> Void
    private var writer: MeetingAudioWriter?
    private var captureProgress = MeetingCaptureProgress()
    private var closingWriters: [Task<String?, Never>] = []
    private var launchTask: Task<Void, Never>?
    private var cancelRecordingStart = false
    private var reloadGeneration = 0
    private var tickTask: Task<Void, Never>?
    @ObservationIgnored private lazy var workQueue = MeetingWorkQueue { [weak self] id in
        await self?.transcribe(id)
    }
    private var cancelRequested: Set<UUID> = []
    private var foreground = true
    /// When each meeting was stopped in this process, for the stop-to-transcript timing log.
    private var stoppedAt: [UUID: Date] = [:]
    private var startingRecording = false
    private var finishingRecording = false
    var isStartingRecording: Bool { startingRecording }
    var isFinishingRecording: Bool { finishingRecording }
    private var speakerAttempt: UUID?
    private var recordingStopNotice: String?
    /// The short Lock Screen line for an automatic stop; nil when the person stopped it.
    private var liveActivityNotice: String?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// Where the current recording lost the microphone, so the transcript can say so.
    private var gapTracker = MeetingGapTracker()
    /// Takes the microphone back after an interruption whose end iOS never announces.
    private var resumeRetry: Task<Void, Never>?
    private var resumingCapture = false
    private let liveActivity = MeetingLiveActivity()
    var hasRecordingLiveActivity: Bool { isRecording && liveActivity.isActive }
    func restoreRecordingLiveActivity() -> Bool {
        guard let recording else { return false }
        if !liveActivity.isActive {
            liveActivity.start(title: recording.title)
            liveActivity.update(state: isInterrupted ? .interrupted : (isPaused ? .paused : .recording),
                                recordedSeconds: exactSeconds)
        }
        return liveActivity.isActive
    }
    private let continuedProcessing = MeetingContinuedProcessing()

    /// The one coordinator, for the meeting App Intents and the Focus filter.
    private(set) static weak var current: MeetingCoordinator?

    init(dictation: DictationCoordinator, store: MeetingStore = .default,
         recover: @escaping @Sendable (MeetingStore) async -> Void = { store in
             _ = await Task.detached(priority: .utility) { store.recoverInterrupted() }.value
         },
         requestPermission: @escaping @MainActor () async -> Bool = {
             if AVAudioApplication.shared.recordPermission == .granted { return true }
             return await AVAudioApplication.requestRecordPermission()
         },
         startCapture: (@MainActor (@escaping ([Float]) -> Void) async throws -> Void)? = nil,
         stopCapture: (@MainActor () -> Void)? = nil) {
        self.dictation = dictation
        self.store = store
        self.recover = recover
        self.requestPermission = requestPermission
        self.startCapture = startCapture ?? { try await dictation.startMeetingCapture(sink: $0) }
        self.stopCapture = stopCapture ?? { dictation.stopMeetingCapture() }
        dictation.onMeetingInterruption = { [weak self] interruption in self?.handleInterruption(interruption) }
        continuedProcessing.onExpiration = { [weak self] in
            guard let self, let id = self.transcribingID else { return }
            self.cancelTranscription(id)
        }
        Self.current = self
        launchTask = Task { await launch() }
    }

    /// Recover anything a previous process left mid-recording or mid-transcription, then
    /// transcribe whatever is waiting.
    private func launch() async {
        await recover(store)
        await reload()
        // Recorded meetings, and once per build the failed ones: every meeting on the phone had
        // failed with the speech-model stall before build 2026110408 fixed it, and a failed
        // meeting was never tried again, so the fix could not show.
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let ids = MeetingLaunchQueue.ids(meetings, currentBuild: build,
                                         lastRetriedBuild: UserDefaults.standard.string(forKey: Self.retriedBuildKey))
        for id in ids {
            if meeting(id)?.status == .failed {
                ZoneLog.coordinator.info("meeting \(id.uuidString.prefix(8), privacy: .public) failed on an earlier build; trying again")
                // Persist the queue before recording the build-level retry marker. A process
                // killed before this item starts must still find it recorded on next launch.
                _ = try? store.update(id) { $0.status = .recorded }
            }
            enqueue(id)
        }
        UserDefaults.standard.set(build, forKey: Self.retriedBuildKey)
        #if DEBUG
        autorunIfAsked()
        #endif
    }

    private static let retriedBuildKey = "zone.meetings.retriedFailedBuild"

    #if DEBUG
    /// Simulator dogfooding: `-zoneMeetingAutorun 45` records a meeting for 45 s once the speech
    /// model is ready, then stops it, so the whole path (record, stop, diarize, transcribe) runs
    /// unattended with `ZONE_SIM_CLIP` and its timings land in the log.
    private func autorunIfAsked() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-zoneMeetingAutorun"), index + 1 < args.count,
              let seconds = Double(args[index + 1]) else { return }
        Task { [weak self] in
            let started = Date()
            while let self, !self.dictation.modelIsReady, Date().timeIntervalSince(started) < 300 {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let self else { return }
            ZoneLog.coordinator.info("meeting autorun: model ready after \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s")
            await self.startRecording(title: "Autorun meeting")
            try? await Task.sleep(for: .seconds(seconds))
            await self.stopRecording()
        }
    }
    #endif

    func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        let store = store
        let all = await Task.detached(priority: .utility) { store.all() }.value
        guard generation == reloadGeneration else { return }
        meetings = all
        releaseOrphans()
    }

    /// A meeting marked "transcribing" that no transcription in this process is working on (a
    /// worker that died, a status written by a task that was torn down) would read
    /// "Transcribing" forever. It goes back to recorded, keeping its finished segments, with a
    /// Transcribe button. The launch recovery does the same for one left by a dead process.
    private func releaseOrphans() {
        let orphans = meetings.filter { $0.status == .transcribing && $0.id != transcribingID }
        guard !orphans.isEmpty else { return }
        for meeting in orphans {
            ZoneLog.coordinator.error("meeting \(meeting.id.uuidString.prefix(8), privacy: .public) was marked transcribing with nothing working on it")
            if let fixed = try? store.update(meeting.id, { meeting in
                guard meeting.status == .transcribing else { return }
                meeting.status = .recorded
                meeting.message = "Transcription was interrupted. Tap Transcribe to continue where it left off."
            }) { replaceInList(fixed) }
        }
    }

    func meeting(_ id: UUID) -> Meeting? { meetings.first { $0.id == id } }

    var isRecording: Bool { recording != nil }

    func scenePhaseChanged(active: Bool) {
        foreground = active
        if active, isInterrupted { Task { await resumeAfterInterruption() } }
        // Back on screen with a transcript under way: ask iOS to let it finish if Zone leaves
        // again (a no-op when already granted or on iOS before 26).
        if active, let id = transcribingID { continuedProcessing.begin(meeting: id, title: meeting(id)?.title) }
        if active { MeetingFocus.applyOnForeground(self) }
    }

    // MARK: Recording

    /// Starts a meeting. `title` is the optional name typed before starting; empty means the
    /// dated default ("Meeting, Nov 2 at 10:04 AM").
    func startRecording(title: String? = nil) async {
        guard recording == nil else { showsRecorder = true; return }
        guard !startingRecording else { return }
        guard !finishingRecording else {
            lastError = "The previous meeting is still saving. Start another when it finishes."
            return
        }
        startingRecording = true
        cancelRecordingStart = false
        defer {
            startingRecording = false
            if recording == nil, !finishingRecording { workQueue.resume() }
        }
        await launchTask?.value
        guard !cancelRecordingStart, !Task.isCancelled else { return }
        lastError = nil
        if let refusal = dictation.meetingStartRefusal { lastError = refusal; return }
        let permissionGranted = await requestPermission()
        guard !cancelRecordingStart, !Task.isCancelled else { return }
        guard permissionGranted else {
            lastError = "Zone needs the microphone to record. Turn it on in Settings."
            return
        }
        do {
            try DiskSpace.ensureRoom(for: MeetingRecordingSafety.reserveBytes, what: "a meeting recording")
            workQueue.suspend()
            MeetingPlayback.current?.stop()
            SpeakerSamplePlayer.current?.stop()
            let name = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let (meeting, writer) = try store.beginRecording(title: name?.isEmpty == false ? name : nil)
            self.writer = writer
            captureProgress = MeetingCaptureProgress()
            do {
                try await startCapture(makeSink(writer))
                // Stop or Discard while the microphone armed: release it and keep nothing.
                if cancelRecordingStart || Task.isCancelled {
                    stopCapture()
                    throw CancellationError()
                }
            } catch {
                self.writer = nil
                try? await writer.finish()
                try? store.delete(meeting.id)
                if error is CancellationError { return }
                throw error
            }
            recording = Recording(id: meeting.id, title: meeting.title, startedAt: Date())
            recordedSeconds = 0
            isPaused = false
            isInterrupted = false
            recordingWarning = nil
            recordingStopNotice = nil
            liveActivityNotice = nil
            gapTracker = MeetingGapTracker()
            MeetingAudioPriority.apply()
            liveActivity.start(title: meeting.title)
            showsRecorder = true
            refreshSpaceLeft()
            startTicking()
            // The transcript follows this recording; fetch the speaker model while it records.
            prefetchSpeakerModel()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            ZoneLog.coordinator.info("meeting \(meeting.id.uuidString.prefix(8), privacy: .public) recording started")
            await reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Renames the meeting being recorded (the title on the recorder).
    func renameRecording(to title: String) {
        guard let current = recording else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != current.title else { return }
        recording?.title = trimmed
        rename(current.id, to: trimmed)
        liveActivity.update(title: trimmed)
    }

    func togglePause() {
        guard recording != nil, !isInterrupted else { return }
        isPaused.toggle()
        let value = isPaused
        captureProgress.setPaused(value)
        liveActivity.update(state: value ? .paused : .recording, recordedSeconds: exactSeconds)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func stopRecording() async {
        if startingRecording, recording == nil { cancelRecordingStart = true; return }
        let gap = gapTracker.close(at: Date())
        guard let (current, writer) = endCapture() else { return }
        finishingRecording = true
        defer {
            finishingRecording = false
            if recording == nil, !startingRecording { workQueue.resume() }
        }
        if let gap { addGap(gap, to: current.id) }
        let closing = closingWriters
        closingWriters.removeAll()
        var saveWarning: String?
        do { try await writer?.finish() } catch { saveWarning = "Some audio may not have been saved: \(error.localizedDescription)" }
        for task in closing { if let warning = await task.value { saveWarning = warning } }
        if let saveWarning { lastError = saveWarning }
        let stopNotice = recordingStopNotice
        recordingStopNotice = nil
        let store = store
        var finished: Meeting?
        let notice = saveWarning ?? stopNotice
        do {
            finished = try await Task.detached(priority: .userInitiated) {
                try store.finishRecording(current.id, recordingNotice: notice)
            }.value
        } catch { lastError = "The audio was kept, but the meeting could not be finalized: \(error.localizedDescription). Reopen Zone to recover it." }
        stoppedAt[current.id] = Date()
        ZoneLog.coordinator.info("meeting \(current.id.uuidString.prefix(8), privacy: .public) stopped, \(finished?.duration ?? 0, format: .fixed(precision: 1)) s of audio")
        if let finished, finished.duration < 1 {
            try? store.delete(current.id)
            lastError = "That recording was under a second, so it was not kept."
        }
        await reload()
        if let finished, finished.duration >= 1 { enqueue(current.id) }
    }

    /// Throws the recording away: capture stops, and the audio and the meeting are deleted.
    /// The recorder asks first.
    func discardRecording() async {
        if startingRecording, recording == nil { cancelRecordingStart = true; return }
        guard let (current, writer) = endCapture() else { return }
        finishingRecording = true
        defer {
            finishingRecording = false
            if recording == nil, !startingRecording { workQueue.resume() }
        }
        let closing = closingWriters
        closingWriters.removeAll()
        try? await writer?.finish()
        for task in closing { _ = await task.value }
        do { try store.delete(current.id) } catch { lastError = "The recording could not be deleted: \(error.localizedDescription)" }
        ZoneLog.coordinator.info("meeting \(current.id.uuidString.prefix(8), privacy: .public) discarded")
        await reload()
    }

    /// Stops capture and clears the recording before any await, so a second tap on Stop (or Stop
    /// then Cancel) finds nothing to stop instead of finishing the same meeting twice.
    private func endCapture() -> (Recording, MeetingAudioWriter?)? {
        guard let current = recording else { return nil }
        tickTask?.cancel()
        tickTask = nil
        resumeRetry?.cancel()
        resumeRetry = nil
        gapTracker = MeetingGapTracker()
        captureProgress.close()
        stopCapture()
        MeetingAudioPriority.restore()
        liveActivity.end(notice: liveActivityNotice)
        liveActivityNotice = nil
        let writer = self.writer
        self.writer = nil
        recording = nil
        isPaused = false
        isInterrupted = false
        levels = Array(repeating: 0, count: levels.count)
        showsRecorder = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        return (current, writer)
    }

    /// The audio thread's only work: drop paused audio, hand the rest to the writer, count it.
    private func makeSink(_ writer: MeetingAudioWriter) -> ([Float]) -> Void {
        let progress = captureProgress
        return { samples in progress.append(samples, to: writer) }
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                guard let self else { return }
                // On screen: 20 updates a second for the wave. Screen off: once a second, no wave.
                try? await Task.sleep(for: .milliseconds(self.foreground ? 50 : 1_000))
                guard !Task.isCancelled, self.recording != nil else { return }
                ticks += 1
                if ticks % (self.foreground ? 100 : 5) == 0 {
                    // One read, off the main thread: the volume query estimates purgeable space
                    // and must not hitch the wave every five seconds.
                    let available = await Task.detached(priority: .utility) { DiskSpace.available() }.value
                    guard !Task.isCancelled, self.recording != nil else { return }
                    self.applySpaceLeft(available)
                    if MeetingRecordingSafety.shouldStop(availableBytes: available) {
                        await self.autoStop(MeetingRecordingSafety.storageMessage, lockScreen: "Saved because storage is low")
                        return
                    }
                }
                if self.captureProgress.reachedLimit {
                    await self.autoStop(MeetingRecordingSafety.limitMessage,
                                        lockScreen: "Saved at the \(MeetingRecordingSafety.maximumLabel) limit")
                    return
                }
                let seconds = Double(self.captureProgress.sampleCount) / 16_000
                self.liveActivity.heartbeat(recordedSeconds: seconds)
                if self.foreground {
                    var next = self.levels
                    next.removeFirst()
                    next.append(self.isPaused || self.isInterrupted ? 0 : min(max(self.dictation.level, 0), 1))
                    // Paused or interrupted, the wave settles to zeros and stops notifying: an
                    // unchanged array must not redraw the full-screen edge 20 times a second.
                    if next != self.levels { self.levels = next }
                    // Whole seconds only: the running clock draws itself (TimelineLabel), and every
                    // change here re-renders the recorder and the space behind it.
                    if Int(seconds) != Int(self.recordedSeconds) { self.recordedSeconds = seconds }
                } else {
                    self.recordedSeconds = seconds
                }
                if let writer = self.writer {
                    if let failure = writer.failure {
                        self.recordingStopNotice = "Recording stopped because audio could not be saved: \(failure.localizedDescription)"
                    } else if writer.droppedSamples > 0 {
                        self.recordingStopNotice = "Recording stopped because the phone could not save audio fast enough. Some audio was skipped."
                    }
                    if let notice = self.recordingStopNotice {
                        self.lastError = notice
                        self.liveActivityNotice = "Saved early: audio could not be written"
                        await self.stopRecording()
                        return
                    }
                }
            }
        }
    }

    /// Zone ended the recording itself; the reason is kept with the meeting and on the Lock Screen.
    private func autoStop(_ notice: String, lockScreen: String) async {
        recordingStopNotice = notice
        lastError = notice
        liveActivityNotice = lockScreen
        await stopRecording()
    }

    /// Recorded audio to the sample, for the Lock Screen timer anchor; `recordedSeconds` is
    /// whole seconds on screen.
    private var exactSeconds: Double { Double(captureProgress.sampleCount) / 16_000 }

    func refreshSpaceLeft() { applySpaceLeft(DiskSpace.available()) }

    private func applySpaceLeft(_ available: Int64?) {
        hoursOfSpaceLeft = available.map { Double(max(0, $0 - MeetingRecordingSafety.reserveBytes)) / Self.bytesPerSecond / 3_600 }
        if isRecording, let available, available <= MeetingRecordingSafety.warningBytes {
            recordingWarning = "Storage is running low. Zone will save and stop before the recording uses the remaining reserve."
        }
    }

    /// "112 hours of space", "40 minutes of space", or nil when the volume will not say.
    var spaceShortLabel: String? {
        guard let hours = hoursOfSpaceLeft else { return nil }
        if hours < 1 { let minutes = max(1, Int(hours * 60)); return "\(minutes) \(minutes == 1 ? "minute" : "minutes") of space" }
        if hours >= 1_000 { return "Over 1,000 hours of space" }
        let rounded = Int(hours.rounded(.down))
        return "\(rounded.formatted()) \(rounded == 1 ? "hour" : "hours") of space"
    }

    /// "About 9 hours of space left", or nil when the volume will not say.
    var spaceLeftLabel: String? {
        guard let hours = hoursOfSpaceLeft else { return nil }
        if hours < 1 { let minutes = max(1, Int(hours * 60)); return "About \(minutes) \(minutes == 1 ? "minute" : "minutes") of space left on this iPhone" }
        if hours >= 100 { return "Over 100 hours of space left on this iPhone" }
        let rounded = Int(hours.rounded(.down))
        return "About \(rounded) \(rounded == 1 ? "hour" : "hours") of space left on this iPhone"
    }

    // MARK: Expectations

    /// The model that writes meeting transcripts: the one picked for dictation.
    var transcriberName: String { dictation.selectedModel.shortName }

    /// Seconds of work per second of audio, learned on this iPhone for the current engine.
    private var learnedRate: Double? {
        _ = learnedRateVersion
        return UserDefaults.standard.object(forKey: Self.rateKey(dictation.engineKind.rawValue)) as? Double
    }
    private var learnedRateVersion = 0
    /// Seconds the current transcription spent in `waitForEngine`, left out of the learned rate.
    @ObservationIgnored private var engineWaitSeconds: Double = 0
    private static func rateKey(_ engine: String) -> String { "zone.meetings.rate.\(engine)" }

    /// About how long transcription takes for this much audio, as words.
    func estimateLabel(forAudio seconds: Double) -> String {
        MeetingEstimate.label(MeetingEstimate.seconds(forAudio: seconds, rate: learnedRate, labelsSpeakers: labelsSpeakers))
    }

    /// About how long is left for the meeting being transcribed, or nil when not transcribing.
    func remainingLabel(_ meeting: Meeting) -> String? {
        guard transcribingID == meeting.id, phase == "Transcribing" || phase == "Finding speakers" else { return nil }
        let done = min(max(progress, 0), 1)
        let transcription = MeetingEstimate.seconds(forAudio: meeting.duration, rate: learnedRate, labelsSpeakers: false)
        let left: Double
        if phase == "Finding speakers" {
            // Progress here is the diarizer's; all of the transcription is still ahead.
            let speakers = MeetingEstimate.seconds(forAudio: meeting.duration, rate: learnedRate, labelsSpeakers: true) - transcription
            left = transcription + max(speakers, 0) * (1 - done)
        } else {
            left = transcription * (1 - done)
        }
        return left < 60 ? "under a minute left" : MeetingEstimate.label(left) + " left"
    }

    private func learnRate(engine: String, seconds: Double, audio: Double) {
        let key = Self.rateKey(engine)
        let previous = UserDefaults.standard.object(forKey: key) as? Double
        guard let next = MeetingEstimate.updatedRate(previous: previous, measuredSeconds: seconds, audioSeconds: audio) else { return }
        UserDefaults.standard.set(next, forKey: key)
        learnedRateVersion += 1
    }

    // MARK: Interruptions

    private func handleInterruption(_ interruption: AudioCaptureEngine.Interruption) {
        guard let current = recording else { return }
        switch interruption {
        case .began, .mediaServicesReset:
            // iOS can send several begin/reset notices for one call. Only the first closes
            // the part; later notices must not lose or replace the held recording.
            guard !isInterrupted else { return }
            isInterrupted = true
            var reason = "mediaServicesReset"
            if case .began(let cause) = interruption { reason = cause }
            gapTracker.began(at: Date(), audioSeconds: Double(captureProgress.sampleCount) / 16_000, reason: reason)
            liveActivity.update(state: .interrupted, recordedSeconds: exactSeconds)
            // Close this part; the audio so far is safe and the meeting continues in a new part.
            let writer = self.writer
            self.writer = nil
            if let writer {
                closingWriters.append(Task {
                    do { try await writer.finish(); return nil }
                    catch { return "Some interrupted audio could not be saved: \(error.localizedDescription)" }
                })
            }
            scheduleResumeRetries()
            if case .mediaServicesReset = interruption {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    await self?.resumeAfterInterruption()
                }
            }
            ZoneLog.audio.info("meeting \(current.id.uuidString.prefix(8), privacy: .public) interrupted")
            Journal.log("meetingHeld", recording: current.id, ["cause": String(describing: interruption)])
        case .ended:
            Task { await resumeAfterInterruption() }
        }
    }

    /// Opens a new audio part and takes the microphone back. From the background iOS may
    /// refuse; the meeting then stays interrupted until Zone is opened again.
    /// The microphone arms off the main thread; one attempt runs at a time.
    func resumeAfterInterruption() async {
        guard let current = recording, isInterrupted, !resumingCapture else { return }
        resumingCapture = true
        defer { resumingCapture = false }
        do {
            let writer = try store.continueRecording(current.id)
            do {
                try await dictation.resumeMeetingCapture(sink: makeSink(writer))
                // Stopped or discarded while the microphone came back.
                guard recording?.id == current.id, isInterrupted else { throw CancellationError() }
            } catch {
                closingWriters.append(Task {
                    do { try await writer.finish(); return nil }
                    catch { return "Some audio could not be saved: \(error.localizedDescription)" }
                })
                throw error
            }
            self.writer = writer
            isInterrupted = false
            recordingWarning = nil
            resumeRetry?.cancel()
            resumeRetry = nil
            MeetingAudioPriority.apply()
            if let gap = gapTracker.ended(at: Date()) { addGap(gap, to: current.id) }
            liveActivity.update(state: isPaused ? .paused : .recording, recordedSeconds: exactSeconds)
            Journal.log("meetingResumed", recording: current.id, ["appState": DictationCoordinator.appStateName()])
        } catch {
            guard recording?.id == current.id else { return }
            recordingWarning = "Recording stopped for a call or another app. Zone takes the microphone back as soon as iOS allows; open Zone and tap Resume to do it now."
            Journal.log("meetingResumeFailed", recording: current.id,
                        ["error": JournalFormat.error(error), "appState": DictationCoordinator.appStateName()])
        }
    }

    /// iOS announces the end of most interruptions, and `.ended` resumes at once. Some never
    /// end with a notice (another app that records and quits, a failed engine restart), so
    /// while the meeting is held Zone keeps asking for the microphone back, at 2, 5, 10, 20 and
    /// then every 30 seconds. A request during a call simply fails; nothing is taken from it.
    private func scheduleResumeRetries() {
        resumeRetry?.cancel()
        resumeRetry = Task { [weak self] in
            var attempt = 0
            while true {
                try? await Task.sleep(for: .seconds(MeetingResumeSchedule.delay(attempt: attempt)))
                attempt += 1
                guard !Task.isCancelled, let self, self.recording != nil, self.isInterrupted else { return }
                await self.resumeAfterInterruption()
            }
        }
    }

    private func addGap(_ gap: MeetingGap, to id: UUID) {
        ZoneLog.coordinator.info("meeting \(id.uuidString.prefix(8), privacy: .public) gap of \(gap.seconds, format: .fixed(precision: 1)) s at \(gap.at, format: .fixed(precision: 1)) s (\(gap.reason, privacy: .public))")
        Journal.log("meetingGap", recording: id, ["seconds": JournalFormat.seconds(gap.seconds), "reason": gap.reason])
        if let updated = try? store.update(id, { $0.gaps = ($0.gaps ?? []) + [gap] }) { replaceInList(updated) }
    }

    // MARK: Editing

    func rename(_ id: UUID, to title: String) { mutate { try $0.rename(id, to: title) } }
    func renameSpeaker(_ id: UUID, speaker: String, to name: String) { mutate { try $0.renameSpeaker(id, speaker: speaker, to: name) } }
    func setMe(_ id: UUID, speaker: String?) { mutate { try $0.setMe(id, speaker: speaker) } }

    func editTranscript(_ id: UUID, original: [MeetingSegment], texts: [String]) throws {
        replaceInList(try store.editTranscript(id, original: original, texts: texts))
    }

    func delete(_ id: UUID) {
        cancelTranscription(id)
        mutate {
            try $0.delete(id)
            onDelete?(id)
        }
    }

    /// Joins two meetings (earlier first) and transcribes whatever of the result is not yet.
    func merge(_ id: UUID, with other: UUID) -> UUID? {
        do {
            guard transcribingID != id, transcribingID != other else { throw MeetingStoreError.busy }
            let merged = try store.merge(id, other)
            // The later meeting is gone: its words now live in the merged one.
            onDelete?(merged.id == id ? other : id)
            workQueue.cancel(id)
            workQueue.cancel(other)
            Task {
                await reload()
                if merged.status != .done { enqueue(merged.id) }
            }
            return merged.id
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func retranscribe(_ id: UUID, expectedSpeakerCount: Int? = nil) {
        guard transcribingID != id else { return }
        do {
            try store.resetTranscript(id, expectedSpeakerCount: expectedSpeakerCount)
            enqueue(id)
            Task { await reload() }
        } catch { lastError = error.localizedDescription }
    }

    private func mutate(_ body: (MeetingStore) throws -> Void) {
        do { try body(store) } catch { lastError = error.localizedDescription }
        Task { await reload() }
    }

    // MARK: Speaker model

    /// Starts the speaker model download if labels are on and the model is missing. Safe to
    /// call from every appear and every toggle: a running download is joined, not restarted.
    func prefetchSpeakerModel() {
        guard labelsSpeakers else { return }
        if MeetingDiarizer.modelsPresent() {
            speakerModel = .ready
            return
        }
        let started = speakerDownload.start({
            try await MeetingDiarizer.download { fraction in
                Task { @MainActor [weak self] in self?.speakerModelProgress(fraction) }
            }
        }, finished: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.speakerModel = MeetingDiarizer.modelsPresent() ? .ready : .absent
                ZoneLog.coordinator.info("speaker model downloaded")
            case .failure(let error):
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    self.speakerModel = .absent
                } else {
                    self.speakerModel = .failed("The speaker model didn't download: \(error.localizedDescription)")
                    ZoneLog.coordinator.error("speaker model download failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        })
        if started {
            speakerModel = .downloading(0)
            speakerDownloadMovedAt = Date()
            ZoneLog.coordinator.info("speaker model download started")
        }
    }

    func cancelSpeakerModelDownload() {
        speakerDownload.cancel()
        if case .downloading = speakerModel { speakerModel = .absent }
    }

    private func speakerModelProgress(_ fraction: Double) {
        // Late updates after a cancel or the finish are ignored.
        guard case .downloading(let current) = speakerModel, speakerDownload.isRunning else { return }
        if fraction > current { speakerDownloadMovedAt = Date() }
        speakerModel = .downloading(max(current, fraction))
    }

    /// Holds a transcription until the speaker model is on the phone. Never waits forever:
    /// Pause, turning labels off, a failed download (after one retry) or a download that stops
    /// moving for 90 s all end the wait.
    private func waitForSpeakerModel(id: UUID) async throws {
        var attempts = 0
        phase = Self.downloadPhase
        while !MeetingDiarizer.modelsPresent() {
            if cancelRequested.contains(id) { throw Stop.cancelled }
            guard labelsSpeakers else { throw Stop.speakersOff }
            if speakerDownload.isRunning {
                if Date().timeIntervalSince(speakerDownloadMovedAt) > 90 {
                    cancelSpeakerModelDownload()
                    speakerModel = .failed("The speaker model download stopped moving. Check the connection.")
                }
            } else {
                if attempts >= 2 {
                    if case .failed(let message) = speakerModel { throw SpeechEngineError.unavailable(message) }
                    throw SpeechEngineError.unavailable("The speaker model didn't download.")
                }
                attempts += 1
                prefetchSpeakerModel()
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        speakerModel = .ready
    }

    // MARK: Transcription

    func enqueue(_ id: UUID) {
        guard transcribingID != id, !queued.contains(id) else { return }
        cancelRequested.remove(id)
        workQueue.enqueue(id)
    }

    /// Wait for current processing to unwind; a suspended recording queue stays suspended.
    func drainProcessing() async { await workQueue.drain() }

    func cancelTranscription(_ id: UUID) {
        if transcribingID == id { cancelRequested.insert(id) }
        workQueue.cancel(id)
    }

    private enum Stop: Error { case cancelled, missingModel, speakersOff }

    /// Generous limits: a stalled step fails the meeting with a message instead of sitting at a
    /// percentage forever. The speech model gets 30 s plus twice the chunk's length to finish a
    /// chunk of at most 28 s, and 30 s to take any audio at all.
    private static let chunkFeedStall: TimeInterval = 30
    private static func chunkFinishLimit(_ chunk: MeetingChunk) -> TimeInterval { 30 + 2 * (chunk.end - chunk.start) }
    /// Loading (and compiling) the four speaker models, and diarizing without a progress update.
    private static let speakerLoadLimit: TimeInterval = 120
    private static let diarizeStall: TimeInterval = 180

    private func transcribe(_ id: UUID) async {
        guard !Task.isCancelled, !cancelRequested.contains(id) else { return }
        let store = store
        guard var meeting = try? store.meeting(id), meeting.status != .recording, meeting.duration > 0 else { return }
        phase = "Getting ready"
        progress = meeting.progress
        beginBackgroundTime()
        continuedProcessing.begin(meeting: id, title: meeting.title)
        defer {
            phase = ""
            cancelRequested.remove(id)
            endBackgroundTime()
            continuedProcessing.finish(meeting: id, success: (try? store.meeting(id))?.status == .done)
        }
        var note = meeting.speakerNotice
        do {
            meeting = try store.update(id) { $0.status = .transcribing; $0.message = nil }
            await reload()
            try await waitForEngine()
            let audio = try await Task.detached(priority: .utility) { try store.audio(id) }.value
            try Task.checkCancellation()
            let from = meeting.transcribedThrough, to = audio.duration

            // 1. Who spoke when, once per untranscribed stretch.
            var turns = meeting.turns ?? []
            if meeting.turns == nil {
                // The diarizer's own bound: the stretch still to label, not the whole meeting.
                if labelsSpeakers, to - from > MeetingRecordingSafety.maximumSpeakerSeconds {
                    note = from > 0 ? MeetingRecordingSafety.speakerLimitPartMessage : MeetingRecordingSafety.speakerLimitMessage
                } else if labelsSpeakers, to - from >= 2, MeetingDiarizer.modelsPresent() {
                    do {
                        let started = Date()
                        turns = try await findSpeakers(audio: audio, from: from, to: to,
                                                       existing: from > 0 ? meeting.speakers : [], id: id,
                                                       expectedSpeakerCount: from == 0 ? meeting.speakerCountHint : nil)
                        ZoneLog.coordinator.info("meeting diarized \(Int(to - from)) s of audio in \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s, \(Set(turns.compactMap(\.speaker)).count) speakers")
                    } catch Stop.cancelled {
                        throw Stop.cancelled
                    } catch is CancellationError {
                        throw Stop.cancelled
                    } catch Stop.speakersOff {
                        // Turned off while the model downloaded: one undivided transcript.
                        turns = []
                    } catch {
                        turns = []
                        note = "Speakers were not labeled: \(error.localizedDescription)."
                        ZoneLog.coordinator.error("diarization failed: \(error.localizedDescription, privacy: .public)")
                    }
                } else if labelsSpeakers, !MeetingDiarizer.modelsPresent() {
                    // Speech is useful immediately. A speaker-model download must not hold
                    // the entire transcript hostage to a slow or unavailable connection.
                    prefetchSpeakerModel()
                    note = "Transcript saved without speaker labels. When the speaker model finishes downloading, use Transcribe again to add labels."
                }
                let saved = turns
                meeting = try store.update(id) { $0.turns = saved; $0.speakerNotice = note }
            }

            // 2. Chunks cut at pauses, silence skipped.
            let transcribeStarted = Date()
            engineWaitSeconds = 0
            phase = "Transcribing"
            // Start from what is already transcribed, not from the diarizer's last figure: that
            // left a meeting reading "Transcribing, 100%" before its first chunk was done.
            progress = to > 0 ? min(from / to, 1) : 0
            let scan = Task.detached(priority: .utility) {
                try audio.levels(frameSamples: 1_600)
            }
            let levels = try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
            let chunks = MeetingChunkPlanner.splitting(
                MeetingChunkPlanner.plan(turns: turns, levels: levels, from: from, to: to),
                at: (meeting.gaps ?? []).map(\.at))
            try Task.checkCancellation()
            for chunk in chunks {
                try Task.checkCancellation()
                if cancelRequested.contains(id) { throw Stop.cancelled }
                // Only the pronoun fix, not a dictation style: someone saying "new line" in a
                // meeting is talking, not giving a command.
                let text = TextStyle.capitalizingPronounI(try await transcribeChunk(audio: audio, chunk: chunk, id: id))
                let fraction = max(progress, to > 0 ? min(chunk.end / to, 1) : 1)
                meeting = try store.update(id) { meeting in
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        meeting.segments.append(MeetingSegment(start: chunk.start, end: chunk.end, speaker: chunk.speaker, text: text))
                    }
                    meeting.transcribedThrough = max(meeting.transcribedThrough, chunk.end)
                    meeting.progress = fraction
                }
                progress = fraction
                replaceInList(meeting)
            }
            try Task.checkCancellation()
            let engineName = dictation.engineKind.rawValue
            let diarizerName = turns.isEmpty ? nil : MeetingDiarizer.modelName
            // Working time only: waiting on a recording or a dictation for the engine is not speed.
            let transcribeSeconds = max(Date().timeIntervalSince(transcribeStarted) - engineWaitSeconds, 0)
            ZoneLog.coordinator.info("meeting transcribed \(Int(to - from)) s of audio in \(chunks.count) chunks, \(transcribeSeconds, format: .fixed(precision: 1)) s, engine \(engineName, privacy: .public)")
            learnRate(engine: engineName, seconds: transcribeSeconds, audio: to - from)
            if let stopped = stoppedAt.removeValue(forKey: id) {
                ZoneLog.coordinator.info("meeting \(id.uuidString.prefix(8), privacy: .public) done \(Date().timeIntervalSince(stopped), format: .fixed(precision: 1)) s after stop, \(meeting.segments.count) segments, \(Set(meeting.segments.compactMap(\.speaker)).count) speakers")
            }
            let finalNote = note
            meeting = try store.update(id) { meeting in
                meeting.transcribedThrough = to
                meeting.progress = 1
                meeting.turns = nil
                meeting.engine = engineName
                // Earlier stretches of a resumed or merged meeting keep the speaker model they had.
                if let diarizerName { meeting.diarizer = diarizerName }
                meeting.message = finalNote ?? (meeting.segments.isEmpty ? "No speech was recognized in this recording." : nil)
                meeting.status = .done
            }
            // A transcript with words and no speaker-label problem counts for the rating prompt.
            if finalNote == nil, !meeting.segments.isEmpty {
                dictation.reviews.recordSuccess(onScreen: UIApplication.shared.applicationState == .active)
            }
        } catch where error as? Stop == .cancelled || error is CancellationError {
            // Cancelled for a new recording: still queued, and resumes on its own when it stops.
            let message = workQueue.isSuspended
                ? "Paused while a meeting records. Continues when it stops."
                : "Transcription paused. Tap Transcribe to continue."
            _ = try? store.update(id) { $0.status = .recorded; $0.message = message }
        } catch {
            let message = (error as? Stop) == .missingModel
                ? "Download a speech model in Settings, then tap Transcribe."
                : "Transcription stopped: \(error.localizedDescription). Tap Transcribe to continue where it left off."
            ZoneLog.coordinator.error("meeting transcription failed: \(error.localizedDescription, privacy: .public)")
            _ = try? store.update(id) { $0.status = .failed; $0.message = message }
        }
        await reload()
    }

    private func findSpeakers(audio: MeetingAudio, from: Double, to: Double, existing: [MeetingSpeaker], id: UUID,
                              expectedSpeakerCount: Int?) async throws -> [MeetingTurn] {
        if !MeetingDiarizer.modelsPresent() { try await waitForSpeakerModel(id: id) }
        phase = "Loading the speaker model"
        // The Neural Engine only while Zone is on screen; in the background it fails without a
        // paid entitlement, so a failure there is retried once on the CPU.
        defer { speakerAttempt = nil }
        var useNeuralEngine = UIApplication.shared.applicationState == .active
        var raw: [MeetingTurn] = []
        for attempt in 0..<2 {
            let attemptID = UUID()
            speakerAttempt = attemptID
            do {
                let neuralEngine = useNeuralEngine
                let models = try await Watchdog.run(what: "The speaker model", limit: Self.speakerLoadLimit) {
                    try await MeetingDiarizer.loadModels(neuralEngine: neuralEngine) { _ in }
                }
                if cancelRequested.contains(id) { throw Stop.cancelled }
                phase = "Finding speakers"
                progress = 0
                let pulse = Watchdog.Pulse()
                raw = try await Watchdog.run(what: "Finding speakers", limit: Self.diarizeStall, pulse: pulse) {
                    try await MeetingDiarizer.turns(audio: audio, from: from, to: to, models: models,
                                                   expectedSpeakerCount: expectedSpeakerCount) { fraction in
                        pulse.beat()
                        Task { @MainActor [weak self] in
                            guard let self, self.transcribingID == id, self.speakerAttempt == attemptID, self.phase == "Finding speakers" else { return }
                            self.progress = fraction
                        }
                    }
                }
                break
            } catch Stop.cancelled {
                throw Stop.cancelled
            } catch is CancellationError {
                throw Stop.cancelled
            } catch {
                guard attempt == 0, useNeuralEngine, !(error is Watchdog.Stalled) else { throw error }
                useNeuralEngine = false
            }
        }
        let normalized = MeetingSpeakerLabels.normalize(raw, existing: existing)
        let speakers = normalized.speakers
        _ = try store.update(id) { $0.speakers = speakers }
        return normalized.turns
    }

    /// Waits until the speech model is loaded and dictation is not using it. Never takes the
    /// engine from a dictation, and holds off while a new meeting is recording.
    private func waitForEngine() async throws {
        let began = Date()
        defer { engineWaitSeconds += Date().timeIntervalSince(began) }
        var askedToPrepare = false
        var waitingForModelSince: Date?
        while !dictation.engineIsFreeForMeetings || recording != nil {
            if let id = transcribingID, cancelRequested.contains(id) { throw Stop.cancelled }
            try Task.checkCancellation()
            if !dictation.modelIsReady {
                switch dictation.modelState {
                case .missing:
                    // A removed model stays removed. Background/queued work must not
                    // silently download hundreds of MB again after storage cleanup.
                    throw Stop.missingModel
                case .failed:
                    if askedToPrepare || !dictation.modelIsDownloaded(dictation.selectedModel) { throw Stop.missingModel }
                    askedToPrepare = true
                    dictation.prepareModel()
                case .loading where !dictation.isPreparingModel:
                    // "Loading" with nothing loading (the model was unloaded): this wait used to
                    // spin forever. Ask for it once more.
                    dictation.prepareModel()
                default: break
                }
                let since = waitingForModelSince ?? Date()
                waitingForModelSince = since
                if case .downloading = dictation.modelState {} else if Date().timeIntervalSince(since) > 180 {
                    throw Watchdog.Stalled(what: "The speech model", seconds: 180)
                }
                phase = "Waiting for the speech model"
            } else if recording != nil {
                waitingForModelSince = nil
                phase = "Waits until this recording stops"
            } else {
                waitingForModelSince = nil
                phase = "Paused while you dictate"
            }
            try await Task.sleep(for: .milliseconds(400))
        }
        phase = "Transcribing"
    }

    private func transcribeChunk(audio: MeetingAudio, chunk: MeetingChunk, id: UUID) async throws -> String {
        while true {
            try await waitForEngine()
            try Task.checkCancellation()
            let session = try dictation.makeMeetingUtterance()
            defer { session.cancel() }
            var offset = Int(chunk.start * 16_000)
            let end = min(Int(chunk.end * 16_000), audio.sampleCount)
            var yielded = false
            var lastAvailable = session.availableAudioSamples
            var movedAt = Date()
            while offset < end {
                try Task.checkCancellation()
                if cancelRequested.contains(id) { session.cancel(); throw Stop.cancelled }
                if !dictation.engineIsFreeForMeetings || recording != nil {
                    // Dictation started: give the engine back at once and redo this chunk later.
                    session.cancel()
                    yielded = true
                    break
                }
                if let failure = session.failure { session.cancel(); throw failure }
                let available = session.availableAudioSamples
                if available != lastAvailable { lastAvailable = available; movedAt = Date() }
                let count = min(8_000, end - offset)
                // Wait only when the session has no room for the next read. A batch model
                // (Fluid Speech Mini, Parakeet) holds audio until a whole segment is cut, about
                // 20 s or a pause, so capping the queue at one second meant the buffer could
                // never drain and every meeting failed after 30 s with "The speech model did
                // not respond" once Heavy became the engine (four meetings on the phone,
                // 2026-11-01 to 2026-11-03, all at 0%). The capacity (48 s) is above any chunk
                // (28 s), so this only waits on a model that has truly stopped, and a dictation
                // still gets the engine back at once through the cancel above.
                if available < count {
                    if Date().timeIntervalSince(movedAt) > Self.chunkFeedStall {
                        session.cancel()
                        throw Watchdog.Stalled(what: "The speech model", seconds: Self.chunkFeedStall)
                    }
                    try await Task.sleep(for: .milliseconds(15))
                    continue
                }
                let start = offset
                let samples = try await Task.detached(priority: .utility) { try audio.read(offset: start, count: count) }.value
                try Task.checkCancellation()
                if !dictation.engineIsFreeForMeetings || recording != nil {
                    session.cancel()
                    yielded = true
                    break
                }
                session.feed(samples)
                offset += count
            }
            if yielded { continue }
            do {
                return try await Watchdog.run(what: "The speech model", limit: Self.chunkFinishLimit(chunk)) {
                    try await session.finish()
                }
            } catch {
                session.cancel()
                throw error
            }
        }
    }

    private func replaceInList(_ meeting: Meeting) {
        reloadGeneration += 1
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) { meetings[index] = meeting }
    }

    /// A little time after the person leaves Zone. When dictation is on, the armed audio
    /// session keeps Zone running anyway; when it is off, iOS suspends Zone after this and the
    /// work resumes from the last saved chunk when Zone is opened.
    private func beginBackgroundTime() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Meeting transcript") { [weak self] in
            self?.endBackgroundTime()
        }
    }

    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
