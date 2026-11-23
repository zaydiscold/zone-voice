// by zayd/cold @ zayd.wtf

import AVFoundation

/// Zone's dictation cues, one start/stop pair per set (Chime by default; Water drop, Kalimba,
/// Glass, Wood in Settings). Synthesized by `scripts/make-sounds.py`, no third-party audio. They play on the
/// app's own audio session, which is active whenever a dictation can start, so they are heard
/// while Zone sits in the background behind Messages.
@MainActor
final class DictationSounds {
    /// Cues last 0.2 to 0.4 s. Speech capture is never muted to hide
    /// them: early words matter.
    /// The quiet cue can still reach the microphone; device testing assesses that tradeoff.
    /// Below full scale so the cue sits under speech and media rather than over it.
    nonisolated static let volume: Float = 0.55

    enum Set: String, CaseIterable, Identifiable, Sendable {
        case chime, drop, kalimba, glass, wood
        var id: String { rawValue }
        var label: String {
            switch self {
            case .chime: return "Chime"
            case .drop: return "Water drop"
            case .kalimba: return "Kalimba"
            case .glass: return "Glass"
            case .wood: return "Wood"
            }
        }
    }

    private let bundle: Bundle
    private(set) var set: Set
    /// Touched only on `AudioHardwareQueue`: creating, preparing and playing a player all reach
    /// the audio daemons. The first `play()` of an unprepared player set up its audio queue
    /// with a synchronous XPC, 140 to 190 ms on the main thread in the hang reports.
    private let players = CuePlayers()
    /// True while capture holds an active session. Only then may a cue be prepared:
    /// `prepareToPlay` activates the session, and nothing at app initialization may touch
    /// audio hardware or interrupt media before the user records or previews.
    private var sessionIsArmed = false

    init(bundle: Bundle = .main, set: Set = .chime) {
        self.bundle = bundle
        self.set = set
        load()
    }

    func use(_ next: Set) {
        guard next != set else { return }
        set = next
        load()
    }

    /// Capture armed or released the session. Armed, the cues are prepared off the main thread
    /// so the first one plays without setting up its audio queue; released, they let go of it.
    func sessionArmed(_ armed: Bool) {
        guard armed != sessionIsArmed else { return }
        sessionIsArmed = armed
        let players = self.players
        if armed {
            AudioHardwareQueue.async { players.prepare() }
        } else {
            // Queued before the deactivation that follows, so no cue holds audio I/O open.
            AudioHardwareQueue.async { players.stop() }
        }
    }

    private func load() {
        let names = (start: "dictation-start-\(set.rawValue)", stop: "dictation-stop-\(set.rawValue)")
        let bundle = self.bundle, players = self.players, prepare = sessionIsArmed
        AudioHardwareQueue.async {
            players.load(start: Self.player(named: names.start, in: bundle), stop: Self.player(named: names.stop, in: bundle))
            if prepare { players.prepare() }
        }
    }

    func playStart() {
        play(start: true)
    }

    func playStop() {
        play(start: false)
    }

    /// Waits for the queue, so a cue asked for just before is stopped too. Called before the
    /// session is released.
    func stopPlayback() {
        let players = self.players
        AudioHardwareQueue.sync { players.stop() }
    }

    /// Let the short finish cue complete before releasing audio. Cancellation still ends
    /// promptly; a stalled player can never hold a shortcut open indefinitely.
    func finishStopCue() async {
        let players = self.players
        // The cue may still be queued behind other audio work; ask once it has started.
        let remaining = (try? await AudioHardwareQueue.run { players.stopCueRemaining() }) ?? 0
        guard remaining > 0 else { return }
        try? await Task.sleep(for: .seconds(min(0.5, remaining)))
    }

    /// Plays on the hardware queue, so the main thread never waits for an audio queue to be
    /// set up, whatever state the player is in.
    private func play(start: Bool) {
        let players = self.players
        let name = start ? "start" : "stop"
        AudioHardwareQueue.async {
            guard let player = start ? players.startCue : players.stopCue else {
                ZoneLog.audio.error("dictation \(name, privacy: .public) sound missing from the bundle")
                return
            }
            // A preview can play before capture has configured its mixing session. The default
            // soloAmbient category interrupts music; ambient keeps a preview alongside it.
            let session = AVAudioSession.sharedInstance()
            if session.category == .soloAmbient {
                do { try session.setCategory(.ambient) }
                catch {
                    ZoneLog.audio.error("could not configure dictation sound: \(error.localizedDescription, privacy: .public)")
                    return
                }
            }
            player.currentTime = 0
            let started = player.play()
            ZoneLog.audio.info("dictation \(name, privacy: .public) sound played=\(started)")
        }
    }

    nonisolated private static func player(named name: String, in bundle: Bundle) -> AVAudioPlayer? {
        guard let url = bundle.url(forResource: name, withExtension: "caf"),
              let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.volume = volume
        // Not prepared here: prepareToPlay activates the audio session. `sessionArmed` prepares
        // the cues once capture has activated it anyway.
        return player
    }
}

/// The current set's two players. Hardware queue only.
private final class CuePlayers: @unchecked Sendable {
    private(set) var startCue: AVAudioPlayer?
    private(set) var stopCue: AVAudioPlayer?

    func load(start: AVAudioPlayer?, stop: AVAudioPlayer?) {
        self.stop()
        startCue = start
        stopCue = stop
    }

    func prepare() {
        startCue?.prepareToPlay()
        stopCue?.prepareToPlay()
    }

    /// Also undoes `prepareToPlay`.
    func stop() {
        startCue?.stop()
        stopCue?.stop()
    }

    func stopCueRemaining() -> TimeInterval {
        guard let stopCue, stopCue.isPlaying else { return 0 }
        return max(0, stopCue.duration - stopCue.currentTime)
    }
}
