// by zayd/cold @ zayd.wtf

import Foundation

/// One cancellable piece of background work that many callers share, such as the speaker
/// model download: starting it again while it runs joins the running one, cancelling it is
/// immediate, and a caller waiting on it is never left waiting on work nobody will finish,
/// even when that work ignores cancellation.
///
/// Meeting mode used to download its speaker model only inside the first transcription, and
/// flipping "Label speakers" off and on during that download left the screen confused. With this,
/// the toggle starts or cancels the one download, Meetings starts it on appear, and a
/// transcription joins whatever download is current.
@MainActor
public final class SingleFlight {
    public enum Outcome: Equatable, Sendable {
        /// The work finished, or nothing was running.
        case done
        /// It was cancelled and nothing replaced it.
        case cancelled
    }

    private var task: Task<Void, Never>?
    /// Bumped on every start and cancel, so a finishing task only reports for its own run.
    private var generation = 0
    /// Waiters on the current run. `nil` tells a waiter the run was cancelled: look again.
    private var waiters: [CheckedContinuation<Result<Void, Error>?, Never>] = []

    public init() {}

    public var isRunning: Bool { task != nil }

    /// Starts `operation` unless it is already running. Returns true when it started now.
    /// `finished` runs on the main actor when this run ends by itself (not when cancelled).
    @discardableResult
    public func start(_ operation: @escaping @Sendable () async throws -> Void,
                      finished: (@MainActor (Result<Void, Error>) -> Void)? = nil) -> Bool {
        guard task == nil else { return false }
        generation += 1
        let mine = generation
        task = Task { [weak self] in
            let result: Result<Void, Error>
            do {
                try await operation()
                result = .success(())
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                guard let self, self.generation == mine else { return }
                self.task = nil
                let waiting = self.waiters
                self.waiters = []
                waiting.forEach { $0.resume(returning: result) }
                finished?(result)
            }
        }
        return true
    }

    /// Cancels the running work. Waiters are released at once.
    public func cancel() {
        guard let running = task else { return }
        generation += 1
        running.cancel()
        task = nil
        let waiting = waiters
        waiters = []
        waiting.forEach { $0.resume(returning: nil) }
    }

    /// Waits for the current work. Cancelled and restarted while waiting: waits for the new run.
    /// Cancelled and not restarted: returns `.cancelled` at once. Other errors are thrown.
    public func join() async throws -> Outcome {
        var sawCancel = false
        while task != nil {
            let result = await withCheckedContinuation { waiters.append($0) }
            guard let result else { sawCancel = true; continue }
            do {
                try result.get()
                return .done
            } catch is CancellationError {
                return .cancelled
            }
        }
        return sawCancel ? .cancelled : .done
    }
}
