// by zayd/cold @ zayd.wtf

import Foundation
import FluidAudio
import ZoneCore

/// Logical file sizes, split so a small download is not confused with its prepared runtime.
/// These are not allocated APFS bytes or a guarantee of immediately reclaimed free space.
struct ModelStorageBreakdown: Sendable {
    let modelFiles: Int64
    let preparedFiles: Int64
    var total: Int64 { modelFiles + preparedFiles }

    init(directory: URL?, preparedFiles: Int64) {
        modelFiles = directory.map { DiskUsage.bytes(at: $0) } ?? 0
        self.preparedFiles = preparedFiles
    }
}

extension SpeechModel {
    var storageBreakdown: ModelStorageBreakdown {
        let directory = assetDirectory
        let prepared: Int64
        switch self {
        case .fluidSpeechMini, .parakeet110m:
            prepared = directory.map { CompiledModelJanitor.bytes(for: $0) } ?? 0
        default:
            prepared = 0
        }
        return ModelStorageBreakdown(directory: directory, preparedFiles: prepared)
    }

    /// Exact historical locations, independent of the visible catalog. Never delete a
    /// parent Models directory: speaker models and future downloads may share it.
    var assetDirectory: URL? {
        switch self {
        // Where moonshine-swift 0.1.5 kept them: Application Support/MoonshineModels/stt-en-<arch>,
        // with ModelArch raw values 2 (Tiny), 4 (Small) and 5 (Medium) streaming.
        case .moonshineTiny: return Self.moonshineDirectory("stt-en-2")
        case .moonshineSmall: return Self.moonshineDirectory("stt-en-4")
        case .moonshineMedium: return Self.moonshineDirectory("stt-en-5")
        case .parakeet110m: return AsrModels.defaultCacheDirectory(for: .tdtCtc110m)
        case .fluidSpeechMini: return ParakeetEngine.Model.fluidSpeechMini.directory
        case .appleSpeech, .appleDictation: return nil
        }
    }

    private static func moonshineDirectory(_ key: String) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MoonshineModels", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
    }
}

/// A single background inventory per library revision, never per progress tick or body render.
struct ModelLibraryInventory: Sendable {
    struct Entry: Sendable {
        let downloaded: Bool
        let storage: ModelStorageBreakdown
    }
    let entries: [SpeechModel: Entry]

    static func read(scan: @escaping @Sendable () -> [SpeechModel: Entry] = { scanDisk() }) async -> Self {
        let task = Task.detached(priority: .utility) { Self(entries: scan()) }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func scanDisk() -> [SpeechModel: Entry] {
        var entries: [SpeechModel: Entry] = [:]
        for model in SpeechModel.allCases {
            if Task.isCancelled { break }
            entries[model] = Entry(downloaded: !model.needsDownload || model.makeEngine().assetsPresent(),
                                   storage: model.storageBreakdown)
        }
        return entries
    }
}

/// Gate before hopping to MainActor: network callbacks can arrive thousands of times a second.
/// Labels do not bypass the interval (concurrent file downloads alternate them constantly).
final class ModelProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastTime: TimeInterval?
    private var lastFraction: Double = -1
    private var loading = false

    func accept(_ fraction: Double, file: String = "", now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.withLock {
            guard fraction.isFinite else { return false }
            if file == "loading" {
                guard !loading else { return false }
                loading = true
                return true
            }
            guard !loading else { return false }
            let value = min(1, max(0, fraction))
            guard value >= lastFraction, value != lastFraction else { return false }
            guard lastTime == nil || now - lastTime! >= 0.1 || value == 1 else { return false }
            lastTime = now
            lastFraction = value
            return true
        }
    }
}
