// by zayd/cold @ zayd.wtf

import Darwin
import Foundation

public enum RecordingRefusal {
    public static let starting = "Wait for the mic to start."
    public static let writing = "Try again when Zone finishes writing."
    public static let recording = "Stop the current recording to start another."
    public static let keyboard = "Finish the keyboard recording to start another."
    public static let note = "Finish the voice note to start another recording."
    public static let meeting = "Stop the meeting to start another recording."
    public static let retry = "Finish or cancel the audio retry before starting a recording."
    public static let clip = "Stop the test clip to start another recording."
    public static let voiceSetup = "Finish voice setup to start another recording."
    public static let idle = "Start a recording first."
}

/// "The Zone keyboard is recording by itself": the only link between a recording in the
/// keyboard (`KeyboardCapture`) and the app's own starts (the Action Button, the Dynamic
/// Island's Dictate and Note, Home, a `zone://dictate` link).
///
/// The keyboard writes it when its microphone actually starts, refreshes the heartbeat about
/// once a second while the microphone is live (recording or paused), and clears it when the
/// microphone goes off for any reason. Recognition after that does not hold it. A claim whose
/// heartbeat has gone quiet is dead: a keyboard that iOS ended mid-recording must never block
/// the Action Button. With the keyboard route unused, nothing ever writes one, and the app
/// behaves as if this did not exist.
public struct KeyboardRecordingClaim: Codable, Equatable, Sendable {
    /// The keyboard's own request, the one it is recording.
    public let requestID: UUID
    /// When the keyboard's microphone started.
    public let since: Date
    /// The keyboard's latest sign that its microphone is still live.
    public var heartbeat: Date

    /// How often the keyboard refreshes the heartbeat while it records.
    public static let refresh: TimeInterval = 1
    /// A heartbeat older than this means the keyboard is gone (or its microphone is): the claim
    /// is ignored and cleared.
    public static let tolerance: TimeInterval = 8

    public init(requestID: UUID, since: Date, heartbeat: Date) {
        self.requestID = requestID
        self.since = since
        self.heartbeat = heartbeat
    }

    /// True while the keyboard is still recording. A heartbeat from the future beyond the
    /// tolerance means the clock moved back after it was written: a live keyboard rewrites it
    /// within a second, so only a dead one stays ahead.
    public func isLive(now: Date) -> Bool {
        let age = now.timeIntervalSince(heartbeat)
        return age <= Self.tolerance && age >= -Self.tolerance
    }

    /// What a start press says while the keyboard records, as iOS shows it under the Action
    /// Button or the island.
    public static let pressRefusal = RecordingRefusal.keyboard
    /// The same for a start inside Zone (Home, or the keyboard's own link into Zone).
    public static let appRefusal = RecordingRefusal.keyboard

    public enum Verdict: Equatable, Sendable {
        /// No claim: start as always.
        case clear
        /// A dead claim: clear it from the store, then start as always.
        case stale
        /// The keyboard is recording: refuse the start.
        case keyboardRecording(UUID)
    }

    /// The rule every app start runs before it touches the microphone.
    /// - Parameter forRequest: a start that is the keyboard's own request (its link into Zone
    ///   for the same id) is never refused by its own claim.
    public static func verdict(_ claim: KeyboardRecordingClaim?, now: Date, forRequest: UUID? = nil) -> Verdict {
        guard let claim else { return .clear }
        guard claim.isLive(now: now) else { return .stale }
        if let forRequest, forRequest == claim.requestID { return .clear }
        return .keyboardRecording(claim.requestID)
    }
}

/// The open descriptor owns the microphone across the two processes. Closing the
/// descriptor (including process death) releases it. Never unlink the lock file.
public final class MicrophoneLease {
    private let descriptors: [Int32]
    /// The app can proceed with iOS arbitration after a file error. Advertise a
    /// descriptor to older peers only when their probe can actually observe it.
    public let holdsPeerLock: Bool

    private enum Attempt {
        case held(Int32)
        case busy
        case missing
        case unavailable(String, Int32)
    }

    public convenience init?(at file: URL?) {
        guard case .held(let fd) = Self.lock(file, create: true) else { return nil }
        self.init([fd], holdsPeerLock: true)
    }

    private init(_ descriptors: [Int32], holdsPeerLock: Bool) {
        self.descriptors = descriptors
        self.holdsPeerLock = holdsPeerLock
    }

    private static func lock(_ file: URL?, create: Bool) -> Attempt {
        guard let file else { return .unavailable("container", ENOENT) }
        let flags = O_CLOEXEC | (create ? O_RDWR | O_CREAT : O_RDONLY)
        var fd: Int32
        repeat { fd = open(file.path, flags, 0o600) } while fd < 0 && errno == EINTR
        if fd < 0 {
            let code = errno
            if !create && code == ENOENT { return .missing }
            return failure("open", code)
        }
        var status: Int32
        repeat { status = flock(fd, LOCK_EX | LOCK_NB) } while status < 0 && errno == EINTR
        if status == 0 { return .held(fd) }
        let code = errno
        close(fd)
        return failure("flock", code)
    }

    private static func failure(_ operation: String, _ code: Int32) -> Attempt {
        if code == EEXIST || code == EAGAIN || code == EWOULDBLOCK { return .busy }
        return .unavailable(operation, code)
    }

    fileprivate static func acquire(at file: URL?, legacy: URL?, report: (String, Int32) -> Void) -> MicrophoneLease? {
        var held: [Int32] = []
        // Never move, replace or unlink the inode an older running process might be using.
        // When it exists, keep its descriptor for the full recording.
        var files: [(url: URL?, create: Bool)] = [(file, true)]
        if let legacy { files.append((legacy, false)) }
        for (url, create) in files {
            switch lock(url, create: create) {
            case .held(let fd):
                held.append(fd)
            case .busy:
                for fd in held { close(fd) }
                return nil
            case .missing:
                break
            case .unavailable(let operation, let code):
                report(operation, code)
            }
        }
        return MicrophoneLease(held, holdsPeerLock: !held.isEmpty)
    }

    deinit { for fd in descriptors { close(fd) } }
}

/// Held by the same store as the recording host, so losing its view controller
/// never drops the lock. The host already clears its claim when capture ends.
public final class MicrophoneOwnership {
    public let file: URL?
    private let stateLock = NSLock()
    private var keyboardLease: (id: UUID, lease: MicrophoneLease)?

    private let legacyFile: URL?

    public init(file: URL?) {
        self.file = file
        legacyFile = nil
    }

    init(group: URL?) {
        let legacy = group?.appendingPathComponent("microphone.lock")
        legacyFile = legacy
        file = group?.appendingPathComponent("Library/Application Support/microphone.lock")
    }

    public func reserveForApp(report: (String, Int32) -> Void) -> MicrophoneLease? {
        if legacyFile != nil, let directory = file?.deletingLastPathComponent() {
            // open() below supplies the precise error if the directory remains unavailable.
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return MicrophoneLease.acquire(at: file, legacy: legacyFile, report: report)
    }

    public func reserveForKeyboard(recordingID: UUID, report: (String, Int32) -> Void) -> Bool {
        stateLock.withLock {
            guard keyboardLease == nil, let lease = reserveForApp(report: report) else { return false }
            keyboardLease = (recordingID, lease)
            return true
        }
    }

    public func keyboardStopped(recordingID: UUID) {
        stateLock.withLock {
            if keyboardLease?.id == recordingID { keyboardLease = nil }
        }
    }
}

/// Posting a status and reading it back are separate operations across processes. Elect
/// exactly one recorder for a keyboard request before either starts its microphone.
public enum KeyboardTapOwner {
    private static let cleanup = DispatchQueue(label: "wtf.zayd.zone.tap-owners", qos: .utility)
    private static var lastCleanup = Date.distantPast // cleanup queue only

    public static func take(_ id: UUID, directory: URL) -> Bool {
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return false }
        let path = directory.appendingPathComponent(id.uuidString).path
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    public static func take(_ request: DictationRequest, store: SharedStore) -> Bool {
        // The memory store is process-local and used by the simulator harness and unit tests.
        let base = store is InMemorySharedStore ? FileManager.default.temporaryDirectory
            : FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)
        guard let folder = base?.appendingPathComponent("Library/Application Support/KeyboardTapOwners"),
              abs(request.createdAt.timeIntervalSinceNow) < 86_400 else { return false }
        guard take(request.id, directory: folder) else { return false }
        cleanup.async {
            guard Date().timeIntervalSince(lastCleanup) >= 3_600 else { return }
            lastCleanup = Date()
            if let markers = try? FileManager.default.contentsOfDirectory(at: folder,
                    includingPropertiesForKeys: [.creationDateKey]) {
                for marker in markers where marker.lastPathComponent != request.id.uuidString {
                    if let date = try? marker.resourceValues(forKeys: [.creationDateKey]).creationDate,
                       date.timeIntervalSinceNow < -172_800 { try? FileManager.default.removeItem(at: marker) }
                }
            }
        }
        return true
    }
}
