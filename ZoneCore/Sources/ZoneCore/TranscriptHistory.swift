// by zayd/cold @ zayd.wtf

import Foundation
import CryptoKit

/// How long finished transcripts are kept on the phone.
public enum HistoryRetention: String, Codable, CaseIterable, Sendable {
    /// Nothing is kept; a dictation in progress is still saved until it finishes, so a crash
    /// cannot lose it, and is dropped once it does.
    case off
    case sevenDays
    case thirtyDays
    /// Until the user deletes it; no automatic count or age deletion.
    case untilDeleted

    /// Until I delete: a dictation is the user's own writing, and losing last month's text to a
    /// timer they never chose is worse than a long list. Off, 7 days and 30 days stay one tap away.
    /// Thirty days was the default through 1.0.1; see `File.init(from:)` for that migration.
    public static let `default`: HistoryRetention = .untilDeleted

    public var maxAge: TimeInterval? {
        switch self {
        case .off: return 0
        case .sevenDays: return 7 * 86_400
        case .thirtyDays: return 30 * 86_400
        case .untilDeleted: return nil
        }
    }

    public var label: String {
        switch self {
        case .off: return "Off"
        case .sevenDays: return "7 days"
        case .thirtyDays: return "30 days"
        case .untilDeleted: return "Until I delete"
        }
    }
}

/// Where a dictation was started.
public enum TranscriptSource: String, Codable, Sendable {
    case keyboard
    case app
    case note
    case remote
}

/// What happened to a dictation. A string-backed struct rather than an enum so other parts of Zone
/// (remote dictation to a Mac, say) can add their own values without breaking older readers.
public struct TranscriptStatus: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Still being recorded; only seen on records rebuilt from an in-flight file.
    public static let recording = TranscriptStatus(rawValue: "recording")
    /// In flight, held by an interruption (an alarm, a call): the microphone is off and the
    /// recording resumes when it ends. Only the app turns this into a cut-off, at launch.
    public static let paused = TranscriptStatus(rawValue: "paused")
    /// Finished; nothing has said where it went yet.
    public static let finished = TranscriptStatus(rawValue: "finished")
    /// Put into a text field (keyboard warm path or Insert).
    public static let inserted = TranscriptStatus(rawValue: "inserted")
    /// Offered with Insert and Dismiss, not taken yet.
    public static let offered = TranscriptStatus(rawValue: "offered")
    /// Offered and dismissed: kept here so it can still be rescued.
    public static let dismissed = TranscriptStatus(rawValue: "dismissed")
    /// Saved as a note in the app.
    public static let note = TranscriptStatus(rawValue: "note")
    /// Sent to another device.
    public static let sentRemote = TranscriptStatus(rawValue: "sentRemote")
    /// The recording ended without finishing (crash, kill, timeout); the text is what was saved.
    public static let cutOff = TranscriptStatus(rawValue: "cutOff")
    /// Remote dictation: the computer kept the text (its agent left, or another app came to the front).
    public static let heldOnComputer = TranscriptStatus(rawValue: "heldOnComputer")
    /// Remote dictation: no answer from the computer; the phone offers to send again.
    public static let notDelivered = TranscriptStatus(rawValue: "notDelivered")

    /// Short wording for lists, shared by the keyboard panel and the app's History screen. Nil for
    /// statuses that need no label (a plain finished or inserted dictation). Unknown values get none.
    public var label: String? {
        switch self {
        case .cutOff: return "Cut off, saved"
        case .dismissed: return "Dismissed"
        case .offered: return "Not inserted"
        case .note: return "Note"
        case .sentRemote: return "Sent to computer"
        case .heldOnComputer: return "Held on computer"
        case .notDelivered: return "Not delivered"
        case .recording: return "Recording"
        case .paused: return "Paused"
        default: return nil
        }
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One dictation, text only. Audio is never stored.
public struct TranscriptRecord: Codable, Identifiable, Equatable, Sendable {
    /// The dictation request's id when there is one, so the keyboard can find its record.
    public let id: UUID
    public var text: String
    public let createdAt: Date
    public var updatedAt: Date
    public var audioSeconds: Double
    /// `EngineKind.rawValue` of the engine that recognized it.
    public var engine: String
    public var source: TranscriptSource
    public var status: TranscriptStatus
    /// Free-form target, for sources that know one ("MacBook Pro" for remote). Nil otherwise.
    public var destination: String?
    /// Set when this text came from retrying a saved recording: when that recording was made.
    /// `createdAt` is then when it was transcribed, so a retried recording sorts as the newest
    /// item and still says which moment it came from.
    public var finishedAt: Date?
    public var recoveredFrom: Date?
    /// How many times iOS took the microphone during the recording (an alarm, a call) and Zone
    /// picked it back up. Nil when it never happened.
    public var interruptions: Int?

    public init(id: UUID, text: String, createdAt: Date, updatedAt: Date, audioSeconds: Double,
                engine: String, source: TranscriptSource, status: TranscriptStatus, destination: String? = nil,
                recoveredFrom: Date? = nil, interruptions: Int? = nil) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.audioSeconds = audioSeconds
        self.engine = engine
        self.source = source
        self.status = status
        self.destination = destination
        self.recoveredFrom = recoveredFrom
        self.interruptions = interruptions
    }

    public var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}

/// The local transcript history, shared by the app and the keyboard through the App Group.
///
/// Finished records live in one JSON file, newest first, together with the retention setting.
/// A dictation in progress has its own small file in `inflight/`, rewritten as text arrives, so a
/// crash, a kill or a timeout keeps everything recognized so far: the next `recoverCutOff()` turns
/// any leftover in-flight file into a `.cutOff` record. Writes from the two processes are
/// serialized with `NSFileCoordinator`. Nothing here leaves the phone on its own: the app sends
/// finished records to a computer only after the person pairs one (Zone Link).
///
/// Every read decodes the whole file and every save decodes and rewrites it, so both grow with the
/// library: about 10 ms to decode 2,000 dictations on an M4 Pro, five times that at 10,000
/// (docs/research/2026-11-18-lexicon-and-history-perf.md). With `keepsDecodedFile` the last decode
/// is reused while the file on disk is the same version, so History's once-a-second refresh,
/// `retention` beside `records()`, and a save right after a read decode nothing again. A change
/// that changes nothing writes nothing.
public final class TranscriptHistory: @unchecked Sendable {
    public let directory: URL
    // Shared by the app and keyboard, outside the backup-excluded History directory.
    private let transferDefaults: UserDefaults?
    private static let transferKey = "zone.stats.transferTotals"
    private let fileURL: URL
    private let inflightURL: URL
    private let lock = NSLock()
    private let sinkLock = NSLock()
    private var deletionSink: (@Sendable ([UUID], Date) -> Void)?
    /// False in the keyboard and the other extensions: their memory limit is far below the app's,
    /// and a library held between their rare reads would cost them megabytes for nothing.
    public let keepsDecodedFile: Bool
    private let snapshotLock = NSLock()
    private var snapshot: Snapshot?
    private var memoryPressure: DispatchSourceMemoryPressure?

    /// Told the ids of finished records the person deleted on purpose: one dictation, a date
    /// range, or everything. Never told about records that history retention aged out, a
    /// shorter retention pruned, or a cancelled dictation that was never saved. Zone Link uses
    /// this to tell a paired computer "delete this too" and nothing else. Nil by default.
    public var explicitDeletionSink: (@Sendable ([UUID], Date) -> Void)? {
        get { sinkLock.lock(); defer { sinkLock.unlock() }; return deletionSink }
        set { sinkLock.lock(); deletionSink = newValue; sinkLock.unlock() }
    }

    private func reportDeleted(_ ids: [UUID]) {
        guard !ids.isEmpty, let sink = explicitDeletionSink else { return }
        sink(ids, Date())
    }

    /// The history in the App Group container, or nil when the container is unreachable (the
    /// keyboard without Full Access).
    public static let shared: TranscriptHistory? = {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ZoneContract.appGroup) else {
            return nil
        }
        let directory = container.appendingPathComponent("Library/Application Support/History", isDirectory: true)
        return TranscriptHistory(directory: directory, keepsDecodedFile: Bundle.main.bundleURL.pathExtension != "appex",
                                 transferDefaults: UserDefaults(suiteName: ZoneContract.appGroup))
    }()

    public init(directory: URL, keepsDecodedFile: Bool = true, transferDefaults: UserDefaults? = nil) {
        self.transferDefaults = transferDefaults
        self.directory = directory
        self.keepsDecodedFile = keepsDecodedFile
        fileURL = directory.appendingPathComponent("history.json")
        inflightURL = directory.appendingPathComponent("inflight", isDirectory: true)
        try? FileManager.default.createDirectory(at: inflightURL, withIntermediateDirectories: true)
        // Transcripts are personal and rebuildable from nothing; keep them out of iCloud backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = directory
        try? dir.setResourceValues(values)
        if keepsDecodedFile {
            // The kept decode is only a shortcut; under memory pressure it goes, and the next read decodes.
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
            source.setEventHandler { [weak self] in self?.forgetSnapshot() }
            source.resume()
            memoryPressure = source
        }
    }

    deinit {
        memoryPressure?.cancel()
    }

    // MARK: Reading

    public var retention: HistoryRetention {
        read().retention
    }

    /// Newest first.
    public func records(now: Date = Date()) -> [TranscriptRecord] {
        let file = read()
        return Self.pruned(file.records, retention: file.retention, now: now)
    }

    public func recent(limit: Int, now: Date = Date()) -> [TranscriptRecord] {
        Array(records(now: now).prefix(limit))
    }

    /// If the latest finish produced no readable words, the shortcut must not fall
    /// back to an earlier recording. Older history files have no finish receipt.
    public func lastFinishedRecording(now: Date = Date()) -> TranscriptRecord? {
        lastRecordingEvent(now: now)?.record
    }

    /// The ID and time remain when editing a saved note removes its raw History row.
    public func lastRecordingEvent(now: Date = Date()) -> (id: UUID, at: Date, isNote: Bool?, record: TranscriptRecord?)? {
        let file = read()
        guard file.retention != .off else { return nil }
        let records = Self.pruned(file.records, retention: file.retention, now: now)
        guard let last = file.lastFinish else {
            // Older versions saved the words without a finish receipt.
            guard let record = records.first(where: { $0.status != .recording }) else { return nil }
            return (record.id, record.finishedAt ?? record.createdAt, record.status == .note, record)
        }
        let record = records.first { $0.id == last.id }
        return (last.id, last.at, last.isNote ?? record.map { $0.status == .note }, record)
    }

    public func recentDictations(limit: Int, now: Date = Date()) -> [TranscriptRecord] {
        Array(records(now: now).lazy.filter { $0.status != .note }.prefix(limit))
    }

    func records(withIDs ids: Set<UUID>) -> [UUID: TranscriptRecord] {
        var matches: [UUID: TranscriptRecord] = [:]
        for record in read().records where ids.contains(record.id) && matches[record.id] == nil {
            matches[record.id] = record
        }
        return matches
    }

    public func record(id: UUID) -> TranscriptRecord? {
        read().records.first { $0.id == id }
    }

    /// Case- and diacritic-insensitive substring search over the text, newest first.
    public func search(_ query: String, now: Date = Date()) -> [TranscriptRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return records(now: now) }
        return records(now: now).filter {
            $0.text.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    // MARK: A dictation's life

    /// Starts the in-flight file for a dictation.
    public func begin(id: UUID, engine: String, source: TranscriptSource, destination: String? = nil, now: Date = Date()) {
        let record = TranscriptRecord(id: id, text: "", createdAt: now, updatedAt: now, audioSeconds: 0,
                                      engine: engine, source: source, status: .recording, destination: destination)
        writeInflight(record)
    }

    /// Saves the text recognized so far. Cheap: only this dictation's small file is rewritten.
    /// - Parameter status: `.paused` while an interruption holds the recording, `.recording`
    ///   again when it resumes; nil keeps the current one.
    public func saveProgress(id: UUID, text: String, audioSeconds: Double, status: TranscriptStatus? = nil,
                             interruptions: Int? = nil, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard var record = readInflight(id) else { return }
        record.text = text
        record.audioSeconds = audioSeconds
        record.updatedAt = now
        if let status { record.status = status }
        if let interruptions { record.interruptions = interruptions }
        writeInflightLocked(record)
    }

    /// Moves a finished dictation into the history. With retention off it is dropped instead.
    /// Without a prior `begin` (an engine that never saved progress) a record is made from the arguments.
    ///
    /// - Parameter recoveredFrom: when the text comes from retrying a saved recording, the time
    ///   that recording was made. The record is then dated `now` (it sorts first, as the newest
    ///   thing transcribed) and keeps the original time in `recoveredFrom`; an earlier cut-off
    ///   record of the same recording is replaced, and its time wins if it is earlier.
    @discardableResult
    public func finish(id: UUID, text: String, audioSeconds: Double, status: TranscriptStatus = .finished,
                       engine: String? = nil, source: TranscriptSource? = nil, recoveredFrom: Date? = nil,
                       interruptions: Int? = nil, statsStartedAt: Date? = nil, now: Date = Date()) -> Bool {
        finishOutcome(id: id, text: text, audioSeconds: audioSeconds, status: status, engine: engine,
                      source: source, recoveredFrom: recoveredFrom, interruptions: interruptions,
                      statsStartedAt: statsStartedAt, now: now) == .stored
    }

    public enum FinishOutcome { case stored, retentionOff, empty, failed }

    @discardableResult
    public func finishOutcome(id: UUID, text: String, audioSeconds: Double, status: TranscriptStatus = .finished,
                       engine: String? = nil, source: TranscriptSource? = nil, recoveredFrom: Date? = nil,
                       interruptions: Int? = nil, statsStartedAt: Date? = nil, now: Date = Date()) -> FinishOutcome {
        let inflight = readInflight(id)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let receipt = FinishReceipt(id: id, at: now, isNote: !trimmed.isEmpty && status == .note)
        guard !trimmed.isEmpty else {
            coordinate { $0.remember(receipt) }
            removeInflight(id)
            return .empty
        }
        var original: Date?
        if let recoveredFrom {
            let previous = record(id: id)
            let earlier = [recoveredFrom, inflight?.createdAt, previous?.createdAt, previous?.recoveredFrom]
            original = earlier.compactMap { $0 }.min()
        }
        var record = TranscriptRecord(
            id: id, text: trimmed, createdAt: original == nil ? (inflight?.createdAt ?? now) : now, updatedAt: now,
            audioSeconds: audioSeconds,
            engine: engine ?? inflight?.engine ?? "", source: source ?? inflight?.source ?? .app,
            status: status, destination: inflight?.destination, recoveredFrom: original,
            interruptions: interruptions ?? inflight?.interruptions)
        record.finishedAt = now
        var keepsFinished = retention != .off || status == .cutOff
        // The final decoder flush can contain words absent from the last progress save.
        // Make those words recoverable before committing the consolidated history file.
        if keepsFinished { writeInflight(record) }
        let saved = coordinate { file in
            keepsFinished = file.retention != .off || status == .cutOff
            file.remember(receipt)
            if let statsStartedAt {
                file.stats.finish(id: id, start: statsStartedAt, words: record.wordCount, seconds: audioSeconds,
                                  recoveryDate: recoveredFrom == nil ? nil : now, awaitingNote: status == .note || record.source == .note)
            }
            file.records.removeAll { $0.id == id }
            file.records.insert(record, at: 0)
            file.records = Self.pruned(file.records, retention: file.retention, now: now)
            file.pruneUnreadable(retention: file.retention, now: now)
        }
        // Preserve the crash-recovery copy if the final write fails. Repeating finish is safe
        // because its record replaces the same id.
        if saved || !keepsFinished { removeInflight(id) }
        guard saved else { return .failed }
        return keepsFinished ? .stored : .retentionOff
    }

    /// Drops a dictation the user cancelled. Cancelling is a choice, so nothing is kept.
    public func cancel(id: UUID) {
        // Cancellation can arrive while final persistence is queued. Remove either form.
        _ = delete(ids: [id], previouslyLinked: false, discardingRecording: true)
    }

    /// Turns every in-flight file left behind (crash, kill, timeout) into a `.cutOff` record with
    /// the last text saved, and returns those records. Call once when the app starts, and from
    /// the keyboard when it appears. In-flight files touched within `activeWindow` belong to a
    /// dictation still running and are left alone, and so are `.paused` ones touched within
    /// `pausedWindow`: an interruption holds those, and iOS may suspend Zone for the whole hold,
    /// so they stop being touched. The app's launch call passes 0 for both, because a new
    /// process holds nothing.
    @discardableResult
    public func recoverCutOff(now: Date = Date(), activeWindow: TimeInterval = 30,
                              pausedWindow: TimeInterval = InterruptionPolicy.holdLimit + 60) -> [TranscriptRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: inflightURL, includingPropertiesForKeys: nil)) ?? []
        var recovered: [TranscriptRecord] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  var record = try? JSONDecoder.history.decode(TranscriptRecord.self, from: data) else {
                // A locked file or a newer format can become readable later. Backup
                // also includes these bytes until the person explicitly deletes them.
                continue
            }
            let window = record.status == .paused ? max(activeWindow, pausedWindow) : activeWindow
            guard now.timeIntervalSince(record.updatedAt) > window else { continue }
            record.text = record.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !record.text.isEmpty else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            record.status = .cutOff
            recovered.append(record)
        }
        guard !recovered.isEmpty else { return [] }
        // A cut-off dictation remains visible even with retention off until it is used or
        // deleted. Keep its in-flight copy until the recovered records are durable.
        let saved = modify(now: now, keepingDespiteOff: Set(recovered.map(\.id))) { records in
            for record in recovered {
                records.removeAll { $0.id == record.id }
                records.insert(record, at: 0)
            }
            records.sort { $0.createdAt > $1.createdAt }
        }
        guard saved else { return [] }
        for record in recovered { removeInflight(record.id) }
        return recovered
    }

    /// Records where a dictation went (inserted, dismissed, sent).
    public func mark(id: UUID, status: TranscriptStatus, destination: String? = nil, keptWords: Int? = nil, now: Date = Date()) {
        coordinate { file in
            if let keptWords { file.stats.delivery(id: id, kept: keptWords) }
            if let index = file.records.firstIndex(where: { $0.id == id }) {
                file.records[index].status = status
                file.records[index].updatedAt = now
                if let destination { file.records[index].destination = destination }
            }
            file.records = Self.pruned(file.records, retention: file.retention, now: now)
            file.pruneUnreadable(retention: file.retention, now: now)
        }
    }

    public func confirmKept(id: UUID, words: Int) {
        confirmKept([(id, words)])
    }

    public func confirmKept(_ counts: [(UUID, Int)]) {
        coordinate { file in
            for (id, count) in counts { file.stats.delivery(id: id, kept: count, permanent: true) }
        }
    }

    public func resetStats(now: Date = Date()) -> Bool {
        coordinate { $0.stats.clear(at: now) }
    }

    public func stats(legacyWords: Int, legacySeconds: Double, since: Date?, transferred: DictationTotals? = nil) -> (DictationTotals, DictationTotals)? {
        withStats(legacyWords: legacyWords, legacySeconds: legacySeconds, transferred: transferred) { stats in
            (stats.totals(), since.map { stats.totals(since: $0) } ?? DictationTotals())
        }
    }

    public func islandStats(legacyWords: Int, legacySeconds: Double, since: Date?, transferred: DictationTotals?) -> (DictationTotals, DictationTotals, IslandGardenProgress)? {
        withStats(legacyWords: legacyWords, legacySeconds: legacySeconds, transferred: transferred) { stats in
            (stats.totals(), since.map { stats.totals(since: $0) } ?? DictationTotals(), stats.garden(on: Date(), calendar: .current))
        }
    }

    private func withStats<T>(legacyWords: Int, legacySeconds: Double, transferred: DictationTotals?, totals: (DictationReceipts) -> T) -> T? {
        let existing = read()
        let needsTransferCache = transferDefaults.map { $0.data(forKey: Self.transferKey) == nil } ?? false
        if existing.stats.unmatchedWords != nil, !existing.differsFromDisk, !needsTransferCache { return totals(existing.stats) }
        var result: T?
        let saved = coordinate(recoverUndecodable: false) { file in
            file.stats.seedIfEmpty(from: transferred)
            file.stats.migrate(words: legacyWords, seconds: legacySeconds, history: file.records)
            result = totals(file.stats)
        }
        return saved ? result : nil
    }

    // MARK: Deleting and settings

    /// Includes older records and entries this build cannot interpret, without pruning them.
    public func backupData() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(LibraryBackupError.unavailableHistory)
        NSFileCoordinator().coordinate(readingItemAt: fileURL, options: [], error: &coordinationError) { url in
            result = Result {
                if !FileManager.default.fileExists(atPath: url.path) { return try JSONEncoder.history.encode(File()) }
                let data = try Data(contentsOf: url)
                _ = try JSONDecoder.history.decode(File.self, from: data)
                return data
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    public static func recordsInBackup(_ data: Data) throws -> [TranscriptRecord] {
        try JSONDecoder.history.decode(File.self, from: data).records
    }

    /// Preserve quarantined bytes and in-flight text even when the current schema cannot read
    /// them. Backups expose these JSON files as recovery material rather than discarding them.
    public func backupRecoveryFiles() throws -> [String: Data] {
        lock.lock(); defer { lock.unlock() }
        var result: [String: Data] = [:]
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) {
            for url in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
                where Self.isRecoveryFileName(url.lastPathComponent) {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw LibraryBackupError.invalidDocument
                }
                result[url.lastPathComponent] = try Data(contentsOf: url)
            }
        }
        if (try? inflightURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            throw LibraryBackupError.invalidDocument
        } else if fm.fileExists(atPath: inflightURL.path) {
            for url in try fm.contentsOfDirectory(at: inflightURL, includingPropertiesForKeys: [.isRegularFileKey]) where url.pathExtension == "json" {
                guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw LibraryBackupError.invalidDocument }
                result["inflight-" + url.lastPathComponent] = try Data(contentsOf: url)
            }
        }
        return result
    }

    @discardableResult
    public func importRecoveryFiles(_ files: [String: Data]) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        // Raw recovery writes are content addressed and atomic. Import the readable text
        // separately through coordinate, after releasing this nonrecursive lock.
        for (name, data) in files {
            guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name.hasSuffix(".json") else { throw LibraryBackupError.invalidDocument }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let target = directory.appendingPathComponent("history.imported-recovery-\(digest).json")
            if !FileManager.default.fileExists(atPath: target.path) { try data.write(to: target, options: Self.writeOptions) }
        }
        return files.count
    }

    @discardableResult
    public func importInFlightText(_ files: [String: Data]) throws -> Int {
        var recovered: [TranscriptRecord] = []
        for (name, data) in files where name.hasPrefix("inflight-") {
            if var record = try? JSONDecoder.history.decode(TranscriptRecord.self, from: data),
               !record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                record.status = .cutOff
                recovered.append(record)
            }
        }
        var count = 0
        if !recovered.isEmpty {
            guard coordinate({ file in
                var ids = Set(file.records.map(\.id))
                for record in recovered where ids.insert(record.id).inserted { file.records.append(record); count += 1 }
                file.retention = .untilDeleted
                file.records.sort { $0.createdAt > $1.createdAt }
            }) else { throw LibraryBackupError.unavailableHistory }
        }
        return count
    }

    /// Additive restore. Keep existing IDs and all unreadable entries. Imported history must
    /// not expire immediately, so the import screen explicitly says it switches to Until I delete.
    @discardableResult
    public func importBackupData(_ data: Data) throws -> Int {
        let incoming = try JSONDecoder.history.decode(File.self, from: data)
        var added = 0
        let saved = coordinate { file in
            var ids = Set(file.records.map { $0.id.uuidString.uppercased() })
            file.stats.restore(incoming.stats)
            ids.formUnion(file.unreadable.compactMap { $0.string("id")?.uppercased() })
            for record in incoming.records where ids.insert(record.id.uuidString.uppercased()).inserted {
                file.records.append(record)
                added += 1
            }
            for raw in incoming.unreadable {
                if let id = raw.string("id")?.uppercased() {
                    if ids.insert(id).inserted { file.unreadable.append(raw); added += 1 }
                } else if !file.unreadable.contains(where: { $0 == raw }) {
                    file.unreadable.append(raw); added += 1
                }
            }
            file.records.sort { $0.createdAt > $1.createdAt }
            file.retention = .untilDeleted
        }
        guard saved else { throw LibraryBackupError.unavailableHistory }
        return added
    }

    @discardableResult
    public func delete(id: UUID) -> Bool {
        delete(ids: [id], previouslyLinked: false)
    }

    @discardableResult
    public func delete(ids: Set<UUID>, previouslyLinked: Bool) -> Bool {
        delete(ids: ids, previouslyLinked: previouslyLinked, discardingRecording: false)
    }

    private func delete(ids: Set<UUID>, previouslyLinked: Bool, discardingRecording: Bool) -> Bool {
        guard !ids.isEmpty else { return true }
        var deleted: [UUID] = []
        let saved = coordinate { file in
            deleted = file.records.filter { ids.contains($0.id) }.map(\.id)
            if discardingRecording {
                for id in ids { file.stats.entries.removeValue(forKey: id.uuidString) }
            }
            file.records.removeAll { ids.contains($0.id) }
            file.unreadable.removeAll { entry in
                guard let raw = entry.string("id"), let id = UUID(uuidString: raw) else { return false }
                return ids.contains(id)
            }
        }
        if saved {
            for id in ids { removeInflight(id) }
            reportDeleted(previouslyLinked ? Array(ids) : deleted)
        }
        return saved
    }

    /// Deletes finished records created within `range` (Settings > Your data). Unreadable entries
    /// carry no trustworthy date, so only "delete everything" removes them.
    @discardableResult
    public func delete(createdIn range: ClosedRange<Date>) -> Bool {
        var deleted: [UUID] = []
        let saved = coordinate { file in
            deleted = file.records.filter { range.contains($0.createdAt) }.map(\.id)
            file.records.removeAll { range.contains($0.createdAt) }
        }
        if saved { reportDeleted(deleted) }
        return saved
    }

    /// "Delete all" from History. The same as `deleteAllWithRecovery()`, for a caller that does
    /// not show whether it worked.
    public func deleteAll() {
        _ = deleteAllWithRecovery()
    }

    /// Deletes every finished record, including entries this build cannot read, and every copy a
    /// backup would otherwise still export: quarantined history bytes (`history.unreadable-*`),
    /// recovery files imported from a backup (`history.imported-recovery-*`) and in-flight files
    /// a crash or kill left behind. Only a person's explicit "delete all" may call this; history
    /// retention never does, so aging out and Off never erase recovery material.
    ///
    /// The in-flight file of a dictation running right now stays (the same windows as
    /// `recoverCutOff`), so a recording in progress is not lost; retention keeps or drops it when
    /// it finishes. Backups the person already saved elsewhere are theirs and are not touched.
    ///
    /// - Returns: true only when the history file was saved empty and no recovery file is left.
    @discardableResult
    public func deleteAllWithRecovery(clearingStats: Bool = false, now: Date = Date(), activeWindow: TimeInterval = 30,
                                      pausedWindow: TimeInterval = InterruptionPolicy.holdLimit + 60) -> Bool {
        var deleted: [UUID] = []
        // First the history file: an undecodable one is set aside as a quarantine copy here,
        // which the sweep below then removes.
        let saved = coordinate { file in
            deleted = file.records.map(\.id)
            if clearingStats { file.stats.clear(at: now) }
            file.records.removeAll()
            file.lastFinish = nil
            file.unreadable.removeAll()
        }
        if saved { reportDeleted(deleted) }
        let swept = removeRecoveryFiles(now: now, activeWindow: activeWindow, pausedWindow: pausedWindow)
        return saved && swept
    }

    /// Removes the recovery files `backupRecoveryFiles()` would export, except the in-flight file
    /// of a live dictation. Only regular files and symbolic links (the link, never its target) are
    /// removed, one by one; nothing else in the directory is. True when none is left.
    private func removeRecoveryFiles(now: Date, activeWindow: TimeInterval, pausedWindow: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        var clean = true
        func remove(_ url: URL) {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true || values?.isSymbolicLink == true else {
                // A folder or something else under a recovery name: not ours to delete wholesale,
                // and a backup refuses it, so report it rather than claim it is gone.
                clean = false
                return
            }
            do { try fm.removeItem(at: url) } catch { clean = false }
        }
        if fm.fileExists(atPath: directory.path) {
            do {
                for url in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    where Self.isRecoveryFileName(url.lastPathComponent) {
                    remove(url)
                }
            } catch {
                clean = false
            }
        }
        if (try? inflightURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            remove(inflightURL)
        } else if fm.fileExists(atPath: inflightURL.path) {
            do {
                for url in try fm.contentsOfDirectory(at: inflightURL, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    where url.pathExtension == "json" {
                    let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
                    if !isLink, let data = try? Data(contentsOf: url),
                       let record = try? JSONDecoder.history.decode(TranscriptRecord.self, from: data) {
                        let window = record.status == .paused ? max(activeWindow, pausedWindow) : activeWindow
                        if now.timeIntervalSince(record.updatedAt) <= window { continue }
                    }
                    remove(url)
                }
            } catch {
                clean = false
            }
        }
        return clean
    }

    static func isRecoveryFileName(_ name: String) -> Bool {
        name.hasPrefix("history.unreadable-") || name.hasPrefix("history.imported-recovery-")
    }

    /// Changing to a shorter retention prunes at once; `.off` clears the history.
    public func setRetention(_ retention: HistoryRetention, now: Date = Date()) {
        coordinate { file in
            file.retention = retention
            file.retentionChosen = true
            if retention == .off { file.lastFinish = nil }
            file.records = retention == .off ? [] : Self.pruned(file.records, retention: retention, now: now)
            file.pruneUnreadable(retention: retention, now: now)
        }
    }

    /// Physically remove expired records even if no new dictation has been recorded.
    public func purgeExpired(now: Date = Date()) {
        modify(now: now) { _ in }
    }

    // MARK: Pruning

    static func pruned(_ records: [TranscriptRecord], retention: HistoryRetention, now: Date,
                       keeping: Set<UUID> = []) -> [TranscriptRecord] {
        var kept = records
        if let maxAge = retention.maxAge {
            kept = kept.filter { keeping.contains($0.id) || (retention == .off && $0.status == .cutOff) || (maxAge > 0 && now.timeIntervalSince($0.createdAt) <= maxAge) }
        }
        return kept
    }

    // MARK: Files

    /// The history file. Decoding is per record: a record this build cannot read (a newer
    /// build's source or field, a damaged entry) is carried through untouched as raw JSON
    /// instead of failing the whole file. Before, one unreadable record made the file decode as
    /// empty and the next dictation's write replaced every record with just itself.
    struct FinishReceipt: Codable, Equatable {
        let id: UUID
        let at: Date
        var isNote: Bool?
    }

    struct File: Codable, Equatable {
        var lastFinish: FinishReceipt?

        mutating func remember(_ receipt: FinishReceipt) {
            if retention != .off, receipt.at >= (lastFinish?.at ?? .distantPast) { lastFinish = receipt }
        }

        var stats = DictationReceipts()
        var retention: HistoryRetention = .default
        /// True once the user has picked a retention on the History screen. Files written before
        /// this flag existed stored the old thirty-day default whether or not anyone chose it.
        var retentionChosen = false
        var records: [TranscriptRecord] = []
        /// Entries kept verbatim and written back after the readable records. Retention, Delete
        /// and Delete All still apply to them through their `id` and `createdAt`.
        var unreadable: [HistoryJSON] = []
        /// Decoding changed what the bytes say (the old thirty-day default below), so the next
        /// save writes the file even if its change changes nothing else. Never encoded.
        var differsFromDisk = false

        init() {}

        private enum CodingKeys: String, CodingKey { case retention, retentionChosen, records, stats, lastFinish }

        private enum LegacyStatsKeys: String, CodingKey { case prefixes }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let statsFields = try? container.nestedContainer(keyedBy: LegacyStatsKeys.self, forKey: .stats) {
                differsFromDisk = statsFields.contains(.prefixes)
            }
            stats = (try? container.decode(DictationReceipts.self, forKey: .stats)) ?? DictationReceipts()
            retention = (try? container.decode(HistoryRetention.self, forKey: .retention)) ?? .default
            lastFinish = try? container.decode(FinishReceipt.self, forKey: .lastFinish)
            retentionChosen = (try? container.decode(Bool.self, forKey: .retentionChosen)) ?? false
            // Through 1.0.1 every new history file was written with the thirty-day default, and
            // the picker could not re-select the value it already showed, so an unflagged
            // thirtyDays is the old default, not a choice. Move it to the new default before any
            // pruning runs, so nothing older than thirty days is deleted after this update.
            if !retentionChosen && retention == .thirtyDays {
                retention = .default
                differsFromDisk = true
            }
            guard container.contains(.records) else { return }
            var list = try container.nestedUnkeyedContainer(forKey: .records)
            while !list.isAtEnd {
                if let record = try? list.decode(TranscriptRecord.self) {
                    records.append(record)
                } else {
                    unreadable.append(try list.decode(HistoryJSON.self))
                }
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(lastFinish, forKey: .lastFinish)
            if stats != DictationReceipts() { try container.encode(stats, forKey: .stats) }
            try container.encode(retention, forKey: .retention)
            try container.encode(retentionChosen, forKey: .retentionChosen)
            var list = container.nestedUnkeyedContainer(forKey: .records)
            for record in records { try list.encode(record) }
            for raw in unreadable { try list.encode(raw) }
        }

        /// The file as JSON, written one record at a time into one buffer. `JSONEncoder` on the
        /// whole file first builds a tree of every record: 16 MB above the decode for 10,000
        /// dictations, paid by the keyboard on every mark, against about 2 MB this way. The same
        /// keys and values; `JSONEncoder` still writes each record, so escaping and dates match.
        func encoded() throws -> Data {
            let encoder = JSONEncoder.history
            var data = Data()
            data.append(contentsOf: Array(#"{"retention":"#.utf8))
            data.append(try encoder.encode(retention))
            if stats != DictationReceipts() {
                data.append(contentsOf: Array(#", "stats":"#.utf8))
                try stats.appendJSON(to: &data, encoder: encoder)
            }
            data.append(contentsOf: Array(#","retentionChosen":"#.utf8))
            data.append(try encoder.encode(retentionChosen))
            if let lastFinish {
                data.append(contentsOf: #","lastFinish":"#.utf8)
                data.append(try encoder.encode(lastFinish))
            }
            data.append(contentsOf: Array(#","records":["#.utf8))
            var first = true
            for record in records {
                if !first { data.append(UInt8(ascii: ",")) }
                data.append(try encoder.encode(record))
                first = false
            }
            for raw in unreadable {
                if !first { data.append(UInt8(ascii: ",")) }
                data.append(try encoder.encode(raw))
                first = false
            }
            data.append(contentsOf: Array("]}".utf8))
            return data
        }

        /// Applies retention to the entries this build cannot read, by their `createdAt`.
        mutating func pruneUnreadable(retention: HistoryRetention, now: Date) {
            guard let maxAge = retention.maxAge else { return }
            unreadable.removeAll { raw in
                guard maxAge > 0 else { return true }
                guard let created = raw.date("createdAt") else { return false }
                return now.timeIntervalSince(created) > maxAge
            }
        }
    }

    private func read() -> File {
        var result = File()
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: fileURL, options: [], error: &error) { url in
            if case .decoded(let file) = load(at: url) { result = file }
        }
        return result
    }

    /// One version of the history file on disk. Every write is atomic (a new file renamed into
    /// place), so a write by either process gives the file a new inode; the size and the
    /// modification and status-change times, to the nanosecond, catch anything written in place.
    struct FileVersion: Equatable {
        let device: Int64
        let inode: UInt64
        let size: Int64
        let modified: Int
        let modifiedNanoseconds: Int
        let changed: Int
        let changedNanoseconds: Int

        /// The file at `url`: nil when there is none, `.some(nil)` when it is there but is not a
        /// regular file or cannot be looked at.
        static func at(_ url: URL) -> FileVersion?? {
            var info = stat()
            guard stat(url.path, &info) == 0 else { return errno == ENOENT ? nil : .some(nil) }
            guard info.st_mode & S_IFMT == S_IFREG else { return .some(nil) }
            return FileVersion(info)
        }

        private init(_ info: stat) {
            device = Int64(info.st_dev)
            inode = UInt64(info.st_ino)
            size = Int64(info.st_size)
            modified = Int(info.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int(info.st_mtimespec.tv_nsec)
            changed = Int(info.st_ctimespec.tv_sec)
            changedNanoseconds = Int(info.st_ctimespec.tv_nsec)
        }
    }

    /// The last decode and the version of the file it was decoded from.
    struct Snapshot {
        let version: FileVersion
        let file: File
    }

    enum Stored {
        case missing
        case decoded(File)
        /// Readable bytes that are not a history file at all.
        case undecodable(Data)
        /// There but not readable (a directory, no permission, an I/O error).
        case unreadable
    }

    /// What is at `url`, decoded, or a kept decode when the file is the version it was made from.
    /// Read with `Data(contentsOf:)` as before (reading through a file handle peaked about 5 MB
    /// higher for an 18.8 MB file), between two looks at the version: a decode is kept only when
    /// the file did not change while it was read.
    func load(at url: URL) -> Stored {
        let before: FileVersion
        switch FileVersion.at(url) {
        case .some(.some(let version)): before = version
        case .some(.none): return .unreadable
        case .none: return .missing
        }
        if keepsDecodedFile {
            snapshotLock.lock()
            let kept = snapshot
            snapshotLock.unlock()
            if let kept, kept.version == before { return .decoded(kept.file) }
        }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        guard let file = try? JSONDecoder.history.decode(File.self, from: data) else { return .undecodable(data) }
        if keepsDecodedFile, case .some(.some(let after)) = FileVersion.at(url), after == before {
            snapshotLock.lock()
            snapshot = Snapshot(version: before, file: file)
            snapshotLock.unlock()
        }
        return .decoded(file)
    }

    func forgetSnapshot() {
        snapshotLock.lock()
        snapshot = nil
        snapshotLock.unlock()
    }

    /// Whether a decode is kept right now (tests).
    var hasSnapshot: Bool {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return snapshot != nil
    }

    @discardableResult
    private func modify(now: Date = Date(), keepingDespiteOff keeping: Set<UUID> = [], finish: FinishReceipt? = nil, _ change: (inout [TranscriptRecord]) -> Void) -> Bool {
        coordinate { file in
            if let finish { file.remember(finish) }
            change(&file.records)
            file.records = Self.pruned(file.records, retention: file.retention, now: now, keeping: keeping)
            file.pruneUnreadable(retention: file.retention, now: now)
        }
    }

    private func cacheForTransfer(_ stats: DictationReceipts) {
        guard let transferDefaults, stats.unmatchedWords != nil,
              let data = try? JSONEncoder().encode(stats.totals()) else { return }
        transferDefaults.set(data, forKey: Self.transferKey)
    }

    @discardableResult
    private func coordinate(recoverUndecodable: Bool = true, _ change: (inout File) -> Void) -> Bool {
        lock.lock()
        var error: NSError?
        var saved = false
        var changed = false
        var statsChanged = false
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: .forMerging, error: &error) { url in
            var file = File()
            var original: File?
            switch load(at: url) {
            case .missing:
                break
            case .decoded(let saved):
                file = saved
                original = saved
            case .undecodable(let data):
                guard recoverUndecodable else { return }
                // Not even the outline is readable. Keep the bytes beside it before starting
                // over, rather than overwriting the only copy of someone's history.
                let aside = url.deletingLastPathComponent()
                    .appendingPathComponent("history.unreadable-\(Int(Date().timeIntervalSince1970)).json")
                guard (try? data.write(to: aside, options: Self.writeOptions)) != nil else { return }
            case .unreadable:
                // There, but not readable now: starting from nothing would replace it with just
                // this change. The caller keeps its recovery file and retries later.
                return
            }
            if file.stats.entries.isEmpty, file.stats.unmatchedWords == nil,
               let data = transferDefaults?.data(forKey: Self.transferKey) {
                // Even the first keyboard finish or backup import may precede opening Home.
                let cache = try? JSONDecoder().decode(DictationTotals.self, from: data)
                file.stats.seedIfEmpty(from: cache)
                if cache == DictationTotals() {
                    // A committed zero snapshot supersedes a stale app display cache.
                    file.stats.migrate(words: 0, seconds: 0, history: [])
                }
            }
            change(&file)
            // A change that changes nothing (marking a record already gone, a purge with nothing
            // to purge) leaves the file as it is. Compared as values, not bytes: the encoder's key
            // order differs from process to process, so the bytes of an unchanged library written
            // by the keyboard, or by the app's previous launch, never matched.
            if let original, file == original, !original.differsFromDisk {
                if transferDefaults?.data(forKey: Self.transferKey) == nil { cacheForTransfer(file.stats) }
                saved = true
                return
            }
            do {
                let data = try file.encoded()
                try data.write(to: url, options: Self.writeOptions)
                statsChanged = (original?.stats ?? DictationReceipts()) != file.stats
                if statsChanged || transferDefaults?.data(forKey: Self.transferKey) == nil { cacheForTransfer(file.stats) }
                changed = true
                saved = true
            } catch {
                // The caller retains the recovery file and can retry after storage recovers.
            }
            // Decoded again on the next read: the file holds dates to the second, not `file`'s.
            forgetSnapshot()
        }
        // NotificationCenter can synchronously wait for an observer's operation queue.
        // Backup on the main thread takes this same lock. Release it before notifying,
        // otherwise the writer waits for main while main waits for the writer forever.
        lock.unlock()
        if saved && changed && error == nil {
            if statsChanged { DarwinNotifier.post(.statsChanged) }
            NotificationCenter.default.post(name: .init("ZoneLibraryDidChange"), object: nil)
        }
        return saved && error == nil
    }

    /// Readable after the first unlock, so a dictation running with the phone locked can still save.
    private static var writeOptions: Data.WritingOptions {
        #if os(iOS)
        return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        return [.atomic]
        #endif
    }

    private func inflightFile(_ id: UUID) -> URL {
        inflightURL.appendingPathComponent("\(id.uuidString).json")
    }

    private func readInflight(_ id: UUID) -> TranscriptRecord? {
        guard let data = try? Data(contentsOf: inflightFile(id)) else { return nil }
        return try? JSONDecoder.history.decode(TranscriptRecord.self, from: data)
    }

    private func writeInflight(_ record: TranscriptRecord) {
        lock.lock(); defer { lock.unlock() }
        writeInflightLocked(record)
    }

    private func writeInflightLocked(_ record: TranscriptRecord) {
        guard let data = try? JSONEncoder.history.encode(record) else { return }
        try? data.write(to: inflightFile(record.id), options: Self.writeOptions)
    }

    private func removeInflight(_ id: UUID) {
        try? FileManager.default.removeItem(at: inflightFile(id))
    }
}

/// A JSON value carried through without interpretation (see `TranscriptHistory.File`).
enum HistoryJSON: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([HistoryJSON]), object([String: HistoryJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([HistoryJSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: HistoryJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    func string(_ key: String) -> String? {
        guard case .object(let fields) = self, case .string(let value)? = fields[key] else { return nil }
        return value
    }

    func date(_ key: String) -> Date? {
        string(key).flatMap { ISO8601DateFormatter().date(from: $0) }
    }
}

private extension JSONEncoder {
    static let history: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let history: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
