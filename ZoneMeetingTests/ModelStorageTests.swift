// by zayd/cold @ zayd.wtf

import XCTest
import ZoneCore
@testable import Zone

@MainActor
final class ModelStorageTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var models: [SpeechModel: StorageTestEngine] = [:]
    private var dictation: DictationCoordinator!

    /// The library promises a download size before fetching; it must match what is fetched,
    /// and only measured models may claim a prepared copy.
    func testCatalogSizesMatchPinnedSnapshotAndMeasurement() {
        let pinned = HuggingFaceSnapshot.fluidSpeechMini.totalBytes
        XCTAssertLessThan(abs(SpeechModel.fluidSpeechMini.approximateDownloadBytes - pinned), 1_000_000)
        XCTAssertGreaterThanOrEqual(SpeechModel.fluidSpeechMini.approximatePreparedBytes, 1_284_184_974)
        for model in SpeechModel.allCases where model != .fluidSpeechMini {
            XCTAssertEqual(model.approximatePreparedBytes, 0, "\(model) has no measured prepared size")
        }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "model-storage-" + UUID().uuidString
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for model in SpeechModel.allCases {
            models[model] = StorageTestEngine(kind: model.productEngine, directory: root.appendingPathComponent(model.rawValue))
        }
        try models[.fluidSpeechMini]!.write(1024)
        let store = UserDefaultsSharedStore(suiteName: suite)
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!, store: store)
        dictation = DictationCoordinator(settings: settings, store: store, engine: models[.fluidSpeechMini]!, reviews: .forTests,
                                        modelEngineFactory: { [models] in models[$0]! })
    }

    override func tearDownWithError() throws {
        dictation?.endSession(reason: .user)
        dictation = nil
        models = [:]
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    private func ready() async { await dictation.prepareModelAndWait() }

    func testRedownloadingTheModelInUseLoadsItWithoutReopeningZone() async throws {
        await ready()
        await dictation.deleteModels([.fluidSpeechMini])
        XCTAssertFalse(dictation.modelIsReady)
        await dictation.downloadModel(.fluidSpeechMini)
        await dictation.prepareModelAndWait()
        XCTAssertTrue(dictation.modelIsReady)
        XCTAssertGreaterThanOrEqual(models[.fluidSpeechMini]!.prepareCount, 2)
    }

    func testCancellingALibraryDownloadEndsItQuietlyAndUnblocksDeletion() async throws {
        await ready()
        await dictation.deleteModels([.fluidSpeechMini])
        let started = expectation(description: "download waiting for a network")
        models[.fluidSpeechMini]!.onDownload = {
            started.fulfill()
            try await Task.sleep(nanoseconds: 60_000_000_000) // offline: waits until cancelled
        }
        let download = Task { await dictation.downloadModel(.fluidSpeechMini) }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertNotNil(dictation.modelDeletionBlocker)
        dictation.cancelModelDownload(.fluidSpeechMini)
        await download.value
        XCTAssertTrue(dictation.libraryDownloads.isEmpty)
        XCTAssertNil(dictation.libraryError, "a cancel the person asked for is not an error")
        XCTAssertNil(dictation.modelDeletionBlocker)
        XCTAssertFalse(models[.fluidSpeechMini]!.assetsPresent())
    }

    /// Only Diagnostics switches now (to Apple's recognizer, for comparison), but the guard
    /// must still let an idle switch through.
    func testSwitchGuardStillAllowsAnIdleSwitch() async throws {
        // Switching persists the choice in the app's own defaults; leave them as found.
        let saved = UserDefaults.standard.object(forKey: "zone.diagnostics.engine")
        defer { UserDefaults.standard.set(saved, forKey: "zone.diagnostics.engine") }
        await ready()
        XCTAssertNil(dictation.modelSwitchBlocker)
        await dictation.selectModel(.appleSpeech)
        XCTAssertEqual(dictation.selectedModel, .appleSpeech, "an idle switch still works")
        XCTAssertEqual(models[.appleSpeech]!.prepareCount, 1, "switching uses the supplied model factory, not a real network download")
    }

    func testOffDuringPermissionInvalidatesPendingArmButAllowsNextExplicitArm() async throws {
        await ready()
        let gate = StorageGate()
        let entered = expectation(description: "permission pending")
        var requests = 0, captureStarts = 0
        let store = UserDefaultsSharedStore(suiteName: suite)
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!, store: store)
        dictation = DictationCoordinator(settings: settings, store: store, engine: models[.fluidSpeechMini]!, reviews: .forTests,
            requestSessionPermission: {
                requests += 1
                if requests == 1 { entered.fulfill(); await gate.wait() }
                return true
            }, armSessionCapture: { captureStarts += 1 })
        await ready()
        let start = Task { try await dictation.armSession() }
        await fulfillment(of: [entered], timeout: 3)
        dictation.endSession(reason: .user)
        await gate.open()
        do { try await start.value; XCTFail("Off did not cancel pending arm") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(dictation.isArmed)
        XCTAssertEqual(captureStarts, 0)
        try await dictation.armSession()
        XCTAssertTrue(dictation.isArmed)
        XCTAssertEqual(captureStarts, 1)
    }

    func testCancelledArmCannotStartCaptureAfterPermissionReturns() async throws {
        await ready()
        let gate = StorageGate()
        let entered = expectation(description: "permission pending")
        var captureStarts = 0
        let store = UserDefaultsSharedStore(suiteName: suite)
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!, store: store)
        dictation = DictationCoordinator(settings: settings, store: store, engine: models[.fluidSpeechMini]!, reviews: .forTests,
            requestSessionPermission: { entered.fulfill(); await gate.wait(); return true },
            armSessionCapture: { captureStarts += 1 })
        await ready()
        let start = Task { try await dictation.armSession() }
        await fulfillment(of: [entered], timeout: 3)
        start.cancel()
        await gate.open()
        do { try await start.value; XCTFail("Cancelled arm started capture") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(dictation.isArmed)
        XCTAssertEqual(captureStarts, 0)
    }

    func testOffDuringModelLoadingDoesNotRequestPermissionOrArmWhenLoadCompletes() async throws {
        await ready()
        let gate = StorageGate()
        let entered = expectation(description: "model loading")
        let engine = models[.fluidSpeechMini]!
        engine.unload()
        engine.onPrepare = { entered.fulfill(); await gate.wait() }
        var permissionRequests = 0, captureStarts = 0, startEntered = false
        let store = UserDefaultsSharedStore(suiteName: suite)
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!, store: store)
        dictation = DictationCoordinator(settings: settings, store: store, engine: engine, reviews: .forTests,
            requestSessionPermission: { permissionRequests += 1; return true },
            armSessionCapture: { captureStarts += 1 })
        let start = Task { startEntered = true; try await dictation.armSession() }
        await fulfillment(of: [entered], timeout: 3)
        while !startEntered { await Task.yield() }
        dictation.endSession(reason: .user)
        await gate.open()
        do { try await start.value; XCTFail("Off did not cancel model-waiting arm") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(dictation.isArmed)
        XCTAssertEqual(permissionRequests, 0)
        XCTAssertEqual(captureStarts, 0)
        XCTAssertTrue(dictation.modelIsReady, "shared preparation may finish without starting the mic")
    }

    func testOffClearsKeyboardRequestQueuedBehindModelLoading() async throws {
        await ready()
        let gate = StorageGate()
        let entered = expectation(description: "model loading")
        let engine = models[.fluidSpeechMini]!
        engine.unload()
        engine.onPrepare = { entered.fulfill(); await gate.wait() }
        var permissionRequests = 0, captureStarts = 0
        let store = UserDefaultsSharedStore(suiteName: suite)
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!, store: store)
        dictation = DictationCoordinator(settings: settings, store: store, engine: engine, reviews: .forTests,
            requestSessionPermission: { permissionRequests += 1; return true },
            armSessionCapture: { captureStarts += 1 })
        let request = DictationRequest(id: UUID(), generation: 1, createdAt: Date(), inputSession: nil, contextBefore: nil)
        store.request = request
        dictation.handle(url: URL(string: "zone://dictate?request=\(request.id.uuidString)")!)
        await fulfillment(of: [entered], timeout: 3)
        dictation.endSession(reason: .user)
        await gate.open()
        await ready()
        XCTAssertFalse(dictation.isArmed)
        XCTAssertEqual(permissionRequests, 0)
        XCTAssertEqual(captureStarts, 0)
        XCTAssertEqual(store.status?.phase, .cancelled)
        XCTAssertEqual(store.status?.requestID, request.id)
    }

    func testInventoryScanDoesNotBlockMainActor() async {
        let entered = expectation(description: "background scan started")
        let release = DispatchSemaphore(value: 0)
        let scan = Task {
            await ModelLibraryInventory.read {
                XCTAssertFalse(Thread.isMainThread)
                entered.fulfill()
                _ = release.wait(timeout: .now() + 3)
                return [:]
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        // We resumed on MainActor while filesystem work remains blocked on the background lane.
        XCTAssertTrue(Thread.isMainThread)
        release.signal()
        let snapshot = await scan.value
        XCTAssertTrue(snapshot.entries.isEmpty)
    }

    func testProgressBurstIsBoundedAndStillDeliversCompletionAndLoading() {
        let gate = ModelProgressGate()
        var delivered = 0
        for tick in 0..<10_000 {
            if gate.accept(Double(tick) / 10_000, file: "file-\(tick % 24)", now: Double(tick) / 10_000) {
                delivered += 1
            }
        }
        XCTAssertLessThanOrEqual(delivered, 11)
        XCTAssertTrue(gate.accept(1, now: 1))
        XCTAssertFalse(gate.accept(1, now: 1.1))
        XCTAssertFalse(gate.accept(0.8, now: 1.2))
        XCTAssertFalse(gate.accept(.nan, now: 1.3))
        XCTAssertTrue(gate.accept(1, file: "loading", now: 1.4))
        XCTAssertFalse(gate.accept(1, file: "loading", now: 1.5))
        XCTAssertFalse(gate.accept(0.9, now: 2))
    }

    func testStorageBreakdownSeparatesPreparedFilesAndExcludesSavedDocuments() throws {
        let directory = root.appendingPathComponent("speech-model")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 253).write(to: directory.appendingPathComponent("weights"))
        try Data(repeating: 2, count: 500).write(to: root.appendingPathComponent("saved-recording.wav"))
        let storage = ModelStorageBreakdown(directory: directory, preparedFiles: 1_267)
        XCTAssertEqual(storage.modelFiles, 253)
        XCTAssertEqual(storage.preparedFiles, 1_267)
        XCTAssertEqual(storage.total, 1_520)
        // A partial or removed download can still have attributable prepared files.
        try FileManager.default.removeItem(at: directory)
        let cached = ModelStorageBreakdown(directory: directory, preparedFiles: 1_267)
        XCTAssertEqual(cached.modelFiles, 0)
        XCTAssertEqual(cached.total, 1_267)
        XCTAssertEqual(ModelStorageBreakdown(directory: nil, preparedFiles: 0).total, 0)
    }

    func testDeleteAllRemovesPartialAndRetiredFilesButKeepsRecordings() async throws {
        await ready()
        try models[.moonshineMedium]!.write(512)
        models[.moonshineMedium]!.complete = false
        let recording = root.appendingPathComponent("precious-recording.wav")
        try Data([1, 2, 3]).write(to: recording)
        XCTAssertEqual(Set(dictation.downloadedSpeechModels), [.fluidSpeechMini, .moonshineMedium])
        await dictation.deleteModels(dictation.downloadedSpeechModels)
        XCTAssertEqual(models[.fluidSpeechMini]!.bytesOnDisk(), 0)
        XCTAssertEqual(models[.moonshineMedium]!.bytesOnDisk(), 0)
        XCTAssertEqual(try Data(contentsOf: recording), Data([1, 2, 3]))
        XCTAssertEqual(dictation.modelState, .missing)
        XCTAssertNil(dictation.libraryError)
        XCTAssertNotNil(dictation.libraryNotice)
        XCTAssertFalse(dictation.isDeletingModels)
        let prepares = models[.fluidSpeechMini]!.prepareCount
        dictation.scenePhaseChanged(.active)
        await Task.yield()
        XCTAssertEqual(models[.fluidSpeechMini]!.prepareCount, prepares, "opening the app must not recreate deleted files")
    }

    func testRetiredCleanupKeepsActiveModelAndIsIdempotent() async throws {
        await ready()
        for model in SpeechModel.retired { try models[model]!.write(512) }
        await dictation.deleteModels(SpeechModel.retired)
        for model in SpeechModel.retired { XCTAssertEqual(models[model]!.bytesOnDisk(), 0) }
        XCTAssertEqual(models[.fluidSpeechMini]!.bytesOnDisk(), 1024)
        XCTAssertTrue(dictation.modelIsReady)
        await dictation.deleteModels(SpeechModel.retired)
        XCTAssertNil(dictation.libraryError)
        XCTAssertEqual(models[.fluidSpeechMini]!.bytesOnDisk(), 1024)
        XCTAssertTrue(SpeechModel.retired.allSatisfy { models[$0]!.bytesOnDisk() == 0 })
    }

    func testDeletionReservesEngineWhileNativeCleanupIsSuspended() async throws {
        await ready()
        let gate = StorageGate()
        let entered = expectation(description: "unload started")
        models[.fluidSpeechMini]!.onUnload = { entered.fulfill(); await gate.wait() }
        let deletion = Task { await dictation.deleteModel(.fluidSpeechMini) }
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertTrue(dictation.isDeletingModels)
        XCTAssertEqual(models[.fluidSpeechMini]!.bytesOnDisk(), 1024)
        for _ in 0..<8 { await dictation.deleteModel(.fluidSpeechMini) }
        await dictation.downloadModel(.fluidSpeechMini)
        await dictation.switchEngine(to: .appleSpeech)
        dictation.prepareModel()
        do { try await dictation.armSession(); XCTFail("armed during deletion") } catch {}
        XCTAssertThrowsError(try dictation.makeMeetingUtterance())
        XCTAssertThrowsError(try dictation.makeBenchmarkUtterance())
        do { try await dictation.startClipCapture(); XCTFail("clip capture during deletion") } catch {}
        XCTAssertEqual(models[.fluidSpeechMini]!.downloadCount, 0)
        XCTAssertEqual(dictation.selectedModel, .fluidSpeechMini)
        await gate.open()
        await deletion.value
        XCTAssertNil(dictation.libraryError)
        XCTAssertEqual(models[.fluidSpeechMini]!.removeCount, 1)
        XCTAssertEqual(models[.fluidSpeechMini]!.bytesOnDisk(), 0)
    }

    func testFailedRemovalReportsFailureAndCanBeRetried() async throws {
        await ready()
        models[.fluidSpeechMini]!.refuseRemoval = true
        await dictation.deleteModel(.fluidSpeechMini)
        XCTAssertNotNil(dictation.libraryError)
        XCTAssertEqual(models[.fluidSpeechMini]!.bytesOnDisk(), 1024)
        XCTAssertFalse(dictation.isDeletingModels)
        models[.fluidSpeechMini]!.refuseRemoval = false
        await dictation.deleteModel(.fluidSpeechMini)
        XCTAssertNil(dictation.libraryError)
        XCTAssertEqual(models[.fluidSpeechMini]!.bytesOnDisk(), 0)
    }

    func testRecordingMeetingBlocksDeletionWithoutStoppingOrDeletingIt() async throws {
        await ready()
        let store = MeetingStore(directory: root.appendingPathComponent("Meetings"))
        let meeting = MeetingCoordinator(dictation: dictation, store: store, recover: { _ in },
                                         requestPermission: { true }, startCapture: { _ in }, stopCapture: {})
        let saved = UserDefaults.standard.object(forKey: "zone.meetings.labelSpeakers")
        UserDefaults.standard.set(false, forKey: "zone.meetings.labelSpeakers")
        defer { UserDefaults.standard.set(saved, forKey: "zone.meetings.labelSpeakers") }
        await meeting.startRecording()
        XCTAssertTrue(meeting.isRecording)
        await dictation.deleteModel(.fluidSpeechMini)
        XCTAssertNotNil(dictation.libraryError)
        XCTAssertTrue(meeting.isRecording)
        XCTAssertEqual(models[.fluidSpeechMini]!.bytesOnDisk(), 1024)
        await meeting.discardRecording()
    }

    func testLateBackgroundCompletionCannotRecreateDeletedResumeData() async throws {
        let directory = root.appendingPathComponent("late-download")
        let destination = directory.appendingPathComponent("weights")
        let file = RemoteFile(url: URL(string: "https://example.invalid/never-requested")!,
                              destination: destination, bytes: 1, digest: .sha256(String(repeating: "0", count: 64)))
        let downloader = ModelDownloader.shared
        await downloader.preventWritesAndCancel(in: [directory])
        let task = URLSession.shared.downloadTask(with: file.url) // deliberately never resumed
        defer { task.cancel() }
        task.taskDescription = String(data: try JSONEncoder().encode(file), encoding: .utf8)
        let resume = Data([1, 2, 3])
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled,
                            userInfo: [NSURLSessionDownloadTaskResumeData: resume])
        downloader.urlSession(URLSession.shared, task: task, didCompleteWithError: error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        var explicit = file
        let saved = UserDefaults.standard.dictionary(forKey: "zone.models.deletionGenerations") as? [String: String] ?? [:]
        explicit.storageGeneration = ModelDownloadBarrier(generations: saved).generation(for: destination)
        XCTAssertNotNil(explicit.storageGeneration)
        task.taskDescription = String(data: try JSONEncoder().encode(explicit), encoding: .utf8)
        downloader.urlSession(URLSession.shared, task: task, didCompleteWithError: error)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathExtension("resume")), resume)
    }

    func testCatalogOffersOneModelAndMigratesRetiredSelection() {
        XCTAssertEqual(SpeechModel.offered, [.fluidSpeechMini])
        XCTAssertEqual(EngineKind.recommended, .fluidMiniCPU, "every iPhone starts on Fluid Speech Mini")
        XCTAssertEqual(Set(SpeechModel.retired), [.moonshineTiny, .moonshineSmall, .moonshineMedium, .parakeet110m])
        // Exactly where moonshine-swift 0.1.5 kept each model, so launch cleanup finds them.
        for (model, key) in [(SpeechModel.moonshineTiny, "stt-en-2"), (.moonshineSmall, "stt-en-4"), (.moonshineMedium, "stt-en-5")] {
            XCTAssertEqual(model.assetDirectory?.lastPathComponent, key)
            XCTAssertEqual(model.assetDirectory?.deletingLastPathComponent().lastPathComponent, "MoonshineModels")
        }
        let saved = UserDefaults.standard.object(forKey: "zone.diagnostics.engine")
        defer { UserDefaults.standard.set(saved, forKey: "zone.diagnostics.engine") }
        for model in SpeechModel.retired {
            EngineKind.selected = model.productEngine
            XCTAssertFalse(EngineKind.selected.model.isRetired)
        }
        // A phone that last used Light saved a Moonshine engine that no longer exists.
        for raw in ["moonshineTiny", "moonshineTinySingleThread", "moonshineSmallSingleThread", "moonshineMedium"] {
            UserDefaults.standard.set(raw, forKey: "zone.diagnostics.engine")
            XCTAssertEqual(EngineKind.selected, .fluidMiniCPU, raw)
        }
    }

    /// The retired Moonshine models name Fluid Speech Mini as their replacement engine. Their
    /// cleanup must still go through a files-only engine, or deleting old Moonshine files would
    /// delete the model in use.
    func testRetiredMoonshineCleanupOnlyTouchesItsOwnFolder() throws {
        for model in [SpeechModel.moonshineTiny, .moonshineSmall, .moonshineMedium] {
            XCTAssertTrue(model.isFilesOnly)
            XCTAssertTrue(model.makeEngine() is RetiredModelFiles, "\(model)")
        }
        for model in [SpeechModel.fluidSpeechMini, .parakeet110m] {
            XCTAssertFalse(model.isFilesOnly)
            XCTAssertFalse(model.makeEngine() is RetiredModelFiles, "\(model)")
        }
        let old = root.appendingPathComponent("MoonshineModels/stt-en-2")
        let live = root.appendingPathComponent("fluid-speech-mini")
        for directory in [old, live] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(count: 700).write(to: directory.appendingPathComponent("weights"))
        }
        let files = RetiredModelFiles(kind: SpeechModel.moonshineTiny.productEngine, directory: old)
        XCTAssertEqual(files.bytesOnDisk(), 700)
        XCTAssertFalse(files.assetsPresent(), "a retired model is never offered as ready")
        try files.removeAssets()
        try files.removeAssets() // idempotent: launch cleanup retries every time
        XCTAssertEqual(files.bytesOnDisk(), 0)
        XCTAssertEqual(DiskUsage.bytes(at: live), 700, "only the retired folder is removed")
        XCTAssertThrowsError(try files.beginUtterance())
    }

    /// The launch sweep of retired downloads used to run before the model in use could load:
    /// a median 0.77 s added to every cold start on a phone, for a sweep that freed nothing.
    /// The production launch (no injected engine): the load is not held, the sweep still runs.
    func testLaunchSweepRunsBesideTheModelLoad() async throws {
        let planted = try XCTUnwrap(SpeechModel.moonshineTiny.assetDirectory)
        try FileManager.default.createDirectory(at: planted, withIntermediateDirectories: true)
        try Data(count: 512).write(to: planted.appendingPathComponent("launch-sweep-test"))
        let store = UserDefaultsSharedStore(suiteName: suite)
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!, store: store)
        let launched = DictationCoordinator(settings: settings, store: store)
        XCTAssertFalse(SpeechModel.retired.contains(launched.selectedModel), "The model in use is never a retired one")
        XCTAssertFalse(launched.isDeletingModels, "Loading the model in use must not wait for the sweep")
        let deadline = Date().addingTimeInterval(10)
        while FileManager.default.fileExists(atPath: planted.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: planted.path), "The sweep still removes retired downloads")
    }
}

private actor StorageGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { await withCheckedContinuation { waiters.append($0) } }
    func open() { for waiter in waiters { waiter.resume() }; waiters = [] }
}

private final class StorageTestEngine: SpeechEngine {
    let kind: EngineKind
    let directory: URL
    var isReady = false
    var complete = true
    var prepareCount = 0
    var downloadCount = 0
    var removeCount = 0
    var refuseRemoval = false
    var onUnload: (() async -> Void)?
    var onPrepare: (() async -> Void)?
    var onDownload: (() async throws -> Void)?
    init(kind: EngineKind, directory: URL) { self.kind = kind; self.directory = directory }
    func write(_ bytes: Int) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(count: bytes).write(to: directory.appendingPathComponent("weights"))
    }
    func assetsPresent() -> Bool { complete && bytesOnDisk() > 0 }
    func bytesOnDisk() -> Int64 { DiskUsage.bytes(at: directory) }
    func removeAssets() throws {
        removeCount += 1
        if refuseRemoval { throw SpeechEngineError.unavailable("Test: storage refused removal") }
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    func downloadAssets(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        downloadCount += 1
        try await onDownload?()
        try write(1024)
    }
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        prepareCount += 1
        await onPrepare?()
        isReady = true
    }
    func setContextHints(_ text: String) {}
    func beginUtterance() throws -> UtteranceSession { throw SpeechEngineError.notReady }
    func unload() { isReady = false }
    func unloadAndWait() async { unload(); await onUnload?() }
}
