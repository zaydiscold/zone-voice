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
        return TranscriptHistory(directory: directory, keepsDecodedFile: Bundle.main.bundleURL.pathExtension != "appex")
    }()

    public init(directory: URL, keepsDecodedFile: Bool = true) {
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
                       interruptions: Int? = nil, now: Date = Date()) -> Bool {
        let inflight = readInflight(id)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            removeInflight(id)
            return false
        }
        var original: Date?
        if let recoveredFrom {
            let previous = record(id: id)
            let earlier = [recoveredFrom, inflight?.createdAt, previous?.createdAt, previous?.recoveredFrom]
            original = earlier.compactMap { $0 }.min()
        }
        let record = TranscriptRecord(
            id: id, text: trimmed, createdAt: original == nil ? (inflight?.createdAt ?? now) : now, updatedAt: now,
            audioSeconds: audioSeconds,
            engine: engine ?? inflight?.engine ?? "", source: source ?? inflight?.source ?? .app,
            status: status, destination: inflight?.destination, recoveredFrom: original,
            interruptions: interruptions ?? inflight?.interruptions)
        let keepsFinished = retention != .off || status == .cutOff
        // The final decoder flush can contain words absent from the last progress save.
        // Make those words recoverable before committing the consolidated history file.
        if keepsFinished { writeInflight(record) }
        let saved = modify(now: now) { records in
            records.removeAll { $0.id == id }
            records.insert(record, at: 0)
        }
        // Preserve the crash-recovery copy if the final write fails. Repeating finish is safe
        // because its record replaces the same id.
        if saved || !keepsFinished { removeInflight(id) }
        return saved && keepsFinished
    }

    /// Drops a dictation the user cancelled. Cancelling is a choice, so nothing is kept.
    public func cancel(id: UUID) {
        // Cancellation can arrive while final persistence is queued. Remove either form.
        delete(id: id)
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
                try? FileManager.default.removeItem(at: file)
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
    public func mark(id: UUID, status: TranscriptStatus, destination: String? = nil, now: Date = Date()) {
        modify(now: now) { records in
            guard let index = records.firstIndex(where: { $0.id == id }) else { return }
            records[index].status = status
            records[index].updatedAt = now
            if let destination { records[index].destination = destination }
        }
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
                where url.lastPathComponent.hasPrefix("history.unreadable-") || url.lastPathComponent.hasPrefix("history.imported-recovery-") {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw LibraryBackupError.invalidDocument
                }
                result[url.lastPathComponent] = try Data(contentsOf: url)
            }
        }
        if fm.fileExists(atPath: inflightURL.path) {
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

    public func delete(id: UUID) {
        removeInflight(id)
        var deleted: [UUID] = []
        let saved = coordinate { file in
            deleted = file.records.filter { $0.id == id }.map(\.id)
            file.records.removeAll { $0.id == id }
            file.unreadable.removeAll { $0.string("id")?.uppercased() == id.uuidString }
        }
        if saved { reportDeleted(deleted) }
    }

    /// Deletes finished records created within `range` (Settings > Your data). Unreadable entries
    /// carry no trustworthy date, so only "delete everything" removes them.
    public func delete(createdIn range: ClosedRange<Date>) {
        var deleted: [UUID] = []
        let saved = coordinate { file in
            deleted = file.records.filter { range.contains($0.createdAt) }.map(\.id)
            file.records.removeAll { range.contains($0.createdAt) }
        }
        if saved { reportDeleted(deleted) }
    }

    /// Deletes every finished record, including entries this build cannot read. In-flight files
    /// of a dictation running right now stay, so a recording in progress is not lost; it is
    /// dropped or kept by retention when it finishes.
    public func deleteAll() {
        var deleted: [UUID] = []
        let saved = coordinate { file in
            deleted = file.records.map(\.id)
            file.records.removeAll()
            file.unreadable.removeAll()
        }
        if saved { reportDeleted(deleted) }
    }

    /// Changing to a shorter retention prunes at once; `.off` clears the history.
    public func setRetention(_ retention: HistoryRetention, now: Date = Date()) {
        coordinate { file in
            file.retention = retention
            file.retentionChosen = true
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
    struct File: Codable, Equatable {
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

        private enum CodingKeys: String, CodingKey { case retention, retentionChosen, records }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            retention = (try? container.decode(HistoryRetention.self, forKey: .retention)) ?? .default
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
            data.append(contentsOf: Array(#","retentionChosen":"#.utf8))
            data.append(try encoder.encode(retentionChosen))
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
    private func modify(now: Date = Date(), keepingDespiteOff keeping: Set<UUID> = [], _ change: (inout [TranscriptRecord]) -> Void) -> Bool {
        coordinate { file in
            change(&file.records)
            file.records = Self.pruned(file.records, retention: file.retention, now: now, keeping: keeping)
            file.pruneUnreadable(retention: file.retention, now: now)
        }
    }

    @discardableResult
    private func coordinate(_ change: (inout File) -> Void) -> Bool {
        lock.lock()
        var error: NSError?
        var saved = false
        var changed = false
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
            change(&file)
            // A change that changes nothing (marking a record already gone, a purge with nothing
            // to purge) leaves the file as it is. Compared as values, not bytes: the encoder's key
            // order differs from process to process, so the bytes of an unchanged library written
            // by the keyboard, or by the app's previous launch, never matched.
            if let original, file == original, !original.differsFromDisk {
                saved = true
                return
            }
            do {
                let data = try file.encoded()
                try data.write(to: url, options: Self.writeOptions)
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
