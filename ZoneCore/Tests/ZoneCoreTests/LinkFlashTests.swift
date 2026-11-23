// by zayd/cold @ zayd.wtf

import CryptoKit
import XCTest
@testable import ZoneCore

/// The receiving half of Flash, written from PROTOCOL.md for these tests: each frame is a row
/// (which chunks, the body), solved by elimination over GF(2). The phone never needs it.
struct FlashTestDecoder {
    private(set) var session: UInt32?
    private(set) var total = 0
    private(set) var chunkCount = 0
    private(set) var chunkBytes = 0
    /// Pivot chunk to (the chunks this row mentions, as bits; the XOR of their bodies, as
    /// 64-bit words so a row is combined eight bytes at a time).
    private var rows: [Int: (mask: [UInt64], body: [UInt64])] = [:]
    private(set) var framesUsed = 0

    var isComplete: Bool { chunkCount > 0 && rows.count == chunkCount }

    /// Takes one frame. Returns false when it is not a frame of this flash.
    @discardableResult
    mutating func add(_ frame: Data) -> Bool {
        let bytes = [UInt8](frame)
        guard bytes.count > LinkFlashFormat.headerBytes, Array(bytes[0..<3]) == [0x5a, 0x46, 0x31] else { return false }
        func u32(_ at: Int) -> UInt32 { bytes[at..<(at + 4)].reduce(0) { $0 << 8 | UInt32($1) } }
        let frameSession = u32(3), length = Int(u32(7)), count = Int(bytes[11]) << 8 | Int(bytes[12]), index = u32(13)
        let body = Array(bytes[LinkFlashFormat.headerBytes...])
        if session == nil {
            session = frameSession; total = length; chunkCount = count; chunkBytes = body.count
        }
        guard frameSession == session, length == total, count == chunkCount, body.count == chunkBytes, count > 0 else { return false }
        guard !isComplete else { return true }
        framesUsed += 1

        var mask = [UInt64](repeating: 0, count: (count + 63) / 64)
        for chunk in LinkFlashEncoder.chunkSet(session: frameSession, index: index, chunkCount: count) {
            mask[chunk / 64] |= 1 << UInt64(chunk % 64)
        }
        var value = Self.words(body)
        while let pivot = Self.highest(mask) {
            guard let other = rows[pivot] else {
                rows[pivot] = (mask, value)
                break
            }
            for word in mask.indices { mask[word] ^= other.mask[word] }
            for offset in value.indices { value[offset] ^= other.body[offset] }
        }
        return true
    }

    /// The payload, once there are as many independent rows as chunks.
    func payload() -> Data? {
        guard isComplete else { return nil }
        var solved = [[UInt64]](repeating: [], count: chunkCount)
        // Lowest pivot first: a row only mentions its pivot and lower chunks.
        for pivot in 0..<chunkCount {
            guard var (mask, value) = rows[pivot] else { return nil }
            mask[pivot / 64] &= ~(1 << UInt64(pivot % 64))
            while let chunk = Self.highest(mask) {
                for offset in value.indices { value[offset] ^= solved[chunk][offset] }
                mask[chunk / 64] &= ~(1 << UInt64(chunk % 64))
            }
            solved[pivot] = value
        }
        var out = Data(capacity: chunkCount * chunkBytes)
        for chunk in solved {
            out.append(contentsOf: chunk.flatMap { word in (0..<8).map { UInt8(word >> UInt64(8 * $0) & 0xff) } }.prefix(chunkBytes))
        }
        return out.prefix(total)
    }

    private static func words(_ bytes: [UInt8]) -> [UInt64] {
        var out = [UInt64](repeating: 0, count: (bytes.count + 7) / 8)
        for (index, byte) in bytes.enumerated() { out[index / 8] |= UInt64(byte) << UInt64(8 * (index % 8)) }
        return out
    }

    private static func highest(_ mask: [UInt64]) -> Int? {
        for word in mask.indices.reversed() where mask[word] != 0 {
            return word * 64 + 63 - mask[word].leadingZeroBitCount
        }
        return nil
    }

    static func decode(_ frames: [Data]) -> Data? {
        var decoder = FlashTestDecoder()
        for frame in frames {
            decoder.add(frame)
            if decoder.isComplete { break }
        }
        return decoder.payload()
    }
}

enum FlashFixtures {
    /// The pairing secret of the vector the computer side publishes: `ab` 32 times.
    static let secretHex = String(repeating: "ab", count: 32)
    static let keyHex = "a00f0027d0be63dc4d0e64abf643d94be5f261dc0e4502d7028dc0e2c20f56fc"
    static let endpoint = "523c7996bad77424e96786cf7a7205115337a5b4565cd25506a0f297b191a5ea"
    static let phone = LinkPhone(id: "0F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F0", name: "Zone test iPhone", app: "1.0.3 (test)")

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static func bytes(hex: String) -> Data {
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    private static let sentences = [
        "Can you send me the draft before lunch", "Running ten minutes late, start without me",
        "Remind me to call the dentist on Thursday", "The build passed, shipping it this afternoon",
        "Let us move the review to next week", "Pick up oat milk and coffee on the way home",
        "That sounds good, see you at seven", "I think the second option is the better one",
        "Book the train for the ninth and send me the times", "The invoice went out this morning",
    ]

    /// A library with stable ids and varied words: dictations, a note for every ten, one meeting.
    static func library(dictations: Int) -> [LinkItem] {
        let records = (0..<dictations).map { number -> TranscriptRecord in
            let words = "\(sentences[number % sentences.count]), item \(number * 7919 % 10_007). \(sentences[(number * 3 + 1) % sentences.count])."
            return LinkFixtures.dictation(number, text: words, source: number % 4 == 0 ? .app : .keyboard)
        }
        let notes = (0..<max(1, dictations / 10)).map { LinkFixtures.note($0, text: "Note \($0): \(sentences[($0 + 5) % sentences.count]).") }
        return LinkEncoding.library(dictations: records, notes: notes, meetings: [LinkFixtures.meeting()])
    }
}

final class LinkFlashTests: XCTestCase {
    // MARK: The key

    func testFlashKeyMatchesTheComputerSideVector() throws {
        let link = LinkPairingLink(endpointID: FlashFixtures.endpoint, secret: FlashFixtures.secretHex, name: "frostbyte")
        XCTAssertEqual(link.secretBytes, Data(repeating: 0xab, count: 32), "the secret is used as bytes, not as hex text")
        XCTAssertEqual(FlashFixtures.hex(link.flashKey), FlashFixtures.keyHex)
    }

    // MARK: The fountain code, against scripts/flash_reference.py

    private func referencePayload() -> Data {
        Data((0..<1280).map { UInt8(($0 * 7 + 3) & 0xff) })
    }

    func testReferenceVector() throws {
        let encoder = try LinkFlashEncoder(payload: referencePayload(), session: 0x0102_0304, chunkBytes: 300)
        XCTAssertEqual(encoder.chunkCount, 5)
        XCTAssertEqual(encoder.cycleLength, 75)
        let sets = (5...12).map { LinkFlashEncoder.chunkSet(session: 0x0102_0304, index: UInt32($0), chunkCount: 5) }
        XCTAssertEqual(sets, [[1], [0, 3], [1], [0, 3, 4], [1, 2, 4], [1], [1, 2, 3], [2, 4]])

        let frames = (0..<40).map { encoder.frame(UInt32($0)) }
        XCTAssertTrue(frames.allSatisfy { $0.count == 317 })
        XCTAssertEqual(FlashFixtures.hex(frames[0].prefix(32)), "5a46310102030400000500000500000000030a11181f262d343b424950575e65")
        XCTAssertEqual(FlashFixtures.hex(frames[7].prefix(32)), "5a46310102030400000500000500000007373e454c535a61686f767d848b9299")
        let digest = SHA256.hash(data: frames.reduce(into: Data()) { $0.append($1) })
        XCTAssertEqual(digest.map { String(format: "%02x", $0) }.joined(),
                       "16e659e1a7b1a24735a6f04aeca9514d3ab1a59f285993c2b1e6e97a00c39b12")
    }

    func testPlainFramesAreTheChunksInOrder() throws {
        let payload = referencePayload()
        let encoder = try LinkFlashEncoder(payload: payload, session: 7, chunkBytes: 300)
        let joined = (0..<5).reduce(into: Data()) { $0.append(encoder.frame(UInt32($1)).dropFirst(17)) }
        XCTAssertEqual(joined.prefix(1280), payload)
        XCTAssertEqual(joined.suffix(220), Data(count: 220), "the last chunk is zero padded")
    }

    func testAnEmptyChoiceFallsBackToOneChunk() {
        // With one chunk, a coded frame whose word has bit 0 clear chooses nothing: it is chunk 0.
        for index in 1..<200 {
            XCTAssertEqual(LinkFlashEncoder.chunkSet(session: 99, index: UInt32(index), chunkCount: 1), [0])
        }
        // With two chunks, about a quarter of the words choose neither.
        let sets = (2..<400).map { LinkFlashEncoder.chunkSet(session: 99, index: UInt32($0), chunkCount: 2) }
        XCTAssertTrue(sets.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(sets), [[0], [1], [0, 1]])
        for index in 2..<400 where sets[index - 2].count == 1 {
            let words = LinkFlashEncoder.mixWords(session: 99, index: UInt32(index), count: 1)
            if words[0] & 3 == 0 { XCTAssertEqual(sets[index - 2], [index % 2], "an empty set is chunk i mod k") }
        }
    }

    func testSetsUseEveryWordPastSixtyFourChunks() {
        let set = LinkFlashEncoder.chunkSet(session: 0xA1B2_C3D4, index: 5_000, chunkCount: 200)
        XCTAssertTrue(set.contains { $0 >= 128 } && set.contains { $0 < 64 })
        XCTAssertTrue(set.allSatisfy { $0 < 200 })
        XCTAssertEqual(set, set.sorted())
        XCTAssertTrue((80...120).contains(set.count), "about half the chunks, got \(set.count)")
    }

    func testEncoderRefusesWhatTheHeaderCannotSay() {
        XCTAssertThrowsError(try LinkFlashEncoder(payload: Data(), session: 1)) { XCTAssertEqual($0 as? LinkFlashEncoder.Failure, .empty) }
        XCTAssertThrowsError(try LinkFlashEncoder(payload: Data(count: 10), session: 1, chunkBytes: 0)) {
            XCTAssertEqual($0 as? LinkFlashEncoder.Failure, .badChunkSize)
        }
        XCTAssertThrowsError(try LinkFlashEncoder(payload: Data(count: 65_536), session: 1, chunkBytes: 1)) {
            XCTAssertEqual($0 as? LinkFlashEncoder.Failure, .tooLarge(chunks: 65_536))
        }
        XCTAssertNoThrow(try LinkFlashEncoder(payload: Data(count: 65_535), session: 1, chunkBytes: 1))
    }

    // MARK: Round trips through the decoder

    func testDecodesFromCodedFramesOnly() throws {
        let payload = referencePayload()
        let encoder = try LinkFlashEncoder(payload: payload, session: 0x0102_0304, chunkBytes: 300)
        let frames = (0..<40).map { encoder.frame(UInt32($0)) }
        XCTAssertEqual(FlashTestDecoder.decode(Array(frames[..<5])), payload)
        XCTAssertEqual(FlashTestDecoder.decode(Array(frames[5...])), payload, "no plain frame at all")
        XCTAssertEqual(FlashTestDecoder.decode(frames[3..<30].reversed()), payload, "any order")
        XCTAssertNil(FlashTestDecoder.decode(Array(frames[..<4])), "four frames cannot hold five chunks")
    }

    func testALargePayloadFromCodedFramesOnly() throws {
        // The same case scripts/flash_reference.py checks: 400 kB, frames k to 2k+20.
        let payload = Data((0..<400_000).map { UInt8(($0 * 31 + 5) & 0xff) })
        let encoder = try LinkFlashEncoder(payload: payload, session: 0xA1B2_C3D4, chunkBytes: 300)
        XCTAssertEqual(encoder.chunkCount, 1334)
        var decoder = FlashTestDecoder()
        for index in 1334..<(2 * 1334 + 20) {
            decoder.add(encoder.frame(UInt32(index)))
            if decoder.isComplete { break }
        }
        XCTAssertEqual(decoder.payload(), payload)
        XCTAssertLessThanOrEqual(decoder.framesUsed, 1334 + 20)
    }

    func testSurvivesLostFramesAndASecondCycle() throws {
        var generator = SystemRandomNumberGenerator()
        for size in [1, 299, 300, 301, 4_000, 19_333] {
            let payload = Data((0..<size).map { _ in UInt8.random(in: 0...255, using: &generator) })
            let encoder = try LinkFlashEncoder(payload: payload, session: .random(in: 1...UInt32.max))
            var decoder = FlashTestDecoder()
            var shown = 0
            // A camera that misses four frames in ten, watching the phone loop.
            while !decoder.isComplete, shown < 20 * encoder.cycleLength {
                let index = UInt32(shown % encoder.cycleLength)
                shown += 1
                if Int.random(in: 0..<10, using: &generator) < 4 { continue }
                decoder.add(encoder.frame(index))
            }
            XCTAssertEqual(decoder.payload(), payload, "size \(size)")
            XCTAssertLessThan(shown, 3 * encoder.chunkCount + 120, "size \(size) took \(shown) frames for \(encoder.chunkCount) chunks")
        }
    }

    func testFramesFromAnotherFlashAreIgnored() throws {
        let one = try LinkFlashEncoder(payload: referencePayload(), session: 1)
        let two = try LinkFlashEncoder(payload: Data(referencePayload().reversed()), session: 2)
        var decoder = FlashTestDecoder()
        XCTAssertTrue(decoder.add(one.frame(0)))
        XCTAssertFalse(decoder.add(two.frame(1)))
        XCTAssertFalse(decoder.add(Data("not a frame".utf8)))
        for index in 1..<5 { decoder.add(one.frame(UInt32(index))) }
        XCTAssertEqual(decoder.payload(), referencePayload())
    }

    // MARK: The payload

    func testPayloadJSONHasTheProtocolShape() throws {
        let items = FlashFixtures.library(dictations: 3)
        let json = try LinkFlashPayload.json(phone: FlashFixtures.phone, items: items)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(object["t"] as? String, "flash")
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(object["phone"] as? [String: String],
                       ["id": FlashFixtures.phone.id, "name": "Zone test iPhone", "app": "1.0.3 (test)"])
        XCTAssertEqual((object["items"] as? [[String: Any]])?.count, items.count)
        XCTAssertTrue(String(decoding: json, as: UTF8.self).hasPrefix(#"{"t":"flash","v":1,"phone":{"#))
        // The items are byte for byte what a Link frame carries.
        let link = try LinkMessage.items(seq: 1, items: items).encoded()
        let tail = try XCTUnwrap(String(decoding: link, as: UTF8.self).range(of: #""items":["#)).lowerBound
        XCTAssertTrue(String(decoding: json, as: UTF8.self).hasSuffix(String(String(decoding: link, as: UTF8.self)[tail...])))

        let empty = try LinkFlashPayload.json(phone: FlashFixtures.phone, items: [])
        XCTAssertTrue(String(decoding: empty, as: UTF8.self).hasSuffix(#""items":[]}"#))
    }

    func testSealedLayoutIsNonceCiphertextTag() throws {
        let key = FlashFixtures.bytes(hex: FlashFixtures.keyHex)
        let json = try LinkFlashPayload.json(phone: FlashFixtures.phone, items: FlashFixtures.library(dictations: 20))
        let packed = try LinkFlashPayload.deflate(json)
        XCTAssertLessThan(packed.count, json.count / 2)
        XCTAssertNotEqual(packed.first, 0x78, "raw DEFLATE has no zlib header")
        XCTAssertNotEqual(Array(packed.prefix(2)), [0x1f, 0x8b], "and no gzip header")
        XCTAssertEqual(try LinkFlashPayload.inflate(packed), json)

        let nonce = Data(0..<12)
        let sealed = try LinkFlashPayload.seal(json, key: key, nonce: nonce)
        XCTAssertEqual(sealed.count, 12 + packed.count + 16)
        XCTAssertEqual(sealed.prefix(12), nonce)
        // The same bytes CryptoKit gives when asked for the three parts one at a time.
        let box = try ChaChaPoly.seal(packed, using: SymmetricKey(data: key), nonce: try ChaChaPoly.Nonce(data: nonce))
        XCTAssertEqual(sealed, Data(nonce) + box.ciphertext + box.tag)
        XCTAssertEqual(try LinkFlashPayload.open(sealed, key: key), json)

        let other = try LinkFlashPayload.seal(json, key: key)
        XCTAssertNotEqual(other.prefix(12), try LinkFlashPayload.seal(json, key: key).prefix(12), "a fresh nonce every time")
    }

    func testAWrongKeyOrAChangedByteDoesNotOpen() throws {
        let key = FlashFixtures.bytes(hex: FlashFixtures.keyHex)
        let json = try LinkFlashPayload.json(phone: FlashFixtures.phone, items: FlashFixtures.library(dictations: 5))
        let sealed = try LinkFlashPayload.seal(json, key: key)
        var wrong = key
        wrong[0] ^= 1
        XCTAssertThrowsError(try LinkFlashPayload.open(sealed, key: wrong)) { XCTAssertEqual($0 as? LinkFlashPayload.Failure, .damaged) }
        for position in [0, 12, sealed.count / 2, sealed.count - 1] {
            var changed = sealed
            changed[position] ^= 0x40
            XCTAssertThrowsError(try LinkFlashPayload.open(changed, key: key), "byte \(position)")
        }
        XCTAssertThrowsError(try LinkFlashPayload.seal(json, key: Data(count: 16))) { XCTAssertEqual($0 as? LinkFlashPayload.Failure, .badKey) }
        XCTAssertThrowsError(try LinkFlashPayload.open(sealed, key: Data(count: 31))) { XCTAssertEqual($0 as? LinkFlashPayload.Failure, .badKey) }
    }

    // MARK: A whole flash

    func testALibraryGoesThroughFramesAndComesBackTheSame() throws {
        let key = FlashFixtures.bytes(hex: FlashFixtures.keyHex)
        let items = FlashFixtures.library(dictations: 600) + [LinkItem.deletion(id: LinkFixtures.uuid(9_999).uuidString, kind: .dictation, at: 1_794_445_300)]
        let plan = try LinkFlash.plan(items: items, phone: FlashFixtures.phone, key: key)
        XCTAssertEqual(plan.items, items)
        XCTAssertEqual(plan.leftOut, 0)
        XCTAssertGreaterThan(plan.encoder.chunkCount, 20)

        // Coded frames only, a third of them lost.
        var decoder = FlashTestDecoder()
        var index = plan.encoder.chunkCount
        while !decoder.isComplete, index < plan.encoder.cycleLength {
            if index % 3 != 0 { decoder.add(plan.encoder.frame(UInt32(index))) }
            index += 1
        }
        let sealed = try XCTUnwrap(decoder.payload())
        let json = try LinkFlashPayload.open(sealed, key: key)
        XCTAssertEqual(json.count, plan.jsonBytes)
        struct Flash: Decodable { let t: String; let v: Int; let phone: LinkPhone; let items: [LinkItem] }
        let flash = try JSONDecoder().decode(Flash.self, from: json)
        XCTAssertEqual(flash.t, "flash")
        XCTAssertEqual(flash.phone, FlashFixtures.phone)
        XCTAssertEqual(flash.items, items)
        XCTAssertEqual(flash.items.last?.deleted, true)
    }

    func testAPlanTakesWhatFitsFromTheFront() throws {
        let key = FlashFixtures.bytes(hex: FlashFixtures.keyHex)
        let items = FlashFixtures.library(dictations: 400)
        let whole = try LinkFlash.plan(items: items, phone: FlashFixtures.phone, key: key)
        let limit = whole.encoder.chunkCount / 3
        let part = try LinkFlash.plan(items: items, phone: FlashFixtures.phone, key: key, maxChunks: limit)
        XCTAssertLessThanOrEqual(part.encoder.chunkCount, limit)
        XCTAssertGreaterThan(part.items.count, items.count / 5)
        XCTAssertEqual(part.items, Array(items.prefix(part.items.count)), "the front of the list, in order")
        XCTAssertEqual(part.leftOut, items.count - part.items.count)
        XCTAssertGreaterThan(part.leftOut, 0)

        XCTAssertThrowsError(try LinkFlash.plan(items: [], phone: FlashFixtures.phone, key: key)) {
            XCTAssertEqual($0 as? LinkFlash.Failure, .nothingToSend)
        }
        let huge = LinkItem(id: LinkFixtures.uuid(1).uuidString, kind: .note, createdAt: 1, updatedAt: 1,
                            text: (0..<4_000).map { "\($0 * 7919 % 10_007)" }.joined(separator: " ")).stamped()
        XCTAssertThrowsError(try LinkFlash.plan(items: [huge], phone: FlashFixtures.phone, key: key, maxChunks: 2)) {
            XCTAssertEqual($0 as? LinkFlash.Failure, .tooLarge)
        }
    }

    // MARK: The playhead

    func testThePlayheadFollowsTheClockAndStartsAgain() {
        // k = 5: 75 frames a pass, twelve a second.
        XCTAssertEqual(LinkFlashPlayhead(elapsed: 0, cycleLength: 75, framesPerSecond: 12).frame, 0)
        XCTAssertEqual(LinkFlashPlayhead(elapsed: 0.08, cycleLength: 75, framesPerSecond: 12).frame, 0)
        XCTAssertEqual(LinkFlashPlayhead(elapsed: 0.09, cycleLength: 75, framesPerSecond: 12).frame, 1)
        XCTAssertEqual(LinkFlashPlayhead(elapsed: 1, cycleLength: 75, framesPerSecond: 12).frame, 12)
        let last = LinkFlashPlayhead(elapsed: 74.5 / 12, cycleLength: 75, framesPerSecond: 12)
        XCTAssertEqual([last.pass, last.frame], [1, 74])
        let again = LinkFlashPlayhead(elapsed: 75.5 / 12, cycleLength: 75, framesPerSecond: 12)
        XCTAssertEqual([again.pass, again.frame], [2, 0], "after 3k + 60 frames it starts again from frame 0")
        XCTAssertEqual(LinkFlashPlayhead(elapsed: -3, cycleLength: 75, framesPerSecond: 12).frame, 0)
        XCTAssertEqual(LinkFlashPlayhead(elapsed: .infinity, cycleLength: 75, framesPerSecond: 12).cycleLength, 75)

        let line = LinkFlashPlayhead(elapsed: (1354.0 + 339.5) / 12, cycleLength: 1354, framesPerSecond: 12).line
        XCTAssertTrue(line.hasPrefix("Pass 2, 340 of "), line)
        XCTAssertFalse(line.contains("\u{2014}"))
    }

    func testTheDefaultIsTwentyCodesOfNineHundredBytes() {
        XCTAssertEqual(LinkFlashFormat.framesPerSecond, 20)
        XCTAssertEqual(LinkFlashFormat.chunkBytes, 900)
        XCTAssertEqual(LinkFlashMode.color.codesPerPicture, 3)
        XCTAssertEqual(LinkFlashMode.blackAndWhite.codesPerPicture, 1)
        XCTAssertEqual(LinkFlashMode.blackAndWhite.chunkBytes, 900)
        // Twenty a second: a frame every 50 ms, three refreshes of a 60 Hz screen.
        XCTAssertEqual(LinkFlashPlayhead(elapsed: 0.049, cycleLength: 100).frame, 0)
        XCTAssertEqual(LinkFlashPlayhead(elapsed: 0.051, cycleLength: 100).frame, 1)
        XCTAssertEqual(LinkFlashPlayhead(elapsed: 1, cycleLength: 100).frame, 20)
    }

    func testAPlanCarriesItsRateAndTheEstimateUsesIt() throws {
        let key = FlashFixtures.bytes(hex: FlashFixtures.keyHex)
        let items = FlashFixtures.library(dictations: 400)
        let fast = try LinkFlash.plan(items: items, phone: FlashFixtures.phone, key: key)
        XCTAssertEqual(fast.framesPerSecond, 20)
        XCTAssertEqual(fast.encoder.chunkBytes, 900)
        XCTAssertEqual(fast.seconds, Double(fast.encoder.chunkCount + 10) / 20, accuracy: 1e-9)
        let larger = try LinkFlash.plan(items: items, phone: FlashFixtures.phone, key: key,
                                        chunkBytes: 300, framesPerSecond: 12)
        XCTAssertEqual(larger.framesPerSecond, 12)
        XCTAssertGreaterThan(larger.encoder.chunkCount, 2 * fast.encoder.chunkCount)
        XCTAssertGreaterThan(larger.seconds, 3 * fast.seconds, "fast is three to five times quicker, more the larger the flash")
    }

    // MARK: What counts as delivered

    func testAConfirmedFlashCountsAsDelivered() throws {
        let phone = LinkTestPhone()
        for number in 1...5 { phone.dictate(number) }
        let pending = phone.delivery.pending(library: phone.library(), deletions: phone.log.all())
        XCTAssertEqual(pending.count, 5)

        // Showing the flash changes nothing: the phone cannot know the computer saw it.
        _ = try LinkFlash.plan(items: pending, phone: FlashFixtures.phone, key: FlashFixtures.bytes(hex: FlashFixtures.keyHex))
        XCTAssertEqual(phone.store.pendingCount(for: phone.endpointID, library: phone.library(), deletions: phone.log.all()), 5)
        XCTAssertNil(phone.store.computer(phone.endpointID)?.lastFlashAt)

        // The person says the computer received it.
        let when = Date(timeIntervalSince1970: 1_794_600_000)
        phone.store.recordFlash(pending, to: phone.endpointID, at: when)
        XCTAssertEqual(phone.store.pendingCount(for: phone.endpointID, library: phone.library(), deletions: phone.log.all()), 0)
        XCTAssertEqual(phone.store.computer(phone.endpointID)?.itemsSent, 5)
        XCTAssertEqual(phone.store.computer(phone.endpointID)?.lastFlashAt, when)

        // A new dictation and a delete are the only things left for the next flash.
        phone.dictate(6)
        phone.history.delete(id: LinkFixtures.uuid(2))
        let next = phone.delivery.pending(library: phone.library(), deletions: phone.log.all())
        XCTAssertEqual(next.map(\.id), [LinkFixtures.uuid(6).uuidString, LinkFixtures.uuid(2).uuidString])
        XCTAssertEqual(next.map(\.deleted), [false, true])
        phone.store.recordFlash(next, to: phone.endpointID)
        XCTAssertEqual(phone.store.computer(phone.endpointID)?.itemsSent, 6, "a deletion is not an item sent")
        XCTAssertTrue(phone.delivery.pending(library: phone.library(), deletions: phone.log.all()).isEmpty)
    }

    func testAFlashToAComputerNeverConnectedSurvivesItsFirstLinkSession() async throws {
        // Paired by scanning while the network was blocked: no welcome yet, so no database id.
        let phone = LinkTestPhone()
        for number in 1...4 { phone.dictate(number) }
        XCTAssertNil(phone.delivery.computerID)
        XCTAssertEqual(phone.store.computer(phone.endpointID)?.confirmed, false)
        phone.store.recordFlash(phone.delivery.pending(library: phone.library(), deletions: []), to: phone.endpointID)

        // Later the network works. The first welcome names the database; what was flashed stays delivered.
        phone.dictate(5)
        let sync = LinkComputerSync(endpointID: phone.endpointID, store: phone.store, deletions: phone.log) { phone.library() }
        let toSend = await sync.welcomed(by: LinkComputer(id: "DB-1", name: "testbox"), itemsOnComputer: 4, resendAll: false)
        XCTAssertEqual(toSend.map(\.id), [LinkFixtures.uuid(5).uuidString])
        XCTAssertEqual(phone.delivery.computerID, "DB-1")

        // A computer that asks for everything still gets everything.
        let again = await sync.welcomed(by: LinkComputer(id: "DB-1"), itemsOnComputer: 0, resendAll: true)
        XCTAssertEqual(again.count, 5)
    }

    func testAComputerSavedBeforeFlashStillLoads() throws {
        // computers.json written before lastFlashAt existed.
        let old = #"[{"endpointID":"abc","name":"box","pairedAt":0,"confirmed":true,"itemsSent":3,"needsPairing":false}]"#
        let computers = try JSONDecoder().decode([PairedComputer].self, from: Data(old.utf8))
        XCTAssertEqual(computers.first?.itemsSent, 3)
        XCTAssertNil(computers.first?.lastFlashAt)
    }
}
