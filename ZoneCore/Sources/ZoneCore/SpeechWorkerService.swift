import Darwin
import Foundation

@objc(ZoneSpeechWorkerService)
public protocol SpeechWorkerService {
    func endIdleSession()
    func cacheSize(reply: @escaping (Int64) -> Void)
    func clearCache(reply: @escaping (Bool) -> Void)
    func ping(reply: @escaping (Int32) -> Void)
    /// The helper's process ID, its memory footprint and what iOS says is left before its
    /// limit, in bytes (0 where iOS reports none). Asked before any model work, so a host can
    /// tell that the helper is too small without getting it ended.
    func limits(reply: @escaping (Int32, UInt64, UInt64) -> Void)
    /// The lab's memory measurement (`MiniMemoryProbe`). `units` is "cpu" or "neuralEngine".
    /// The reply is the result's fields as JSON. Every stage is in the helper's recording log.
    func probe(_ units: String, windows: Int, recording: String, reply: @escaping (Data?, NSError?) -> Void)
    func warm(_ recording: String, reply: @escaping (NSError?) -> Void)
    func recognize(_ request: String, recording: String, reply: @escaping (Data?, NSError?) -> Void)
    func cancel(_ request: String)
}

/// The helper's own refusals, as an error domain and codes that survive the process boundary.
public enum SpeechHelperRefusal {
    public static let domain = "ZoneSpeechHelper"
    /// iOS gives the helper less memory than Zone's speech model needs.
    public static let tooLittleRoom = 1
}

/// Send only a bounded description and the error code across the process boundary.
public enum WorkerDiagnostic {
    public static func error(_ error: Error, stage: String? = nil) -> NSError {
        let ns = error as NSError
        // Preserve the system's text for this domain and code without paths or caller-supplied userInfo.
        let description = NSError(domain: ns.domain, code: ns.code).localizedDescription
        var info: [String: Any] = [NSLocalizedDescriptionKey: String(description.prefix(240))]
        info["workerStage"] = stage ?? ns.userInfo["workerStage"] as? String
        return NSError(domain: ns.domain, code: ns.code, userInfo: info)
    }
}

public struct WorkerTranscript: Codable, Sendable {
    public var text: String
    public var doubts: [DoubtfulWord]
    public var audioSeconds: Double
    public var fields: [String: String]

    public init(text: String, doubts: [DoubtfulWord], audioSeconds: Double, fields: [String: String]) {
        self.text = text
        self.doubts = doubts
        self.audioSeconds = audioSeconds
        self.fields = fields
    }
}

public extension SharedMiniModel {
    static func sweepRecordings(in folder: URL? = recording(UUID())?.deletingLastPathComponent(), now: Date = Date()) {
        guard let folder else { return }
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        let cutoff = now.addingTimeInterval(-600)
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys)) else { return }
        for file in files where file.pathExtension == "wav" && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let date = values.contentModificationDate, date < cutoff, let owner = KeyboardAudioFile.lock(file) else { continue }
            defer { try? owner.close() }
            try? fm.removeItem(at: file)
        }
    }

    static func recording(_ id: UUID) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)?
            .appendingPathComponent("Library/Caches/WorkerAudio/\(id.uuidString).wav")
    }
}

public enum WorkerStorage {
    public static var coordinationDirectory: URL? {
        KeyboardCapture.group?.appendingPathComponent("Library/Application Support/WorkerCoordination")
    }

    public static func lease(_ name: String, in folder: URL) throws -> FileHandle? {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = open(folder.appendingPathComponent(name).path, O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK | O_CLOEXEC,
                      S_IRUSR | S_IWUSR)
        if fd >= 0 { return FileHandle(fileDescriptor: fd, closeOnDealloc: true) }
        if errno == EWOULDBLOCK { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    /// All hosts claim the launch before calling ExtensionFoundation. A worker may outlive its
    /// host during compilation, so also check the lease held inside the worker process.
    public static func hostLease(in folder: URL? = coordinationDirectory) throws -> FileHandle? {
        guard let folder else { throw CocoaError(.fileNoSuchFile) }
        guard let host = try lease("host.lock", in: folder) else { return nil }
        guard let probe = try lease("worker.lock", in: folder) else { try host.close(); return nil }
        try probe.close()
        return host
    }

    /// Caller holds the host lease. A keyboard retry after a process death shares this budget.
    public static func reserveLaunch(for id: UUID, in folder: URL) throws -> Bool {
        let url = folder.appendingPathComponent(id.uuidString + ".attempts")
        let count = (try? Data(contentsOf: url).first).map(Int.init) ?? 0
        guard count < 2 else { return false }
        try Data([UInt8(count + 1)]).write(to: url, options: .atomic)
        return true
    }

    /// Caller holds the worker cache lease and has no compile in progress. Only unfinished
    /// bundle siblings matching Core ML's process and thread suffix are removed.
    @discardableResult
    public static func sweepTemporaryPrograms(in root: URL) throws -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return 0 }
        var removed = 0
        for build in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where CompiledModelCache.isDirectory(build, fm) {
            for key in try fm.contentsOfDirectory(at: build, includingPropertiesForKeys: nil) where CompiledModelCache.isDirectory(key, fm) {
                for file in try fm.contentsOfDirectory(at: key, includingPropertiesForKeys: nil)
                where CompiledModelCache.isDirectory(file, fm) && isTemporaryProgram(file.lastPathComponent) {
                    try fm.removeItem(at: file)
                    removed += 1
                }
            }
        }
        return removed
    }

    /// What the helper's cache holds: finished programs, and the temporary copies a helper
    /// that iOS ended during preparation left behind. Logical file sizes.
    public struct CacheContents: Equatable, Sendable {
        public var finishedBytes: Int64 = 0
        public var strandedBytes: Int64 = 0
        public var strandedCopies = 0
        public var total: Int64 { finishedBytes + strandedBytes }
    }

    public static func contents(of root: URL) -> CacheContents {
        let fm = FileManager.default
        var contents = CacheContents()
        var stranded = Set<String>()
        guard let files = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return contents }
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            let bytes = Int64(values.fileSize ?? 0)
            if let copy = file.pathComponents.first(where: isTemporaryProgram) {
                contents.strandedBytes += bytes
                stranded.insert(copy)
            } else {
                contents.finishedBytes += bytes
            }
        }
        contents.strandedCopies = stranded.count
        return contents
    }

    /// Core ML names a program it is still writing `<hash>.tmp.<process>_<thread>.bundle`.
    static func isTemporaryProgram(_ name: String) -> Bool {
        name.range(of: #"^[a-fA-F0-9]+\.tmp\.[0-9]+_[0-9]+\.bundle$"#, options: .regularExpression) != nil
    }

    /// Everything the helper prepared, finished or not. Used when the helper cannot hold the
    /// model at all, so none of it will ever be read. Returns the bytes removed.
    @discardableResult
    public static func removeEverything(in root: URL) throws -> Int64 {
        let before = contents(of: root).total
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent().appendingPathComponent("zone-prepared.json"))
        return before
    }

    /// Whether the helper should be opened so it can delete what it cannot use: the first time
    /// on each app build and iOS build (an older build may have left files), and after any host
    /// asked the helper for model work that it may not have finished. Two reads of the shared
    /// defaults, so every keyboard appearance and app launch can ask.
    public static func needsTidy(in defaults: UserDefaults? = WorkerHealth.shared, build: WorkerHealth.Build = .current) -> Bool {
        guard let defaults else { return false }
        return defaults.bool(forKey: "helperCacheDirty") || defaults.string(forKey: "helperTidiedBuild") != build.app + " " + build.os
    }

    /// Set by a host before it asks the helper to prepare, recognize or measure.
    public static func markDirty(in defaults: UserDefaults? = WorkerHealth.shared) {
        defaults?.set(true, forKey: "helperCacheDirty")
    }

    /// Set by the helper once its cache holds no temporary copies.
    public static func markTidied(in defaults: UserDefaults? = WorkerHealth.shared, build: WorkerHealth.Build = .current) {
        defaults?.set(false, forKey: "helperCacheDirty")
        defaults?.set(build.app + " " + build.os, forKey: "helperTidiedBuild")
    }

    /// Bytes of temporary copies last seen in the helper's cache, for the storage screen.
    public static var strandedBytes: Int64 {
        get { Int64(defaults?.integer(forKey: "workerCacheStrandedBytes") ?? 0) }
        set { defaults?.set(newValue, forKey: "workerCacheStrandedBytes") }
    }

    public static let preparedBytes: Int64 = 1_300_000_000
    public static func requiredRoom(_ bytes: Int64) -> Int64 { bytes + max(50_000_000, bytes / 5) }
    private static func inventory(root: URL, build: String?) -> [String: Int]? {
        guard let build else { return nil }
        let directory = root.appendingPathComponent(build)
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return nil }
        var sizes: [String: Int] = [:]
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return nil }
            if values.isRegularFile == true { sizes[file.path] = values.fileSize }
        }
        return sizes.isEmpty ? nil : sizes
    }

    public static func cacheIsPrepared(root: URL, build: String?) -> Bool {
        guard let sizes = inventory(root: root, build: build),
              let receipt = try? Data(contentsOf: root.deletingLastPathComponent().appendingPathComponent("zone-prepared.json")),
              let expected = try? JSONDecoder().decode([String: Int].self, from: receipt) else { return false }
        return sizes == expected
    }

    public static func rememberPrepared(root: URL, build: String?) {
        guard let sizes = inventory(root: root, build: build) else { return }
        try? JSONEncoder().encode(sizes).write(to: root.deletingLastPathComponent().appendingPathComponent("zone-prepared.json"), options: .atomic)
    }

    public static var preparedForCurrentSystem: Bool {
        get { defaults?.string(forKey: "preparedWorkerSystem") == currentSystem }
        set { defaults?.set(newValue ? currentSystem : nil, forKey: "preparedWorkerSystem") }
    }
    private static var currentSystem: String { ProcessInfo.processInfo.operatingSystemVersionString + SharedMiniModel.revision }

    public static func checkRoom(prepared: Bool, free: Int64?) throws {
        guard !prepared, let free, free < requiredRoom(preparedBytes) else { return }
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError,
                      userInfo: [NSLocalizedDescriptionKey: "Free up space to prepare the keyboard speech model."])
    }

    private static var defaults: UserDefaults? { UserDefaults(suiteName: AppGroup.identifier) }
    public static var bytes: Int64 {
        get { Int64(defaults?.integer(forKey: "workerCacheBytes") ?? 0) }
        set { defaults?.set(newValue, forKey: "workerCacheBytes") }
    }
    public static var request: String? { defaults?.string(forKey: "workerCacheRemoval") }
    public static var needsRemoval: Bool { request != defaults?.string(forKey: "workerCacheRemoved") }
    public static func requestRemoval() { defaults?.set(UUID().uuidString, forKey: "workerCacheRemoval") }
    public static func acknowledge(_ token: String?) { defaults?.set(token, forKey: "workerCacheRemoved") }
}
