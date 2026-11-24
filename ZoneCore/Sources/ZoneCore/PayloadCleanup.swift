// by zayd/cold @ zayd.wtf

import Foundation

/// The App Group store holds two things a user typed or said: a result's text and the up to 64
/// characters before the cursor that a request carries. The privacy policy promises both are gone
/// once the text is inserted or dismissed, so they are cleared then, and anything a crash or an
/// abandoned request left behind is cleared the next time the keyboard looks. The ledger's
/// consumed id stays, so a cleared result can never be replayed.
public extension SharedStore {
    /// In-memory stores use these defaults. The App Group store commits each operation on disk.
    func admitRequest(_ next: DictationRequest, initialStatus: DictationStatus) -> Bool {
        guard initialStatus.requestID == next.id, initialStatus.generation == next.generation,
              request.map({ $0.id == next.id || next.tappedAt > $0.tappedAt }) != false else { return false }
        if result?.requestID != next.id { result = nil }
        request = next
        status = initialStatus
        return true
    }

    func resetHandoff(at date: Date) {
        request = nil
        status = nil
        result = nil
        control = nil
        ledger = InsertionLedger()
    }

    func publishFinal(_ final: DictationResult, for original: DictationRequest) -> Bool {
        guard final.requestID == original.id, request == nil || request?.id == original.id else { return false }
        request = original
        result = final
        return true
    }

    func transferRequestToKeyboard(_ original: DictationRequest) -> Bool {
        guard request?.id == original.id, request?.generation == original.generation else { return false }
        updateLedger(for: original.id) { $0.droppedGeneration = max($0.droppedGeneration, original.generation) }
        withdraw(original.id)
        return true
    }

    func withdraw(_ id: UUID) {
        if request?.id == id { request = nil }
        if status?.requestID == id { status = nil }
        clearPayloads(for: id)
    }

    func claimInsertion(_ id: UUID, explicitlyRequested: Bool, now: Date) -> Bool {
        guard let offered = result, offered.requestID == id else { return false }
        return claimInsertion(offered, explicitlyRequested: explicitlyRequested, now: now)
    }

    func claimInsertion(_ offered: DictationResult, explicitlyRequested: Bool, now: Date) -> Bool {
        var current = ledger
        guard current.claim(offered, current: result, explicit: explicitlyRequested, now: now) else { return false }
        ledger = current
        return true
    }

    func updateLedger(for id: UUID, _ change: (inout InsertionLedger) -> Void) {
        var current = ledger
        change(&current)
        ledger = current
    }

    func acknowledgeInsertion(_ id: UUID) {
        var current = ledger
        guard current.claimedResultID == id else { return }
        current.consume(id)
        ledger = current
        clearPayloads(for: id)
    }

    func dismissResult(_ offered: DictationResult) -> Bool {
        guard result == offered else { return false }
        ledger.consume(offered.requestID)
        clearPayloads(for: offered.requestID)
        return true
    }

    /// Clears the result text and the request's context for `requestID` after an insert or a dismiss.
    func clearPayloads(for requestID: UUID) {
        if result?.requestID == requestID {
            result = nil
        }
        if let request, request.id == requestID, request.contextBefore != nil {
            self.request = request.withoutContext()
        }
    }

    /// Clears payloads that can no longer be offered: a result already consumed or older than the
    /// offer window, and the context of any request older than that window.
    func purgeStalePayloads(now: Date = Date(), maxAge: TimeInterval = InsertionDecider.maxAge) {
        if let result,
           ledger.consumedResultID == result.requestID || now.timeIntervalSince(result.createdAt) > maxAge {
            self.result = nil
        }
        if let request, request.contextBefore != nil {
            let consumed = ledger.consumedResultID == request.id
            if consumed || now.timeIntervalSince(request.createdAt) > maxAge {
                self.request = request.withoutContext()
            }
        }
    }
}

extension DictationRequest {
    func withoutContext() -> DictationRequest {
        DictationRequest(id: id, generation: generation, createdAt: tappedAt,
                         inputSession: inputSession, contextBefore: nil, holdToTalk: holdToTalk, schema: schema)
    }
}
