// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

extension LinkTestPhone {
    /// One session over an in-memory pipe.
    @discardableResult
    func sync(with computer: FakeComputer, pair: String? = nil, frameTimeout: TimeInterval = 5) async throws -> LinkSessionOutcome {
        let (phoneEnd, computerEnd) = LinkMemoryStream.pair()
        let identity = identity
        let serving = Task { await computer.serve(computerEnd, peer: identity) }
        defer { phoneEnd.hangUp(); serving.cancel() }
        let delegate = LinkComputerSync(endpointID: endpointID, store: store, deletions: log) { [self] in library() }
        let outcome = try await LinkSession.run(
            over: phoneEnd, phone: LinkPhone(id: "INSTALL", name: "Test iPhone", app: "1.0.3 (1)"), pairSecret: pair,
            delegate: delegate, frameTimeout: frameTimeout, onStall: { phoneEnd.hangUp() })
        store.pruneDeletions(log, libraryIDs: Set(library().map(\.id)))
        return outcome
    }
}

final class LinkSyncTests: XCTestCase {
    private var phone: LinkTestPhone!
    private var computer: FakeComputer!

    override func setUp() {
        phone = LinkTestPhone()
        computer = FakeComputer()
    }

    private func pairAndSync() async throws -> LinkSessionOutcome {
        try await phone.sync(with: computer, pair: computer.newPairingSecret())
    }

    private func assertRefused(_ reason: String, pair: String? = nil, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await phone.sync(with: computer, pair: pair)
            XCTFail("expected refused \(reason)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? LinkSessionError, .refused(reason), file: file, line: line)
        }
    }

    // MARK: Pairing and the first send

    func testPairingSendsTheWholeLibraryInFramesEachAcknowledged() async throws {
        phone.extraDictations = (0..<1_203).map { LinkFixtures.dictation($0) }
        phone.notes = [LinkFixtures.note(1), LinkFixtures.note(2)]
        phone.meetings = [LinkFixtures.meeting()]

        let outcome = try await pairAndSync()

        XCTAssertEqual(outcome.delivered, 1_206)
        XCTAssertEqual(outcome.frames, 3)
        XCTAssertEqual(computer.frames.map(\.count), [500, 500, 206])
        XCTAssertEqual(computer.liveRows.count, 1_206)
        XCTAssertEqual(Set(computer.liveRows.map(\.item.kind)), [.dictation, .note, .meeting])
        XCTAssertEqual(phone.delivery.delivered.count, 1_206)
        XCTAssertTrue(phone.delivery.attempted.isEmpty)
        XCTAssertEqual(phone.delivery.computerID, computer.databaseID)

        guard case .hello(let who, let pair)? = computer.hellos.first else { return XCTFail("no hello") }
        XCTAssertEqual(who, LinkPhone(id: "INSTALL", name: "Test iPhone", app: "1.0.3 (1)"))
        XCTAssertEqual(pair?.count, 64)

        let saved = try XCTUnwrap(phone.store.computer(phone.endpointID))
        XCTAssertTrue(saved.confirmed)
        XCTAssertEqual(saved.itemsSent, 1_206)
        XCTAssertEqual(saved.computerID, computer.databaseID)
        XCTAssertEqual(saved.os, "macos")
    }

    func testASecondSessionSendsNothingNewAndCarriesNoSecret() async throws {
        phone.dictate(1); phone.dictate(2)
        phone.notes = [LinkFixtures.note(1)]
        _ = try await pairAndSync()
        computer.clearFrames()

        let outcome = try await phone.sync(with: computer)

        XCTAssertEqual(outcome.delivered, 0)
        XCTAssertEqual(outcome.frames, 0)
        XCTAssertTrue(computer.frames.isEmpty)
        guard case .hello(_, let pair)? = computer.hellos.last else { return XCTFail("no hello") }
        XCTAssertNil(pair, "the pairing secret goes out once")
        XCTAssertEqual(computer.sessions, 2)
    }

    func testOnlyAChangedOrNewRecordIsSentAgain() async throws {
        let first = phone.dictate(1)
        phone.dictate(2)
        var note = LinkFixtures.note(1)
        phone.notes = [note]
        _ = try await pairAndSync()
        computer.clearFrames()

        phone.now = phone.now.addingTimeInterval(60)
        phone.history.mark(id: first, status: .inserted, now: phone.now)
        note.text = "note, edited"
        note.editedAt = phone.now
        phone.notes = [note]
        phone.dictate(3)

        let outcome = try await phone.sync(with: computer)

        XCTAssertEqual(outcome.delivered, 3)
        XCTAssertEqual(Set(computer.frames.flatMap { $0 }.map(\.id)),
                       [first.uuidString, note.id.uuidString, LinkFixtures.uuid(3).uuidString])
        XCTAssertEqual(computer.rows[first.uuidString]?.item.status, "inserted")
        XCTAssertEqual(computer.rows[note.id.uuidString]?.item.text, "note, edited")
        XCTAssertEqual(computer.liveRows.count, 4)
    }

    // MARK: Deletions and retention

    func testAnExplicitDeleteIsSentAsADeletion() async throws {
        let doomed = phone.dictate(1)
        phone.dictate(2)
        _ = try await pairAndSync()
        computer.clearFrames()

        phone.history.delete(id: doomed)
        XCTAssertEqual(phone.log.all().map(\.id), [doomed.uuidString])
        let outcome = try await phone.sync(with: computer)

        XCTAssertEqual(outcome.deletions, 1)
        let sent = computer.frames.flatMap { $0 }
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(sent[0].deleted)
        XCTAssertEqual(sent[0].kind, .dictation)
        XCTAssertEqual(computer.rows[doomed.uuidString]?.deleted, true)
        XCTAssertNil(computer.rows[doomed.uuidString]?.item.text, "the computer drops the text")
        XCTAssertEqual(computer.liveRows.count, 1)
        XCTAssertNil(phone.delivery.delivered[doomed.uuidString])
        XCTAssertEqual(phone.store.computer(phone.endpointID)?.itemsSent, 2, "a deletion is not an item sent")
        XCTAssertTrue(phone.log.all().isEmpty, "told once, then forgotten")

        computer.clearFrames()
        let outcome1 = try await phone.sync(with: computer)
        XCTAssertEqual(outcome1.delivered, 0)
    }

    func testRecordsThatAgeOutOfHistoryAreNotDeletions() async throws {
        // History keeps dictations until deleted by default, so choose thirty days, as a person can.
        phone.history.setRetention(.thirtyDays, now: phone.now)
        phone.dictate(1); phone.dictate(2); phone.dictate(3)
        _ = try await pairAndSync()
        computer.clearFrames()

        // Thirty-one days on, thirty-day retention drops all three.
        phone.now = phone.now.addingTimeInterval(31 * 86_400)
        phone.history.purgeExpired(now: phone.now)
        XCTAssertTrue(phone.history.records(now: phone.now).isEmpty)
        XCTAssertTrue(phone.log.all().isEmpty, "retention is not a deletion")

        let outcome = try await phone.sync(with: computer)

        XCTAssertEqual(outcome.delivered, 0)
        XCTAssertTrue(computer.frames.isEmpty)
        XCTAssertEqual(computer.liveRows.count, 3, "the computer is the long-term copy")
    }

    func testAShorterRetentionIsNotADeletionEither() async throws {
        phone.dictate(1)
        _ = try await pairAndSync()
        computer.clearFrames()

        phone.history.setRetention(.off, now: phone.now)
        XCTAssertTrue(phone.history.records(now: phone.now).isEmpty)

        let outcome2 = try await phone.sync(with: computer)
        XCTAssertEqual(outcome2.delivered, 0)
        XCTAssertEqual(computer.liveRows.count, 1)
    }

    func testDeleteRangeAndDeleteAllSendDeletions() async throws {
        phone.dictate(1)
        phone.now = phone.now.addingTimeInterval(3_600)
        let later = phone.now
        phone.dictate(2); phone.dictate(3)
        _ = try await pairAndSync()

        phone.history.delete(createdIn: later.addingTimeInterval(-1)...later.addingTimeInterval(1))
        let outcome3 = try await phone.sync(with: computer)
        XCTAssertEqual(outcome3.deletions, 2)
        XCTAssertEqual(computer.liveRows.map(\.item.id), [LinkFixtures.uuid(1).uuidString])

        phone.history.deleteAll()
        let outcome4 = try await phone.sync(with: computer)
        XCTAssertEqual(outcome4.deletions, 1)
        XCTAssertTrue(computer.liveRows.isEmpty)
        XCTAssertEqual(computer.rows.count, 3, "deleted rows stay as markers")
    }

    func testNoteAndMeetingDeletionsCarryTheirKind() async throws {
        let note = LinkFixtures.note(1)
        let meeting = LinkFixtures.meeting()
        phone.notes = [note]
        phone.meetings = [meeting]
        _ = try await pairAndSync()
        computer.clearFrames()

        phone.notes = []
        phone.log.record([note.id], kind: .note, at: phone.now)
        phone.meetings = []
        phone.log.record([meeting.id], kind: .meeting, at: phone.now)
        _ = try await phone.sync(with: computer)

        let sent = computer.frames.flatMap { $0 }
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.first { $0.id == note.id.uuidString }?.kind, .note)
        XCTAssertEqual(sent.first { $0.id == meeting.id.uuidString }?.kind, .meeting)
        XCTAssertTrue(sent.allSatisfy(\.deleted))
        XCTAssertTrue(computer.liveRows.isEmpty)
    }

    func testDeletingSomethingTheComputerNeverHadSendsNothing() async throws {
        phone.dictate(1)
        _ = try await pairAndSync()
        computer.clearFrames()

        let unsent = phone.dictate(2)
        phone.history.delete(id: unsent)
        // A cancelled dictation was never a finished record: it does not even reach the log.
        phone.history.begin(id: LinkFixtures.uuid(3), engine: "fluidMini", source: .keyboard, now: phone.now)
        phone.history.cancel(id: LinkFixtures.uuid(3))
        XCTAssertEqual(phone.log.all().map(\.id), [unsent.uuidString])

        let outcome5 = try await phone.sync(with: computer)
        XCTAssertEqual(outcome5.delivered, 0)
        XCTAssertTrue(computer.frames.isEmpty)
        XCTAssertTrue(phone.log.all().isEmpty, "nobody needs it, so the log lets it go")
    }

    func testARecordThatComesBackUnderTheSameIdIsNotDeleted() async throws {
        let id = phone.dictate(1, text: "cut off halfway")
        _ = try await pairAndSync()
        phone.history.delete(id: id)
        phone.now = phone.now.addingTimeInterval(5)
        phone.dictate(1, text: "the whole recording, retried")

        let outcome = try await phone.sync(with: computer)

        XCTAssertEqual(outcome.deletions, 0)
        XCTAssertEqual(computer.rows[id.uuidString]?.deleted, false)
        XCTAssertEqual(computer.rows[id.uuidString]?.item.text, "the whole recording, retried")
    }

    // MARK: Refusals and resets

    func testNotPairedIsRefusedAndNothingIsSent() async throws {
        phone.dictate(1)
        await assertRefused("not_paired")
        XCTAssertTrue(computer.frames.isEmpty)
        XCTAssertTrue(phone.delivery.delivered.isEmpty)
        XCTAssertEqual(phone.store.computer(phone.endpointID)?.confirmed, false)

        // Forgotten by the computer after a good pairing: the same answer, and the phone keeps
        // what it knows, so pairing again sends only what is new.
        _ = try await pairAndSync()
        computer.forgetPhones()
        phone.dictate(2)
        await assertRefused("not_paired")
        XCTAssertEqual(phone.delivery.delivered.count, 1)
        computer.clearFrames()
        let outcome6 = try await pairAndSync()
        XCTAssertEqual(outcome6.delivered, 1)
    }

    func testAWrongOrUsedSecretIsRefused() async throws {
        phone.dictate(1)
        await assertRefused("bad_secret", pair: String(repeating: "0", count: 64))
        let secret = computer.newPairingSecret()
        _ = try await phone.sync(with: computer, pair: secret)
        computer.forgetPhones()
        await assertRefused("bad_secret", pair: secret)
        XCTAssertEqual(LinkSessionError.refused("bad_secret").needsPairing, true)
    }

    func testBusyAndVersionAreReportedInPlainWords() async {
        computer.refuseEverything("busy")
        await assertRefused("busy")
        XCTAssertFalse(LinkSessionError.refused("busy").needsPairing)
        for error in [LinkSessionError.refused("busy"), .refused("version"), .refused("not_paired"), .refused("bad_secret"),
                      .refused("???"), .unexpected("x"), .timedOut, .unreachable("x"), .connectionLost("x")] {
            XCTAssertFalse(error.plainMessage.isEmpty)
            XCTAssertFalse(error.plainMessage.contains("\u{2014}"), "no long dashes in what people read")
            XCTAssertFalse(error.plainMessage.contains("_"), "no protocol codes in what people read")
        }
    }

    func testResendAllSendsEverythingAgain() async throws {
        phone.dictate(1); phone.dictate(2)
        phone.notes = [LinkFixtures.note(1)]
        _ = try await pairAndSync()
        computer.clearFrames()

        computer.askForEverythingOnce()
        let outcome = try await phone.sync(with: computer)

        XCTAssertTrue(outcome.resendAll)
        XCTAssertEqual(outcome.delivered, 3)
        XCTAssertEqual(computer.frames.flatMap { $0 }.count, 3)
        computer.clearFrames()
        let outcome7 = try await phone.sync(with: computer)
        XCTAssertEqual(outcome7.delivered, 0, "asked once, sent once")
    }

    func testResendingToTheSameDatabaseDeliversAnOfflineDeletion() async throws {
        phone.dictate(1)
        let fromPhone = phone.dictate(2)
        let fromComputer = phone.dictate(3)
        _ = try await pairAndSync()

        phone.history.delete(id: fromPhone)
        phone.store.forgetDeliveries(for: phone.endpointID)
        let first = try await phone.sync(with: computer)
        XCTAssertEqual(first.deletions, 1)
        XCTAssertEqual(computer.rows[fromPhone.uuidString]?.deleted, true)

        phone.history.delete(id: fromComputer)
        computer.askForEverythingOnce()
        let second = try await phone.sync(with: computer)
        XCTAssertEqual(second.deletions, 1)
        XCTAssertEqual(computer.rows[fromComputer.uuidString]?.deleted, true)
        XCTAssertEqual(computer.liveRows.count, 1)
    }

    func testANewDatabaseGetsEverythingAgain() async throws {
        phone.dictate(1); phone.dictate(2)
        _ = try await pairAndSync()
        let old = computer.databaseID

        computer.replaceDatabase()
        let outcome = try await phone.sync(with: computer)

        XCTAssertNotEqual(computer.databaseID, old)
        XCTAssertFalse(outcome.resendAll)
        XCTAssertEqual(outcome.delivered, 2)
        XCTAssertEqual(computer.liveRows.count, 2)
        XCTAssertEqual(phone.delivery.computerID, computer.databaseID)
    }

    // MARK: Failures in the middle

    func testAFrameWithNoAckIsNotDeliveredAndGoesAgain() async throws {
        _ = try await pairAndSync()
        phone.dictate(1); phone.dictate(2)
        computer.goSilentAfterItems(true)

        do {
            try await phone.sync(with: computer, frameTimeout: 0.3)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? LinkSessionError, .timedOut)
        }
        XCTAssertTrue(phone.delivery.delivered.isEmpty, "no ack, not delivered")
        XCTAssertEqual(phone.delivery.attempted.count, 2)

        computer.goSilentAfterItems(false)
        computer.clearFrames()
        let outcome8 = try await phone.sync(with: computer)
        XCTAssertEqual(outcome8.delivered, 2)
        XCTAssertEqual(phone.delivery.delivered.count, 2)
        XCTAssertTrue(phone.delivery.attempted.isEmpty)
    }

    func testDeletingAnItemWhoseAckWasLostStillTellsTheComputer() async throws {
        _ = try await pairAndSync()
        let id = phone.dictate(1)
        computer.goSilentAfterItems(true)
        _ = try? await phone.sync(with: computer, frameTimeout: 0.3)
        XCTAssertEqual(computer.rows[id.uuidString]?.deleted, false, "the computer stored it; only the ack was lost")

        phone.history.delete(id: id)
        computer.goSilentAfterItems(false)
        let outcome9 = try await phone.sync(with: computer)
        XCTAssertEqual(outcome9.deletions, 1)
        XCTAssertEqual(computer.rows[id.uuidString]?.deleted, true)
    }

    func testAComputerThatHangsUpFailsCleanly() async throws {
        let (phoneEnd, computerEnd) = LinkMemoryStream.pair()
        computerEnd.hangUp()
        let delegate = LinkComputerSync(endpointID: phone.endpointID, store: phone.store, deletions: phone.log) { [] }
        do {
            _ = try await LinkSession.run(over: phoneEnd, phone: LinkPhone(id: "I", name: "n", app: "a"), pairSecret: nil,
                                          delegate: delegate, frameTimeout: 2)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is LinkByteQueue.Closed)
        }
    }

    func testAnOversizedOrUnreadableFrameEndsTheSession() async throws {
        for bytes in [Data([0xff, 0xff, 0xff, 0xff]), try LinkFrame.frame(Data("not json".utf8)),
                      try LinkFrame.frame(Data(#"{"t":"ack","seq":1}"#.utf8))] {
            let (phoneEnd, computerEnd) = LinkMemoryStream.pair()
            try await computerEnd.write(bytes)
            let delegate = LinkComputerSync(endpointID: phone.endpointID, store: phone.store, deletions: phone.log) { [] }
            do {
                _ = try await LinkSession.run(over: phoneEnd, phone: LinkPhone(id: "I", name: "n", app: "a"), pairSecret: nil,
                                              delegate: delegate, frameTimeout: 2)
                XCTFail("expected an error")
            } catch let error as LinkSessionError {
                guard case .unexpected = error else { return XCTFail("\(error)") }
            }
        }
    }
}

final class LinkDeliveryStateTests: XCTestCase {
    private func item(_ number: Int, text: String = "words") -> LinkItem {
        LinkEncoding.item(LinkFixtures.dictation(number, text: text))!
    }

    func testPendingIsWhatTheComputerLacksOldestFirst() {
        var state = LinkDeliveryState()
        let library = [item(3), item(1), item(2)]
        XCTAssertEqual(state.pending(library: library, deletions: []).map(\.id), [item(1), item(2), item(3)].map(\.id))

        state.acknowledge([item(1), item(2)])
        XCTAssertEqual(state.pending(library: library, deletions: []).map(\.id), [item(3).id])
        XCTAssertEqual(state.pending(library: [item(1, text: "edited"), item(2)], deletions: []).map(\.id), [item(1).id])
    }

    func testAdoptForgetsOnlyWhenTheDatabaseChangedOrAskedTo() {
        var state = LinkDeliveryState()
        XCTAssertFalse(state.adopt(computerID: "A", resendAll: false), "the first welcome has nothing to forget")
        state.acknowledge([item(1)])
        XCTAssertFalse(state.adopt(computerID: "A", resendAll: false))
        XCTAssertEqual(state.delivered.count, 1)
        XCTAssertTrue(state.adopt(computerID: "A", resendAll: true))
        XCTAssertTrue(state.delivered.isEmpty)
        state.acknowledge([item(1)])
        XCTAssertTrue(state.adopt(computerID: "B", resendAll: false))
        XCTAssertTrue(state.delivered.isEmpty)
        XCTAssertEqual(state.computerID, "B")
    }

    func testDeletionsGoOnlyWhereTheItemMayBe() {
        var state = LinkDeliveryState()
        state.acknowledge([item(1)])
        state.willSend([item(2)])
        let deletions = [1, 2, 3].map { LinkDeletion(id: item($0).id, kind: .dictation, at: Double($0)) }
        let pending = state.pending(library: [], deletions: deletions + deletions)
        XCTAssertEqual(pending.map(\.id), [item(1).id, item(2).id], "delivered and attempted, each once, never the unknown one")
        XCTAssertTrue(pending.allSatisfy(\.deleted))

        state.acknowledge(pending)
        XCTAssertFalse(state.mayHave(item(1).id))
        XCTAssertFalse(state.mayHave(item(2).id))
    }

    func testStateSurvivesEncodingAndOlderFiles() throws {
        var state = LinkDeliveryState(computerID: "A")
        state.acknowledge([item(1)])
        state.willSend([item(2)])
        XCTAssertEqual(try JSONDecoder().decode(LinkDeliveryState.self, from: JSONEncoder().encode(state)), state)
        XCTAssertEqual(try JSONDecoder().decode(LinkDeliveryState.self, from: Data("{}".utf8)), LinkDeliveryState())
    }
}

final class LinkStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("link-store-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    func testNothingIsWrittenUntilAComputerIsPaired() {
        let store = LinkStore(directory: directory)
        XCTAssertTrue(store.computers().isEmpty)
        XCTAssertEqual(store.delivery(for: "x"), LinkDeliveryState())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testComputersAndDeliveryPersistAndForgettingRemovesBoth() {
        let store = LinkStore(directory: directory)
        store.add(PairedComputer(endpointID: "a", name: "one"))
        store.add(PairedComputer(endpointID: "b", name: "two"))
        store.update("a") { $0.itemsSent = 12; $0.lastError = "offline" }
        store.updateDelivery(for: "a") { $0.delivered["id"] = "rev" }
        store.updateDelivery(for: "b") { $0.delivered["id"] = "rev" }

        let reopened = LinkStore(directory: directory)
        XCTAssertEqual(reopened.computers().map(\.name), ["one", "two"])
        XCTAssertEqual(reopened.computer("a")?.itemsSent, 12)
        XCTAssertEqual(reopened.delivery(for: "a").delivered, ["id": "rev"])

        store.add(PairedComputer(endpointID: "a", name: "one again"))
        XCTAssertEqual(reopened.computers().map(\.name), ["two", "one again"], "pairing again replaces the entry")

        reopened.remove("a")
        XCTAssertEqual(store.computers().map(\.endpointID), ["b"])
        XCTAssertEqual(store.delivery(for: "a"), LinkDeliveryState())
        XCTAssertEqual(store.delivery(for: "b").delivered, ["id": "rev"])
        XCTAssertNil(store.update("a") { $0.itemsSent = 1 })

        // A session still finishing for a forgotten computer leaves nothing behind.
        store.updateDelivery(for: "a") { $0.delivered["late"] = "rev" }
        XCTAssertEqual(store.delivery(for: "a"), LinkDeliveryState())
    }

    func testDeletionLogKeepsOneEntryPerRecordAndClears() {
        let log = LinkDeletionLog(fileURL: directory.appendingPathComponent("deletions.json"))
        let id = UUID()
        log.record([id], kind: .note, at: Date(timeIntervalSince1970: 10))
        log.record([id, UUID()], kind: .note, at: Date(timeIntervalSince1970: 20))
        log.record([], kind: .note)
        XCTAssertEqual(log.all().count, 2)
        XCTAssertEqual(log.all().first, LinkDeletion(id: id.uuidString, kind: .note, at: 10))
        XCTAssertEqual(LinkDeletionLog(fileURL: log.fileURL).all().count, 2, "it is a file, not memory")
        log.prune { $0.id == id.uuidString }
        XCTAssertEqual(log.all().map(\.id), [id.uuidString])
        log.clear()
        XCTAssertTrue(log.all().isEmpty)
    }

    func testSecretsInMemory() {
        let secrets = LinkMemorySecrets()
        XCTAssertNil(secrets.secret(LinkSecretName.phoneKey))
        secrets.setSecret(Data([1, 2, 3]), for: LinkSecretName.phoneKey)
        XCTAssertEqual(secrets.secret(LinkSecretName.phoneKey), Data([1, 2, 3]))
        secrets.setSecret(nil, for: LinkSecretName.phoneKey)
        XCTAssertNil(secrets.secret(LinkSecretName.phoneKey))
        XCTAssertNotEqual(LinkSecretName.pairing("a"), LinkSecretName.flash("a"))
    }
}

final class LinkDeadlineTests: XCTestCase {
    func testWorkThatFinishesInTimeReturnsItsValue() async throws {
        let value = try await LinkDeadline.run(seconds: 5) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testWorkThatNeverFinishesTimesOutAndIsToldTo() async {
        let expired = expectation(description: "onExpire")
        let started = Date()
        do {
            // A sleep that ignores cancellation stands in for a read stuck inside iroh.
            _ = try await LinkDeadline.run(seconds: 0.2, onExpire: { expired.fulfill() }) { () -> Int in
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 3) { continuation.resume() }
                }
                return 1
            }
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? LinkSessionError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "it does not wait for the stuck work")
        await fulfillment(of: [expired], timeout: 1)
    }

    func testCancellingTheCallerEndsTheWaitAtOnce() async {
        let expired = expectation(description: "onExpire")
        let task = Task {
            try await LinkDeadline.run(seconds: 30, onExpire: { expired.fulfill() }) { () -> Int in
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 3) { continuation.resume() }
                }
                return 1
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let started = Date()
        task.cancel()
        let result = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        if case .failure(let error) = result { XCTAssertTrue(error is CancellationError) } else { XCTFail("expected cancellation") }
        await fulfillment(of: [expired], timeout: 1)
    }

    func testAFailureIsPassedThrough() async {
        struct Boom: Error {}
        do {
            _ = try await LinkDeadline.run(seconds: 5) { () -> Int in throw Boom() }
            XCTFail("expected Boom")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }
}
