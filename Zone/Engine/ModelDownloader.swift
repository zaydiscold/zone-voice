// by zayd/cold @ zayd.wtf

import Foundation
import UIKit
import UserNotifications
import ZoneCore

// MARK: - Background model downloads

/// One file of a pinned model snapshot.
struct RemoteFile: Sendable, Codable {
    let url: URL
    let destination: URL
    let bytes: Int64
    let digest: FileDigest
    var storageGeneration: String? = nil
}

/// Downloads model files on a background `URLSession`, so a 250 MB model keeps arriving while
/// Zone is suspended or after iOS kills it; the system relaunches the app to hand over what
/// finished. Every file is checked against its pinned hash before it is moved into place, a
/// failed transfer keeps its resume data beside the destination so the next attempt continues
/// instead of starting over, and model folders are excluded from iCloud backup because they
/// can always be downloaded again.
///
/// Each task carries its `RemoteFile` as JSON in `taskDescription`, because after a relaunch
/// the delegate sees tasks this process never started.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// A completed background transfer must not recreate a deleted model after relaunch.
    private let fileMutationLock = NSLock()
    private static let barrierKey = "zone.models.deletionGenerations"
    private var writeBarrier = ModelDownloadBarrier(generations:
        UserDefaults.standard.dictionary(forKey: ModelDownloader.barrierKey) as? [String: String] ?? [:])
    private var cancelledDownloadIDs: Set<Int> = []

    private func writesBlocked(_ file: RemoteFile) -> Bool {
        writeBarrier.blocks(file.destination, generation: file.storageGeneration)
    }

    func preventWritesAndCancel(in directories: [URL]) async {
        fileMutationLock.withLock {
            writeBarrier.retire(directories)
            UserDefaults.standard.set(writeBarrier.generations, forKey: Self.barrierKey)
        }
        for task in await session.allTasks {
            guard let file = task.taskDescription.flatMap(Self.decode),
                  fileMutationLock.withLock({ writesBlocked(file) }) else { continue }
            fileMutationLock.withLock { _ = cancelledDownloadIDs.insert(task.taskIdentifier) }
            task.cancel()
        }
    }
    @TaskLocal static var allowsNewTransfers = true
    static let shared = ModelDownloader()
    static let sessionIdentifier = "wtf.zayd.zone.models"

    /// Set by the app delegate when iOS relaunches Zone for this session's events.
    var backgroundCompletionHandler: (() -> Void)?

    private let lock = NSLock()
    private var waiters: [String: CheckedContinuation<Void, Error>] = [:]
    private var progressHandlers: [String: @Sendable (Int64) -> Void] = [:]
    /// Outcome of `didFinishDownloadingTo`, read when the task completes.
    private var finished: [Int: Result<Void, Error>] = [:]

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = true
        configuration.timeoutIntervalForResource = 60 * 60 * 6
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// Creates the session so a relaunch for background events reaches this delegate.
    func reconnect() { _ = session }

    /// Downloads every file that is missing or the wrong size, all at once so the system can
    /// keep going while Zone is suspended. `progress` gets total bytes on disk out of `total`.
    func fetch(_ files: [RemoteFile], progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let total = files.reduce(0) { $0 + $1.bytes }
        let present = files.filter { Self.size(of: $0.destination) == $0.bytes }
        let missing = files.filter { Self.size(of: $0.destination) != $0.bytes }
        let done = Counter(present.reduce(0) { $0 + $1.bytes })
        let inFlight = InFlight()
        progress(done.total, total)
        guard !missing.isEmpty else { return }
        guard Self.allowsNewTransfers else { throw SpeechEngineError.notReady }
        try DiskSpace.ensureRoom(for: missing.reduce(0) { $0 + $1.bytes }, what: "this model")

        let running = await session.allTasks
        try await withThrowingTaskGroup(of: Void.self) { group in
            for file in missing {
                let key = file.destination.path
                group.addTask { [self] in
                    // Background transfers wait for a network for up to six hours; cancelling the
                    // caller must stop waiting (and pause the transfer) instead of hanging with it.
                    try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        lock.lock()
                        guard !Task.isCancelled else {
                            lock.unlock()
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        waiters[key] = continuation
                        progressHandlers[key] = { written in
                            progress(done.total + inFlight.set(key, written), total)
                        }
                        lock.unlock()
                        // A task from before a relaunch may already be carrying this file. If it
                        // finished between `allTasks` and the registration above, its completion
                        // found no waiter and this one would wait forever (failure map S8), so a
                        // completed task is settled from the disk instead.
                        if let task = running.first(where: { task in
                            guard let remote = task.taskDescription.flatMap(Self.decode), remote.destination.path == key else { return false }
                            return !fileMutationLock.withLock { writesBlocked(remote) }
                        }) {
                            guard task.state == .completed else { return }
                            if Self.size(of: file.destination) == file.bytes {
                                lock.lock()
                                let waiter = waiters.removeValue(forKey: key)
                                progressHandlers[key] = nil
                                lock.unlock()
                                waiter?.resume() // nil when its delegate got there first and resumed it
                                return
                            }
                        }
                        start(file)
                    }
                    } onCancel: {
                        abandon(key)
                    }
                    done.add(file.bytes)
                    progress(done.total + inFlight.set(key, 0), total)
                }
            }
            do {
                try await group.waitForAll()
            } catch {
                // One failed file (a checksum, an HTTP error) ends the fetch now rather than
                // after every other file has finished.
                group.cancelAll()
                throw error
            }
        }
    }

    /// Stops waiting for one file and pauses its transfer, keeping resume data beside the
    /// destination so the next fetch continues from there.
    private func abandon(_ key: String) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: key)
        progressHandlers[key] = nil
        lock.unlock()
        waiter?.resume(throwing: CancellationError())
        session.getAllTasks { [self] tasks in
            // A new fetch for this file may have registered meanwhile; its transfer stays.
            guard lock.withLock({ waiters[key] == nil }) else { return }
            for task in tasks {
                guard let download = task as? URLSessionDownloadTask,
                      let file = task.taskDescription.flatMap(Self.decode), file.destination.path == key else { continue }
                // Its late completion must not settle a newer fetch's waiter for the same path.
                fileMutationLock.withLock { _ = cancelledDownloadIDs.insert(task.taskIdentifier) }
                download.cancel(byProducingResumeData: { data in
                    guard let data else { return }
                    try? FileManager.default.createDirectory(at: file.destination.deletingLastPathComponent(),
                                                             withIntermediateDirectories: true)
                    try? data.write(to: Self.resumeDataURL(for: file.destination))
                })
            }
        }
    }

    private func start(_ file: RemoteFile) {
        var file = file
        file.storageGeneration = fileMutationLock.withLock { writeBarrier.generation(for: file.destination) }
        let resumeURL = Self.resumeDataURL(for: file.destination)
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: resumeURL) {
            try? FileManager.default.removeItem(at: resumeURL)
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: file.url)
        }
        task.taskDescription = Self.encode(file)
        // Only this newly requested transfer can write through an earlier deletion barrier.
        // Old completed tasks not returned by allTasks remain barred even after re-download.
        task.countOfBytesClientExpectsToReceive = file.bytes
        task.resume()
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription.flatMap(Self.decode)?.destination.path else { return }
        lock.lock()
        let handler = progressHandlers[key]
        lock.unlock()
        handler?(totalBytesWritten)
    }

    /// The temporary file disappears when this returns, so it is checked and placed here.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        fileMutationLock.lock()
        defer { fileMutationLock.unlock() }
        let result: Result<Void, Error> = Result {
            guard let file = downloadTask.taskDescription.flatMap(Self.decode) else {
                throw SpeechEngineError.unavailable("A model download lost its destination.")
            }
            guard !writesBlocked(file), !cancelledDownloadIDs.contains(downloadTask.taskIdentifier) else { throw CancellationError() }
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                throw SpeechEngineError.unavailable("\(file.url.lastPathComponent) failed with HTTP \(status).")
            }
            let manager = FileManager.default
            let folder = file.destination.deletingLastPathComponent()
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let staged = file.destination.appendingPathExtension("download")
            try? manager.removeItem(at: staged)
            try manager.moveItem(at: location, to: staged)
            guard Self.size(of: staged) == file.bytes, try file.digest.matches(fileAt: staged) else {
                try? manager.removeItem(at: staged)
                throw SpeechEngineError.unavailable("\(file.destination.lastPathComponent) failed its checksum.")
            }
            try? manager.removeItem(at: file.destination)
            try manager.moveItem(at: staged, to: file.destination)
        }
        lock.lock()
        finished[downloadTask.taskIdentifier] = result
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let file = task.taskDescription.flatMap(Self.decode) else { return }
        let key = file.destination.path
        // There is no live fetch waiter when the coordinator admits deletion. A cancelled
        // pre-relaunch task arriving later must not consume a NEW fetch's waiter for this path.
        if fileMutationLock.withLock({ cancelledDownloadIDs.contains(task.taskIdentifier) || writesBlocked(file) }) {
            lock.withLock { finished[task.taskIdentifier] = nil }
            return
        }
        fileMutationLock.withLock {
            if !writesBlocked(file), !cancelledDownloadIDs.contains(task.taskIdentifier), let error = error as NSError?,
               let resume = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                try? FileManager.default.createDirectory(at: file.destination.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? resume.write(to: Self.resumeDataURL(for: file.destination))
            }
        }
        lock.lock()
        let outcome = error.map { Result<Void, Error>.failure($0) } ?? finished[task.taskIdentifier] ?? .success(())
        finished[task.taskIdentifier] = nil
        let waiter = waiters.removeValue(forKey: key)
        progressHandlers[key] = nil
        lock.unlock()
        waiter?.resume(with: outcome)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [self] in
            backgroundCompletionHandler?()
            backgroundCompletionHandler = nil
        }
    }

    // MARK: Helpers

    /// Keeps a re-downloadable model folder out of iCloud and device backups.
    static func excludeFromBackup(_ directory: URL) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    static func size(of url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    private static func resumeDataURL(for destination: URL) -> URL {
        destination.appendingPathExtension("resume")
    }

    private static func encode(_ file: RemoteFile) -> String? {
        (try? JSONEncoder().encode(file)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func decode(_ text: String) -> RemoteFile? {
        try? JSONDecoder().decode(RemoteFile.self, from: Data(text.utf8))
    }
}

/// A thread-safe byte count shared between download tasks.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64
    init(_ value: Int64) { self.value = value }
    var total: Int64 { lock.withLock { value } }
    func add(_ bytes: Int64) { lock.withLock { value += bytes } }
}

/// Bytes written so far by every file still downloading, so concurrent files add up to one
/// steady progress figure.
private final class InFlight: @unchecked Sendable {
    private let lock = NSLock()
    private var written: [String: Int64] = [:]
    /// Records one file's bytes and returns the sum over all files in flight.
    func set(_ key: String, _ bytes: Int64) -> Int64 {
        lock.withLock {
            written[key] = bytes == 0 ? nil : bytes
            return written.values.reduce(0, +)
        }
    }
}

/// Hands iOS's relaunch-for-downloads callback to the model downloader.
final class ZoneAppDelegate: NSObject, UIApplicationDelegate {
    private var unlockObserver: NSObjectProtocol?

    /// Before launch finishes, so a tap on one of Zone's notifications that launched Zone still
    /// reaches it (`ZoneNotificationResponder`).
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = ZoneNotificationResponder.shared
        IslandLostNotice.registerCategory()
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == ModelDownloader.sessionIdentifier else { return completionHandler() }
        // Before the first unlock the downloader would read its deletion record as empty and keep
        // that for the life of the process, and could not move a file into place anyway. The
        // events wait in the session until it is created after the unlock.
        guard ProtectedDataProbe.standard.isAvailable() else {
            unlockObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, let observer = self.unlockObserver else { return }
                NotificationCenter.default.removeObserver(observer)
                self.unlockObserver = nil
                Self.handOver(completionHandler)
            }
            return
        }
        Self.handOver(completionHandler)
    }

    private static func handOver(_ completionHandler: @escaping () -> Void) {
        ModelDownloader.shared.backgroundCompletionHandler = completionHandler
        ModelDownloader.shared.reconnect()
    }
}
