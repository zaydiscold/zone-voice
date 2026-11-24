// by zayd/cold @ zayd.wtf

import Foundation

/// The cold path: no session was alive, so the keyboard wrote a request and its `requested`
/// status, then opened Zone. iOS usually starts the process about 270 ms later, and that new
/// process finds the status the tap just wrote.
public enum ColdStart {
    /// How long a `requested` status is still the tap a launch was opened to serve. The
    /// keyboard reattaches to a `requested` status for the same span (`RecordingRecovery`), and
    /// the slowest launch the phone's journal shows for its own tap (November 5 to 10) came 5 s
    /// after it, so this keeps twice that.
    public static let requestWindow = RecordingRecovery.requestWindow

    /// Whether the keyboard's second way of opening Zone should still run for a tap.
    ///
    /// The keyboard asks iOS to open Zone, and asks again another way when iOS reports the
    /// first ask failed. Zayd's phone, November 9 to 20: 14 of 90 taps that opened Zone brought
    /// it to the front twice, the second time 0.6 s after he was back in his app, with one tap
    /// and Zone already recording. Once Zone is recording or writing out this very request,
    /// the tap has been served and another open could only pull the person out of their app.
    public static func secondOpenStillNeeded(status: DictationStatus?, requestID: UUID?) -> Bool {
        guard let status, let requestID, status.requestID == requestID else { return true }
        switch status.phase {
        case .recording, .transcribing: return false
        case .requested, .starting, .needsApp, .ready, .cancelled, .failed, .interrupted: return true
        }
    }

    /// Whether a new app process must mark the stored status interrupted. Only the app writes
    /// `starting`, `recording` and `transcribing`, so a new process finding one knows the
    /// process that wrote it is gone. `requested` is the keyboard's: it is left alone when it
    /// is the stored request's own, recent and not dropped, because that is the tap this launch
    /// exists to serve. Until 2026-11-10 it was terminalized too, and 45 of 50 cold taps showed
    /// "The previous recording was interrupted" a moment after the tap.
    public static func launchTerminalizes(status: DictationStatus?, request: DictationRequest?,
                                          ledger: InsertionLedger, now: Date) -> Bool {
        guard let status else { return false }
        switch status.phase {
        case .starting, .recording, .transcribing:
            return true
        case .requested:
            return !isLiveTap(status: status, request: request, ledger: ledger, now: now)
        case .ready, .cancelled, .failed, .interrupted, .needsApp:
            return false
        }
    }

    /// A `requested` status that matches the stored request, is within `requestWindow` (either
    /// way, so a clock moved back does not keep it forever) and has not been dropped.
    static func isLiveTap(status: DictationStatus, request: DictationRequest?, ledger: InsertionLedger, now: Date) -> Bool {
        guard let request, request.id == status.requestID, request.generation == status.generation,
              request.generation > ledger.droppedGeneration else { return false }
        let age = now.timeIntervalSince(status.updatedAt)
        return age <= requestWindow && age >= -requestWindow
    }

    /// Whether a keyboard that opened Zone for `ownedID`, and is on screen again, should stop
    /// waiting: the tap is older than `requestWindow` and Zone never acknowledged it (no status of
    /// its own, still `requested`, or only `needsApp`). Without this the strip kept saying "Finish
    /// in Zone, then come back", with no mic key, after a launch that never reached the screen.
    public static func keyboardGivesUp(ownedID: UUID, request: DictationRequest?, status: DictationStatus?, now: Date) -> Bool {
        guard let request, request.id == ownedID,
              now.timeIntervalSince(request.createdAt) > requestWindow else { return false }
        guard let status, status.requestID == ownedID else { return true }
        return status.phase == .requested || status.phase == .needsApp
    }
}
