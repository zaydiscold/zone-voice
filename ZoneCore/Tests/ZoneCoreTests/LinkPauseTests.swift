// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// The per-computer switch (Settings > Computers, "Send to this computer"): off sends nothing
/// over the network, keeps what the computer is known to hold, and on again sends only what
/// changed meanwhile, deletions included.
final class LinkPauseTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("link-pause-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    // MARK: The stored flag

    func testAComputerSavedBeforeTheSwitchExistedReadsAsOn() throws {
        // computers.json exactly as the first Zone Link build wrote it: no pausedAt.
        let old = #"[{"endpointID":"a","name":"Studio Mac","pairedAt":800000000,"confirmed":true,"#
            + #""itemsSent":12,"needsPairing":false,"lastSyncAt":800000100}]"#
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(old.utf8).write(to: directory.appendingPathComponent("computers.json"))

        let store = LinkStore(directory: directory)
        let computer = try XCTUnwrap(store.computer("a"))
        XCTAssertEqual(computer.name, "Studio Mac")
        XCTAssertEqual(computer.itemsSent, 12)
        XCTAssertNil(computer.pausedAt)
        XCTAssertFalse(computer.isPaused)
        XCTAssertTrue(computer.syncsAutomatically)
    }

    func testTurningOffIsSavedWithTheComputerAndKeepsItsDeliveryState() throws {
        let store = LinkStore(directory: directory)
        store.add(PairedComputer(endpointID: "a", name: "one"))
        store.add(PairedComputer(endpointID: "b", name: "two"))
        store.updateDelivery(for: "a") { $0.delivered = ["x": "1", "y": "2"]; $0.attempted = ["z"] }
        let before = store.delivery(for: "a")

        let off = Date(timeIntervalSince1970: 1_794_500_000)
        store.setSending(false, to: "a", at: off)

        let reopened = LinkStore(directory: directory)
        XCTAssertEqual(reopened.computer("a")?.pausedAt, off)
        XCTAssertEqual(reopened.computer("a")?.isPaused, true)
        XCTAssertEqual(reopened.computer("b")?.isPaused, false, "only the one switched off")
        XCTAssertEqual(reopened.delivery(for: "a"), before, "off forgets nothing about what was sent")

        // Off again keeps the first date: it says since when.
        reopened.setSending(false, to: "a", at: off.addingTimeInterval(500))
        XCTAssertEqual(store.computer("a")?.pausedAt, off)

        reopened.setSending(true, to: "a")
        XCTAssertNil(store.computer("a")?.pausedAt)
        XCTAssertEqual(store.delivery(for: "a"), before)
        XCTAssertNil(store.setSending(false, to: "gone"), "a forgotten computer is not brought back")
        XCTAssertNil(store.computer("gone"))
    }

    // MARK: The rule

    func testOffAllowsNoSyncAtAllAndRefusedAllowsOnlyWhatThePersonAsksFor() {
        var on = PairedComputer(endpointID: "on", name: "on")
        var off = PairedComputer(endpointID: "off", name: "off")
        off.pausedAt = Date()
        var refused = PairedComputer(endpointID: "refused", name: "refused")
        refused.needsPairing = true
        var offAndRefused = refused
        offAndRefused.endpointID = "off-refused"
        offAndRefused.pausedAt = Date()

        let all: [LinkSyncReason] = [.changed, .foreground, .manual, .paired]
        XCTAssertEqual(all.filter { on.allowsSync($0) }, all)
        XCTAssertEqual(all.filter { off.allowsSync($0) }, [], "Sync now included")
        XCTAssertEqual(all.filter { refused.allowsSync($0) }, [.manual, .paired])
        XCTAssertEqual(all.filter { offAndRefused.allowsSync($0) }, [])
        XCTAssertTrue(on.syncsAutomatically)
        XCTAssertFalse(off.syncsAutomatically)
        XCTAssertFalse(refused.syncsAutomatically)

        let computers = [on, off, refused, offAndRefused]
        XCTAssertEqual(computers.due(for: .changed), ["on"])
        XCTAssertEqual(computers.due(for: .foreground), ["on"])
        XCTAssertEqual(computers.due(for: .manual), ["on", "refused"])

        on.pausedAt = Date()
        XCTAssertEqual([on].due(for: .foreground), [])
        on.pausedAt = nil
        XCTAssertEqual([on].due(for: .foreground), ["on"])
    }

    func testAStrongerReasonWins() {
        XCTAssertLessThan(LinkSyncReason.changed, .foreground)
        XCTAssertLessThan(LinkSyncReason.foreground, .manual)
        XCTAssertLessThan(LinkSyncReason.manual, .paired)
        XCTAssertEqual(max(LinkSyncReason.changed, .manual), .manual)
    }

    // MARK: Back on

    func testBackOnSendsOnlyWhatChangedWhileOffDeletionsIncluded() async throws {
        let phone = LinkTestPhone()
        let computer = FakeComputer()
        let doomed = phone.dictate(1)
        let edited = phone.dictate(2)
        phone.dictate(3)
        phone.notes = [LinkFixtures.note(1)]
        _ = try await phone.sync(with: computer, pair: computer.newPairingSecret())
        XCTAssertEqual(computer.liveRows.count, 4)
        computer.clearFrames()

        // A second computer, on, that already had dictation 1 and is told about its deletion first.
        phone.store.add(PairedComputer(endpointID: "other", name: "other"))
        phone.store.updateDelivery(for: "other") { state in
            state.acknowledge(phone.library())
        }

        phone.store.setSending(false, to: phone.endpointID)
        XCTAssertFalse(try XCTUnwrap(phone.store.computer(phone.endpointID)).allowsSync(.foreground))

        // While off: a new dictation, an edit, an explicit delete.
        phone.now = phone.now.addingTimeInterval(60)
        phone.dictate(4)
        phone.history.mark(id: edited, status: .inserted, now: phone.now)
        phone.history.delete(id: doomed)
        XCTAssertEqual(phone.log.all().map(\.id), [doomed.uuidString])

        // The other computer hears of the deletion and the log is pruned: the entry stays,
        // because the computer that is off may still have the record.
        let deletion = phone.store.delivery(for: "other").pending(library: phone.library(), deletions: phone.log.all())
            .filter(\.deleted)
        XCTAssertEqual(deletion.map(\.id), [doomed.uuidString])
        phone.store.updateDelivery(for: "other") { $0.acknowledge(deletion) }
        phone.store.pruneDeletions(phone.log, libraryIDs: Set(phone.library().map(\.id)))
        XCTAssertEqual(phone.log.all().map(\.id), [doomed.uuidString], "kept for the computer that is off")

        // Nothing reached the computer while it was off.
        XCTAssertTrue(computer.frames.isEmpty)
        XCTAssertEqual(computer.liveRows.count, 4)

        // Back on: one session sends the new one, the edited one and the deletion. Nothing else.
        let on = try XCTUnwrap(phone.store.setSending(true, to: phone.endpointID))
        XCTAssertTrue(on.allowsSync(.foreground))
        let outcome = try await phone.sync(with: computer)

        let sent = computer.frames.flatMap { $0 }
        XCTAssertEqual(Set(sent.filter { !$0.deleted }.map(\.id)), [LinkFixtures.uuid(4).uuidString, edited.uuidString])
        XCTAssertEqual(sent.filter(\.deleted).map(\.id), [doomed.uuidString])
        XCTAssertEqual(outcome.delivered, 3, "deletions included")
        XCTAssertEqual(outcome.deletions, 1)
        XCTAssertEqual(computer.rows[doomed.uuidString]?.deleted, true)
        XCTAssertEqual(computer.rows[edited.uuidString]?.item.status, "inserted")
        XCTAssertEqual(computer.liveRows.count, 4, "1 deleted, 4 added")
        XCTAssertTrue(phone.log.all().isEmpty, "every computer that may have had it has been told")
    }

    func testAFlashWhileOffCountsAndLeavesTheSwitchOff() throws {
        let phone = LinkTestPhone()
        phone.dictate(1)
        phone.dictate(2)
        phone.store.setSending(false, to: phone.endpointID)

        let items = phone.store.delivery(for: phone.endpointID).pending(library: phone.library(), deletions: [])
        XCTAssertEqual(items.count, 2)
        phone.store.recordFlash(items, to: phone.endpointID)

        let computer = try XCTUnwrap(phone.store.computer(phone.endpointID))
        XCTAssertTrue(computer.isPaused, "a flash does not turn sending back on")
        XCTAssertEqual(computer.itemsSent, 2)
        XCTAssertNotNil(computer.lastFlashAt)
        XCTAssertTrue(phone.store.delivery(for: phone.endpointID).pending(library: phone.library(), deletions: []).isEmpty,
                      "back on, nothing the flash carried goes again")
    }
}
