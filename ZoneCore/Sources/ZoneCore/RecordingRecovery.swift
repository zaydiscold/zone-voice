// by zayd/cold @ zayd.wtf

import Foundation

/// Reattach controls after iOS recreates a keyboard. This never grants automatic insertion.
public enum RecordingRecovery {
    /// How long a `.requested` or `.starting` status counts as current; older, nothing is serving
    /// it. The keyboard writes `.requested` just before it opens Zone.
    public static let requestWindow: TimeInterval = 10

    /// A recording status is written on transitions and can outlive the app. Check the
    /// independent microphone heartbeat before continuing to show it on a mounted keyboard.
    /// A held recording intentionally stops its microphone while an interruption lasts.
    public static func lostContact(status: DictationStatus, session: @autoclosure () -> SessionState?, now: Date) -> Bool {
        guard status.phase == .transcribing || (status.phase == .recording && status.paused != true),
              now.timeIntervalSince(status.updatedAt) > 30 else { return false }
        return session().map { abs(now.timeIntervalSince($0.heartbeat)) > 30 } ?? true
    }

    public static func activeRequest(request: DictationRequest?, status: DictationStatus?,
                                     ledger: InsertionLedger, session: SessionState?, now: Date) -> DictationRequest? {
        guard let request, let status, session?.isAlive(now: now) == true,
              request.schema == ZoneContract.schemaVersion,
              request.id == status.requestID, request.generation == status.generation,
              request.generation > ledger.droppedGeneration,
              request.id != ledger.consumedResultID else { return nil }
        switch status.phase {
        case .recording, .transcribing: return request
        case .requested, .starting:
            return now.timeIntervalSince(status.updatedAt) <= requestWindow ? request : nil
        default: return nil
        }
    }
}
