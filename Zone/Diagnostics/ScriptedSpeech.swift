// by zayd/cold @ zayd.wtf

#if DEBUG
import Foundation
import ZoneCore

/// Development builds only: `-zoneFakeSpeech "First note|Second note"` swaps the speech model for
/// a script, one line per recording (the last line repeats), so UI tests and screen reviews can
/// run real notes, through the real microphone engine and coordinator, on a simulator with no
/// model downloaded. An empty line is a recording with no words.
enum ScriptedSpeech {
    static func engineIfRequested() -> SpeechEngine? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-zoneFakeSpeech"), index + 1 < arguments.count else { return nil }
        let lines = arguments[index + 1].components(separatedBy: "|")
        return ScriptedSpeechEngine(lines: lines.isEmpty ? [""] : lines)
    }
}

private final class ScriptedSpeechEngine: SpeechEngine {
    let kind: EngineKind = .default
    private(set) var isReady = false
    private let lines: [String]
    private var used = 0

    init(lines: [String]) { self.lines = lines }

    func assetsPresent() -> Bool { true }
    func bytesOnDisk() -> Int64 { 0 }
    func removeAssets() throws {}
    func downloadAssets(progress: @escaping @Sendable (Double, String) -> Void) async throws {}
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws { isReady = true }
    func setContextHints(_ text: String) {}
    func beginUtterance() throws -> UtteranceSession {
        let line = lines[min(used, lines.count - 1)]
        used += 1
        return ScriptedUtterance(text: line)
    }
    func unload() { isReady = false }
}

private final class ScriptedUtterance: UtteranceSession {
    private let text: String
    private var seconds = 0.0
    init(text: String) { self.text = text }
    var audioSeconds: Double { seconds }
    /// The words appear as the audio comes in, a word a second, like a live recognizer.
    var textSoFar: String { text.split(separator: " ").prefix(Int(seconds)).joined(separator: " ") }
    var failure: Error? { nil }
    var availableAudioSamples: Int { .max }
    func feed(_ samples: [Float]) { seconds += Double(samples.count) / 16_000 }
    func finish() async throws -> String {
        // About as long as a warm model takes, so the Saving state is seen.
        try await Task.sleep(for: .milliseconds(350))
        return text
    }
    func cancel() {}
}
#endif
