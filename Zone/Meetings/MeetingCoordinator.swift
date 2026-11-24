// by zayd/cold @ zayd.wtf

import AVFoundation
import ActivityKit
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
    private(set) var levels: [Float] = Array(repeating: 0, count: MeetingWaveSignal.count)
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

    /// What the queue says while it compares the voices of merged recordings. The transcript
    /// is finished and readable meanwhile; only who-is-who can still change.
    static let matchPhase = "Matching voices"
    /// True while the voices of this merged meeting are being compared.
    func isMatchingVoices(_ id: UUID) -> Bool {
        guard transcribingID == id || queued.contains(id), let current = meeting(id) else { return false }
        return current.status == .done && current.speakerGroupsToMatch != nil
    }

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

    /// Give speakers the names typed for their voices in other meetings (`MeetingKnownVoices`).
    /// On by default; it only ever reuses names the person typed.
    var recognizesVoices: Bool {
        get { access(keyPath: \.recognizesVoices); return UserDefaults.standard.object(forKey: Self.recognizeKey) as? Bool ?? true }
        set { withMutation(keyPath: \.recognizesVoices) { UserDefaults.standard.set(newValue, forKey: Self.recognizeKey) } }
    }
    private static let recognizeKey = "zone.meetings.recognizeVoices"

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
    /// Voice prints for stretches of a meeting's audio, per voice; nil when the speaker model
    /// is not on the phone. Tests pass their own.
    typealias VoicePrinter = @MainActor (MeetingAudio, [String: [Range<Double>]]) async throws -> [String: [Float]]?
    @ObservationIgnored private let voicePrinter: VoicePrinter
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
    var blocksLibraryDeletion: Bool { startingRecording || isRecording || finishingRecording }
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
    private let liveActivity: MeetingLiveActivity
    var hasRecordingLiveActivity: Bool { isRecording && liveActivity.isActive }
    func restoreRecordingLiveActivity() -> Bool {
        guard let recording else { return false }
        if !liveActivity.isActive {
            liveActivity.start(title: recording.title,
                               state: isInterrupted ? .interrupted : (isPaused ? .paused : .recording),
                               recordedSeconds: exactSeconds)
        }
        return liveActivity.isActive
    }
    func refreshIslandAppearance() { liveActivity.refreshAppearance() }

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
         stopCapture: (@MainActor () -> Void)? = nil,
         voicePrinter: VoicePrinter? = nil) {
        self.voicePrinter = voicePrinter ?? { audio, spans in try await MeetingCoordinator.listen(to: audio, spans: spans) }
        self.dictation = dictation
        liveActivity = MeetingLiveActivity { dictation.meetingIslandColors }
        self.store = store
        self.recover = recover
        self.requestPermission = requestPermission
        self.startCapture = startCapture ?? { try await dictation.startMeetingCapture(sink: $0) }
        self.stopCapture = stopCapture ?? { dictation.stopMeetingCapture() }
        dictation.onMeetingLevel = { [weak self] level in
            self?.liveActivity.appendLevel(level)
        }
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
        #if DEBUG
        let seeded = store
        await Task.detached(priority: .userInitiated) { MeetingDebugSeed.runIfAsked(seeded) }.value
        #endif
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
        // A merge whose voices were still being compared when Zone closed picks up here.
        for meeting in meetings where meeting.status == .done && meeting.speakerGroupsToMatch != nil {
            enqueue(meeting.id)
        }
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
        if args.contains("-zoneVoiceSetupAutorun") {
            let session = VoiceSetupSession(dictation: dictation, meetings: self)
            Task { await session.autorun() }
        }
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
            #if targetEnvironment(simulator)
            if let index = args.firstIndex(of: "-zoneMeetingRebuildAt"), index + 1 < args.count,
               let delay = Double(args[index + 1]), delay.isFinite, delay > 0, delay < seconds {
                Task { await self.rebuildCardAfterSimulatedInterruption(delay: delay) }
            }
            #endif
            try? await Task.sleep(for: .seconds(seconds))
            await self.stopRecording()
        }
    }
    #if targetEnvironment(simulator)
    /// Exercise the coordinator's hold and resume handlers with an expired card for screenshots.
    private func rebuildCardAfterSimulatedInterruption(delay: Double) async {
        let id = recording?.id
        try? await Task.sleep(for: .seconds(delay))
        guard let id, recording?.id == id, !isInterrupted else { return }
        handleInterruption(.began(reason: "Simulator fixture"))
        resumeRetry?.cancel()
        resumeRetry = nil
        for activity in Activity<RecordingActivityAttributes>.activities
        where activity.content.state.meetingTitle == recording?.title {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        let deadline = Date().addingTimeInterval(3)
        while liveActivity.isActive, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        handleInterruption(.ended(shouldResume: true))
    }
    #endif
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
        if active, isInterrupted {
            Task { await resumeAfterInterruption() }
        } else if active, isRecording {
            _ = restoreRecordingLiveActivity()
        }
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
        dictation.publishMicrophoneGrant()
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
            if liveActivity.isActive {
                liveActivity.update(state: isPaused ? .paused : .recording, recordedSeconds: exactSeconds)
            } else {
                _ = restoreRecordingLiveActivity()
            }
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
    // MARK: Speakers

    /// The speakers as they were before the last change to who is who in a meeting, for Undo.
    struct SpeakerUndo: Equatable {
        let meeting: UUID
        let speakers: [MeetingSpeaker]
        /// What Undo takes back, as the bar says it: "Combined Speaker 3 with Me".
        let what: String
        var review: ReviewUndo?
    }

    struct ReviewUndo: Equatable {
        let candidates: [String: [String]]
        let pendingGroups: [[String]]?
        let showedNotice: Bool
        let confirmedSpeakers: [MeetingSpeaker]
    }
    private(set) var speakerUndo: SpeakerUndo?

    /// Every change to who is who goes through here: the list on screen updates at once (a
    /// store reload would lag a tap behind), and the state before it is kept for Undo.
    private func editSpeakers(_ id: UUID, what: String, _ change: (MeetingStore) throws -> Meeting) {
        guard let before = meeting(id) ?? (try? store.meeting(id)) else { return }
        do {
            let after = try change(store)
            replaceInList(after)
            if after.speakers != before.speakers { speakerUndo = SpeakerUndo(meeting: id, speakers: before.speakers, what: what) }
        } catch { lastError = error.localizedDescription }
    }

    func renameSpeaker(_ id: UUID, speaker: String, to name: String, sharesName: Bool = false) {
        let old = meeting(id)?.speakerName(speaker) ?? "Speaker"
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        editSpeakers(id, what: trimmed.isEmpty ? "Cleared \(old)'s name" : "Named \(old) \(trimmed)") {
            try $0.renameSpeaker(id, speaker: speaker, to: name, sharesName: sharesName)
        }
    }

    /// Marks a speaker as the phone's owner. When someone else already is, the two are joined
    /// as one person (`MeetingStore.setMe`); `moveMe` is the other answer.
    func setMe(_ id: UUID, speaker: String?) {
        let old = speaker.flatMap { meeting(id)?.speakerName($0) } ?? "Me"
        let joins = speaker != nil && meeting(id)?.me(except: speaker) != nil
        editSpeakers(id, what: speaker == nil ? "Cleared Me" : (joins ? "Combined \(old) with Me" : "Marked \(old) as Me")) {
            try $0.setMe(id, speaker: speaker)
        }
    }

    /// Makes this speaker the only "me": whoever had it was someone else.
    func moveMe(_ id: UUID, to speaker: String) {
        let old = meeting(id)?.speakerName(speaker) ?? "Speaker"
        editSpeakers(id, what: "Moved Me to \(old)") { try $0.moveMe(id, to: speaker) }
    }

    /// Two speakers are one person: `speaker`'s lines show under `target`.
    func joinSpeakers(_ id: UUID, speaker: String, into target: String) {
        let from = meeting(id)?.speakerName(speaker) ?? "Speaker", to = meeting(id)?.speakerName(target) ?? "Speaker"
        editSpeakers(id, what: "Combined \(from) with \(to)") { try $0.joinSpeakers(id, speaker: speaker, into: target) }
    }

    /// A voice that was joined to someone is its own speaker again.
    func separateSpeaker(_ id: UUID, speaker: String) {
        let from = meeting(id)?.speakerName(speaker) ?? "Speaker"
        editSpeakers(id, what: "Separated a voice from \(from)") { try $0.separateSpeaker(id, speaker: speaker) }
    }

    /// Names typed for people in other meetings, newest meeting first, without the ones already
    /// in this meeting: offered on the Speakers screen so a name used before is one tap.
    func speakerNames(notIn id: UUID, limit: Int = 6) -> [String] {
        let here = Set((meeting(id)?.people ?? []).compactMap { $0.name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        var names: [String] = []
        for other in meetings.sorted(by: { $0.createdAt > $1.createdAt }) where other.id != id {
            for person in other.people {
                guard let name = person.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                      !here.contains(name.lowercased()), !names.contains(where: { $0.lowercased() == name.lowercased() }) else { continue }
                names.append(name)
                if names.count == limit { return names }
            }
        }
        return names
    }

    func undoSpeakerChange() {
        guard let undo = speakerUndo else { return }
        speakerUndo = nil
        do {
            let restored = try store.update(undo.meeting) { meeting in
                if let review = undo.review {
                    guard meeting.speakers == review.confirmedSpeakers, meeting.voiceReviewCandidates == nil,
                          meeting.speakerGroupsToMatch == nil else { throw MeetingStoreError.transcriptChanged }
                    meeting.voiceReviewCandidates = review.candidates
                    meeting.speakerGroupsToMatch = review.pendingGroups
                    if review.showedNotice && meeting.message == nil { meeting.message = MeetingVoiceMatch.unmatchedMessage }
                }
                guard MeetingSpeakerEdit.restore(undo.speakers, in: &meeting) else { throw MeetingStoreError.transcriptChanged }
            }
            replaceInList(restored)
        } catch { lastError = error.localizedDescription }
    }

    func forgetSpeakerUndo() { speakerUndo = nil }

    // MARK: Matching voices after a merge

    /// The default `voicePrinter`: the speaker model, on the Neural Engine while Zone is on
    /// screen and on the CPU otherwise (and once more on the CPU when the Neural Engine fails,
    /// as labeling does). Nil when the model is not on the phone.
    private static func listen(to audio: MeetingAudio, spans: [String: [Range<Double>]]) async throws -> [String: [Float]]? {
        guard MeetingDiarizer.modelsPresent() else { return nil }
        var neuralEngine = UIApplication.shared.applicationState == .active
        while true {
            do {
                let units = neuralEngine
                let models = try await Watchdog.run(what: "The speaker model", limit: speakerLoadLimit) {
                    try await MeetingDiarizer.loadModels(neuralEngine: units) { _ in }
                }
                return try await Watchdog.run(what: "Matching voices", limit: diarizeStall) {
                    try await MeetingDiarizer.voicePrints(audio: audio, spans: spans, models: models)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard neuralEngine, !(error is Watchdog.Stalled) else { throw error }
                neuralEngine = false
            }
        }
    }

    /// Compares the voices a merge brought in with the people already in the meeting and joins
    /// the ones that match (`MeetingVoiceMatch`). Voices labeled before prints were kept are
    /// listened to first: a few of each one's longest lines, seconds of work, with no new
    /// transcript. Interrupted (a recording starts, Zone closes), it leaves the waiting list on
    /// disk and runs again; nothing is lost and the transcript reads as before meanwhile.
    private func matchVoices(_ id: UUID) async {
        let store = store
        guard let meeting = try? store.meeting(id), meeting.status == .done, meeting.speakerGroupsToMatch != nil else { return }
        phase = Self.matchPhase
        progress = 0
        beginBackgroundTime()
        defer { phase = ""; endBackgroundTime() }
        let started = Date()
        var listened = 0
        var waitingForPrints = false
        for attempt in 1...2 {
            do {
                let current = try store.meeting(id)
                let needed = MeetingVoiceMatch.voicesNeedingPrints(in: current)
                let spans = Dictionary(uniqueKeysWithValues: needed.map {
                    ($0, MeetingVoiceMatch.spans(forVoice: $0, in: current.segments))
                }).filter { spans in
                    spans.value.reduce(0) { $0 + $1.upperBound - $1.lowerBound } >= MeetingVoiceMatch.minimumPrintSeconds
                }
                guard !spans.isEmpty else { waitingForPrints = false; break }
                waitingForPrints = true
                let audio = try await Task.detached(priority: .utility) { try store.audio(id) }.value
                try Task.checkCancellation()
                guard let prints = try await voicePrinter(audio, spans) else { break }
                try Task.checkCancellation()
                let saved = try store.update(id) { meeting in
                    for index in meeting.speakers.indices where !MeetingVoiceMatch.usablePrint(meeting.speakers[index].voice) {
                        let key = meeting.speakers[index].id
                        if spans[key] != nil, let print = prints[key], MeetingVoiceMatch.usablePrint(print) {
                            meeting.speakers[index].voice = print
                            listened += 1
                        }
                    }
                }
                waitingForPrints = MeetingVoiceMatch.voicesNeedingPrints(in: saved).contains { spans[$0] != nil }
                if !waitingForPrints { break }
            } catch is CancellationError {
                return
            } catch {
                waitingForPrints = true
                ZoneLog.coordinator.error("voice match attempt \(attempt) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard !Task.isCancelled else { return }
        var outcome = MeetingVoiceMatch.Outcome()
        var before: [MeetingSpeaker] = []
        if let updated = try? store.update(id, { meeting in
            before = meeting.speakers
            let groups = meeting.speakerGroupsToMatch
            outcome = MeetingVoiceMatch.resolve(&meeting)
            if waitingForPrints && !outcome.unmatched.isEmpty { meeting.speakerGroupsToMatch = groups }
            meeting.message = meeting.voiceReviewCandidates == nil ? nil : MeetingVoiceMatch.unmatchedMessage
        }) {
            replaceInList(updated)
            // Zone decided this, so it is one tap to take back.
            if !outcome.joined.isEmpty {
                let count = outcome.joined.count
                speakerUndo = SpeakerUndo(meeting: id, speakers: before,
                                          what: count == 1 ? "Matched 1 voice across the recordings" : "Matched \(count) voices across the recordings")
            }
        }
        ZoneLog.coordinator.info("merged voices matched in \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s: \(outcome.joined.count) joined, \(outcome.unmatched.count) open, \(listened) listened to")
    }

    func finishVoiceReview(_ id: UUID, selected: Set<MeetingVoiceMatch.ReviewPair>) throws {
        let before = try store.meeting(id)
        let after = try store.update(id) { meeting in
            let allowed = Set(MeetingVoiceMatch.reviewPairs(in: meeting))
            guard selected.isSubset(of: allowed),
                  let speakers = MeetingVoiceMatch.reviewedSpeakers(for: selected, in: meeting)
            else { throw MeetingStoreError.transcriptChanged }
            meeting.speakers = speakers
            meeting.voiceReviewCandidates = nil
            meeting.speakerGroupsToMatch = nil
            if meeting.message == MeetingVoiceMatch.unmatchedMessage { meeting.message = nil }
        }
        replaceInList(after)
        if let candidates = before.voiceReviewCandidates {
            speakerUndo = SpeakerUndo(meeting: id, speakers: before.speakers,
                                      what: selected.isEmpty ? "Kept voices separate" : "Combined voices",
                                      review: ReviewUndo(candidates: candidates, pendingGroups: before.speakerGroupsToMatch,
                                                         showedNotice: before.message == MeetingVoiceMatch.unmatchedMessage,
                                                         confirmedSpeakers: after.speakers))
        }
    }

    /// Earlier meetings where voice setup's print now finds the person (`MeetingKnownVoices.findMe`).
    func findMe(profile: VoiceProfile) async -> [MeetingKnownVoices.MeMatch] {
        guard labelsSpeakers, recognizesVoices else { return [] }
        let store = store
        return await Task.detached(priority: .utility) {
            MeetingKnownVoices.findMe(in: store.all(), profile: profile)
        }.value
    }

    /// Marks the person as "me" in those meetings, as recognized: a dot says Zone chose it, and
    /// tapping the name confirms or corrects it, as for a new meeting. A meeting the person
    /// changed meanwhile (someone already "me", the speaker named) is left alone.
    func markRecognizedMe(_ matches: [MeetingKnownVoices.MeMatch]) {
        mutate { store in
            for match in matches {
                _ = try store.update(match.meeting) { meeting in
                    guard !meeting.speakers.contains(where: { $0.isMe }),
                          let index = meeting.speakers.firstIndex(where: { $0.id == match.speaker }),
                          (meeting.speakers[index].name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    meeting.speakers[index].isMe = true
                    meeting.speakers[index].recognized = true
                }
            }
        }
    }

    func editTranscript(_ id: UUID, original: [MeetingSegment], texts: [String]) throws {
        replaceInList(try store.editTranscript(id, original: original, texts: texts))
    }

    @discardableResult
    func delete(_ id: UUID) -> Bool {
        cancelTranscription(id)
        defer { Task { await reload() } }
        do {
            try store.delete(id)
            onDelete?(id)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Joins two meetings (earlier first), transcribes whatever of the result is not yet, and
    /// compares the two recordings' voices so the same person stays one speaker. With prints
    /// kept for every voice the queue can match immediately. Otherwise it samples their lines first.
    func merge(_ id: UUID, with other: UUID) -> UUID? {
        do {
            guard transcribingID != id, transcribingID != other else { throw MeetingStoreError.busy }
            let merged = try store.merge(id, other, queueVoiceMatch: true)
            // The later meeting is gone: its words now live in the merged one.
            onDelete?(merged.id == id ? other : id)
            workQueue.cancel(id)
            workQueue.cancel(other)
            replaceInList(merged)
            meetings.removeAll { $0.id != merged.id && ($0.id == id || $0.id == other) }
            if merged.status != .done || merged.speakerGroupsToMatch != nil { enqueue(merged.id) }
            Task { await reload() }
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
                if self.speakerModel == .ready {
                    for meeting in self.meetings where meeting.status == .done && meeting.speakerGroupsToMatch != nil {
                        self.enqueue(meeting.id)
                    }
                }
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
        // A finished transcript whose merged voices still wait to be compared: only that.
        if meeting.status == .done {
            if meeting.speakerGroupsToMatch != nil { await matchVoices(id) }
            return
        }
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
            // Loudness per 100 ms: the second look's speech gate and the chunk planner's cuts.
            let scan = Task.detached(priority: .utility) {
                try audio.levels(frameSamples: 1_600)
            }
            let levels = try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }

            // 1. Who spoke when, once per untranscribed stretch.
            var turns = meeting.turns ?? []
            if meeting.turns == nil {
                // The diarizer's own bound: the stretch still to label, not the whole meeting.
                if labelsSpeakers, to - from > MeetingRecordingSafety.maximumSpeakerSeconds {
                    note = from > 0 ? MeetingRecordingSafety.speakerLimitPartMessage : MeetingRecordingSafety.speakerLimitMessage
                } else if labelsSpeakers, to - from >= 2, MeetingDiarizer.modelsPresent() {
                    do {
                        let started = Date()
                        turns = try await findSpeakers(audio: audio, from: from, to: to, levels: levels,
                                                       existing: meeting.speakers, id: id,
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
                let labeledNobody = from == 0 && !saved.contains { $0.speaker != nil }
                meeting = try store.update(id) {
                    $0.turns = saved
                    // Transcribe again keeps named voices for the speaker pass to find again
                    // (resetTranscript). A pass from the start that labeled nobody (it failed,
                    // heard no voices, had no model, or labels are off) lists none of them, and
                    // holds them for the next Transcribe again instead of losing their prints.
                    if labeledNobody, $0.holdSpeakersForNextPass(), note == nil {
                        note = "Speakers were not labeled, so the people you named are not shown. Transcribe again with speaker labels on to find them."
                    }
                    $0.speakerNotice = note
                }
            }

            // 2. Chunks cut at pauses, silence skipped.
            let transcribeStarted = Date()
            engineWaitSeconds = 0
            phase = "Transcribing"
            // Start from what is already transcribed, not from the diarizer's last figure: that
            // left a meeting reading "Transcribing, 100%" before its first chunk was done.
            progress = to > 0 ? min(from / to, 1) : 0
            let chunks = MeetingChunkPlanner.splitting(
                MeetingChunkPlanner.plan(turns: turns, levels: levels, from: from, to: to),
                at: (meeting.gaps ?? []).map(\.at))
            try Task.checkCancellation()
            let correct = await dictation.meetingTextCorrection()
            for chunk in chunks {
                try Task.checkCancellation()
                if cancelRequested.contains(id) { throw Stop.cancelled }
                let text = correct(try await transcribeChunk(audio: audio, chunk: chunk, id: id))
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
        // Voices a merge left waiting behind an unfinished transcript are compared now.
        if let finished = try? store.meeting(id), finished.status == .done, finished.speakerGroupsToMatch != nil {
            await matchVoices(id)
        }
    }

    private func findSpeakers(audio: MeetingAudio, from: Double, to: Double, levels: [Float], existing: [MeetingSpeaker], id: UUID,
                              expectedSpeakerCount: Int?) async throws -> [MeetingTurn] {
        if !MeetingDiarizer.modelsPresent() { try await waitForSpeakerModel(id: id) }
        phase = "Loading the speaker model"
        // The Neural Engine only while Zone is on screen; in the background it fails without a
        // paid entitlement, so a failure there is retried once on the CPU.
        defer { speakerAttempt = nil }
        var useNeuralEngine = UIApplication.shared.applicationState == .active
        var raw = MeetingDiarizer.Speakers(turns: [], voices: [:])
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
                    try await MeetingDiarizer.speakers(audio: audio, from: from, to: to, levels: levels, models: models,
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
        if let failure = raw.secondLookFailure {
            ZoneLog.coordinator.error("speaker second look failed, first pass kept: \(failure, privacy: .public)")
        } else {
            ZoneLog.coordinator.info("speaker second look: \(raw.secondLookWindows) windows, \(raw.turns.count) turns")
        }
        // A resumed stretch finds the people already named by their voice prints.
        let normalized = MeetingSpeakerLabels.normalize(raw.turns, existing: existing, voices: raw.voices)
        // From the start (a fresh or repeated transcript) only voices this pass heard are listed;
        // later stretches keep everyone the earlier transcript names.
        let heard = Set(normalized.turns.compactMap(\.speaker))
        // A pass from the start that heard nobody leaves the kept people to the caller, which
        // holds them for the next Transcribe again rather than writing an empty list over them.
        if from == 0, heard.isEmpty { return [] }
        var speakers = from > 0 ? normalized.speakers : normalized.speakers.filter { heard.contains($0.id) }
        // People named in other meetings get their names back when their voice is heard again.
        if recognizesVoices, speakers.contains(where: { $0.voice != nil && $0.name == nil && !$0.isMe }) {
            let store = store
            let people = await Task.detached(priority: .utility) {
                MeetingKnownVoices.people(in: store.all(), excluding: id,
                                          profile: VoiceProfileStore.default.load(model: MeetingDiarizer.modelName))
            }.value
            let before = speakers
            speakers = MeetingKnownVoices.recognize(speakers, turns: normalized.turns, people: people)
            let recognized = zip(before, speakers).filter { $0.recognized != $1.recognized }.count
            ZoneLog.coordinator.info("meeting speakers recognized by voice: \(recognized) of \(speakers.count), \(people.count) known")
        }
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
                    dictation.prepareModel(allowDownload: false)
                case .loading where !dictation.isPreparingModel:
                    // "Loading" with nothing loading (the model was unloaded): this wait used to
                    // spin forever. Ask for it once more.
                    dictation.prepareModel(allowDownload: false)
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
