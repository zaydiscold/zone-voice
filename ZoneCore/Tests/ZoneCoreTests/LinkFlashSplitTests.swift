// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// A library larger than one flash: each flash the person confirms carries the next part, and
/// together they carry the whole library and its deletions exactly once, in both choices.
final class LinkFlashSplitTests: XCTestCase {
    private let key = FlashFixtures.bytes(hex: FlashFixtures.keyHex)

    /// 300 dictations with varied words outside the history file, five in it, the computer
    /// told about all of them, then three of the five deleted on purpose.
    private func phoneWithALargeLibrary() -> LinkTestPhone {
        let phone = LinkTestPhone()
        phone.extraDictations = (0..<300).map { number in
            LinkFixtures.dictation(number, text: "Dictation \(number), item \(number * 7919 % 10_007), with words that do not repeat \(number * 104_729 % 99_991).")
        }
        for number in 1_000..<1_005 { phone.dictate(number) }
        phone.store.acknowledge(phone.library(), by: phone.endpointID)
        for number in 1_000..<1_003 { phone.history.delete(id: LinkFixtures.uuid(number)) }
        return phone
    }

    /// Small pieces and a small limit stand in for a library past `planChunks`.
    private func plan(_ items: [LinkItem]) throws -> LinkFlashPlan {
        try LinkFlash.plan(items: items, phone: FlashFixtures.phone, key: key, chunkBytes: 64, maxChunks: 40)
    }

    /// Flashes with this choice, each confirmed, until one carries all that was left.
    private func flashUntilDone(_ phone: LinkTestPhone, everything: Bool,
                                between: (Int, LinkFlashPlan) -> Void = { _, _ in }) throws -> [LinkFlashPlan] {
        var plans: [LinkFlashPlan] = []
        while plans.count < 200 {
            let sending = phone.store.flashItems(for: phone.endpointID, everything: everything,
                                                 library: phone.library(), deletions: phone.log.all())
            let plan = try plan(sending)
            XCTAssertEqual(plan.items.count + plan.leftOut, sending.count)
            XCTAssertLessThanOrEqual(plan.encoder.chunkCount, 40)
            phone.store.recordFlash(plan, everything: everything, to: phone.endpointID)
            plans.append(plan)
            between(plans.count, plan)
            if plan.leftOut == 0 { break }
        }
        return plans
    }

    func testEverythingInSeveralFlashesCarriesTheWholeLibraryAndItsDeletionsOnce() throws {
        let phone = phoneWithALargeLibrary()
        let library = phone.library()
        XCTAssertEqual(library.count, 302)
        let everything = phone.store.flashItems(for: phone.endpointID, everything: true, library: library, deletions: phone.log.all())
        XCTAssertEqual(everything.count, 305, "the library, then the three deletions")
        XCTAssertEqual(everything.suffix(3).map(\.deleted), [true, true, true])

        let plans = try flashUntilDone(phone, everything: true)
        XCTAssertGreaterThan(plans.count, 3, "a library this size takes several flashes")
        let carried = plans.flatMap(\.items)
        XCTAssertEqual(carried.count, 305, "nothing carried twice")
        XCTAssertEqual(Set(carried.filter { !$0.deleted }.map(\.id)), Set(library.map(\.id)))
        XCTAssertEqual(Set(carried.filter(\.deleted).map(\.id)), Set((1_000..<1_003).map { LinkFixtures.uuid($0).uuidString }))
        // Each flash went on where the one before it stopped.
        XCTAssertEqual(carried.map(\.id), everything.map(\.id))

        // The round is over: the next Everything is the whole library again, and the deletions
        // were told, so they are gone.
        XCTAssertNil(phone.store.computer(phone.endpointID)?.flashResume)
        let next = phone.store.flashItems(for: phone.endpointID, everything: true, library: phone.library(), deletions: phone.log.all())
        XCTAssertEqual(next.map(\.id), everything.prefix(302).map(\.id))
        XCTAssertNotNil(phone.store.computer(phone.endpointID)?.lastFlashAt)
    }

    func testNotSentYetInSeveralFlashesCarriesWhatWasNotSentOnce() throws {
        let phone = LinkTestPhone()
        phone.extraDictations = (0..<300).map { LinkFixtures.dictation($0, text: "Words \($0 * 7919 % 10_007) and \($0 * 104_729 % 99_991).") }
        let pending = phone.store.flashItems(for: phone.endpointID, everything: false, library: phone.library(), deletions: phone.log.all())
        XCTAssertEqual(pending.count, 300)
        let plans = try flashUntilDone(phone, everything: false)
        XCTAssertGreaterThan(plans.count, 3)
        XCTAssertEqual(plans.flatMap(\.items).map(\.id), pending.map(\.id), "each part once, in order")
        XCTAssertTrue(phone.store.flashItems(for: phone.endpointID, everything: false, library: phone.library(), deletions: phone.log.all()).isEmpty)
        XCTAssertNil(phone.store.computer(phone.endpointID)?.flashResume, "Not sent yet leaves Everything's place alone")
    }

    /// A record edited during a round goes again later in the same round; one not reached yet
    /// goes once, as it is now.
    func testARecordEditedDuringARoundGoesAgainInIt() throws {
        let phone = phoneWithALargeLibrary()
        let first = LinkFixtures.uuid(0).uuidString
        let later = LinkFixtures.uuid(299).uuidString
        let plans = try flashUntilDone(phone, everything: true) { count, plan in
            guard count == 1 else { return }
            XCTAssertTrue(plan.items.contains { $0.id == first })
            XCTAssertFalse(plan.items.contains { $0.id == later })
            var extra = phone.extraDictations
            for number in [0, 299] {
                extra[number].text = "Edited after the first flash"
                extra[number].updatedAt = phone.now
            }
            phone.extraDictations = extra
        }
        let carried = plans.flatMap(\.items)
        XCTAssertEqual(carried.filter { $0.id == first }.map(\.text), ["Dictation 0, item 0, with words that do not repeat 0.", "Edited after the first flash"])
        XCTAssertEqual(carried.filter { $0.id == later }.map(\.text), ["Edited after the first flash"])
        XCTAssertTrue(phone.store.flashItems(for: phone.endpointID, everything: false, library: phone.library(), deletions: phone.log.all()).isEmpty,
                      "the computer has every record as it is now")
    }

    func testEverythingCanStartAgainFromTheFirstRecord() throws {
        let phone = phoneWithALargeLibrary()
        let whole = phone.store.flashItems(for: phone.endpointID, everything: true, library: phone.library(), deletions: phone.log.all())
        let part = try plan(whole)
        XCTAssertGreaterThan(part.leftOut, 0)
        phone.store.recordFlash(part, everything: true, to: phone.endpointID)
        let resume = try XCTUnwrap(phone.store.computer(phone.endpointID)?.flashResume)
        XCTAssertEqual(resume.id, part.items.last?.id)

        let rest = phone.store.flashItems(for: phone.endpointID, everything: true, library: phone.library(), deletions: phone.log.all())
        XCTAssertEqual(rest.map(\.id), Array(whole.dropFirst(part.items.count)).map(\.id))
        let counted = phone.store.flashItems(for: phone.endpointID, everything: true, library: phone.library(),
                                             deletions: phone.log.all(), fromTheStart: true)
        XCTAssertEqual(counted.map(\.id), whole.map(\.id), "counting from the start ignores the place")

        phone.store.restartFlashEverything(for: phone.endpointID)
        XCTAssertNil(phone.store.computer(phone.endpointID)?.flashResume)
        XCTAssertEqual(phone.store.flashItems(for: phone.endpointID, everything: true, library: phone.library(), deletions: phone.log.all()).map(\.id),
                       whole.map(\.id))
    }

    /// Records join the library after the second flash of a round with times before where it
    /// goes on from: a note and a meeting restored from a backup keep their own times, and a
    /// dictation made while the clock was set back has an early one. A dictation the round
    /// already carried is deleted meanwhile too. The round carries each of them once, and when
    /// it ends the computer has the whole library as it is now: Not sent yet has nothing.
    func testARoundCarriesWhatJoinsTheLibraryWithAnOlderTime() throws {
        let phone = phoneWithALargeLibrary()
        let note = LinkFixtures.note(1, text: "Restored from a backup, written long before this round")
        let meeting = LinkFixtures.meeting(1)
        let clockBack = LinkFixtures.dictation(5_000, text: "Dictated while the clock was set back", at: 1_700_000_000)
        let deleted = LinkFixtures.uuid(2)
        var carriedSoFar: [LinkItem] = []
        let plans = try flashUntilDone(phone, everything: true) { count, plan in
            carriedSoFar += plan.items
            guard count == 2 else { return }
            phone.notes = [note]
            phone.meetings = [meeting]
            phone.extraDictations = phone.extraDictations.filter { $0.id != deleted } + [clockBack]
            phone.store.recordDeletion([deleted], kind: .dictation, in: phone.log)
            // All three really are before where the round goes on from.
            let resume = try? XCTUnwrap(phone.store.computer(phone.endpointID)?.flashResume)
            let joined = phone.library().filter { [note.id, meeting.id, clockBack.id].map(\.uuidString).contains($0.id) }
            XCTAssertEqual(joined.count, 3)
            for item in joined { XCTAssertEqual(resume?.precedes(item), false, item.id) }
            XCTAssertTrue(carriedSoFar.contains { $0.id == deleted.uuidString && !$0.deleted }, "carried before it was deleted")
        }
        XCTAssertGreaterThan(plans.count, 3, "the additions came part-way through the round")
        let carried = plans.flatMap(\.items)
        for id in [note.id, meeting.id, clockBack.id] {
            XCTAssertEqual(carried.filter { $0.id == id.uuidString }.count, 1, "\(id) goes in the round, once")
        }
        XCTAssertEqual(carried.filter { $0.id == deleted.uuidString }.map(\.deleted), [false, true], "carried, then its deletion")
        XCTAssertEqual(Set(carried.map { "\($0.id) \($0.deleted)" }).count, carried.count, "nothing carried twice")
        XCTAssertEqual(carried.count, 305 + 3 + 1)
        XCTAssertNil(phone.store.computer(phone.endpointID)?.flashResume, "the round is over")
        XCTAssertTrue(phone.store.flashItems(for: phone.endpointID, everything: false, library: phone.library(), deletions: phone.log.all()).isEmpty,
                      "the computer has every record as it is now, and every deletion")
    }

    /// A restored backup larger than a flash: some of the round's flashes carry only records
    /// from before where it goes on from. The place never moves back, so the round does not
    /// carry again what it already carried.
    func testThePlaceOnlyMovesForward() throws {
        let phone = phoneWithALargeLibrary()
        let restored = (0..<120).map { number in
            LinkFixtures.note(number, text: "Restored note \(number), \(number * 7919 % 10_007) and \(number * 104_729 % 99_991).")
        }
        var places: [LinkFlashResume] = []
        let plans = try flashUntilDone(phone, everything: true) { count, _ in
            if count == 1 { phone.notes = restored }
            if let place = phone.store.computer(phone.endpointID)?.flashResume { places.append(place) }
        }
        XCTAssertTrue(plans.dropFirst().contains { plan in plan.leftOut > 0 && plan.items.allSatisfy { $0.kind == .note } },
                      "a flash of restored notes only, before the round's end")
        for (earlier, later) in zip(places, places.dropFirst()) {
            XCTAssertTrue((earlier.updatedAt, earlier.id) <= (later.updatedAt, later.id), "\(later) is before \(earlier)")
        }
        let carried = plans.flatMap(\.items)
        XCTAssertEqual(carried.count, 305 + 120, "nothing carried twice")
        XCTAssertEqual(Set(carried.map(\.id)).count, carried.count)
        XCTAssertTrue(phone.store.flashItems(for: phone.endpointID, everything: false, library: phone.library(), deletions: phone.log.all()).isEmpty)
    }

    /// A new database on the computer, or one that asks for everything, holds none of what the
    /// round's earlier flashes carried: the next Everything flash starts from the first record.
    /// The first welcome, and the same database again, leave the place alone.
    func testANewComputerLibraryStartsEverythingFromTheFirstRecord() async throws {
        let phone = phoneWithALargeLibrary()
        let computer = FakeComputer()
        var resume: LinkFlashResume? { phone.store.computer(phone.endpointID)?.flashResume }
        func everything(fromTheStart: Bool = false) -> [String] {
            phone.store.flashItems(for: phone.endpointID, everything: true, library: phone.library(), deletions: phone.log.all(),
                                   fromTheStart: fromTheStart).map(\.id)
        }
        func flashAPart() throws {
            let part = try plan(phone.store.flashItems(for: phone.endpointID, everything: true, library: phone.library(),
                                                       deletions: phone.log.all()))
            XCTAssertGreaterThan(part.leftOut, 0)
            phone.store.recordFlash(part, everything: true, to: phone.endpointID)
            XCTAssertNotNil(resume)
            XCTAssertLessThan(everything().count, everything(fromTheStart: true).count)
        }

        try flashAPart()
        try await phone.sync(with: computer, pair: computer.newPairingSecret())
        XCTAssertNotNil(resume, "the first welcome has nothing to forget")
        try await phone.sync(with: computer)
        XCTAssertNotNil(resume, "the same database")

        computer.replaceDatabase()
        try await phone.sync(with: computer)
        XCTAssertNil(resume, "a new database")
        XCTAssertEqual(everything(), everything(fromTheStart: true))

        try flashAPart()
        computer.askForEverythingOnce()
        let outcome = try await phone.sync(with: computer)
        XCTAssertTrue(outcome.resendAll)
        XCTAssertNil(resume, "the computer asked for everything")
        XCTAssertEqual(everything(), everything(fromTheStart: true))
    }

    /// "Send everything again" forgets what the computer was sent and where Everything goes on.
    func testSendEverythingAgainStartsEverythingFromTheFirstRecord() throws {
        let phone = phoneWithALargeLibrary()
        let whole = phone.store.flashItems(for: phone.endpointID, everything: true, library: phone.library(), deletions: phone.log.all())
        let part = try plan(whole)
        phone.store.recordFlash(part, everything: true, to: phone.endpointID)
        XCTAssertNotNil(phone.store.computer(phone.endpointID)?.flashResume)

        let before = phone.delivery
        phone.store.forgetDeliveries(for: phone.endpointID)
        XCTAssertNil(phone.store.computer(phone.endpointID)?.flashResume)
        XCTAssertTrue(phone.delivery.delivered.isEmpty)
        XCTAssertEqual(phone.delivery.attempted, before.attempted.union(before.delivered.keys))
        let library = phone.library()
        XCTAssertEqual(phone.store.flashItems(for: phone.endpointID, everything: true, library: library, deletions: phone.log.all()).map(\.id),
                       whole.map(\.id),
                       "the whole library from its first record, including pending deletions")
        XCTAssertEqual(phone.store.flashItems(for: phone.endpointID, everything: false, library: library, deletions: phone.log.all()).count,
                       whole.count, "and Not sent yet includes the same deletions")
    }

    /// A waiting clip goes first in every flash until one that carried it is confirmed.
    func testAWaitingClipGoesFirstUntilAFlashCarriesIt() throws {
        let phone = phoneWithALargeLibrary()
        let clip = try phone.store.clips.add("https://example.invalid/clip", source: .typed, to: [phone.endpointID])
        let plans = try flashUntilDone(phone, everything: true)
        XCTAssertEqual(plans.first?.items.first?.id, clip.id.uuidString)
        XCTAssertEqual(plans.flatMap(\.items).filter { $0.kind == .clip }.count, 1, "carried once")
        XCTAssertTrue(phone.store.clips.pending(for: phone.endpointID).isEmpty)
    }

    func testAComputerSavedBeforeEverythingWentOnStartsFromTheFirstRecord() throws {
        let old = #"[{"endpointID":"abc","name":"box","pairedAt":0,"confirmed":true,"itemsSent":3,"needsPairing":false,"lastFlashAt":0}]"#
        let computers = try JSONDecoder().decode([PairedComputer].self, from: Data(old.utf8))
        XCTAssertNil(computers.first?.flashResume)
        var saved = try XCTUnwrap(computers.first)
        saved.flashResume = LinkFlashResume(updatedAt: 1_794_445_200.5, id: "X")
        let again = try JSONDecoder().decode(PairedComputer.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(again.flashResume, saved.flashResume)
    }

    /// The place sorts the way Everything sends the library: time, then id.
    func testThePlaceComesBeforeLaterRecordsOnly() {
        let resume = LinkFlashResume(updatedAt: 10, id: "B")
        func item(_ time: Double, _ id: String) -> LinkItem { LinkItem(id: id, kind: .note, createdAt: time, updatedAt: time, text: "t") }
        XCTAssertTrue(resume.precedes(item(10, "C")))
        XCTAssertTrue(resume.precedes(item(11, "A")))
        XCTAssertFalse(resume.precedes(item(10, "B")), "not the record itself")
        XCTAssertFalse(resume.precedes(item(10, "A")))
        XCTAssertFalse(resume.precedes(item(9.5, "Z")))
    }
}
