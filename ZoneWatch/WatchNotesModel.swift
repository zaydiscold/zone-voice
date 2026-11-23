// by zayd/cold @ zayd.wtf

import Combine
import Foundation
import WatchConnectivity

@MainActor
final class WatchNotesModel: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var notes: [WatchSavedNote] = []
    @Published private(set) var error: String?
    private var ledger: WatchNoteLedger?
    var canSave: Bool { ledger != nil }

    override init() {
        super.init()
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
            ledger = try WatchNoteLedger(url: support.appendingPathComponent("watch-notes.json"))
            notes = ledger?.notes ?? []
        } catch { self.error = "Saved notes could not be read. Existing files were kept. \(error.localizedDescription)" }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func save(_ text: String) -> Bool {
        guard let ledger else { return false }
        do {
            let note = try CompanionNoteEnvelope(text: text)
            try ledger.save(note)
            notes = ledger.notes
            error = nil
            queue(note)
            return true
        } catch { self.error = "Could not save. Your draft is still here. \(error.localizedDescription)"; return false }
    }

    func retry(_ id: UUID) {
        guard let saved = ledger?.notes.first(where: { $0.id == id }), saved.delivery != .receivedOnPhone else { return }
        queue(saved.note)
    }

    private func queue(_ note: CompanionNoteEnvelope) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        guard session.isCompanionAppInstalled else {
            error = "Saved on this Watch. Install and open Zone on your paired iPhone to receive notes."
            return
        }
        do {
            let alreadyQueued = session.outstandingUserInfoTransfers.contains {
                (try? CompanionNoteEnvelope.receive($0.userInfo).id) == note.id
            }
            if !alreadyQueued { session.transferUserInfo(try note.userInfo()) }
            try ledger?.mark(note.id, delivery: .queued)
            notes = ledger?.notes ?? []
            error = nil
        } catch { self.error = "Saved on this Watch. Transfer could not be queued. \(error.localizedDescription)" }
    }

    func status(_ saved: WatchSavedNote) -> String {
        switch saved.delivery {
        case .savedOnWatch: "Saved on Watch"
        case .queued: "Saved on Watch · waiting for iPhone"
        case .receivedOnPhone: "Received on iPhone"
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            if let error { self.error = "Saved notes are on this Watch. \(error.localizedDescription)" }
            guard activationState == .activated else { return }
            for saved in self.notes where saved.delivery != .receivedOnPhone { self.queue(saved.note) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let receipt = CompanionNoteReceipt(userInfo) else { return }
        Task { @MainActor in
            guard let ledger = self.ledger else { return }
            do {
                try ledger.mark(receipt.noteID, delivery: .receivedOnPhone)
                self.notes = ledger.notes
                self.error = nil
            } catch { self.error = "Your note is on iPhone, but this Watch could not save the receipt. Retry later." }
        }
    }

    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        guard let error else { return } // Transport completion is not a persisted-phone receipt.
        Task { @MainActor in self.error = "Saved on this Watch. Transfer will need another try. \(error.localizedDescription)" }
    }
}
