// by zayd/cold @ zayd.wtf

import CryptoKit
import XCTest
@testable import ZoneCore

/// Synthetic items that are hard to carry exactly: times on both sides of daylight saving
/// changes, several at the same instant, very old and far future ones, fractions a Date makes,
/// and text with emoji, right-to-left scripts, NUL, escapes and a very long line.
enum FlashEdgeItems {
    static func id(_ n: Int) -> String { LinkFixtures.uuid(70_000 + n).uuidString }

    static func utc(_ text: String) -> Double {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)!.timeIntervalSince1970
    }

    static func dictation(_ n: Int, at created: Double, updated: Double? = nil, text: String,
                          source: String = "keyboard") -> LinkItem {
        LinkItem(id: id(n), kind: .dictation, source: source, createdAt: created, updatedAt: updated ?? created, text: text,
                 durationS: 1.25 + Double(n) / 8, engine: "fluidMini", status: "inserted").stamped()
    }

    static func library() -> [LinkItem] {
        var items: [LinkItem] = []
        // Los Angeles springs forward at 10:00 UTC on March 8, 2026 and falls back at 09:00
        // UTC on November 1, 2026: 01:30 local happens twice that night.
        let spring = utc("2026-03-08T10:00:00Z")
        items.append(dictation(1, at: spring - 0.000_123, text: "Just before the clocks change \u{1F551}"))
        items.append(dictation(2, at: spring + 0.5, text: "Just after the clocks change"))
        items.append(LinkItem(id: id(3), kind: .note, createdAt: utc("2026-11-01T08:30:00Z") + 0.25,
                              updatedAt: utc("2026-11-01T08:30:00Z") + 0.25,
                              text: "\u{05E9}\u{05DC}\u{05D5}\u{05DD} \u{05E2}\u{05D5}\u{05DC}\u{05DD}, the first half past one").stamped())
        items.append(LinkItem(id: id(4), kind: .note, createdAt: utc("2026-11-01T09:30:00Z") + 0.25,
                              updatedAt: utc("2026-11-01T09:30:00Z") + 0.25,
                              text: "\u{0645}\u{0631}\u{062D}\u{0628}\u{0627} \u{0628}\u{0627}\u{0644}\u{0639}\u{0627}\u{0644}\u{0645}, the second half past one").stamped())
        // Three at the same instant.
        for n in 5...7 { items.append(dictation(n, at: 1_794_445_200.123_456, text: "Same moment, number \(n)")) }
        // Very old, the epoch, before it, and far in the future.
        items.append(dictation(8, at: 978_307_200.000_001, text: "a\u{0}b, e\u{301}t\u{E9}, NUL and a combining accent"))
        items.append(dictation(9, at: 0.5, text: "Half a second after 1970 began"))
        items.append(dictation(10, at: -86_400.25, text: "A day before 1970"))
        items.append(dictation(11, at: 4_102_444_800.987_654, text: "New year 2100"))
        items.append(dictation(12, at: 253_402_300_799.999, text: "The last second of 9999"))
        // Edited before it was made: a clock that moved back.
        items.append(dictation(13, at: 1_794_445_200.5, updated: 1_794_445_100.25, text: "Updated before created"))
        items.append(dictation(14, at: 1_794_445_201,
                               text: "\"quotes\" \\ back / slash \t tab \r\n new line \u{2028} separator \u{FEFF} BOM \u{1D11E} clef \u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466} \u{1F3F3}\u{FE0F}\u{200D}\u{1F308}"))
        // One very long line.
        let long = (0..<6_000).map { "word\($0 * 7919 % 10_007)" }.joined(separator: " ")
        items.append(LinkItem(id: id(15), kind: .note, createdAt: 1_794_445_202.75, updatedAt: 1_794_445_202.75, text: long).stamped())
        // Times as a Date makes them: seconds since 2001 with all their binary digits.
        var state: UInt64 = 0x5EED_F1A5
        for n in 16..<56 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let since2001 = 700_000_000 + Double(state >> 11) / Double(UInt64(1) << 53) * 200_000_000
            let created = LinkEncoding.seconds(Date(timeIntervalSinceReferenceDate: since2001))
            items.append(dictation(n, at: created, updated: created + Double(n % 3) * 0.1,
                                   text: "Dictation \(n) at a time with every binary digit used", source: n % 5 == 0 ? "app" : "keyboard"))
        }
        // A meeting, with segments.
        let segments: [LinkJSON] = (0..<6).map { n in
            .object(["speaker": n % 2 == 0 ? .string("Speaker \u{00C5}sa") : .null, "start": .number(Double(n) * 7.125),
                     "end": .number(Double(n) * 7.125 + 6.5), "text": .string("Segment \(n), \u{1F4C8} numbers up")])
        }
        items.append(LinkItem(id: id(56), kind: .meeting, createdAt: 1_794_440_000.333, updatedAt: 1_794_443_600.666,
                              text: "Speaker \u{00C5}sa: Segment 0\nSegment 1", title: "Standup \u{1F680}", durationS: 3_600.5,
                              engine: "parakeet", status: "done", extra: ["segments": .array(segments)]).stamped())
        return items
    }

    /// A clip waiting for the computer, and a deletion of a record it has.
    static let clip = LinkItem(id: id(57), kind: .clip, source: "clipboard", createdAt: 1_794_445_300.125, updatedAt: 1_794_445_300.125,
                               text: "https://example.invalid/path?q=1&r=2")
    static let deletion = LinkDeletion(id: id(58), kind: .dictation, at: 1_794_445_400.5)
}

final class LinkFlashCheckTests: XCTestCase {
    /// The digest of zone-mcp's check vector (`scripts/flash_reference.py`, CHECK_VECTOR, and
    /// `src/flash/check.rs`): the same three items, from the phone's side.
    func testTheDigestMatchesTheComputerSideVector() throws {
        let items = [
            LinkItem(id: "9F1C2E6A-0000-4000-8000-000000000001", kind: .dictation, source: "keyboard", createdAt: 1_794_445_200.25,
                     updatedAt: 1_794_445_203.5, text: "the words", durationS: 4.2, engine: "fluidMini", status: "finished",
                     rev: "5b1f0c9a2d3e4f60"),
            LinkItem(id: "9F1C2E6A-0000-4000-8000-000000000002", kind: .note, createdAt: 1_804_773_829.042_786_6,
                     updatedAt: 1_804_773_829.042_786_6, text: "caf\u{E9} \u{1F600} \u{05E9}\u{05DC}\u{05D5}\u{05DD} a\u{0}b"),
            LinkItem.deletion(id: "9F1C2E6A-0000-4000-8000-000000000003", kind: .dictation, at: 1_794_445_300),
        ]
        XCTAssertEqual(LinkFlashCheck.digest(items), "9bbd47a61c92a30de9cbd968fa4de4bed8e6d230d17ed7dabbfa6a63f3d02a6f")
        let check = LinkFlashCheck(items: items)
        XCTAssertEqual(check.items, 3)
        XCTAssertEqual(check.oldest, 1_794_445_200.25)
        XCTAssertEqual(check.newest, 1_804_773_829.042_786_6, "a deletion's time is not a created time")
        XCTAssertEqual(LinkFlashCheck(items: [items[2]]).oldest, nil)
        // Minus zero is written as zero.
        let zero = LinkItem(id: "Z", kind: .note, createdAt: 0, updatedAt: 0, text: nil)
        let minus = LinkItem(id: "Z", kind: .note, createdAt: -0.0, updatedAt: -0.0, text: nil)
        XCTAssertEqual(LinkFlashCheck.digest([zero]), LinkFlashCheck.digest([minus]))
    }

    /// Every time the phone writes reads back as the same double, to the last bit: what the
    /// computer's digest checks.
    func testTimesAreWrittenToTheLastBit() throws {
        var state: UInt64 = 0xC0FF_EE00
        let number = try NSRegularExpression(pattern: #""created_at":([-0-9.eE+]+)"#)
        for _ in 0..<20_000 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let since2001 = 700_000_000 + Double(state >> 11) / Double(UInt64(1) << 53) * 200_000_000
            let time = LinkEncoding.seconds(Date(timeIntervalSinceReferenceDate: since2001))
            let json = String(decoding: try LinkItem(id: "T", kind: .note, createdAt: time, updatedAt: time, text: "t").encoded(), as: UTF8.self)
            let match = try XCTUnwrap(number.firstMatch(in: json, range: NSRange(json.startIndex..., in: json)))
            let written = String(json[Range(match.range(at: 1), in: json)!])
            XCTAssertEqual(Double(written)?.bitPattern, time.bitPattern, written)
        }
    }

    func testTheFlashCarriesItsSummaryBeforeTheItems() throws {
        let items = FlashEdgeItems.library() + [LinkItem.deletion(id: FlashEdgeItems.id(99), kind: .note, at: 1_794_445_500)]
        let json = try LinkFlashPayload.json(phone: FlashFixtures.phone, items: items)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let check = try XCTUnwrap(object["check"] as? [String: Any])
        XCTAssertEqual(check["items"] as? Int, items.count)
        XCTAssertEqual(check["digest"] as? String, LinkFlashCheck.digest(items))
        XCTAssertEqual(check["oldest"] as? Double, -86_400.25)
        XCTAssertEqual(check["newest"] as? Double, 253_402_300_799.999)
        let text = String(decoding: json, as: UTF8.self)
        XCTAssertLessThan(try XCTUnwrap(text.range(of: #""check":"#)).lowerBound, try XCTUnwrap(text.range(of: #""items":["#)).lowerBound)
        // An empty flash says so too.
        let empty = String(decoding: try LinkFlashPayload.json(phone: FlashFixtures.phone, items: []), as: UTF8.self)
        XCTAssertTrue(empty.contains(#""check":{"digest":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","items":0}"#), empty)
    }

    /// A plan is stale once something it carries changed: a record edited or deleted, a clip
    /// taken off the list, a deletion this computer is now spared. Something new since leaves
    /// it current (it goes in the next flash), and so does a record a Link sync delivered.
    func testAPlanKnowsWhenWhatItCarriesChangedUnderIt() throws {
        let key = FlashFixtures.bytes(hex: FlashFixtures.keyHex)
        let items = FlashEdgeItems.library()
        let plan = try LinkFlash.plan(items: items, phone: FlashFixtures.phone, key: key)
        XCTAssertTrue(plan.isCurrent(sending: items, library: items))
        XCTAssertTrue(plan.isMade(from: items))
        var edited = items
        edited[3].text = "changed after the flash was made"
        edited = edited.map { $0.stamped() }
        XCTAssertFalse(plan.isCurrent(sending: edited, library: edited), "one was edited")
        XCTAssertFalse(plan.isMade(from: edited))
        let fewer = Array(items.dropLast())
        XCTAssertFalse(plan.isCurrent(sending: fewer, library: fewer), "one was deleted")
        // New since: the flash still carries nothing out of date, so the codes need not change
        // while they show; a plan made now would carry it too.
        let more = items + [FlashEdgeItems.clip]
        XCTAssertTrue(plan.isCurrent(sending: more, library: items), "one more to send")
        XCTAssertFalse(plan.isMade(from: more))
        // A Link sync delivered the first three as they are: carrying them again is harmless.
        XCTAssertTrue(plan.isCurrent(sending: Array(items.dropFirst(3)), library: items))

        // A clip and a deletion must still be waiting to go.
        let deletion = LinkItem.deletion(id: FlashEdgeItems.deletion.id, kind: .dictation, at: FlashEdgeItems.deletion.at)
        let waiting = [FlashEdgeItems.clip] + items + [deletion]
        let both = try LinkFlash.plan(items: waiting, phone: FlashFixtures.phone, key: key)
        XCTAssertTrue(both.isCurrent(sending: waiting, library: items))
        XCTAssertFalse(both.isCurrent(sending: Array(waiting.dropFirst()), library: items), "the clip was taken off the list")
        XCTAssertFalse(both.isCurrent(sending: Array(waiting.dropLast()), library: items), "the deletion is spared now")

        // A plan that left items for the next flash is current while what it carries is the same.
        let part = try LinkFlash.plan(items: items, phone: FlashFixtures.phone, key: key, chunkBytes: 64, maxChunks: 40)
        XCTAssertGreaterThan(part.leftOut, 0)
        XCTAssertTrue(part.isCurrent(sending: items, library: items))
        XCTAssertTrue(part.isMade(from: items))
        var first = items
        first[0].text = "changed in the part this flash carries"
        first = first.map { $0.stamped() }
        XCTAssertFalse(part.isCurrent(sending: first, library: first))
        // A change among the items left for the next flash does not touch this one: the next
        // flash is made when it is shown.
        var later = items
        later[later.count - 1].text = "changed in the part left for later"
        later = later.map { $0.stamped() }
        XCTAssertTrue(part.isCurrent(sending: later, library: later))
    }

    /// A library too large for one flash is split: no flash goes past what the computer can
    /// solve and check quickly.
    func testNoFlashIsLargerThanTheComputerSolvesQuickly() throws {
        XCTAssertEqual(LinkFlashFormat.planChunks, 4_096)
        let key = FlashFixtures.bytes(hex: FlashFixtures.keyHex)
        let items = FlashFixtures.library(dictations: 3_000)
        // Tiny chunks stand in for a very large library.
        let plan = try LinkFlash.plan(items: items, phone: FlashFixtures.phone, key: key, chunkBytes: 1)
        XCTAssertLessThanOrEqual(plan.encoder.chunkCount, LinkFlashFormat.planChunks)
        XCTAssertGreaterThan(plan.encoder.chunkCount, LinkFlashFormat.planChunks * 3 / 4, "it fills most of the flash")
        XCTAssertGreaterThan(plan.leftOut, 0)
        XCTAssertEqual(plan.items, Array(items.prefix(plan.items.count)))
    }

    /// The name the person compares with the computer's page, and the least time a camera
    /// needs before a Done on the page can be this flash's.
    func testAFlashHasANameAndALeastTime() throws {
        let key = FlashFixtures.bytes(hex: FlashFixtures.keyHex)
        let items = FlashFixtures.library(dictations: 400)
        let color = try LinkFlash.plan(items: items, phone: FlashFixtures.phone, key: key, session: 0x8BAD_F1A5, codesPerPicture: 3)
        // zone's status says `"session": "8badf1a5"` for this flash.
        XCTAssertEqual(color.name, "8bad f1a5")
        XCTAssertEqual(String(format: "%08x", color.encoder.session), color.name.replacingOccurrences(of: " ", with: ""))
        XCTAssertEqual(try LinkFlash.plan(items: items, phone: FlashFixtures.phone, key: key, session: 0x8000_0001).name, "8000 0001")
        XCTAssertEqual(color.minimumSeconds, Double(color.encoder.chunkCount) / 60, accuracy: 1e-9)
        XCTAssertLessThan(color.minimumSeconds, color.seconds)
        let plain = try LinkFlash.plan(items: items, phone: FlashFixtures.phone, key: key)
        XCTAssertEqual(plain.minimumSeconds, Double(plain.encoder.chunkCount) / 20, accuracy: 1e-9)
        XCTAssertNotEqual(plain.name, color.name, "a new flash, a new name")
    }

    /// What Send by Flash with Everything carries, through `LinkStore.flashItems`, is in the
    /// order the fixture below gives the computer side: the waiting clip, the library, the
    /// deletion. Part-way through a round it is the same order: a record from before where the
    /// round goes on from, which the computer does not have as it is, keeps its place in the
    /// library instead of going first or last.
    func testEverythingIsInTheFixturesOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flash-order-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LinkStore(directory: directory)
        let endpointID = "order-test-computer"
        store.add(PairedComputer(endpointID: endpointID, name: "box"))
        store.updateDelivery(for: endpointID) { $0.delivered[FlashEdgeItems.deletion.id] = "0000000000000000" }
        let clip = FlashEdgeItems.clip
        try store.clips.add(clip.text ?? "", source: .clipboard, to: [endpointID], at: Date(timeIntervalSince1970: try XCTUnwrap(clip.createdAt)),
                            id: try XCTUnwrap(UUID(uuidString: clip.id)))
        let library = FlashEdgeItems.library()
        let deletion = LinkItem.deletion(id: FlashEdgeItems.deletion.id, kind: .dictation, at: FlashEdgeItems.deletion.at)
        let ordered = LinkDeliveryState().pending(library: library, deletions: [])

        // As testWriteAFixtureForTheComputerSide builds it. The clip from the outbox carries a
        // rev the fixture's does not, so it is compared by id.
        let fixture = [clip] + ordered + [deletion]
        let everything = store.flashItems(for: endpointID, everything: true, library: library, deletions: [FlashEdgeItems.deletion])
        XCTAssertEqual(everything.map(\.id), fixture.map(\.id))
        XCTAssertEqual(Array(everything.dropFirst()), Array(fixture.dropFirst()))

        // Part-way: an earlier flash carried the first 20 records and the computer has them,
        // except the sixth, which changed (or joined from a backup with its old time) since.
        store.acknowledge(Array(ordered.prefix(20)).enumerated().filter { $0.offset != 5 }.map(\.element), by: endpointID)
        store.update(endpointID) { $0.flashResume = LinkFlashResume(after: ordered[19]) }
        let goingOn = store.flashItems(for: endpointID, everything: true, library: library, deletions: [FlashEdgeItems.deletion])
        let expected = [clip.id] + ordered.enumerated().filter { $0.offset == 5 || $0.offset >= 20 }.map(\.element.id) + [deletion.id]
        XCTAssertEqual(goingOn.map(\.id), expected)
    }

    /// `ZONE_FLASH_FIXTURE=/path/flash-iphone.json swift test --package-path ZoneCore --filter
    /// LinkFlashCheckTests/testWriteAFixtureForTheComputerSide` writes what zone-mcp's break-it
    /// test replays (`tests/fixtures/flash-iphone.json` there): a sealed flash of the edge items
    /// as this phone encodes it, the frames' hash, the order a Link session and a Flash send
    /// them in, and every field as the phone holds it in memory, times as bits. Synthetic
    /// items only, sealed with the published test secret.
    func testWriteAFixtureForTheComputerSide() throws {
        guard let path = ProcessInfo.processInfo.environment["ZONE_FLASH_FIXTURE"] else {
            throw XCTSkip("set ZONE_FLASH_FIXTURE to write the fixture")
        }
        let key = FlashFixtures.bytes(hex: FlashFixtures.keyHex)
        let library = FlashEdgeItems.library()
        let deletions = [FlashEdgeItems.deletion]
        // What a Link session sends a computer that has the deleted record and nothing else.
        let link = LinkDeliveryState(delivered: [FlashEdgeItems.deletion.id: "0000000000000000"])
            .pending(library: library, deletions: deletions)
        // What Send by Flash with Everything sends: the waiting clip, the library, the deletion.
        let flashItems = [FlashEdgeItems.clip] + LinkDeliveryState().pending(library: library, deletions: [])
            + link.filter(\.deleted)
        let plan = try LinkFlash.plan(items: flashItems, phone: FlashFixtures.phone, key: key, session: 0x8BAD_F1A5,
                                      nonce: Data(repeating: 7, count: 12))
        XCTAssertEqual(plan.items.count, flashItems.count)
        // The sealed payload, put back together from the plain frames the phone shows first.
        var sealed = Data()
        for index in 0..<plan.encoder.chunkCount { sealed.append(plan.encoder.frame(UInt32(index)).dropFirst(LinkFlashFormat.headerBytes)) }
        sealed = sealed.prefix(plan.encoder.totalLength)
        XCTAssertNoThrow(try LinkFlashPayload.open(sealed, key: key))
        var frames = SHA256()
        for index in 0..<plan.encoder.cycleLength { frames.update(data: plan.encoder.frame(UInt32(index))) }
        let encoded = try flashItems.map { String(decoding: try $0.encoded(), as: UTF8.self) }
        func bits(_ value: Double?) -> Any { value.map { String(format: "%016llx", $0.bitPattern) } ?? NSNull() }
        func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 { bytes.map { String(format: "%02x", $0) }.joined() }
        let expected: [[String: Any]] = flashItems.map { item in
            [
                "id": item.id, "kind": item.kind.rawValue, "deleted": item.deleted, "source": item.source ?? NSNull(),
                "created_bits": bits(item.deleted ? nil : item.createdAt), "updated_bits": bits(item.updatedAt),
                "text_sha256": item.deleted ? NSNull() : item.text.map { hex(SHA256.hash(data: Data($0.utf8))) } ?? NSNull(),
                "title": item.title ?? NSNull(), "duration_bits": bits(item.durationS), "engine": item.engine ?? NSNull(),
                "status": item.status ?? NSNull(), "rev": item.rev ?? NSNull(),
            ]
        }
        let check = LinkFlashCheck(items: flashItems)
        let fixture: [String: Any] = [
            "about": "Written by ZoneCore LinkFlashCheckTests.testWriteAFixtureForTheComputerSide. Synthetic items, the published test secret (ab x 32).",
            "secret": FlashFixtures.secretHex,
            "session": Int(plan.encoder.session),
            "chunk": plan.encoder.chunkBytes,
            "k": plan.encoder.chunkCount,
            "cycle": plan.encoder.cycleLength,
            "sealed_base64": sealed.base64EncodedString(),
            "frames_sha256": hex(frames.finalize()),
            "phone": ["id": FlashFixtures.phone.id, "name": FlashFixtures.phone.name, "app": FlashFixtures.phone.app],
            "flash_order": flashItems.map(\.id),
            "link_order": link.map(\.id),
            "items_json": "[" + encoded.joined(separator: ",") + "]",
            "expected": expected,
            "check": ["items": check.items, "digest": check.digest, "oldest_bits": bits(check.oldest), "newest_bits": bits(check.newest)],
        ]
        let data = try JSONSerialization.data(withJSONObject: fixture, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: URL(fileURLWithPath: path))
    }
}
