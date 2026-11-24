// by zayd/cold @ zayd.wtf

import Foundation

/// The CPU decoder stays resident. A recording captures the accelerator only if preparation
/// (including its first prediction) has finished. Only a failure or leaving the foreground
/// can downgrade that recording. The rolling session publishes one result per segment.
public final class MiniComputeRouter: @unchecked Sendable {
    public typealias Decode = @Sendable ([Float]) async throws -> RecognizedSegment
    private let lock = NSLock()
    private var generation = UUID()
    private var enabled = false
    private var foreground = false
    private var failed = false
    private var ready: Decode?
    private var loading: Task<Void, Never>?

    private var draining: Task<Void, Never>?

    public init() {}

    public func configure(enabled: Bool, foreground: Bool,
                          prepare: @escaping @Sendable () async throws -> Decode,
                          onFailure: @escaping @Sendable (Error) -> Void) {
        lock.withLock {
            self.foreground = foreground
            if !enabled && self.enabled {
                generation = UUID()
                ready = nil
                failed = false
                if let loading {
                    loading.cancel()
                    draining = loading
                    self.loading = nil
                }
            }
            self.enabled = enabled
            guard enabled, foreground, ready == nil, loading == nil, !failed else { return }
            let id = generation
            let previous = draining
            loading = Task.detached(priority: .utility) { [self] in
                await previous?.value
                let result: Result<Decode, Error>
                do {
                    try Task.checkCancellation()
                    result = .success(try await prepare())
                } catch {
                    result = .failure(error)
                }
                lock.withLock {
                    guard generation == id else { return }
                    loading = nil
                    draining = nil
                    switch result {
                    case .success(let decoder): ready = decoder
                    case .failure(let error):
                        failed = self.foreground
                        onFailure(error)
                    }
                }
            }
        }
    }

    public var isForeground: Bool { lock.withLock { foreground } }

    public var canAccelerate: Bool { lock.withLock { foreground && enabled && ready != nil && !failed } }

    public func waitForPreparation() async {
        let task = lock.withLock { loading ?? draining }
        await task?.value
    }

    public func session(cpu: @escaping Decode, allowAcceleration: Bool = true, report: @escaping @Sendable (String, Double) -> Void,
                        onFailure: @escaping @Sendable (Error) -> Void) -> Decode {
        let (accelerated, id) = lock.withLock { (allowAcceleration && foreground && enabled ? ready : nil, generation) }
        let state = SessionState()
        return { [self] samples in
            let start = ProcessInfo.processInfo.systemUptime
            if let accelerated, state.eligible,
               lock.withLock({ foreground && (generation != id || !failed) }) {
                do {
                    let result = try await accelerated(samples)
                    report("cpuAndNeuralEngine", ProcessInfo.processInfo.systemUptime - start)
                    return result
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError { throw error }
                    lock.withLock {
                        if generation == id && foreground {
                            failed = true
                            ready = nil
                        }
                    }
                    onFailure(error)
                }
            }
            state.downgrade()
            try Task.checkCancellation()
            let result = try await cpu(samples)
            report("cpuOnly", ProcessInfo.processInfo.systemUptime - start)
            return result
        }
    }

    private final class SessionState: @unchecked Sendable {
        private let lock = NSLock()
        private var active = true
        var eligible: Bool { lock.withLock { active } }
        func downgrade() { lock.withLock { active = false } }
    }
}
