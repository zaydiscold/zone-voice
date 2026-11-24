// by zayd/cold @ zayd.wtf

import Foundation

public struct LibraryNote: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var text: String
    public let createdAt: Date
    public var recordingID: UUID?
    public var editedAt: Date?

    public init(id: UUID = UUID(), text: String, createdAt: Date = Date(), editedAt: Date? = nil, recordingID: UUID? = nil) {
        self.recordingID = recordingID
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.editedAt = editedAt
    }
}

/// The portable manifest inside a .zonebackup document package. Dates, IDs and speaker
/// names survive an export/import round trip. Audio sits beside it, never base64 in RAM.
public struct LibraryBackup: Codable, Sendable {
    public var formatVersion = 1
    public var createdAt: Date
    public var notes: [LibraryNote]
    public var dictations: [TranscriptRecord]
    public var meetings: [Meeting]
    public var vocabulary: PersonalVocabulary.Document?
    public var historyArchive: Data?
    public var historyRecoveryFiles: [String: Data]?

    public init(notes: [LibraryNote], dictations: [TranscriptRecord], meetings: [Meeting], historyArchive: Data? = nil, historyRecoveryFiles: [String: Data]? = nil, createdAt: Date = Date()) {
        self.createdAt = createdAt
        self.notes = notes
        self.dictations = dictations
        self.meetings = meetings
        self.historyArchive = historyArchive
        self.historyRecoveryFiles = historyRecoveryFiles
    }

    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        let backup = try decoder.decode(Self.self, from: data)
        guard backup.formatVersion == 1 else { throw LibraryBackupError.newerVersion }
        if let vocabulary = backup.vocabulary, vocabulary.version != 1 { throw LibraryBackupError.newerVersion }
        if let archive = backup.historyArchive {
            let archiveIDs = Set(try TranscriptHistory.recordsInBackup(archive).map(\.id))
            guard Set(backup.dictations.map(\.id)).isSubset(of: archiveIDs) else { throw LibraryBackupError.invalidDocument }
        }
        for name in backup.historyRecoveryFiles?.keys ?? Dictionary<String, Data>().keys {
            guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), !name.contains("\0"), name.hasSuffix(".json") else { throw LibraryBackupError.invalidDocument }
        }
        guard Set(backup.notes.map(\.id)).count == backup.notes.count,
              Set(backup.dictations.map(\.id)).count == backup.dictations.count,
              Set(backup.meetings.map(\.id)).count == backup.meetings.count else {
            throw LibraryBackupError.invalidDocument
        }
        for meeting in backup.meetings {
            guard Set(meeting.parts.map(\.fileName)).count == meeting.parts.count else {
                throw LibraryBackupError.invalidDocument
            }
            for part in meeting.parts {
                guard safePartName(part.fileName), part.bytes >= 0, part.bytes % 2 == 0 else {
                    throw LibraryBackupError.invalidDocument
                }
            }
        }
        return backup
    }

    public var readableText: String {
        var sections = ["Zone notes and transcripts", "Exported \(createdAt.formatted())", "", "NOTES", ""]
        sections.append(TranscriptExport.text(for: notes.map { .init(date: $0.createdAt, text: $0.text) }))
        sections += ["", "DICTATION HISTORY", "", TranscriptExport.text(for: dictations.map { .init(date: $0.createdAt, text: $0.text) })]
        sections += ["", "MEETINGS", ""]
        sections += meetings.sorted { $0.createdAt < $1.createdAt }.map { MeetingExport.text($0) }
        return sections.joined(separator: "\n") + "\n"
    }

    /// Folder backups accumulate records. Deleting from the phone never deletes its backup.
    /// Newer snapshots win on matching IDs; a later save preserves edits.
    public func accumulating(_ previous: Self) -> Self {
        var merged = self
        if let older = previous.vocabulary {
            if merged.vocabulary == nil { merged.vocabulary = older }
            else { merged.vocabulary?.merge(older) }
        }
        merged.notes += previous.notes.filter { old in !notes.contains { $0.id == old.id } }
        merged.dictations += previous.dictations.filter { old in !dictations.contains { $0.id == old.id } }
        merged.meetings += previous.meetings.filter { old in !meetings.contains { $0.id == old.id } }
        merged.historyRecoveryFiles = (previous.historyRecoveryFiles ?? [:]).merging(historyRecoveryFiles ?? [:]) { _, current in current }
        if previous.historyArchive != nil || historyArchive != nil {
            let old = previous.historyArchive.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            var current = historyArchive.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
            var records = current["records"] as? [Any] ?? []
            var ids = Set(records.compactMap { (($0 as? [String: Any])?["id"] as? String)?.uppercased() })
            var idless = Set(records.filter { (($0 as? [String: Any])?["id"] as? String) == nil }
                .compactMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .fragmentsAllowed]) })
            for record in old?["records"] as? [Any] ?? [] {
                if let id = ((record as? [String: Any])?["id"] as? String)?.uppercased() {
                    if ids.insert(id).inserted { records.append(record) }
                } else if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .fragmentsAllowed]),
                          idless.insert(data).inserted {
                    records.append(record)
                }
            }
            func receipts(_ object: Any?) -> DictationReceipts? {
                guard let object, let data = try? JSONSerialization.data(withJSONObject: object, options: .fragmentsAllowed) else { return nil }
                return try? JSONDecoder().decode(DictationReceipts.self, from: data)
            }
            var stats = receipts(current["stats"]) ?? DictationReceipts()
            if let prior = receipts(old?["stats"]) { stats.restore(prior, accumulating: true) }
            stats.reset = nil
            if stats != DictationReceipts(), let data = try? JSONEncoder().encode(stats) {
                current["stats"] = try? JSONSerialization.jsonObject(with: data)
            } else {
                current.removeValue(forKey: "stats")
            }
            current["records"] = records
            current["retention"] = "untilDeleted"
            merged.historyArchive = try? JSONSerialization.data(withJSONObject: current, options: [.sortedKeys])
        }
        return merged
    }

    static func safePartName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
            && !name.contains("\\") && !name.contains("\0") && name.hasSuffix(".pcm")
    }
}

public enum LibraryBackupError: LocalizedError {
    case newerVersion, invalidDocument, missingAudio(String), recording, unavailableHistory
    public var errorDescription: String? {
        switch self {
        case .newerVersion: return "This backup needs a newer version of Zone."
        case .invalidDocument: return "This is not a complete Zone backup. Your existing library has not been replaced."
        case .missingAudio(let title): return "The backup is missing audio for \(title). Keep the complete .zonebackup document together."
        case .recording: return "Stop the meeting recording before making a backup. Your notes are still saved on this iPhone."
        case .unavailableHistory: return "Zone could not open dictation history. Try again before exporting your library."
        }
    }
}

public enum LibraryBackupFiles {
    public static func read(_ folder: URL) throws -> LibraryBackup {
        let manifest = folder.appendingPathComponent("library.json")
        try requireRegularFile(manifest, within: folder)
        let backup = try LibraryBackup.decode(Data(contentsOf: manifest))
        // Validate ALL inputs before any store is changed. Never follow a link out of a package.
        for meeting in backup.meetings {
            let directory = folder.appendingPathComponent("Meetings/\(meeting.id.uuidString)", isDirectory: true)
            for part in meeting.parts {
                let url = directory.appendingPathComponent(part.fileName)
                do {
                    try requireRegularFile(url, within: folder)
                    let actual = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                    guard actual == Int(part.bytes) else { throw LibraryBackupError.invalidDocument }
                } catch { throw LibraryBackupError.missingAudio(meeting.title) }
            }
        }
        return backup
    }

    /// Copy audio with FileManager so even a multi-hour meeting isn't loaded into memory.
    /// The manifest is committed LAST; a failed write never advertises missing audio.
    @discardableResult
    public static func write(_ snapshot: LibraryBackup, to folder: URL, meetingDirectory: URL,
                             accumulate: Bool = false) throws -> LibraryBackup {
        guard !snapshot.meetings.contains(where: { $0.status == .recording }) else { throw LibraryBackupError.recording }
        _ = try LibraryBackup.decode(LibraryBackup.encoder.encode(snapshot))
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.path), try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw LibraryBackupError.invalidDocument
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var backup = snapshot
        let manifest = folder.appendingPathComponent("library.json")
        var previous: (backup: LibraryBackup, bytes: Data)?
        if accumulate, fm.fileExists(atPath: manifest.path) {
            let old = try read(folder)
            previous = (old, try Data(contentsOf: manifest))
        }
        if accumulate {
            backup = snapshot.accumulating(previous?.backup ?? LibraryBackup(notes: [], dictations: [], meetings: []))
        }
        for meeting in snapshot.meetings {
            let destination = folder.appendingPathComponent("Meetings/\(meeting.id.uuidString)", isDirectory: true)
            for directory in [folder.appendingPathComponent("Meetings"), destination] {
                if fm.fileExists(atPath: directory.path), try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw LibraryBackupError.invalidDocument }
            }
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            for part in meeting.parts {
                let source = meetingDirectory.appendingPathComponent(meeting.id.uuidString).appendingPathComponent(part.fileName)
                try requireRegularFile(source, within: meetingDirectory)
                guard (try source.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(part.bytes) else {
                    throw LibraryBackupError.missingAudio(meeting.title)
                }
                let target = destination.appendingPathComponent(part.fileName)
                if fm.fileExists(atPath: target.path) {
                    try requireRegularFile(target, within: folder)
                    guard (try target.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(part.bytes) else {
                        // A resumed meeting has a fresh part name. Changed bytes under the same
                        // name indicate a concurrent write; do not corrupt an older backup.
                        throw LibraryBackupError.recording
                    }
                } else {
                    let staging = destination.appendingPathComponent(".\(UUID().uuidString).tmp")
                    do {
                        try fm.copyItem(at: source, to: staging)
                        try fm.moveItem(at: staging, to: target)
                    } catch { try? fm.removeItem(at: staging); throw error }
                }
            }
        }
        var encoded = try LibraryBackup.encoder.encode(backup)
        if let previous, encoded != previous.bytes {
            // Only the snapshot time differs when nothing else changed. Keep the old time, so
            // both files come out byte-identical and neither is rewritten.
            var unchanged = backup
            unchanged.createdAt = previous.backup.createdAt
            let candidate = try LibraryBackup.encoder.encode(unchanged)
            if candidate == previous.bytes { backup = unchanged; encoded = candidate }
        }
        try writeIfChanged(encoded, to: manifest)
        try writeIfChanged(Data(backup.readableText.utf8), to: folder.appendingPathComponent("Notes and transcripts.txt"))
        return backup
    }

    /// The folder is often in iCloud Drive: an identical rewrite costs flash writes and a fresh
    /// upload for nothing. The old bytes are read (cheap) and compared before writing.
    private static func writeIfChanged(_ data: Data, to url: URL) throws {
        if let existing = try? Data(contentsOf: url), existing == data { return }
        try data.write(to: url, options: .atomic)
    }

    /// Existing meeting IDs always win. Import is additive, so a second import is harmless.
    public static func restoreMeetings(_ backup: LibraryBackup, from folder: URL, into store: MeetingStore) throws -> Int {
        let existing = Set(store.all().map(\.id))
        var count = 0
        let fm = FileManager.default
        try fm.createDirectory(at: store.directory, withIntermediateDirectories: true)
        for var meeting in backup.meetings where !existing.contains(meeting.id) {
            let staging = store.directory.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
            do {
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                for part in meeting.parts {
                    let source = folder.appendingPathComponent("Meetings/\(meeting.id.uuidString)").appendingPathComponent(part.fileName)
                    try requireRegularFile(source, within: folder)
                    try fm.copyItem(at: source, to: staging.appendingPathComponent(part.fileName))
                }
                if meeting.status == .recording || meeting.status == .transcribing { meeting.status = .recorded }
                let meetingEncoder = JSONEncoder()
                meetingEncoder.dateEncodingStrategy = .iso8601
                try meetingEncoder.encode(meeting).write(to: staging.appendingPathComponent("meeting.json"), options: .atomic)
                #if os(iOS)
                try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: staging.path)
                #endif
                try fm.moveItem(at: staging, to: store.folder(meeting.id))
                count += 1
            } catch { try? fm.removeItem(at: staging); throw error }
        }
        return count
    }

    private static func requireRegularFile(_ url: URL, within root: URL) throws {
        // Check all parents too: a normal file inside a symbolic-link directory escapes just
        // as easily as a file symlink. Package paths are always absolute here.
        let root = root.standardizedFileURL
        guard url.standardizedFileURL.path.hasPrefix(root.path + "/") else { throw LibraryBackupError.invalidDocument }
        var current = url.standardizedFileURL
        while current.path != root.path {
            let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw LibraryBackupError.invalidDocument }
            current.deleteLastPathComponent()
        }
        if try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw LibraryBackupError.invalidDocument }
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw LibraryBackupError.invalidDocument
        }
    }
}
