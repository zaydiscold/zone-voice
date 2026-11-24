// by zayd/cold @ zayd.wtf

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// How a clip was sent (Zone Link protocol, "Clips").
public enum LinkClipSource: String, Codable, Sendable, CaseIterable {
    /// What was on the phone's clipboard.
    case clipboard
    /// Shared from another app.
    case share
    /// The Send to Computer shortcut.
    case shortcut
    /// Typed into Zone.
    case typed
}

/// A piece of text the person chose to send to their computers: a paste bin, phone to computer.
///
/// A clip is not part of the library. It waits here until every computer it was meant for has
/// acknowledged it, then stays a while as a line in the Sent list, and deleting it is never
/// sent anywhere.
public struct LinkClip: Codable, Equatable, Identifiable, Sendable {
    /// The most a clip may hold, in bytes of UTF-8 (the protocol's 256 kB).
    public static let maxBytes = 256_000
    /// How much of a clip stays on the phone for the Sent list once every computer has it.
    public static let previewCharacters = 160

    public var id: UUID
    /// The whole text while a computer is still waiting for it. Once every computer has it,
    /// only the first `previewCharacters`: a sent clip is the computer's to keep, not the phone's.
    public var text: String
    public var source: LinkClipSource
    public var createdAt: Date
    /// The size of what was sent, in bytes of UTF-8.
    public var bytes: Int
    /// Endpoint ids of the computers that have not acknowledged it yet.
    public var waiting: [String]
    /// Endpoint ids of the computers that acknowledged it.
    public var sentTo: [String]
    /// When the last computer acknowledged it.
    public var sentAt: Date?

    public init(id: UUID = UUID(), text: String, source: LinkClipSource, createdAt: Date = Date(), waiting: [String]) {
        self.id = id
        self.text = text
        self.source = source
        self.createdAt = createdAt
        self.bytes = text.utf8.count
        self.waiting = waiting
        self.sentTo = []
    }

    /// True once no computer is waiting for it.
    public var isSent: Bool { waiting.isEmpty }

    /// The clip as the computer stores it: an ordinary item of kind `clip`.
    public var item: LinkItem {
        let at = LinkEncoding.seconds(createdAt)
        return LinkItem(id: id.uuidString, kind: .clip, source: source.rawValue, createdAt: at, updatedAt: at,
                        text: text).stamped()
    }

    /// One line for the Sent list: the start of the text, on one line.
    public var preview: String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return line.count > Self.previewCharacters ? String(line.prefix(Self.previewCharacters)) + "…" : line
    }
}

public enum LinkClipFailure: Error, Equatable {
    /// Nothing but spaces and line breaks.
    case empty
    /// More than `LinkClip.maxBytes`.
    case tooLarge(bytes: Int)
    /// No paired computer has sending switched on.
    case noComputer
    /// The outbox could not be written (the iPhone has not been unlocked since it started, or
    /// it is full). Nothing was queued, so nothing is sent.
    case notSaved

    /// What the person is told. Plain words.
    public var plainMessage: String {
        switch self {
        case .empty: return "Nothing to send."
        case .tooLarge: return "Too large for one clip (max \(LinkClip.maxBytes / 1000) kB)."
        case .noComputer: return "No active computer. Enable Send to this computer in Settings → Computers."
        case .notSaved: return "Zone could not save that, so nothing was sent. Unlock this iPhone and try again."
        }
    }
}

/// Why the outbox file could not be read, rewritten or erased. A missing file is never one of
/// these: it is an empty outbox.
public enum LinkClipPersistenceError: Error, Equatable, Sendable {
    /// The file is there but could not be opened or read (the iPhone has not been unlocked
    /// since it started, or access was denied). What it holds is unknown.
    case unreadable
    /// The file was read but is not a list of clips.
    case malformed
    /// Something other than an ordinary file is where the outbox belongs (a symbolic link, a
    /// folder). Zone neither follows nor removes it.
    case notAFile
    /// The file could be neither replaced, removed nor emptied.
    case notWritten
}

/// What taking every clip off the phone did (`LinkClipOutbox.removeAll`).
public struct LinkClipRemoval: Equatable, Sendable {
    /// Clips that were still waiting for at least one computer. None of them is sent now.
    /// Zero when `known` is false.
    public var withdrawn: Int
    /// Clips at least one computer had acknowledged. Their copies stay on those computers:
    /// nothing is ever sent to take one back. Zero when `known` is false.
    public var delivered: Int
    /// True when no clip text is left in the outbox file (it is gone, or emptied in place).
    /// False when it could be neither removed nor emptied, or could not even be looked at:
    /// nothing in it is ever sent or listed (`LinkClipOutbox` keeps an erase pending apart
    /// from the file, and erases it before anything new is queued), but its text is on disk.
    public var erased: Bool
    /// False when the file could not be read first, so the counts are unknown: some of its
    /// clips may have been waiting, and some may already be on a computer.
    public var known: Bool
    /// Why the file was not erased, or why it could not be read. Nil when it was read and erased.
    public var failure: LinkClipPersistenceError?

    public init(withdrawn: Int, delivered: Int, erased: Bool, known: Bool = true,
                failure: LinkClipPersistenceError? = nil) {
        self.withdrawn = withdrawn
        self.delivered = delivered
        self.erased = erased
        self.known = known
        self.failure = failure
    }
}

/// The clips waiting for a computer, and the last few that were sent. One file, `clips.json`,
/// beside the rest of what Zone Link keeps. Safe to use from any thread.
///
/// Taking a clip off the phone (`remove`, `removeAll`) fails closed: when the file cannot be
/// rewritten, the clip's id is remembered apart from it (in memory, and in `defaults` when
/// given), and a withdrawn clip is never listed, never pending and never sent, even after a
/// relaunch. A session that planned a clip before it was withdrawn asks again just before each
/// frame goes (`LinkComputerSync.stillToSend`), so it is not sent either. A frame already
/// written to the connection, and a clip a computer acknowledged, cannot be taken back.
///
/// Taking every clip off (`removeAll`) does not depend on reading the file: it records an
/// erase as pending first (in memory, and in `defaults` when given), and while one is pending
/// nothing in the file is listed, pending or sent, whatever it holds, even clips whose ids
/// were never known because the file could not be read. The erase is retried before any
/// change, and a new clip is queued only once it succeeds. A file that cannot be read is never
/// overwritten, a symbolic link is never followed, and a folder is never removed.
public final class LinkClipOutbox: @unchecked Sendable {
    /// How many sent clips are kept for the Sent list. Waiting clips are always kept.
    public static let sentKept = 20
    /// Where the ids of withdrawn clips are kept when the outbox file cannot be rewritten.
    /// Ids only, never text.
    public static let withdrawnKey = "zone.link.clipsWithdrawn"
    /// Set while a Delete everything has not yet erased the outbox file. No text, a flag.
    public static let erasePendingKey = "zone.link.clipsErasePending"
    private static let forgottenKey = "zone.link.clipRecipientsToRemove"

    public let fileURL: URL
    private let lock = NSLock()
    private let defaults: UserDefaults?
    /// Clips taken off the phone whose text the file may still hold. Guarded by `lock`.
    private var withdrawn: Set<UUID>
    /// True while everything in the file is withdrawn and the file is still to be erased.
    /// Guarded by `lock`.
    private var erasePending: Bool
    private var forgotten: [String: Date]

    /// - Parameter defaults: where withdrawn ids and a pending erase outlive the process when
    ///   the file cannot be rewritten. The app passes `.standard`; nil keeps them in memory only.
    public init(fileURL: URL, defaults: UserDefaults? = nil) {
        self.fileURL = fileURL
        self.defaults = defaults
        withdrawn = Set((defaults?.stringArray(forKey: Self.withdrawnKey) ?? []).compactMap(UUID.init(uuidString:)))
        erasePending = defaults?.bool(forKey: Self.erasePendingKey) ?? false
        forgotten = defaults?.dictionary(forKey: Self.forgottenKey) as? [String: Date] ?? [:]
    }

    /// Checks a text before it is queued: not empty, not over the limit. The text itself is
    /// sent exactly as given.
    public static func check(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LinkClipFailure.empty }
        let bytes = text.utf8.count
        guard bytes <= LinkClip.maxBytes else { throw LinkClipFailure.tooLarge(bytes: bytes) }
    }

    /// Queues a clip for these computers. It stays until each of them acknowledges it.
    /// Returns only once the clip is on disk: throws `LinkClipFailure.notSaved` otherwise, and
    /// then nothing is queued, so a caller never says a clip is on its way when it is not.
    @discardableResult
    public func add(_ text: String, source: LinkClipSource, to endpointIDs: [String], at date: Date = Date(),
                    id: UUID = UUID()) throws -> LinkClip {
        try Self.check(text)
        var targets: [String] = []
        for endpointID in endpointIDs where !targets.contains(endpointID) { targets.append(endpointID) }
        guard !targets.isEmpty else { throw LinkClipFailure.noComputer }
        let clip = LinkClip(id: id, text: text, source: source, createdAt: date, waiting: targets)
        // Also refused when the file cannot be read (its clips are not overwritten) or a
        // pending erase still fails (nothing new joins text the person deleted).
        guard change({ $0.append(clip) }) == nil else { throw LinkClipFailure.notSaved }
        return clip
    }

    /// Every clip, newest first: the Sent list.
    public func all() -> [LinkClip] {
        lock.lock(); defer { lock.unlock() }
        return read().sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
    }

    public func clip(_ id: UUID) -> LinkClip? {
        lock.lock(); defer { lock.unlock() }
        return read().first { $0.id == id }
    }

    /// The clips one computer is still to be sent, oldest first, as items.
    public func pending(for endpointID: String) -> [LinkItem] {
        lock.lock(); defer { lock.unlock() }
        return read().filter { $0.waiting.contains(endpointID) }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
            .map(\.item)
    }

    /// True while any clip waits for this computer.
    public func hasPending(for endpointID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return read().contains { $0.waiting.contains(endpointID) }
    }

    /// The ids (as item ids) of the clips still waiting for this computer, read now. A session
    /// checks against this just before each frame goes, so a clip withdrawn after it planned
    /// is left out.
    public func waitingIDs(for endpointID: String) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(read().filter { $0.waiting.contains(endpointID) }.map(\.id.uuidString))
    }

    /// A computer acknowledged these items (or the person said a Flash arrived): the clips
    /// among them stop waiting for it. Items of other kinds are ignored.
    public func acknowledge(_ items: [LinkItem], by endpointID: String, at date: Date = Date()) {
        let ids = Set(items.filter { $0.kind == .clip }.compactMap { UUID(uuidString: $0.id) })
        guard !ids.isEmpty else { return }
        change { clips in
            for index in clips.indices where ids.contains(clips[index].id) && clips[index].waiting.contains(endpointID) {
                clips[index].waiting.removeAll { $0 == endpointID }
                clips[index].sentTo.append(endpointID)
                if clips[index].waiting.isEmpty { Self.settle(&clips[index], at: date) }
            }
        }
    }

    /// Takes a clip off the phone. Nothing is told to any computer: one that has it keeps it,
    /// and one still waiting for it never gets it, even when the file cannot be read or
    /// rewritten (its id is then remembered apart from the file). Returns why the file still
    /// holds it, or nil.
    @discardableResult
    public func remove(_ id: UUID) -> LinkClipPersistenceError? {
        change(withdrawingOnFailure: [id]) { $0.removeAll { $0.id == id } }
    }

    /// Takes every clip off the phone: the ones waiting and the Sent list. Nothing is told to
    /// any computer. One that acknowledged a clip keeps it; no clip still waiting is sent from
    /// now on, even when the file cannot be read, removed or emptied, and even after a relaunch.
    @discardableResult
    public func removeAll() -> LinkClipRemoval {
        lock.lock(); defer { lock.unlock() }
        // Counted before the erase is recorded. An erase already pending means the file's
        // clips were withdrawn (and counted) by an earlier call.
        let loaded: Result<[LinkClip], LinkClipPersistenceError> = erasePending ? .success([]) : load()
        // Recorded before anything is touched, so an interrupted or refused erase still hides
        // every clip in the file, including ones whose ids could not be read.
        setErasePending(true)
        let failure = erase()
        let clips = ((try? loaded.get()) ?? []).filter { !withdrawn.contains($0.id) }
        if failure == nil {
            setErasePending(false)
            setWithdrawn([])
            clearForgotten()
        } else {
            withdraw(clips.map(\.id))
        }
        var readFailure: LinkClipPersistenceError?
        if case .failure(let error) = loaded { readFailure = error }
        return LinkClipRemoval(withdrawn: clips.filter { !$0.isSent }.count,
                               delivered: clips.filter { !$0.sentTo.isEmpty }.count,
                               erased: failure == nil, known: readFailure == nil, failure: failure ?? readFailure)
    }

    /// Clears the Sent list. Clips still waiting for a computer stay. Returns why the file
    /// could not be changed, or nil. A file that cannot be read is left as it is: which of its
    /// clips were sent is unknown, and the waiting ones must not be lost.
    @discardableResult
    public func removeSent() -> LinkClipPersistenceError? {
        change { $0.removeAll(where: \.isSent) }
    }

    /// A computer was forgotten: nothing waits for it any more. A clip that waited only for
    /// it, and reached no other computer, is dropped.
    public func forget(_ endpointID: String, at date: Date = Date()) {
        change(forgetting: (endpointID, date)) { _ in }
    }

    private func clearForgotten() {
        guard !forgotten.isEmpty else { return }
        forgotten.removeAll()
        defaults?.removeObject(forKey: Self.forgottenKey)
    }

    private func retained(_ loaded: [LinkClip]) -> [LinkClip] {
        guard !withdrawn.isEmpty || !forgotten.isEmpty else { return loaded }
        return loaded.compactMap { clip in
            guard !withdrawn.contains(clip.id) else { return nil }
            guard let date = clip.waiting.compactMap({ forgotten[$0] }).max() else { return clip }
            var kept = clip
            kept.waiting.removeAll { forgotten[$0] != nil }
            if kept.waiting.isEmpty {
                guard !kept.sentTo.isEmpty else { return nil }
                Self.settle(&kept, at: date)
            }
            return kept
        }
    }

    /// Takes every clip off the phone (`removeAll`): forgetting the last computer.
    public func clear() {
        removeAll()
    }

    /// Every computer has it: keep the time and a short preview, not the whole text.
    private static func settle(_ clip: inout LinkClip, at date: Date) {
        clip.sentAt = date
        if clip.text.count > LinkClip.previewCharacters {
            clip.text = String(clip.text.prefix(LinkClip.previewCharacters))
        }
    }

    /// Reads, changes and writes the outbox in one step. Returns why the change was not
    /// written, or nil. Even then, a clip the change took away stays away (`withdraw`): a
    /// clip the person removed is never sent because the file refused the write. A pending
    /// erase is done first, and when it fails nothing is changed. A file that cannot be read
    /// is never overwritten (that would drop the clips it holds): the change is refused, and
    /// `withdrawingOnFailure` names the clips it was taking away.
    @discardableResult
    private func change(withdrawingOnFailure ids: [UUID] = [],
                        forgetting: (String, Date)? = nil,
                        _ body: (inout [LinkClip]) -> Void) -> LinkClipPersistenceError? {
        lock.lock(); defer { lock.unlock() }
        if let (endpoint, date) = forgetting {
            forgotten[endpoint] = date
            defaults?.set(forgotten, forKey: Self.forgottenKey)
        }
        if erasePending {
            if let failure = erase() {
                withdraw(ids)
                return failure
            }
            setErasePending(false)
            setWithdrawn([])
            clearForgotten()
        }
        var clips: [LinkClip]
        switch load() {
        case .success(let loaded): clips = retained(loaded)
        case .failure(let failure):
            withdraw(ids)
            return failure
        }
        let before = clips
        body(&clips)
        // The newest `sentKept` sent clips stay; older sent ones go. Waiting ones always stay.
        let sent = clips.filter(\.isSent).sorted { ($0.sentAt ?? $0.createdAt) > ($1.sentAt ?? $1.createdAt) }
        if sent.count > Self.sentKept {
            let dropped = Set(sent.dropFirst(Self.sentKept).map(\.id))
            clips.removeAll { dropped.contains($0.id) }
        }
        guard clips != before || !forgotten.isEmpty else { return nil }
        if let failure = write(clips) {
            let kept = Set(clips.map(\.id))
            withdraw(before.map(\.id).filter { !kept.contains($0) })
            return failure
        }
        // Whatever the file held for a withdrawn clip was just replaced.
        setWithdrawn([])
        clearForgotten()
        return nil
    }

    /// Call with the lock held, after `load` succeeded. Nil once the file holds exactly
    /// `clips` (or is gone when there are none).
    private func write(_ clips: [LinkClip]) -> LinkClipPersistenceError? {
        if clips.isEmpty { return erase() }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // An atomic write renames a new file over the old name: it never writes through a link.
        guard let data = try? JSONEncoder().encode(clips),
              (try? data.write(to: fileURL, options: LinkStore.writeOptions)) != nil else { return .notWritten }
        // A clip is often a code or a password, on its way to a computer and nothing more: out
        // of the iPhone's own backups, like History. An atomic write makes a new file, so this
        // is set again after every write.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = fileURL
        try? url.setResourceValues(values)
        return nil
    }

    /// Call with the lock held. Nil once no clip text is left under the outbox's name: nothing
    /// is there, or the ordinary file that was there is unlinked or emptied in place. Never
    /// follows a symbolic link, never removes a folder, and never claims an erase for a path it
    /// was refused a look at.
    private func erase() -> LinkClipPersistenceError? {
        let path = fileURL.path
        var info = stat()
        if lstat(path, &info) != 0 {
            return errno == ENOENT || errno == ENOTDIR ? nil : .unreadable
        }
        guard info.st_mode & S_IFMT == S_IFREG else { return .notAFile }
        // `unlink` refuses folders, and on a link removes the link alone.
        if unlink(path) == 0 || errno == ENOENT { return nil }
        // A folder that refuses to drop the file may still let it be emptied in place.
        let fd = open(path, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            switch errno {
            case ENOENT: return nil
            case ELOOP: return .notAFile
            default: return .notWritten
            }
        }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG else { return .notAFile }
        guard ftruncate(fd, 0) == 0 else { return .notWritten }
        _ = fsync(fd)
        return nil
    }

    /// Call with the lock held. The clips in the file, withdrawn ones included. A missing file
    /// (or an emptied one) is an empty outbox; anything that could not be read is a failure,
    /// never "no clips", so it is not overwritten as though it were empty.
    private func load() -> Result<[LinkClip], LinkClipPersistenceError> {
        let fd = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            switch errno {
            case ENOENT, ENOTDIR: return .success([])
            case ELOOP: return .failure(.notAFile)
            default: return .failure(.unreadable)
            }
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .failure(.unreadable) }
        guard info.st_mode & S_IFMT == S_IFREG else { return .failure(.notAFile) }
        let data: Data
        do { data = try handle.readToEnd() ?? Data() } catch { return .failure(.unreadable) }
        guard !data.isEmpty else { return .success([]) }
        guard let clips = try? JSONDecoder().decode([LinkClip].self, from: data) else { return .failure(.malformed) }
        return .success(clips)
    }

    /// Call with the lock held.
    private func setErasePending(_ pending: Bool) {
        guard pending != erasePending else { return }
        erasePending = pending
        if pending {
            defaults?.set(true, forKey: Self.erasePendingKey)
        } else {
            defaults?.removeObject(forKey: Self.erasePendingKey)
        }
    }

    /// Call with the lock held. These clips are never read back from the file again.
    private func withdraw(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        setWithdrawn(withdrawn.union(ids))
    }

    /// Call with the lock held.
    private func setWithdrawn(_ ids: Set<UUID>) {
        guard ids != withdrawn else { return }
        withdrawn = ids
        if ids.isEmpty {
            defaults?.removeObject(forKey: Self.withdrawnKey)
        } else {
            defaults?.set(ids.map(\.uuidString).sorted(), forKey: Self.withdrawnKey)
        }
    }

    /// Call with the lock held. Withdrawn clips are left out, whatever the file says; nothing
    /// is listed while an erase is pending or the file cannot be read.
    private func read() -> [LinkClip] {
        guard !erasePending, let clips = try? load().get() else { return [] }
        return retained(clips)
    }
}

/// What the Sent list and the shortcut say about a clip.
public enum LinkClipCopy {
    public static let row = "Send text to your computer"
    public static let rowNote = "Send a link, code, or clipboard snippet straight to your computer."
    public static let sent = "Sent"

    /// "Sent", or "Waiting for Studio Mac", or both when one computer has it and another does
    /// not. `names` maps endpoint ids to computer names.
    public static func status(_ clip: LinkClip, names: [String: String]) -> String {
        let waiting = list(clip.waiting.map { names[$0] ?? "the computer" })
        guard !clip.waiting.isEmpty else { return sent }
        guard !clip.sentTo.isEmpty else { return "Waiting for \(waiting)" }
        return "Sent to \(list(clip.sentTo.map { names[$0] ?? "the computer" })). Waiting for \(waiting)"
    }

    /// One sentence for the shortcut's answer and the sheet, after a send was tried.
    public static func outcome(_ clip: LinkClip, names: [String: String]) -> String {
        if clip.isSent {
            return "Sent to \(list(clip.sentTo.map { names[$0] ?? "the computer" }))."
        }
        let waiting = list(clip.waiting.map { names[$0] ?? "the computer" })
        let rest = "Zone could not reach \(waiting) just now. It is saved and goes with the next sync."
        guard !clip.sentTo.isEmpty else { return rest }
        return "Sent to \(list(clip.sentTo.map { names[$0] ?? "the computer" })). \(rest)"
    }

    /// While a clip that is saved waits for its first answers. Never "Sent": that is said only
    /// once a computer has acknowledged it (`outcome`).
    public static let sending = "Sending…"

    /// The answer when the clip was taken off the phone before every computer had it (the
    /// person removed it, or chose Delete everything). It does not say the clip is gone from a
    /// computer: one that acknowledged it keeps it.
    public static let removed = "Removed from Zone before every computer confirmed it. A computer that already received it keeps its copy."

    /// Added to Delete everything's confirmation while there are clips: what it does to them.
    /// Nil when there are none. It never promises to reach a computer.
    public static func deleteEverythingNote(waiting: Int, delivered: Int) -> String? {
        var parts: [String] = []
        if waiting > 0 {
            parts.append(waiting == 1 ? "Cancels the waiting send. A copy already on its way can still arrive."
                                      : "Cancels \(waiting) waiting sends. A copy already on its way can still arrive.")
        }
        if delivered > 0 {
            parts.append("Text your computer already received stays there.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Added after Delete everything when the outbox file could not be erased, or could not be
    /// read first (so what it held is unknown). Nil when it was read and erased. Never says what
    /// a computer has: one that received a clip keeps it, and an unread file cannot tell which.
    public static func deletedEverything(_ removal: LinkClipRemoval) -> String? {
        switch (removal.erased, removal.known) {
        case (true, true):
            return nil
        case (true, false):
            return "Zone erased the text waiting for your computer without being able to read it first, so it can't tell whether your computer already received any. Text your computer already received stays there."
        case (false, true):
            return "Zone could not erase the text waiting for your computer from this iPhone's storage. It won't be sent or listed; try Delete everything again later to erase it."
        case (false, false):
            return "Zone could neither read nor erase the text waiting for your computer on this iPhone. None of it will be sent or listed from now on; unlock this iPhone and try Delete everything again to erase it. Text your computer already received stays there."
        }
    }

    /// "Studio Mac", "Studio Mac and ThinkPad", "A, B and C".
    public static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return "the computer"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }
}
