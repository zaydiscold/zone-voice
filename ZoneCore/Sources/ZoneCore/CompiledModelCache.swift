// by zayd/cold @ zayd.wtf

import Foundation

/// Finds Core ML compile-cache entries that can never be used again.
///
/// Core ML compiles each model for the device on first load and keeps the result under
/// `Library/Caches/<bundle id>/com.apple.e5rt.e5bundlecache/<OS build>/<key>/<key>.bundle`.
/// The key includes the model's absolute path, and that path contains the app's data container
/// UUID, which iOS changes across some installs and restarts. Each change recompiles the model
/// and leaves the old copy behind for good. Fluid Speech Mini compiles to a 1.14 GB CPU program,
/// and one test phone held 19 of them (22.4 GB) with 5.85 GB of the disk free.
///
/// An entry is stale when:
/// - it sits under an OS build directory other than the running one (an iOS update), or
/// - every descriptor (`*.e5`) in it names a model inside another app data container, or
/// - it is an abandoned compile (`.tmp.` in its bundle name) older than `abandonedAfter`.
/// Anything that cannot be read or matched is kept.
public enum CompiledModelCache {
    public static let directoryName = "com.apple.e5rt.e5bundlecache"
    /// A compile in progress writes a `.tmp.` bundle and renames it when done.
    public static let abandonedAfter: TimeInterval = 3_600

    /// Only entries whose every readable descriptor names this exact model directory.
    /// The Library-relative suffix survives iOS data-container moves. Unknown or mixed
    /// entries stay intact; never clear all Core ML caches (other models use them too).
    public static func entries(in root: URL, forModelDirectory model: URL,
                               fileManager: FileManager = .default) -> [URL] {
        let path = model.standardizedFileURL.path
        let marker = path.range(of: "/Library/", options: .backwards).map { String(path[$0.lowerBound...]) } ?? path
        let needle = marker + "/"
        var result: [URL] = []
        for build in (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            guard isDirectory(build, fileManager) else { continue }
            for entry in (try? fileManager.contentsOfDirectory(at: build, includingPropertiesForKeys: nil)) ?? [] {
                guard isDirectory(entry, fileManager) else { continue }
                let bundles = (try? fileManager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? []
                let perBundle = bundles.filter { isDirectory($0, fileManager) }.map { descriptors(in: $0, fileManager: fileManager) }
                guard !perBundle.isEmpty, perBundle.allSatisfy({ !$0.isEmpty }) else { continue }
                let files = perBundle.flatMap { $0 }
                guard !files.isEmpty, files.allSatisfy({ file in
                    guard let data = try? Data(contentsOf: file), data.count <= 256 * 1024 else { return false }
                    return String(decoding: data, as: UTF8.self).contains(needle)
                }) else { continue }
                result.append(entry)
            }
        }
        return result
    }

    /// A model's entries as seen from the files it used, for OS builds whose descriptors do not
    /// name the model's path (iOS 26.2 and macOS 26.1 name a content hash, `<build>/<hash>/model.milhash`,
    /// so `entries(in:forModelDirectory:)` finds nothing there). Built from the program files learned
    /// by residency after the model's own decode (`CompiledProgramReadahead.Program.learn`) and kept
    /// by the app per model, for the OS build it was learned on.
    public struct LearnedEntries: Codable, Equatable, Sendable {
        public var osBuild: String
        /// Entry directory names directly under the build directory.
        public var entries: [String]

        /// The entries holding `files`; files outside `root/osBuild` are ignored.
        public init(files: [URL], root: URL, osBuild: String) {
            self.osBuild = osBuild
            let base = root.appendingPathComponent(osBuild, isDirectory: true).resolvingSymlinksInPath().path + "/"
            var names: [String] = []
            for file in files {
                let path = file.resolvingSymlinksInPath().path
                guard path.hasPrefix(base), let name = path.dropFirst(base.count).split(separator: "/").first,
                      !name.isEmpty, name != ".", name != ".." else { continue }
                if !names.contains(String(name)) { names.append(String(name)) }
            }
            entries = names
        }

        /// The entries still present under `root`, only when they were learned on `osBuild`.
        public func existing(in root: URL, osBuild current: String?, fileManager: FileManager = .default) -> [URL] {
            guard let current, current == osBuild else { return [] }
            let build = root.appendingPathComponent(osBuild, isDirectory: true)
            return entries.map { build.appendingPathComponent($0, isDirectory: true) }
                .filter { CompiledModelCache.isDirectory($0, fileManager) }
        }
    }

    /// The data container UUID in a path such as
    /// `/private/var/mobile/Containers/Data/Application/<UUID>/Library/...`, uppercased.
    public static func containerID(inPath path: String) -> String? {
        let marker = "/Containers/Data/Application/"
        guard let range = path.range(of: marker) else { return nil }
        let rest = path[range.upperBound...]
        let candidate = rest.prefix(36)
        guard candidate.count == 36, UUID(uuidString: String(candidate)) != nil else { return nil }
        return candidate.uppercased()
    }

    /// Every data container UUID named in a compiled bundle's descriptor (a binary file that
    /// stores the source model's path as plain text).
    public static func containerIDs(inDescriptor data: Data) -> Set<String> {
        let text = String(decoding: data, as: UTF8.self)
        var found = Set<String>()
        var search = text.startIndex..<text.endIndex
        while let range = text.range(of: "/Containers/Data/Application/", range: search) {
            if let id = containerID(inPath: String(text[range.lowerBound...].prefix(80))) {
                found.insert(id)
            }
            search = range.upperBound..<text.endIndex
        }
        return found
    }

    /// The OS build in `ProcessInfo.operatingSystemVersionString`, e.g. "24A5390f" from
    /// "Version 27.0 (Build 24A5390f)".
    public static func osBuild(fromVersionString string: String) -> String? {
        guard let range = string.range(of: "Build ") else { return nil }
        let build = string[range.upperBound...].prefix { $0.isLetter || $0.isNumber }
        return build.isEmpty ? nil : String(build)
    }

    /// Top-level directories under `root` that are safe to delete.
    public static func staleEntries(in root: URL, currentContainerID: String?, currentOSBuild: String?,
                                    now: Date = Date(), fileManager: FileManager = .default) -> [URL] {
        guard let builds = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var stale: [URL] = []
        for build in builds where isDirectory(build, fileManager) {
            if let currentOSBuild, build.lastPathComponent != currentOSBuild {
                stale.append(build)
                continue
            }
            guard let keys = try? fileManager.contentsOfDirectory(at: build, includingPropertiesForKeys: nil) else { continue }
            for key in keys where isDirectory(key, fileManager) {
                stale += staleParts(of: key, currentContainerID: currentContainerID, now: now, fileManager: fileManager)
            }
        }
        return stale
    }

    /// The whole entry when it belongs to another container, otherwise its abandoned compiles.
    static func staleParts(of entry: URL, currentContainerID: String?, now: Date, fileManager: FileManager) -> [URL] {
        let bundles = (try? fileManager.contentsOfDirectory(at: entry, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var named = Set<String>()
        var abandoned: [URL] = []
        var compiling = false
        for bundle in bundles {
            if bundle.lastPathComponent.contains(".tmp.") {
                let modified = (try? bundle.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
                if now.timeIntervalSince(modified) >= abandonedAfter { abandoned.append(bundle) } else { compiling = true }
            }
            for descriptor in descriptors(in: bundle, fileManager: fileManager) {
                guard let data = try? Data(contentsOf: descriptor, options: .alwaysMapped) else { continue }
                named.formUnion(containerIDs(inDescriptor: data.prefix(256 * 1024)))
            }
        }
        // A compile still running in this entry keeps all of it, whatever it names.
        guard !compiling else { return [] }
        if let currentContainerID, !named.isEmpty, !named.contains(currentContainerID) { return [entry] }
        if !bundles.isEmpty, abandoned.count == bundles.count { return [entry] }
        return abandoned
    }

    /// `*.e5` files up to two levels inside a bundle (`<key>.bundle/<arch>.bundle/<arch>.e5`).
    static func descriptors(in bundle: URL, fileManager: FileManager) -> [URL] {
        var found: [URL] = []
        var level = [bundle]
        for _ in 0..<2 {
            var next: [URL] = []
            for directory in level {
                for item in (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                    if item.pathExtension == "e5", (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false { found.append(item) }
                    else if isDirectory(item, fileManager) { next.append(item) }
                }
            }
            level = next
        }
        return found
    }

    static func isDirectory(_ url: URL, _ fileManager: FileManager) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { return false }
        var directory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }
}
