// by zayd/cold @ zayd.wtf

import XCTest
import ZoneCore
@testable import Zone

@MainActor
final class NoteHistoryMutationTests: XCTestCase {
    private enum Change { case edit, delete, range }

    func testEditRetriesAfterHistoryFailure() throws { try exercise(.edit) }
    func testDeleteRetriesAfterHistoryFailure() throws { try exercise(.delete) }
    func testDateRangeRetriesAfterHistoryFailure() throws { try exercise(.range) }

    func testConflictingNotesWritePreservesHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let history = TranscriptHistory(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let notesURL = directory.appendingPathComponent("notes.json")
        let store = NotesStore(url: notesURL) { history }
        let id = UUID()
        XCTAssertTrue(history.finish(id: id, text: "recorded words", audioSeconds: 1, status: .note, source: .note))
        let note = try XCTUnwrap(store.add("original", recordingID: id))
        let second = NotesStore(url: notesURL) { history }
        XCTAssertNotNil(second.add("another note"))
        XCTAssertFalse(store.update(note, text: "my draft"))
        XCTAssertNotNil(history.record(id: id))
        XCTAssertEqual(try LibraryNotesFile.read(at: notesURL).map(\.text), ["another note", "original"])
        XCTAssertTrue(store.update(note, text: "my draft"))
        XCTAssertNil(history.record(id: id))
        XCTAssertEqual(try LibraryNotesFile.read(at: notesURL).map(\.text), ["another note", "my draft"])
    }

    func testRefusedFinalReplacementKeepsCanonicalNoteForRetry() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let notesFolder = directory.appendingPathComponent("Notes")
        try manager.createDirectory(at: notesFolder, withIntermediateDirectories: true)
        defer {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: notesFolder.path)
            try? manager.removeItem(at: directory)
        }
        let history = TranscriptHistory(directory: directory.appendingPathComponent("History"))
        let notesURL = notesFolder.appendingPathComponent("notes.json")
        let store = NotesStore(url: notesURL) { history }
        let id = UUID()
        XCTAssertTrue(history.finish(id: id, text: "recorded words", audioSeconds: 1, status: .note, source: .note))
        let note = try XCTUnwrap(store.add("canonical words", recordingID: id))
        // History has committed. Block only the upcoming rename of the staged notes file.
        history.explicitDeletionSink = { _, _ in
            do { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: notesFolder.path) }
            catch { XCTFail("Could not inject a rename failure: \(error)") }
        }
        XCTAssertFalse(store.update(note, text: "my draft"))
        XCTAssertNil(history.record(id: id))
        XCTAssertEqual(store.notes, [note])
        XCTAssertEqual(try LibraryNotesFile.read(at: notesURL), [note])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: notesFolder.path)
        XCTAssertTrue(store.update(note, text: "my draft"))
        XCTAssertEqual(try LibraryNotesFile.read(at: notesURL).map(\.text), ["my draft"])
    }

    func testRetryOfLegacyPartialEditRemovesOnlyItsOriginalHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let history = TranscriptHistory(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.json")
        let id = UUID(), other = UUID()
        for recording in [id, other] {
            XCTAssertTrue(history.finish(id: recording, text: "original", audioSeconds: 1, status: .note, source: .note))
        }
        let edited = Note(text: "hand edit", editedAt: Date(), recordingID: id)
        let untouched = Note(text: "original", recordingID: other)
        try LibraryNotesFile.write([edited, untouched], to: url)
        var accessible = false
        let store = NotesStore(url: url) { accessible ? history : nil }
        XCTAssertTrue(store.update(untouched, text: untouched.text))
        XCTAssertFalse(store.update(edited, text: edited.text))
        accessible = true
        XCTAssertTrue(NoteEditDraft(opening: edited).canSave(over: edited))
        XCTAssertFalse(NoteEditDraft(opening: untouched).canSave(over: untouched))
        XCTAssertTrue(store.update(edited, text: edited.text))
        XCTAssertTrue(store.update(edited, text: edited.text))
        XCTAssertNil(history.record(id: id))
        XCTAssertNotNil(history.record(id: other))
        XCTAssertEqual(try LibraryNotesFile.read(at: url), [edited, untouched])
    }

    func testUntouchedStaleDraftKeepsNewerWordsAndHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let history = TranscriptHistory(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.json")
        let store = NotesStore(url: url) { history }
        let id = UUID()
        let opened = try XCTUnwrap(store.add("partial", recordingID: id))
        XCTAssertTrue(history.finish(id: id, text: "complete", audioSeconds: 1, status: .note, source: .note))
        let latest = try XCTUnwrap(store.add("complete", recordingID: id))
        let draft = NoteEditDraft(opening: opened)
        XCTAssertFalse(draft.changed(from: latest))
        XCTAssertFalse(draft.canSave(over: latest))
        XCTAssertFalse(draft.canSave(over: Note(text: "another note")))
        XCTAssertTrue(store.update(opened, text: draft.text))
        XCTAssertEqual(try LibraryNotesFile.read(at: url), [latest])
        XCTAssertNotNil(history.record(id: id))
    }

    func testDirtyConcurrentDraftRequiresExplicitRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.json")
        let store = NotesStore(url: url)
        let opened = try XCTUnwrap(store.add("A"))
        var draft = NoteEditDraft(opening: opened)
        draft.text = "C"
        XCTAssertTrue(store.update(opened, text: "B"))
        let current = try XCTUnwrap(store.notes.first)
        XCTAssertTrue(draft.changed(from: current))
        XCTAssertFalse(store.update(try XCTUnwrap(draft.opened), text: draft.text))
        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(try LibraryNotesFile.read(at: url).map(\.text), ["B"])
        // Try again in the recovery sheet explicitly uses the current note as its base.
        XCTAssertTrue(store.update(current, text: draft.text))
        XCTAssertEqual(try LibraryNotesFile.read(at: url).map(\.text), ["C"])
    }

    private func exercise(_ change: Change) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let history = TranscriptHistory(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let notesURL = directory.appendingPathComponent("notes.json")
        let store = NotesStore(url: notesURL) { history }
        let date = Date()
        func seed(_ text: String, at date: Date) throws -> Note {
            let id = UUID()
            XCTAssertTrue(history.finish(id: id, text: text, audioSeconds: 1, status: .note, source: .note, now: date))
            return try XCTUnwrap(store.add(text, recordingID: id, createdAt: date))
        }
        let subject = try seed("original words", at: date)
        let other = try seed("same original words", at: date.addingTimeInterval(75))
        let sibling = try seed("second note", at: date)
        let before = store.notes
        var deliveries: [UUID] = []
        store.onDelete = { deliveries += $0 }
        func apply() -> Bool {
            switch change {
            case .edit: return store.update(subject, text: "replacement")
            case .delete: return store.delete(subject)
            case .range: return store.delete(createdIn: date...date)
            }
        }
        // An existing unreadable History file refuses deletion. Keep its exact bytes
        // beside the fixture so restoring access exercises a real retry.
        let file = directory.appendingPathComponent("history.json")
        let backup = directory.appendingPathComponent("history.saved")
        let manager = FileManager.default
        try manager.moveItem(at: file, to: backup)
        try manager.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertFalse(apply())
        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(store.notes, before)
        XCTAssertEqual(try LibraryNotesFile.read(at: notesURL), before)
        XCTAssertTrue(deliveries.isEmpty)
        try manager.removeItem(at: file)
        try manager.moveItem(at: backup, to: file)
        XCTAssertTrue(apply())
        XCTAssertNil(store.lastError)
        XCTAssertNil(history.record(id: try XCTUnwrap(subject.recordingID)))
        XCTAssertNotNil(history.record(id: try XCTUnwrap(other.recordingID)))
        XCTAssertEqual(store.notes.first { $0.id == other.id }, other)
        if change == .range {
            XCTAssertNil(history.record(id: try XCTUnwrap(sibling.recordingID)))
            XCTAssertEqual(Set(deliveries), [subject.id, sibling.id])
        } else {
            XCTAssertNotNil(history.record(id: try XCTUnwrap(sibling.recordingID)))
            XCTAssertEqual(deliveries, change == .delete ? [subject.id] : [])
        }
        XCTAssertEqual(store.notes.first { $0.id == subject.id }?.text, change == .edit ? "replacement" : nil)
        XCTAssertEqual(try LibraryNotesFile.read(at: notesURL), store.notes)
    }
}
