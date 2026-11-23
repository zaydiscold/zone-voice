// by zayd/cold @ zayd.wtf

import Foundation
import ZoneCore

/// Deletes Core ML compile caches this app can never use again (see `CompiledModelCache`):
/// copies compiled for an older data container path or an older iOS build, and compiles that
/// were killed part way. They can reach tens of gigabytes, 1.14 GB per
/// Fluid Speech Mini compile. Runs off the main actor after a model is ready, so the compile
/// in use is complete and named by the current container.
enum CompiledModelJanitor {
    /// The app's Core ML compile cache, `Library/Caches/<bundle id>/com.apple.e5rt.e5bundlecache`.
    static var root: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let bundleID = Bundle.main.bundleIdentifier else { return nil }
        return caches.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent(CompiledModelCache.directoryName, isDirectory: true)
    }

    private static var osBuild: String? {
        CompiledModelCache.osBuild(fromVersionString: ProcessInfo.processInfo.operatingSystemVersionString)
    }

    /// A model's compiled entries: those whose descriptors name the model's directory, plus those
    /// its own decode was seen using on this OS build (`remember`). iOS 26's descriptors name a
    /// content hash instead of the model, so without the second set the delete, the storage
    /// figure and the room check before a load all missed Fluid Mini's 1.2 GB there.
    static func entries(for model: URL) -> [URL] {
        guard let root else { return [] }
        var found = CompiledModelCache.entries(in: root, forModelDirectory: model)
        let seen = Set(found.map { $0.resolvingSymlinksInPath().path })
        for entry in learned(for: model)?.existing(in: root, osBuild: osBuild) ?? []
        where !seen.contains(entry.resolvingSymlinksInPath().path) {
            found.append(entry)
        }
        return found
    }

    static func bytes(for model: URL) -> Int64 {
        entries(for: model).reduce(0) { $0 + DiskUsage.bytes(at: $1) }
    }

    /// Only the entries found through descriptors; for the load journal's comparison.
    static func descriptorMatchedBytes(for model: URL) -> Int64 {
        guard let root else { return 0 }
        return CompiledModelCache.entries(in: root, forModelDirectory: model).reduce(0) { $0 + DiskUsage.bytes(at: $1) }
    }

    /// Caller has unloaded and drained the model and prevents any new preparation.
    static func remove(for model: URL) throws {
        for entry in entries(for: model) {
            try FileManager.default.removeItem(at: entry)
        }
        UserDefaults.standard.removeObject(forKey: learnedKey(model))
    }

    /// Records the cache entries holding `programFiles`, the files the model's decode used.
    static func remember(programFiles: [URL], for model: URL) {
        guard let root, let osBuild, !programFiles.isEmpty else { return }
        let learned = CompiledModelCache.LearnedEntries(files: programFiles, root: root, osBuild: osBuild)
        guard !learned.entries.isEmpty, let data = try? JSONEncoder().encode(learned) else { return }
        UserDefaults.standard.set(data, forKey: learnedKey(model))
    }

    private static func learned(for model: URL) -> CompiledModelCache.LearnedEntries? {
        UserDefaults.standard.data(forKey: learnedKey(model))
            .flatMap { try? JSONDecoder().decode(CompiledModelCache.LearnedEntries.self, from: $0) }
    }

    private static func learnedKey(_ model: URL) -> String { "zone.compiledEntries." + model.lastPathComponent }

    static func sweep() {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let bundleID = Bundle.main.bundleIdentifier else { return }
        let root = caches.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent(CompiledModelCache.directoryName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let container = CompiledModelCache.containerID(inPath: NSHomeDirectory())
        let build = CompiledModelCache.osBuild(fromVersionString: ProcessInfo.processInfo.operatingSystemVersionString)
        let stale = CompiledModelCache.staleEntries(in: root, currentContainerID: container, currentOSBuild: build)
        guard !stale.isEmpty else { return }
        var freed: Int64 = 0
        var removed = 0
        for entry in stale {
            let bytes = DiskUsage.bytes(at: entry)
            do {
                try FileManager.default.removeItem(at: entry)
                freed += bytes
                removed += 1
            } catch {
                ZoneLog.coordinator.error("compiled model cache: could not remove \(entry.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        ZoneLog.coordinator.notice("compiled model cache: removed \(removed) stale entries, \(freed / 1_000_000) MB (container \(container ?? "unknown", privacy: .public), build \(build ?? "unknown", privacy: .public))")
    }
}
