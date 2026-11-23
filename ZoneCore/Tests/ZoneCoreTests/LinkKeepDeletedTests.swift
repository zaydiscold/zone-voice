// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// The per-computer switch "Keep what I delete here" (Settings > Computers): off, a delete on
/// the phone is sent to the computer as before; on, that computer is never told, so it keeps
/// its copy, and turning the switch off later does not send those deletes after all.
final class LinkKeepDeletedTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("link-keep-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    // MARK: Stored with the computer

    func testAComputerSavedBeforeTheSwitchExistedReadsAsOff() throws {
        // computers.json and deletions.json exactly as builds before the switch wrote them.
        let computers = #"[{"endpointID":"a","name":"Studio Mac","pairedAt":800000000,"confirmed":true,"#
            + #""itemsSent":12,"needsPairing":false,"pausedAt":800000050}]"#
        let deletions = #"[{"id":"9F1C2E6A-0000-4000-8000-000000000001","kind":"dictation","at":1794500000}]"#
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(computers.utf8).write(to: directory.appendingPathComponent("computers.json"))
        try Data(deletions.utf8).write(to: directory.appendingPathComponent("deletions.json"))

        let store = LinkStore(directory: directory)
        let computer = try XCTUnwrap(store.computer("a"))
        XCTAssertNil(computer.keepsDeletedSince)
        XCTAssertFalse(computer.keepsDeleted, "deletes are still sent, as before")
        XCTAssertTrue(computer.isPaused, "the rest of the record reads as it did")

        let log = LinkDeletionLog(fileURL: store.deletionLogURL)
        let entry = try XCTUnwrap(log.all().first)
        XCTAssertNil(entry.keptBy)
        XCTAssertFalse(entry.isKept(by: "a"))
        XCTAssertEqual(store.deletions(for: "a", from: log.all()), [entry], "an old deletion is still owed")
    }

    func testTheSwitchIsSavedWithTheComputerAndOnlyThatComputer() throws {
        let store = LinkStore(directory: directory)
        let log = LinkDeletionLog(fileURL: store.deletionLogURL)
        store.add(PairedComputer(endpointID: "a", name: "one"))
        store.add(PairedComputer(endpointID: "b", name: "two"))
        XCTAssertEqual(store.computers().map(\.keepsDeleted), [false, false], "off when a computer is paired")

        let on = Date(timeIntervalSince1970: 1_794_500_000)
        store.setKeepsDeleted(true, for: "a", log: log, at: on)
        let reopened = LinkStore(directory: directory)
        XCTAssertEqual(reopened.computer("a")?.keepsDeletedSince, on)
        XCTAssertEqual(reopened.computer("b")?.keepsDeleted, false)
        XCTAssertEqual(reopened.computers().keepingNames, ["one"])

        // On again keeps the first date: it says since when.
        reopened.setKeepsDeleted(true, for: "a", log: log, at: on.addingTimeInterval(90))
        XCTAssertEqual(store.computer("a")?.keepsDeletedSince, on)
        reopened.setKeepsDeleted(false, for: "a", log: log)
        XCTAssertEqual(store.computer("a")?.keepsDeleted, false)
        XCTAssertNil(store.setKeepsDeleted(true, for: "gone", log: log), "a forgotten computer is not brought back")
        XCTAssertNil(store.computer("gone"))
    }

    // MARK: What is sent

    func testOffADeleteIsSentAndOnItIsNotAndTheComputerKeepsItsCopy() async throws {
        let phone = LinkTestPhone()
        let computer = FakeComputer()
        let first = phone.dictate(1)
        let second = phone.dictate(2)
        phone.dictate(3)
        _ = try await phone.sync(with: computer, pair: computer.newPairingSecret())
        XCTAssertEqual(computer.liveRows.count, 3)

        // Off, the default: a delete reaches the computer at the next sync.
        phone.history.delete(id: first)
        var outcome = try await phone.sync(with: computer)
        XCTAssertEqual(outcome.deletions, 1)
        XCTAssertEqual(computer.rows[first.uuidString]?.deleted, true)
        XCTAssertNil(computer.rows[first.uuidString]?.item.text, "the words are dropped there")

        // On: the next delete is written down as kept by this computer and never sent.
        phone.store.setKeepsDeleted(true, for: phone.endpointID, log: phone.log)
        computer.clearFrames()
        phone.history.delete(id: second)
        XCTAssertEqual(phone.log.all().map(\.keptBy), [[phone.endpointID]])
        XCTAssertEqual(phone.store.pendingCount(for: phone.endpointID, library: phone.library(), deletions: phone.log.all()), 0)
        phone.now = phone.now.addingTimeInterval(60)
        phone.dictate(4)
        outcome = try await phone.sync(with: computer)
        XCTAssertEqual(outcome.deletions, 0)
        XCTAssertEqual(computer.frames.flatMap { $0 }.map(\.id), [LinkFixtures.uuid(4).uuidString], "new items still go")
        XCTAssertEqual(computer.rows[second.uuidString]?.deleted, false, "the computer keeps its copy")
        XCTAssertEqual(computer.rows[second.uuidString]?.item.text, "dictation number 2")

        // Nobody else needs that deletion, so the log lets it go.
        phone.store.pruneDeletions(phone.log, libraryIDs: Set(phone.library().map(\.id)))
        XCTAssertTrue(phone.log.all().isEmpty)
    }

    func testTurningItOffLaterIsNotRetroactive() async throws {
        let phone = LinkTestPhone()
        let computer = FakeComputer()
        let kept = phone.dictate(1)
        let later = phone.dictate(2)
        phone.dictate(3)
        _ = try await phone.sync(with: computer, pair: computer.newPairingSecret())
        // A second computer that has everything and is never reached keeps the log entries alive,
        // which is the hard case: the entry is still there when the switch goes off.
        phone.store.add(PairedComputer(endpointID: "other", name: "other"))
        phone.store.updateDelivery(for: "other") { $0.acknowledge(phone.library()) }

        phone.store.setKeepsDeleted(true, for: phone.endpointID, log: phone.log)
        phone.history.delete(id: kept)
        phone.store.pruneDeletions(phone.log, libraryIDs: Set(phone.library().map(\.id)))
        XCTAssertEqual(phone.log.all().map(\.id), [kept.uuidString], "still owed to the other computer")
        XCTAssertEqual(phone.store.deletions(for: "other", from: phone.log.all()).map(\.id), [kept.uuidString])

        phone.store.setKeepsDeleted(false, for: phone.endpointID, log: phone.log)
        computer.clearFrames()
        var outcome = try await phone.sync(with: computer)
        XCTAssertEqual(outcome.delivered, 0, "the delete made while it was on is not sent after all")
        XCTAssertEqual(computer.rows[kept.uuidString]?.deleted, false)

        // Only what is deleted after that is deleted there.
        phone.history.delete(id: later)
        outcome = try await phone.sync(with: computer)
        XCTAssertEqual(outcome.deletions, 1)
        XCTAssertEqual(computer.rows[later.uuidString]?.deleted, true)
        XCTAssertEqual(computer.rows[kept.uuidString]?.deleted, false, "still kept")
        XCTAssertEqual(computer.liveRows.count, 2)
    }

    func testTurningItOnSparesADeleteThatWasStillWaiting() async throws {
        let phone = LinkTestPhone()
        let computer = FakeComputer()
        let waiting = phone.dictate(1)
        phone.dictate(2)
        _ = try await phone.sync(with: computer, pair: computer.newPairingSecret())

        // Deleted while off, but the computer has not been told yet when the switch goes on.
        phone.history.delete(id: waiting)
        XCTAssertEqual(phone.store.pendingCount(for: phone.endpointID, library: phone.library(), deletions: phone.log.all()), 1)
        phone.store.setKeepsDeleted(true, for: phone.endpointID, log: phone.log)
        XCTAssertEqual(phone.store.pendingCount(for: phone.endpointID, library: phone.library(), deletions: phone.log.all()), 0)

        // And it stays spared when the switch goes off again.
        phone.store.setKeepsDeleted(false, for: phone.endpointID, log: phone.log)
        computer.clearFrames()
        let outcome = try await phone.sync(with: computer)
        XCTAssertEqual(outcome.delivered, 0)
        XCTAssertEqual(computer.rows[waiting.uuidString]?.deleted, false)
    }

    func testOneComputerKeepsWhileAnotherDeletes() throws {
        let phone = LinkTestPhone()
        let doomed = phone.dictate(1)
        phone.dictate(2)
        phone.store.add(PairedComputer(endpointID: "other", name: "other"))
        for id in [phone.endpointID, "other"] {
            phone.store.updateDelivery(for: id) { $0.acknowledge(phone.library()) }
        }
        phone.store.setKeepsDeleted(true, for: phone.endpointID, log: phone.log)

        phone.history.delete(id: doomed)
        let library = phone.library(), all = phone.log.all()
        XCTAssertTrue(phone.store.pending(for: phone.endpointID, library: library, deletions: all).isEmpty)
        let owed = phone.store.pending(for: "other", library: library, deletions: all)
        XCTAssertEqual(owed.map(\.id), [doomed.uuidString])
        XCTAssertEqual(owed.map(\.deleted), [true])

        // Told, the other computer no longer needs the entry; the keeper never did.
        phone.store.updateDelivery(for: "other") { $0.acknowledge(owed) }
        phone.store.pruneDeletions(phone.log, libraryIDs: Set(library.map(\.id)))
        XCTAssertTrue(phone.log.all().isEmpty)
        XCTAssertTrue(phone.delivery.mayHave(doomed.uuidString), "the phone still knows the keeper has it")
    }

    func testAFlashCarriesNoDeletionsToAComputerThatKeeps() throws {
        let phone = LinkTestPhone()
        let doomed = phone.dictate(1)
        phone.dictate(2)
        phone.store.updateDelivery(for: phone.endpointID) { $0.acknowledge(phone.library()) }
        phone.store.setKeepsDeleted(true, for: phone.endpointID, log: phone.log)
        phone.history.delete(id: doomed)
        phone.dictate(3)

        // What Send by Flash offers as Not sent yet: the new dictation, and no deletion.
        let items = phone.store.pending(for: phone.endpointID, library: phone.library(), deletions: phone.log.all())
        XCTAssertEqual(items.map(\.id), [LinkFixtures.uuid(3).uuidString])
        XCTAssertFalse(items.contains(where: \.deleted))
    }

    // MARK: What the app says

    func testTheDeleteConfirmationsSayWhichComputersKeepTheirCopies() {
        XCTAssertEqual(LinkCopy.deleteNote(["Studio Mac"], keeping: []), "Studio Mac deletes its copies the next time Zone syncs.")
        XCTAssertEqual(LinkCopy.deleteNote(["Studio Mac"], keeping: ["Studio Mac"]), "Studio Mac keeps its copies.")
        XCTAssertEqual(LinkCopy.deleteNote(["Studio Mac"], keeping: ["Studio Mac"], what: "copy of the transcript"),
                       "Studio Mac keeps its copy of the transcript.")
        XCTAssertEqual(LinkCopy.deleteNote(["Studio Mac", "laptop"], keeping: ["laptop"]),
                       "Studio Mac deletes its copies the next time Zone syncs. Laptop keeps its copies.")
        XCTAssertEqual(LinkCopy.deleteNote(["a", "b"], keeping: ["a", "b"]), "A and b keep their copies.")
        XCTAssertEqual(LinkCopy.deleteNote(["a", "b", "c"], keeping: ["a", "b", "c"]), "Your paired computers keep their copies.")
        XCTAssertEqual(LinkCopy.deleteNote(["a", "b", "c"], keeping: ["c"]),
                       "A and b delete their copies the next time Zone syncs. C keeps its copies.")
        XCTAssertEqual(LinkCopy.deleteNote(["a", "b", "c", "d"], keeping: ["d"]),
                       "Your other computers delete their copies the next time Zone syncs. D keeps its copies.")
        XCTAssertEqual(LinkCopy.deleteNote(["a", "b", "c", "d"], keeping: ["a", "b", "c"]),
                       "D deletes its copies the next time Zone syncs. Your other computers keep their copies.")
        // Two computers with the same name: one keeps, one deletes.
        XCTAssertEqual(LinkCopy.deleteNote(["mac", "mac"], keeping: ["mac"]),
                       "Mac deletes its copies the next time Zone syncs. Mac keeps its copies.")
        XCTAssertNil(LinkCopy.deleteNote([], keeping: ["gone"]))
    }

    func testPrivacySaysWhatADeleteDoesOnEachComputer() throws {
        let plain = try XCTUnwrap(LinkCopy.privacyParagraph(["Studio Mac"]))
        XCTAssertTrue(plain.contains("Deleting something here tells the computer to delete its copy the next time Zone syncs;"))
        XCTAssertEqual(LinkCopy.privacyParagraph(["Studio Mac"], keeping: []), plain)

        let keeps = try XCTUnwrap(LinkCopy.privacyParagraph(["Studio Mac"], keeping: ["Studio Mac"]))
        XCTAssertFalse(keeps.contains("tells the computer to delete"), "that would no longer be true")
        XCTAssertTrue(keeps.contains("You turned on Keep what I delete here for Studio Mac, so deleting something here leaves its copy there."))
        XCTAssertTrue(keeps.contains("Dictations that only age out of History stay on the computer too."))

        let mixed = try XCTUnwrap(LinkCopy.privacyParagraph(["Studio Mac", "laptop"], keeping: ["laptop"]))
        XCTAssertTrue(mixed.contains("Deleting something here tells Studio Mac to delete its copy the next time Zone syncs. You turned on Keep what I delete here for laptop, so deleting something here leaves its copy there."))
        for text in [plain, keeps, mixed] {
            XCTAssertTrue(text.hasSuffix("stops the sending and leaves what the computer already has."))
            XCTAssertFalse(text.contains("\u{2014}"))
        }
    }

    func testTheSwitchFooterSaysWhatItDoesAndThatOffIsNotRetroactive() {
        XCTAssertEqual(LinkCopy.keepSwitch, "Keep what I delete here")
        let off = LinkCopy.keepFooter("Studio Mac", on: false)
        XCTAssertTrue(off.contains("also deletes the copy on Studio Mac the next time Zone syncs"))
        let on = LinkCopy.keepFooter("Studio Mac", on: true)
        XCTAssertTrue(on.contains("Studio Mac keeps its copy of anything you delete on this iPhone while this is on."))
        XCTAssertTrue(on.contains("Turning it off later does not reach back"))
        XCTAssertFalse((off + on).contains("\u{2014}"))
        XCTAssertEqual(ZoneLinks.computerApp.absoluteString, "https://github.com/zaydiscold/zone-mcp")
    }
}
