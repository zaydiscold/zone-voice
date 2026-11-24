import AVFoundation
import Darwin
import CoreML
import ExtensionFoundation
import FluidAudio
import Foundation
import OSLog
import ZoneFluidAudio
import ZoneCore

private enum WorkerJournal {
    static let log = RecordingJournal.shared(process: "worker")
    static let started = ProcessInfo.processInfo.systemUptime
    static let logger = Logger(subsystem: "wtf.zayd.zone", category: "speech-worker")
    static func step(_ name: String, _ id: UUID?, _ extra: [String: String] = [:]) {
        var fields = MemoryFootprint.journalFields()
        fields["step"] = name
        fields["pid"] = String(ProcessInfo.processInfo.processIdentifier)
        fields["uptimeMs"] = String(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))
        fields.merge(extra) { _, value in value }
        log?.log("speechWorkerStep", recording: id, fields)
        log?.flush()
        if log == nil { logger.info("Speech worker step \(name, privacy: .public)") }
    }

    /// One stage of the lab's memory measurement, on disk before the next stage starts.
    static func lab(_ step: MiniMemoryProbe.Step, _ id: UUID?, place: String) {
        var fields = step.fields
        fields["place"] = place
        fields["pid"] = String(ProcessInfo.processInfo.processIdentifier)
        log?.log("ownModelLab", recording: id, fields)
        log?.flush()
    }
}

/// What iOS allows this process: its footprint plus what is left, nil where no limit is given.
private func ownLimitBytes() -> UInt64? {
    guard let footprint = MemoryFootprint.current(), let left = MemoryFootprint.available() else { return nil }
    return footprint + left
}

/// The helper will not load Zone's speech model in a process iOS would end for it.
private struct TooLittleRoom: CustomNSError {
    static let errorDomain = SpeechHelperRefusal.domain
    var errorCode: Int { SpeechHelperRefusal.tooLittleRoom }
    var errorUserInfo: [String: Any] { ["workerStage": "tooLittleRoom"] }
}

@main
struct ZoneSpeechWorker: AppExtension {
    var configuration: ConnectionHandler {
        // First act, before anything else runs: what this process weighs and what iOS allows it.
        WorkerJournal.step("launched", nil)
        return ConnectionHandler(onConnection: { connection in
            guard let folder = WorkerStorage.coordinationDirectory,
                  let lease = try? WorkerStorage.lease("worker.lock", in: folder) else { return false }
            WorkerJournal.step("connected", nil)
            connection.exportedInterface = NSXPCInterface(with: SpeechWorkerService.self)
            connection.exportedObject = WorkerService()
            connection.invalidationHandler = {
                Task { await WorkerEngine.shared.clientDisconnected(); try? lease.close() }
            }
            connection.resume()
            return true
        })
    }
}

private final class WorkerService: NSObject, SpeechWorkerService {
    let engine = WorkerEngine.shared

    func endIdleSession() {
        Task { await engine.endIdleSession() }
    }

    func ping(reply: @escaping (Int32) -> Void) { reply(ProcessInfo.processInfo.processIdentifier) }

    func limits(reply: @escaping (Int32, UInt64, UInt64) -> Void) {
        let footprint = MemoryFootprint.current() ?? 0
        let left = MemoryFootprint.available() ?? 0
        Task {
            // A helper too small for the model clears what it can never use before it answers,
            // because the host lets it go right after.
            await engine.tidy()
            reply(ProcessInfo.processInfo.processIdentifier, footprint, left)
        }
    }

    func probe(_ units: String, windows: Int, recording: String, reply: @escaping (Data?, NSError?) -> Void) {
        let id = UUID(uuidString: recording)
        guard let units = MiniMemoryProbeUnits(rawValue: units), let directory = SharedMiniModel.directory else {
            return reply(nil, WorkerDiagnostic.error(CocoaError(.fileNoSuchFile)))
        }
        Task.detached(priority: .userInitiated) {
            // This process is expendable, so the guard is off: the point is to find the stage
            // iOS ends it at. Each stage is on disk before it starts.
            let options = MiniMemoryProbe.Options(directory: directory, units: units, windows: windows, guarded: false)
            let result = MiniMemoryProbe.run(options) { WorkerJournal.lab($0, id, place: "helper") }
            await self.engine.tidy()
            reply(try? JSONEncoder().encode(result.fields), nil)
        }
    }

    func cacheSize(reply: @escaping (Int64) -> Void) {
        Task { await engine.tidy(); reply(await engine.measure()) }
    }

    func clearCache(reply: @escaping (Bool) -> Void) {
        Task {
            do { try await engine.finishRemoval(); reply(true) }
            catch { reply(false) }
        }
    }

    func warm(_ recording: String, reply: @escaping (NSError?) -> Void) {
        let id = UUID(uuidString: recording)
        WorkerJournal.step("warmReceived", id)
        Task {
            do { _ = try await engine.load(recording: id); WorkerJournal.step("warmReply", id); reply(nil) }
            catch { WorkerJournal.step("warmError", id, ["code": JournalFormat.error(error)]); reply(WorkerDiagnostic.error(error)) }
        }
    }

    func recognize(_ request: String, recording: String, reply: @escaping (Data?, NSError?) -> Void) {
        guard let fileID = UUID(uuidString: request), let id = UUID(uuidString: recording) else {
            return reply(nil, WorkerDiagnostic.error(CocoaError(.fileReadInvalidFileName)))
        }
        WorkerJournal.step("requestReceived", id)
        Task {
            do {
                let result = try await engine.recognize(fileID, recording: id)
                WorkerJournal.step("reply", id)
                reply(result, nil)
            } catch {
                WorkerJournal.step("requestError", id, ["code": JournalFormat.error(error)])
                reply(nil, WorkerDiagnostic.error(error))
            }
        }
    }

    func cancel(_ request: String) {
        guard let id = UUID(uuidString: request) else { return }
        Task { await engine.cancel(id) }
    }
}

private actor WorkerEngine {
    static let shared = WorkerEngine()
    private var removal: Task<Void, Error>?
    private var activeCalls = 0
    private func beginCall() { activeCalls += 1 }
    private func endCall() { activeCalls -= 1 }

    func clientDisconnected() async {
        // A dead host cannot consume the answer. The host owns the lifetime of this process.
        jobs.values.forEach { $0.cancel() }
        let pending = Array(jobs.values)
        // The next host can use a completed compile even if this host disappeared.
        _ = await loading?.result
        for job in pending { _ = await job.result }
        loading = nil
        cacheLease = nil
    }

    func endIdleSession() {
        guard activeCalls == 0 else { return }
        // Core ML can retain mapped programs after its manager is released.
        loading = nil
        exit(EXIT_SUCCESS)
    }

    private var cache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier!)
            .appendingPathComponent(CompiledModelCache.directoryName)
    }

    private var cacheLease: FileHandle?

    private func ownCache() async throws {
        let folder = cache.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        while cacheLease == nil {
            try Task.checkCancellation()
            let fd = open(folder.appendingPathComponent("zone-model-use.lock").path,
                          O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK | O_CLOEXEC, S_IRUSR | S_IWUSR)
            if fd >= 0 {
                cacheLease = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            } else {
                guard errno == EWOULDBLOCK else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private var preparing = false

    /// Removes what this helper can never use. With room for the model that is only the
    /// temporary copies of a stopped preparation. Without room (an iPhone gives the helper
    /// 35 MB) it is everything: no program in this cache will ever be read. Deleting needs
    /// almost no memory, so it is safe in a helper too small for the model.
    func tidy() async {
        guard !preparing, jobs.isEmpty else { return }
        beginCall()
        defer { endCall() }
        do {
            // Keep the lease a loaded model already holds; give back one taken only for this.
            let held = cacheLease != nil
            try await ownCache()
            defer { if !held { cacheLease = nil } }
            guard !preparing, jobs.isEmpty else { return }
            if WorkerHealth.hasRoom(limitBytes: ownLimitBytes()) {
                let count = try WorkerStorage.sweepTemporaryPrograms(in: cache)
                WorkerJournal.step("cacheSweep", nil, ["removed": String(count)])
            } else {
                loading = nil
                let found = WorkerStorage.contents(of: cache)
                let freed = try WorkerStorage.removeEverything(in: cache)
                WorkerStorage.preparedForCurrentSystem = false
                WorkerJournal.step("cacheCleared", nil, ["bytes": String(freed), "strandedCopies": String(found.strandedCopies),
                                                         "strandedBytes": String(found.strandedBytes)])
            }
            let left = WorkerStorage.contents(of: cache)
            WorkerStorage.bytes = left.total
            WorkerStorage.strandedBytes = left.strandedBytes
            if left.strandedBytes == 0 { WorkerStorage.markTidied() }
        } catch { WorkerJournal.step("sweepError", nil, ["code": JournalFormat.error(error)]) }
    }

    func measure() -> Int64 {
        beginCall()
        defer { endCall() }
        var bytes: Int64 = 0
        if let files = FileManager.default.enumerator(at: cache, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            for case let file as URL in files {
                let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if info?.isRegularFile == true { bytes += Int64(info?.fileSize ?? 0) }
            }
        }
        WorkerStorage.bytes = bytes
        WorkerStorage.strandedBytes = WorkerStorage.contents(of: cache).strandedBytes
        return bytes
    }

    func finishRemoval() async throws {
        beginCall()
        defer { endCall() }
        if let removal { return try await removal.value }
        guard WorkerStorage.needsRemoval else { return }
        let task = Task { try await purge() }
        removal = task
        defer { removal = nil }
        try await task.value
    }

    private func purge() async throws {
        let token = WorkerStorage.request
        let pending = Array(jobs.values)
        pending.forEach { $0.cancel() }
        loading?.cancel()
        _ = await loading?.result
        loading = nil
        for job in pending { _ = await job.result }
        try await ownCache()
        defer { cacheLease = nil }
        if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }
        WorkerStorage.preparedForCurrentSystem = false
        WorkerStorage.bytes = 0
        WorkerStorage.strandedBytes = 0
        WorkerStorage.acknowledge(token)
    }

    typealias Decode = MiniComputeRouter.Decode
    private var loading: Task<Decode, Error>?
    private var jobs: [UUID: Task<Data, Error>] = [:]
    private var loadMs = 0
    private var firstPredictionMs = 0
    private var requests = 0

    func load(permitRemoval: Bool = true, recording: UUID?) async throws -> Decode {
        beginCall()
        defer { endCall() }
        if WorkerStorage.needsRemoval || removal != nil {
            guard permitRemoval else { throw CancellationError() }
            try await finishRemoval()
        }
        guard SharedMiniModel.verified, let directory = SharedMiniModel.directory else { throw CocoaError(.fileNoSuchFile) }
        // Never prepare or load where iOS would end the process for it: each such end during
        // preparation left 1.2 GB behind on the iPhone (November 22, 2026).
        guard WorkerHealth.hasRoom(limitBytes: ownLimitBytes()) else {
            WorkerJournal.step("refusedTooLittleRoom", recording)
            throw TooLittleRoom()
        }
        if let loading { WorkerJournal.step("reuseLoad", recording); return try await loading.value }
        let start = Date()
        preparing = true
        let task = Task<Decode, Error> {
            defer { preparing = false }
            try await ownCache()
            try Task.checkCancellation()
            let swept = try WorkerStorage.sweepTemporaryPrograms(in: cache)
            defer {
                do { _ = try WorkerStorage.sweepTemporaryPrograms(in: cache) }
                catch { WorkerJournal.step("sweepError", recording, ["code": JournalFormat.error(error)]) }
            }
            WorkerJournal.step("cacheSweep", recording, ["removed": String(swept)])
            let volume = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            let osBuild = CompiledModelCache.osBuild(fromVersionString: ProcessInfo.processInfo.operatingSystemVersionString)
            for stale in CompiledModelCache.staleEntries(in: cache, currentContainerID: nil, currentOSBuild: osBuild) {
                try FileManager.default.removeItem(at: stale)
            }
            let cold = WorkerStorage.cacheIsPrepared(root: cache, build: osBuild) == false
            WorkerJournal.step("spaceCheck", recording, ["cold": String(cold),
                "free": volume?.volumeAvailableCapacityForImportantUsage.map(String.init) ?? "unknown"])
            try WorkerStorage.checkRoom(prepared: !cold, free: volume?.volumeAvailableCapacityForImportantUsage)
            WorkerJournal.step("loadModels", recording)
            let models = try await Self.loadModels(at: directory, recording: recording)
            try Task.checkCancellation()
            let manager = MiniModelLoader.manager(at: directory, repeatMargin: nil)
            WorkerJournal.step("attachModels", recording)
            try await manager.loadModels(models)
            let decode = ParakeetUtterance.decoder(manager: manager, decoderLayers: await manager.decoderLayerCount, lane: SerialRecognitionDecoder())
            loadMs = Int(Date().timeIntervalSince(start) * 1000)
            let first = Date()
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            WorkerJournal.step("firstPrediction", recording)
            _ = try await manager.transcribe([Float](repeating: 0, count: FluidWarmUp.samples), decoderState: &state)
            firstPredictionMs = Int(Date().timeIntervalSince(first) * 1000)
            WorkerStorage.rememberPrepared(root: cache, build: osBuild)
            WorkerStorage.preparedForCurrentSystem = true
            WorkerJournal.step("prepared", recording, ["cold": String(cold), "loadMs": String(loadMs),
                                                      "firstPredictionMs": String(firstPredictionMs)])
            _ = measure()
            return decode
        }
        loading = task
        do { return try await task.value } catch { loading = nil; throw error }
    }

    func cancel(_ id: UUID) { jobs[id]?.cancel() }

    func recognize(_ id: UUID, recording: UUID) async throws -> Data {
        beginCall()
        defer { endCall() }
        if WorkerStorage.needsRemoval || removal != nil { try await finishRemoval() }
        guard jobs[id] == nil, let url = SharedMiniModel.recording(id) else { throw CocoaError(.fileReadUnknown) }
        let job = Task {
            let decode = try await load(permitRemoval: false, recording: recording)
            try Task.checkCancellation()
            let start = Date()
            WorkerJournal.step("openWAV", recording)
            let (text, doubts, seconds) = try await Self.decodeFile(url, with: decode, recording: recording)
            try Task.checkCancellation()
            requests += 1
            return try JSONEncoder().encode(WorkerTranscript(text: text, doubts: doubts,
                audioSeconds: seconds,
                fields: ["computeUnits": "cpuOnly", "modelLoadMs": String(loadMs),
                         "workerRequest": String(requests), "workerPID": String(ProcessInfo.processInfo.processIdentifier),
                         "firstPredictionMs": String(firstPredictionMs), "recognitionMs": String(Int(Date().timeIntervalSince(start) * 1000)),
                         "workerMB": MemoryFootprint.current().map(MemoryFootprint.megabytes) ?? "unknown"]))
        }
        jobs[id] = job
        defer { jobs[id] = nil }
        return try await job.value
    }

    private nonisolated static func loadModels(at directory: URL, recording: UUID?) async throws -> AsrModels {
        // This worker only loads the verified v3 Mini snapshot. Use FluidAudio's component
        // names and model container so each synchronous Core ML load has a durable boundary.
        typealias Names = ModelNames.ASR
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        func component(_ name: String) throws -> MLModel {
            try Task.checkCancellation()
            WorkerJournal.step("componentBegin", recording, ["component": name])
            do {
                let model = try MLModel(contentsOf: directory.appendingPathComponent(name), configuration: config)
                WorkerJournal.step("componentEnd", recording, ["component": name])
                return model
            } catch { throw WorkerDiagnostic.error(error, stage: name) }
        }
        WorkerJournal.step("vocabulary", recording)
        let data = try Data(contentsOf: directory.appendingPathComponent(Names.vocabularyFile))
        let vocabulary = try JSONDecoder().decode([Int: String].self, from: data)
        guard (0..<AsrModelVersion.v3.blankId).allSatisfy({ vocabulary[$0] != nil }) else {
            throw WorkerDiagnostic.error(CocoaError(.fileReadCorruptFile), stage: "vocabulary")
        }
        let encoder = try component(Names.encoderFile)
        let hasCTC = FileManager.default.fileExists(atPath: directory.appendingPathComponent(Names.ctcHeadFile).path)
        return try AsrModels(encoder: encoder, preprocessor: component(Names.preprocessorFile),
            decoder: component(Names.decoderFile), joint: component(Names.jointV3File),
            ctcHead: hasCTC ? component(Names.ctcHeadFile) : nil, configuration: config, vocabulary: vocabulary, version: .v3)
    }

    private nonisolated static func decodeFile(_ url: URL, with decode: @escaping Decode, recording: UUID) async throws -> (String, [DoubtfulWord], Double) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard format.channelCount == 1, format.sampleRate >= 8000,
              let target = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
              let converter = AVAudioConverter(from: format, to: target),
              let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 16000) else { throw CocoaError(.fileReadCorruptFile) }
        WorkerJournal.step("decode", recording)
        let session = ParakeetUtterance(decode: decode)
        defer { session.cancel() }
        var ended = false
        while !ended {
            try Task.checkCancellation()
            while session.availableAudioSamples < Int(buffer.frameCapacity) {
                if let error = session.failure { throw error }
                try await Task.sleep(for: .milliseconds(20))
            }
            var error: NSError?
            var readError: Error?
            let status = converter.convert(to: buffer, error: &error) { count, state in
                guard file.framePosition < file.length,
                      let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
                    state.pointee = .endOfStream
                    return nil
                }
                do { try file.read(into: input) } catch { readError = error }
                state.pointee = input.frameLength > 0 ? .haveData : .endOfStream
                return input.frameLength > 0 ? input : nil
            }
            if let readError { throw readError }
            if let error { throw error }
            guard status != .error else { throw CocoaError(.fileReadCorruptFile) }
            if buffer.frameLength > 0, let data = buffer.floatChannelData?[0] {
                session.feed(Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))))
            }
            ended = status == .endOfStream
            await Task.yield()
        }
        let text = try await withTaskCancellationHandler {
            try await session.finish()
        } onCancel: {
            session.cancel()
        }
        try Task.checkCancellation()
        return (text, session.doubtfulWords, Double(file.length) / format.sampleRate)
    }

}
