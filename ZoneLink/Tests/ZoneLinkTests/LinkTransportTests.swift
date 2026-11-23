// by zayd/cold @ zayd.wtf

import IrohLib
import XCTest
import ZoneCore
@testable import ZoneLink

/// The fake computer behind a real iroh endpoint, in this process: it accepts connections on
/// the `zone-sync/1` ALPN and authorizes each session by the endpoint id iroh authenticated.
final class IrohComputer: @unchecked Sendable {
    let endpoint: Endpoint
    let computer: FakeComputer
    private var accepting: Task<Void, Never>?

    init(computer: FakeComputer = FakeComputer()) async throws {
        self.computer = computer
        endpoint = try await Endpoint.bind(options: EndpointOptions(preset: presetMinimal(), alpns: [LinkProtocol.alpn]))
        let endpoint = endpoint
        accepting = Task {
            while let incoming = await endpoint.acceptNext() {
                Task {
                    guard let connection = try? await incoming.accept().connect() else { return }
                    guard connection.alpn() == LinkProtocol.alpn, let stream = try? await connection.acceptBi() else { return }
                    await computer.serve(LinkIrohStream(stream), peer: connection.remoteId().description)
                    // The phone closes when it has read everything. Closing first could cut
                    // off the last frame.
                    _ = await connection.closed()
                }
            }
        }
    }

    var id: String { endpoint.id().description }
    var peer: LinkPeer { LinkPeer(endpointID: id, addresses: endpoint.addr().directAddresses()) }

    func stop() async {
        accepting?.cancel()
        try? await endpoint.close()
    }
}

final class LinkTransportTests: XCTestCase {
    private var machine: IrohComputer!
    private var computer: FakeComputer { machine.computer }
    private var phone: LinkTestPhone!
    private var secrets: LinkMemorySecrets!
    private var transport: LinkTransport!

    override func setUp() async throws {
        machine = try await IrohComputer()
        phone = LinkTestPhone(endpointID: machine.id)
        secrets = LinkMemorySecrets()
        transport = LinkTransport(secrets: secrets, configuration: LinkTransportConfiguration(network: .isolated, connectSeconds: 10, frameSeconds: 10))
    }

    override func tearDown() async throws {
        await transport.shutdown()
        await machine.stop()
    }

    @discardableResult
    private func sync(pair: String? = nil, over transport: LinkTransport? = nil, peer: LinkPeer? = nil) async throws -> LinkSessionOutcome {
        let phone = phone!
        let delegate = LinkComputerSync(endpointID: phone.endpointID, store: phone.store, deletions: phone.log) { phone.library() }
        let outcome = try await (transport ?? self.transport).sync(
            with: peer ?? machine.peer, phone: LinkPhone(id: "INSTALL", name: "Test iPhone", app: "1.0.3 (1)"),
            pairSecret: pair, delegate: delegate)
        phone.store.pruneDeletions(phone.log, libraryIDs: Set(phone.library().map(\.id)))
        return outcome
    }

    private func pairAndSync() async throws -> LinkSessionOutcome {
        try await sync(pair: computer.newPairingSecret())
    }

    private func assertFails(_ expected: (LinkSessionError) -> Bool, pair: String? = nil, peer: LinkPeer? = nil,
                             over transport: LinkTransport? = nil, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await sync(pair: pair, over: transport, peer: peer)
            XCTFail("expected the session to fail", file: file, line: line)
        } catch let error as LinkSessionError {
            XCTAssertTrue(expected(error), "\(error)", file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    // MARK: The round trip

    func testEndpointIDIsSixtyFourLowercaseHex() async throws {
        let id = try await transport.phoneEndpointID()
        XCTAssertEqual(id.count, 64)
        XCTAssertTrue(id.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertEqual(machine.id.count, 64)
        XCTAssertTrue(LinkTransport.isEndpointID(id))
        XCTAssertFalse(LinkTransport.isEndpointID("not-an-endpoint-id"))
        // The pairing link parser and iroh agree on what an endpoint id is.
        let link = try LinkPairingLink.parse("zone://pair?v=1&n=\(machine.id)&s=\(computer.newPairingSecret())&name=testbox")
        XCTAssertEqual(link.endpointID, machine.id)
    }

    func testPairingSendsEverythingInFramesAndTheComputerPinsThePhonesKey() async throws {
        phone.extraDictations = (0..<1_203).map { LinkFixtures.dictation($0) }
        phone.notes = [LinkFixtures.note(1), LinkFixtures.note(2)]
        phone.meetings = [LinkFixtures.meeting()]
        let before = await transport.isRunning
        XCTAssertFalse(before, "no endpoint before the first sync")

        let outcome = try await pairAndSync()

        XCTAssertEqual(outcome.delivered, 1_206)
        XCTAssertEqual(outcome.frames, 3)
        XCTAssertEqual(computer.frames.map(\.count), [500, 500, 206])
        XCTAssertEqual(computer.liveRows.count, 1_206)
        XCTAssertEqual(phone.delivery.delivered.count, 1_206)
        XCTAssertEqual(phone.delivery.computerID, computer.databaseID)
        let meeting = try XCTUnwrap(computer.rows[LinkFixtures.meeting().id.uuidString]?.item)
        XCTAssertTrue(meeting.text?.hasPrefix("Dana: Let us start with the launch.") == true)
        guard case .hello(let who, let pair)? = computer.hellos.first else { return XCTFail("no hello") }
        XCTAssertEqual(who.name, "Test iPhone")
        XCTAssertEqual(pair?.count, 64)
        let running = await transport.isRunning
        XCTAssertTrue(running)
    }

    func testASecondSessionSendsNothingNew() async throws {
        phone.dictate(1); phone.dictate(2)
        phone.notes = [LinkFixtures.note(1)]
        _ = try await pairAndSync()
        computer.clearFrames()

        let outcome = try await sync()

        XCTAssertEqual(outcome.delivered, 0)
        XCTAssertTrue(computer.frames.isEmpty)
        XCTAssertEqual(computer.sessions, 2)
        guard case .hello(_, let pair)? = computer.hellos.last else { return XCTFail("no hello") }
        XCTAssertNil(pair)
    }

    func testAChangedRecordIsSentAgain() async throws {
        let id = phone.dictate(1)
        phone.dictate(2)
        _ = try await pairAndSync()
        computer.clearFrames()

        phone.now = phone.now.addingTimeInterval(60)
        phone.history.mark(id: id, status: .inserted, now: phone.now)
        let outcome = try await sync()

        XCTAssertEqual(outcome.delivered, 1)
        XCTAssertEqual(computer.frames.flatMap { $0 }.map(\.id), [id.uuidString])
        XCTAssertEqual(computer.rows[id.uuidString]?.item.status, "inserted")
    }

    func testAnExplicitDeleteArrivesAsADeletion() async throws {
        let id = phone.dictate(1)
        phone.dictate(2)
        _ = try await pairAndSync()
        computer.clearFrames()

        phone.history.delete(id: id)
        let outcome = try await sync()

        XCTAssertEqual(outcome.deletions, 1)
        XCTAssertEqual(computer.frames.flatMap { $0 }.map(\.deleted), [true])
        XCTAssertEqual(computer.rows[id.uuidString]?.deleted, true)
        XCTAssertNil(computer.rows[id.uuidString]?.item.text)
        XCTAssertEqual(computer.liveRows.count, 1)
    }

    func testARetentionPurgeSendsNothing() async throws {
        // History keeps dictations until deleted by default, so choose thirty days, as a person can.
        phone.history.setRetention(.thirtyDays, now: phone.now)
        phone.dictate(1); phone.dictate(2)
        _ = try await pairAndSync()
        computer.clearFrames()

        phone.now = phone.now.addingTimeInterval(31 * 86_400)
        phone.history.purgeExpired(now: phone.now)
        XCTAssertTrue(phone.history.records(now: phone.now).isEmpty)
        let outcome = try await sync()

        XCTAssertEqual(outcome.delivered, 0)
        XCTAssertTrue(computer.frames.isEmpty)
        XCTAssertEqual(computer.liveRows.count, 2)
    }

    func testNotPairedIsRefused() async throws {
        phone.dictate(1)
        await assertFails { $0 == .refused("not_paired") }
        XCTAssertTrue(computer.frames.isEmpty)
        XCTAssertTrue(phone.delivery.delivered.isEmpty)

        // The computer pins the key, not the claim: a second phone with its own key is a
        // stranger even though the first one is paired.
        _ = try await pairAndSync()
        let stranger = LinkTransport(secrets: LinkMemorySecrets(), configuration: LinkTransportConfiguration(network: .isolated))
        await assertFails({ $0 == .refused("not_paired") }, over: stranger)
        await stranger.shutdown()
    }

    func testAUsedSecretIsRefused() async throws {
        let secret = computer.newPairingSecret()
        _ = try await sync(pair: secret)
        computer.forgetPhones()
        await assertFails({ $0 == .refused("bad_secret") }, pair: secret)
    }

    func testResendAllSendsEverythingAgain() async throws {
        phone.dictate(1); phone.dictate(2)
        phone.notes = [LinkFixtures.note(1)]
        _ = try await pairAndSync()
        computer.clearFrames()

        computer.askForEverythingOnce()
        let outcome = try await sync()

        XCTAssertTrue(outcome.resendAll)
        XCTAssertEqual(outcome.delivered, 3)
        XCTAssertEqual(computer.frames.flatMap { $0 }.count, 3)
    }

    func testANewDatabaseGetsEverythingAgain() async throws {
        phone.dictate(1); phone.dictate(2)
        _ = try await pairAndSync()
        computer.replaceDatabase()

        let outcome = try await sync()

        XCTAssertEqual(outcome.delivered, 2)
        XCTAssertEqual(computer.liveRows.count, 2)
    }

    // MARK: Failure, time and identity

    func testAnUnreachableComputerFailsCleanlyWithinTheTimeLimit() async throws {
        phone.dictate(1)
        let impatient = LinkTransport(secrets: secrets, configuration: LinkTransportConfiguration(network: .isolated, connectSeconds: 2))
        // A port nothing listens on, and a key nobody holds.
        let nobody = LinkPeer(endpointID: try SecretKey.generate().public().description, addresses: ["127.0.0.1:9"])
        let started = Date()
        await assertFails({ if case .unreachable = $0 { return true } else { return false } }, peer: nobody, over: impatient)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3.5, "two seconds to give up, not iroh's own longer wait")
        XCTAssertTrue(phone.delivery.delivered.isEmpty)
        XCTAssertTrue(phone.delivery.attempted.isEmpty, "nothing was put on the wire")

        // The same transport still works afterwards.
        let outcome = try await sync(pair: computer.newPairingSecret(), over: impatient)
        XCTAssertEqual(outcome.delivered, 1)
        await impatient.shutdown()
    }

    func testAnEndpointIDThatIsNotOneFailsBeforeAnyNetwork() async throws {
        await assertFails({ if case .unreachable = $0 { return true } else { return false } },
                          peer: LinkPeer(endpointID: "nonsense"))
        let running = await transport.isRunning
        XCTAssertFalse(running)
    }

    func testAComputerThatStopsAnsweringTimesOutAndTheItemsGoNextTime() async throws {
        _ = try await pairAndSync()
        phone.dictate(1)
        computer.goSilentAfterItems(true)
        let impatient = LinkTransport(secrets: secrets, configuration: LinkTransportConfiguration(network: .isolated, frameSeconds: 1))
        await assertFails({ $0 == .timedOut }, over: impatient)
        XCTAssertTrue(phone.delivery.delivered.isEmpty)

        computer.goSilentAfterItems(false)
        let outcome = try await sync(over: impatient)
        XCTAssertEqual(outcome.delivered, 1)
        await impatient.shutdown()
    }

    func testCancellingASyncEndsIt() async throws {
        _ = try await pairAndSync()
        phone.dictate(1)
        computer.goSilentAfterItems(true)
        let task = Task { try await self.sync() }
        try await Task.sleep(nanoseconds: 500_000_000)
        let started = Date()
        task.cancel()
        let result = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        guard case .failure(let error) = result else { return XCTFail("expected the sync to stop") }
        XCTAssertTrue(error is CancellationError, "\(error)")
    }

    func testThePhoneKeepsOneIdentityAndTheComputerSeesIt() async throws {
        let id = try await transport.phoneEndpointID()
        XCTAssertEqual(secrets.secret(LinkSecretName.phoneKey)?.count, 32)
        let again = LinkTransport(secrets: secrets, configuration: LinkTransportConfiguration(network: .isolated))
        let same = try await again.phoneEndpointID()
        XCTAssertEqual(same, id, "the key is read back, not made again")

        // Paired with one transport, recognized with another that has the same key.
        _ = try await pairAndSync()
        let outcome = try await sync(over: again)
        XCTAssertEqual(outcome.delivered, 0)
        await again.shutdown()
    }

    func testAKeyThatCannotBeSavedIsAnErrorNotANewIdentity() async throws {
        struct Locked: LinkSecretStore {
            func secret(_ name: String) -> Data? { nil }
            func setSecret(_ value: Data?, for name: String) -> Bool { false }
        }
        let locked = LinkTransport(secrets: Locked(), configuration: LinkTransportConfiguration(network: .isolated))
        do {
            _ = try await locked.phoneEndpointID()
            XCTFail("expected keyUnavailable")
        } catch {
            XCTAssertEqual(error as? LinkTransportError, .keyUnavailable)
        }
        do {
            try await sync(over: locked)
            XCTFail("expected keyUnavailable")
        } catch {
            XCTAssertEqual(error as? LinkTransportError, .keyUnavailable)
        }
        let running = await locked.isRunning
        XCTAssertFalse(running)
    }

    func testTheEndpointClosesWhenIdleAndReopensOnDemand() async throws {
        let brief = LinkTransport(secrets: secrets, configuration: LinkTransportConfiguration(network: .isolated, idleSeconds: 0.5))
        phone.dictate(1)
        _ = try await sync(pair: computer.newPairingSecret(), over: brief)
        var running = await brief.isRunning
        XCTAssertTrue(running, "kept for a moment so a second sync can reuse it")

        try await Task.sleep(nanoseconds: 1_500_000_000)
        running = await brief.isRunning
        XCTAssertFalse(running, "closed after sitting idle")

        phone.dictate(2)
        let outcome = try await sync(over: brief)
        XCTAssertEqual(outcome.delivered, 1)
        await brief.shutdown()
        running = await brief.isRunning
        XCTAssertFalse(running)
    }

    func testTwoSyncsAtOnceShareTheEndpoint() async throws {
        phone.extraDictations = (0..<300).map { LinkFixtures.dictation($0) }
        _ = try await pairAndSync()
        async let first = sync()
        async let second = sync()
        let outcomes = try await [first, second]
        XCTAssertEqual(outcomes.map(\.delivered), [0, 0])
        XCTAssertEqual(computer.liveRows.count, 300)
    }
}
