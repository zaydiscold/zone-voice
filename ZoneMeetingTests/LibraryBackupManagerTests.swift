// by zayd/cold @ zayd.wtf

import XCTest
import ZoneCore
@testable import Zone

/// The automatic folder backup end to end on the simulator: a real bookmark, the off-main
/// resolve, snapshot and coordinated write, and the schedule that keeps the 30 second check
/// from rewriting an unchanged library into iCloud Drive.
@MainActor
final class LibraryBackupManagerTests: XCTestCase {
    private var roots: [URL] = []
    private var suites: [String] = []

    override func tearDown() {
        for url in roots { try? FileManager.default.removeItem(at: url) }
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        roots = []; suites = []
        super.tearDown()
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url
    }

    private func defaults() -> UserDefaults {
        let suite = "backup-test-" + UUID().uuidString
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    private func makeCoordinators() throws -> (DictationCoordinator, MeetingCoordinator) {
        let suite = "backup-test-" + UUID().uuidString
        suites.append(suite)
        let store = UserDefaultsSharedStore(suiteName: suite)
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!, store: store)
        let dictation = DictationCoordinator(settings: settings, store: store, engine: BackupTestEngine())
        let meetings = MeetingCoordinator(dictation: dictation, store: MeetingStore(directory: try temporaryFolder()),
                                          recover: { _ in }, requestPermission: { false })
        return (dictation, meetings)
    }

    private func written(_ folder: URL) -> Date? {
        let manifest = folder.appendingPathComponent("Zone library.zonebackup/library.json")
        return try? manifest.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    func testCleanChecksSkipTheWriteAndChangesOrBackUpNowWrite() async throws {
        try XCTSkipIf(TranscriptHistory.shared == nil, "History needs the App Group container")
        let (dictation, meetings) = try makeCoordinators()
        let folder = try temporaryFolder()
        let manager = LibraryBackupManager(defaults: defaults(), minimumInterval: 0)
        try await manager.selectFolder(folder)
        XCTAssertEqual(manager.folderName, folder.lastPathComponent)

        await manager.saveAutomatically(notes: dictation.notes, meetings: meetings)
        XCTAssertNil(manager.lastError)
        let first = try XCTUnwrap(written(folder), "The first check after launch or a new folder saves")
        XCTAssertNotNil(try LibraryBackupFiles.read(folder.appendingPathComponent("Zone library.zonebackup")))

        for _ in 0..<5 { await manager.saveAutomatically(notes: dictation.notes, meetings: meetings) }
        XCTAssertEqual(written(folder), first, "Checks with nothing changed must not rewrite the backup")

        let savedBefore = try XCTUnwrap(manager.lastSavedAt)
        await manager.saveNow(notes: dictation.notes, meetings: meetings)
        XCTAssertGreaterThan(try XCTUnwrap(manager.lastSavedAt), savedBefore, "Back up now always runs a save")
        let manual = try XCTUnwrap(written(folder))

        // A real change, then the burst of notifications it would come with.
        let burst = try meetings.store.beginRecording(title: "Burst")
        try await burst.1.finish()
        _ = try meetings.store.finishRecording(burst.0.id)
        for _ in 0..<10 { manager.libraryChanged(notes: dictation.notes, meetings: meetings) }
        let deadline = Date().addingTimeInterval(8)
        // The manifest lands before the save finishes; wait for the whole save.
        while (written(folder) == manual || manager.isWorking) && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        let afterBurst = try XCTUnwrap(written(folder))
        XCTAssertGreaterThan(afterBurst, manual, "A burst of changes saves once it settles")
        XCTAssertTrue(try LibraryBackupFiles.read(folder.appendingPathComponent("Zone library.zonebackup")).meetings.contains { $0.id == burst.0.id })
        XCTAssertFalse(manager.isWorking)
        await manager.saveAutomatically(notes: dictation.notes, meetings: meetings)
        XCTAssertEqual(written(folder), afterBurst)

        // Meeting edits post no notification; the source signature still catches them.
        let added = try meetings.store.beginRecording(title: "Standup")
        try await added.1.finish()
        _ = try meetings.store.finishRecording(added.0.id)
        await manager.saveAutomatically(notes: dictation.notes, meetings: meetings)
        let withMeeting = try LibraryBackupFiles.read(folder.appendingPathComponent("Zone library.zonebackup"))
        XCTAssertTrue(withMeeting.meetings.contains { $0.id == added.0.id })
    }

    func testFailedSaveIsRetriedByTheNextCheck() async throws {
        try XCTSkipIf(TranscriptHistory.shared == nil, "History needs the App Group container")
        let (dictation, meetings) = try makeCoordinators()
        let folder = try temporaryFolder()
        let manager = LibraryBackupManager(defaults: defaults(), minimumInterval: 0)
        try await manager.selectFolder(folder)
        let package = folder.appendingPathComponent("Zone library.zonebackup", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("not a backup".utf8).write(to: package.appendingPathComponent("library.json"))

        await manager.saveAutomatically(notes: dictation.notes, meetings: meetings)
        XCTAssertNotNil(manager.lastError, "An unreadable existing backup is never overwritten")
        await manager.saveAutomatically(notes: dictation.notes, meetings: meetings)
        XCTAssertNotNil(manager.lastError)

        try FileManager.default.removeItem(at: package.appendingPathComponent("library.json"))
        await manager.saveAutomatically(notes: dictation.notes, meetings: meetings)
        XCTAssertNil(manager.lastError, "With nothing else changed, the retry still runs after a failure")
        XCTAssertNotNil(try LibraryBackupFiles.read(package))
    }

    /// The 5 minute spacing, shortened to 5 seconds: a change right after a save waits for the
    /// interval and is then saved by the deferred save with no further prompting; Back up now
    /// and a finished meeting never wait.
    func testSavesAreSpacedButPendingChangesStillLand() async throws {
        try XCTSkipIf(TranscriptHistory.shared == nil, "History needs the App Group container")
        let (dictation, meetings) = try makeCoordinators()
        let folder = try temporaryFolder()
        let manager = LibraryBackupManager(defaults: defaults(), minimumInterval: 5)
        try await manager.selectFolder(folder)
        await manager.saveNow(notes: dictation.notes, meetings: meetings)
        let first = try XCTUnwrap(written(folder))

        // A meeting added on disk: the next automatic check must wait for the interval.
        let added = try meetings.store.beginRecording(title: "Spaced")
        try await added.1.finish()
        _ = try meetings.store.finishRecording(added.0.id)
        await manager.saveAutomatically(notes: dictation.notes, meetings: meetings)
        XCTAssertEqual(written(folder), first, "Inside the interval the change waits")

        let deadline = Date().addingTimeInterval(9)
        while (written(folder) == first || manager.isWorking) && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        let deferred = try XCTUnwrap(written(folder))
        XCTAssertGreaterThan(deferred, first, "The pending change saves when the interval ends, without another trigger")
        let package = folder.appendingPathComponent("Zone library.zonebackup")
        XCTAssertTrue(try LibraryBackupFiles.read(package).meetings.contains { $0.id == added.0.id })

        await manager.saveNow(notes: dictation.notes, meetings: meetings)
        XCTAssertNil(manager.lastError)
        XCTAssertEqual(written(folder), deferred, "Back up now runs, and an unchanged library is not rewritten")

        let ended = try meetings.store.beginRecording(title: "Ended")
        try await ended.1.finish()
        _ = try meetings.store.finishRecording(ended.0.id)
        manager.libraryChanged(notes: dictation.notes, meetings: meetings, prompt: true)
        let promptDeadline = Date().addingTimeInterval(4)
        while !((try? LibraryBackupFiles.read(package).meetings.contains { $0.id == ended.0.id }) ?? false) && Date() < promptDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(try LibraryBackupFiles.read(package).meetings.contains { $0.id == ended.0.id },
                      "A finished meeting saves after the debounce even inside the interval")
    }

    func testStoppedBackupsNeverWrite() async throws {
        let (dictation, meetings) = try makeCoordinators()
        let folder = try temporaryFolder()
        let manager = LibraryBackupManager(defaults: defaults(), minimumInterval: 0)
        try await manager.selectFolder(folder)
        manager.stopAutomaticBackups()
        await manager.saveNow(notes: dictation.notes, meetings: meetings)
        XCTAssertNil(written(folder))
    }
}

private final class BackupTestEngine: SpeechEngine {
    let kind: EngineKind = .fluidMiniCPU
    var isReady = true
    func assetsPresent() -> Bool { true }
    func bytesOnDisk() -> Int64 { 0 }
    func removeAssets() throws {}
    func downloadAssets(progress: @escaping @Sendable (Double, String) -> Void) async throws {}
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {}
    func setContextHints(_ text: String) {}
    func beginUtterance() throws -> UtteranceSession { throw CancellationError() }
    func unload() {}
}
