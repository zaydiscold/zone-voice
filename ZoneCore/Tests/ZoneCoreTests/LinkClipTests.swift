// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// Clips (PROTOCOL.md, "Clips"): text the person sends from the phone to a computer on purpose.
/// An item of kind `clip`, sent first, held until acknowledged, never part of the library and
/// never a deletion.
final class LinkClipTests: XCTestCase {
    private var directory: URL!
    private let at = Date(timeIntervalSince1970: 1_794_600_000)

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("link-clips-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func outbox() -> LinkClipOutbox {
        LinkClipOutbox(fileURL: directory.appendingPathComponent("clips.json"))
    }

    // MARK: The item

    func testAClipIsAnItemOfKindClipWithItsSourceAndNothingElse() throws {
        let id = UUID(uuidString: "C11B0000-0000-4000-8000-000000000001")!
        let clip = LinkClip(id: id, text: "ssh studio@10.0.0.7\n", source: .clipboard, createdAt: at, waiting: ["a"])
        let item = clip.item
        XCTAssertEqual(item.kind, .clip)
        XCTAssertEqual(item.id, "C11B0000-0000-4000-8000-000000000001")
        XCTAssertEqual(item.source, "clipboard")
        XCTAssertEqual(item.text, "ssh studio@10.0.0.7\n", "the text goes exactly as given, line break and all")
        XCTAssertEqual(item.createdAt, 1_794_600_000)
        XCTAssertEqual(item.updatedAt, 1_794_600_000)
        XCTAssertFalse(item.deleted)
        XCTAssertNotNil(item.rev)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: item.encoded()) as? [String: Any])
        XCTAssertEqual(json["kind"] as? String, "clip")
        XCTAssertEqual(json["source"] as? String, "clipboard")
        for key in ["title", "duration_s", "engine", "status"] {
            XCTAssertTrue(json[key] is NSNull, "\(key) is null on a clip")
        }
        XCTAssertNil(json["deleted"])
        XCTAssertEqual(try JSONDecoder().decode(LinkItem.self, from: item.encoded()), item)
        XCTAssertEqual(LinkClipSource.allCases.map(\.rawValue), ["clipboard", "share", "shortcut", "typed"])
    }

    // MARK: The limit

    func testTheLimitIs256kBOfUTF8AndEmptyTextIsRefused() throws {
        let box = outbox()
        XCTAssertEqual(LinkClip.maxBytes, 256_000)
        let most = String(repeating: "a", count: LinkClip.maxBytes)
        XCTAssertNoThrow(try box.add(most, source: .typed, to: ["a"]))
        XCTAssertThrowsError(try box.add(most + "a", source: .typed, to: ["a"])) {
            XCTAssertEqual($0 as? LinkClipFailure, .tooLarge(bytes: LinkClip.maxBytes + 1))
        }
        // Bytes, not characters: "é" is two bytes.
        let accented = String(repeating: "é", count: LinkClip.maxBytes / 2)
        XCTAssertNoThrow(try box.add(accented, source: .typed, to: ["a"]))
        XCTAssertThrowsError(try box.add(accented + "é", source: .typed, to: ["a"])) {
            XCTAssertEqual($0 as? LinkClipFailure, .tooLarge(bytes: LinkClip.maxBytes + 2))
        }
        for blank in ["", "   ", "\n\t "] {
            XCTAssertThrowsError(try box.add(blank, source: .typed, to: ["a"])) {
                XCTAssertEqual($0 as? LinkClipFailure, .empty)
            }
        }
        XCTAssertThrowsError(try box.add("hello", source: .typed, to: [])) {
            XCTAssertEqual($0 as? LinkClipFailure, .noComputer)
        }
        XCTAssertEqual(box.all().count, 2, "a refused clip is not kept")
        XCTAssertFalse(LinkClipFailure.tooLarge(bytes: 1).plainMessage.contains("\u{2014}"))
    }

    func testTheLargestClipFitsInOneFrame() throws {
        let clip = LinkClip(text: String(repeating: "\"", count: LinkClip.maxBytes), source: .typed, waiting: ["a"])
        // Every character needs escaping in JSON, the worst case for size.
        let plan = LinkBatcher.plan([clip.item])
        XCTAssertEqual(plan.tooLarge.count, 0)
        XCTAssertEqual(plan.batches.count, 1)
        XCTAssertEqual(plan.batches[0].items[0].text, clip.text, "sent whole, not cut down to fit")
        XCTAssertLessThanOrEqual(plan.batches[0].payload.count, LinkProtocol.maxItemsFrameBytes)
    }

    // MARK: The outbox

    func testAClipWaitsForEachComputerUntilItAcknowledges() throws {
        let box = outbox()
        let clip = try box.add("first", source: .clipboard, to: ["a", "b", "a"], at: at)
        XCTAssertEqual(clip.waiting, ["a", "b"], "a computer is listed once")
        XCTAssertEqual(box.pending(for: "a").map(\.text), ["first"])
        XCTAssertEqual(box.pending(for: "b").map(\.text), ["first"])
        XCTAssertEqual(box.pending(for: "c"), [])
        XCTAssertTrue(box.hasPending(for: "a"))

        box.acknowledge([clip.item], by: "a", at: at.addingTimeInterval(1))
        var saved = try XCTUnwrap(outbox().clip(clip.id), "kept on disk")
        XCTAssertEqual(saved.waiting, ["b"])
        XCTAssertEqual(saved.sentTo, ["a"])
        XCTAssertFalse(saved.isSent)
        XCTAssertNil(saved.sentAt)
        XCTAssertEqual(box.pending(for: "a"), [], "never sent to that computer again")
        XCTAssertEqual(box.pending(for: "b").count, 1)

        // The same acknowledgement twice changes nothing.
        box.acknowledge([clip.item], by: "a", at: at.addingTimeInterval(2))
        XCTAssertEqual(box.clip(clip.id)?.sentTo, ["a"])

        box.acknowledge([clip.item], by: "b", at: at.addingTimeInterval(3))
        saved = try XCTUnwrap(box.clip(clip.id))
        XCTAssertTrue(saved.isSent)
        XCTAssertEqual(saved.sentAt, at.addingTimeInterval(3))
        XCTAssertFalse(box.hasPending(for: "b"))
    }

    func testPendingIsOldestFirstAndTheSentListNewestFirst() throws {
        let box = outbox()
        try box.add("second", source: .typed, to: ["a"], at: at.addingTimeInterval(10))
        try box.add("first", source: .typed, to: ["a"], at: at)
        try box.add("third", source: .typed, to: ["a"], at: at.addingTimeInterval(20))
        XCTAssertEqual(box.pending(for: "a").map(\.text), ["first", "second", "third"])
        XCTAssertEqual(box.all().map(\.text), ["third", "second", "first"])
    }

    func testOnlyTheLastTwentySentAreKeptAndWaitingOnesAlways() throws {
        let box = outbox()
        let waiting = try box.add("still waiting", source: .typed, to: ["offline"], at: at.addingTimeInterval(-500))
        for number in 0..<25 {
            let clip = try box.add("clip \(number)", source: .typed, to: ["a"], at: at.addingTimeInterval(Double(number)))
            box.acknowledge([clip.item], by: "a", at: at.addingTimeInterval(Double(number) + 0.5))
        }
        let all = box.all()
        XCTAssertEqual(all.filter(\.isSent).count, LinkClipOutbox.sentKept)
        XCTAssertEqual(all.filter(\.isSent).map(\.text).first, "clip 24")
        XCTAssertEqual(all.filter(\.isSent).map(\.text).last, "clip 5", "the oldest sent ones went")
        XCTAssertNotNil(box.clip(waiting.id), "a waiting clip is never dropped to make room")
    }

    func testASentClipKeepsOnlyAPreviewOfItsText() throws {
        let box = outbox()
        let long = String(repeating: "secret words ", count: 400)
        let clip = try box.add(long, source: .share, to: ["a"], at: at)
        XCTAssertEqual(box.clip(clip.id)?.text, long, "whole while it waits")
        box.acknowledge([clip.item], by: "a")
        let saved = try XCTUnwrap(box.clip(clip.id))
        XCTAssertEqual(saved.text.count, LinkClip.previewCharacters)
        XCTAssertEqual(saved.bytes, long.utf8.count, "the size sent is still known")
        let onDisk = try String(contentsOf: directory.appendingPathComponent("clips.json"), encoding: .utf8)
        XCTAssertLessThan(onDisk.count, 1_000)

        let lines = LinkClip(text: "one\ntwo\r\n  three  ", source: .typed, waiting: ["a"])
        XCTAssertEqual(lines.preview, "one two   three")
    }

    func testForgettingAComputerStopsClipsWaitingForIt() throws {
        let box = outbox()
        let onlyGone = try box.add("for the forgotten one", source: .typed, to: ["gone"], at: at)
        let both = try box.add("for both", source: .typed, to: ["kept", "gone"], at: at.addingTimeInterval(1))
        let reached = try box.add("one has it", source: .typed, to: ["kept", "gone"], at: at.addingTimeInterval(2))
        box.acknowledge([reached.item], by: "kept")

        box.forget("gone")
        XCTAssertNil(box.clip(onlyGone.id), "it reached nobody and nobody waits for it")
        XCTAssertEqual(box.clip(both.id)?.waiting, ["kept"])
        XCTAssertEqual(box.clip(reached.id)?.isSent, true)
        XCTAssertNotNil(box.clip(reached.id)?.sentAt)

        // Through the store, which is what the app calls.
        let store = LinkStore(directory: directory)
        store.add(PairedComputer(endpointID: "kept", name: "Studio Mac"))
        store.remove("kept")
        XCTAssertNil(store.clips.clip(both.id))
        XCTAssertEqual(store.clips.all().map(\.id), [reached.id])
    }

    func testClearingTheSentListLeavesWaitingClips() throws {
        let box = outbox()
        let sent = try box.add("sent", source: .typed, to: ["a"])
        let waiting = try box.add("waiting", source: .typed, to: ["a"])
        box.acknowledge([sent.item], by: "a")
        box.removeSent()
        XCTAssertEqual(box.all().map(\.id), [waiting.id])
        box.remove(waiting.id)
        XCTAssertEqual(box.all(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("clips.json").path),
                       "an empty outbox leaves no file")
    }

    // MARK: What a session sends

    func testClipsGoFirstAndAreRemovedFromTheOutboxOnAck() async throws {
        let phone = LinkTestPhone()
        let computer = FakeComputer()
        phone.dictate(1)
        phone.dictate(2)
        let clip = try phone.store.clips.add("https://example.com/build/42", source: .clipboard, to: [phone.endpointID], at: at)

        let outcome = try await phone.sync(with: computer, pair: computer.newPairingSecret())
        XCTAssertEqual(outcome.delivered, 3)
        XCTAssertEqual(computer.frames.first?.first?.kind, .clip, "the clip leads the first frame")
        XCTAssertEqual(computer.frames.first?.first?.source, "clipboard")
        XCTAssertEqual(computer.rows[clip.id.uuidString]?.item.text, "https://example.com/build/42")

        XCTAssertEqual(phone.store.clips.clip(clip.id)?.isSent, true)
        XCTAssertEqual(phone.store.clips.pending(for: phone.endpointID), [])
        XCTAssertEqual(phone.store.computer(phone.endpointID)?.itemsSent, 2, "Items sent counts the library, not clips")
        XCTAssertNil(phone.delivery.delivered[clip.id.uuidString], "a clip leaves no mark in the library's delivery state")
        XCTAssertFalse(phone.delivery.attempted.contains(clip.id.uuidString))

        computer.clearFrames()
        let again = try await phone.sync(with: computer)
        XCTAssertEqual(again.delivered, 0, "an acknowledged clip is never sent twice")
    }

    func testAClipThatWasNotAcknowledgedStaysQueuedForTheNextSync() async throws {
        let phone = LinkTestPhone()
        let computer = FakeComputer()
        _ = try await phone.sync(with: computer, pair: computer.newPairingSecret())
        let clip = try phone.store.clips.add("queued while offline", source: .shortcut, to: [phone.endpointID], at: at)

        computer.goSilentAfterItems(true)
        do {
            _ = try await phone.sync(with: computer, frameTimeout: 0.3)
            XCTFail("the computer never acknowledged")
        } catch {}
        XCTAssertEqual(phone.store.clips.clip(clip.id)?.waiting, [phone.endpointID], "sent but not acknowledged is still waiting")
        XCTAssertEqual(phone.store.pendingCount(for: phone.endpointID, library: phone.library(), deletions: phone.log.all()), 1,
                       "so a sync that would otherwise have nothing to send still connects")

        computer.goSilentAfterItems(false)
        let outcome = try await phone.sync(with: computer)
        XCTAssertEqual(outcome.delivered, 1)
        XCTAssertEqual(phone.store.clips.clip(clip.id)?.isSent, true)
    }

    func testTheOutboxIsKeptOutOfTheDevicesBackups() throws {
        let box = outbox()
        let url = directory.appendingPathComponent("clips.json")
        let first = try box.add("123456", source: .clipboard, to: ["a"], at: at)
        XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        // Every write replaces the file, so the mark must survive a change too.
        box.acknowledge([first.item], by: "a", at: at)
        try box.add("another", source: .typed, to: ["a"], at: at)
        XCTAssertEqual(try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testAWaitingClipSurvivesTheAppBeingRelaunched() async throws {
        let phone = LinkTestPhone()
        let computer = FakeComputer()
        _ = try await phone.sync(with: computer, pair: computer.newPairingSecret())
        let clip = try phone.store.clips.add("sent from the lock screen", source: .shortcut, to: [phone.endpointID], at: at)

        // A new store on the same folder is what the app has after it is quit and opened again.
        let relaunched = LinkStore(directory: phone.store.directory)
        XCTAssertEqual(relaunched.clips.clip(clip.id)?.waiting, [phone.endpointID])
        let pending = relaunched.pending(for: phone.endpointID, library: phone.library(), deletions: phone.log.all())
        XCTAssertEqual(pending.map(\.id), [clip.id.uuidString], "it goes first in the next sync after the relaunch")
        XCTAssertEqual(pending.first?.text, "sent from the lock screen")
        XCTAssertEqual(pending.first?.source, "shortcut")

        let outcome = try await phone.sync(with: computer)
        XCTAssertEqual(outcome.delivered, 1)
        XCTAssertEqual(LinkStore(directory: phone.store.directory).clips.clip(clip.id)?.isSent, true,
                       "and once acknowledged, the next launch knows it was sent")
    }

    func testAClipGoesOnlyToTheComputersItWasQueuedFor() async throws {
        let phone = LinkTestPhone()
        let other = "aa3c7996bad77424e96786cf7a7205115337a5b4565cd25506a0f297b191a5ea"
        phone.store.add(PairedComputer(endpointID: other, name: "paused one"))
        try phone.store.clips.add("only for the other", source: .typed, to: [other], at: at)
        XCTAssertEqual(phone.store.pending(for: phone.endpointID, library: [], deletions: []), [])
        XCTAssertEqual(phone.store.pending(for: other, library: [], deletions: []).map(\.kind), [.clip])
    }

    // MARK: Never a deletion

    func testClipsNeverProduceDeletions() async throws {
        let phone = LinkTestPhone()
        let computer = FakeComputer()
        phone.dictate(1)
        let sent = try phone.store.clips.add("sent then removed", source: .typed, to: [phone.endpointID], at: at)
        _ = try await phone.sync(with: computer, pair: computer.newPairingSecret())
        let waiting = try phone.store.clips.add("removed while waiting", source: .typed, to: [phone.endpointID], at: at)

        // Removed on the phone: one the computer has, one it never got. Then every sent clip cleared.
        phone.store.clips.remove(sent.id)
        phone.store.clips.remove(waiting.id)
        phone.store.clips.removeSent()
        XCTAssertEqual(phone.log.all(), [], "removing a clip writes nothing to the deletion log")

        computer.clearFrames()
        let outcome = try await phone.sync(with: computer)
        XCTAssertEqual(outcome.deletions, 0)
        XCTAssertEqual(outcome.delivered, 0)
        XCTAssertEqual(computer.rows[sent.id.uuidString]?.deleted, false, "the computer keeps the clip it was sent")
        XCTAssertNil(computer.rows[waiting.id.uuidString], "and never hears of the one that was removed first")

        // Even with every way a deletion is made: the log only ever names library records, and
        // a clip id in the delivery state is impossible, so no deletion can be planned for one.
        let pending = phone.store.pending(for: phone.endpointID, library: [], deletions: [
            LinkDeletion(id: sent.id.uuidString, kind: .clip, at: 1_794_600_100),
        ])
        XCTAssertEqual(pending, [], "the computer is not known to hold it as a library record, so nothing is sent")

        // A computer that asks for everything again gets the library, not old clips.
        computer.askForEverythingOnce()
        let everything = try await phone.sync(with: computer)
        XCTAssertEqual(everything.delivered, 1)
        XCTAssertEqual(everything.deletions, 0)
    }

    // MARK: Flash

    func testAFlashCarriesWaitingClipsAndConfirmingItSettlesThem() throws {
        let phone = LinkTestPhone()
        phone.dictate(1)
        let clip = try phone.store.clips.add("on a plane", source: .typed, to: [phone.endpointID], at: at)
        let items = phone.store.pending(for: phone.endpointID, library: phone.library(), deletions: [])
        XCTAssertEqual(items.map(\.kind), [.clip, .dictation])

        let json = try LinkFlashPayload.json(phone: FlashFixtures.phone, items: items)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let first = try XCTUnwrap((payload["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["kind"] as? String, "clip")
        XCTAssertEqual(first["text"] as? String, "on a plane")

        phone.store.recordFlash(items, to: phone.endpointID, at: at)
        XCTAssertEqual(phone.store.clips.clip(clip.id)?.isSent, true)
        XCTAssertEqual(phone.store.computer(phone.endpointID)?.itemsSent, 1)
        XCTAssertEqual(phone.store.pending(for: phone.endpointID, library: phone.library(), deletions: []), [])
    }

    // MARK: Wording

    func testTheSentListSaysWaitingForTheComputerOrSent() throws {
        let names = ["a": "Studio Mac", "b": "ThinkPad"]
        var clip = LinkClip(text: "x", source: .typed, waiting: ["a"])
        XCTAssertEqual(LinkClipCopy.status(clip, names: names), "Waiting for Studio Mac")
        XCTAssertEqual(LinkClipCopy.outcome(clip, names: names),
                       "Zone could not reach Studio Mac just now. It is saved and goes with the next sync.")
        clip.waiting = ["a", "b"]
        XCTAssertEqual(LinkClipCopy.status(clip, names: names), "Waiting for Studio Mac and ThinkPad")
        clip.waiting = ["b"]
        clip.sentTo = ["a"]
        XCTAssertEqual(LinkClipCopy.status(clip, names: names), "Sent to Studio Mac. Waiting for ThinkPad")
        clip.waiting = []
        clip.sentTo = ["a", "b"]
        XCTAssertEqual(LinkClipCopy.status(clip, names: names), "Sent")
        XCTAssertEqual(LinkClipCopy.outcome(clip, names: names), "Sent to Studio Mac and ThinkPad.")
        XCTAssertEqual(LinkClipCopy.status(LinkClip(text: "x", source: .typed, waiting: ["gone"]), names: [:]),
                       "Waiting for the computer")
    }

    // MARK: When it is sent

    func testSendingAClipSyncsAtOnceWithEveryComputerThatIsOn() {
        var on = PairedComputer(endpointID: "a", name: "on")
        on.confirmed = true
        var paused = PairedComputer(endpointID: "b", name: "paused")
        paused.pausedAt = at
        var refused = PairedComputer(endpointID: "c", name: "refused")
        refused.needsPairing = true
        XCTAssertEqual([on, paused, refused].due(for: .clip), ["a", "c"],
                       "never a paused one; one that refused is tried, since the person asked")
        XCTAssertGreaterThan(LinkSyncReason.clip, .foreground)
        XCTAssertLessThan(LinkSyncReason.clip, .manual)
    }
}
