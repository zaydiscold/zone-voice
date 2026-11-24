// by zayd/cold @ zayd.wtf

import AudioToolbox
import AVFAudio
import ZoneCore

@MainActor
final class KeyboardRecordingCue {
    private var player: AVAudioPlayer?
    private var fallback: SystemSoundID?

    @discardableResult
    func play(start: Bool, preferences: KeyboardPreferences) -> TimeInterval {
        cancel()
        let prefix = start ? "dictation-start-" : "dictation-stop-"
        guard preferences.soundsEnabled,
              let url = Bundle.main.url(forResource: prefix + preferences.soundSet, withExtension: "caf") else { return 0 }
        let player = try? AVAudioPlayer(contentsOf: url)
        if let player {
            player.volume = KeyboardPreferences.cueVolume
            if player.play() {
                self.player = player
                return player.duration
            }
        }
        var sound: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &sound) == noErr else { return 0 }
        let playing = sound
        fallback = playing
        AudioServicesPlaySystemSoundWithCompletion(playing) { [weak self] in
            Task { @MainActor in
                if self?.fallback == playing { self?.cancel() }
            }
        }
        return player?.duration ?? 0.5
    }

    func cancel() {
        player?.stop()
        player = nil
        if let fallback { AudioServicesDisposeSystemSoundID(fallback) }
        fallback = nil
    }
}
