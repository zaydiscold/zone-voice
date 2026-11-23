// by zayd/cold @ zayd.wtf

import Foundation

/// Accepted presses run in order. A stop received while start awaits microphone/model setup
/// must wait for that start, not launch a second start or return before it has done anything.
@MainActor
public final class ShortcutActionQueue {
    private var tail: Task<Void, Error>?
    private var generation: UInt64 = 0

    private var latestRequest: UUID?

    public init() {}

    /// Reserve before enqueueing so even an idle Off supersedes a delayed Open Zone reply.
    public func acceptRequest() -> UUID {
        let token = UUID()
        latestRequest = token
        return token
    }

    public func isCurrent(_ token: UUID) -> Bool { latestRequest == token }

    public func enqueueRecovery(for token: UUID, _ action: @escaping @MainActor () async throws -> Void) -> Task<Void, Error> {
        enqueue { [weak self] in
            guard self?.isCurrent(token) == true else { return }
            try await action()
        }
    }

    public func enqueue(_ action: @escaping @MainActor () async throws -> Void) -> Task<Void, Error> {
        generation &+= 1
        let ownGeneration = generation
        let previous = tail
        let task = Task { @MainActor [weak self] in
            _ = await previous?.result
            defer { if self?.generation == ownGeneration { self?.tail = nil } }
            try await action()
        }
        tail = task
        return task
    }
}
