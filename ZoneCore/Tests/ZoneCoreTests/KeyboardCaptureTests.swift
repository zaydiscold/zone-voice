// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class KeyboardCaptureTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func route(enabled: Bool = true, systemSupports: Bool = true, microphoneGranted: Bool = true,
                       speechAssetInstalled: Bool = true,
                       heartbeatAge: TimeInterval? = nil, failures: KeyboardCapture.Failures = .init()) -> KeyboardCapture.Route {
        KeyboardCapture.route(enabled: enabled, systemSupports: systemSupports, microphoneGranted: microphoneGranted,
                              speechAssetInstalled: speechAssetInstalled,
                              appHeartbeat: heartbeatAge.map { now.addingTimeInterval(-$0) }, failures: failures, now: now)
    }

    func testEraseRequestRemovesAFreshKeyboardRetry() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let retry = folder.appendingPathComponent(KeyboardCapture.retryName(UUID()))
        try Data([1]).write(to: retry)
        try KeyboardCapture.eraseRecordings(in: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retry.path))
    }

    func testOnByDefaultAndTheSwitchSendsEveryTapToTheApp() {
        XCTAssertTrue(KeyboardPreferences().dictatesInKeyboard)
        XCTAssertEqual(route(enabled: false), .app)
    }

    func testTheKeyboardRecordsOnlyWhenEverythingAllowsIt() {
        XCTAssertEqual(route(), .keyboard)
        XCTAssertEqual(route(systemSupports: false), .app)
        XCTAssertEqual(route(microphoneGranted: false), .app)
    }

    /// Recording here without Apple's speech asset would record, then lose the words. Until the
    /// app has found the asset installed, a tap opens Zone, which fetches it.
    func testNoSpeechAssetSendsTheTapToTheApp() {
        XCTAssertEqual(route(speechAssetInstalled: false), .app)
        XCTAssertEqual(route(speechAssetInstalled: true), .keyboard)
        XCTAssertFalse(InMemorySharedStore().keyboardSpeechReady, "unknown reads as not installed")
    }

    /// From anomalyco/hex #2045: its testers' 4 GB iPhones ended the keyboard as the capture
    /// started. Short of room, the tap opens Zone instead.
    func testShortOfMemoryTheTapGoesToTheApp() {
        let mb: UInt64 = 1_048_576
        XCTAssertTrue(KeyboardCapture.hasMemory(available: nil, pageLoaded: false), "no limit reported: the simulator")
        XCTAssertTrue(KeyboardCapture.hasMemory(available: 177 * mb, pageLoaded: false), "Zayd's iPhone 15 Pro, 2026-11-20")
        XCTAssertTrue(KeyboardCapture.hasMemory(available: 32 * mb, pageLoaded: false))
        XCTAssertFalse(KeyboardCapture.hasMemory(available: 31 * mb, pageLoaded: false))
        XCTAssertTrue(KeyboardCapture.hasMemory(available: 24 * mb, pageLoaded: true), "the page is already paid for")
        XCTAssertFalse(KeyboardCapture.hasMemory(available: 23 * mb, pageLoaded: true))
        XCTAssertEqual(KeyboardCapture.route(enabled: true, systemSupports: true, microphoneGranted: true, speechAssetInstalled: true,
                                             hasMemory: false, appHeartbeat: nil, failures: .init(), now: now), .app)
        XCTAssertEqual(KeyboardCapture.route(enabled: true, systemSupports: true, microphoneGranted: true, speechAssetInstalled: true,
                                             hasMemory: true, appHeartbeat: nil, failures: .init(), now: now), .keyboard)
    }

    /// From anomalyco/hex #2071: a keyboard process opened before the microphone was allowed
    /// keeps reading "not asked". The app's published reading is enough.
    func testTheAppsMicrophoneReadingStandsInForAStaleKeyboardReading() {
        let grant = MicrophoneReading(granted: true, at: now, install: "one")
        var observation = KeyboardCapture.PermissionObservation()
        XCTAssertFalse(observation.allowed(keyboard: false, app: nil))
        XCTAssertTrue(observation.allowed(keyboard: false, app: grant))
        XCTAssertTrue(observation.allowed(keyboard: nil, app: grant))
        XCTAssertFalse(observation.allowed(keyboard: false, app: grant))
        let laterChange = MicrophoneReading(granted: true, at: now.addingTimeInterval(-3600), install: "one")
        XCTAssertTrue(observation.allowed(keyboard: false, app: laterChange))
        let suite = "KeyboardCaptureTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let app = UserDefaultsSharedStore(suiteName: suite)
        let keyboard = UserDefaultsSharedStore(suiteName: suite)
        XCTAssertFalse(keyboard.appMicrophoneGranted, "unknown reads as not granted")
        app.appMicrophoneGranted = true
        XCTAssertTrue(keyboard.appMicrophoneGranted)
        app.appMicrophoneGranted = false
        XCTAssertFalse(keyboard.appMicrophoneGranted)
    }

    /// The page loads ahead of a tap only for someone who dictated in the keyboard lately, and
    /// only when a tap would record here.
    func testThePageLoadsAheadOnlyForSomeoneWhoDictatesHere() {
        let day: TimeInterval = 24 * 3600
        XCTAssertFalse(KeyboardCapture.preloads(route: .keyboard, lastDictatedHere: nil, now: now), "someone who only types")
        XCTAssertTrue(KeyboardCapture.preloads(route: .keyboard, lastDictatedHere: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(KeyboardCapture.preloads(route: .keyboard, lastDictatedHere: now.addingTimeInterval(-13 * day), now: now))
        XCTAssertFalse(KeyboardCapture.preloads(route: .keyboard, lastDictatedHere: now.addingTimeInterval(-15 * day), now: now))
        XCTAssertFalse(KeyboardCapture.preloads(route: .app, lastDictatedHere: now.addingTimeInterval(-60), now: now),
                       "Zone keeps the microphone ready, or the route is off")
        XCTAssertFalse(KeyboardCapture.preloads(route: .keyboard, lastDictatedHere: now.addingTimeInterval(60), now: now),
                       "a clock moved back")
    }

    /// History says which recognizer wrote a dictation the keyboard recorded by itself.
    func testHistoryNamesAppleSpeechOnlyForTheKeyboardsOwnRecordings() {
        XCTAssertEqual(KeyboardCapture.historyEngine(for: "dictation"), "appleDictation")
        XCTAssertEqual(KeyboardCapture.historyEngine(for: "speech"), "appleSpeech")
        XCTAssertEqual(KeyboardCapture.historyEngine(for: "zoneMini"), "zoneMini")
        XCTAssertNil(KeyboardCapture.historyNote(engine: KeyboardCapture.historyEngine(for: "scripted"), source: .keyboard))
        XCTAssertEqual(KeyboardCapture.historyNote(engine: "appleSpeech", source: .keyboard),
                       "Recorded in the keyboard with Apple's speech model.")
        XCTAssertNil(KeyboardCapture.historyNote(engine: "fluidMiniANE", source: .keyboard), "Zone recorded it")
        XCTAssertNil(KeyboardCapture.historyNote(engine: "appleSpeech", source: .app), "the Apple engine chosen in the app")
    }

    func testPartiallyDeletedModelLosesReadiness() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: directory) }
        try manager.createDirectory(at: directory.appendingPathComponent("JointDecisionv3.mlmodelc"), withIntermediateDirectories: true)
        for file in SharedMiniModel.files {
            let url = directory.appendingPathComponent(file.path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(file.bytes))
            try handle.close()
        }
        XCTAssertTrue(SharedMiniModel.filesPresent(in: directory))
        try manager.removeItem(at: directory.appendingPathComponent("Encoder.mlmodelc/weights/weight.bin"))
        XCTAssertFalse(SharedMiniModel.filesPresent(in: directory))
    }

    func testMicrophoneReservationBlocksAnIndependentOpenerUntilReleased() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let id = UUID()
        let keyboard = MicrophoneOwnership(file: file)
        var app = MicrophoneLease(at: file)
        XCTAssertNotNil(app)
        XCTAssertFalse(keyboard.reserveForKeyboard(recordingID: id, report: { _, code in XCTFail("Unexpected microphone lock error \(code)") }))
        app = nil
        XCTAssertTrue(keyboard.reserveForKeyboard(recordingID: id, report: { _, code in XCTFail("Unexpected microphone lock error \(code)") }))
        XCTAssertNil(MicrophoneLease(at: file))
        keyboard.keyboardStopped(recordingID: id)
        XCTAssertNotNil(MicrophoneLease(at: file))
    }

    func testUpgradeKeepsVerificationAndAnUnchangedPermissionKeepsItsOrder() throws {
        let suite = "upgrade-" + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(["revision": SharedMiniModel.revision], forKey: "verifiedMiniModel")
        let store = UserDefaultsSharedStore(suiteName: suite)
        XCTAssertNotNil(defaults.dictionary(forKey: "verifiedMiniModel"))
        store.appMicrophoneGranted = true
        let before = try XCTUnwrap(store.appMicrophoneReading)
        store.appMicrophoneGranted = true
        XCTAssertEqual(store.appMicrophoneReading?.at, before.at)
    }

    func testRestoreDiscardsDeviceReadingsAndLegacyModelVerification() {
        let suite = "restore-" + UUID().uuidString
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = UserDefaults(suiteName: suite)!
        let old = UserDefaultsSharedStore(suiteName: suite, installID: "first")
        old.keyboardSpeechReady = true
        old.appMicrophoneGranted = true
        defaults.set(["status": "complete and verified"], forKey: "verifiedMiniModel")
        let restored = UserDefaultsSharedStore(suiteName: suite, installID: "restored")
        XCTAssertFalse(restored.keyboardSpeechReady)
        XCTAssertFalse(restored.appMicrophoneGranted)
        XCTAssertNil(defaults.object(forKey: "verifiedMiniModel"))
    }

    func testTheSpeechAssetFlagTravelsThroughTheAppGroup() {
        let suite = "KeyboardCaptureTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let app = UserDefaultsSharedStore(suiteName: suite)
        let keyboard = UserDefaultsSharedStore(suiteName: suite)
        XCTAssertFalse(keyboard.keyboardSpeechReady)
        app.keyboardSpeechReady = true
        XCTAssertTrue(keyboard.keyboardSpeechReady)
        app.keyboardSpeechReady = false
        XCTAssertFalse(keyboard.keyboardSpeechReady)
    }

    func testRecognitionTimeGrowsWithTheRecordingLikeTheApps() {
        XCTAssertEqual(KeyboardCapture.recognitionLimit(audioSeconds: 0), 60)
        XCTAssertEqual(KeyboardCapture.recognitionLimit(audioSeconds: 100), 60)
        XCTAssertEqual(KeyboardCapture.recognitionLimit(audioSeconds: 240), 120)
        XCTAssertEqual(KeyboardCapture.recognitionLimit(audioSeconds: 3600), 300)
        XCTAssertEqual(KeyboardCapture.recognitionLimit(audioSeconds: .infinity), 60)
    }

    /// A muted track, or iOS closing the route with silence instead of an error, gives zeros.
    func testAnAllSilentRecordingIsAFailure() {
        XCTAssertTrue(KeyboardCapture.isSilent(peak: 0))
        XCTAssertFalse(KeyboardCapture.isSilent(peak: 0.00005))
        XCTAssertTrue(KeyboardCapture.isSilent(peak: .nan))
        XCTAssertFalse(KeyboardCapture.isSilent(peak: 0.0001))
        XCTAssertFalse(KeyboardCapture.isSilent(peak: 0.003), "a quiet room is about -50 dBFS")
    }

    func testARecordingStopsByItselfAtTheAppsLimits() {
        XCTAssertEqual(KeyboardCapture.maximumLength, DictationLimits.standard.maximumLength)
        XCTAssertEqual(KeyboardCapture.pauseLimit, InactivityPolicy.minimumPauseLimit)
        let start = now
        XCTAssertEqual(KeyboardCapture.limitDecision(now: start.addingTimeInterval(60), startedAt: start, pausedSince: nil), .keepRecording)
        XCTAssertEqual(KeyboardCapture.limitDecision(now: start.addingTimeInterval(7200), startedAt: start, pausedSince: nil), .reachedMaximum)
        XCTAssertEqual(KeyboardCapture.limitDecision(now: start.addingTimeInterval(400), startedAt: start,
                                                     pausedSince: start.addingTimeInterval(200)), .keepRecording)
        XCTAssertEqual(KeyboardCapture.limitDecision(now: start.addingTimeInterval(500), startedAt: start,
                                                     pausedSince: start.addingTimeInterval(200)), .pausedTooLong)
    }

    private func request(_ age: TimeInterval, generation: Int = 3) -> DictationRequest {
        DictationRequest(id: UUID(), generation: generation, createdAt: now.addingTimeInterval(-age), inputSession: "a", contextBefore: nil)
    }

    func testTheKeyboardsResultNeverReplacesANewerRequestOrResult() {
        let mine = request(30)
        XCTAssertTrue(KeyboardCapture.mayPublish(local: mine, storedRequest: nil, storedResult: nil))
        XCTAssertTrue(KeyboardCapture.mayPublish(local: mine, storedRequest: mine, storedResult: nil))
        XCTAssertTrue(KeyboardCapture.mayPublish(local: mine, storedRequest: request(60), storedResult: nil), "an older request goes")
        XCTAssertFalse(KeyboardCapture.mayPublish(local: mine, storedRequest: request(5), storedResult: nil))
        let newer = DictationResult(requestID: UUID(), generation: 4, text: "hi", audioSeconds: 1,
                                    createdAt: now.addingTimeInterval(-1), inputSession: nil)
        XCTAssertFalse(KeyboardCapture.mayPublish(local: mine, storedRequest: nil, storedResult: newer))
        let older = DictationResult(requestID: UUID(), generation: 1, text: "hi", audioSeconds: 1,
                                    createdAt: now.addingTimeInterval(-90), inputSession: nil)
        XCTAssertTrue(KeyboardCapture.mayPublish(local: mine, storedRequest: nil, storedResult: older))
    }

    /// Generations start over in each keyboard controller, so a cancel on another one can share
    /// this request's number. The keyboard's own result must not read as cancelled.
    func testTheKeyboardsResultIsNeverTakenForAnotherControllersCancel() {
        let mine = request(1, generation: 2)
        var ledger = InsertionLedger()
        ledger.droppedGeneration = 2
        let generation = KeyboardCapture.publishedGeneration(of: mine, ledger: ledger)
        XCTAssertEqual(generation, 3)
        let result = DictationResult(requestID: mine.id, generation: generation, text: "hello there", audioSeconds: 2,
                                     createdAt: now, inputSession: "a")
        XCTAssertEqual(InsertionDecider.decide(result: result, request: mine, ledger: ledger, currentInputSession: "a",
                                               ownsRequest: true, now: now), .insertNow)
        XCTAssertEqual(KeyboardCapture.publishedGeneration(of: request(1, generation: 9), ledger: ledger), 9)
    }



    /// A meeting, a note or a dictation in the app stamps the heartbeat every second or three.
    func testAnAppThatIsCapturingKeepsTheMicrophone() {
        XCTAssertEqual(route(heartbeatAge: 0), .app)
        XCTAssertEqual(route(heartbeatAge: 3), .app)
        XCTAssertEqual(route(heartbeatAge: 8), .app)
        XCTAssertEqual(route(heartbeatAge: 8.1), .keyboard)
        XCTAssertEqual(route(heartbeatAge: 86_400), .keyboard)
        // The clock moved back a little after the stamp: still a running app.
        XCTAssertEqual(route(heartbeatAge: -2), .app)
        XCTAssertEqual(route(heartbeatAge: -60), .keyboard)
    }

    func testTwoFailedStartsInARowHoldOffForAnHour() {
        var failures = KeyboardCapture.Failures()
        failures.recordFailure(now: now.addingTimeInterval(-120))
        XCTAssertEqual(route(failures: failures), .keyboard, "one failure is not a pattern")
        failures.recordFailure(now: now.addingTimeInterval(-60))
        XCTAssertEqual(route(failures: failures), .app)
        XCTAssertTrue(failures.holdsOff(now: now.addingTimeInterval(3539)))
        XCTAssertFalse(failures.holdsOff(now: now.addingTimeInterval(3541)), "tries again after the hour")
    }

    func testASuccessOrALongGapClearsTheCount() {
        var failures = KeyboardCapture.Failures()
        failures.recordFailure(now: now)
        failures.recordSuccess()
        failures.recordFailure(now: now)
        XCTAssertFalse(failures.holdsOff(now: now))

        var spaced = KeyboardCapture.Failures()
        spaced.recordFailure(now: now)
        spaced.recordFailure(now: now.addingTimeInterval(7200))
        XCTAssertEqual(spaced.count, 1, "a failure hours later starts over")
        XCTAssertFalse(spaced.holdsOff(now: now.addingTimeInterval(7201)))
    }

    func testAClockMovedBackDoesNotHoldOffForever() {
        let failures = KeyboardCapture.Failures(count: 5, last: now.addingTimeInterval(500))
        XCTAssertFalse(failures.holdsOff(now: now))
    }

    func testFailuresSurviveTheKeyboardsDefaults() throws {
        var failures = KeyboardCapture.Failures()
        failures.recordFailure(now: now)
        failures.recordFailure(now: now)
        let back = try JSONDecoder().decode(KeyboardCapture.Failures.self, from: JSONEncoder().encode(failures))
        XCTAssertEqual(back, failures)
    }

    func testAfterTheProbeOnlySilenceOrNeedsAppLeavesTheKeyboardToRecord() {
        XCTAssertEqual(KeyboardCapture.routeAfterProbe(phase: nil), .keyboard)
        XCTAssertEqual(KeyboardCapture.routeAfterProbe(phase: .requested), .keyboard)
        XCTAssertEqual(KeyboardCapture.routeAfterProbe(phase: .needsApp), .keyboard)
        for phase in [DictationPhase.starting, .recording, .transcribing, .ready, .cancelled, .failed, .interrupted] {
            XCTAssertEqual(KeyboardCapture.routeAfterProbe(phase: phase), .app, "\(phase)")
        }
    }

    func testLevelsUseTheSameScaleAsTheApp() {
        XCTAssertEqual(KeyboardCapture.level(rootMeanSquare: 0), 0)
        XCTAssertEqual(KeyboardCapture.level(rootMeanSquare: -1), 0)
        XCTAssertEqual(KeyboardCapture.level(rootMeanSquare: .nan), 0)
        XCTAssertEqual(KeyboardCapture.level(rootMeanSquare: 0.001), 0, "below -50 dBFS is a flat line")
        var scale = AdaptiveLevelScale()
        XCTAssertEqual(KeyboardCapture.level(rootMeanSquare: 0.1), scale.map(decibels: -20, elapsed: 0), accuracy: 0.0001)
        XCTAssertEqual(KeyboardCapture.level(rootMeanSquare: 1), 1)
        XCTAssertEqual(KeyboardCapture.level(rootMeanSquare: 40), 1)
        XCTAssertLessThan(KeyboardCapture.level(rootMeanSquare: 0.05), KeyboardCapture.level(rootMeanSquare: 0.2))
    }

    func testThePreferenceTravelsToTheKeyboardAndOlderRecordsReadOn() throws {
        let off = KeyboardPreferences(dictatesInKeyboard: false)
        let back = try JSONDecoder().decode(KeyboardPreferences.self, from: JSONEncoder().encode(off))
        XCTAssertFalse(back.dictatesInKeyboard)
        let older = try JSONDecoder().decode(KeyboardPreferences.self, from: Data(#"{"autocorrectEnabled":false}"#.utf8))
        XCTAssertTrue(older.dictatesInKeyboard)
        XCTAssertFalse(older.autocorrectEnabled)
    }
}
