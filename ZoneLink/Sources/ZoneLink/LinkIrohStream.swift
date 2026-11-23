// by zayd/cold @ zayd.wtf

import Foundation
import IrohLib
import ZoneCore

/// One iroh bidirectional stream as the byte stream a session runs over.
public struct LinkIrohStream: LinkByteStream {
    private let sending: SendStream
    private let receiving: RecvStream

    public init(_ stream: BiStream) {
        sending = stream.send()
        receiving = stream.recv()
    }

    public func write(_ data: Data) async throws {
        try await sending.writeAll(buf: data)
    }

    public func read(exactly count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        return try await receiving.readExact(size: UInt32(count))
    }

    public func finishWriting() async throws {
        try await sending.finish()
    }

    /// Waits until the other side has finished its half, reading and dropping anything left.
    public func drain(limit: UInt32 = 64 * 1024) async throws {
        _ = try await receiving.readToEnd(sizeLimit: limit)
    }
}
