// by zayd/cold @ zayd.wtf

#if DEBUG
import Foundation
import ZoneCore

/// Development builds only: `-zoneFakeSpeech "First note|Second note"` swaps the speech model for
/// a script, one line per recording (the last line repeats), so UI tests and screen reviews can
/// run real notes, through the real microphone engine and coordinator, on a simulator with no
/// model downloaded. An empty line is a recording with no words.
///
/// `-zoneFakeModelDownload N` adds a download: the model reads as missing until asked for, then
/// reports progress for N seconds at an uneven pace, so setup's download line can be seen.
enum ScriptedSpeech {
    #if targetEnvironment(simulator)
    static func blockedRecoveryStore() -> AudioRecoveryStore? {
        guard let key = ProcessInfo.processInfo.environment["ZONE_TEST_BLOCKED_RECOVERY"], let id = UUID(uuidString: key),
              let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier) else { return nil }
        let folder = "RecordingTest-" + id.uuidString
        let blocker = URL.temporaryDirectory.appendingPathComponent(folder)
        if !FileManager.default.fileExists(atPath: blocker.path) { try? Data().write(to: blocker) }
        return AudioRecoveryStore(directory: blocker.appendingPathComponent("AudioRecovery"),
                                  fallbackDirectory: group.appendingPathComponent(folder))
    }
    #endif

    static func engineIfRequested() -> SpeechEngine? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-zoneFakeSpeech"), index + 1 < arguments.count else { return nil }
        let lines = arguments[index + 1].components(separatedBy: "|")
        var downloadSeconds: Double?
        if let at = arguments.firstIndex(of: "-zoneFakeModelDownload"), at + 1 < arguments.count {
            downloadSeconds = Double(arguments[at + 1])
        }
        return ScriptedSpeechEngine(lines: lines.isEmpty ? [""] : lines, downloadSeconds: downloadSeconds)
    }
}

private final class ScriptedSpeechEngine: SpeechEngine {
    let kind: EngineKind = .default
    private(set) var isReady = false
    private let lines: [String]
    private var used = 0
    private let downloadSeconds: Double?
    private var downloaded: Bool

    init(lines: [String], downloadSeconds: Double? = nil) {
        self.lines = lines
        self.downloadSeconds = downloadSeconds
        downloaded = downloadSeconds == nil
    }

    func assetsPresent() -> Bool { downloaded }
    func bytesOnDisk() -> Int64 { 0 }
    func removeAssets() throws {}
    func downloadAssets(progress: @escaping @Sendable (Double, String) -> Void) async throws {}
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-zoneHoldSpeechModelLoading") {
            try await Task.sleep(for: .seconds(180))
        }
        #endif
        if !downloaded, let seconds = downloadSeconds {
            let steps = max(1, Int(seconds * 4))
            for step in 1...steps {
                try await Task.sleep(for: .milliseconds(250))
                // Faster in the middle, like a real transfer finding its speed.
                let t = Double(step) / Double(steps)
                progress(t * t * (3 - 2 * t), "Encoder.mlmodelc")
            }
            progress(1, "loading")
            try await Task.sleep(for: .milliseconds(700))
            downloaded = true
        }
        isReady = true
    }
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
