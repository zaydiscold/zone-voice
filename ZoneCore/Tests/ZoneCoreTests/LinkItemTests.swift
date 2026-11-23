// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class LinkItemTests: XCTestCase {
    private func object(_ item: LinkItem) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: item.encoded()) as? [String: Any])
    }

    func testDictationCarriesEveryProtocolField() throws {
        var record = LinkFixtures.dictation(1, text: "  the words \n", at: 1_794_445_200.25)
        record.destination = "MacBook Pro"
        record.recoveredFrom = Date(timeIntervalSince1970: 1_794_000_000)
        let item = try XCTUnwrap(LinkEncoding.item(record))
        let json = try object(item)

        XCTAssertEqual(json["id"] as? String, "9F1C2E6A-0000-4000-8000-000000000001")
        XCTAssertEqual(json["kind"] as? String, "dictation")
        XCTAssertEqual(json["source"] as? String, "keyboard")
        XCTAssertEqual(json["created_at"] as? Double, 1_794_445_201.25)
        XCTAssertEqual(json["updated_at"] as? Double, 1_794_445_203.25)
        XCTAssertEqual(json["text"] as? String, "the words")
        XCTAssertTrue(json["title"] is NSNull, "title is written as null, not left out")
        XCTAssertEqual(json["duration_s"] as? Double, 4.2)
        XCTAssertEqual(json["engine"] as? String, "fluidMini")
        XCTAssertEqual(json["status"] as? String, "inserted")
        let extra = try XCTUnwrap(json["extra"] as? [String: Any])
        XCTAssertEqual(extra["destination"] as? String, "MacBook Pro")
        XCTAssertEqual(extra["recovered_from"] as? Double, 1_794_000_000)
        XCTAssertEqual((json["rev"] as? String)?.count, 16)
        XCTAssertNil(json["deleted"])
    }

    func testSourceAndStatusPassThroughUnchanged() throws {
        for source in [TranscriptSource.keyboard, .app, .note, .remote] {
            let item = try XCTUnwrap(LinkEncoding.item(LinkFixtures.dictation(2, source: source)))
            XCTAssertEqual(item.source, source.rawValue)
        }
        let custom = TranscriptStatus(rawValue: "somethingNewer")
        XCTAssertEqual(LinkEncoding.item(LinkFixtures.dictation(3, status: custom))?.status, "somethingNewer")
    }

    func testOnlyFinishedDictationsWithWordsAreSent() {
        XCTAssertNil(LinkEncoding.item(LinkFixtures.dictation(1, status: .recording)))
        XCTAssertNil(LinkEncoding.item(LinkFixtures.dictation(1, status: .paused)))
        XCTAssertNil(LinkEncoding.item(LinkFixtures.dictation(1, text: "  \n ")))
        for status in [TranscriptStatus.finished, .inserted, .offered, .dismissed, .note, .sentRemote, .cutOff,
                       .heldOnComputer, .notDelivered] {
            XCTAssertNotNil(LinkEncoding.item(LinkFixtures.dictation(1, status: status)), status.rawValue)
        }
    }

    func testUnknownDurationAndEngineAreNull() throws {
        var record = LinkFixtures.dictation(1)
        record.audioSeconds = 0
        record.engine = ""
        let json = try object(try XCTUnwrap(LinkEncoding.item(record)))
        XCTAssertTrue(json["duration_s"] is NSNull)
        XCTAssertTrue(json["engine"] is NSNull)
    }

    func testNote() throws {
        var note = LinkFixtures.note(1, text: "buy milk")
        let created = try object(try XCTUnwrap(LinkEncoding.item(note)))
        XCTAssertEqual(created["kind"] as? String, "note")
        XCTAssertTrue(created["source"] is NSNull)
        XCTAssertEqual(created["created_at"] as? Double, 1_794_000_001)
        XCTAssertEqual(created["updated_at"] as? Double, 1_794_000_001, "an unedited note was last updated when it was made")
        XCTAssertTrue(created["status"] is NSNull)

        note.editedAt = Date(timeIntervalSince1970: 1_794_000_500)
        XCTAssertEqual(try object(try XCTUnwrap(LinkEncoding.item(note)))["updated_at"] as? Double, 1_794_000_500)
        XCTAssertNil(LinkEncoding.item(LibraryNote(text: "   ")))
    }

    func testMeetingTextNamesSpeakersAndKeepsSegments() throws {
        let item = try XCTUnwrap(LinkEncoding.item(LinkFixtures.meeting()))
        XCTAssertEqual(item.kind, .meeting)
        XCTAssertEqual(item.title, "Planning 1")
        XCTAssertNil(item.source)
        XCTAssertEqual(item.status, "done")
        XCTAssertEqual(item.durationS, 30)
        XCTAssertEqual(item.text, """
            Dana: Let us start with the launch.
            Me: The build is ready.
            Speaker 3: Then we ship on Friday.
            Agreed.
            """)
        guard case .array(let segments)? = item.extra["segments"] else { return XCTFail("no segments") }
        XCTAssertEqual(segments.count, 4, "a segment with no words is left out")
        XCTAssertEqual(segments[0], .object(["speaker": .string("Dana"), "start": .number(0), "end": .number(4.5),
                                             "text": .string("Let us start with the launch.")]))
        XCTAssertEqual(segments[3], .object(["speaker": .null, "start": .number(12.5), "end": .number(15), "text": .string("Agreed.")]))
    }

    func testMeetingIsSentOnlyWhenItsTranscriptIsDone() {
        for status in [Meeting.Status.recording, .recorded, .transcribing, .failed] {
            XCTAssertNil(LinkEncoding.item(LinkFixtures.meeting(status: status)), status.rawValue)
        }
        var empty = LinkFixtures.meeting()
        empty.segments = []
        XCTAssertNil(LinkEncoding.item(empty))
    }

    func testRevIsStableAndFollowsContent() throws {
        let record = LinkFixtures.dictation(7)
        let first = try XCTUnwrap(LinkEncoding.item(record))
        XCTAssertEqual(first.rev, LinkEncoding.item(record)?.rev)
        XCTAssertEqual(first.rev, first.stamped().rev, "stamping twice changes nothing")

        var edited = record
        edited.text = "different words"
        XCTAssertNotEqual(LinkEncoding.item(edited)?.rev, first.rev)
        var marked = record
        marked.status = .dismissed
        XCTAssertNotEqual(LinkEncoding.item(marked)?.rev, first.rev)
        XCTAssertNotEqual(LinkEncoding.item(LinkFixtures.dictation(8, text: record.text))?.rev, first.rev, "the id is part of it")
    }

    func testDeletionIsTheShortForm() throws {
        let deletion = LinkItem.deletion(id: "9F1C2E6A-0000-4000-8000-000000000001", kind: .dictation, at: 1_794_445_300)
        let json = String(decoding: try deletion.encoded(), as: UTF8.self)
        XCTAssertEqual(json, #"{"deleted":true,"id":"9F1C2E6A-0000-4000-8000-000000000001","kind":"dictation","updated_at":1794445300}"#)
        XCTAssertEqual(try JSONDecoder().decode(LinkItem.self, from: Data(json.utf8)), deletion)
    }

    func testItemsDecodeFromTheProtocolExampleAndIgnoreUnknownFields() throws {
        let example = """
            {"id":"9F1C2E6A-0000-4000-8000-000000000001","kind":"dictation","source":"keyboard",
             "created_at":1794445200.25,"updated_at":1794445203.5,"text":"the words","title":null,
             "duration_s":4.2,"engine":"fluidMini","status":"finished","extra":{},"rev":"5b1f0c9a2d3e4f60",
             "something_new":{"nested":[1,2,3]}}
            """
        let item = try JSONDecoder().decode(LinkItem.self, from: Data(example.utf8))
        XCTAssertEqual(item.text, "the words")
        XCTAssertEqual(item.rev, "5b1f0c9a2d3e4f60")
        XCTAssertFalse(item.deleted)
        XCTAssertEqual(try JSONDecoder().decode(LinkItem.self, from: item.encoded()), item)
    }

    func testLibraryGathersEveryKind() {
        let items = LinkEncoding.library(
            dictations: [LinkFixtures.dictation(1), LinkFixtures.dictation(2, status: .recording)],
            notes: [LinkFixtures.note(1)], meetings: [LinkFixtures.meeting(), LinkFixtures.meeting(2, status: .recorded)])
        XCTAssertEqual(items.map(\.kind), [.dictation, .note, .meeting])
        XCTAssertEqual(Set(items.map(\.id)).count, 3)
    }
}

final class LinkFrameTests: XCTestCase {
    func testFrameIsFourBigEndianBytesThenThePayload() throws {
        let payload = Data(#"{"t":"bye"}"#.utf8)
        let frame = try LinkFrame.frame(payload)
        XCTAssertEqual(Array(frame.prefix(4)), [0, 0, 0, 11])
        XCTAssertEqual(frame.dropFirst(4), payload)
        XCTAssertEqual(try LinkFrame.length(header: Data([0, 0x10, 0, 1])), 0x100001)
    }

    func testFourMebibytesIsTheLimit() throws {
        XCTAssertNoThrow(try LinkFrame.frame(Data(count: 4_194_304)))
        XCTAssertThrowsError(try LinkFrame.frame(Data(count: 4_194_305)))
        XCTAssertEqual(try LinkFrame.length(header: Data([0, 0x40, 0, 0])), 4_194_304)
        XCTAssertThrowsError(try LinkFrame.length(header: Data([0, 0x40, 0, 1]))) {
            XCTAssertEqual($0 as? LinkFrame.Failure, .tooLarge(4_194_305))
        }
    }

    func testDecoderTakesBytesInAnyPieces() throws {
        let first = try LinkFrame.frame(Data("one".utf8))
        let second = try LinkFrame.frame(Data())
        let third = try LinkFrame.frame(Data("three".utf8))
        var decoder = LinkFrameDecoder()
        var out: [String] = []
        for byte in first + second + third {
            decoder.append(Data([byte]))
            while let payload = try decoder.next() { out.append(String(decoding: payload, as: UTF8.self)) }
        }
        XCTAssertEqual(out, ["one", "", "three"])
        XCTAssertEqual(decoder.pendingBytes, 0)

        var whole = LinkFrameDecoder()
        whole.append(first + second + third.prefix(6))
        XCTAssertEqual(try whole.next(), Data("one".utf8))
        XCTAssertEqual(try whole.next(), Data())
        XCTAssertNil(try whole.next(), "half a frame is not a frame")

        var hostile = LinkFrameDecoder()
        hostile.append(Data([0xff, 0xff, 0xff, 0xff]))
        XCTAssertThrowsError(try hostile.next())
    }

    func testMessagesMatchTheProtocolExamples() throws {
        let hello = LinkMessage.hello(phone: LinkPhone(id: "A", name: "Zayd's iPhone", app: "1.0.3 (2026111401)"), pair: nil)
        XCTAssertEqual(String(decoding: try hello.encoded(), as: UTF8.self),
                       #"{"phone":{"app":"1.0.3 (2026111401)","id":"A","name":"Zayd's iPhone"},"t":"hello","v":1}"#,
                       "pair is left out unless this is the pairing connection")
        let pairing = LinkMessage.hello(phone: LinkPhone(id: "A", name: "n", app: "a"), pair: "ab")
        XCTAssertTrue(String(decoding: try pairing.encoded(), as: UTF8.self).contains(#""pair":"ab""#))
        XCTAssertEqual(try LinkMessage.decode(try pairing.encoded()), pairing)

        let welcome = #"{"t":"welcome","v":1,"computer":{"id":"DB","name":"frostbyte","os":"macos","version":"0.1.0"},"items":1629,"resend_all":false}"#
        XCTAssertEqual(try LinkMessage.decode(Data(welcome.utf8)),
                       .welcome(computer: LinkComputer(id: "DB", name: "frostbyte", os: "macos", version: "0.1.0"), items: 1629, resendAll: false))
        XCTAssertEqual(try LinkMessage.decode(Data(#"{"t":"refused","reason":"not_paired"}"#.utf8)), .refused(reason: "not_paired"))
        XCTAssertEqual(try LinkMessage.decode(Data(#"{"t":"ack","seq":1,"stored":500}"#.utf8)), .ack(seq: 1, stored: 500))
        XCTAssertEqual(try LinkMessage.decode(Data(#"{"t":"bye"}"#.utf8)), .bye)
        XCTAssertEqual(String(decoding: try LinkMessage.bye.encoded(), as: UTF8.self), #"{"t":"bye"}"#)

        let item = try XCTUnwrap(LinkEncoding.item(LinkFixtures.dictation(1)))
        let items = LinkMessage.items(seq: 3, items: [item, .deletion(id: "X", kind: .note, at: 5)])
        let text = String(decoding: try items.encoded(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix(#"{"t":"items","seq":3,"items":[{"#))
        XCTAssertEqual(try LinkMessage.decode(Data(text.utf8)), items)
    }

    func testUnknownAndWrongVersionMessagesAreErrors() {
        XCTAssertThrowsError(try LinkMessage.decode(Data(#"{"t":"surprise"}"#.utf8)))
        XCTAssertThrowsError(try LinkMessage.decode(Data("[]".utf8)))
        XCTAssertThrowsError(try LinkMessage.decode(Data(#"{"t":"welcome","v":2,"computer":{"id":"DB"}}"#.utf8))) {
            XCTAssertEqual($0 as? LinkMessage.DecodingFailure, .unsupportedVersion(2))
        }
        // A welcome with only what the phone needs still reads.
        XCTAssertEqual(try? LinkMessage.decode(Data(#"{"t":"welcome","computer":{"id":"DB"}}"#.utf8)),
                       .welcome(computer: LinkComputer(id: "DB"), items: nil, resendAll: false))
    }
}

final class LinkBatcherTests: XCTestCase {
    private func items(_ count: Int, textBytes: Int = 20) -> [LinkItem] {
        (0..<count).map { LinkEncoding.item(LinkFixtures.dictation($0, text: String(repeating: "a", count: textBytes)))! }
    }

    func testAtMostFiveHundredItemsPerFrame() throws {
        let plan = LinkBatcher.plan(items(1_201))
        XCTAssertEqual(plan.batches.map(\.items.count), [500, 500, 201])
        XCTAssertEqual(plan.batches.map(\.seq), [1, 2, 3])
        XCTAssertTrue(plan.tooLarge.isEmpty)
        for batch in plan.batches {
            guard case .items(let seq, let decoded) = try LinkMessage.decode(batch.payload) else { return XCTFail() }
            XCTAssertEqual(seq, batch.seq)
            XCTAssertEqual(decoded, batch.items)
        }
    }

    func testAtMostOneMebibytePerFrame() {
        // 40 items of about 100 KB: ten fit in a frame.
        let plan = LinkBatcher.plan(items(40, textBytes: 100_000))
        XCTAssertGreaterThan(plan.batches.count, 3)
        for batch in plan.batches {
            XCTAssertLessThanOrEqual(batch.payload.count, 1_048_576)
            XCTAssertFalse(batch.items.isEmpty)
        }
        XCTAssertEqual(plan.batches.flatMap(\.items).count, 40)
        XCTAssertEqual(plan.batches.flatMap(\.items).map(\.id), items(40).map(\.id), "order is kept")
    }

    func testAFrameIsFilledToTheByte() {
        let plan = LinkBatcher.plan(items(30), maxItems: 500, maxBytes: 1_000)
        for batch in plan.batches { XCTAssertLessThanOrEqual(batch.payload.count, 1_000) }
        XCTAssertEqual(plan.batches.flatMap(\.items).count, 30)
        XCTAssertGreaterThan(plan.batches.count, 1)
    }

    func testAnOversizedMeetingKeepsItsTextAndDropsSegmentDetail() throws {
        var meeting = LinkFixtures.meeting()
        // 9,000 segments of 70 characters: about 630 KB of text, and as much again in segments.
        meeting.segments = (0..<9_000).map {
            MeetingSegment(start: Double($0), end: Double($0) + 1, speaker: "S1", text: String(repeating: "word ", count: 14))
        }
        let item = try XCTUnwrap(LinkEncoding.item(meeting))
        XCTAssertGreaterThan(try item.encoded().count, 1_048_576)

        let plan = LinkBatcher.plan([item])
        XCTAssertTrue(plan.tooLarge.isEmpty)
        let sent = try XCTUnwrap(plan.batches.first?.items.first)
        XCTAssertEqual(sent.text, item.text)
        XCTAssertEqual(sent.rev, item.rev, "the rev still names the full content, so it is not sent again and again")
        XCTAssertNil(sent.extra["segments"])
        XCTAssertEqual(sent.extra["segments_omitted"], .bool(true))
        XCTAssertLessThanOrEqual(plan.batches[0].payload.count, 1_048_576)
    }

    func testAnItemThatCannotFitIsReportedAndTheRestStillGo() {
        let giant = LinkEncoding.item(LinkFixtures.dictation(999, text: String(repeating: "x", count: 1_100_000)))!
        let plan = LinkBatcher.plan(items(3) + [giant] + items(2))
        XCTAssertEqual(plan.tooLarge.map(\.id), [giant.id])
        XCTAssertEqual(plan.batches.flatMap(\.items).count, 5)
    }

    func testNothingToSendIsNoFrames() {
        XCTAssertEqual(LinkBatcher.plan([]).batches, [])
    }
}
