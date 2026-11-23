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

    override func setUpWithError() throws {
        suite = "note-flow-" + UUID().uuidString
        let store = UserDefaultsSharedStore(suiteName: suite)
        settings = AppSettings(defaults: UserDefaults(suiteName: suite)!, store: store)
        settings.soundsEnabled = false
        settings.startsSessionOnOpen = false
        engine = NoteFlowSpeechEngine()
        permission = NoteFlowGate(open: true)
        let gate = permission!
        coordinator = DictationCoordinator(settings: settings, store: store, engine: engine,
                                           reviews: ReviewPrompter(store: ReviewPromptStore(suiteName: suite), appVersion: "test"),
                                           requestSessionPermission: { await gate.wait(); return true })
        notesBefore = Set(coordinator.notes.notes.map(\.id))
    }

    override func tearDown() async throws {
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
        coordinator.handle(url: ZoneContract.dictateURL(requestID: UUID()))
        XCTAssertNil(coordinator.notePage, "The page would stand in front of the keyboard's dictation screen")
        XCTAssertTrue(coordinator.showsDictationScreen)
        coordinator.dismissDictationScreen()
    }

    func testTappingTheLiveActivityKeepsAFreshPage() async throws {
        let page = try await saveOneNote("Opened from the island.")
        coordinator.handle(url: URL(string: "zone://recording")!)
        XCTAssertEqual(coordinator.notePage?.noteID, page.noteID)
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
    var availableAudioSamples: Int { 0 }
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
