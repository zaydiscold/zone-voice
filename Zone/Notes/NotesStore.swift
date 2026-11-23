// by zayd/cold @ zayd.wtf

import Foundation
import Observation
import ZoneCore

typealias Note = LibraryNote

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

    init() {
        url = Self.fileURL
        do { notes = try LibraryNotesFile.read(at: url) }
        catch { lastError = "Your notes file could not be read. Its original data is safe and has not been replaced. \(error.localizedDescription)" }
    }

    @discardableResult
    func add(_ text: String) -> Note? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let note = Note(id: UUID(), text: trimmed, createdAt: Date())
        var next = notes
        next.insert(note, at: 0)
        guard save(next) else { return nil }
        notes = next
        return note
    }

    /// Settings > Your data: every note created within `range`.
    func delete(createdIn range: ClosedRange<Date>) {
        let next = notes.filter { !range.contains($0.createdAt) }
        let removed = notes.filter { range.contains($0.createdAt) }.map(\.id)
        if next.count != notes.count, save(next) {
            notes = next
            onDelete?(removed)
        }
    }

    /// A hand edit. Empty text deletes the note, as emptying it in the editor means.
    func update(_ note: Note, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != note.text else { return }
        guard !trimmed.isEmpty else { delete(note); return }
        var next = notes
        guard let index = next.firstIndex(where: { $0.id == note.id }) else { return }
        next[index].text = trimmed
        next[index].editedAt = Date()
        if save(next) { notes = next }
    }

    func delete(_ note: Note) {
        // A note already gone (deleted on another screen a moment before) is not a second
        // deletion: a paired computer would otherwise log one for nothing.
        guard notes.contains(where: { $0.id == note.id }) else { return }
        let next = notes.filter { $0.id != note.id }
        if save(next) {
            notes = next
            onDelete?([note.id])
        }
    }

    @discardableResult
    func importBackup(_ imported: [Note]) throws -> Int {
        let current = try backupNotes()
        let existing = Set(current.map(\.id))
        let added = imported.filter { !existing.contains($0.id) }
        let next = (current + added).sorted { $0.createdAt > $1.createdAt }
        guard save(next) else { throw CocoaError(.fileWriteUnknown) }
        notes = next
        return added.count
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

    private func save(_ next: [Note]) -> Bool {
        do {
            try LibraryNotesFile.write(next, to: url)
            lastError = nil
            NotificationCenter.default.post(name: .init("ZoneLibraryDidChange"), object: nil)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}
