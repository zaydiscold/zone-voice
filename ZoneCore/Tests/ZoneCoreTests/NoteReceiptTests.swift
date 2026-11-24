// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// A note's words must be in the notes file or on a recovery card at every moment of its save,
/// using isolated stores and simulated stops between writes. NoteCaptureFlowTests exercises
/// the app coordinator. Synthetic words only.
final class NoteReceiptTests: XCTestCase {
    private var root: URL!
    private var recovery: AudioRecoveryStore!
    private var history: TranscriptHistory!
    private var notesURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("note-receipt-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        recovery = AudioRecoveryStore(directory: root.appendingPathComponent("AudioRecovery"))
        history = TranscriptHistory(directory: root.appendingPathComponent("History"))
        notesURL = root.appendingPathComponent("notes.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let words = "Synthetic note: buy stamps and water the fern."

    /// Recorded, recognized, saved to History and its audio finalized, the way stopDictation does
    /// before it writes the notes file. Returns the recording's id.
    private func recordAndReachTheNotesWrite(isNote: Bool) async throws -> UUID {
        let id = UUID()
        history.begin(id: id, engine: "test", source: isNote ? .note : .app)
        let writer = try recovery.begin(id: id, engine: "test", source: isNote ? .note : .app)
        writer.append([Float](repeating: 0.05, count: 16_000))
        try await writer.finish()
        let durable = history.finish(id: id, text: words, audioSeconds: 1,
                                     status: NoteReceipt.historyStatus(isNote: isNote, noteWriteFailed: false))
        XCTAssertTrue(durable)
        try recovery.complete(id, text: words, discardShortEmpty: true)
        if NoteReceipt.mayRelease(historyDurable: durable, isNote: isNote, noteWritten: false) {
            try recovery.consumeTextReceipt(id)
        }
        return id
    }

    /// What a relaunched Zone can show for this recording: the notes file, a recovery card, or
    /// a History record that Home and search do not hide.
    private func whereTheWordsAre(_ id: UUID) throws -> (inNotes: Bool, onCard: Bool, visibleInHistory: Bool) {
        let notes = try LibraryNotesFile.read(at: notesURL)
        let cards = try AudioRecoveryStore(directory: recovery.directory).records()
            .filter { $0.state == .failed || $0.state == .textReady || $0.state == .retrying }
        let record = TranscriptHistory(directory: history.directory).records().first { $0.id == id }
        return (notes.contains { $0.text == words },
                cards.contains { $0.id == id && $0.text == words },
                record.map { $0.status != .note } ?? false)
    }

    /// The defect: iOS ends Zone after History saved the note and before the notes file was
    /// written (Cleanup, before 1.0.6, ran in between for up to eight seconds). The note was in no list.
    func testANoteEndedBeforeItsFileWriteIsStillOnARecoveryCard() async throws {
        let id = try await recordAndReachTheNotesWrite(isNote: true)
        // The process ends here. Nothing below runs; the next launch reads what is on disk.
        try AudioRecoveryStore(directory: recovery.directory).recoverAbandoned()
        let found = try whereTheWordsAre(id)
        XCTAssertFalse(found.inNotes)
        XCTAssertFalse(found.visibleInHistory, "A .note record is hidden from Home and search")
        XCTAssertTrue(found.onCard, "The note's words must survive on Home's recovery card")
    }

    func testANoteWrittenToItsFileReleasesItsReceipt() async throws {
        let id = try await recordAndReachTheNotesWrite(isNote: true)
        try LibraryNotesFile.write([LibraryNote(text: words)], to: notesURL)
        if NoteReceipt.mayRelease(historyDurable: true, isNote: true, noteWritten: true) {
            try recovery.consumeTextReceipt(id)
        }
        let found = try whereTheWordsAre(id)
        XCTAssertTrue(found.inNotes)
        XCTAssertFalse(found.onCard, "A saved note leaves no card behind")
    }

    /// The notes file refused the write: History shows it as cut off and the card stays.
    func testANoteTheFileRefusedIsVisibleInHistoryAndOnACard() async throws {
        let id = try await recordAndReachTheNotesWrite(isNote: true)
        let blocked = root.appendingPathComponent("missing-folder/notes.json")
        XCTAssertThrowsError(try LibraryNotesFile.write([LibraryNote(text: words)], to: blocked))
        history.finish(id: id, text: words, audioSeconds: 1,
                       status: NoteReceipt.historyStatus(isNote: true, noteWriteFailed: true))
        XCTAssertFalse(NoteReceipt.mayRelease(historyDurable: true, isNote: true, noteWritten: false))
        let found = try whereTheWordsAre(id)
        XCTAssertTrue(found.visibleInHistory)
        XCTAssertTrue(found.onCard)
    }

    /// Dictations are unchanged: History is their durable home and the receipt goes with it.
    func testADictationReleasesItsReceiptOnceHistoryHoldsIt() async throws {
        let id = try await recordAndReachTheNotesWrite(isNote: false)
        let found = try whereTheWordsAre(id)
        XCTAssertTrue(found.visibleInHistory)
        XCTAssertFalse(found.onCard)
        XCTAssertFalse(NoteReceipt.mayRelease(historyDurable: false, isNote: false, noteWritten: false))
        XCTAssertEqual(NoteReceipt.historyStatus(isNote: false, noteWriteFailed: true), .finished)
    }
}
