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
                guard let shared = SharedMiniModel.directory else { return Self.privateMini }
                if SharedMiniModel.verified || !FileManager.default.fileExists(atPath: Self.privateMini.path) { return shared }
                return Self.privateMini
            }
        }
        static var privateMini: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Models/fluid-speech-mini-coreml", isDirectory: true)
        }

        static let initialMigration = Task.detached(priority: .utility) { reconcileMini() }

        static func reconcileMini() {
            let start = ProcessInfo.processInfo.systemUptime
            guard let shared = SharedMiniModel.directory else {
                Journal.log("miniShareCheck", ["reason": "groupUnavailable"]); return
            }
            let snapshot = HuggingFaceSnapshot.fluidSpeechMini
            var fields = ["privatePresent": String(FileManager.default.fileExists(atPath: privateMini.path)),
                          "sharedPresent": String(FileManager.default.fileExists(atPath: shared.path)),
                          "previousMarker": String(SharedMiniModel.verified)]
            let ready: Bool
            do {
                ready = try SharedMiniModel.prepareShared(from: privateMini, to: shared, published: SharedMiniModel.verified,
                    isComplete: snapshot.isComplete, verify: snapshot.verified)
            } catch { ready = false; fields["code"] = JournalFormat.error(error) }
            SharedMiniModel.publish(ready)
            fields["verified"] = String(ready)
            fields["ms"] = String(Int((ProcessInfo.processInfo.systemUptime - start) * 1000))
            Journal.log("miniShareCheck", fields)
            if ready { Task { @MainActor in WorkerCacheClient.modelShared() } }
        }

    }

    private let router = MiniComputeRouter()
    private var lastRecordingDecoder: MiniComputeRouter.Decode?
    private var lastRecordingID: UUID?
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
        case .fluidSpeechMini:
            let path = model.directory
            let snapshot = HuggingFaceSnapshot.fluidSpeechMini
            if snapshot.isComplete(at: path) { return true }
            // The background move may have renamed the directory during the size checks.
            guard path == Model.privateMini, let shared = SharedMiniModel.directory else { return false }
            return snapshot.isComplete(at: shared)
        }
    }

    func bytesOnDisk() -> Int64 {
        if model == .fluidSpeechMini { return SpeechModel.fluidSpeechMini.storageBreakdown.total }
        return DiskUsage.bytes(at: model.directory) + CompiledModelJanitor.bytes(for: model.directory)
    }

    func removeAssets() throws {
        if model == .fluidSpeechMini {
            SharedMiniModel.publish(false)
            try SharedMiniModel.removeCopies([Model.privateMini, SharedMiniModel.directory].compactMap { $0 }, remove: removeDirectory)
        } else {
            try removeDirectory(model.directory)
        }
    }

    private func removeDirectory(_ directory: URL) throws {
        try CompiledModelJanitor.remove(for: directory)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
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
        if model == .fluidSpeechMini { await Model.initialMigration.value }
        try ensureRoomToPrepare()
        switch model {
        case .tdtCtc110m:
            _ = try await AsrModels.download(to: model.directory, version: .tdtCtc110m) { update in
                progress(update.fractionCompleted, "parakeet-tdt-ctc-110m")
            }
            ModelDownloader.excludeFromBackup(model.directory)
        case .fluidSpeechMini:
            _ = try await prepareMiniFiles(progress: progress)
        }
    }

    private func prepareMiniFiles(progress: @escaping @Sendable (Double, String) -> Void) async throws -> URL {
        await Model.initialMigration.value
        let destination = model.directory
        if destination == SharedMiniModel.directory, SharedMiniModel.verified,
           HuggingFaceSnapshot.fluidSpeechMini.isComplete(at: destination) { return destination }
        try await HuggingFaceSnapshot.fluidSpeechMini.download(to: destination, progress: progress)
        if destination == Model.privateMini { await Task.detached { Model.reconcileMini() }.value }
        return model.directory
    }

    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        if isReady { return }
        let units = Self.computeUnits(accelerated: useNeuralEngine)
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
            await Model.initialMigration.value
            try ensureRoomToPrepare()
            let directory = try await prepareMiniFiles(progress: progress)
            progress(1, "loading")
            let wantsTopK = Self.spelledLetterRepeatMargin != nil
            models = try await Task.detached(priority: .userInitiated) {
                if wantsTopK { Self.installSpelledLetterJoint(in: directory) }
                return try MiniModelLoader.load(at: directory, units: units)
            }.value
        }
        progress(1, "loading")
        // FluidAudio may also fetch Parakeet's CTC head while loading, so exclude after it.
        ModelDownloader.excludeFromBackup(model.directory)
        let manager = MiniModelLoader.manager(at: model.directory, repeatMargin: model == .fluidSpeechMini ? Self.spelledLetterRepeatMargin : nil)
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
        if let reason = takeLoadWarmUpSkipReason() {
            Journal.log("warmUpSkipped", ["reason": reason])
            return
        }
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

    private let loadWarmUpSkipReason = Locked<String?>(nil)

    func skipPendingLoadWarmUp(reason: String = "pressDuringLoad") {
        loadWarmUpSkipReason.withLock { $0 = reason }
    }

    func takeLoadWarmUpSkipReason() -> String? {
        loadWarmUpSkipReason.withLock { reason in
            defer { reason = nil }
            return reason
        }
    }

    func prewarm() {
        lock.lock()
        defer { lock.unlock() }
        guard let manager, ready, !router.canAccelerate else { return }
        Self.warmUp(lane: decodeLane, manager: manager, decoderLayers: decoderLayers, program: program, model: model,
                    ifIdleFor: Self.warmUpAfterIdle, reason: "keyboard")
    }

    private static func computeUnits(accelerated: Bool) -> MLComputeUnits {
        accelerated ? .cpuAndNeuralEngine : .cpuOnly
    }

    func configureAcceleration(enabled: Bool, foreground: Bool) {
        guard model == .fluidSpeechMini, !useNeuralEngine else { return }
        router.configure(enabled: enabled && isReady, foreground: foreground, prepare: { [router] in
            let directory = Model.fluidSpeechMini.directory
            let units = Self.computeUnits(accelerated: true)
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            let models = try AsrModels.loadLocal(from: directory, version: .v3,
                                                  configuration: configuration, encoderComputeUnits: units)
            let manager = AsrManager(config: ASRConfig(tdtConfig: TdtConfig(spelledLetterRepeatMargin:
                FluidMiniJointTopK.isInstalled(in: directory) ? Self.spelledLetterRepeatMargin : nil)))
            try await manager.loadModels(models)
            let layers = await manager.decoderLayerCount
            var state = TdtDecoderState.make(decoderLayers: layers)
            try Task.checkCancellation()
            guard router.isForeground else { throw SpeechEngineError.notReady }
            _ = try await manager.transcribe([Float](repeating: 0, count: FluidWarmUp.samples), decoderState: &state)
            Journal.log("miniAccelerationReady")
            return ParakeetUtterance.decoder(manager: manager, decoderLayers: layers,
                                             lane: SerialRecognitionDecoder(), allowed: { [weak router] in
                router?.isForeground == true
            })
        }, onFailure: { Journal.log("miniAccelerationPrepareFailed", ["error": JournalFormat.error($0)]) })
    }

    // Diagnostics times its explicitly selected engine kind. User recordings opt into routing below.
    func beginUtterance() throws -> UtteranceSession {
        try beginUtterance(recording: nil, allowAcceleration: false)
    }

    func endRecording(_ id: UUID) {
        lock.withLock {
            if lastRecordingID == id {
                lastRecordingID = nil
                lastRecordingDecoder = nil
            }
        }
    }

    func beginUtterance(recording: UUID?, allowAcceleration: Bool = true, warmUp: Bool = true, submission: AudioModelSubmission? = nil) throws -> UtteranceSession {
        lock.lock()
        defer { lock.unlock() }
        guard let manager, ready else { throw SpeechEngineError.notReady }
        if let recording, lastRecordingID == recording, let lastRecordingDecoder {
            return ParakeetUtterance(decode: lastRecordingDecoder, submission: submission)
        }
        // Queued before the utterance can queue anything, so its first decode finds a warm model.
        if warmUp && (!allowAcceleration || !router.canAccelerate) {
            Self.warmUp(lane: decodeLane, manager: manager, decoderLayers: decoderLayers, program: program, model: model,
                        ifIdleFor: Self.warmUpAfterIdle, reason: "dictation")
        }
        let decode = ParakeetUtterance.decoder(manager: manager, decoderLayers: decoderLayers, lane: decodeLane)
        let id = recording ?? UUID()
        let routed = router.session(cpu: decode, allowAcceleration: allowAcceleration, report: { [useNeuralEngine] route, elapsed in
            Journal.log("speechSegmentRecognized", recording: id, [
                "route": useNeuralEngine ? "cpuAndNeuralEngine" : route, "ms": String(Int(elapsed * 1000))])
        }, onFailure: { Journal.log("miniAccelerationRetry", recording: id, ["error": JournalFormat.error($0)]) })
        lastRecordingID = recording
        lastRecordingDecoder = recording == nil ? nil : routed
        return ParakeetUtterance(decode: routed, submission: submission)
    }

    func unload() {
        configureAcceleration(enabled: false, foreground: false)
        lock.lock()
        let manager = self.manager
        let lane = decodeLane
        let previous = cleanupTask
        lastRecordingDecoder = nil
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
        await router.waitForPreparation()
        await cleanup?.value
    }
}

extension ParakeetUtterance: UtteranceSession {}

/// A pinned Hugging Face model snapshot: exact files at an exact revision, each with the hash
/// Hugging Face records for it, so the download is reproducible, verified, and nothing beyond
/// the runtime files (no source packages, no samples) lands. Generate the list with
/// `scripts/pin_hf_snapshot.py <repo> <revision> [prefixes]`.
struct HuggingFaceSnapshot: Sendable {
    typealias File = SharedMiniModel.File

    let repo: String
    let revision: String
    let files: [File]
    /// Copies made after download, `(source, destination)`, for loaders that expect other names.
    var aliases: [(String, String)] = []

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    /// FluidVoice-Labs/fluid-speech-mini-coreml, CC BY 4.0.
    static let fluidSpeechMini = HuggingFaceSnapshot(
        repo: SharedMiniModel.identifier,
        revision: SharedMiniModel.revision,
        files: SharedMiniModel.files,
        // FluidAudio's v3 loader opens JointDecisionv3.mlmodelc. Fluid Mini's joint has the
        // same required outputs (token_id, token_prob, duration) without the top-K pair. This
        // copy is the fallback; `prepare` replaces it with `FluidMiniJointTopK`, the same joint
        // plus the top-K pair the spelled-letter rule reads.
        aliases: [("JointDecision.mlmodelc", "JointDecisionv3.mlmodelc")])

    func verified(at directory: URL) throws -> Bool {
        guard isComplete(at: directory) else { return false }
        return try files.allSatisfy { try $0.hash.matches(fileAt: directory.appendingPathComponent($0.path)) }
    }

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
        if directory == SharedMiniModel.directory, revision == SharedMiniModel.revision {
            let ready = try verified(at: directory)
            SharedMiniModel.publish(ready)
            Journal.log("miniShareCheck", ["verified": String(ready), "source": "download"])
            if ready { Task { @MainActor in WorkerCacheClient.modelShared() } }
        }
        progress(1, "loading")
    }
}
