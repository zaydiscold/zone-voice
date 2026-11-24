// by zayd/cold @ zayd.wtf

import AppIntents
import XCTest
import ZoneCore
@testable import Zone

/// The note card and the Note saved page, through the production coordinator, the real
/// microphone engine and the real Voice note intent. Speech is a script, so each note's words
/// are known. Covers the presses the way they come on a phone: one after another with no pause,
/// called off while the microphone comes on, thrown away, silent, failing, saved from the
/// background and found later, and interrupted by the keyboard.
@MainActor
final class NoteCaptureFlowTests: XCTestCase {
    private var coordinator: DictationCoordinator!
    private var engine: NoteFlowSpeechEngine!
    private var suite: String!
    private var settings: AppSettings!
    private var permission: NoteFlowGate!
    private var notesBefore: Set<UUID> = []
    /// The failed-press record, in this test's own suite: never the app's standard preferences.
    private var failureRecord: NoteStartFailureRecord!
    /// Coordinators made to stand for Zone after iOS ended its process.
    private var relaunched: [DictationCoordinator] = []

    override func setUpWithError() throws {
        suite = "note-flow-" + UUID().uuidString
        let store = UserDefaultsSharedStore(suiteName: suite)
        settings = AppSettings(defaults: UserDefaults(suiteName: suite)!, store: store)
        settings.soundsEnabled = false
        settings.startsSessionOnOpen = false
        engine = NoteFlowSpeechEngine()
        permission = NoteFlowGate(open: true)
        failureRecord = NoteStartFailureRecord(defaults: UserDefaults(suiteName: suite)!)
        coordinator = makeCoordinator(store: store)
        notesBefore = Set(coordinator.notes.notes.map(\.id))
    }

    private func makeCoordinator(store: UserDefaultsSharedStore, hardware: CaptureHardware = LiveCaptureHardware()) -> DictationCoordinator {
        let gate = permission!
        return DictationCoordinator(settings: settings, store: store, engine: engine,
                                    reviews: ReviewPrompter(store: ReviewPromptStore(suiteName: suite), appVersion: "test"),
                                    noteFailureRecord: failureRecord,
                                    requestSessionPermission: { await gate.wait(); return true },
                                    captureHardware: hardware)
    }

    override func tearDown() async throws {
        for zone in relaunched {
            zone.scenePhaseChanged(.background)
            zone.endSession(reason: .user)
        }
        relaunched = []
        DictationCoordinator.shortcutCoordinator = coordinator
        await permission.open()
        if coordinator.activity.isRecording { coordinator.cancelDictation() }
        try? await coordinator.settleRecordingShortcut()
        coordinator.endSession(reason: .user)
        for note in coordinator.notes.notes where !notesBefore.contains(note.id) { coordinator.notes.delete(note) }
        coordinator = nil
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    private var newNotes: [Note] { coordinator.notes.notes.filter { !notesBefore.contains($0.id) } }

    private func waitFor(_ what: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: One note, start to finish

    func testNumbersPersistAcrossRelaunchAndReachKeyboard() throws {
        let store = UserDefaultsSharedStore(suiteName: suite)
        settings.numbers.mode = .words
        settings.numbers.styles.insert(.veryCasual)
        settings.numbers.styles.remove(.excited)
        let expected = NumberPreferences(mode: .words, styles: [.veryCasual, .casual, .formal])
        XCTAssertEqual(store.keyboardPreferences.numbers, expected)
        let reopened = AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), store: store)
        XCTAssertEqual(reopened.numbers, expected)
    }

    func testNumbersInSavedNote() async throws {
        settings.numbers.mode = .words
        settings.defaultTextStyle = .casual
        await coordinator.prepareModelAndWait()
        engine.texts = ["I saw 7 birds"]
        await coordinator.dictateNote()
        await coordinator.stopDictation(reason: "noteCard")
        XCTAssertEqual(coordinator.lastSavedNote?.text, "I saw seven birds")
    }

    func testNumbersInAppDictation() async throws {
        settings.numbers.mode = .words
        settings.defaultTextStyle = .casual
        await coordinator.prepareModelAndWait()
        engine.texts = ["I saw 7 birds"]
        await coordinator.startAppDictation(contextBefore: "")
        await coordinator.stopDictation(reason: "user")
        let result = try XCTUnwrap(coordinator.lastResult)
        XCTAssertEqual(coordinator.composerInsertion(result.text, before: ""), "I saw seven birds")
    }

    func testCardFollowsTheNoteAndThePageShowsTheSavedWords() async throws {
        await coordinator.prepareModelAndWait()
        let recognition = NoteFlowGate(open: false)
        engine.finishGate = recognition
        engine.texts = ["Pick up oat milk and call the dentist."]
        await coordinator.dictateNote()
        guard case .recording = coordinator.noteCard else { return XCTFail("No recording card: \(String(describing: coordinator.noteCard))") }
        XCTAssertTrue(coordinator.noteIsLive)
        XCTAssertNil(coordinator.notePage)
        XCTAssertFalse(coordinator.hasRecordingScreen, "A note has its card, not the dictation strip")
        XCTAssertTrue(coordinator.isBusyForWhatsNew)

        let stop = Task { await coordinator.stopDictation(reason: "noteCard") }
        try await waitFor("saving") { coordinator.noteCard == .saving }
        XCTAssertNil(coordinator.notePage, "No page until the words are saved")
        await recognition.open()
        await stop.value

        XCTAssertNil(coordinator.noteCard, "The card goes when the page comes")
        let page = try XCTUnwrap(coordinator.notePage)
        let saved = try XCTUnwrap(coordinator.lastSavedNote)
        XCTAssertEqual(page.noteID, saved.id)
        XCTAssertEqual(page.notesBefore, coordinator.notes.notes.count - 1)
        XCTAssertTrue(coordinator.notes.notes.contains { $0.id == saved.id && $0.text.contains("oat milk") })
        XCTAssertTrue(coordinator.isBusyForWhatsNew, "What's New waits while the page is up")

        coordinator.closeNotePage()
        XCTAssertNil(coordinator.notePage)
        XCTAssertEqual(coordinator.activity, .idle, "Done acknowledges the finished note")
        XCTAssertFalse(coordinator.isBusyForWhatsNew)
    }

    // MARK: Rapid fire through the Action Button's own intent

    func testFiveActionButtonNotesInARowEachSaveAndEachPressClosesTheLastPage() async throws {
        await coordinator.prepareModelAndWait()
        engine.texts = (1...5).map { "Rapid note number \($0)." }
        var pages: [UUID] = []
        for round in 1...5 {
            _ = try await DictateNoteIntent().perform()
            guard case .recording = coordinator.noteCard else { return XCTFail("Press \(round) did not record") }
            XCTAssertNil(coordinator.notePage, "Press \(round) left the last page up over the new note")
            _ = try await DictateNoteIntent().perform()
            let page = try XCTUnwrap(coordinator.notePage, "Press \(round) saved no page")
            XCTAssertFalse(pages.contains(page.noteID))
            pages.append(page.noteID)
            XCTAssertFalse(coordinator.isArmed, "Each stop releases the microphone (round \(round))")
            XCTAssertNil(coordinator.noteCard)
        }
        XCTAssertEqual(newNotes.count, 5)
        XCTAssertEqual(Set(newNotes.map(\.id)), Set(pages))
        for round in 1...5 {
            XCTAssertTrue(newNotes.contains { $0.text.contains("number \(round)") }, "Note \(round) is missing")
        }
        XCTAssertEqual(coordinator.notePage?.noteID, pages.last)
        XCTAssertEqual(engine.starts, 5)
    }

    /// The same five notes with the page's own mic: no Done in between.
    func testNewNoteFromThePageClosesItAndRecordsAgain() async throws {
        await coordinator.prepareModelAndWait()
        engine.texts = ["First thought.", "Second thought."]
        await coordinator.dictateNote()
        await coordinator.stopDictation(reason: "noteCard")
        let first = try XCTUnwrap(coordinator.notePage)
        await coordinator.dictateNote()
        XCTAssertNil(coordinator.notePage)
        guard case .recording = coordinator.noteCard else { return XCTFail("The page's mic did not record") }
        await coordinator.stopDictation(reason: "noteCard")
        let second = try XCTUnwrap(coordinator.notePage)
        XCTAssertNotEqual(first.noteID, second.noteID)
        XCTAssertEqual(second.notesBefore, first.notesBefore + 1)
    }

    // MARK: Called off, thrown away, silent, failed

    func testXWhileTheMicrophoneComesOnRecordsNothing() async throws {
        await coordinator.prepareModelAndWait()
        await permission.close()
        let press = Task { await coordinator.dictateNote() }
        try await waitFor("starting card") {
            if case .starting = coordinator.noteCard { return true }
            return false
        }
        XCTAssertEqual(coordinator.noteCard, .starting(detail: "Turning on the microphone"))
        coordinator.cancelNoteStart()
        XCTAssertNil(coordinator.noteCard, "X takes the card away at once")
        await permission.open()
        await press.value
        XCTAssertEqual(engine.starts, 0, "A called-off note must not record")
        XCTAssertFalse(coordinator.activity.isBusy)
        XCTAssertNil(coordinator.noteCard)
        XCTAssertNil(coordinator.notePage)
        XCTAssertTrue(newNotes.isEmpty)
    }

    /// X, then a second thought before the microphone was even on: the start goes on.
    func testPressingAgainAfterXWhileTheMicrophoneComesOnStillRecords() async throws {
        await coordinator.prepareModelAndWait()
        await permission.close()
        engine.texts = ["Changed my mind back."]
        let press = Task { await coordinator.dictateNote() }
        try await waitFor("starting card") { coordinator.noteCard != nil }
        coordinator.cancelNoteStart()
        XCTAssertNil(coordinator.noteCard)
        await coordinator.dictateNote()
        guard case .starting = coordinator.noteCard else { return XCTFail("The second press did not take the start back") }
        await permission.open()
        await press.value
        guard case .recording = coordinator.noteCard else { return XCTFail("The resumed start did not record") }
        XCTAssertEqual(engine.starts, 1)
        await coordinator.stopDictation(reason: "noteCard")
        XCTAssertNotNil(coordinator.notePage)
    }

    func testXDuringAnActionButtonPressPreparationEndsThePressWithoutRecording() async throws {
        let hardware = FakeCaptureHardware(sampleRate: 16_000)
        hardware.deliverFirstBufferOnStart = true
        coordinator = makeCoordinator(store: UserDefaultsSharedStore(suiteName: suite), hardware: hardware)
        await coordinator.prepareModelAndWait()
        await permission.close()
        let press = Task { _ = try await DictateNoteIntent().perform() }
        try await waitFor("starting card") {
            if case .starting = coordinator.noteCard { return true }
            return false
        }
        coordinator.cancelNoteStart()
        await permission.open()
        try await press.value
        XCTAssertEqual(engine.starts, 0)
        XCTAssertEqual(hardware.snapshot.starts, 0)
        XCTAssertFalse(coordinator.activity.isBusy)
        XCTAssertFalse(coordinator.isArmed, "The press released the microphone it turned on")
        XCTAssertNil(coordinator.noteCard)

        // The next press is a normal note.
        engine.texts = ["After the cancel."]
        _ = try await DictateNoteIntent().perform()
        guard case .recording = coordinator.noteCard else { return XCTFail("The next press did not record") }
        _ = try await DictateNoteIntent().perform()
        XCTAssertNotNil(coordinator.notePage)
    }

    func testDiscardedNoteLeavesNoNoteNoPageAndNoCard() async throws {
        await coordinator.prepareModelAndWait()
        await coordinator.dictateNote()
        coordinator.cancelDictation()
        XCTAssertNil(coordinator.noteCard)
        XCTAssertNil(coordinator.notePage)
        XCTAssertTrue(newNotes.isEmpty)
        XCTAssertEqual(coordinator.activity, .idle)
    }

    func testSilentNoteSaysNoWordsBrieflyAndSavesNothing() async throws {
        await coordinator.prepareModelAndWait()
        engine.texts = ["   "]
        await coordinator.dictateNote()
        await coordinator.stopDictation(reason: "noteCard")
        XCTAssertEqual(coordinator.noteCard, .noWords)
        XCTAssertNil(coordinator.notePage)
        XCTAssertTrue(newNotes.isEmpty)
        XCTAssertFalse(coordinator.noteIsLive, "The composer is free again")
        coordinator.dismissNoteOutcome()
        XCTAssertNil(coordinator.noteCard)
    }

    func testNoWordsCardFoldsAwayByItself() async throws {
        await coordinator.prepareModelAndWait()
        engine.texts = [""]
        await coordinator.dictateNote()
        await coordinator.stopDictation(reason: "noteCard")
        XCTAssertEqual(coordinator.noteCard, .noWords)
        try await waitFor("the card to fold", timeout: .seconds(5)) { coordinator.noteCard == nil }
    }

    func testFailedRecognitionSaysSoOnTheCardAndXAcknowledgesIt() async throws {
        await coordinator.prepareModelAndWait()
        engine.finishFails = true
        await coordinator.dictateNote()
        await coordinator.stopDictation(reason: "noteCard")
        guard case .failed(let message) = coordinator.noteCard else {
            return XCTFail("No failure on the card: \(String(describing: coordinator.noteCard))")
        }
        XCTAssertTrue(message.contains("could not be written out"), message)
        XCTAssertNil(coordinator.notePage)
        guard case .failed = coordinator.activity else { return XCTFail("Home's notice has nothing to show") }
        coordinator.dismissNoteOutcome()
        XCTAssertNil(coordinator.noteCard)
        XCTAssertEqual(coordinator.activity, .idle, "X on the card also clears Home's copy of the failure")
    }

    // MARK: A note is safe until the notes file holds it (NoteReceipt)

    /// The notes file refuses the write. The note's words stay on Home's recovery card and in
    /// History as cut off; before, History hid them as a `.note` and the card was already gone.
    func testANoteTheNotesFileRefusedKeepsItsWordsOnARecoveryCard() async throws {
        let blocked = FileManager.default.temporaryDirectory
            .appendingPathComponent("note-flow-missing-\(UUID().uuidString)/notes.json")
        relaunched.append(coordinator)
        engine = NoteFlowSpeechEngine()
        let gate = permission!
        coordinator = DictationCoordinator(settings: settings, store: UserDefaultsSharedStore(suiteName: suite), engine: engine,
                                           reviews: ReviewPrompter(store: ReviewPromptStore(suiteName: suite), appVersion: "test"),
                                           noteFailureRecord: failureRecord, notes: NotesStore(url: blocked),
                                           requestSessionPermission: { await gate.wait(); return true })
        notesBefore = []
        await coordinator.prepareModelAndWait()
        engine.texts = ["Synthetic note the file refused."]
        await coordinator.dictateNote()
        guard case .recording = coordinator.noteCard else { return XCTFail("No recording card") }
        await coordinator.stopDictation(reason: "noteCard")

        guard case .failed(let message) = coordinator.noteCard else {
            return XCTFail("A note that was not saved must say so: \(String(describing: coordinator.noteCard))")
        }
        XCTAssertTrue(message.contains("Could not save the note"), message)
        XCTAssertNil(coordinator.notePage, "No Note saved page for a note that was not saved")
        XCTAssertNil(coordinator.lastSavedNote)
        let id = try XCTUnwrap(coordinator.lastResult?.requestID)
        try await waitFor("the recovery card") {
            coordinator.audioRecoveryRecords.contains { $0.id == id && $0.state == .textReady && $0.text.contains("file refused") }
        }
        let record = TranscriptHistory.shared?.records().first { $0.id == id }
        XCTAssertNotEqual(record?.status, .note, "A .note record is hidden from Home and search")
        coordinator.deleteAudioRecovery(id)
        TranscriptHistory.shared?.delete(id: id)
    }

    /// The keyboard's mic tapped while a note is being spoken: the note carries on and saves whole.
    /// Before, the tap retired the note mid-sentence and it skipped its own save.
    func testAKeyboardTapNeverEndsANoteBeingSpoken() async throws {
        await coordinator.prepareModelAndWait()
        engine.texts = ["Synthetic note a keyboard tap must not end."]
        await coordinator.dictateNote()
        guard case .recording = coordinator.noteCard else { return XCTFail("No recording card") }
        let store = UserDefaultsSharedStore(suiteName: suite)
        let request = DictationRequest(id: UUID(), generation: 9, createdAt: Date(), inputSession: "field", contextBefore: nil)
        store.request = request
        store.status = DictationStatus(requestID: request.id, generation: 9, phase: .requested, updatedAt: Date(), message: nil)
        DarwinNotifier.post(.requestChanged)
        try await waitFor("the refusal") { store.status?.requestID == request.id && store.status?.phase == .failed }
        XCTAssertEqual(store.status?.message, DictationCoordinator.noteRefusal)
        guard case .recording = coordinator.noteCard else { return XCTFail("The note stopped: \(String(describing: coordinator.noteCard))") }
        await coordinator.stopDictation(reason: "noteCard")
        let saved = try XCTUnwrap(coordinator.lastSavedNote)
        XCTAssertTrue(saved.text.contains("keyboard tap must not end"), saved.text)
    }

    /// The notes file could not be read at launch and can a moment later. The next note joins
    /// the older ones; before, it replaced them all.
    func testANoteSavedAfterAFailedFirstReadKeepsTheOlderNotes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notes-reread-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        let store = NotesStore(url: url)
        XCTAssertNotNil(store.lastError)
        XCTAssertNil(store.add("Refused while the file is unreadable"), "Nothing is written over a file that cannot be read")
        XCTAssertEqual(try Data(contentsOf: url), Data("not json".utf8))
        let older = [LibraryNote(id: UUID(), text: "Older one", createdAt: Date(timeIntervalSinceNow: -60)),
                     LibraryNote(id: UUID(), text: "Older two", createdAt: Date(timeIntervalSinceNow: -30))]
        try JSONEncoder().encode(older).write(to: url)
        XCTAssertNotNil(store.add("The new one"))
        XCTAssertEqual(Set(try LibraryNotesFile.read(at: url).map(\.text)), ["Older one", "Older two", "The new one"])
        XCTAssertNil(store.lastError)
    }

    /// A saved note releases its receipt only after the write: no card is left behind.
    func testASavedNoteLeavesNoRecoveryCard() async throws {
        await coordinator.prepareModelAndWait()
        engine.texts = ["Synthetic note that saved."]
        await coordinator.dictateNote()
        await coordinator.stopDictation(reason: "noteCard")
        let saved = try XCTUnwrap(coordinator.lastSavedNote)
        XCTAssertTrue(coordinator.notes.notes.contains { $0.id == saved.id })
        let id = try XCTUnwrap(coordinator.lastResult?.requestID)
        try await waitFor("the receipt to go") {
            !coordinator.audioRecoveryRecords.contains { $0.id == id }
        }
    }

    func testSavedCasualNoteFollowsAutoCapitalization() async throws {
        settings.defaultTextStyle = .casual
        settings.autoCapitalizationEnabled = false
        let page = try await saveOneNote("My iPhone uses Apple Music")
        let saved = try XCTUnwrap(coordinator.notes.notes.first { $0.id == page.noteID })
        XCTAssertEqual(saved.text, "my iphone uses apple music")
    }

    func testFillerOnlyNoteKeepsTheSpokenWords() async throws {
        let page = try await saveOneNote("um")
        let saved = try XCTUnwrap(coordinator.notes.notes.first { $0.id == page.noteID })
        XCTAssertEqual(saved.text.lowercased(), "um")
    }

    func testFailedStartSaysSoOnTheCard() async throws {
        await coordinator.prepareModelAndWait()
        engine.startFails = true
        await coordinator.dictateNote()
        guard case .failed = coordinator.noteCard else {
            return XCTFail("A note that could not start must say so: \(String(describing: coordinator.noteCard))")
        }
        engine.startFails = false
        engine.texts = ["Second try."]
        await coordinator.dictateNote()
        guard case .recording = coordinator.noteCard else { return XCTFail("Try again did not record") }
        await coordinator.stopDictation(reason: "noteCard")
        XCTAssertNotNil(coordinator.notePage)
    }

    // MARK: The page: edit, delete, Added to Notes

    func testShortcutReadsTheSavedNoteBeforeAndAfterAnEdit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let history = TranscriptHistory(directory: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notes.json")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let id = UUID()
        XCTAssertTrue(history.finish(id: id, text: "raw words", audioSeconds: 1, status: .note, source: .note, now: date))
        var note = LibraryNote(text: "Clean words", recordingID: id)
        try LibraryNotesFile.write([note], to: url)
        XCTAssertEqual(try LastDictationIntent.recentResult(history: history, notesURL: url, now: date), "Clean words")
        XCTAssertEqual(try LastDictationIntent.recent(history: history, notesURL: url, now: date)?.finishedAt, date)
        note.text = "My edit"
        try LibraryNotesFile.write([note], to: url)
        XCTAssertTrue(history.delete(id: id))
        XCTAssertEqual(try LastDictationIntent.recentResult(history: history, notesURL: url, now: date), "My edit")
        XCTAssertEqual(try LastDictationIntent.recent(history: history, notesURL: url, now: date)?.finishedAt, date)
        try LibraryNotesFile.write([], to: url)
        XCTAssertNil(try LastDictationIntent.recentResult(history: history, notesURL: url, now: date))
    }

    func testTwoStoresCannotReplaceEachOthersNotes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let first = NotesStore(url: url), second = NotesStore(url: url)
        XCTAssertNotNil(first.add("one"))
        XCTAssertNil(second.add("two"))
        XCTAssertNotNil(second.lastError)
        XCTAssertNotNil(second.add("two"))
        XCTAssertEqual(try LibraryNotesFile.read(at: url).map(\.text), ["two", "one"])
    }

    func testRetryUsesOneNoteAndPreservesHandEdits() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = NotesStore(url: url)
        let recording = UUID()
        let original = try XCTUnwrap(store.add("partial", recordingID: recording))
        let recovered = try XCTUnwrap(store.add("complete", recordingID: recording))
        XCTAssertEqual(recovered.id, original.id)
        XCTAssertEqual(recovered.createdAt, original.createdAt)
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertTrue(store.update(recovered, text: "my edit"))
        let copy = try XCTUnwrap(store.add("later retry", recordingID: recording))
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(try LibraryNotesFile.read(at: url).map(\.text), ["later retry", "my edit"])
        XCTAssertEqual(store.add("complete retry", recordingID: recording)?.id, copy.id)
        XCTAssertEqual(store.notes.count, 2)
    }

    func testPreviouslyImportedWatchNoteCannotReturnAfterDeletion() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let envelope = try CompanionNoteEnvelope(text: "older Watch")
        let url = folder.appendingPathComponent("notes.json")
        let store = NotesStore(url: url)
        try store.importBackup([Note(id: envelope.id, text: envelope.text, createdAt: envelope.createdAt)])
        XCTAssertTrue(store.delete(try XCTUnwrap(store.notes.first)))
        let reopened = NotesStore(url: url)
        try reopened.importWatch(envelope)
        XCTAssertTrue(reopened.notes.isEmpty)
    }

    func testWatchRedeliveryAfterDeletionIsIgnored() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notes.json")
        let store = NotesStore(url: url)
        let envelope = try CompanionNoteEnvelope(text: "Watch only")
        try store.importWatch(envelope)
        XCTAssertTrue(store.delete(try XCTUnwrap(store.notes.first)))
        let reopened = NotesStore(url: url)
        try reopened.importWatch(envelope)
        XCTAssertTrue(reopened.notes.isEmpty)
    }

    func testConcurrentEditorPreservesDraftUntilExplicitRetry() throws {
        let opened = try XCTUnwrap(coordinator.notes.add("A"))
        defer { _ = coordinator.deleteNote(opened.id) }
        var draft = NoteEditDraft(opening: opened)
        XCTAssertTrue(coordinator.updateNote(opened.id, text: "B"))
        XCTAssertTrue(coordinator.saveNoteDraft(draft))
        XCTAssertEqual(coordinator.notes.notes.first { $0.id == opened.id }?.text, "B")
        draft.text = "C"
        XCTAssertFalse(coordinator.saveNoteDraft(draft))
        XCTAssertEqual(coordinator.failedNoteEdits[opened.id], "C")
        XCTAssertEqual(coordinator.notes.notes.first { $0.id == opened.id }?.text, "B")
        XCTAssertTrue(coordinator.saveNoteDraft(opened.id, text: draft.text))
        XCTAssertNil(coordinator.failedNoteEdits[opened.id])
        XCTAssertEqual(coordinator.notes.notes.first { $0.id == opened.id }?.text, "C")
    }

    func testRefusedEditSurvivesLeavingThePage() async throws {
        let page = try await saveOneNote("Original")
        let url = coordinator.notes.fileURL
        let original = try Data(contentsOf: url)
        defer { try? original.write(to: url, options: .atomic) }
        try Data("unreadable".utf8).write(to: url, options: .atomic)
        let recording = try XCTUnwrap(coordinator.notes.notes.first { $0.id == page.noteID }?.recordingID)
        let history = try XCTUnwrap(TranscriptHistory.shared)
        XCTAssertNotNil(history.record(id: recording))
        let draft = "Keep my changed words"
        defer { XCTAssertNotNil(history.record(id: recording)) }
        XCTAssertFalse(coordinator.saveNoteDraft(page.noteID, text: draft))
        XCTAssertEqual(coordinator.failedNoteEdits[page.noteID], draft)
    }

    func testRefusedPageDeletionKeepsThePage() async throws {
        let page = try await saveOneNote("Keep this page")
        let url = coordinator.notes.fileURL
        let original = try Data(contentsOf: url)
        defer { try? original.write(to: url, options: .atomic) }
        try Data("unreadable".utf8).write(to: url, options: .atomic)
        coordinator.deleteNote(page.noteID)
        XCTAssertEqual(coordinator.notePage?.noteID, page.noteID)
        XCTAssertNotNil(coordinator.notes.lastError)
    }

    func testLegacyNoteNeverDeletesHistoryByGuessing() throws {
        let history = try XCTUnwrap(TranscriptHistory.shared)
        let now = Date()
        let text = UUID().uuidString
        let first = UUID(), second = UUID()
        defer { history.delete(id: first); history.delete(id: second) }
        XCTAssertTrue(history.finish(id: first, text: text, audioSeconds: 1, status: .note, source: .note, now: now))
        XCTAssertTrue(history.finish(id: second, text: text, audioSeconds: 1, status: .note, source: .note, now: now))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = NotesStore(url: url)
        let ambiguous = try XCTUnwrap(store.add(text, createdAt: now))
        XCTAssertTrue(store.delete(ambiguous))
        XCTAssertNotNil(history.record(id: first))
        XCTAssertNotNil(history.record(id: second))
        history.delete(id: second)
        let unique = try XCTUnwrap(store.add(text, createdAt: now))
        XCTAssertTrue(store.delete(unique))
        XCTAssertNotNil(history.record(id: first))
    }

    func testEditingANoteRemovesItsOriginalHistoryWords() async throws {
        let phrase = "Private phrase " + UUID().uuidString
        let page = try await saveOneNote(phrase)
        let history = try XCTUnwrap(TranscriptHistory.shared)
        let raw = try XCTUnwrap(history.records().first { $0.status == .note && $0.text == phrase })
        defer { history.delete(id: raw.id) }
        XCTAssertTrue(coordinator.updateNote(page.noteID, text: "Replacement"))
        XCTAssertNil(history.record(id: raw.id))
    }

    func testEditingOnThePageUpdatesTheNoteInPlace() async throws {
        let page = try await saveOneNote("Buy stamps.")
        coordinator.updateNote(page.noteID, text: "Buy stamps and envelopes.")
        let note = try XCTUnwrap(coordinator.notes.notes.first { $0.id == page.noteID })
        XCTAssertEqual(note.text, "Buy stamps and envelopes.")
        XCTAssertNotNil(note.editedAt)
        XCTAssertEqual(coordinator.notePage?.noteID, page.noteID, "Saving an edit keeps the page up")
    }

    func testEmptyingTheNoteOnThePageDeletesItAndClosesThePage() async throws {
        let page = try await saveOneNote("Delete me by emptying.")
        coordinator.updateNote(page.noteID, text: "  \n ")
        XCTAssertFalse(coordinator.notes.notes.contains { $0.id == page.noteID })
        XCTAssertNil(coordinator.notePage)
    }

    func testDeleteOnThePageRemovesTheNoteTellsLinkAndClosesThePage() async throws {
        var deleted: [UUID] = []
        coordinator.notes.onDelete = { deleted += $0 }
        let page = try await saveOneNote("A note to delete.")
        coordinator.deleteNote(page.noteID)
        XCTAssertFalse(coordinator.notes.notes.contains { $0.id == page.noteID })
        XCTAssertNil(coordinator.notePage)
        XCTAssertEqual(deleted, [page.noteID])
        coordinator.deleteNote(page.noteID)
        coordinator.notes.delete(LibraryNote(id: page.noteID, text: "gone", createdAt: Date()))
        XCTAssertEqual(deleted, [page.noteID], "Deleting a note already gone is not a second deletion")
    }

    func testAddedToNotesClosesThePageAndRevealsTheNoteForAMoment() async throws {
        let page = try await saveOneNote("Find me on Home.")
        coordinator.revealNoteInLibrary(page.noteID)
        XCTAssertNil(coordinator.notePage)
        XCTAssertEqual(coordinator.noteReveal?.noteID, page.noteID)
        try await waitFor("the light to go out", timeout: .seconds(4)) { coordinator.noteReveal == nil }
    }

    // MARK: Leaving Zone and coming back

    func testAPageSavedWhileAwayShowsWhenFreshAndIsDroppedWhenStale() async throws {
        coordinator.scenePhaseChanged(.background)
        var now = Date()
        coordinator.noteClock = { now }
        let page = try await saveOneNote("Saved from the Lock Screen.")
        now = now.addingTimeInterval(4 * 60)
        coordinator.scenePhaseChanged(.active)
        XCTAssertEqual(coordinator.notePage?.noteID, page.noteID, "Back within minutes: the page is waiting")

        coordinator.scenePhaseChanged(.background)
        now = now.addingTimeInterval(DictationCoordinator.notePageFreshness)
        coordinator.scenePhaseChanged(.active)
        XCTAssertNil(coordinator.notePage, "Back much later: the page is stale and gone")
        XCTAssertTrue(coordinator.notes.notes.contains { $0.id == page.noteID }, "The note itself stays")
    }

    func testTheKeyboardsDictationScreenAlwaysWinsOverThePage() async throws {
        _ = try await saveOneNote("A note, then the keyboard.")
        let request = DictationRequest(id: UUID(), generation: 1, createdAt: Date(), inputSession: "field", contextBefore: nil)
        let store = UserDefaultsSharedStore(suiteName: suite)
        store.request = request
        store.status = DictationStatus(requestID: request.id, generation: request.generation, phase: .requested, updatedAt: Date(), message: nil)
        coordinator.handle(url: ZoneContract.dictateURL(requestID: request.id))
        XCTAssertNil(coordinator.notePage, "The page would stand in front of the keyboard's dictation screen")
        XCTAssertTrue(coordinator.showsDictationScreen)
        coordinator.dismissDictationScreen()
    }

    func testTappingTheLiveActivityKeepsAFreshPage() async throws {
        let page = try await saveOneNote("Opened from the island.")
        coordinator.handle(url: URL(string: "zone://recording")!)
        XCTAssertEqual(coordinator.notePage?.noteID, page.noteID)
    }

    // MARK: Several notes saved in a row away from Zone

    /// One Action Button note: both presses, away from Zone. Returns the page it left.
    private func pressNote() async throws -> NotePage {
        _ = try await DictateNoteIntent().perform()
        guard case .recording = coordinator.noteCard else {
            XCTFail("The press did not record: \(coordinator.activity)")
            throw NoteFlowFailure.failed
        }
        _ = try await DictateNoteIntent().perform()
        return try XCTUnwrap(coordinator.notePage)
    }

    /// Zayd, November 19: three notes from the Action Button, then Zone opened on a page for
    /// the third only. The first two could not be copied or fixed without finding them in Notes.
    func testNotesSavedInARowAwayFromZoneAllComeOnOnePage() async throws {
        coordinator.scenePhaseChanged(.background)
        await coordinator.prepareModelAndWait()
        engine.texts = ["First away.", "Second away.", "Third away."]
        var ids: [UUID] = []
        for _ in 1...3 { ids.append(try await pressNote().noteID) }
        XCTAssertEqual(coordinator.notePage?.entries.map(\.noteID), ids, "Oldest first, the newest last")
        XCTAssertEqual(coordinator.notePage?.noteID, ids[2], "The page opens on the newest")

        coordinator.scenePhaseChanged(.active)
        XCTAssertEqual(coordinator.notePage?.entries.map(\.noteID), ids, "Opening Zone shows all three")
        let texts = ids.compactMap { id in coordinator.notes.notes.first { $0.id == id }?.text }
        XCTAssertEqual(texts.count, 3)
        XCTAssertTrue(texts[0].contains("First") && texts[2].contains("Third"))
        XCTAssertEqual(coordinator.notePage?.combinedText(in: coordinator.notes.notes),
                       texts.joined(separator: "\n\n"), "Copy all: oldest first, a blank line between")

        coordinator.deleteNote(ids[1])
        XCTAssertEqual(coordinator.notePage?.entries.map(\.noteID), [ids[0], ids[2]], "Deleting one keeps the page on the rest")
        coordinator.updateNote(ids[2], text: "   ")
        XCTAssertEqual(coordinator.notePage?.noteID, ids[0], "Emptying the newest leaves the one before it")
        XCTAssertEqual(coordinator.notePage?.earlier, [])
        coordinator.deleteNote(ids[0])
        XCTAssertNil(coordinator.notePage, "The page goes with its last note")
    }

    /// A page the person looked at leaves nothing behind: the page's own mic, or another press
    /// after coming back, starts a page for that one note.
    func testAPageThatWasSeenIsNotCarriedIntoTheNext() async throws {
        coordinator.scenePhaseChanged(.active)
        await coordinator.prepareModelAndWait()
        engine.texts = ["Seen in Zone.", "From the page's mic.", "Saved away.", "After coming back."]
        _ = try await saveOneNote("Seen in Zone.")
        await coordinator.dictateNote()
        await coordinator.stopDictation(reason: "noteCard")
        XCTAssertEqual(coordinator.notePage?.earlier, [], "The first page was on screen")

        coordinator.closeNotePage()
        coordinator.scenePhaseChanged(.background)
        let away = try await pressNote()
        XCTAssertEqual(away.earlier, [])
        coordinator.scenePhaseChanged(.active)
        coordinator.scenePhaseChanged(.background)
        let next = try await pressNote()
        XCTAssertEqual(next.earlier, [], "The page for the note saved away was seen on coming back")
    }

    func testDoneAndAStalePageLeaveNothingUnseen() async throws {
        coordinator.scenePhaseChanged(.background)
        var now = Date()
        coordinator.noteClock = { now }
        await coordinator.prepareModelAndWait()
        engine.texts = (1...6).map { "Away \($0)." }
        _ = try await pressNote()
        let page1 = try await pressNote()
        XCTAssertEqual(page1.earlier.count, 1)
        coordinator.closeNotePage()
        let page2 = try await pressNote()
        XCTAssertEqual(page2.earlier, [], "Done was the person finishing with those notes")

        let page3 = try await pressNote()
        XCTAssertEqual(page3.earlier.count, 1)
        now = now.addingTimeInterval(DictationCoordinator.notePageFreshness + 1)
        coordinator.scenePhaseChanged(.active)
        XCTAssertNil(coordinator.notePage, "Back much later: the page is stale")
        coordinator.scenePhaseChanged(.background)
        let page4 = try await pressNote()
        XCTAssertEqual(page4.earlier, [], "Old notes are in Notes, not on a new page")

        // Back in Zone with no page up, then away again: nothing is unseen.
        coordinator.closeNotePage(reason: "keyboardRequest")
        coordinator.scenePhaseChanged(.active)
        coordinator.scenePhaseChanged(.background)
        let page5 = try await pressNote()
        XCTAssertEqual(page5.earlier, [])
    }

    /// The keyboard's dictation takes the screen from the page; the notes on it were not read.
    func testAPageTakenAwayByTheKeyboardKeepsItsNotesForTheNextPage() async throws {
        coordinator.scenePhaseChanged(.background)
        await coordinator.prepareModelAndWait()
        engine.texts = ["Before the keyboard.", "After the keyboard."]
        let first = try await pressNote()
        coordinator.closeNotePage(reason: "keyboardRequest")
        let second = try await pressNote()
        XCTAssertEqual(second.earlier.map(\.noteID), [first.noteID])
    }

    func testKeyboardDestinationsPreserveUnseenNotes() async throws {
        coordinator.scenePhaseChanged(.background)
        await coordinator.prepareModelAndWait()
        engine.texts = ["First.", "Second.", "Third."]
        let first = try await pressNote()
        coordinator.handle(url: ZoneContract.Destination.home.url)
        XCTAssertEqual(coordinator.notePage?.noteID, first.noteID)
        coordinator.handle(url: ZoneContract.Destination.notes.url)
        XCTAssertNil(coordinator.notePage)
        let second = try await pressNote()
        XCTAssertEqual(second.earlier.map(\.noteID), [first.noteID])
        coordinator.handle(url: ZoneContract.Destination.settings.url)
        XCTAssertNil(coordinator.notePage)
        let third = try await pressNote()
        XCTAssertEqual(third.earlier.map(\.noteID), [first.noteID, second.noteID])
    }

    func testAPageHoldsOnlySoManyEarlierNotes() async throws {
        coordinator.scenePhaseChanged(.background)
        await coordinator.prepareModelAndWait()
        let count = DictationCoordinator.unseenNotesLimit + 4
        engine.texts = (1...count).map { "Many \($0)." }
        var ids: [UUID] = []
        for _ in 1...count { ids.append(try await pressNote().noteID) }
        let page = try XCTUnwrap(coordinator.notePage)
        XCTAssertEqual(page.entries.map(\.noteID), Array(ids.suffix(DictationCoordinator.unseenNotesLimit + 1)),
                       "The newest notes; the rest are in Notes on Home")
        XCTAssertEqual(newNotes.count, count, "Every note is saved whatever the page shows")
    }

    func testRemovingANoteFromAPage() {
        let ids = (0..<3).map { _ in UUID() }
        let page = NotePage(noteID: ids[2], savedAt: Date(), notesBefore: 4, audioSeconds: 3,
                            earlier: [.init(noteID: ids[0], audioSeconds: 1), .init(noteID: ids[1], audioSeconds: 2)])
        XCTAssertEqual(page.removing(UUID()), page, "A note that is not on the page changes nothing")
        XCTAssertEqual(page.removing(ids[0])?.entries.map(\.noteID), [ids[1], ids[2]])
        let promoted = page.removing(ids[2])
        XCTAssertEqual(promoted?.noteID, ids[1])
        XCTAssertEqual(promoted?.audioSeconds, 2)
        XCTAssertEqual(promoted?.earlier.map(\.noteID), [ids[0]])
        XCTAssertNil(NotePage(noteID: ids[0], savedAt: Date(), notesBefore: 0, audioSeconds: 1).removing(ids[0]))
    }

    // MARK: Not a note

    func testTheComposersOwnDictationIsNeverANote() async throws {
        await coordinator.prepareModelAndWait()
        engine.texts = ["Practice words."]
        await coordinator.startAppDictation(contextBefore: "")
        XCTAssertNil(coordinator.noteCard, "The composer's recording has no note card")
        await coordinator.stopDictation(reason: "user")
        XCTAssertNil(coordinator.notePage)
        XCTAssertNil(coordinator.lastSavedNote)
        XCTAssertTrue(newNotes.isEmpty)
    }

    func testANoteCalledOffMidStartDoesNotTurnTheNextRecordingIntoANote() async throws {
        await coordinator.prepareModelAndWait()
        await permission.close()
        let press = Task { await coordinator.dictateNote() }
        try await waitFor("starting card") { coordinator.noteCard != nil }
        coordinator.cancelNoteStart()
        await permission.open()
        await press.value
        engine.texts = ["Composer words."]
        await coordinator.startAppDictation(contextBefore: "")
        XCTAssertNil(coordinator.noteCard)
        await coordinator.stopDictation(reason: "user")
        XCTAssertTrue(newNotes.isEmpty)
    }

    // MARK: Finish when quiet

    /// Changed with the behavior: a thinking pause must never save a note.
    func testFinishWhenQuietNeverStopsANote() async throws {
        settings.finishWhenQuiet = true
        await coordinator.prepareModelAndWait()
        engine.texts = ["Book the vet for Thursday."]
        await coordinator.dictateNote()
        guard case .recording = coordinator.noteCard else { return XCTFail("No recording card") }
        await coordinator.stopDictation(reason: "quiet")
        XCTAssertTrue(coordinator.activity.isRecording, "Silence cut off a note")
        XCTAssertNil(coordinator.notePage)
        XCTAssertTrue(newNotes.isEmpty)
        XCTAssertNil(coordinator.quietFinishIn)
        XCTAssertNil(coordinator.quietUntil)
        await coordinator.stopDictation(reason: "noteCard")
        XCTAssertNotNil(coordinator.notePage, "Explicit stop still saves")
    }

    func testStartSoundAloneCannotArmAppDictationQuietTimer() async throws {
        settings.finishWhenQuiet = true
        settings.finishWhenQuietWait = 5
        settings.soundsEnabled = true
        await coordinator.prepareModelAndWait()
        await coordinator.startAppDictation(contextBefore: "")
        XCTAssertTrue(coordinator.activity.isRecording)
        AudioHardwareQueue.sync {} // The queued player has returned its actual start and duration.
        let cue = try XCTUnwrap(coordinator.startCueWindow)
        let start = cue.lowerBound
        XCTAssertGreaterThan(cue.upperBound - start, 0.1)
        for step in 0..<95 {
            // Simulate three mic readings of the opening cue, then silence. Keep the clock
            // below the stop threshold so the countdown itself proves whether the cue armed it.
            coordinator.watchForQuiet(step < 3 ? 0.9 : 0, now: start + Double(step) * 0.05)
        }
        XCTAssertNil(coordinator.quietFinishIn)
        for step in 95..<185 {
            coordinator.watchForQuiet(step < 103 ? 0.9 : 0, now: start + Double(step) * 0.05)
        }
        XCTAssertNotNil(coordinator.quietFinishIn, "Later speech must still arm Finish when quiet")
    }

    func testHomeDictationFinishesOverANewFanAfterSpeech() async throws {
        settings.finishWhenQuiet = true
        settings.finishWhenQuietWait = 5
        engine.texts = ["Finished over the fan"]
        await coordinator.prepareModelAndWait()
        await coordinator.startAppDictation(contextBefore: "")
        XCTAssertTrue(coordinator.activity.isRecording)
        var scale = AdaptiveLevelScale()
        var now = 0.0
        func send(_ db: Float, samples: Int) {
            for _ in 0..<samples {
                coordinator.watchForQuiet(scale.map(decibels: db, elapsed: 0.05), now: now)
                now += 0.05
            }
        }
        send(-50, samples: 80)
        send(-18, samples: 15)
        send(-32, samples: 75)
        XCTAssertNotNil(coordinator.quietFinishIn)
        XCTAssertTrue(coordinator.activity.isRecording)
        send(-32, samples: 35)
        try await waitFor("five seconds of fan finishes Home dictation") { !coordinator.activity.isBusy }
        XCTAssertEqual(coordinator.lastResult?.text, "Finished over the fan")
    }

    func testQuietMeterIgnoresEveryNoteWaitAndStillFinishesDictation() async throws {
        settings.finishWhenQuiet = true
        await coordinator.prepareModelAndWait()
        engine.texts = ["Thinking note", "Regular dictation"]
        await coordinator.dictateNote()
        for wait in SilenceFinish.waitChoices {
            settings.finishWhenQuietWait = wait
            for step in 0..<850 {
                coordinator.watchForQuiet(step < 40 ? 0.9 : 0,
                                          now: Double(step) * 0.05)
            }
            await Task.yield()
            XCTAssertTrue(coordinator.activity.isRecording, "Note ended at wait \(wait)")
            XCTAssertNil(coordinator.quietUntil)
            XCTAssertNil(coordinator.quietFinishIn)
        }
        await coordinator.stopDictation(reason: "noteCard")
        settings.finishWhenQuietWait = 3
        await coordinator.startAppDictation(contextBefore: "")
        for step in 0..<200 {
            coordinator.watchForQuiet(step < 40 ? 0.9 : 0, now: Double(step) * 0.05)
        }
        try await waitFor("ordinary dictation finishes", timeout: .seconds(8)) {
            !coordinator.activity.isBusy
        }
        XCTAssertFalse(coordinator.activity.isRecording)
    }

    /// Home's hero under the card names the note and counts its words; the clock and
    /// "Listening" belong to the card alone.
    func testHomesHeroCountsTheNotesWordsInsteadOfRepeatingTheCard() {
        XCTAssertEqual(HomeView.noteDetail(liveTranscript: ""), "Your words appear here as you talk")
        XCTAssertEqual(HomeView.noteDetail(liveTranscript: "  "), "Your words appear here as you talk")
        XCTAssertEqual(HomeView.noteDetail(liveTranscript: "Milk"), "1 word so far")
        XCTAssertEqual(HomeView.noteDetail(liveTranscript: "Pick up\noat milk"), "4 words so far")
    }

    func testARefusedBackgroundPressKeepsItsReasonForTheNextOpen() {
        coordinator.pressFindsZoneInFront = { false }
        XCTAssertTrue(coordinator.notePressFailed("Unlock your iPhone, then press again."), "The background press needs a notice")
        XCTAssertEqual(coordinator.noteOutcome, .failed("Unlock your iPhone, then press again."))
        XCTAssertEqual(coordinator.activity, .failed("Unlock your iPhone, then press again."))
    }

    func testBackgroundRefusalRemainsOnHomeAfterTheCardFolds() async throws {
        coordinator.pressFindsZoneInFront = { false }
        coordinator.notePressFailed("Zone's microphone did not start. Press again.")
        try await waitFor("error card folds", timeout: .seconds(13)) { coordinator.noteOutcome == nil }
        XCTAssertEqual(coordinator.activity, .failed("Zone's microphone did not start. Press again."))
    }

    func testARefusedPressInFrontShowsTheReasonWithoutANotification() {
        coordinator.pressFindsZoneInFront = { true }
        XCTAssertFalse(coordinator.notePressFailed("Turn on Live Activities."), "Already on screen")
        XCTAssertEqual(coordinator.noteOutcome, .failed("Turn on Live Activities."))
        XCTAssertEqual(coordinator.activity, .failed("Turn on Live Activities."))
    }

    func testARefusedPressCannotReplaceAnOngoingNoteWithAnError() async {
        await coordinator.prepareModelAndWait()
        await coordinator.dictateNote()
        coordinator.pressFindsZoneInFront = { false }
        XCTAssertFalse(coordinator.notePressFailed("Another press failed."), "A note is recording")
        XCTAssertTrue(coordinator.activity.isRecording)
        XCTAssertNil(coordinator.noteOutcome)
    }

    func testARefusalBeforeTheAppGraphExistsIsShownOnceItArrives() async {
        DictationCoordinator.shortcutCoordinator = nil
        defer { DictationCoordinator.shortcutCoordinator = coordinator }
        var notices: [String] = []
        await ZoneIntentHost.noteFailed("Unlock your iPhone, then press again.", notify: { notices.append($0) })
        XCTAssertEqual(notices, ["Unlock your iPhone, then press again."])
        DictationCoordinator.shortcutCoordinator = coordinator
        coordinator.pressFindsZoneInFront = { true }
        ZoneIntentHost.restoreNoteFailure()
        XCTAssertEqual(coordinator.activity, .failed("Unlock your iPhone, then press again."))
        XCTAssertEqual(coordinator.noteOutcome, .failed("Unlock your iPhone, then press again."))
        coordinator.dismissNoteOutcome()
        ZoneIntentHost.restoreNoteFailure()
        XCTAssertNil(coordinator.noteOutcome, "A consumed refusal cannot replay")
    }

    // MARK: A failed press outlives the process

    /// Zone after iOS ended its process: a new coordinator over the same preferences, the way
    /// AppGraph builds one, with Home not yet on screen.
    private func relaunchedZone(at now: Date? = nil) -> DictationCoordinator {
        let zone = DictationCoordinator(settings: settings, store: UserDefaultsSharedStore(suiteName: suite),
                                        engine: NoteFlowSpeechEngine(),
                                        reviews: ReviewPrompter(store: ReviewPromptStore(suiteName: suite), appVersion: "test"),
                                        noteFailureRecord: failureRecord,
                                        requestSessionPermission: { true })
        if let now { zone.noteClock = { now } }
        relaunched.append(zone)
        return zone
    }

    /// The review finding: with notifications denied, Home was the only receipt, and it lived
    /// only in the process iOS evicted.
    func testABackgroundRefusalIsOnHomeAfterIOSEndsZone() {
        let pressedAt = Date(timeIntervalSince1970: 1_800_000_000)
        coordinator.noteClock = { pressedAt }
        coordinator.pressFindsZoneInFront = { false }
        let refusal = "Zone's microphone did not start. Press again."
        XCTAssertTrue(coordinator.notePressFailed(refusal))
        XCTAssertEqual(failureRecord.current(now: pressedAt), .init(message: refusal, at: pressedAt))

        let zone = relaunchedZone(at: pressedAt.addingTimeInterval(3 * 60 * 60))
        XCTAssertEqual(zone.activity, .idle, "Not restored in the background, where no one sees Home")
        zone.scenePhaseChanged(.active)
        XCTAssertEqual(zone.activity, coordinator.activity, "Home after the relaunch says what it said before")
        XCTAssertEqual(zone.activity, .failed(refusal))
        XCTAssertNil(zone.noteOutcome, "The card belonged to the press; only Home comes back")
        XCTAssertEqual(failureRecord.current(now: pressedAt.addingTimeInterval(3 * 60 * 60))?.at, pressedAt,
                       "Restoring keeps the press's time, so a refusal cannot live forever")

        // Evicted again before anyone dismissed it: still there.
        let again = relaunchedZone(at: pressedAt.addingTimeInterval(4 * 60 * 60))
        again.scenePhaseChanged(.active)
        XCTAssertEqual(again.activity, .failed(refusal))

        again.dismissNotice()
        XCTAssertNil(failureRecord.current(now: pressedAt.addingTimeInterval(4 * 60 * 60)))
        let afterDismiss = relaunchedZone(at: pressedAt.addingTimeInterval(4 * 60 * 60))
        afterDismiss.scenePhaseChanged(.active)
        XCTAssertEqual(afterDismiss.activity, .idle, "A dismissed refusal never comes back")
    }

    func testASavedRefusalOlderThanItsLifetimeIsDropped() {
        let pressedAt = Date(timeIntervalSince1970: 1_800_000_000)
        coordinator.noteClock = { pressedAt }
        coordinator.pressFindsZoneInFront = { false }
        coordinator.notePressFailed("Unlock your iPhone, then press again.")
        let later = pressedAt.addingTimeInterval(NoteStartFailureRecord.lifetime + 1)
        let zone = relaunchedZone(at: later)
        zone.scenePhaseChanged(.active)
        XCTAssertEqual(zone.activity, .idle)
        XCTAssertNil(UserDefaults(suiteName: suite)!.object(forKey: NoteStartFailureRecord.key), "Expired records are removed")
    }

    func testDismissingTheNoteCardForgetsTheSavedRefusal() {
        coordinator.pressFindsZoneInFront = { true }
        coordinator.notePressFailed("Turn on Live Activities.")
        coordinator.dismissNoteOutcome()
        let zone = relaunchedZone()
        zone.scenePhaseChanged(.active)
        XCTAssertEqual(zone.activity, .idle)
    }

    func testASuccessfulNoteForgetsTheSavedRefusal() async throws {
        coordinator.pressFindsZoneInFront = { false }
        coordinator.notePressFailed("Zone's microphone did not start. Press again.")
        _ = try await saveOneNote("The second press worked.")
        XCTAssertNil(failureRecord.current(now: Date()))
        let zone = relaunchedZone()
        zone.scenePhaseChanged(.active)
        XCTAssertEqual(zone.activity, .idle, "A note that recorded is never followed by its old refusal")
    }

    /// Something newer happened in the relaunched process before Home came up (a keyboard
    /// dictation, another press): the old refusal is stale, as it would be in the old process.
    func testNewerActivityBeforeHomeOpensForgetsTheSavedRefusal() async {
        coordinator.pressFindsZoneInFront = { false }
        coordinator.notePressFailed("Zone's microphone did not start. Press again.")
        let zone = relaunchedZone()
        zone.pressFindsZoneInFront = { false }
        zone.notePressFailed("Unlock your iPhone, then press again.")
        zone.scenePhaseChanged(.active)
        XCTAssertEqual(zone.activity, .failed("Unlock your iPhone, then press again."))
        XCTAssertEqual(failureRecord.current(now: Date())?.message, "Unlock your iPhone, then press again.")
        zone.cancelDictation()
        XCTAssertNil(failureRecord.current(now: Date()), "Whatever clears Home clears the record")
    }

    /// Before the first unlock nothing is read or written: the refusal waits in memory. Once the
    /// graph exists it is saved like any other, so a later eviction keeps it.
    func testARefusalBeforeTheGraphIsSavedOnlyOnceTheGraphExists() async {
        let standardBefore = UserDefaults.standard.object(forKey: NoteStartFailureRecord.key) as? NSDictionary
        DictationCoordinator.shortcutCoordinator = nil
        await ZoneIntentHost.noteFailed("Unlock your iPhone, then press again.", notify: { _ in })
        XCTAssertNil(failureRecord.current(now: Date()), "No coordinator, no preferences")
        XCTAssertEqual(UserDefaults.standard.object(forKey: NoteStartFailureRecord.key) as? NSDictionary, standardBefore)
        DictationCoordinator.shortcutCoordinator = coordinator
        coordinator.pressFindsZoneInFront = { false }
        ZoneIntentHost.restoreNoteFailure()
        XCTAssertEqual(failureRecord.current(now: Date())?.message, "Unlock your iPhone, then press again.")
        let zone = relaunchedZone()
        zone.scenePhaseChanged(.active)
        XCTAssertEqual(zone.activity, .failed("Unlock your iPhone, then press again."))
    }

    func testTheRecordKeepsOnlyAShortReasonAndItsTime() throws {
        let defaults = UserDefaults(suiteName: suite)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        failureRecord.save("Unlock your iPhone, then press again.", at: now)
        let stored = try XCTUnwrap(defaults.dictionary(forKey: NoteStartFailureRecord.key))
        XCTAssertEqual(Set(stored.keys), ["message", "at"])
        let detail = "The synthetic file Example Notes.txt could not be opened."
        failureRecord.save(detail, at: now)
        XCTAssertEqual(failureRecord.current(now: now)?.message, "Zone could not start recording. Open Zone, then press again.")
        defaults.set(["message": detail, "at": now.timeIntervalSince1970], forKey: NoteStartFailureRecord.key)
        XCTAssertNil(failureRecord.current(now: now))
        failureRecord.save(String(repeating: "a", count: NoteStartFailureRecord.maxLength + 1), at: now)
        XCTAssertNil(defaults.object(forKey: NoteStartFailureRecord.key), "Not a refusal; not kept")
        failureRecord.save("   ", at: now)
        XCTAssertNil(failureRecord.current(now: now))
        defaults.set("garbage", forKey: NoteStartFailureRecord.key)
        XCTAssertNil(failureRecord.current(now: now))
        XCTAssertNil(defaults.object(forKey: NoteStartFailureRecord.key), "Unreadable records are removed")
        failureRecord.save("Press again.", at: now.addingTimeInterval(NoteStartFailureRecord.clockSkew + 60))
        XCTAssertNil(failureRecord.current(now: now), "Far in the future is a broken clock, not a fresh press")
    }

    func testFailureReportingWaitsForTheNotificationReceipt() async throws {
        DictationCoordinator.shortcutCoordinator = nil
        defer { DictationCoordinator.shortcutCoordinator = coordinator }
        let receipt = NoteFlowGate(open: false)
        var entered = false
        var returned = false
        let report = Task { @MainActor in
            await ZoneIntentHost.noteFailed("Unlock your iPhone, then press again.", notify: { _ in
                entered = true
                await receipt.wait()
            })
            returned = true
        }
        try await waitFor("notification submission") { entered }
        XCTAssertFalse(returned, "iOS can suspend Zone as soon as the intent returns")
        await receipt.open()
        await report.value
        XCTAssertTrue(returned)
        DictationCoordinator.shortcutCoordinator = coordinator
        coordinator.pressFindsZoneInFront = { true }
        ZoneIntentHost.restoreNoteFailure()
    }

    // MARK: Helpers

    private func saveOneNote(_ text: String) async throws -> NotePage {
        await coordinator.prepareModelAndWait()
        engine.texts = [text]
        await coordinator.dictateNote()
        guard case .recording = coordinator.noteCard else {
            XCTFail("No recording: \(coordinator.activity)")
            throw NoteFlowFailure.failed
        }
        await coordinator.stopDictation(reason: "noteCard")
        return try XCTUnwrap(coordinator.notePage)
    }
}

private enum NoteFlowFailure: Error { case failed }

/// Speaks the next script line for each note.
private final class NoteFlowSpeechEngine: SpeechEngine {
    let kind: EngineKind = .fluidMiniCPU
    var isReady = true
    var texts: [String] = ["A note."]
    var starts = 0
    var startFails = false
    var finishFails = false
    var finishGate: NoteFlowGate?
    func assetsPresent() -> Bool { true }
    func bytesOnDisk() -> Int64 { 0 }
    func removeAssets() throws {}
    func downloadAssets(progress: @escaping @Sendable (Double, String) -> Void) async throws {}
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {}
    func setContextHints(_ text: String) {}
    func beginUtterance() throws -> UtteranceSession {
        if startFails { throw NoteFlowFailure.failed }
        let text = texts.isEmpty ? "" : texts[min(starts, texts.count - 1)]
        starts += 1
        return NoteFlowUtterance(text: text, fails: finishFails, gate: finishGate)
    }
    func unload() {}
}

private final class NoteFlowUtterance: UtteranceSession {
    let textSoFar: String
    let fails: Bool
    let gate: NoteFlowGate?
    var audioSeconds: Double { 0 }
    var failure: Error? { nil }
    // This scripted session consumes each buffer immediately and has room for the next.
    var availableAudioSamples: Int { .max }
    init(text: String, fails: Bool, gate: NoteFlowGate?) { textSoFar = text; self.fails = fails; self.gate = gate }
    func feed(_ samples: [Float]) {}
    func finish() async throws -> String {
        await gate?.wait()
        if fails { throw NoteFlowFailure.failed }
        return textSoFar
    }
    func cancel() {}
}

/// Holds whoever waits until it is opened. Closing it again holds the next waiters.
private actor NoteFlowGate {
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(open: Bool) { isOpen = open }
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
    func close() { isOpen = false }
}
