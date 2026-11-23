// by zayd/cold @ zayd.wtf

import Foundation

/// The two directions of the one stream a session uses. The transport supplies it (iroh in the
/// app); the session logic below never knows what carries the bytes.
public protocol LinkByteStream: Sendable {
    func write(_ data: Data) async throws
    /// Exactly `count` bytes. Throws when the stream ends first.
    func read(exactly count: Int) async throws -> Data
    /// Nothing more will be written.
    func finishWriting() async throws
}

public enum LinkSessionError: Error, Equatable {
    /// The computer answered `refused`: `not_paired`, `bad_secret`, `version` or `busy`.
    case refused(String)
    /// The computer sent something the protocol does not allow at that point.
    case unexpected(String)
    /// No frame arrived in time.
    case timedOut
    /// The computer could not be reached at all.
    case unreachable(String)
    /// The connection was up and then dropped.
    case connectionLost(String)

    /// What the Computers screen shows. Plain words, no codes.
    public var plainMessage: String {
        switch self {
        case .refused("not_paired"): return "This computer forgot your iPhone. Pair it again."
        case .refused("bad_secret"): return "Pairing code expired or already used. Run `zone pair` or choose Pair a phone on your computer."
        case .refused("version"): return "Version mismatch. Update Zone on your iPhone or computer."
        case .refused("busy"): return "Computer is busy. Zone will retry."
        case .refused: return "Connection refused by computer."
        case .unexpected: return "Unexpected response from computer."
        case .timedOut: return "Computer timed out."
        case .unreachable: return "Couldn't reach computer. Check if it's awake and online."
        case .connectionLost: return "Connection dropped. Zone will retry."
        }
    }

    /// True when trying again later cannot help until the person pairs again.
    public var needsPairing: Bool {
        switch self {
        case .refused("not_paired"), .refused("bad_secret"): return true
        default: return false
        }
    }
}

/// What the session asks of whoever keeps the delivery state.
public protocol LinkSessionDelegate: Sendable {
    /// The computer said `welcome`. Returns everything it should be sent now.
    func welcomed(by computer: LinkComputer, itemsOnComputer: Int?, resendAll: Bool) async -> [LinkItem]
    /// A frame with these items is about to go out.
    func willSend(_ items: [LinkItem]) async
    /// The computer acknowledged the frame with these items: they are delivered.
    func acknowledged(_ items: [LinkItem]) async
}

public struct LinkSessionOutcome: Equatable, Sendable {
    public var computer: LinkComputer
    public var resendAll: Bool
    /// `items` frames sent, each acknowledged.
    public var frames: Int
    /// Items acknowledged, deletions included.
    public var delivered: Int
    public var deletions: Int
    /// Items too large for a frame, left unsent.
    public var tooLarge: Int
}

/// One sync session, phone side: `hello`, then `welcome` or `refused`, then `items` frames each
/// answered by an `ack`, then `bye`.
public enum LinkSession {
    public static func run(over stream: LinkByteStream, phone: LinkPhone, pairSecret: String?,
                           delegate: LinkSessionDelegate, frameTimeout: TimeInterval = LinkProtocol.idleSeconds,
                           onStall: @escaping @Sendable () -> Void = {}) async throws -> LinkSessionOutcome {
        try await send(.hello(phone: phone, pair: pairSecret), over: stream)

        let computer: LinkComputer
        let resendAll: Bool
        let held: Int?
        switch try await receive(from: stream, timeout: frameTimeout, onStall: onStall) {
        case .welcome(let who, let items, let resend):
            computer = who
            held = items
            resendAll = resend
        case .refused(let reason):
            throw LinkSessionError.refused(reason)
        default:
            throw LinkSessionError.unexpected("expected welcome or refused")
        }

        let pending = await delegate.welcomed(by: computer, itemsOnComputer: held, resendAll: resendAll)
        let plan = LinkBatcher.plan(pending)
        var outcome = LinkSessionOutcome(computer: computer, resendAll: resendAll, frames: 0, delivered: 0,
                                         deletions: 0, tooLarge: plan.tooLarge.count)
        for batch in plan.batches {
            try Task.checkCancellation()
            await delegate.willSend(batch.items)
            try await stream.write(try LinkFrame.frame(batch.payload))
            // An item counts as delivered only once the computer says its frame is on disk.
            guard case .ack(let seq, _) = try await receive(from: stream, timeout: frameTimeout, onStall: onStall),
                  seq == batch.seq else {
                throw LinkSessionError.unexpected("expected ack \(batch.seq)")
            }
            await delegate.acknowledged(batch.items)
            outcome.frames += 1
            outcome.delivered += batch.items.count
            outcome.deletions += batch.items.filter(\.deleted).count
        }

        try await send(.bye, over: stream)
        try? await stream.finishWriting()
        return outcome
    }

    static func send(_ message: LinkMessage, over stream: LinkByteStream) async throws {
        try await stream.write(try LinkFrame.frame(try message.encoded()))
    }

    static func receive(from stream: LinkByteStream, timeout: TimeInterval,
                        onStall: @escaping @Sendable () -> Void) async throws -> LinkMessage {
        let payload = try await LinkDeadline.run(seconds: timeout, onExpire: onStall) {
            let header = try await stream.read(exactly: LinkFrame.headerBytes)
            do {
                return try await stream.read(exactly: try LinkFrame.length(header: header))
            } catch let failure as LinkFrame.Failure {
                throw LinkSessionError.unexpected("frame too large: \(failure)")
            }
        }
        do {
            return try LinkMessage.decode(payload)
        } catch {
            throw LinkSessionError.unexpected("unreadable message")
        }
    }
}

/// Runs something with a time limit, for work that does not stop when its task is cancelled
/// (a read waiting on the network inside iroh does not). When time runs out, or the caller is
/// cancelled, `onExpire` runs so the caller can close whatever the work is waiting on; the
/// work is left to finish on its own and its result is dropped.
public enum LinkDeadline {
    public static func run<T: Sendable>(seconds: TimeInterval, onExpire: @escaping @Sendable () -> Void = {},
                                        _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let gate = Gate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                gate.wait(continuation)
                Task {
                    do { gate.finish(.success(try await work())) }
                    catch { gate.finish(.failure(error)) }
                }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                    if gate.finish(.failure(LinkSessionError.timedOut)) { onExpire() }
                }
            }
        } onCancel: {
            if gate.finish(.failure(CancellationError())) { onExpire() }
        }
    }

    /// Resumes its continuation once, with whichever result arrives first.
    private final class Gate<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var result: Result<T, Error>?

        func wait(_ continuation: CheckedContinuation<T, Error>) {
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        /// True when this result is the one that was used.
        @discardableResult
        func finish(_ result: Result<T, Error>) -> Bool {
            lock.lock()
            guard self.result == nil else { lock.unlock(); return false }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
            return true
        }
    }
}

/// Keeps one computer's delivery state in a `LinkStore` as a session runs.
public final class LinkComputerSync: LinkSessionDelegate, @unchecked Sendable {
    private let endpointID: String
    private let store: LinkStore
    private let deletions: LinkDeletionLog
    private let library: @Sendable () async -> [LinkItem]

    /// - Parameter library: the current library as items, read when the computer has said welcome.
    public init(endpointID: String, store: LinkStore, deletions: LinkDeletionLog,
                library: @escaping @Sendable () async -> [LinkItem]) {
        self.endpointID = endpointID
        self.store = store
        self.deletions = deletions
        self.library = library
    }

    public func welcomed(by computer: LinkComputer, itemsOnComputer: Int?, resendAll: Bool) async -> [LinkItem] {
        // A new database, or resend_all, also starts an Everything flash round over.
        store.adopt(computerID: computer.id, resendAll: resendAll, for: endpointID)
        store.update(endpointID) { saved in
            saved.confirmed = true
            saved.computerID = computer.id
            saved.os = computer.os
            saved.version = computer.version
            saved.itemsOnComputer = itemsOnComputer
            if let name = computer.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                saved.name = LinkPairingLink.cleanedName(name)
            }
        }
        let items = await library()
        return store.pending(for: endpointID, library: items, deletions: deletions.all())
    }

    public func willSend(_ items: [LinkItem]) async {
        store.updateDelivery(for: endpointID) { $0.willSend(items) }
    }

    public func acknowledged(_ items: [LinkItem]) async {
        let kept = store.acknowledge(items, by: endpointID)
        if kept > 0 { store.update(endpointID) { $0.itemsSent += kept } }
    }
}

extension LinkStore {
    /// How many items a computer has not been sent yet, without connecting.
    public func pendingCount(for endpointID: String, library: [LinkItem], deletions: [LinkDeletion]) -> Int {
        pending(for: endpointID, library: library, deletions: deletions).count
    }

    /// Drops deletions no paired computer still needs: nobody has the item, every computer
    /// that has it keeps its copy, or the record is back in the library (a retried recording
    /// keeps its id).
    public func pruneDeletions(_ log: LinkDeletionLog, libraryIDs: Set<String>) {
        let states = computers().map { ($0.endpointID, delivery(for: $0.endpointID)) }
        log.prune { entry in
            !libraryIDs.contains(entry.id) && states.contains { $0.1.mayHave(entry.id) && !entry.isKept(by: $0.0) }
        }
    }
}
