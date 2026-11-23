// by zayd/cold @ zayd.wtf

import CryptoKit
import Foundation

/// The numbers of Flash (Zone Link protocol, carrier 2): the phone shows a rapid sequence of QR
/// codes and the computer's camera reads them. No network is involved at any point.
public enum LinkFlashFormat {
    /// Every frame starts with these three ASCII bytes.
    public static let magic = Data("ZF1".utf8)
    /// Magic, session, total length, chunk count and frame index, before the body.
    public static let headerBytes = 17
    /// Bytes of payload per chunk. 900 gives a version 21 QR code (101 modules) at correction
    /// level L. The protocol lets the phone choose: the computer reads the chunk size from the
    /// length of each frame.
    public static let chunkBytes = 900
    /// The chunk count is 16 bits on the wire.
    public static let maxChunks = 65_535
    /// The most chunks the phone puts in one flash: 3.7 MB sealed, a little over a minute in
    /// color and about three and a half minutes in black and white when the camera catches
    /// every code. A larger library goes in more than one flash (`LinkFlash.plan` takes what
    /// fits from the front, `LinkStore.flashItems` says what the next one carries). The
    /// computer's solve is dense rows, about k squared work, and so is finding a misread code
    /// (zone-mcp, src/flash/assemble.rs): at 16,384 the final solve took about 10 seconds and a
    /// few misread codes took minutes, sixteen times what 4,096 costs.
    public static let planChunks = 4_096
    /// Pictures a second. Twenty divides a 60 or 120 Hz display, so every picture stays up for
    /// the same number of refreshes, and a 30 picture a second webcam still sees each one whole
    /// at least once.
    public static let framesPerSecond = 20
}

/// How a flash looks on the screen.
///
/// Both send 900 byte frames, 20 pictures a second. Measured for black and white on simulator
/// recordings of the Flash screen run through a webcam model (30 pictures a second, rolling
/// shutter, 12 to 25 ms exposure, the phone turned 3 degrees, light blur, noise and JPEG, the
/// code 400 to 520 pixels wide in the 720 pixel square the page reads), decoded by
/// `zone dev flash-decode`: 17 to 18 kB of sealed data a second. Nothing was filmed with a real
/// camera yet.
public enum LinkFlashMode: String, CaseIterable, Sendable {
    /// Three frames a picture, one in each of red, green and blue (`LinkFlashColor`): about
    /// 54 kB a second shown.
    case color
    /// One frame a picture, black on white: about 18 kB a second. For cameras that mix up the
    /// colors, and for computers whose zone reads only black and white.
    case blackAndWhite

    public var chunkBytes: Int { LinkFlashFormat.chunkBytes }
    public var framesPerSecond: Int { LinkFlashFormat.framesPerSecond }
    public var codesPerPicture: Int { self == .color ? LinkFlashColor.channels : 1 }
}

/// What a Flash carries: the same items a Link session sends, in one sealed block.
///
/// The JSON `{"t":"flash","v":1,"phone":{...},"items":[...]}` is compressed with raw DEFLATE and
/// sealed with ChaCha20-Poly1305 under the Flash key, as `nonce(12) || ciphertext || tag(16)`.
public enum LinkFlashPayload {
    public enum Failure: Error, Equatable {
        /// The key is not 32 bytes.
        case badKey
        case compression
        /// The block does not open with this key, or was changed on the way.
        case damaged
    }

    /// The flash's JSON: `t`, `v`, `phone`, the phone's own summary of the items (`check`, see
    /// `LinkFlashCheck`), then the items, byte for byte as a Link frame carries them.
    public static func json(phone: LinkPhone, items: [LinkItem]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var out = Data(#"{"t":"flash","v":\#(LinkProtocol.version),"phone":"#.utf8)
        out.append(try encoder.encode(phone))
        out.append(Data(#","check":"#.utf8))
        out.append(try encoder.encode(LinkFlashCheck(items: items)))
        out.append(Data(#","items":["#.utf8))
        for (index, item) in items.enumerated() {
            if index > 0 { out.append(0x2c) }
            out.append(try item.encoded())
        }
        out.append(contentsOf: [0x5d, 0x7d])
        return out
    }

    /// Raw DEFLATE (RFC 1951): no zlib or gzip header.
    public static func deflate(_ data: Data) throws -> Data {
        guard !data.isEmpty, let packed = try? (data as NSData).compressed(using: .zlib) else { throw Failure.compression }
        return packed as Data
    }

    public static func inflate(_ data: Data) throws -> Data {
        guard !data.isEmpty, let plain = try? (data as NSData).decompressed(using: .zlib) else { throw Failure.compression }
        return plain as Data
    }

    /// Compresses and seals. The nonce is random unless a test supplies one.
    public static func seal(_ json: Data, key: Data, nonce: Data? = nil) throws -> Data {
        guard key.count == 32 else { throw Failure.badKey }
        let chosen = try nonce.map { try ChaChaPoly.Nonce(data: $0) } ?? ChaChaPoly.Nonce()
        let box = try ChaChaPoly.seal(try deflate(json), using: SymmetricKey(data: key), nonce: chosen)
        return box.combined
    }

    /// The JSON inside a sealed block. The phone only sends; this is here so tests can read
    /// back what the phone would show.
    public static func open(_ sealed: Data, key: Data) throws -> Data {
        guard key.count == 32 else { throw Failure.badKey }
        guard let box = try? ChaChaPoly.SealedBox(combined: sealed),
              let packed = try? ChaChaPoly.open(box, using: SymmetricKey(data: key)) else { throw Failure.damaged }
        return try inflate(packed)
    }
}

/// The phone's summary of what a flash carries, so the computer can check every item arrived
/// as it was sent (Zone Link protocol, "Carrier 2: Flash"):
/// `{"digest":"<64 hex>","items":1764,"newest":1794800000.5,"oldest":1741000000.25}`.
///
/// `items` counts the entries, `oldest` and `newest` are the smallest and largest `created_at`
/// of the ones that are not deletions (left out when there are none), and `digest` is SHA-256
/// over six lines per entry, in order, each ended by a line feed: the id, the kind, `1` for a
/// deletion else `0`, `created_at` and `updated_at` as the 16 hex digits of their binary64 bits
/// (minus zero as zero; `-` when not sent), and the hex SHA-256 of the text (`-` when not sent).
/// The times go in as bits, so one that changes in its last binary digit on the way does not
/// match. A deletion sends neither `created_at` nor `text`, so both are `-` for it.
public struct LinkFlashCheck: Codable, Equatable, Sendable {
    public var items: Int
    public var oldest: Double?
    public var newest: Double?
    public var digest: String

    public init(items list: [LinkItem]) {
        items = list.count
        let times = list.filter { !$0.deleted }.compactMap(\.createdAt)
        oldest = times.min()
        newest = times.max()
        digest = Self.digest(list)
    }

    public static func digest(_ items: [LinkItem]) -> String {
        func bits(_ value: Double?) -> String {
            guard let value else { return "-" }
            // Adding zero turns minus zero into zero and leaves everything else as it is.
            return String(format: "%016llx", (value + 0.0).bitPattern)
        }
        func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
            bytes.map { String(format: "%02x", $0) }.joined()
        }
        var all = SHA256()
        for item in items {
            let text = item.deleted ? nil : item.text
            let lines = [
                item.id,
                item.kind.rawValue,
                item.deleted ? "1" : "0",
                bits(item.deleted ? nil : item.createdAt),
                bits(item.updatedAt),
                text.map { hex(SHA256.hash(data: Data($0.utf8))) } ?? "-",
            ]
            for line in lines {
                all.update(data: Data(line.utf8))
                all.update(data: Data([0x0a]))
            }
        }
        return hex(all.finalize())
    }
}

/// Turns a sealed payload into the endless sequence of frames a Flash shows.
///
/// The payload is cut into `chunkCount` chunks. The first `chunkCount` frames are the chunks
/// themselves; every later frame is the XOR of a set of chunks chosen by splitmix64, so the
/// receiver needs enough different frames, never one particular frame.
public struct LinkFlashEncoder: Sendable {
    public enum Failure: Error, Equatable {
        case empty
        /// More chunks than the 16-bit count can say.
        case tooLarge(chunks: Int)
        case badChunkSize
    }

    /// Random, the same for every frame of one flash.
    public let session: UInt32
    /// Bytes of payload, before the last chunk's padding.
    public let totalLength: Int
    public let chunkBytes: Int
    public let chunkCount: Int
    /// The payload, zero padded to a whole number of chunks.
    private let padded: [UInt8]

    public init(payload: Data, session: UInt32, chunkBytes: Int = LinkFlashFormat.chunkBytes,
                maxChunks: Int = LinkFlashFormat.maxChunks) throws {
        guard chunkBytes > 0 else { throw Failure.badChunkSize }
        guard !payload.isEmpty else { throw Failure.empty }
        let count = (payload.count + chunkBytes - 1) / chunkBytes
        guard count <= min(maxChunks, LinkFlashFormat.maxChunks), payload.count <= Int(UInt32.max) else {
            throw Failure.tooLarge(chunks: count)
        }
        var bytes = [UInt8](payload)
        bytes.append(contentsOf: [UInt8](repeating: 0, count: count * chunkBytes - payload.count))
        self.session = session
        self.totalLength = payload.count
        self.chunkBytes = chunkBytes
        self.chunkCount = count
        self.padded = bytes
    }

    /// How many chunks a payload of this size needs.
    public static func chunks(forBytes bytes: Int, chunkBytes: Int = LinkFlashFormat.chunkBytes) -> Int {
        (bytes + chunkBytes - 1) / chunkBytes
    }

    public var frameBytes: Int { LinkFlashFormat.headerBytes + chunkBytes }

    /// After this many frames the phone starts again from frame 0.
    public var cycleLength: Int { 3 * chunkCount + 60 }

    /// The 64-bit words that choose a coded frame's chunks: splitmix64 started at
    /// `(session << 32) | index`.
    public static func mixWords(session: UInt32, index: UInt32, count: Int) -> [UInt64] {
        var state = UInt64(session) << 32 | UInt64(index)
        var words: [UInt64] = []
        words.reserveCapacity(count)
        for _ in 0..<count {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            words.append(z ^ (z >> 31))
        }
        return words
    }

    /// Which chunks frame `index` is the XOR of, lowest first.
    public static func chunkSet(session: UInt32, index: UInt32, chunkCount: Int) -> [Int] {
        guard chunkCount > 0 else { return [] }
        if Int(index) < chunkCount { return [Int(index)] }
        let words = mixWords(session: session, index: index, count: (chunkCount + 63) / 64)
        var chosen: [Int] = []
        for (wordIndex, word) in words.enumerated() {
            var bits = word
            while bits != 0 {
                let chunk = wordIndex * 64 + bits.trailingZeroBitCount
                if chunk < chunkCount { chosen.append(chunk) }
                bits &= bits - 1
            }
        }
        return chosen.isEmpty ? [Int(index) % chunkCount] : chosen
    }

    /// The bytes of frame `index`: `"ZF1" || session || total length || chunk count || index || body`,
    /// integers big-endian.
    public func frame(_ index: UInt32) -> Data {
        var out = [UInt8](repeating: 0, count: frameBytes)
        out[0] = 0x5a; out[1] = 0x46; out[2] = 0x31
        func put(_ value: UInt32, at offset: Int) {
            out[offset] = UInt8(value >> 24 & 0xff)
            out[offset + 1] = UInt8(value >> 16 & 0xff)
            out[offset + 2] = UInt8(value >> 8 & 0xff)
            out[offset + 3] = UInt8(value & 0xff)
        }
        put(session, at: 3)
        put(UInt32(totalLength), at: 7)
        out[11] = UInt8(chunkCount >> 8 & 0xff)
        out[12] = UInt8(chunkCount & 0xff)
        put(index, at: 13)

        let size = chunkBytes
        let chunks = Self.chunkSet(session: session, index: index, chunkCount: chunkCount)
        padded.withUnsafeBufferPointer { source in
            out.withUnsafeMutableBufferPointer { target in
                guard let from = source.baseAddress, let base = target.baseAddress else { return }
                let body = base + LinkFlashFormat.headerBytes
                for chunk in chunks {
                    let part = from + chunk * size
                    for offset in 0..<size { body[offset] ^= part[offset] }
                }
            }
        }
        return Data(out)
    }
}

/// Where a Flash is at one moment: which frame is on screen, and which time round.
///
/// The frame follows the clock, not a count of screen refreshes, so a dropped refresh never
/// slows the flash down. After `3k + 60` frames the phone starts again from frame 0.
public struct LinkFlashPlayhead: Equatable, Sendable {
    /// 1 the first time through the frames, 2 the second, and so on.
    public let pass: Int
    /// The frame on screen, from 0 to one less than `cycleLength`.
    public let frame: Int
    public let cycleLength: Int

    public init(elapsed: TimeInterval, cycleLength: Int, framesPerSecond: Int = LinkFlashFormat.framesPerSecond) {
        let cycle = max(1, cycleLength)
        // Clamped so a clock that jumps cannot overflow.
        let shown = Int(min(max(0, elapsed) * Double(max(1, framesPerSecond)), 1e15))
        self.pass = shown / cycle + 1
        self.frame = shown % cycle
        self.cycleLength = cycle
    }

    /// "Pass 2, 340 of 1,354".
    public var line: String {
        "Pass \(pass.formatted()), \((frame + 1).formatted()) of \(cycleLength.formatted())"
    }
}

/// One Flash, ready to show: which items it carries and the frames that carry them.
public struct LinkFlashPlan: Sendable {
    /// The items in this flash, in the order they were given.
    public let items: [LinkItem]
    /// Items that did not fit in one flash. They go in the next one.
    public let leftOut: Int
    /// Size of the JSON before compression.
    public let jsonBytes: Int
    public let encoder: LinkFlashEncoder
    /// Pictures shown a second.
    public let framesPerSecond: Int
    /// Frames in each picture: 3 in color (one a channel), 1 in black and white.
    public let codesPerPicture: Int

    /// Seconds for the computer to see enough frames when it misses none.
    public var seconds: Double {
        Double(encoder.chunkCount + 10) / Double(max(1, framesPerSecond * codesPerPicture))
    }

    /// The fewest seconds in which any camera could have read this whole flash once its codes
    /// are up: one frame for every piece, at the fastest the phone shows them. A page that says
    /// Done sooner after these codes appeared is showing an earlier flash.
    public var minimumSeconds: Double {
        Double(encoder.chunkCount) / Double(max(1, framesPerSecond * codesPerPicture))
    }

    /// The flash's name, for the person to compare with the computer's page: its session in
    /// hex, in two groups of four (`8f3a 21c4`). zone reports the same eight digits as the
    /// flash's `session`, which every frame carries, so the page can show it from the first
    /// code it reads to its Done. Two flashes, even of the same items, never share a name
    /// except by a one in four billion chance.
    public var name: String {
        let session = encoder.session
        return String(format: "%04x %04x", session >> 16, session & 0xFFFF)
    }

    /// Pictures before the phone starts again from frame 0: every frame of a cycle is shown once.
    public var pictureCycle: Int {
        (encoder.cycleLength + codesPerPicture - 1) / max(1, codesPerPicture)
    }

    /// The frames picture `index` carries, in channel order (red, green, blue).
    public func frames(inPicture index: Int) -> [UInt32] {
        (0..<codesPerPicture).map { UInt32((index * codesPerPicture + $0) % encoder.cycleLength) }
    }

    /// True when nothing this flash carries has changed since it was made. The computer takes
    /// a flash's versions as the phone's (the phone wins merges), so a flash made before an
    /// edit or a delete would put the older state back, even after a Link sync had given the
    /// computer the newer one, and a Yes would mark versions as delivered that it never got.
    ///
    /// - `sending` is what the same choice would send now, and `library` the library now.
    /// - Every record must still be in the library exactly as the flash has it. One a Link
    ///   sync delivered meanwhile is the same version, so carrying it again changes nothing.
    /// - Every deletion and clip must still be waiting to go: a clip taken off the list, or a
    ///   deletion this computer is now spared, must not go after all.
    /// - Something new since (a recording that landed, a clip) leaves the flash current: it
    ///   goes in the next flash or by Link, and remaking now would make the computer start
    ///   reading again for nothing.
    public func isCurrent(sending: [LinkItem], library: [LinkItem]) -> Bool {
        let records = Dictionary(library.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let waiting = Dictionary(sending.filter { $0.deleted || $0.kind == .clip }.map { ($0.id, $0) },
                                 uniquingKeysWith: { first, _ in first })
        return items.allSatisfy { item in
            item.deleted || item.kind == .clip ? waiting[item.id] == item : records[item.id] == item
        }
    }
}

extension LinkFlashPlan {
    /// True when `sending`, what the same choice would send now, is exactly the list this plan
    /// was made from, so a plan made now would carry the same. Stricter than `isCurrent`: it
    /// also notices something new.
    public func isMade(from sending: [LinkItem]) -> Bool {
        sending.count == items.count + leftOut && Array(sending.prefix(items.count)) == items
    }
}

/// Where the next Everything flash to one computer goes on from: just after this record, in
/// the order Everything sends the library (`updated_at`, then id, as `LinkDeliveryState.pending`
/// sorts it). A record edited since usually has a later `updated_at`, so it still comes after.
/// One that sorts before this place but joined the library or changed during the round (a
/// meeting or note restored from a backup keeps its old times, and a clock can be set back)
/// is still carried while Not sent yet lists it (`LinkStore.flashItems`).
public struct LinkFlashResume: Codable, Equatable, Sendable {
    public var updatedAt: Double
    public var id: String

    public init(updatedAt: Double, id: String) {
        self.updatedAt = updatedAt
        self.id = id
    }

    public init(after item: LinkItem) {
        self.init(updatedAt: item.updatedAt, id: item.id)
    }

    /// True when `item` comes after this place, so the next Everything flash carries it.
    public func precedes(_ item: LinkItem) -> Bool {
        (updatedAt, id) < (item.updatedAt, item.id)
    }
}

public enum LinkFlash {
    public enum Failure: Error, Equatable {
        case nothingToSend
        /// One item alone is larger than a flash can carry.
        case tooLarge
    }

    /// A random session number whose first byte is 0x80 or above.
    ///
    /// Any 32-bit number is a valid session. This half of them keeps the start of a frame from
    /// reading as text: Core Image writes a run of capital letters and digits (such as "ZF1"
    /// followed by a session that happens to be letters) as a QR alphanumeric segment instead
    /// of plain bytes. Readers join segments back into the same bytes, but one byte segment is
    /// what the protocol describes, so the phone avoids the other case where it can.
    public static func newSession() -> UInt32 {
        .random(in: 0x8000_0000...UInt32.max)
    }

    /// Seals `items` for a computer and cuts the result into frames. When everything does not
    /// fit in one flash (`LinkFlashFormat.planChunks`), the plan holds as many items from the
    /// front as do.
    public static func plan(items: [LinkItem], phone: LinkPhone, key: Data, session: UInt32 = newSession(),
                            chunkBytes: Int = LinkFlashFormat.chunkBytes, maxChunks: Int = LinkFlashFormat.planChunks,
                            framesPerSecond: Int = LinkFlashFormat.framesPerSecond, codesPerPicture: Int = 1,
                            nonce: Data? = nil) throws -> LinkFlashPlan {
        guard !items.isEmpty else { throw Failure.nothingToSend }
        var count = items.count
        while true {
            let included = Array(items.prefix(count))
            let json = try LinkFlashPayload.json(phone: phone, items: included)
            let sealed = try LinkFlashPayload.seal(json, key: key, nonce: nonce)
            let chunks = LinkFlashEncoder.chunks(forBytes: sealed.count, chunkBytes: chunkBytes)
            if chunks <= maxChunks {
                let encoder = try LinkFlashEncoder(payload: sealed, session: session, chunkBytes: chunkBytes, maxChunks: maxChunks)
                return LinkFlashPlan(items: included, leftOut: items.count - count, jsonBytes: json.count, encoder: encoder,
                                     framesPerSecond: framesPerSecond, codesPerPicture: max(1, codesPerPicture))
            }
            guard count > 1 else { throw Failure.tooLarge }
            // Aim a little under the limit; text does not compress evenly.
            let scaled = Int(Double(count) * Double(maxChunks) / Double(chunks) * 0.9)
            count = max(1, min(count - 1, scaled))
        }
    }
}

extension LinkStore {
    /// What Send by Flash carries to one computer, in order.
    ///
    /// Not sent yet is what a Link session would send now (`pending`): the clips waiting for
    /// it, the records it does not have at their current version, then the deletions it is to
    /// be told about. A larger library than one flash goes on by itself, since what a
    /// confirmed flash carried no longer counts as not sent.
    ///
    /// Everything is the waiting clips, the whole library, then the same deletions: a record
    /// this computer never had needs no deletion. When the library is larger than one flash,
    /// each confirmed Everything flash leaves a place to go on from (`flashResume`), and the
    /// next one starts after it, so the flashes add up to the whole library and its deletions
    /// instead of repeating the first part. `fromTheStart` ignores that place, for counting.
    ///
    /// A round reaches every record and deletion there is at any point during it, not only
    /// those after the place. A record can join the library, or change, with a time before
    /// the place: a meeting or note restored from a backup keeps its old times, and a clock
    /// set back writes earlier ones. So Everything also carries every record Not sent yet
    /// lists, each once, in the same order as the rest of the library. Deletions are always
    /// the ones Not sent yet lists, so one made during the round goes in it too.
    public func flashItems(for endpointID: String, everything: Bool, library: [LinkItem], deletions: [LinkDeletion],
                           fromTheStart: Bool = false) -> [LinkItem] {
        let pending = pending(for: endpointID, library: library, deletions: deletions)
        guard everything else { return pending }
        var records = LinkDeliveryState().pending(library: library, deletions: [])
        if !fromTheStart, let resume = computer(endpointID)?.flashResume {
            let notSent = Set(pending.lazy.filter { !$0.deleted && $0.kind != .clip }.map(\.id))
            records = records.filter { resume.precedes($0) || notSent.contains($0.id) }
        }
        // Waiting clips first, as in a sync; they are not in the library.
        return pending.filter { $0.kind == .clip } + records + pending.filter(\.deleted)
    }

    /// The person confirmed that the computer received a flash: its items count as delivered,
    /// exactly as an acknowledged Link frame does.
    public func recordFlash(_ items: [LinkItem], to endpointID: String, at date: Date = Date()) {
        let kept = acknowledge(items, by: endpointID, at: date)
        update(endpointID) { computer in
            computer.itemsSent += kept
            computer.lastFlashAt = date
        }
    }

    /// A confirmed flash, as above. A confirmed Everything flash also moves where the next one
    /// goes on from: after the last record it carried, or back to the first record once it
    /// carried all that was left (nothing left out). The place only moves forward: a flash
    /// that carried only records from before it (Not sent yet ones, `flashItems`) leaves it
    /// where it was, so the round does not carry again what it already carried.
    public func recordFlash(_ plan: LinkFlashPlan, everything: Bool, to endpointID: String, at date: Date = Date()) {
        recordFlash(plan.items, to: endpointID, at: date)
        guard everything else { return }
        update(endpointID) { computer in
            if plan.leftOut == 0 {
                computer.flashResume = nil
            } else if let last = plan.items.last(where: { !$0.deleted && $0.kind != .clip }),
                      computer.flashResume?.precedes(last) ?? true {
                computer.flashResume = LinkFlashResume(after: last)
            }
        }
    }

    /// Applies a computer's `welcome` (`LinkDeliveryState.adopt`). When it forgets what was
    /// sent (a different database, or the computer asked for everything), it also forgets
    /// where an Everything flash would go on from: the new database holds none of the round's
    /// earlier flashes. Returns true when it forgot.
    @discardableResult
    public func adopt(computerID id: String, resendAll: Bool, for endpointID: String) -> Bool {
        let forgot = updateDelivery(for: endpointID) { $0.adopt(computerID: id, resendAll: resendAll) }
        if forgot { update(endpointID) { $0.flashResume = nil } }
        return forgot
    }

    /// "Send everything again": forgets what this computer was sent, and where an Everything
    /// flash would go on from, so the next Link sync and the next Everything flash both
    /// carry the whole library from its first record.
    public func forgetDeliveries(for endpointID: String) {
        updateDelivery(for: endpointID) { $0.forgetDeliveries() }
        update(endpointID) { $0.flashResume = nil }
    }

    /// The next Everything flash starts from the first record again.
    public func restartFlashEverything(for endpointID: String) {
        update(endpointID) { $0.flashResume = nil }
    }
}
