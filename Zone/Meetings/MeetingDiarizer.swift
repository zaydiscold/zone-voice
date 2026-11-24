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

    /// Who spoke when over a stretch, and what each voice sounds like.
    struct Speakers: Sendable {
        /// In meeting time, one voice at any instant.
        var turns: [MeetingTurn]
        /// The diarizer's voice print per speaker id in `turns`.
        var voices: [String: [Float]]
        /// Why the second look did not run, when it did not (the first pass is used instead).
        var secondLookFailure: String?
        var secondLookWindows = 0
    }

    /// The share of "Finding speakers" progress given to the first pass; the rest is the second look.
    private static let firstPassShare = 0.65
    /// Windows per Core ML request batch in the second look, and per progress update.
    private static let secondLookBatch = 64

    /// Speaker turns over `[from, to)` seconds of the meeting, in meeting time. `levels` are the
    /// meeting's 100 ms RMS levels from its start (`MeetingAudio.levels(frameSamples: 1_600)`).
    static func speakers(audio: MeetingAudio, from: Double, to: Double, levels: [Float], models: OfflineDiarizerModels,
                         expectedSpeakerCount: Int? = nil,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> Speakers {
        try await work.run {
            try Task.checkCancellation()
            guard to - from <= MeetingRecordingSafety.maximumSpeakerSeconds else {
                throw SpeechEngineError.unavailable(MeetingRecordingSafety.speakerLimitMessage)
            }
            return try await speakersExclusively(audio: audio, from: from, to: to, levels: levels, models: models,
                                                 expectedSpeakerCount: expectedSpeakerCount, progress: progress)
        }
    }

    private static func speakersExclusively(audio: MeetingAudio, from: Double, to: Double, levels: [Float],
                                            models: OfflineDiarizerModels, expectedSpeakerCount: Int?,
                                            progress: @escaping @Sendable (Double) -> Void) async throws -> Speakers {
        let source = MeetingSampleSource(audio: audio, offset: Int(from * 16_000),
                                         count: max(0, Int((to - from) * 16_000)))
        guard source.sampleCount >= 16_000 * 2 else { return Speakers(turns: [], voices: [:]) }
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
            if total > 0 { progress(firstPassShare * Double(done) / Double(total)) }
        }
        try Task.checkCancellation()
        let firstPass = result.segments.map {
            MeetingTurn(start: from + Double($0.startTimeSeconds), end: from + Double($0.endTimeSeconds), speaker: $0.speakerId)
        }
        let voices = result.speakerDatabase ?? [:]
        var speakers = Speakers(turns: firstPass, voices: voices)

        // The second look (MeetingSecondLook): short windows, each compared with every voice.
        // A failure here keeps the first pass; it never costs the meeting its labels.
        let windows = MeetingSecondLook.windows(levels: levels, from: from, to: to)
        speakers.secondLookWindows = windows.count
        guard !voices.isEmpty, !windows.isEmpty else { progress(1); return speakers }
        do {
            var embeddings: [[Float]] = []
            embeddings.reserveCapacity(windows.count)
            for first in stride(from: 0, to: windows.count, by: secondLookBatch) {
                try Task.checkCancellation()
                let batch = windows[first..<min(first + secondLookBatch, windows.count)].map {
                    ($0.lowerBound - from)..<($0.upperBound - from)
                }
                embeddings += try await manager.embedSpans(audioSource: source, spans: batch)
                progress(firstPassShare + (1 - firstPassShare) * Double(first + batch.count) / Double(windows.count))
            }
            try Task.checkCancellation()
            speakers.turns = MeetingSecondLook.relabel(turns: firstPass, windows: windows, embeddings: embeddings,
                                                       voices: voices, levels: levels, from: from, to: to)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            speakers.secondLookFailure = error.localizedDescription
        }
        progress(1)
        return speakers
    }
}

extension MeetingDiarizer {
    /// One voice print per voice from stretches of a meeting's own audio (`MeetingVoiceMatch.spans`),
    /// for speakers labeled before prints were kept. The same span embedding as the second look,
    /// so the prints compare with the ones the speaker model leaves. Each voice's stretches are
    /// averaged by length, leaving out one that does not sound like the rest.
    static func voicePrints(audio: MeetingAudio, spans: [String: [Range<Double>]],
                            models: OfflineDiarizerModels) async throws -> [String: [Float]] {
        try await work.run {
            let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig.default)
            manager.initialize(models: models)
            let source = MeetingSampleSource(audio: audio, offset: 0, count: audio.sampleCount)
            var prints: [String: [Float]] = [:]
            for voice in spans.keys.sorted() {
                try Task.checkCancellation()
                guard let stretches = spans[voice], !stretches.isEmpty else { continue }
                let vectors = try await manager.embedSpans(audioSource: source, spans: stretches)
                prints[voice] = VoiceSetup.print(of: vectors, seconds: stretches.map { $0.upperBound - $0.lowerBound })
            }
            return prints
        }
    }

    /// Voice prints for stretches of a voice setup recording (`VoiceSetupMeter.spans`): the same
    /// WeSpeaker model and span embedding the second look uses, so the prints compare directly
    /// with a meeting speaker's. Runs under the same lock as meeting labeling.
    static func voicePrints(samples: [Float], spans: [Range<Double>], models: OfflineDiarizerModels) async throws -> [[Float]] {
        guard !spans.isEmpty, !samples.isEmpty else { return [] }
        return try await work.run {
            try Task.checkCancellation()
            let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig.default)
            manager.initialize(models: models)
            return try await manager.embedSpans(audioSource: ArrayAudioSampleSource(samples: samples), spans: spans)
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
