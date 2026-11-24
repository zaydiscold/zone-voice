// by zayd/cold @ zayd.wtf

import Foundation
import Observation
import ZoneCore

typealias Note = LibraryNote

/// Both editors retain the note they opened so a new recording result cannot become
/// the target or the apparent contents of an untouched draft.
struct NoteEditDraft {
    let opened: Note?
    var text: String

    init(opening note: Note? = nil) {
        opened = note
        text = note?.text ?? ""
    }

    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    func changed(from current: Note?) -> Bool {
        guard let opened else { return false }
        return trimmed != opened.text.trimmingCharacters(in: .whitespacesAndNewlines)
            && (current?.id != opened.id || trimmed != current?.text)
    }

    func canSave(over current: Note?) -> Bool {
        guard let opened, let current, opened.id == current.id, !trimmed.isEmpty else { return false }
        // An explicit Save can finish a legacy partial edit. Opening the editor
        // consults only note metadata, so even a large History adds no read here.
        return changed(from: current) || (current.editedAt != nil && current.recordingID != nil && trimmed == current.text)
    }
}

/// Notes dictated through the Action Button or a Shortcut, newest first, kept as one JSON
/// file in Application Support. Nothing leaves the phone unless the person pairs a computer
/// (Zone Link) or exports a backup.
@MainActor
@Observable
final class NotesStore {
    private(set) var notes: [Note] = []
    private(set) var lastError: String?
    private let url: URL
    /// Told the ids of notes the person deleted, after the file no longer holds them. Zone Link
    /// uses it to delete the same notes on a paired computer.
    @ObservationIgnored var onDelete: (([UUID]) -> Void)?

    /// Where the notes file lives, for readers that work off the main thread.
    nonisolated static var fileURL: URL {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("notes.json")
    }

    private let history: () -> TranscriptHistory?

    init(url: URL = NotesStore.fileURL, history: @escaping () -> TranscriptHistory? = { TranscriptHistory.shared }) {
        self.history = history
        self.url = url
        do { notes = try LibraryNotesFile.read(at: url) }
        catch {
            loadFailed = true
            lastError = "Zone could not read your notes. Unlock your iPhone and open Zone again. The original file was not changed."
        }
    }

    /// The first read failed, so `notes` is empty while the file may hold the whole library.
    /// Nothing is written from that empty list: every change reads the file again first, and
    /// is refused while it still cannot be read. Without this, a read that failed once at
    /// launch and worked a moment later let the next saved note replace every older one.
    @ObservationIgnored private var loadFailed = false

    /// True when `notes` is what the file holds. Reads again after a failed first read.
    private func loaded() -> Bool {
        guard loadFailed else { return true }
        do {
            notes = try LibraryNotesFile.read(at: url)
            loadFailed = false
            lastError = nil
            return true
        } catch {
            lastError = "Zone could not read your notes. Unlock your iPhone and open Zone again. The original file was not changed."
            return false
        }
    }

    @discardableResult
    func add(_ text: String, recordingID: UUID? = nil, createdAt: Date = Date()) -> Note? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, loaded() else { return nil }
        if let recordingID, let index = notes.firstIndex(where: { $0.recordingID == recordingID }) {
            var next = notes
            if next[index].editedAt != nil {
                let recovered = Note(id: UUID(), text: trimmed, createdAt: createdAt, recordingID: recordingID)
                next[index].recordingID = nil
                next.insert(recovered, at: 0)
                guard save(next) else { return nil }
                notes = next
                return recovered
            }
            next[index].text = trimmed
            guard save(next) else { return nil }
            notes = next
            return next[index]
        }
        let note = Note(id: UUID(), text: trimmed, createdAt: createdAt, recordingID: recordingID)
        var next = notes
        next.insert(note, at: 0)
        guard save(next) else { return nil }
        notes = next
        return note
    }

    private enum HistoryError: Error { case unavailable, deletionFailed }

    /// Settings > Your data: every note created within `range`.
    @discardableResult
    func delete(createdIn range: ClosedRange<Date>) -> Bool {
        guard loaded() else { return false }
        let next = notes.filter { !range.contains($0.createdAt) }
        let removed = notes.filter { range.contains($0.createdAt) }
        guard !removed.isEmpty else { return true }
        guard rememberDeletedNotes(removed), save(next, removingHistoryFor: removed) else { return false }
        notes = next
        onDelete?(removed.map(\.id))
        return true
    }

    /// A hand edit. Empty text deletes the note, as emptying it in the editor means.
    /// - Returns: false when the file refused the change, so the editor keeps the words.
    @discardableResult
    func update(_ note: Note, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard loaded() else { return false }
        var next = notes
        guard let index = next.firstIndex(where: { $0.id == note.id }) else { return false }
        let previous = next[index]
        if trimmed == previous.text {
            // Older versions could commit the edit before History refused its cleanup.
            guard previous.editedAt != nil, previous.recordingID != nil else { return true }
            return save(next, removingHistoryFor: [previous])
        }
        // The editor never changed the words it opened with. A recording retry or a
        // second editor supplied the newer canonical words in the meantime.
        guard trimmed != note.text else { return true }
        guard previous.text == note.text else {
            lastError = "This note changed while you were editing. Try again to replace the newer words with your draft."
            return false
        }
        guard !trimmed.isEmpty else { return delete(previous) }
        next[index].text = trimmed
        next[index].editedAt = Date()
        guard save(next, removingHistoryFor: [previous]) else { return false }
        notes = next
        return true
    }

    @discardableResult
    func delete(_ note: Note) -> Bool {
        guard loaded() else { return false }
        // A note already gone (deleted on another screen a moment before) is not a second
        // deletion: a paired computer would otherwise log one for nothing.
        guard let removed = notes.first(where: { $0.id == note.id }) else { return true }
        let next = notes.filter { $0.id != note.id }
        guard rememberDeletedNotes([removed]), save(next, removingHistoryFor: [removed]) else { return false }
        notes = next
        onDelete?([note.id])
        return true
    }

    @discardableResult
    func importBackup(_ imported: [Note]) throws -> Int {
        let current = try backupNotes()
        var existing = Set(current.map(\.id))
        let added = imported.filter { existing.insert($0.id).inserted }
        let next = (current + added).sorted { $0.createdAt > $1.createdAt }
        guard save(next, replacing: current) else { throw CocoaError(.fileWriteUnknown) }
        notes = next
        return added.count
    }

    func importWatch(_ envelope: CompanionNoteEnvelope) throws {
        guard !notes.contains(where: { $0.id == envelope.id }),
              !FileManager.default.fileExists(atPath: watchMarkers.appendingPathComponent(envelope.id.uuidString).path)
        else { return }
        // This older ledger stopped changing when this build adopted deletion markers.
        // A note made afterwards cannot be named in it, even if its bytes are damaged.
        let legacy = url.deletingLastPathComponent().appendingPathComponent("imported-watch-ids.json")
        if let modified = try? legacy.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           envelope.createdAt <= modified {
            let ids = try JSONDecoder().decode([UUID].self, from: Data(contentsOf: legacy))
            guard !ids.contains(envelope.id) else { return }
        }
        try importBackup([Note(id: envelope.id, text: envelope.text, createdAt: envelope.createdAt)])
    }

    private var watchMarkers: URL {
        url.deletingLastPathComponent().appendingPathComponent("deleted-watch-notes")
    }

    private func rememberDeletedNotes(_ removed: [Note]) -> Bool {
        // Older notes have no origin tag. Remember their exact IDs, never their words.
        let older = removed.filter { $0.recordingID == nil }
        guard !older.isEmpty else { return true }
        do {
            try FileManager.default.createDirectory(at: watchMarkers, withIntermediateDirectories: true)
            for note in older {
                try Data().write(to: watchMarkers.appendingPathComponent(note.id.uuidString), options: .atomic)
            }
            return true
        } catch {
            lastError = "Zone could not save the deletion. The note is still here."
            return false
        }
    }

    func clearWatchReceipts() throws {
        for file in [watchMarkers, url.deletingLastPathComponent().appendingPathComponent("imported-watch-ids.json")] {
            do { try FileManager.default.removeItem(at: file) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { }
        }
    }

    func backupNotes() throws -> [Note] {
        try Self.backupNotes(at: url, unsaved: notes)
    }

    /// The notes file, for reading a backup off the main thread with `backupNotes(at:unsaved:)`.
    nonisolated var fileURL: URL { url }

    nonisolated static func backupNotes(at url: URL, unsaved: [Note]) throws -> [Note] {
        guard FileManager.default.fileExists(atPath: url.path) else { return unsaved }
        // A malformed file must be reported, never turned into a successful empty backup.
        return try LibraryNotesFile.read(at: url)
    }

    private func save(_ next: [Note], replacing expected: [Note]? = nil, removingHistoryFor affected: [Note] = []) -> Bool {
        let ids = Set(affected.compactMap(\.recordingID))
        let cleanup: (() throws -> Void)? = ids.isEmpty ? nil : { [history] in
            guard let store = history() else { throw HistoryError.unavailable }
            guard store.delete(ids: ids, previouslyLinked: false) else { throw HistoryError.deletionFailed }
        }
        do {
            try LibraryNotesFile.write(next, to: url, replacing: expected ?? notes, beforeReplacing: cleanup)
            lastError = nil
            NotificationCenter.default.post(name: .init("ZoneLibraryDidChange"), object: nil)
            return true
        } catch HistoryError.unavailable {
            lastError = "Zone could not open History. Try again to save your change."
            return false
        } catch HistoryError.deletionFailed {
            lastError = "Zone could not remove the original words from History. Try again to save your change."
            return false
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            loadFailed = true
            lastError = "Your library changed. Your words were kept. Try saving again."
            return false
        } catch {
            lastError = "Zone could not save your changes. Free up space and try saving again."
            return false
        }
    }
}
