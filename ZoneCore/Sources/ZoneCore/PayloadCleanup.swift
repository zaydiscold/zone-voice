// by zayd/cold @ zayd.wtf

import Foundation

/// The App Group store holds two things a user typed or said: a result's text and the up to 64
/// characters before the cursor that a request carries. The privacy policy promises both are gone
/// once the text is inserted or dismissed, so they are cleared then, and anything a crash or an
/// abandoned request left behind is cleared the next time the keyboard looks. The ledger's
/// consumed id stays, so a cleared result can never be replayed.
public extension SharedStore {
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
        DictationRequest(id: id, generation: generation, createdAt: createdAt,
                         inputSession: inputSession, contextBefore: nil, schema: schema)
    }
}
