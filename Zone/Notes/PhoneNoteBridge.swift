// by zayd/cold @ zayd.wtf

import Foundation
import WatchConnectivity
import ZoneCore

/// The paired-phone receiver. Root lifecycle configures its importer against NotesStore's
/// idempotent importBackup. Only that importer's successful return permits a phone receipt.
@MainActor
final class PhoneNoteBridge: NSObject, WCSessionDelegate {
    static let shared = PhoneNoteBridge()
    private var importer: ((CompanionNoteEnvelope) throws -> Void)?
    private var exporter: (() throws -> [CompanionShareItem])?
    private var observer: NSObjectProtocol?
    private var pending: [CompanionNoteEnvelope] = []
    private var pendingURL: URL?
    private var canWritePending = true
    private(set) var lastError: String?

    func start(importNote: @escaping (CompanionNoteEnvelope) throws -> Void,
               exportNotes: @escaping () throws -> [CompanionShareItem]) {
        importer = importNote
        exporter = exportNotes
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
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: Notification.Name("ZoneLibraryDidChange"),
                                                               object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.publishCache() }
            }
        }
        publishCache()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        processPending()
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
                try importer(note)
                // The authoritative notes file has persisted before sending this receipt.
                if WCSession.default.activationState == .activated {
                    WCSession.default.transferUserInfo(CompanionNoteReceipt(noteID: note.id).userInfo)
                    let next = pending.filter { $0.id != note.id }
                    try JSONEncoder().encode(next).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    pending = next
                }
                lastError = nil
            } catch { lastError = "A Watch note is waiting for storage on this iPhone. \(error.localizedDescription)" }
        }
        publishCache()
    }

    func publishCache() {
        guard let exporter, let url = CompanionShareCache.url else { return }
        do {
            var candidates = try exporter()
            let history = TranscriptHistory.shared?.recent(limit: 40) ?? []
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
            let cache = CompanionShareCache(updatedAt: Date(), items: items, omittedCount: max(0, candidates.count - items.count))
            let data = try JSONEncoder().encode(cache)
            guard data.count <= CompanionShareCache.maximumBytes else { throw CompanionNoteError.tooLarge }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { lastError = "Messages could not refresh its recent notes. \(error.localizedDescription)" }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let note = try? CompanionNoteEnvelope.receive(userInfo) else { return }
        Task { @MainActor in self.receive(note) }
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            if let error { self.lastError = error.localizedDescription }
            if activationState == .activated { self.processPending() }
        }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
