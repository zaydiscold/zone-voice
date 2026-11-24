// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// Taking clips off the phone (a removed row, Delete everything, forgetting the last computer)
/// and what the person is told about a send. All text here is synthetic.
///
/// What these pin down:
/// - A withdrawn clip is never sent afterwards: not by the next sync, not by a sync that had
///   already planned it, not after a relaunch, and not when the outbox file refuses the write.
/// - A clip is only "on its way" once it is on disk; an outbox that cannot be written refuses it.
/// - Nothing is ever sent to take a clip back: a computer that stored one keeps it, and the
///   wording never says otherwise.
final class LinkClipWithdrawalTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_794_600_000)
    private let otherID = "aa3c7996bad77424e96786cf7a7205115337a5b4565cd25506a0f297b191a5ea"
    private var directory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    /// Folders made read-only by a test, made writable again in tearDown so they can be removed.
    private var locked: [URL] = []

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("link-withdraw-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "zone-link-withdraw-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        for url in locked { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func lock(_ url: URL, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        locked.append(url)
    }

    private func unlock(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// Permission bits mean nothing to root; these tests need an ordinary user.
    private func requireOrdinaryUser() throws {
        try XCTSkipIf(getuid() == 0, "file permissions do not stop root")
    }

    /// One session with one computer, from any store and endpoint, optionally through a
    /// wrapped delegate and a stream that records the `seq` of every `items` frame.
    private func session(store: LinkStore, log: LinkDeletionLog, endpointID: String, computer: FakeComputer,
                         library: @escaping @Sendable () -> [LinkItem], pair: String? = nil,
                         recorder: SeqRecorder? = nil, frameTimeout: TimeInterval = 5,
                         wrap: ((LinkComputerSync) -> LinkSessionDelegate)? = nil) async throws -> LinkSessionOutcome {
        let (phoneEnd, computerEnd) = LinkMemoryStream.pair()
        let serving = Task { await computer.serve(computerEnd, peer: "phone-endpoint-id") }
        defer { phoneEnd.hangUp(); serving.cancel() }
        let inner = LinkComputerSync(endpointID: endpointID, store: store, deletions: log) { library() }
        return try await LinkSession.run(
            over: RecordingStream(inner: phoneEnd, recorder: recorder ?? SeqRecorder()),
            phone: LinkPhone(id: "INSTALL", name: "Test iPhone", app: "1.0.5 (1)"), pairSecret: pair,
            delegate: wrap?(inner) ?? inner, frameTimeout: frameTimeout, onStall: { phoneEnd.hangUp() })
    }

    private func sync(_ phone: LinkTestPhone, with computer: FakeComputer, endpointID: String? = nil,
                      store: LinkStore? = nil, pair: String? = nil, recorder: SeqRecorder? = nil,
                      frameTimeout: TimeInterval = 5,
                      wrap: ((LinkComputerSync) -> LinkSessionDelegate)? = nil) async throws -> LinkSessionOutcome {
        try await session(store: store ?? phone.store, log: phone.log, endpointID: endpointID ?? phone.endpointID,
                          computer: computer, library: { phone.library() }, pair: pair, recorder: recorder,
                          frameTimeout: frameTimeout, wrap: wrap)
    }

    private func clipFrames(_ computer: FakeComputer) -> [LinkItem] {
        computer.frames.flatMap { $0 }.filter { $0.kind == .clip }
    }

    // MARK: Queue, delete, retry

    func testDeleteEverythingWithdrawsAClipQueuedOfflineAndTheRetryNeverSendsIt() async throws {
        let phone = LinkTestPhone()
        let computer = FakeComputer()
        phone.dictate(1)
        _ = try await sync(phone, with: computer, pair: computer.newPairingSecret())
        computer.clearFrames()

        // Queued while the computer was unreachable: no session at all.
        let clip = try phone.store.clips.add("synthetic one-time code 000000", source: .shortcut,
                                             to: [phone.endpointID], at: at)
        XCTAssertEqual(phone.store.clips.pending(for: phone.endpointID).map(\.id), [clip.id.uuidString])

        let removal = phone.store.clips.removeAll()
        XCTAssertEqual(removal, LinkClipRemoval(withdrawn: 1, delivered: 0, erased: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: phone.store.clips.fileURL.path), "no clip text is left on disk")
        XCTAssertEqual(phone.store.clips.all(), [])
        XCTAssertFalse(phone.store.clips.hasPending(for: phone.endpointID))

        // The computer is back: the retry carries no clip.
        let outcome = try await sync(phone, with: computer)
        XCTAssertEqual(outcome.delivered, 0)
        XCTAssertEqual(clipFrames(computer), [])
        XCTAssertNil(computer.rows[clip.id.uuidString])
        XCTAssertEqual(phone.log.all(), [], "withdrawing a clip writes no deletion")
    }

    func testAClipAComputerStoredWithoutAcknowledgingStaysThereAndIsNotSentAgain() async throws {
        let phone = LinkTestPhone()
        let computer = FakeComputer()
        _ = try await sync(phone, with: computer, pair: computer.newPairingSecret())
        let clip = try phone.store.clips.add("synthetic note in flight", source: .typed, to: [phone.endpointID], at: at)

        // The frame went out and the computer stored it, but its ack never arrived.
        computer.goSilentAfterItems(true)
        do {
            _ = try await sync(phone, with: computer, frameTimeout: 0.3)
            XCTFail("the computer never acknowledged")
        } catch {}
        XCTAssertEqual(computer.rows[clip.id.uuidString]?.item.text, "synthetic note in flight",
                       "a written frame cannot be taken back")
        XCTAssertEqual(phone.store.clips.clip(clip.id)?.waiting, [phone.endpointID], "unacknowledged, so the phone still counts it waiting")

        let removal = phone.store.clips.removeAll()
        XCTAssertEqual(removal.withdrawn, 1)
        XCTAssertEqual(removal.delivered, 0, "the phone cannot know the computer stored it")

        computer.goSilentAfterItems(false)
        computer.clearFrames()
        let outcome = try await sync(phone, with: computer)
        XCTAssertEqual(outcome.delivered, 0)
        XCTAssertEqual(clipFrames(computer), [], "not sent again")
        XCTAssertEqual(computer.rows[clip.id.uuidString]?.deleted, false,
                       "and nothing tells the computer to delete it: the wording must not promise that")
    }

    func testALateAcknowledgmentAfterDeleteDoesNotBringTheClipBack() throws {
        let box = LinkClipOutbox(fileURL: directory.appendingPathComponent("clips.json"), defaults: defaults)
        let clip = try box.add("synthetic late ack", source: .typed, to: ["a", "b"], at: at)
        box.removeAll()
        box.acknowledge([clip.item], by: "a", at: at)
        XCTAssertEqual(box.all(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: box.fileURL.path))
    }

    // MARK: In flight

    func testAClipWithdrawnAfterTheSessionPlannedItIsLeftOutOfTheFrame() async throws {
        let phone = LinkTestPhone()
        let computer = FakeComputer()
        _ = try await sync(phone, with: computer, pair: computer.newPairingSecret())
        computer.clearFrames()
        phone.dictate(1)
        phone.dictate(2)
        let clip = try phone.store.clips.add("synthetic clip withdrawn mid-session", source: .clipboard,
                                             to: [phone.endpointID], at: at)
        let store = phone.store
        let planned = PlannedItems()
        let recorder = SeqRecorder()

        // Delete everything lands after `welcome` planned the clip, before its frame is written.
        let outcome = try await sync(phone, with: computer, recorder: recorder) { inner in
            WithdrawingDelegate(inner: inner, planned: planned) { _ = store.clips.removeAll() }
        }
        XCTAssertEqual(planned.items.first?.id, clip.id.uuidString, "the session had planned the clip")
        XCTAssertEqual(clipFrames(computer), [], "but it never went out")
        XCTAssertNil(computer.rows[clip.id.uuidString])
        XCTAssertEqual(outcome.delivered, 2, "the library still goes")
        XCTAssertEqual(computer.liveRows.count, 2)
        XCTAssertEqual(recorder.seqs, [1])
    }

    func testAFrameLeftEmptyByAWithdrawalIsSkippedAndTheRestAreNumberedWithoutAGap() async throws {
        let phone = LinkTestPhone()
        let computer = FakeComputer()
        _ = try await sync(phone, with: computer, pair: computer.newPairingSecret())
        computer.clearFrames()
        phone.dictate(1)
        // Five of the largest clips need two frames (1 MiB each): four in the first, then one
        // with the dictation.
        let big = String(repeating: "x", count: LinkClip.maxBytes)
        var clips: [LinkClip] = []
        for index in 0..<5 {
            clips.append(try phone.store.clips.add(big, source: .typed, to: [phone.endpointID],
                                                   at: at.addingTimeInterval(Double(index))))
        }
        let planned = LinkBatcher.plan(phone.store.pending(for: phone.endpointID, library: phone.library(), deletions: []))
        XCTAssertEqual(planned.batches.map { $0.items.count }, [4, 2], "the setup makes a clip-only first frame")

        let store = phone.store
        let recorder = SeqRecorder()
        let outcome = try await sync(phone, with: computer, recorder: recorder) { inner in
            WithdrawingDelegate(inner: inner, planned: PlannedItems()) { _ = store.clips.removeAll() }
        }
        XCTAssertEqual(recorder.seqs, [1], "the empty first frame is skipped and the next one is seq 1")
        XCTAssertEqual(outcome.frames, 1)
        XCTAssertEqual(outcome.delivered, 1)
        XCTAssertEqual(clipFrames(computer), [])
        XCTAssertEqual(computer.liveRows.map(\.item.kind), [.dictation])
    }

    func testOnlyClipsAreRecheckedSoAnUnchangedPlanGoesOutByteForByte() async throws {
        let phone = LinkTestPhone()
        let computer = FakeComputer()
        phone.dictate(1)
        let clip = try phone.store.clips.add("synthetic unchanged", source: .typed, to: [phone.endpointID], at: at)
        let recorder = SeqRecorder()
        let outcome = try await sync(phone, with: computer, pair: computer.newPairingSecret(), recorder: recorder)
        XCTAssertEqual(outcome.delivered, 2)
        XCTAssertEqual(recorder.seqs, [1])
        XCTAssertEqual(computer.rows[clip.id.uuidString]?.item.text, "synthetic unchanged")
        XCTAssertEqual(phone.store.clips.clip(clip.id)?.isSent, true)
    }

    // MARK: An outbox that cannot be written

    func testAnUnwritableOutboxRefusesTheClipInsteadOfQueueingNothing() throws {
        try requireOrdinaryUser()
        let folder = directory.appendingPathComponent("Link")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let box = LinkClipOutbox(fileURL: folder.appendingPathComponent("clips.json"), defaults: defaults)
        try lock(folder, 0o500)

        XCTAssertThrowsError(try box.add("synthetic never saved", source: .typed, to: ["a"], at: at)) {
            XCTAssertEqual($0 as? LinkClipFailure, .notSaved)
        }
        XCTAssertEqual(box.all(), [])
        XCTAssertEqual(box.pending(for: "a"), [])
        XCTAssertFalse(LinkClipFailure.notSaved.plainMessage.lowercased().contains("sent to"))
        XCTAssertTrue(LinkClipFailure.notSaved.plainMessage.contains("nothing was sent"))
    }

    func testDeleteEverythingOnAnUnwritableOutboxStillNeverSendsTheClipEvenAfterARelaunch() async throws {
        try requireOrdinaryUser()
        let phone = LinkTestPhone()
        let computer = FakeComputer()
        let store = LinkStore(directory: phone.store.directory, defaults: defaults)
        _ = try await sync(phone, with: computer, store: store, pair: computer.newPairingSecret())
        computer.clearFrames()
        let clip = try store.clips.add("synthetic stuck on disk", source: .shortcut, to: [phone.endpointID], at: at)

        // Neither the folder nor the file will take a change: the file can be neither removed
        // nor emptied.
        try lock(store.clips.fileURL, 0o400)
        try lock(store.directory, 0o500)
        let removal = store.clips.removeAll()
        XCTAssertEqual(removal, LinkClipRemoval(withdrawn: 1, delivered: 0, erased: false, failure: .notWritten))
        XCTAssertNotNil(LinkClipCopy.deletedEverything(removal), "the person is told the text is still on disk")
        XCTAssertTrue(defaults.bool(forKey: LinkClipOutbox.erasePendingKey), "the erase stays pending")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.clips.fileURL.path))
        XCTAssertEqual(store.clips.all(), [])
        XCTAssertEqual(store.pending(for: phone.endpointID, library: [], deletions: []), [])
        XCTAssertEqual(defaults.stringArray(forKey: LinkClipOutbox.withdrawnKey), [clip.id.uuidString],
                       "only the id is kept apart from the file, never the text")

        // A relaunch: a new store over the same folder and the same defaults.
        let relaunched = LinkStore(directory: store.directory, defaults: defaults)
        XCTAssertEqual(relaunched.clips.all(), [])
        let outcome = try await sync(phone, with: computer, store: relaunched)
        XCTAssertEqual(outcome.delivered, 0)
        XCTAssertEqual(clipFrames(computer), [])
        XCTAssertNil(computer.rows[clip.id.uuidString])

        // Once the folder takes writes again, the next change rewrites the file without the
        // withdrawn clip, and the id is no longer needed.
        try unlock(store.directory)
        try unlock(store.clips.fileURL)
        let next = try relaunched.clips.add("synthetic next", source: .typed, to: [phone.endpointID], at: at)
        let onDisk = try JSONDecoder().decode([LinkClip].self, from: Data(contentsOf: store.clips.fileURL))
        XCTAssertEqual(onDisk.map(\.id), [next.id])
        XCTAssertNil(defaults.stringArray(forKey: LinkClipOutbox.withdrawnKey))
        XCTAssertNil(defaults.object(forKey: LinkClipOutbox.erasePendingKey))
    }

    // MARK: An outbox that cannot be read, or is not a file

    /// Synthetic clips written straight to a private file, as an earlier launch would have.
    private func plant(_ texts: [String], waiting: [String] = ["a"], at url: URL) throws -> [LinkClip] {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let clips = texts.enumerated().map { index, text in
            LinkClip(text: text, source: .typed, createdAt: at.addingTimeInterval(Double(index)), waiting: waiting)
        }
        try JSONEncoder().encode(clips).write(to: url)
        return clips
    }

    func testDeleteEverythingOnAnUnreadableUnwritableOutboxHidesClipsWhoseIdsItNeverSawEvenAfterARelaunch() throws {
        try requireOrdinaryUser()
        let folder = directory.appendingPathComponent("Link")
        let url = folder.appendingPathComponent("clips.json")
        let planted = try plant(["synthetic unseen one", "synthetic unseen two"], at: url)
        let box = LinkClipOutbox(fileURL: url, defaults: defaults)
        try lock(url, 0o000)
        try lock(folder, 0o500)

        let removal = box.removeAll()
        XCTAssertEqual(removal, LinkClipRemoval(withdrawn: 0, delivered: 0, erased: false, known: false,
                                                failure: .notWritten))
        XCTAssertNil(defaults.stringArray(forKey: LinkClipOutbox.withdrawnKey), "no id could be read")
        XCTAssertTrue(defaults.bool(forKey: LinkClipOutbox.erasePendingKey))
        let line = try XCTUnwrap(LinkClipCopy.deletedEverything(removal))
        XCTAssertTrue(line.contains("neither read nor erase"))
        XCTAssertTrue(line.contains("already received stays there"))

        // The iPhone unlocks: the file reads again, in this process and after a relaunch.
        try unlock(url)
        XCTAssertEqual(box.all(), [], "same process")
        XCTAssertFalse(box.hasPending(for: "a"))
        let relaunched = LinkClipOutbox(fileURL: url, defaults: defaults)
        XCTAssertEqual(relaunched.all(), [], "relaunch")
        XCTAssertEqual(relaunched.pending(for: "a"), [])
        XCTAssertEqual(relaunched.waitingIDs(for: "a"), [])
        XCTAssertEqual(try JSONDecoder().decode([LinkClip].self, from: Data(contentsOf: url)).map(\.id),
                       planted.map(\.id), "the text is still on disk, as the person was told")

        // Nothing new joins it while the folder still refuses the erase.
        XCTAssertThrowsError(try relaunched.add("synthetic refused", source: .typed, to: ["a"], at: at)) {
            XCTAssertEqual($0 as? LinkClipFailure, .notSaved)
        }
        relaunched.acknowledge(planted.map(\.item), by: "a", at: at)
        XCTAssertEqual(relaunched.all(), [], "a late acknowledgment brings nothing back")

        // Once the folder takes writes, the next queue erases first and only then saves.
        try unlock(folder)
        let next = try relaunched.add("synthetic after erase", source: .typed, to: ["a"], at: at)
        XCTAssertEqual(try JSONDecoder().decode([LinkClip].self, from: Data(contentsOf: url)).map(\.id), [next.id])
        XCTAssertEqual(relaunched.all().map(\.id), [next.id])
        XCTAssertNil(defaults.object(forKey: LinkClipOutbox.erasePendingKey))
    }

    func testForgettingOneRecipientWhileLockedDoesNotReplayOnPairingAgain() throws {
        try requireOrdinaryUser()
        let url = directory.appendingPathComponent("Link/clips.json")
        let old = try plant(["synthetic shared clip"], waiting: ["a", "b"], at: url)[0]
        let box = LinkClipOutbox(fileURL: url, defaults: defaults)
        try lock(url, 0o000)
        defer { try? unlock(url) }
        box.forget("a", at: at)
        try unlock(url)
        let relaunched = LinkClipOutbox(fileURL: url, defaults: defaults)
        XCTAssertTrue(relaunched.pending(for: "a").isEmpty)
        XCTAssertEqual(relaunched.waitingIDs(for: "b"), [old.id.uuidString])
        let fresh = try relaunched.add("new explicit send", source: .typed, to: ["a"])
        let reopened = LinkClipOutbox(fileURL: url, defaults: defaults)
        XCTAssertEqual(reopened.waitingIDs(for: "a"), [fresh.id.uuidString])
        XCTAssertEqual(reopened.waitingIDs(for: "b"), [old.id.uuidString])
    }

    func testDeleteEverythingUnlinksAnUnreadableFileAndSaysWhatItCannotKnow() throws {
        try requireOrdinaryUser()
        let url = directory.appendingPathComponent("Link/clips.json")
        _ = try plant(["synthetic locked file"], at: url)
        let box = LinkClipOutbox(fileURL: url, defaults: defaults)
        try lock(url, 0o000)

        let removal = box.removeAll()
        XCTAssertEqual(removal, LinkClipRemoval(withdrawn: 0, delivered: 0, erased: true, known: false,
                                                failure: .unreadable))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(defaults.object(forKey: LinkClipOutbox.erasePendingKey))
        let line = try XCTUnwrap(LinkClipCopy.deletedEverything(removal), "unknown counts are not silent")
        XCTAssertTrue(line.contains("can't tell"))
        XCTAssertNoThrow(try box.add("synthetic fresh", source: .typed, to: ["a"], at: at))
    }

    func testAFolderThatCannotBeLookedIntoIsNeverReportedErased() throws {
        try requireOrdinaryUser()
        let folder = directory.appendingPathComponent("Link")
        let url = folder.appendingPathComponent("clips.json")
        _ = try plant(["synthetic behind a closed folder"], at: url)
        let box = LinkClipOutbox(fileURL: url, defaults: defaults)
        try lock(folder, 0o000)

        let removal = box.removeAll()
        XCTAssertFalse(removal.erased, "access denied is not proof the file is gone")
        XCTAssertFalse(removal.known)
        XCTAssertEqual(removal.failure, .unreadable)

        try unlock(folder)
        XCTAssertEqual(LinkClipOutbox(fileURL: url, defaults: defaults).all(), [], "relaunch")
        XCTAssertEqual(box.all(), [])
        XCTAssertEqual(box.removeAll(), LinkClipRemoval(withdrawn: 0, delivered: 0, erased: true),
                       "the retry erases it; its clips were counted by the first try")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRemovingOneRowFromAnUnreadableOutboxWithdrawsItWithoutTouchingTheOthers() throws {
        try requireOrdinaryUser()
        let url = directory.appendingPathComponent("Link/clips.json")
        let planted = try plant(["synthetic row to remove", "synthetic row to keep"], at: url)
        let box = LinkClipOutbox(fileURL: url, defaults: defaults)
        let before = try Data(contentsOf: url)
        try lock(url, 0o000)

        XCTAssertEqual(box.remove(planted[0].id), .unreadable)
        XCTAssertEqual(box.removeSent(), .unreadable, "which clips were sent is unknown, so none is dropped")
        try unlock(url)
        XCTAssertEqual(try Data(contentsOf: url), before, "an unreadable file is never overwritten")
        XCTAssertEqual(box.all().map(\.id), [planted[1].id])
        XCTAssertEqual(LinkClipOutbox(fileURL: url, defaults: defaults).pending(for: "a").map(\.id),
                       [planted[1].id.uuidString], "after a relaunch too")
    }

    func testAMalformedOutboxIsNeverOverwrittenByANewClip() throws {
        let url = directory.appendingPathComponent("Link/clips.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = Data("{\"synthetic\": not a clip list".utf8)
        try garbage.write(to: url)
        let box = LinkClipOutbox(fileURL: url, defaults: defaults)

        XCTAssertThrowsError(try box.add("synthetic must not replace it", source: .typed, to: ["a"], at: at)) {
            XCTAssertEqual($0 as? LinkClipFailure, .notSaved)
        }
        XCTAssertEqual(box.removeSent(), .malformed)
        XCTAssertEqual(try Data(contentsOf: url), garbage)
        XCTAssertEqual(box.all(), [])

        // Delete everything is the way out, and is honest that it could not count.
        let removal = box.removeAll()
        XCTAssertEqual(removal, LinkClipRemoval(withdrawn: 0, delivered: 0, erased: true, known: false,
                                                failure: .malformed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNoThrow(try box.add("synthetic after the garbage", source: .typed, to: ["a"], at: at))
    }

    func testALinkWhereTheOutboxBelongsIsNeitherFollowedNorErased() throws {
        let folder = directory.appendingPathComponent("Link")
        let url = folder.appendingPathComponent("clips.json")
        // A private synthetic target outside the outbox folder, holding a valid clip list.
        let target = directory.appendingPathComponent("elsewhere/target.json")
        let planted = try plant(["synthetic behind a link"], at: target)
        let targetBytes = try Data(contentsOf: target)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        let box = LinkClipOutbox(fileURL: url, defaults: defaults)

        XCTAssertEqual(box.all(), [], "the link is not followed")
        XCTAssertEqual(box.pending(for: "a"), [])
        XCTAssertThrowsError(try box.add("synthetic not through a link", source: .typed, to: ["a"], at: at))
        XCTAssertEqual(box.remove(planted[0].id), .notAFile)

        let removal = box.removeAll()
        XCTAssertEqual(removal, LinkClipRemoval(withdrawn: 0, delivered: 0, erased: false, known: false,
                                                failure: .notAFile))
        XCTAssertEqual(try Data(contentsOf: target), targetBytes, "the target is neither emptied nor replaced")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: url.path), target.path)
        XCTAssertEqual(LinkClipOutbox(fileURL: url, defaults: defaults).all(), [], "relaunch")
    }

    func testAFolderWhereTheOutboxBelongsIsNeverRemoved() throws {
        let url = directory.appendingPathComponent("Link/clips.json")
        let inside = url.appendingPathComponent("synthetic.txt")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: inside)
        let box = LinkClipOutbox(fileURL: url, defaults: defaults)

        XCTAssertEqual(box.all(), [])
        XCTAssertThrowsError(try box.add("synthetic not over a folder", source: .typed, to: ["a"], at: at))
        let removal = box.removeAll()
        XCTAssertFalse(removal.erased)
        XCTAssertEqual(removal.failure, .notAFile)
        XCTAssertEqual(try Data(contentsOf: inside), Data("synthetic".utf8), "the folder and what is in it stay")
    }

    func testAFolderThatKeepsTheFileStillLetsDeleteEverythingEmptyIt() throws {
        try requireOrdinaryUser()
        let folder = directory.appendingPathComponent("Link")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let box = LinkClipOutbox(fileURL: folder.appendingPathComponent("clips.json"), defaults: defaults)
        try box.add("synthetic emptied in place", source: .typed, to: ["a"], at: at)
        try lock(folder, 0o500)

        let removal = box.removeAll()
        XCTAssertEqual(removal, LinkClipRemoval(withdrawn: 1, delivered: 0, erased: true))
        XCTAssertEqual(try Data(contentsOf: box.fileURL).count, 0, "no clip text is left in the file")
        XCTAssertEqual(box.all(), [])
        XCTAssertNil(defaults.stringArray(forKey: LinkClipOutbox.withdrawnKey))
    }

    func testRemovingOneRowFromAnUnwritableOutboxStillWithdrawsIt() throws {
        try requireOrdinaryUser()
        let folder = directory.appendingPathComponent("Link")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let box = LinkClipOutbox(fileURL: folder.appendingPathComponent("clips.json"), defaults: defaults)
        let gone = try box.add("synthetic removed row", source: .typed, to: ["a"], at: at)
        let kept = try box.add("synthetic kept row", source: .typed, to: ["a"], at: at.addingTimeInterval(1))
        try lock(box.fileURL, 0o400)
        try lock(folder, 0o500)

        box.remove(gone.id)
        XCTAssertEqual(box.all().map(\.id), [kept.id])
        XCTAssertEqual(box.pending(for: "a").map(\.id), [kept.id.uuidString])
        XCTAssertEqual(LinkClipOutbox(fileURL: box.fileURL, defaults: defaults).all().map(\.id), [kept.id],
                       "after a relaunch too")
    }

    func testForgettingTheLastComputerWithdrawsEveryClip() throws {
        let store = LinkStore(directory: directory.appendingPathComponent("Link"), defaults: defaults)
        store.add(PairedComputer(endpointID: "a", name: "Studio Mac"))
        try store.clips.add("synthetic for a", source: .typed, to: ["a"], at: at)
        store.clips.clear()
        XCTAssertEqual(store.clips.all(), [])
        XCTAssertFalse(store.clips.hasPending(for: "a"))
    }

    // MARK: One computer online, one offline

    func testMixedAcknowledgmentsSayWhichComputerHasItAndDeleteNeverReachesBackForIt() async throws {
        let phone = LinkTestPhone()
        let online = FakeComputer(name: "Studio Mac")
        phone.store.update(phone.endpointID) { $0.name = "Studio Mac" }
        phone.store.add(PairedComputer(endpointID: otherID, name: "ThinkPad"))
        let names = [phone.endpointID: "Studio Mac", otherID: "ThinkPad"]
        _ = try await sync(phone, with: online, pair: online.newPairingSecret())
        online.clearFrames()

        let clip = try phone.store.clips.add("synthetic for both", source: .clipboard,
                                             to: [phone.endpointID, otherID], at: at)
        // Saved, nobody has answered: never "Sent".
        XCTAssertEqual(LinkClipCopy.sending, "Sending…")
        XCTAssertFalse(LinkClipCopy.sending.contains("Sent"))

        // Studio Mac acknowledges; ThinkPad is offline (its sync fails before welcome).
        _ = try await sync(phone, with: online)
        let offline = FakeComputer(name: "ThinkPad")
        offline.refuseEverything("busy")
        do {
            _ = try await sync(phone, with: offline, endpointID: otherID)
            XCTFail("ThinkPad refused")
        } catch {}

        let settled = try XCTUnwrap(phone.store.clips.clip(clip.id))
        XCTAssertEqual(settled.sentTo, [phone.endpointID])
        XCTAssertEqual(settled.waiting, [otherID])
        XCTAssertEqual(LinkClipCopy.outcome(settled, names: names),
                       "Sent to Studio Mac. Zone could not reach ThinkPad just now. It is saved and goes with the next sync.")
        XCTAssertEqual(LinkClipCopy.status(settled, names: names), "Sent to Studio Mac. Waiting for ThinkPad")
        XCTAssertEqual(settled.text, "synthetic for both", "the whole text stays while a computer waits")

        // Delete everything: ThinkPad never gets it, Studio Mac keeps its copy.
        XCTAssertEqual(LinkClipCopy.deleteEverythingNote(waiting: 1, delivered: 1),
                       "Cancels the waiting send. A copy already on its way can still arrive. Text your computer already received stays there.")
        let removal = phone.store.clips.removeAll()
        XCTAssertEqual(removal, LinkClipRemoval(withdrawn: 1, delivered: 1, erased: true))
        XCTAssertNil(LinkClipCopy.deletedEverything(removal))

        offline.refuseEverything(nil)
        _ = try await sync(phone, with: offline, endpointID: otherID, pair: offline.newPairingSecret())
        XCTAssertEqual(clipFrames(offline), [], "the offline computer never receives it")
        _ = try await sync(phone, with: online)
        XCTAssertEqual(online.rows[clip.id.uuidString]?.deleted, false, "the online one keeps its copy")
        XCTAssertEqual(phone.log.all(), [])
    }

    // MARK: Wording

    func testTheWordingNeverClaimsAComputerLostItsCopy() {
        let lines = [LinkClipCopy.removed, LinkClipCopy.sending,
                     LinkClipCopy.deleteEverythingNote(waiting: 3, delivered: 2) ?? "",
                     LinkClipCopy.deleteEverythingNote(waiting: 1, delivered: 0) ?? "",
                     LinkClipCopy.deletedEverything(LinkClipRemoval(withdrawn: 1, delivered: 0, erased: false)) ?? "",
                     LinkClipCopy.deletedEverything(LinkClipRemoval(withdrawn: 0, delivered: 0, erased: true,
                                                                    known: false, failure: .unreadable)) ?? "",
                     LinkClipCopy.deletedEverything(LinkClipRemoval(withdrawn: 0, delivered: 0, erased: false,
                                                                    known: false, failure: .unreadable)) ?? "",
                     LinkClipFailure.notSaved.plainMessage]
        for line in lines {
            XCTAssertFalse(line.isEmpty)
            XCTAssertFalse(line.contains("\u{2014}"), "no em dash: \(line)")
            for claim in ["deleted from your computer", "removed from your computer", "erased from your computer",
                          "deletes it on", "takes it back"] {
                XCTAssertFalse(line.lowercased().contains(claim), "\(line) claims \(claim)")
            }
        }
        XCTAssertEqual(LinkClipCopy.deleteEverythingNote(waiting: 3, delivered: 0),
                       "Cancels 3 waiting sends. A copy already on its way can still arrive.")
        XCTAssertEqual(LinkClipCopy.deleteEverythingNote(waiting: 0, delivered: 2),
                       "Text your computer already received stays there.")
        XCTAssertNil(LinkClipCopy.deleteEverythingNote(waiting: 0, delivered: 0))
        XCTAssertTrue(LinkClipCopy.removed.contains("keeps its copy"))
    }
}

// MARK: Test doubles

/// The `seq` of every `items` frame the phone wrote, in order.
final class SeqRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _seqs: [Int] = []
    var seqs: [Int] { lock.lock(); defer { lock.unlock() }; return _seqs }
    func record(_ seq: Int) { lock.lock(); _seqs.append(seq); lock.unlock() }
}

/// The phone's end of a connection that notes each `items` frame it writes. Every write is
/// one whole frame (`LinkSession`).
struct RecordingStream: LinkByteStream {
    let inner: LinkMemoryStream
    let recorder: SeqRecorder

    func write(_ data: Data) async throws {
        if data.count > LinkFrame.headerBytes,
           case .items(let seq, _)? = try? LinkMessage.decode(Data(data.dropFirst(LinkFrame.headerBytes))) {
            recorder.record(seq)
        }
        try await inner.write(data)
    }

    func read(exactly count: Int) async throws -> Data { try await inner.read(exactly: count) }
    func finishWriting() async throws { try await inner.finishWriting() }
}

final class PlannedItems: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [LinkItem] = []
    var items: [LinkItem] {
        get { lock.lock(); defer { lock.unlock() }; return _items }
        set { lock.lock(); _items = newValue; lock.unlock() }
    }
}

/// The app's delegate, with something happening on the phone after `welcome` planned the
/// session and before its first frame is written: the window Delete everything can land in.
final class WithdrawingDelegate: LinkSessionDelegate, @unchecked Sendable {
    let inner: LinkComputerSync
    let planned: PlannedItems
    let afterPlan: @Sendable () -> Void

    init(inner: LinkComputerSync, planned: PlannedItems, afterPlan: @escaping @Sendable () -> Void) {
        self.inner = inner
        self.planned = planned
        self.afterPlan = afterPlan
    }

    func welcomed(by computer: LinkComputer, itemsOnComputer: Int?, resendAll: Bool) async -> [LinkItem] {
        let items = await inner.welcomed(by: computer, itemsOnComputer: itemsOnComputer, resendAll: resendAll)
        planned.items = items
        afterPlan()
        return items
    }

    func stillToSend(_ items: [LinkItem]) async -> [LinkItem] { await inner.stillToSend(items) }
    func willSend(_ items: [LinkItem]) async { await inner.willSend(items) }
    func acknowledged(_ items: [LinkItem]) async { await inner.acknowledged(items) }
}
