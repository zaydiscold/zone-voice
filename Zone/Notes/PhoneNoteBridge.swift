// by zayd/cold @ zayd.wtf

import Foundation
import notify
import WatchConnectivity
import ZoneCore

/// The paired-phone receiver. Root lifecycle configures its importer against NotesStore's
/// idempotent importBackup. Only that importer's successful return permits a phone receipt.
@MainActor
final class PhoneNoteBridge: NSObject, WCSessionDelegate {
    static let shared = PhoneNoteBridge()
    private var importer: ((CompanionNoteEnvelope) throws -> Void)?
    private var exporter: (() throws -> [CompanionShareItem])?
    private var messagesURL: URL?
    private var cacheGeneration = 0
    private var observer: NSObjectProtocol?
    private var pending: [CompanionNoteEnvelope] = []
    private var pendingURL: URL?
    private var canWritePending = true
    private(set) var lastError: String?

    func start(importNote: @escaping (CompanionNoteEnvelope) throws -> Void,
               exportNotes: @escaping () throws -> [CompanionShareItem]) {
        if let url = CompanionShareCache.url, FileManager.default.fileExists(atPath: url.path) {
            do { try CompanionShareCache.excludeFromBackup(at: url) }
            catch { lastError = "Could not exclude recent Messages text from iPhone backups." }
        }
        importer = importNote
        observeMessages(at: CompanionShareCache.url, exportNotes: exportNotes)
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
            let url = support.appendingPathComponent("incoming-watch-notes.json")
            pendingURL = url
            if FileManager.default.fileExists(atPath: url.path) {
                pending = try JSONDecoder().decode([CompanionNoteEnvelope].self, from: Data(contentsOf: url))
                for note in pending { try note.validate() }
            }
        } catch {
            canWritePending = false
            lastError = "Queued Watch notes could not be read. Existing files were kept."
        }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        processPending()
    }

    func observeMessages(at url: URL?, exportNotes: @escaping () throws -> [CompanionShareItem]) {
        exporter = exportNotes
        messagesURL = url
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: Notification.Name("ZoneLibraryDidChange"),
                                                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scheduleCacheRefresh()
                }
            }
        }
    }

    private func scheduleCacheRefresh() {
        cacheGeneration &+= 1
        let generation = cacheGeneration
        Task { @MainActor in
            guard generation == cacheGeneration else { return }
            publishCache()
        }
    }

    func clearMessagesCache(at url: URL) throws {
        cacheGeneration &+= 1
        try Self.clearCache(at: url)
    }

    func publishAccent(_ accent: AccentChoice) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isWatchAppInstalled else { return }
        var context = session.applicationContext
        let cutoff = UserDefaults.standard.object(forKey: cutoffKey) as? Date
        guard context[AccentChoice.defaultsKey] as? String != accent.rawValue ||
                context["eraseNotesThrough"] as? Date != cutoff else { return }
        context[AccentChoice.defaultsKey] = accent.rawValue
        context["eraseNotesThrough"] = cutoff
        do {
            try session.updateApplicationContext(context)
        } catch {
            ZoneLog.coordinator.error("Could not deliver accent to Watch: \(error.localizedDescription, privacy: .public)")
        }
    }

    private let cutoffKey = "zone.watchNotesErasedThrough"

    /// Read the file itself. A failed startup read leaves an empty in-memory list which
    /// must never replace newer notes still waiting in the inbox on disk.
    nonisolated static func clearInbox(at url: URL, through cutoff: Date) throws -> [CompanionNoteEnvelope] {
        let current: [CompanionNoteEnvelope]
        do { current = try JSONDecoder().decode([CompanionNoteEnvelope].self, from: Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { current = [] }
        for note in current { try note.validate() }
        let remaining = current.filter { $0.createdAt > cutoff }
        try JSONEncoder().encode(remaining).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return remaining
    }

    func eraseWatchNotes(through cutoff: Date) -> (inboxCleared: Bool, watchStatus: String?) {
        let cutoff = max(cutoff, UserDefaults.standard.object(forKey: cutoffKey) as? Date ?? .distantPast)
        UserDefaults.standard.set(cutoff, forKey: cutoffKey)
        var cleared = false
        if let url = pendingURL {
            do {
                pending = try Self.clearInbox(at: url, through: cutoff)
                canWritePending = true
                cleared = true
            } catch { canWritePending = false }
        }
        return (cleared, queueWatchErase(through: cutoff))
    }

    private func queueWatchErase(through cutoff: Date) -> String? {
        guard WCSession.isSupported() else { return nil }
        let session = WCSession.default
        guard session.activationState == .activated else { return "Watch deletion is queued for the next connection." }
        guard session.isPaired && session.isWatchAppInstalled else { return nil }
        var context = session.applicationContext
        context["eraseNotesThrough"] = cutoff
        do {
            try session.updateApplicationContext(context)
            return nil
        } catch { return "Watch deletion is queued. Zone will try again when the Watch connects." }
    }

    private func receive(_ note: CompanionNoteEnvelope) {
        guard canWritePending, let url = pendingURL else { return }
        do {
            if !pending.contains(where: { $0.id == note.id }) {
                let next = pending + [note]
                try JSONEncoder().encode(next).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                pending = next
            }
            processPending()
        } catch { lastError = "A Watch note could not be saved on this iPhone. The Watch retains its copy." }
    }

    private func processPending() {
        guard let importer, let url = pendingURL, canWritePending else { return }
        for note in pending {
            do {
                let cutoff = UserDefaults.standard.object(forKey: cutoffKey) as? Date ?? .distantPast
                if note.createdAt > cutoff {
                    try importer(note)
                }
                // The authoritative notes file has persisted before sending this receipt.
                if WCSession.default.activationState == .activated {
                    if note.createdAt > cutoff {
                        WCSession.default.transferUserInfo(CompanionNoteReceipt(noteID: note.id).userInfo)
                    }
                    let next = pending.filter { $0.id != note.id }
                    try JSONEncoder().encode(next).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    pending = next
                }
                lastError = nil
            } catch { lastError = "A Watch note is waiting. Free up space on your iPhone and open Zone again." }
        }
        publishCache()
    }

    /// One at a time and in order, so the newest request writes last.
    nonisolated private static let cacheQueue = DispatchQueue(label: "wtf.zayd.zone.share-cache", qos: .utility)

    nonisolated static func clearCache(at url: URL) throws {
        try cacheQueue.sync {
            do { try FileManager.default.removeItem(at: url) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { }
            notify_post(CompanionShareCache.clearedNotification)
        }
    }

    /// Rebuilds the list Messages shows. The notes come from the main actor's store; the history
    /// read (a whole-library decode), the encode and the write happen on `cacheQueue`. This runs at
    /// launch and after every saved dictation, and on the main thread it cost one full decode of
    /// the library each time, in front of the first frame and of a cold mic tap.
    func publishCache() {
        guard let exporter, let url = messagesURL else { return }
        let notes: [CompanionShareItem]
        do { notes = try exporter() } catch {
            lastError = "Messages could not load recent notes. Unlock your iPhone and open Zone again."
            return
        }
        Self.cacheQueue.async { [weak self] in
            let failure = Self.writeCache(notes: notes, to: url)
            guard let failure else { return }
            Task { @MainActor in self?.lastError = failure }
        }
    }

    /// Returns what went wrong, or nil.
    nonisolated private static func writeCache(notes: [CompanionShareItem], to url: URL) -> String? {
        do {
            var candidates = notes
            let history = TranscriptHistory.shared?.recentDictations(limit: 40) ?? []
            candidates += history.filter { $0.status != .recording && $0.status != .paused && $0.status != .note }
                .map { CompanionShareItem(id: $0.id, text: $0.text, createdAt: $0.createdAt, source: .dictation) }
            candidates.sort { $0.createdAt > $1.createdAt }
            var items: [CompanionShareItem] = []
            var bytes = 0
            var ids = Set<UUID>()
            for item in candidates where !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard items.count < CompanionShareCache.maximumItems,
                      bytes + item.text.utf8.count < CompanionShareCache.maximumBytes / 2 else { continue }
                guard ids.insert(item.id).inserted else { continue }
                items.append(item)
                bytes += item.text.utf8.count
            }
            if items.isEmpty {
                do { try FileManager.default.removeItem(at: url) }
                catch let error as CocoaError where error.code == .fileNoSuchFile { }
                notify_post(CompanionShareCache.clearedNotification)
                return nil
            }
            let cache = CompanionShareCache(updatedAt: Date(), items: items, omittedCount: max(0, candidates.count - items.count))
            try cache.write(to: url)
            return nil
        } catch { return "Messages could not load recent notes. Unlock your iPhone and open Zone again." }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let note = try? CompanionNoteEnvelope.receive(userInfo) else { return }
        Task { @MainActor in self.receive(note) }
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            if error != nil { self.lastError = "Zone could not reach your Watch. Bring it near your iPhone and open Zone again." }
            if activationState == .activated {
                self.publishAccent(AccentChoice.current)
                self.processPending()
            }
        }
    }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.publishAccent(AccentChoice.current) }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
