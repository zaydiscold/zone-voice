// by zayd/cold @ zayd.wtf

import Foundation

/// The numbers of Zone Link protocol version 1.
public enum LinkProtocol {
    public static let version = 1
    /// The iroh ALPN of the sync protocol, as ASCII bytes.
    public static let alpn = Data("zone-sync/1".utf8)
    /// A frame's length field may not exceed this. A larger one is a protocol error.
    public static let maxFrameBytes = 4 * 1024 * 1024
    /// An `items` frame carries at most this many items.
    public static let maxItemsPerFrame = 500
    /// An `items` frame is at most this many bytes of JSON.
    public static let maxItemsFrameBytes = 1024 * 1024
    /// Either side closes a session with no frame for this long.
    public static let idleSeconds: TimeInterval = 60
}

/// Who is sending, in `hello`.
public struct LinkPhone: Codable, Equatable, Sendable {
    /// A UUID made once per install.
    public var id: String
    public var name: String
    /// Version and build, such as "1.0.3 (2026111401)".
    public var app: String

    public init(id: String, name: String, app: String) {
        self.id = id
        self.name = name
        self.app = app
    }
}

/// Who answered, in `welcome`.
public struct LinkComputer: Codable, Equatable, Sendable {
    /// The UUID of the computer's database. A different one means a different (or new) database.
    public var id: String
    public var name: String?
    public var os: String?
    public var version: String?

    public init(id: String, name: String? = nil, os: String? = nil, version: String? = nil) {
        self.id = id
        self.name = name
        self.os = os
        self.version = version
    }
}

/// One message of the sync protocol. Every message is one JSON object with a `t`.
public enum LinkMessage: Equatable, Sendable {
    case hello(phone: LinkPhone, pair: String?)
    case welcome(computer: LinkComputer, items: Int?, resendAll: Bool)
    case refused(reason: String)
    case items(seq: Int, items: [LinkItem])
    case ack(seq: Int, stored: Int?)
    case bye

    public enum DecodingFailure: Error, Equatable {
        case notAnObject
        case unknownType(String)
        case unsupportedVersion(Int)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        switch self {
        case .hello(let phone, let pair):
            return try encoder.encode(Hello(t: "hello", v: LinkProtocol.version, phone: phone, pair: pair))
        case .welcome(let computer, let items, let resendAll):
            return try encoder.encode(Welcome(t: "welcome", v: LinkProtocol.version, computer: computer, items: items, resend_all: resendAll))
        case .refused(let reason):
            return try encoder.encode(Refused(t: "refused", reason: reason))
        case .items(let seq, let items):
            return try LinkBatcher.payload(seq: seq, encodedItems: items.map { try $0.encoded() })
        case .ack(let seq, let stored):
            return try encoder.encode(Ack(t: "ack", seq: seq, stored: stored))
        case .bye:
            return Data(#"{"t":"bye"}"#.utf8)
        }
    }

    /// Unknown fields are ignored. An unknown `t` or a different `v` is an error.
    public static func decode(_ data: Data) throws -> LinkMessage {
        let decoder = JSONDecoder()
        guard let tag = try? decoder.decode(Tag.self, from: data) else { throw DecodingFailure.notAnObject }
        switch tag.t {
        case "hello":
            let message = try decoder.decode(Hello.self, from: data)
            guard message.v == LinkProtocol.version else { throw DecodingFailure.unsupportedVersion(message.v) }
            return .hello(phone: message.phone, pair: message.pair)
        case "welcome":
            let message = try decoder.decode(Welcome.self, from: data)
            if let version = message.v, version != LinkProtocol.version { throw DecodingFailure.unsupportedVersion(version) }
            return .welcome(computer: message.computer, items: message.items, resendAll: message.resend_all ?? false)
        case "refused":
            return .refused(reason: (try decoder.decode(Refused.self, from: data)).reason ?? "")
        case "items":
            let message = try decoder.decode(Items.self, from: data)
            return .items(seq: message.seq, items: message.items)
        case "ack":
            let message = try decoder.decode(Ack.self, from: data)
            return .ack(seq: message.seq, stored: message.stored)
        case "bye":
            return .bye
        default:
            throw DecodingFailure.unknownType(tag.t)
        }
    }

    private struct Tag: Decodable { let t: String }
    private struct Hello: Codable { let t: String; let v: Int; let phone: LinkPhone; let pair: String? }
    private struct Welcome: Codable { let t: String; let v: Int?; let computer: LinkComputer; let items: Int?; let resend_all: Bool? }
    private struct Refused: Codable { let t: String; let reason: String? }
    private struct Items: Decodable { let seq: Int; let items: [LinkItem] }
    private struct Ack: Codable { let t: String; let seq: Int; let stored: Int? }
}

/// Framing in both directions: a 4-byte big-endian length, then that many bytes of JSON.
public enum LinkFrame {
    public enum Failure: Error, Equatable {
        /// The length is over 4 MiB. The only answer is to close.
        case tooLarge(Int)
    }

    public static let headerBytes = 4

    public static func frame(_ payload: Data) throws -> Data {
        guard payload.count <= LinkProtocol.maxFrameBytes else { throw Failure.tooLarge(payload.count) }
        let count = UInt32(payload.count)
        var out = Data([UInt8(count >> 24 & 0xff), UInt8(count >> 16 & 0xff), UInt8(count >> 8 & 0xff), UInt8(count & 0xff)])
        out.append(payload)
        return out
    }

    /// The payload length a 4-byte header announces.
    public static func length(header: Data) throws -> Int {
        precondition(header.count == headerBytes)
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        guard length <= LinkProtocol.maxFrameBytes else { throw Failure.tooLarge(length) }
        return length
    }
}

/// Takes bytes as they arrive, in pieces of any size, and gives back whole frames.
public struct LinkFrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ bytes: Data) { buffer.append(bytes) }

    /// The next complete frame's payload, or nil until more bytes arrive.
    public mutating func next() throws -> Data? {
        guard buffer.count >= LinkFrame.headerBytes else { return nil }
        let length = try LinkFrame.length(header: Data(buffer.prefix(LinkFrame.headerBytes)))
        guard buffer.count >= LinkFrame.headerBytes + length else { return nil }
        let start = buffer.startIndex + LinkFrame.headerBytes
        let payload = Data(buffer[start..<(start + length)])
        buffer = Data(buffer[(start + length)...])
        return payload
    }

    /// Bytes held that do not make a whole frame yet.
    public var pendingBytes: Int { buffer.count }
}

/// One `items` frame ready to send.
public struct LinkBatch: Equatable, Sendable {
    public let seq: Int
    public let items: [LinkItem]
    /// The complete JSON of the `items` message.
    public let payload: Data
}

/// Cuts a list of items into frames of at most 500 items and 1 MiB.
public enum LinkBatcher {
    public struct Plan: Equatable, Sendable {
        public var batches: [LinkBatch]
        /// Items that do not fit in a frame on their own even without their details.
        public var tooLarge: [LinkItem]
    }

    public static func plan(_ items: [LinkItem], firstSeq: Int = 1, maxItems: Int = LinkProtocol.maxItemsPerFrame,
                            maxBytes: Int = LinkProtocol.maxItemsFrameBytes) -> Plan {
        var plan = Plan(batches: [], tooLarge: [])
        var current: [(item: LinkItem, bytes: Data)] = []
        var currentBytes = 0
        var seq = firstSeq

        func flush() {
            guard !current.isEmpty else { return }
            let payload = (try? payload(seq: seq, encodedItems: current.map(\.bytes))) ?? Data()
            plan.batches.append(LinkBatch(seq: seq, items: current.map(\.item), payload: payload))
            seq += 1
            current = []
            currentBytes = 0
        }

        for original in items {
            // The largest envelope any frame of this plan can have, so the sum is never short.
            let envelope = envelopeBytes(seq: firstSeq + items.count)
            var item = original
            guard var bytes = try? item.encoded() else { plan.tooLarge.append(original); continue }
            if envelope + bytes.count > maxBytes, let slim = slimmed(item), let slimBytes = try? slim.encoded() {
                item = slim
                bytes = slimBytes
            }
            guard envelope + bytes.count <= maxBytes else { plan.tooLarge.append(original); continue }
            let separator = current.isEmpty ? 0 : 1
            if current.count >= maxItems || envelope + currentBytes + separator + bytes.count > maxBytes { flush() }
            currentBytes += (current.isEmpty ? 0 : 1) + bytes.count
            current.append((item, bytes))
        }
        flush()
        return plan
    }

    /// `{"t":"items","seq":N,"items":[...]}` around items that are already encoded.
    public static func payload(seq: Int, encodedItems: [Data]) throws -> Data {
        var out = Data(#"{"t":"items","seq":\#(seq),"items":["#.utf8)
        for (index, item) in encodedItems.enumerated() {
            if index > 0 { out.append(0x2c) }
            out.append(item)
        }
        out.append(contentsOf: [0x5d, 0x7d])
        return out
    }

    private static func envelopeBytes(seq: Int) -> Int {
        #"{"t":"items","seq":\#(seq),"items":[]}"#.utf8.count
    }

    /// A very long meeting can pass 1 MiB once every segment repeats its words. The readable
    /// text stays whole; the per-segment detail is dropped and the item says so.
    private static func slimmed(_ item: LinkItem) -> LinkItem? {
        guard item.extra["segments"] != nil else { return nil }
        var slim = item
        slim.extra["segments"] = nil
        slim.extra["segments_omitted"] = .bool(true)
        return slim
    }
}
