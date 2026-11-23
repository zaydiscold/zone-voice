// by zayd/cold @ zayd.wtf

import AVFoundation
import Foundation
import Observation
import ZoneCore

/// Reads at most three seconds ahead, so playing a six-hour recording never allocates the
/// entire PCM recording. Playback shares the audio session with music and relinquishes it.
@Observable @MainActor
final class MeetingPlayback {
    private(set) static weak var current: MeetingPlayback?
    private(set) var isPlaying = false
    private(set) var position: Double = 0
    private(set) var error: String?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var node: AVAudioPlayerNode?
    @ObservationIgnored private var ownsSession = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var pendingBuffers = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                if notification.name == AVAudioSession.interruptionNotification,
                   notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt != AVAudioSession.InterruptionType.began.rawValue { return }
                Task { @MainActor in self?.stop() }
            })
        }
    }

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    func play(meeting: Meeting, store: MeetingStore) {
        guard MeetingCoordinator.current?.isRecording != true else { return }
        Self.current?.stop()
        SpeakerSamplePlayer.current?.stop()
        Self.current = self
        error = nil
        position = 0
        isPlaying = true
        let token = UUID()
        generation = token
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let audio = try await Task.detached(priority: .userInitiated) { try store.audio(meeting.id) }.value
                guard !Task.isCancelled, self.generation == token else { return }
                let session = AVAudioSession.sharedInstance()
                if session.category != .playAndRecord {
                    try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                    try session.setActive(true)
                    self.ownsSession = true
                }
                let engine = AVAudioEngine(), node = AVAudioPlayerNode()
                let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: format)
                self.engine = engine
                self.node = node
                try engine.start()
                node.play()
                var offset = 0
                while offset < audio.sampleCount {
                    try Task.checkCancellation()
                    guard self.generation == token else { return }
                    while self.pendingBuffers >= 3 {
                        try await Task.sleep(for: .milliseconds(25))
                        try Task.checkCancellation()
                    }
                    let start = offset
                    let samples = try await Task.detached(priority: .userInitiated) { try audio.read(offset: start, count: 16_000) }.value
                    try Task.checkCancellation()
                    guard self.generation == token, !samples.isEmpty else { break }
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
                    buffer.frameLength = buffer.frameCapacity
                    samples.withUnsafeBufferPointer { source in buffer.floatChannelData![0].update(from: source.baseAddress!, count: source.count) }
                    offset += samples.count
                    let playedThrough = Double(offset) / 16_000
                    self.pendingBuffers += 1
                    node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                        Task { @MainActor in
                            guard let self, self.generation == token else { return }
                            self.pendingBuffers -= 1
                            self.position = playedThrough
                        }
                    }
                }
                while self.pendingBuffers > 0 {
                    try await Task.sleep(for: .milliseconds(25))
                    try Task.checkCancellation()
                }
                if self.generation == token { self.stop() }
            } catch is CancellationError {
                // Stop already owns cleanup, and an older task must not stop a newer player.
            } catch {
                guard self.generation == token else { return }
                self.error = "The recording could not play: \(error.localizedDescription)"
                self.stop()
            }
        }
    }

    func stop() {
        generation = UUID()
        work?.cancel()
        work = nil
        node?.stop()
        engine?.stop()
        node = nil
        engine = nil
        pendingBuffers = 0
        isPlaying = false
        if Self.current === self { Self.current = nil }
        let session = AVAudioSession.sharedInstance()
        if ownsSession, session.category == .playback {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        ownsSession = false
    }
}
