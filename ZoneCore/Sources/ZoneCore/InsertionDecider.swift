// by zayd/cold @ zayd.wtf

import Foundation

public enum InsertionDecision: Equatable, Sendable {
    /// Same field, same keyboard: insert without asking.
    case insertNow
    /// Show the text with an Insert button; the user decides where it goes.
    case offerInsert(reason: String)
    /// A previous attempt may or may not have landed; show the text with a Recover button.
    case offerRecovery
    case ignore(reason: String)
}

/// The one place that decides whether a result goes into the field automatically.
public enum InsertionDecider {
    /// Results older than this are never offered; the moment has passed.
    public static let maxAge: TimeInterval = 15 * 60

    public static func decide(
        result: DictationResult,
        request: DictationRequest?,
        ledger: InsertionLedger,
        currentInputSession: String?,
        currentContextBefore: String? = nil,
        ownsRequest: Bool,
        now: Date = Date()
    ) -> InsertionDecision {
        if let reason = unavailableReason(for: result, ledger: ledger, now: now) {
            return .ignore(reason: reason)
        }
        if ledger.claimedResultID == result.requestID {
            return .offerRecovery
        }
        // Only the keyboard instance that asked may insert on its own; anything else asks.
        guard ownsRequest else {
            return .offerInsert(reason: result.inputSession == nil && currentInputSession == nil
                                ? "came from another keyboard session" : "field changed")
        }
        if let session = result.inputSession {
            return session == currentInputSession ? .insertNow : .offerInsert(reason: "field changed")
        }
        // No session identifiers at all: fall back to the text before the cursor, which must
        // still end with what it ended with at request time.
        guard currentInputSession == nil else { return .offerInsert(reason: "field changed") }
        let current = currentContextBefore ?? ""
        guard let expected = request?.contextBefore, !expected.isEmpty else {
            return current.isEmpty ? .insertNow : .offerInsert(reason: "field changed")
        }
        return current.hasSuffix(expected) ? .insertNow : .offerInsert(reason: "field changed")
    }

    /// Checked again when an offered result is claimed. The offer can outlive the handoff.
    public static func unavailableReason(for result: DictationResult, ledger: InsertionLedger, now: Date) -> String? {
        if ledger.consumedResultID == result.requestID {
            return "already inserted"
        }
        if result.generation <= ledger.droppedGeneration {
            return "cancelled"
        }
        if result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "no speech"
        }
        if now.timeIntervalSince(result.createdAt) > maxAge {
            return "stale"
        }
        return nil
    }
}
