// by zayd/cold @ zayd.wtf

import Foundation
import Observation
import ZoneCore

@MainActor
@Observable
final class LibraryBackupManager {
    static let shared = LibraryBackupManager()
    private let defaults: UserDefaults
    private let history: TranscriptHistory?
    private let vocabulary: PersonalVocabulary?
    private let bookmarkKey = "libraryBackupFolder"
    private(set) var isWorking = false
    private(set) var lastError: String?
    private(set) var lastSavedAt: Date?
    private(set) var folderName: String?
    var hasFolder: Bool { defaults.data(forKey: bookmarkKey) != nil }
    /// What changed since the last good folder save. The 30 second check is free while clean.
    @ObservationIgnored private var schedule: LibraryBackupSchedule
    /// Set while an automatic check reads file dates, before it knows whether to save.
    @ObservationIgnored private var checking = false
    @ObservationIgnored private var pendingChange: Task<Void, Never>?
    /// The save waiting for the minimum interval to end, and when it runs.
    @ObservationIgnored private var deferredSave: Task<Void, Never>?
    @ObservationIgnored private var deferredUntil: Date?

    init(defaults: UserDefaults = .standard,
         history: TranscriptHistory? = .shared,
         vocabulary: PersonalVocabulary? = .shared,
         minimumInterval: TimeInterval = LibraryBackupSchedule.defaultMinimumInterval) {
        self.history = history
        self.vocabulary = vocabulary
        self.defaults = defaults
        schedule = LibraryBackupSchedule(minimumInterval: minimumInterval)
        lastSavedAt = defaults.object(forKey: "libraryBackupLastSaved") as? Date
        folderName = defaults.string(forKey: "libraryBackupFolderName")
    }

    /// Creating a bookmark asks the file provider (iCloud Drive) synchronously, so it runs off
    /// the main thread. The new folder counts as a change: the next check fills it.
    func selectFolder(_ url: URL) async throws {
        let bookmark = try await Task.detached(priority: .userInitiated) {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do { return try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) }
            catch { throw BackupScreenFailure(message: "Zone could not open this backup folder. Choose another folder in Files.") }
        }.value
        defaults.set(bookmark, forKey: bookmarkKey)
        defaults.set(url.lastPathComponent, forKey: "libraryBackupFolderName")
        folderName = url.lastPathComponent
        lastError = nil
        schedule.noteChange()
    }

    func stopAutomaticBackups() {
        defaults.removeObject(forKey: bookmarkKey)
        defaults.removeObject(forKey: "libraryBackupFolderName")
        folderName = nil
        lastError = nil
    }

    private func snapshot(notes: NotesStore, meetings: MeetingCoordinator) async throws -> LibraryBackup {
        guard !meetings.isRecording else { throw LibraryBackupError.recording }
        guard let history else { throw LibraryBackupError.unavailableHistory }
        guard let vocabulary else { throw CocoaError(.fileReadNoPermission) }
        let notesURL = notes.fileURL
        let unsavedNotes = notes.notes
        let store = meetings.store
        // History may be large or waiting on a coordinated write. Neither its lock nor
        // JSON/recovery-file reads belong on the UI actor, even after fixing lock inversion.
        let backup = try await Task.detached(priority: .utility) {
            let savedNotes = try NotesStore.backupNotes(at: notesURL, unsaved: unsavedNotes)
            let rawHistory = try history.backupData()
            // Read the unpruned file; expired text still on disk belongs in an export.
            let records = try TranscriptHistory.recordsInBackup(rawHistory)
            var backup = LibraryBackup(notes: savedNotes, dictations: records,
                                 meetings: try store.backupMeetings(), historyArchive: rawHistory,
                                 historyRecoveryFiles: try history.backupRecoveryFiles())
            backup.vocabulary = try vocabulary.document()
            return backup
        }.value
        // Recording may have started while snapshot I/O yielded the main actor.
        guard !meetings.isRecording else { throw LibraryBackupError.recording }
        return backup
    }

    func export(notes: NotesStore, meetings: MeetingCoordinator) async throws -> URL {
        guard !isWorking else { throw CocoaError(.userCancelled) }
        isWorking = true
        defer { isWorking = false }
        var staging: URL?
        do {
            let backup = try await snapshot(notes: notes, meetings: meetings)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("Zone library \(formatter.string(from: Date()))-\(UUID().uuidString.prefix(4)).zonebackup", isDirectory: true)
            staging = folder
            let source = meetings.store.directory
            try await Task.detached(priority: .userInitiated) {
                try LibraryBackupFiles.write(backup, to: folder, meetingDirectory: source)
            }.value
            lastError = nil
            return folder
        } catch {
            if let staging { try? FileManager.default.removeItem(at: staging) }
            let message = (error as? LibraryBackupError)?.errorDescription ?? "Zone could not create the backup. Free up space and export again."
            lastError = message
            throw BackupScreenFailure(message: message)
        }
    }

    /// A note, dictation or meeting changed. Bursts collapse into one save shortly after the last,
    /// and saves are spaced by the schedule's minimum interval. `prompt` (a meeting ended) skips it.
    func libraryChanged(notes: NotesStore, meetings: MeetingCoordinator, prompt: Bool = false) {
        let token = schedule.noteChange(prompt: prompt)
        pendingChange?.cancel()
        pendingChange = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, self.schedule.isLatest(token) else { return }
            await self.saveAutomatically(notes: notes, meetings: meetings)
        }
    }

    /// The periodic and after-change save: skipped while nothing changed since the last good one,
    /// deferred to the end of the minimum interval while changes keep coming.
    func saveAutomatically(notes: NotesStore, meetings: MeetingCoordinator) async {
        await save(notes: notes, meetings: meetings, manual: false)
    }

    /// Back up now, and a newly chosen folder: always a real save.
    func saveNow(notes: NotesStore, meetings: MeetingCoordinator) async {
        await save(notes: notes, meetings: meetings, manual: true)
    }

    /// The bookmark resolution, the security-scoped access, the snapshot and the write all run
    /// off the main thread. Each can wait on fileproviderd for seconds when the folder is in
    /// iCloud Drive (a 1.9 s hang on the phone, 13 s after a reboot). Only results land here.
    private func save(notes: NotesStore, meetings: MeetingCoordinator, manual: Bool) async {
        guard hasFolder, !isWorking, !checking, !meetings.isRecording else { return }
        var sources = [notes.fileURL, meetings.store.directory]
        if let vocabulary { sources.append(vocabulary.storeURL) }
        if let history { sources.append(history.directory) }
        checking = true
        let signature = await Task.detached(priority: .utility) { LibraryBackupSignature.of(sources) }.value
        checking = false
        let now = Date()
        switch schedule.decide(manual ? .manual : .automatic, signature: signature, now: now) {
        case .skip: return
        case .wait(let until):
            deferSave(until: until, notes: notes, meetings: meetings)
            return
        case .save: break
        }
        // Re-check after the await: a recording, an export or "Stop" may have started meanwhile.
        guard !isWorking, !meetings.isRecording, let bookmark = defaults.data(forKey: bookmarkKey) else { return }
        isWorking = true
        defer { isWorking = false }
        schedule.started(at: now)
        let change = schedule.change
        var opened: BackupFolderAccess?
        do {
            let folder = try await Task.detached(priority: .utility) { try BackupFolderAccess(bookmark: bookmark) }.value
            opened = folder
            if let refreshed = folder.refreshedBookmark, defaults.data(forKey: bookmarkKey) == bookmark {
                defaults.set(refreshed, forKey: bookmarkKey)
                defaults.set(folder.url.lastPathComponent, forKey: "libraryBackupFolderName")
                folderName = folder.url.lastPathComponent
            }
            let backup = try await snapshot(notes: notes, meetings: meetings)
            let source = meetings.store.directory
            let destination = folder.url.appendingPathComponent("Zone library.zonebackup", isDirectory: true)
            try await Task.detached(priority: .utility) {
                var coordinationError: NSError?
                var writeResult: Result<Void, Error> = .success(())
                NSFileCoordinator().coordinate(writingItemAt: destination, options: .forMerging, error: &coordinationError) { folder in
                    writeResult = Result { _ = try LibraryBackupFiles.write(backup, to: folder, meetingDirectory: source, accumulate: true) }
                }
                if let coordinationError { throw coordinationError }
                try writeResult.get()
            }.value
            lastSavedAt = Date()
            defaults.set(lastSavedAt, forKey: "libraryBackupLastSaved")
            lastError = nil
            schedule.saved(through: change, signature: signature)
        } catch {
            lastError = (error as? LibraryBackupError)?.errorDescription ?? "Zone could not write the folder backup. Check the folder in Files or choose another one."
            schedule.failed()
        }
        // Access opened on the resolved URL stays open for the whole write, then closes on it.
        if let opened { await Task.detached(priority: .utility) { opened.close() }.value }
    }

    /// One pending save at the end of the interval, so a change is never dropped even if no
    /// other change or periodic check comes along.
    private func deferSave(until: Date, notes: NotesStore, meetings: MeetingCoordinator) {
        if let deferredUntil, deferredUntil <= until, deferredSave != nil { return }
        deferredSave?.cancel()
        deferredUntil = until
        deferredSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(until.timeIntervalSinceNow, 0) + 0.1))
            guard let self, !Task.isCancelled else { return }
            self.deferredSave = nil
            self.deferredUntil = nil
            await self.saveAutomatically(notes: notes, meetings: meetings)
        }
    }

    private static func checkFolder(_ directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let probe = directory.appendingPathComponent(".restore-check-" + UUID().uuidString)
        try Data().write(to: probe, options: .withoutOverwriting)
        try manager.removeItem(at: probe)
    }

    func restore(_ url: URL, notes: NotesStore, meetings: MeetingCoordinator) async throws -> String {
        guard !isWorking, !meetings.isRecording else { throw LibraryBackupError.recording }
        isWorking = true
        defer { isWorking = false }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        var completed: [String] = []
        var stage = "backup validation"
        do {
            let store = meetings.store
            // Full package validation happens before any live record is touched.
            let backup = try await Task.detached(priority: .userInitiated) { try LibraryBackupFiles.read(url) }.value
            guard let history else { throw LibraryBackupError.unavailableHistory }
            stage = "notes"
            _ = try notes.backupNotes()
            try Self.checkFolder(notes.fileURL.deletingLastPathComponent())
            stage = "dictations"
            try Self.checkFolder(history.directory)
            stage = "meetings"
            try Self.checkFolder(store.directory)
            _ = try store.backupMeetings()
            if backup.vocabulary != nil {
                stage = "My words"
                guard let vocabulary else { throw CocoaError(.fileWriteNoPermission) }
                try Self.checkFolder(vocabulary.storeURL.deletingLastPathComponent())
                _ = try vocabulary.document()
            }
            let historyData: Data
            if let archive = backup.historyArchive {
                _ = try TranscriptHistory.recordsInBackup(archive)
                historyData = archive
            } else {
                struct History: Encodable { let retention = "untilDeleted"; let records: [TranscriptRecord] }
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                historyData = try encoder.encode(History(records: backup.dictations))
            }
            stage = "meetings"
            let meetingCount = try await Task.detached(priority: .userInitiated) {
                try LibraryBackupFiles.restoreMeetings(backup, from: url, into: store)
            }.value
            completed.append("\(meetingCount) meetings")
            stage = "My words"
            if let words = backup.vocabulary {
                guard let vocabulary else { throw CocoaError(.fileWriteNoPermission) }
                try await Task.detached(priority: .userInitiated) { try vocabulary.restore(words) }.value
                completed.append("My words")
            }
            stage = "dictations"
            let historyCount = try history.importBackupData(historyData)
            completed.append("\(historyCount) dictations")
            stage = "recovery files"
            let files = try history.importRecoveryFiles(backup.historyRecoveryFiles ?? [:])
            completed.append("\(files) recovery files")
            stage = "recovered dictations"
            let recoveredCount = try history.importInFlightText(backup.historyRecoveryFiles ?? [:])
            completed.append("\(recoveredCount) recovered dictations")
            stage = "notes"
            let noteCount = try notes.importBackup(backup.notes)
            await meetings.reload()
            lastError = nil
            return "Added \(noteCount) notes, \(historyCount + recoveredCount) dictations and \(meetingCount) meetings. Existing records were kept."
        } catch {
            await meetings.reload()
            let receipt = completed.isEmpty ? "No store finished." : "Finished " + completed.joined(separator: ", ") + "."
            let reason = (error as? LibraryBackupError)?.errorDescription ?? "Check the backup in Files, then try importing again."
            let message = "Import stopped during \(stage). \(receipt) \(reason) Any records already added are safe."
            lastError = message
            throw BackupScreenFailure(message: message)
        }
    }
}

private struct BackupScreenFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The chosen backup folder, resolved from its bookmark with security-scoped access open.
/// Built and closed off the main thread: both can wait on the file provider.
private final class BackupFolderAccess: @unchecked Sendable {
    let url: URL
    /// A fresh bookmark when the stored one was stale, for the caller to save.
    let refreshedBookmark: Data?
    private let lock = NSLock()
    private var accessed: Bool

    init(bookmark: Data) throws {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        let accessed = url.startAccessingSecurityScopedResource()
        do {
            refreshedBookmark = stale
                ? try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                : nil
        } catch {
            if accessed { url.stopAccessingSecurityScopedResource() }
            throw error
        }
        self.url = url
        self.accessed = accessed
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        if accessed { url.stopAccessingSecurityScopedResource() }
        accessed = false
    }

    deinit { close() }
}
