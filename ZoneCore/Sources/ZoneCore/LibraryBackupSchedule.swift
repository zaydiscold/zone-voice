// by zayd/cold @ zayd.wtf

import Foundation

/// Decides when the automatic folder backup writes. A save rebuilds the whole library and
/// rewrites it into a folder that is usually in iCloud Drive, so it runs only when something
/// changed since the last good save, when the last attempt failed, or when the person asks.
///
/// Changes arrive two ways: `noteChange()` for in-process events (a note or dictation saved,
/// a meeting ending), and a `LibraryBackupSignature` of the source files, which also catches
/// writes from the keyboard process and meeting edits that post nothing. The first check after
/// launch always saves.
///
/// Automatic saves are at most one per `minimumInterval` (5 minutes). The manifest and its text
/// export hold the whole library, so saving after each of a few hundred dictations a day wrote
/// gigabytes (iOS flagged Zone for disk writes nearly every day). The trade-off: the backup
/// folder can lag the phone by up to 5 minutes while changes keep coming. The library on the
/// phone is saved as before; only its copy in the folder waits. The first change after a quiet
/// period still saves after the short debounce, a pending change is never dropped (it saves
/// when the interval ends), and a meeting ending or Back up now saves right away.
public struct LibraryBackupSchedule: Equatable, Sendable {
    public static let defaultMinimumInterval: TimeInterval = 5 * 60

    public enum Kind: Equatable, Sendable {
        /// Back up now, or a newly chosen folder: always a real save, never delayed.
        case manual
        /// The periodic check and debounced changes: skipped while clean, spaced by the interval.
        case automatic
    }

    public enum Decision: Equatable, Sendable {
        case save
        /// Nothing changed and the last attempt succeeded.
        case skip
        /// Something is pending, but the interval since the last automatic save has not passed.
        case wait(until: Date)
    }

    public let minimumInterval: TimeInterval
    /// Bumped by every change. Starts one ahead of `savedChange`, so launch counts as a change.
    public private(set) var change = 1
    public private(set) var savedChange = 0
    /// The latest change that should not wait for the interval (a meeting ended).
    public private(set) var promptChange = 0
    public private(set) var savedSignature: Int?
    public private(set) var lastAttemptFailed = false
    /// When the last save that wrote (or tried to write) started, manual ones included.
    public private(set) var lastSaveStarted: Date?

    public init(minimumInterval: TimeInterval = LibraryBackupSchedule.defaultMinimumInterval) {
        self.minimumInterval = minimumInterval
    }

    public var isDirty: Bool { savedChange < change }

    /// Records a change and returns its token. A debounced save passes the token back to
    /// `isLatest(_:)` so a burst of changes produces one save, after the last of them.
    /// `prompt` changes (a meeting's audio) skip the interval.
    @discardableResult
    public mutating func noteChange(prompt: Bool = false) -> Int {
        change += 1
        if prompt { promptChange = change }
        return change
    }

    public func isLatest(_ token: Int) -> Bool { token == change }

    public func decide(_ kind: Kind, signature: Int, now: Date) -> Decision {
        if kind == .manual { return .save }
        guard isDirty || lastAttemptFailed || signature != savedSignature else { return .skip }
        // A failed attempt waits for the interval even with a meeting pending, so a folder
        // that keeps failing is not rewritten every 30 seconds.
        if promptChange > savedChange && !lastAttemptFailed { return .save }
        if let last = lastSaveStarted, now.timeIntervalSince(last) < minimumInterval {
            return .wait(until: last.addingTimeInterval(minimumInterval))
        }
        return .save
    }

    /// Call when a save begins; the interval counts from here, so a slow or failed write
    /// cannot be retried in a tight loop.
    public mutating func started(at now: Date) { lastSaveStarted = now }

    /// `change` and `signature` are the values read when the save STARTED. A change that
    /// arrives while the save is running leaves the schedule dirty for the next check.
    public mutating func saved(through change: Int, signature: Int) {
        savedChange = max(savedChange, change)
        savedSignature = signature
        lastAttemptFailed = false
    }

    /// The next check retries even if nothing else changes, once the interval allows.
    public mutating func failed() { lastAttemptFailed = true }
}

/// A cheap fingerprint of the files a backup is built from: paths, sizes and modification
/// times, never contents. Read off the main thread; it only stats local files.
public enum LibraryBackupSignature {
    /// `sources` may be files or directories (read recursively). Missing ones count as empty.
    public static func of(_ sources: [URL]) -> Int {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var entries: [String] = []
        for source in sources {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
                entries.append("\(source.path)|missing")
                continue
            }
            let files: [URL]
            if isDirectory.boolValue {
                let walker = FileManager.default.enumerator(at: source, includingPropertiesForKeys: keys)
                files = walker?.compactMap { $0 as? URL } ?? []
            } else {
                files = [source]
            }
            for file in files {
                guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                let modified = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
                entries.append("\(file.path)|\(values.fileSize ?? -1)|\(modified)")
            }
        }
        var hasher = Hasher()
        for entry in entries.sorted() { hasher.combine(entry) }
        return hasher.finalize()
    }
}
