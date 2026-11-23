// by zayd/cold @ zayd.wtf

import Foundation
import ZoneCore

/// One direction of an in-memory connection: bytes written at one end are read at the other.
final class LinkByteQueue: @unchecked Sendable {
    struct Closed: Error {}
    private let lock = NSLock()
    private var buffer = Data()
    private var closed = false
    private var waiter: (count: Int, continuation: CheckedContinuation<Data, Error>)?

    func append(_ bytes: Data) {
        lock.lock()
        buffer.append(bytes)
        let ready = takeIfReady()
        lock.unlock()
        ready?()
    }

    func close() {
        lock.lock()
        closed = true
        let ready = takeIfReady()
        lock.unlock()
        ready?()
    }

    func read(exactly count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            waiter = (count, continuation)
            let ready = takeIfReady()
            lock.unlock()
            ready?()
        }
    }

    /// Call with the lock held. Returns what to run once it is released.
    private func takeIfReady() -> (() -> Void)? {
        guard let waiting = waiter else { return nil }
        if buffer.count >= waiting.count {
            let bytes = Data(buffer.prefix(waiting.count))
            buffer = Data(buffer.dropFirst(waiting.count))
            waiter = nil
            return { waiting.continuation.resume(returning: bytes) }
        }
        if closed {
            waiter = nil
            return { waiting.continuation.resume(throwing: Closed()) }
        }
        return nil
    }
}

/// One end of an in-memory connection.
struct LinkMemoryStream: LinkByteStream {
    let incoming: LinkByteQueue
    let outgoing: LinkByteQueue

    /// The phone's end and the computer's end of one connection.
    static func pair() -> (phone: LinkMemoryStream, computer: LinkMemoryStream) {
        let up = LinkByteQueue(), down = LinkByteQueue()
        return (LinkMemoryStream(incoming: down, outgoing: up), LinkMemoryStream(incoming: up, outgoing: down))
    }

    func write(_ data: Data) async throws { outgoing.append(data) }
    func read(exactly count: Int) async throws -> Data { try await incoming.read(exactly: count) }
    func finishWriting() async throws { outgoing.close() }
    /// What closing the connection does: both directions end.
    func hangUp() { outgoing.close(); incoming.close() }
}
