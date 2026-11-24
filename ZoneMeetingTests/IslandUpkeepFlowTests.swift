// by zayd/cold @ zayd.wtf

import ActivityKit
import AVFoundation
import XCTest
import ZoneCore
@testable import Zone

/// Keeping Zone's card in the Dynamic Island for as long as standby lasts, through the
/// production coordinator and ActivityKit on the simulator. iOS's rules are modelled in
/// `beforeRequest`: a new card is refused in the background, except inside a press.
@MainActor
final class IslandUpkeepFlowTests: XCTestCase {
    private var coordinator: DictationCoordinator!
    private var indicator: RecordingLiveActivity!
    private var engine: IslandTestEngine!
    private var settings: AppSettings!
    private var suite: String!
    private var notesURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent(suite + ".notes.json") }
    private var requests = 0
    private var inBackground = false
    private var pressing = false
    private var now = Date()
    private var posted: [Bool] = []
    private var withdrawn = 0
    private var clearedNotices = 0

    override func setUp() async throws {
        suite = "island-upkeep-" + UUID().uuidString
        let store = UserDefaultsSharedStore(suiteName: suite)
        settings = AppSettings(defaults: UserDefaults(suiteName: suite)!, store: store)
        settings.soundsEnabled = false
        settings.startsSessionOnOpen = false
        settings.islandWhileReady = true
        engine = IslandTestEngine()
        indicator = RecordingLiveActivity(beforeRequest: { [unowned self] in
            requests += 1
            if inBackground, !pressing { throw RecordingLiveActivity.Failure.foregroundRequired }
        })
        indicator.clock = { [unowned self] in now }
        coordinator = DictationCoordinator(settings: settings, store: store, engine: engine,
            reviews: ReviewPrompter(store: ReviewPromptStore(suiteName: suite), appVersion: "test"),
            cardStopNotice: RecordingCardStopNotice(defaults: UserDefaults(suiteName: suite)!),
            notes: NotesStore(url: notesURL), requestSessionPermission: { true }, recordingLiveActivity: indicator)
        coordinator.postIslandLostNotice = { [unowned self] in posted.append($0) }
        coordinator.withdrawIslandLostNotice = { [unowned self] in withdrawn += 1 }
        coordinator.postRecordingCardStop = { _ in }
        coordinator.postClearedCardNotice = { [unowned self] in clearedNotices += 1 }
        await coordinator.prepareModelAndWait()
        try await coordinator.armSession()
        // On screen, as when the person turned Zone on: the card is made here.
        coordinator.scenePhaseChanged(.active)
        XCTAssertTrue(indicator.showsStandby, "Standby owns the island")
    }

    override func tearDown() async throws {
        coordinator.endSession(reason: .user)
        coordinator = nil
        for activity in Activity<RecordingActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        try? FileManager.default.removeItem(at: notesURL)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    private func goToBackground() {
        inBackground = true
        coordinator.scenePhaseChanged(.background)
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool, seconds: Double = 3) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// iOS ending the card itself, as its eight-hour limit does: ended, still on the Lock Screen.
    private func iOSEndsTheCard() async throws {
        for activity in Activity<RecordingActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .default)
        }
        try await waitUntil(indicator.cardID == nil)
        XCTAssertFalse(indicator.isActive, "Zone sees its card go")
    }

    private func postInterruption(began: Bool, shouldResume: Bool = false) {
        var info: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: began
            ? AVAudioSession.InterruptionType.began.rawValue : AVAudioSession.InterruptionType.ended.rawValue]
        if !began, shouldResume { info[AVAudioSessionInterruptionOptionKey] = AVAudioSession.InterruptionOptions.shouldResume.rawValue }
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
                                        object: AVAudioSession.sharedInstance(), userInfo: info)
    }

    func testForegroundAndSettingsRefreshLeaveSilentPreviewInRecording() async throws {
        let preview = Task { try await coordinator.previewIsland() }
        try await waitUntil(indicator.isPreviewing)
        XCTAssertTrue(indicator.isPreviewing)
        coordinator.refreshIsland()
        goToBackground()
        XCTAssertTrue(indicator.showsRecording)
        try await waitUntil(Activity<RecordingActivityAttributes>.activities.contains { $0.content.state.phase == .recording })
        XCTAssertTrue(Activity<RecordingActivityAttributes>.activities.contains { $0.content.state.phase == .recording })
        let initial = try XCTUnwrap(indicator.latestState)
        XCTAssertGreaterThan(initial.words ?? 0, 0)
        XCTAssertFalse((initial.levels ?? []).isEmpty)
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(indicator.latestState?.beat, initial.beat, "Let SpringBoard render the first full recording frame")
        preview.cancel()
        _ = await preview.result
        XCTAssertFalse(indicator.isPreviewing)
        XCTAssertTrue(indicator.showsStandby)
    }

    // MARK: Renewing

    /// The old rule replaced the card only after four hours, so Zone could leave it with four
    /// left. Now any card half an hour old is replaced wherever a card can be made.
    func testInFrontACardHalfAnHourOldIsReplaced() {
        let made = requests
        now = now.addingTimeInterval(29 * 60)
        XCTAssertFalse(indicator.renewStandbyIfAging(), "Zone just made it")
        now = now.addingTimeInterval(60)
        XCTAssertTrue(indicator.renewStandbyIfAging())
        XCTAssertEqual(requests, made + 1)
        XCTAssertTrue(indicator.showsStandby)
        XCTAssertEqual(indicator.age(), 0, "The eight hours start over")
    }

    /// Away from Zone, the Action Button (or any press) is the one moment iOS makes a card from
    /// the background: an aging standby card starts its eight hours over there.
    func testAPressInTheBackgroundReplacesAnAgingCard() {
        goToBackground()
        now = now.addingTimeInterval(7 * 3600)
        let made = requests
        coordinator.keepIslandDuringPress("test", restoreMissing: false)
        XCTAssertEqual(requests, made + 1, "Refused without a press, as iOS does")
        XCTAssertGreaterThan(indicator.age(), 3600, "No card from the background outside a press")
        pressing = true
        coordinator.keepIslandDuringPress("test", restoreMissing: false)
        XCTAssertTrue(indicator.showsStandby)
        XCTAssertEqual(indicator.age(), 0)
    }

    /// A refused renewal keeps the card that is up: the island never loses a working card to a
    /// failed attempt at a newer one.
    func testARefusedRenewalKeepsTheCard() {
        goToBackground()
        now = now.addingTimeInterval(2 * 3600)
        XCTAssertFalse(indicator.renewStandbyIfAging())
        XCTAssertTrue(indicator.showsStandby)
    }

    // MARK: The relay (iOS 26 scheduled start)

    /// While standby keeps its card, a relay waits for it: scheduled, not yet showing.
    func testARelayWaitsBehindTheStandbyCard() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Scheduled starts are iOS 26") }
        let relay = try XCTUnwrap(indicator.relay, "No relay behind the standby card")
        XCTAssertEqual(relay.activityState, .pending)
    }

    /// Zayd's journal, November 9 to 18: five standby stretches of 8 to 13 hours without opening
    /// Zone, each ending with iOS's orange dot. The relay starts two minutes before the card's
    /// limit, even with Zone in the background, and takes the island over: no notification, a
    /// fresh eight hours, and the next relay asked for.
    func testTheRelayTakesTheIslandOverBeforeTheLimitInTheBackground() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Scheduled starts are iOS 26") }
        goToBackground()
        let old = try XCTUnwrap(indicator.cardID)
        // The card is 8 hours old less 2 minutes and 15 seconds: its relay starts in about 15 s.
        now = now.addingTimeInterval(IslandUpkeep.systemLimit - RecordingLiveActivity.relayLead - 15)
        indicator.restartRelay()
        let relayID = try XCTUnwrap(indicator.relay?.id)
        try await waitUntil(indicator.cardID == relayID, seconds: 40)
        XCTAssertEqual(indicator.cardID, relayID, "The relay is Zone's card now")
        XCTAssertTrue(indicator.showsStandby)
        XCTAssertEqual(indicator.age(), 0, "with all eight hours ahead of it")
        try await waitUntil(Activity<RecordingActivityAttributes>.activities.first { $0.id == old } == nil
                            || Activity<RecordingActivityAttributes>.activities.first { $0.id == old }?.activityState != .active)
        XCTAssertNotEqual(Activity<RecordingActivityAttributes>.activities.first { $0.id == old }?.activityState, .active,
                          "The old card ends")
        XCTAssertEqual(posted, [], "Nothing to tell: the island never left")
        XCTAssertTrue(coordinator.isArmed)
    }

    func testTurningZoneOffCancelsTheRelay() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Scheduled starts are iOS 26") }
        let relay = try XCTUnwrap(indicator.relay)
        coordinator.endSession(reason: .user)
        XCTAssertNil(indicator.relay)
        try await waitUntil(relay.activityState != .pending)
        XCTAssertNotEqual(relay.activityState, .pending, "No relay may start for a Zone that is off")
    }

    /// The person cleared the card: no relay brings it back over that choice.
    func testClearingTheCardCancelsTheRelay() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Scheduled starts are iOS 26") }
        goToBackground()
        let relay = try XCTUnwrap(indicator.relay)
        let card = try XCTUnwrap(Activity<RecordingActivityAttributes>.activities.first { $0.id == indicator.cardID })
        await card.end(nil, dismissalPolicy: .immediate)
        try await waitUntil(indicator.relay == nil)
        XCTAssertNil(indicator.relay)
        try await waitUntil(relay.activityState != .pending)
        XCTAssertNotEqual(relay.activityState, .pending)
    }

    // MARK: Bringing it back

    /// Bring back Zone's island (Control Center, the Action Button, an automation): with
    /// standby on and its card gone, the press makes it again without opening Zone.
    func testBringBackZonesIslandMakesTheMissingCardInsideThePress() async throws {
        goToBackground()
        try await iOSEndsTheCard()
        XCTAssertEqual(posted.count, 1)
        pressing = true
        _ = try await ShowIslandIntent().perform()
        XCTAssertTrue(indicator.showsStandby, "The press brings the card back")
        XCTAssertTrue(coordinator.isArmed, "and leaves the microphone as it was")
        XCTAssertEqual(withdrawn, 1, "The notification describes nothing any more")
    }

    /// With Zone off the action does nothing at all: it never turns the microphone on.
    func testBringBackZonesIslandNeverTurnsZoneOn() async throws {
        coordinator.endSession(reason: .user)
        XCTAssertFalse(indicator.isActive)
        let made = requests
        pressing = true
        _ = try await ShowIslandIntent().perform()
        XCTAssertFalse(coordinator.isArmed)
        XCTAssertFalse(indicator.isActive)
        XCTAssertEqual(requests, made)
    }

    // MARK: Telling the person

    /// iOS ends the card in the background with the microphone still on: one notification,
    /// withdrawn when Zone in front makes the card again.
    func testACardEndedInTheBackgroundIsToldOnceAndWithdrawnWhenBack() async throws {
        goToBackground()
        try await iOSEndsTheCard()
        XCTAssertEqual(posted, [false], "One notification; not at the eight-hour limit")
        XCTAssertTrue(coordinator.isArmed, "The card going does not turn standby off")
        coordinator.refreshIsland()
        XCTAssertEqual(posted.count, 1, "Once per loss")
        inBackground = false
        coordinator.scenePhaseChanged(.active)
        XCTAssertTrue(indicator.showsStandby, "In front the card is made again")
        XCTAssertEqual(withdrawn, 1)
    }

    /// The notification says when it was iOS's eight hours.
    func testTheEightHourLimitIsNamed() async throws {
        goToBackground()
        now = now.addingTimeInterval(8 * 3600)
        try await iOSEndsTheCard()
        XCTAssertEqual(posted, [true])
    }

    /// Turn Zone off (from the notification, or anywhere) withdraws it.
    func testTurningZoneOffWithdrawsTheNotification() async throws {
        goToBackground()
        try await iOSEndsTheCard()
        try coordinator.turnStandbyOffFromControl()
        XCTAssertFalse(coordinator.isArmed)
        XCTAssertEqual(withdrawn, 1)
    }

    func testTheSettingOffSendsNothing() async throws {
        settings.islandLostNotice = false
        goToBackground()
        try await iOSEndsTheCard()
        XCTAssertEqual(posted, [])
    }

    /// The person clears the card, which removes it at once (`dismissed`).
    private func personClearsTheCard() async throws {
        for activity in Activity<RecordingActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        try await waitUntil(indicator.cardID == nil)
    }

    func testOnlyAnUnownedCardIsMissingWhileDismissalAwaitsItsReason() {
        typealias Presence = RecordingLiveActivity.CardPresence
        XCTAssertEqual(Presence(nil), .missing)
        XCTAssertEqual(Presence(.active), .visible)
        XCTAssertEqual(Presence(.stale), .visible)
        XCTAssertEqual(Presence(.ended), .awaitingUpdate)
        XCTAssertEqual(Presence(.dismissed), .awaitingUpdate)
        if #available(iOS 26.0, *) {
            XCTAssertEqual(Presence(.pending), .awaitingUpdate)
        }
    }

    /// Clearing the card from the Lock Screen turns Zone off (Zayd, 2026-11-20): the microphone
    /// is released, so iOS draws no orange indicator, and "Zone is off" says how to get it
    /// back. Before, standby stayed on behind the orange pill until Zone was opened.
    func testClearingTheCardTurnsZoneOffAndSaysSo() async throws {
        goToBackground()
        try await personClearsTheCard()
        try await waitUntil(!coordinator.isArmed)
        XCTAssertFalse(coordinator.isArmed, "Clearing the card is turning Zone off")
        XCTAssertEqual(clearedNotices, 1, "Zone is off, said once")
        XCTAssertEqual(posted, [], "Not the island-ended notification: the microphone is off too")
        // Opening Zone does not put a card back for a Zone that is off.
        inBackground = false
        coordinator.scenePhaseChanged(.active)
        XCTAssertFalse(indicator.isActive)
        XCTAssertFalse(coordinator.isArmed, "Turn on when Zone opens is off in these tests")
    }

    /// With Turn on when Zone opens, opening Zone (the notification's tap) turns it back on:
    /// a cleared card is not Turn off, which keeps Zone off until the person turns it on.
    func testOpeningZoneAfterAClearedCardTurnsItOnAgainWhenThatSettingIsOn() async throws {
        settings.startsSessionOnOpen = true
        settings.hasCompletedOnboarding = true
        goToBackground()
        try await personClearsTheCard()
        try await waitUntil(!coordinator.isArmed)
        XCTAssertFalse(coordinator.isArmed)
        inBackground = false
        coordinator.scenePhaseChanged(.active)
        try await waitUntil(coordinator.isArmed)
        XCTAssertTrue(coordinator.isArmed, "Opening Zone turned it back on")
        try await waitUntil(indicator.showsStandby)
        XCTAssertTrue(indicator.showsStandby)
    }

    /// A card cleared while a call has the microphone: Zone turns off when the call hands the
    /// microphone back, not before, and standby never waits there under iOS's orange indicator.
    func testACardClearedDuringACallTurnsZoneOffWhenTheCallEnds() async throws {
        goToBackground()
        postInterruption(began: true)
        try await waitUntil(!coordinator.isArmed)
        try await personClearsTheCard()
        XCTAssertEqual(clearedNotices, 0, "The microphone is away: nothing to turn off yet")
        postInterruption(began: false, shouldResume: true)
        try await waitUntil(clearedNotices == 1)
        XCTAssertEqual(clearedNotices, 1)
        XCTAssertFalse(coordinator.isArmed, "Standby did not stay on without its card")
        XCTAssertEqual(posted, [])
    }

    /// iOS ending the card at its limit is not the person's doing: Zone stays on and says the
    /// island ended, as before.
    func testACardEndedByiOSLeavesZoneOn() async throws {
        goToBackground()
        try await iOSEndsTheCard()
        try await waitUntil(posted.count == 1)
        XCTAssertTrue(coordinator.isArmed)
        XCTAssertEqual(clearedNotices, 0)
        XCTAssertEqual(posted.count, 1)
    }

    private var isRecording: Bool {
        if case .recording = coordinator.activity { return true }
        return false
    }

    /// iOS's eight-hour limit counts from when the card was made, which can be hours of standby
    /// before the note began. It took the card and the note with it; now the note goes on and
    /// gets its card back when Zone is next in front.
    func testANoteOutlivesIOSTakingItsCard() async throws {
        await coordinator.dictateNote()
        try await waitUntil(isRecording)
        XCTAssertTrue(isRecording)
        XCTAssertTrue(indicator.showsRecording)
        goToBackground()
        try await iOSEndsTheCard()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(isRecording, "iOS taking the card does not end the note")
        XCTAssertFalse(indicator.isActive, "No card can be made in the background")
        inBackground = false
        coordinator.scenePhaseChanged(.active)
        XCTAssertTrue(indicator.showsRecording, "In front, the recording has its card again")
        XCTAssertTrue(isRecording)
        await coordinator.stopDictation()
    }

    func testPressNoteIsSavedIfItsRequiredCardCannotReturn() async throws {
        engine.finalText = "Keep this meeting note."
        try await coordinator.runRecordingShortcut(noteMode: true, finishing: nil, trigger: .control)
        XCTAssertTrue(isRecording)
        try await waitUntil(engine.capturedSeconds > 0.1)
        XCTAssertGreaterThan(engine.capturedSeconds, 0.1)
        goToBackground()
        try await iOSEndsTheCard()
        try await waitUntil(coordinator.lastSavedNote != nil)
        XCTAssertFalse(isRecording)
        XCTAssertNotNil(coordinator.lastSavedNote)
    }

    func testIntentStopsAndKeepsAudioWhenTheSystemRefusesAReplacementCard() async throws {
        try await coordinator.runRecordingShortcut(noteMode: true, finishing: nil, trigger: .shortcut)
        guard case .recording(let id, _) = coordinator.activity else { return XCTFail("The intent must start") }
        try await waitUntil(engine.capturedSeconds > 0.1)
        XCTAssertGreaterThan(engine.capturedSeconds, 0.1)
        goToBackground()
        try await iOSEndsTheCard()
        try await waitUntil(!isRecording)
        XCTAssertFalse(isRecording)
        try await waitUntil(coordinator.audioRecoveryRecords.contains { $0.id == id && $0.audioBytes > 0 }, seconds: 10)
        let kept = try XCTUnwrap(coordinator.audioRecoveryRecords.first { $0.id == id })
        XCTAssertGreaterThan(kept.audioBytes, 0)
        let receipt = RecordingCardStopNotice(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(receipt.message, RecordingCardStopNotice.Outcome.saved.message)
        coordinator.scenePhaseChanged(.active)
        XCTAssertEqual(coordinator.recordingCardStopMessage, receipt.message)
        coordinator.dismissNotice()
        XCTAssertNil(receipt.message)
        coordinator.deleteAudioRecovery(id)
    }

    /// The person clearing a recording's card is still a stop, as it was.
    func testClearingARecordingsCardStillStopsIt() async throws {
        await coordinator.startAppDictation(contextBefore: nil)
        try await waitUntil(isRecording)
        XCTAssertTrue(isRecording)
        for activity in Activity<RecordingActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        try await waitUntil(!isRecording)
        XCTAssertFalse(isRecording)
    }

    /// The card ended while a call had the microphone: nothing is drawn as waiting, so nothing
    /// is said. When standby takes the microphone back with no card, it is.
    func testDuringACallItWaitsForTheMicrophoneToComeBack() async throws {
        goToBackground()
        postInterruption(began: true)
        try await waitUntil(!coordinator.isArmed)
        try await iOSEndsTheCard()
        XCTAssertEqual(posted, [], "The microphone is away: no orange dot yet")
        postInterruption(began: false, shouldResume: true)
        try await waitUntil(coordinator.isArmed && posted.count == 1)
        XCTAssertTrue(coordinator.isArmed)
        XCTAssertEqual(posted.count, 1, "Standby is back with no card of Zone's")
    }

    /// Zone stays in front past the threshold: the card it leaves behind is still fresh.
    func testStayingInFrontKeepsTheCardFresh() async throws {
        let made = requests
        now = now.addingTimeInterval(31 * 60)
        try await waitUntil(requests == made + 1, seconds: 4)
        XCTAssertEqual(requests, made + 1, "Renewed by the in-front check, without leaving Zone")
        XCTAssertTrue(indicator.showsStandby)
    }
}

/// Speech that is never listened to: these tests only keep the microphone waiting.
private final class IslandTestEngine: SpeechEngine {
    let kind: EngineKind = .fluidMiniCPU
    var isReady = true
    func assetsPresent() -> Bool { true }
    func bytesOnDisk() -> Int64 { 0 }
    func removeAssets() throws {}
    func downloadAssets(progress: @escaping @Sendable (Double, String) -> Void) async throws {}
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {}
    func setContextHints(_ text: String) {}
    var finalText = ""
    private var session: IslandTestUtterance?
    var capturedSeconds: Double { session?.audioSeconds ?? 0 }
    func beginUtterance() throws -> UtteranceSession {
        let utterance = IslandTestUtterance(finalText: finalText)
        session = utterance
        return utterance
    }
    func unload() {}
}

private final class IslandTestUtterance: UtteranceSession {
    let finalText: String
    private let samplesReceived = Locked(0)
    init(finalText: String) { self.finalText = finalText }
    var textSoFar: String { "" }
    var audioSeconds: Double { samplesReceived.withLock { Double($0) / 16_000 } }
    var failure: Error? { nil }
    var availableAudioSamples: Int { Int.max }
    func feed(_ samples: [Float]) { samplesReceived.withLock { $0 += samples.count } }
    func finish() async throws -> String { finalText }
    func cancel() {}
}
