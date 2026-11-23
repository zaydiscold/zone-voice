// by zayd/cold @ zayd.wtf

import CoreML
import FluidAudio
import Foundation
import ZoneCore

/// Who spoke when, on the phone: FluidAudio's offline diarizer (pyannote community-1
/// segmentation, WeSpeaker embeddings, VBx clustering; Core ML conversions by Fluid Inference).
///
/// Four Core ML models plus a PLDA table, 21.6 MB from Hugging Face
/// (`FluidInference/speaker-diarization-coreml` at revision df2625ac, the same pin in FluidAudio
/// 0.17.7 and 0.18.3), CC BY 4.0. They
/// download the first time a meeting is labeled and stay in Application Support, excluded from
/// backups. Audio is read straight from the meeting's PCM files through `AudioSampleSource`, so
/// two hours never sit in memory as one array.
enum MeetingDiarizer {
    private static let work = ExclusiveModelWork()
    /// Sum of the five files at the pinned revision (Segmentation 6,006,888; FBank 1,797,068;
    /// Embedding 13,494,485; PldaRho 211,560; plda-parameters.json 89,416).
    static let downloadBytes: Int64 = 21_599_417
    static let downloadHost = "huggingface.co"
    static let license = "CC BY 4.0 (pyannote, WeSpeaker, BUT Speech@FIT, Fluid Inference)"
    /// Stored on each labeled meeting, shown in its details.
    static let modelName = "pyannote community-1 + WeSpeaker, FluidAudio offline"

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models", isDirectory: true)
    }

    private static var repoDirectory: URL { directory.appendingPathComponent("speaker-diarization", isDirectory: true) }

    static func modelsPresent() -> Bool {
        let names = ["Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc", "PldaRho.mlmodelc", "plda-parameters.json"]
        return names.allSatisfy { FileManager.default.fileExists(atPath: repoDirectory.appendingPathComponent($0).path) }
    }

    static func bytesOnDisk() -> Int64 { DiskUsage.bytes(at: repoDirectory) }

    static func removeModels() throws {
        if FileManager.default.fileExists(atPath: repoDirectory.path) { try FileManager.default.removeItem(at: repoDirectory) }
    }

    /// Fetches the five files without loading them, so the first labeled meeting does not wait
    /// for 21.6 MB. Resumable: FluidAudio streams each file into a `.partial` beside its
    /// destination and continues it by byte range, and a cancel keeps what arrived. `progress`
    /// is the share of the download done, 0...1.
    static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        if modelsPresent() { progress(1); return }
        try DiskSpace.ensureRoom(for: downloadBytes, what: "the speaker model")
        try await ModelHub.download(.diarizer, to: directory, variant: "offline") { update in
            // Download-only runs report the download as the first half of a load (0...0.5).
            if case .downloading = update.phase { progress(min(1, update.fractionCompleted * 2)) }
        }
        try Task.checkCancellation()
        ModelDownloader.excludeFromBackup(repoDirectory)
        guard modelsPresent() else {
            throw SpeechEngineError.unavailable("The speaker model download was incomplete. Try again.")
        }
        progress(1)
    }

    /// Downloads if needed, then loads. `neuralEngine` false keeps every model on the CPU,
    /// which is the only choice that survives the app going to the background on a free team.
    static func loadModels(neuralEngine: Bool,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> OfflineDiarizerModels {
        try await work.run {
            try await loadModelsExclusively(neuralEngine: neuralEngine, progress: progress)
        }
    }

    private static func loadModelsExclusively(neuralEngine: Bool,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> OfflineDiarizerModels {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = neuralEngine ? .cpuAndNeuralEngine : .cpuOnly
        let models = try await OfflineDiarizerModels.load(from: directory, configuration: configuration) { update in
            progress(update.fractionCompleted)
        }
        ModelDownloader.excludeFromBackup(repoDirectory)
        return models
    }

    /// Speaker turns over `[from, to)` seconds of the meeting, in meeting time.
    static func turns(audio: MeetingAudio, from: Double, to: Double, models: OfflineDiarizerModels,
                      expectedSpeakerCount: Int? = nil,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> [MeetingTurn] {
        try await work.run {
            try Task.checkCancellation()
            guard to - from <= MeetingRecordingSafety.maximumSpeakerSeconds else {
                throw SpeechEngineError.unavailable(MeetingRecordingSafety.speakerLimitMessage)
            }
            return try await turnsExclusively(audio: audio, from: from, to: to, models: models,
                                              expectedSpeakerCount: expectedSpeakerCount, progress: progress)
        }
    }

    private static func turnsExclusively(audio: MeetingAudio, from: Double, to: Double, models: OfflineDiarizerModels,
                      expectedSpeakerCount: Int?,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> [MeetingTurn] {
        let source = MeetingSampleSource(audio: audio, offset: Int(from * 16_000),
                                         count: max(0, Int((to - from) * 16_000)))
        guard source.sampleCount >= 16_000 * 2 else { return [] }
        var config = OfflineDiarizerConfig.default
        // One speaker at any instant, as FluidAudio did by default before 0.18 (#1081 made
        // overlapping output the default). MeetingChunkPlanner turns every turn into its own
        // chunk, so overlapping turns would transcribe the overlapped audio twice.
        config.postProcessing.exclusiveSegments = true
        // Segmentation windows per Core ML call (0.18, #1014). 0.17.7 always used 32; on the Mac
        // bake-off (62 recordings, 2026-11-08) 8 gave identical turns at the same speed with peak
        // memory 292 MB instead of 605 MB.
        config.segmentation.batchSize = 8
        if let expectedSpeakerCount, (1...8).contains(expectedSpeakerCount) {
            config.clustering.numSpeakers = expectedSpeakerCount
        }
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)
        let result = try await manager.process(audioSource: source, audioLoadingSeconds: 0) { done, total in
            if total > 0 { progress(Double(done) / Double(total)) }
        }
        try Task.checkCancellation()
        return result.segments.map {
            MeetingTurn(start: from + Double($0.startTimeSeconds), end: from + Double($0.endTimeSeconds), speaker: $0.speakerId)
        }
    }
}

/// A window of a meeting's audio as FluidAudio's sample source: reads on demand from disk.
struct MeetingSampleSource: AudioSampleSource {
    let audio: MeetingAudio
    let offset: Int
    let count: Int

    var sampleCount: Int { max(0, min(count, audio.sampleCount - offset)) }

    /// FluidAudio asks for whole 10 s windows, past the end of the source in the last one
    /// (`count: chunkSize` in its embedding pass), and expects zeros there. Without this cap the
    /// last window of a range read the meeting audio after `to`.
    func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws {
        let inside = max(0, min(count, sampleCount - offset))
        if inside > 0 {
            try audio.copySamples(into: destination, offset: self.offset + offset, count: inside)
        }
        if inside < count {
            destination.advanced(by: inside).update(repeating: 0, count: count - inside)
        }
    }
}
