// by zayd/cold @ zayd.wtf

import CoreML
import FluidAudio
import Foundation
import os
import ZoneCore
import ZoneFluidAudio

/// Parakeet-family TDT models through FluidAudio (Core ML), one resident `AsrManager`.
///
/// Two models share this engine: NVIDIA's Parakeet TDT-CTC 110M (FluidAudio downloads it) and
/// Fluid Speech Mini, a drop-in Parakeet v3 package we fetch from Hugging Face at a pinned
/// revision and hand to `AsrModels.loadLocal`.
///
/// Both are batch models: audio is only buffered while the user talks and the whole
/// utterance is decoded once on `finish()` (FluidAudio chunks anything over ~15 s itself).
/// That keeps idle and talking cost near zero but puts all inference after the stop, so
/// stop-to-text latency is the full decode. Leading and trailing silence is trimmed first,
/// since decode time scales with audio length. `useNeuralEngine` picks
/// `.cpuAndNeuralEngine` versus `.cpuOnly`; on iOS 27 a backgrounded app gets hard ANE
/// errors without the Background Inference entitlement.
final class ParakeetEngine: SpeechEngine {
    enum Model: Sendable {
        case tdtCtc110m
        case fluidSpeechMini

        var version: AsrModelVersion {
            switch self {
            case .tdtCtc110m: return .tdtCtc110m
            case .fluidSpeechMini: return .v3
            }
        }

        var directory: URL {
            switch self {
            case .tdtCtc110m:
                return AsrModels.defaultCacheDirectory(for: .tdtCtc110m)
            case .fluidSpeechMini:
                return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Models/fluid-speech-mini-coreml", isDirectory: true)
            }
        }
    }

    private let model: Model
    private let useNeuralEngine: Bool
    private var manager: AsrManager?
    private var cleanupTask: Task<Void, Never>?
    private var decodeLane = SerialRecognitionDecoder()
    private var program: CompiledProgramReadahead.Program?
    private var decoderLayers = 1
    private let lock = NSLock()
    private var ready = false

    init(model: Model, useNeuralEngine: Bool) {
        self.model = model
        self.useNeuralEngine = useNeuralEngine
    }

    var kind: EngineKind {
        switch (model, useNeuralEngine) {
        case (.tdtCtc110m, false): return .parakeetCPU
        case (.tdtCtc110m, true): return .parakeetANE
        case (.fluidSpeechMini, false): return .fluidMiniCPU
        case (.fluidSpeechMini, true): return .fluidMiniANE
        }
    }

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready
    }

    func assetsPresent() -> Bool {
        switch model {
        case .tdtCtc110m: return AsrModels.modelsExist(at: model.directory)
        case .fluidSpeechMini: return HuggingFaceSnapshot.fluidSpeechMini.isComplete(at: model.directory)
        }
    }

    func bytesOnDisk() -> Int64 {
        DiskUsage.bytes(at: model.directory) + CompiledModelJanitor.bytes(for: model.directory)
    }

    func removeAssets() throws {
        try CompiledModelJanitor.remove(for: model.directory)
        if FileManager.default.fileExists(atPath: model.directory.path) {
            try FileManager.default.removeItem(at: model.directory)
        }
    }

    /// The first load also writes a prepared copy several times the download's size, so a
    /// nearly full iPhone is told before downloading, not by a Core ML error afterwards.
    private func ensureRoomToPrepare() throws {
        let catalog: SpeechModel = model == .fluidSpeechMini ? .fluidSpeechMini : .parakeet110m
        guard catalog.approximatePreparedBytes > 0, CompiledModelJanitor.bytes(for: model.directory) == 0 else { return }
        let missing = assetsPresent() ? 0 : max(0, catalog.approximateDownloadBytes - DiskUsage.bytes(at: model.directory))
        try DiskSpace.ensureRoom(for: missing + catalog.approximatePreparedBytes, what: "the speech model")
    }

    func downloadAssets(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        try ensureRoomToPrepare()
        switch model {
        case .tdtCtc110m:
            _ = try await AsrModels.download(to: model.directory, version: .tdtCtc110m) { update in
                progress(update.fractionCompleted, "parakeet-tdt-ctc-110m")
            }
            ModelDownloader.excludeFromBackup(model.directory)
        case .fluidSpeechMini:
            try await HuggingFaceSnapshot.fluidSpeechMini.download(to: model.directory, progress: progress)
        }
    }

    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        if isReady { return }
        let units: MLComputeUnits = useNeuralEngine ? .cpuAndNeuralEngine : .cpuOnly
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units
        let models: AsrModels
        switch model {
        case .tdtCtc110m:
            models = try await AsrModels.downloadAndLoad(
                to: model.directory, configuration: configuration, version: .tdtCtc110m,
                encoderComputeUnits: units
            ) { update in
                switch update.phase {
                case .compiling: progress(1, "loading")
                default: progress(update.fractionCompleted, "parakeet-tdt-ctc-110m")
                }
            }
        case .fluidSpeechMini:
            try ensureRoomToPrepare()
            let directory = model.directory
            try await HuggingFaceSnapshot.fluidSpeechMini.download(to: directory, progress: progress)
            progress(1, "loading")
            let wantsTopK = Self.spelledLetterRepeatMargin != nil
            models = try await Task.detached(priority: .userInitiated) {
                if wantsTopK { Self.installSpelledLetterJoint(in: directory) }
                return try AsrModels.loadLocal(
                    from: directory, version: .v3, configuration: configuration, encoderComputeUnits: units)
            }.value
        }
        progress(1, "loading")
        // FluidAudio may also fetch Parakeet's CTC head while loading, so exclude after it.
        ModelDownloader.excludeFromBackup(model.directory)
        let repeatMargin = model == .fluidSpeechMini && FluidMiniJointTopK.isInstalled(in: model.directory)
            ? Self.spelledLetterRepeatMargin : nil
        let manager = AsrManager(config: ASRConfig(tdtConfig: TdtConfig(spelledLetterRepeatMargin: repeatMargin)))
        try await manager.loadModels(models)
        let layers = await manager.decoderLayerCount
        let program = CompiledProgramReadahead.Program(
            cacheRoot: CompiledModelJanitor.root,
            osBuild: CompiledModelCache.osBuild(fromVersionString: ProcessInfo.processInfo.operatingSystemVersionString))
        lock.lock()
        self.manager = manager
        decodeLane = SerialRecognitionDecoder()
        self.program = program
        decoderLayers = layers
        ready = true
        let lane = decodeLane
        lock.unlock()
        // The first inference after a load pays one-time costs (doc 12's "cold first", 8.1 s
        // for Fluid Mini in the simulator). Pay them now, not on the first dictation. Its decode
        // also shows which compiled files are this model's (`Program.learn`).
        Self.warmUp(lane: lane, manager: manager, decoderLayers: layers, program: program, model: model,
                    ifIdleFor: 0, reason: "load")
    }

    /// FluidAudio's spelled-letter repeat rule (Zone's fork): writes a spelled letter again
    /// ("D A A N" rather than "DAN") when Mini scores the repeat within this many logits of
    /// "nothing new". Off. It fixed most drops in synthetic voices but added letters people did
    /// not say in real recordings (Zayd's Wispr audio and spelling-bee finals), mostly at the
    /// end of a spelled word; see docs/research/2026-11-12-doubled-letters-and-engines.md,
    /// "November 15". Development builds measure it with the bakeoff's
    /// `-zoneBakeoffSpelledLetters 3`, which also installs the top-K joint it reads.
    nonisolated(unsafe) static var spelledLetterRepeatMargin: Float? = nil

    /// Puts Mini's joint with top-K outputs in place of the plain copy FluidAudio would load.
    /// It is assembled from a 12 KB program in ZoneFluidAudio and the downloaded weights, so
    /// it needs no download, and it decides exactly as Mini's own joint. On failure Mini keeps
    /// its own joint and the rule stays off.
    private static func installSpelledLetterJoint(in directory: URL) {
        guard !FluidMiniJointTopK.isInstalled(in: directory) else { return }
        do {
            try FluidMiniJointTopK.install(in: directory)
            ZoneLog.coordinator.notice("installed Fluid Mini's top-K joint for spelled letters")
        } catch {
            ZoneLog.coordinator.error("Fluid Mini top-K joint not installed: \(String(describing: error), privacy: .public)")
        }
    }

    /// A model idle this long may have been paged out (see `SerialRecognitionDecoder`). On the
    /// phone a decode within about 10 s of the previous one was always fast, and one after
    /// 15 s or more usually paid about 3 s; a warm-up that turns out unneeded costs one
    /// inference while the person is still talking.
    static let warmUpAfterIdle: TimeInterval = 5
    /// Off only in the bakeoff's A/B (`-zoneBakeoffWarmUp off`, development builds).
    nonisolated(unsafe) static var warmUpEnabled = true
    /// Off only to measure the warm-up without it (`-zoneBakeoffReadahead off`, development builds).
    nonisolated(unsafe) static var readaheadEnabled = true

    /// Each loaded model's compiled files, so a model learning its own after an engine switch
    /// leaves out the previous model's, which can still be in memory.
    private static let claims = OSAllocatedUnfairLock(initialState: [Model: [URL]]())

    /// Runs one silent inference on the lane so the model's compiled program is back in memory
    /// before the utterance's own decode needs it. Silence still runs the full encoder window,
    /// whatever its length (`FluidWarmUp`): shorter is no cheaper, and under 0.3 s it runs nothing.
    ///
    /// The warm-up first reads the program back with a few parallel reads
    /// (`CompiledProgramReadahead`): the inference alone faults its 1.2 GB in a page at a time,
    /// about 3 s on the phone and 2.4 s on an M4 Mac, while the reads take 0.2 s on the Mac. With
    /// the readahead a short dictation after idle no longer waits behind the warm-up
    /// (docs/research/2026-11-18-model-page-in.md). The load warm-up has nothing to read yet:
    /// its decode is what tells the program's files apart (`Program.learn`). If that found
    /// nothing (memory pressure during the load), the next warm-up learns again.
    private static func warmUp(lane: SerialRecognitionDecoder, manager: AsrManager, decoderLayers: Int,
                               program: CompiledProgramReadahead.Program?, model: Model,
                               ifIdleFor idle: TimeInterval, reason: String) {
        guard warmUpEnabled else { return }
        let idleBefore = lane.idleSeconds
        let queued = ProcessInfo.processInfo.systemUptime
        let started = lane.warmUp(ifIdleFor: idle) {
            let began = ProcessInfo.processInfo.systemUptime
            let learns = reason == "load" || program?.files.isEmpty == true
            var readahead: CompiledProgramReadahead.Report?
            if !learns, readaheadEnabled, let program { readahead = await prefetch(program) }
            let inferenceBegan = ProcessInfo.processInfo.systemUptime
            var state = TdtDecoderState.make(decoderLayers: decoderLayers)
            do {
                _ = try await manager.transcribe([Float](repeating: 0, count: FluidWarmUp.samples), decoderState: &state)
            } catch {
                // The lane discards a warm-up's error; say so here, or a warm-up that stopped
                // working only shows as slow dictations after a pause.
                Journal.log("modelWarmUpFailed", ["reason": reason, "error": JournalFormat.error(error)])
                throw error
            }
            let end = ProcessInfo.processInfo.systemUptime
            var fields = ["reason": reason, "ms": String(Int((end - began) * 1000)),
                          "waitedMs": String(Int((began - queued) * 1000)),
                          "inferenceMs": String(Int((end - inferenceBegan) * 1000)),
                          "idleS": idleBefore.map { String(Int($0)) } ?? "never"]
            if learns, let program {
                let others = Set(claims.withLock { $0.filter { $0.key != model }.values.flatMap { $0 } })
                let files = program.learn(excluding: others)
                claims.withLock { $0[model] = files }
                fields["programFiles"] = String(files.count)
                fields["programMB"] = String(files.reduce(Int64(0)) { $0 + (Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)) } / 1_000_000)
                // What `CompiledModelJanitor` finds for this model by reading Core ML's
                // descriptors alone. 0 next to a programMB of about 1,200 means this iOS no
                // longer names the model's path there (iOS 26.2 does not); the janitor then
                // relies on the entries remembered here (docs/research/2026-11-18-model-page-in.md).
                fields["descriptorMatchMB"] = String(CompiledModelJanitor.descriptorMatchedBytes(for: model.directory) / 1_000_000)
                CompiledModelJanitor.remember(programFiles: files, for: model.directory)
            }
            if let readahead {
                fields["readMB"] = String(readahead.bytesRead / 1_000_000)
                fields["programMB"] = String(readahead.bytes / 1_000_000)
                fields["readMs"] = String(Int(readahead.seconds * 1000))
            }
            Journal.log("modelWarmUp", fields)
        }
        if !started, let idleBefore {
            ZoneLog.coordinator.info("model warm, idle \(String(format: "%.1f", idleBefore), privacy: .public) s")
        }
    }

    /// The readahead blocks while it reads, so it runs on a dispatch queue, not on the Swift
    /// concurrency pool the decode needs.
    private static func prefetch(_ program: CompiledProgramReadahead.Program) async -> CompiledProgramReadahead.Report? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: program.prefetch())
            }
        }
    }

    /// Not wired for the bakeoff, which runs without hints. TDT-CTC-110M's built-in CTC head
    /// supports FluidAudio's custom-vocabulary boosting for about 1 MB extra; that is the path when this engine needs names.
    func setContextHints(_ text: String) {}

    func prewarm() {
        lock.lock()
        defer { lock.unlock() }
        guard let manager, ready else { return }
        Self.warmUp(lane: decodeLane, manager: manager, decoderLayers: decoderLayers, program: program, model: model,
                    ifIdleFor: Self.warmUpAfterIdle, reason: "keyboard")
    }

    func beginUtterance() throws -> UtteranceSession {
        lock.lock()
        defer { lock.unlock() }
        guard let manager, ready else { throw SpeechEngineError.notReady }
        // Queued before the utterance can queue anything, so its first decode finds a warm model.
        Self.warmUp(lane: decodeLane, manager: manager, decoderLayers: decoderLayers, program: program, model: model,
                    ifIdleFor: Self.warmUpAfterIdle, reason: "dictation")
        return ParakeetUtterance(manager: manager, decoderLayers: decoderLayers, lane: decodeLane)
    }

    func unload() {
        lock.lock()
        let manager = self.manager
        let lane = decodeLane
        let previous = cleanupTask
        self.manager = nil
        program = nil
        ready = false
        cleanupTask = Task {
            await previous?.value
            await lane.drain()
            if let manager { await manager.cleanup() }
        }
        lock.unlock()
    }

    func unloadAndWait() async {
        unload()
        let cleanup = lock.withLock { cleanupTask }
        await cleanup?.value
    }
}

/// One dictation: buffer while talking, trim silence, decode once on finish.
/// One dictation for a batch model. Audio is cut into segments of about 20 s at pauses
/// between words (`RollingSegmenter`) and each segment is decoded in the background while the
/// person keeps talking, one at a time and in order. Memory stays flat however long the
/// dictation runs, `textSoFar` grows segment by segment, and the wait after stop covers only
/// the last segment.
final class ParakeetUtterance: UtteranceSession {
    private let session: RollingRecognitionSession

    init(manager: AsrManager, decoderLayers: Int, lane: SerialRecognitionDecoder) {
        session = RollingRecognitionSession(decodeSegment: { segment in
            let doubts = SegmentDoubts()
            let text = try await lane.run {
            let audio = SilenceTrimmer.trim(segment)
            guard !audio.isEmpty else { return "" }
            let padded = audio.count < 16_000 ? audio + [Float](repeating: 0, count: 16_000 - audio.count) : audio
            // A fresh decoder state per segment, on purpose. Carrying the previous segment's
            // state across the cut raised WER from 12.96% to 14.65% on 394 of Zayd's dictations
            // (245 worse, 40 better) and blanked or clipped segment openings; priming with the last
            // ten pieces was also worse (docs/research/2026-11-18-model-lab.md). FluidAudio ignores
            // this state anyway for a segment over 15 s, which it decodes in fresh windows.
            var state = TdtDecoderState.make(decoderLayers: decoderLayers)
            let result = try await manager.transcribe(padded, decoderState: &state)
            // The joint's probability for each piece it emitted: the words it was least sure of
            // can be offered for a one-tap fix in the keyboard (`DoubtfulWords`).
            let pieces = (result.tokenTimings ?? []).map { (piece: $0.token, confidence: $0.confidence) }
            doubts.set(DoubtfulWords.candidates(DoubtfulWords.words(pieces: pieces)))
            return SegmentText.cleaned(result.text)
            }
            return RecognizedSegment(text: text, doubts: doubts.value)
        })
    }

    var audioSeconds: Double { session.audioSeconds }
    var textSoFar: String { session.textSoFar }
    var failure: Error? { session.failure }
    var doubtfulWords: [DoubtfulWord] { session.doubtfulWords }
    var availableAudioSamples: Int { session.availableSamples }
    func feed(_ samples: [Float]) { session.feed(samples) }
    func finish() async throws -> String { try await session.finish() }
    func cancel() { session.cancel() }
}

/// Carries one segment's doubtful words out of the decode lane, which returns only text.
private final class SegmentDoubts: @unchecked Sendable {
    private let lock = NSLock()
    private var words: [DoubtfulWord] = []
    func set(_ words: [DoubtfulWord]) { lock.withLock { self.words = words } }
    var value: [DoubtfulWord] { lock.withLock { words } }
}

/// Drops leading and trailing silence before a batch decode, keeping a margin so soft word
/// edges survive. Energy gate on 20 ms frames, relative to the loudest frame so a quiet
/// speaker is not trimmed away, with an absolute floor for true silence.
enum SilenceTrimmer {
    static func trim(_ samples: [Float], frame: Int = 320, margin: Int = 4_800) -> [Float] {
        guard samples.count > frame * 4 else { return samples }
        let frames = samples.count / frame
        var energies = [Float](repeating: 0, count: frames)
        for index in 0..<frames {
            var sum: Float = 0
            let base = index * frame
            for offset in 0..<frame {
                let value = samples[base + offset]
                sum += value * value
            }
            energies[index] = (sum / Float(frame)).squareRoot()
        }
        let loudest = energies.max() ?? 0
        let threshold = max(loudest * 0.05, 0.003)
        guard let first = energies.firstIndex(where: { $0 >= threshold }),
              let last = energies.lastIndex(where: { $0 >= threshold }) else { return [] }
        let start = max(0, first * frame - margin)
        let end = min(samples.count, (last + 1) * frame + margin)
        return Array(samples[start..<end])
    }
}

/// A pinned Hugging Face model snapshot: exact files at an exact revision, each with the hash
/// Hugging Face records for it, so the download is reproducible, verified, and nothing beyond
/// the runtime files (no source packages, no samples) lands. Generate the list with
/// `scripts/pin_hf_snapshot.py <repo> <revision> [prefixes]`.
struct HuggingFaceSnapshot: Sendable {
    struct File: Sendable {
        let path: String
        let bytes: Int64
        let hash: FileDigest
    }

    let repo: String
    let revision: String
    let files: [File]
    /// Copies made after download, `(source, destination)`, for loaders that expect other names.
    var aliases: [(String, String)] = []

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    /// FluidVoice-Labs/fluid-speech-mini-coreml, CC BY 4.0.
    static let fluidSpeechMini = HuggingFaceSnapshot(
        repo: "FluidVoice-Labs/fluid-speech-mini-coreml",
        revision: "d81c3160dfe5a5e1f8f7267164a07d30617a3a1a",
        // FluidVoice-Labs/fluid-speech-mini-coreml at d81c3160dfe5a5e1f8f7267164a07d30617a3a1a: 24 files, 252,730,493 bytes.
        files: [
            .init(path: "Decoder.mlmodelc/analytics/coremldata.bin", bytes: 243, hash: .sha256("d4beee43a6eab29b2adcc298f2e8582e8fb79d5fe3aa9f1ab692ade681ca369d")),
            .init(path: "Decoder.mlmodelc/coremldata.bin", bytes: 491, hash: .sha256("6094d06d05c1ca4599c7b13c9a4ca7c00826ee2396796cf3084ce602a9884468")),
            .init(path: "Decoder.mlmodelc/metadata.json", bytes: 3_373, hash: .gitBlob("a79debb5125b7c1a6a81e6a4445912c96474c0ee")),
            .init(path: "Decoder.mlmodelc/model.mil", bytes: 13_411, hash: .gitBlob("428742162c9e8b2b1a020e4a47da87adb87e7af0")),
            .init(path: "Decoder.mlmodelc/weights/weight.bin", bytes: 11_845_120, hash: .sha256("d173e381488d07fd7648e2ccecbfb1bceff0457d75461550b26ba7fa2d23309a")),
            .init(path: "Encoder.mlmodelc/analytics/coremldata.bin", bytes: 243, hash: .sha256("3a3caa2c6aec983d94a5659eff09a00f77077147ea6726b8ddfdf022f0238ce9")),
            .init(path: "Encoder.mlmodelc/coremldata.bin", bytes: 427, hash: .sha256("494d8e2ce30b37bcdf494b3ba7ddf6e1bc921b9a59e369a9efd44d013ca3bf7d")),
            .init(path: "Encoder.mlmodelc/metadata.json", bytes: 2_906, hash: .gitBlob("49b43277d5d42ac49af5a9e6bcec63195acbb76c")),
            .init(path: "Encoder.mlmodelc/model.mil", bytes: 712_643, hash: .gitBlob("69c0308b882eae9413bd787f757c80ee46a7f2bb")),
            .init(path: "Encoder.mlmodelc/weights/weight.bin", bytes: 233_096_704, hash: .sha256("cf0b61022de8c698984a8c7185c2d093fa744694621881ff062c46fee2546131")),
            .init(path: "JointDecision.mlmodelc/analytics/coremldata.bin", bytes: 243, hash: .sha256("9e767d69e1092b27b28d9f236b9cbcded58ff3891e320cba7855e2c24e803d69")),
            .init(path: "JointDecision.mlmodelc/coremldata.bin", bytes: 462, hash: .sha256("284b235c08cd4769202af017f854deace69c0209c29f2253a2073bb68d58d38d")),
            .init(path: "JointDecision.mlmodelc/metadata.json", bytes: 2_790, hash: .gitBlob("f838342b52059cd8b06bf6bedd185bb0c7ed1cac")),
            .init(path: "JointDecision.mlmodelc/model.mil", bytes: 7_547, hash: .gitBlob("18e706e2e2d4a78ad825a1a0542af639f52b3c62")),
            .init(path: "JointDecision.mlmodelc/weights/weight.bin", bytes: 6_350_284, hash: .sha256("f991f65979c1b3fee3db39a645aa87e6bef1a304ed1816d074b17479bea797fc")),
            .init(path: "LICENSE", bytes: 18_657, hash: .gitBlob("da6ab6cc8f333d7e89a99812866df8f24374d47c")),
            .init(path: "NOTICE", bytes: 690, hash: .gitBlob("ab1383ddb9427e377b5752cea97d2a0a3411dbc9")),
            .init(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", bytes: 243, hash: .sha256("c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d")),
            .init(path: "Preprocessor.mlmodelc/coremldata.bin", bytes: 486, hash: .sha256("dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d")),
            .init(path: "Preprocessor.mlmodelc/metadata.json", bytes: 2_841, hash: .gitBlob("06162c58cf2f5343a0e60f36f843bcdf3cc58527")),
            .init(path: "Preprocessor.mlmodelc/model.mil", bytes: 28_181, hash: .gitBlob("f987e2479228436c49189aa47edb376db74dcff5")),
            .init(path: "Preprocessor.mlmodelc/weights/weight.bin", bytes: 491_072, hash: .sha256("129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea")),
            .init(path: "config.json", bytes: 314, hash: .gitBlob("88cccfe091f2335ba8f3af8d91bf378a35314b93")),
            .init(path: "parakeet_vocab.json", bytes: 151_122, hash: .gitBlob("c684822ec3b671ebc449c433a7012398d39b8bb0")),
        ],
        // FluidAudio's v3 loader opens JointDecisionv3.mlmodelc. Fluid Mini's joint has the
        // same required outputs (token_id, token_prob, duration) without the top-K pair. This
        // copy is the fallback; `prepare` replaces it with `FluidMiniJointTopK`, the same joint
        // plus the top-K pair the spelled-letter rule reads.
        aliases: [("JointDecision.mlmodelc", "JointDecisionv3.mlmodelc")])

    func isComplete(at directory: URL) -> Bool {
        aliases.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.1).path) }
            && files.allSatisfy { ModelDownloader.size(of: directory.appendingPathComponent($0.path)) == $0.bytes }
    }

    /// Downloads whatever is missing or the wrong size on the background model session,
    /// verifies every file against its pinned hash, and keeps the folder out of backups.
    func download(to directory: URL, progress: @escaping @Sendable (Double, String) -> Void) async throws {
        let remote = files.map { file in
            RemoteFile(url: URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file.path)")!,
                       destination: directory.appendingPathComponent(file.path),
                       bytes: file.bytes, digest: file.hash)
        }
        let label = repo.split(separator: "/").last.map(String.init) ?? repo
        try await ModelDownloader.shared.fetch(remote) { done, total in
            progress(total > 0 ? Double(done) / Double(total) : 0, label)
        }
        let manager = FileManager.default
        for (source, destination) in aliases {
            let target = directory.appendingPathComponent(destination)
            guard !manager.fileExists(atPath: target.path) else { continue }
            try manager.copyItem(at: directory.appendingPathComponent(source), to: target)
        }
        ModelDownloader.excludeFromBackup(directory)
        progress(1, "loading")
    }
}
