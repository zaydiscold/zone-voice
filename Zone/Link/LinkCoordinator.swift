// by zayd/cold @ zayd.wtf

import CryptoKit
import Foundation
import Observation
import UIKit
import ZoneCore
import ZoneLink

/// Zone Link in the app: the paired computers, when to send them the library, and what the
/// Computers screen shows.
///
/// Until a computer is paired this holds nothing: no observers, no deletion log, no key, no
/// iroh endpoint. After pairing it sends the library right away, then again a few seconds after
/// a dictation, note or meeting is saved or changed, whenever Zone comes to the foreground, and
/// on Sync now. Every send runs off the main thread, so a dictation's result never waits on it.
///
/// A clip (text the person sends to the computer on purpose) does not wait: `sendClip` queues it
/// and syncs at once with every computer whose sending is on. One the computer did not
/// acknowledge stays queued and goes first in the next sync.
///
/// Each computer has its own switch ("Send to this computer"). Off, nothing goes to it over the
/// network, for any reason; deletions are still written down, and its delivery state is kept,
/// so on again sends only what changed meanwhile. Which sync may reach which computer is
/// `PairedComputer.allowsSync` in ZoneCore.
@MainActor
@Observable
final class LinkCoordinator {
    typealias Reason = LinkSyncReason

    /// The one coordinator, for the Send to Computer shortcut, which runs outside any view.
    static private(set) weak var shared: LinkCoordinator?

    /// Clips waiting for a computer and the last few sent, newest first.
    private(set) var clips: [LinkClip] = []
    /// Paired computers, in pairing order.
    private(set) var computers: [PairedComputer] = []
    /// Endpoint ids with a sync running now.
    private(set) var syncing: Set<String> = []
    /// A pairing link waiting for an answer. Nothing is saved and nothing is sent until the
    /// person says yes: a link from a stranger would otherwise receive the whole library.
    private(set) var pendingPairing: LinkPairingLink?
    /// One sentence to show once: a bad link, or how pairing went.
    var notice: String?
    /// The computer whose Send by Flash screen is showing.
    var flashTarget: PairedComputer?
    /// Counts up whenever what a Flash would carry may have changed: the library, a deletion,
    /// a Link sync's deliveries, the clips. The Flash screen watches it to make its codes
    /// again while it is showing (`FlashSenderView`), not only when Zone comes back.
    private(set) var flashRevision = 0
    #if DEBUG
    /// `-zoneLinkComputers`: the Computers screen on its own, over whatever is showing.
    var debugShowsComputers = false
    #endif

    @ObservationIgnored private let store: LinkStore
    @ObservationIgnored private let deletions: LinkDeletionLog
    @ObservationIgnored private let secrets: LinkSecretStore
    @ObservationIgnored private let transport: LinkTransport
    @ObservationIgnored private let notes: NotesStore
    @ObservationIgnored private let meetings: MeetingCoordinator
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var debounceReason: Reason?
    @ObservationIgnored private var running: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var again: [String: Reason] = [:]
    /// Computers whose running sync Zone stopped itself, to start it again with a new plan.
    @ObservationIgnored private var restarting: Set<String> = []
    @ObservationIgnored private let background = LinkBackgroundTime()

    /// Long enough for the keyboard to mark a dictation inserted after the app saved it, so
    /// both land in one send.
    private static let changeDelay: Duration = .seconds(4)
    private static let foregroundDelay: Duration = .seconds(1)
    private static let installKey = "zone.link.installID"

    /// Where Zone Link keeps its files.
    nonisolated static func makeStore() -> LinkStore {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return LinkStore(directory: support.appendingPathComponent("Link", isDirectory: true), defaults: .standard)
    }

    init(notes: NotesStore, meetings: MeetingCoordinator) {
        self.notes = notes
        self.meetings = meetings
        store = Self.makeStore()
        deletions = LinkDeletionLog(fileURL: store.deletionLogURL)
        secrets = LinkKeychain()
        transport = LinkTransport(secrets: secrets)
        computers = store.computers()
        clips = computers.isEmpty ? [] : store.clips.all()
        background.onExpire = { [weak self] in self?.outOfBackgroundTime() }
        if !computers.isEmpty { attach() }
        Self.shared = self
    }

    var isPaired: Bool { !computers.isEmpty }

    /// True when at least one computer would be synced with on its own.
    private var anySyncsAutomatically: Bool { computers.contains(where: \.syncsAutomatically) }

    // MARK: Pairing

    private var inputDeadline: ContinuousClock.Instant?

    private var confirmDeadline: ContinuousClock.Instant?
    static let usedCodeKey = "zone.link.usedPairingCodeHashes"

    private func fingerprint(_ link: LinkPairingLink) -> String {
        Data(SHA256.hash(data: Data(link.secret.utf8))).base64EncodedString()
    }

    private func wasUsed(_ link: LinkPairingLink) -> Bool {
        UserDefaults.standard.stringArray(forKey: Self.usedCodeKey)?.contains(fingerprint(link)) == true
    }

    func beginPairingInput(now: ContinuousClock.Instant = .now) {
        declinePairing()
        inputDeadline = now + .seconds(300)
    }

    func endPairingInput() {
        inputDeadline = nil
        declinePairing()
    }

    func offerPairing(_ text: String, now: ContinuousClock.Instant = .now, wallTime: Date = Date()) {
        let deadline = inputDeadline
        inputDeadline = nil
        guard let deadline, now < deadline else {
            notice = "Tap Pair a computer or Paste link to start again."
            return
        }
        do {
            let link = try LinkPairingLink.parse(text)
            guard LinkTransport.isEndpointID(link.endpointID) else { throw LinkPairingLink.Failure.badEndpoint }
            guard !wasUsed(link) else {
                notice = "This code was already used. Get a new code on your computer."
                return
            }
            var effectiveDeadline = deadline
            if let expiry = link.expiresAt {
                let remaining = expiry.timeIntervalSince(wallTime)
                guard remaining > 0 else {
                    notice = "This code expired. Get a new code on your computer."
                    return
                }
                effectiveDeadline = min(deadline, now + .seconds(min(300, remaining)))
            }
            confirmDeadline = effectiveDeadline
            pendingPairing = link
        } catch LinkPairingLink.Failure.unsupportedVersion {
            notice = "This pairing link is from a newer Zone. Update Zone on this iPhone and try again."
        } catch LinkPairingLink.Failure.notAPairingLink {
            notice = "That is not a Zone pairing link."
        } catch {
            notice = "That pairing link is damaged. On your computer, choose Pair a phone again (or run zone pair)."
        }
    }

    func declinePairing() {
        pendingPairing = nil
    }

    /// The person said yes. Saves the computer and sends everything.
    func confirmPairing(now: ContinuousClock.Instant = .now, wallTime: Date = Date()) {
        guard let link = pendingPairing else { return }
        pendingPairing = nil
        guard let deadline = confirmDeadline, now < deadline, link.expiresAt.map({ wallTime < $0 }) ?? true, !wasUsed(link) else {
            notice = "Start pairing again with a new code from your computer."
            return
        }
        let id = link.endpointID
        guard secrets.setSecret(Data(link.secret.utf8), for: LinkSecretName.pairing(id)) else {
            notice = "Zone could not save the pairing code. Unlock this iPhone and try again."
            return
        }
        var used = UserDefaults.standard.stringArray(forKey: Self.usedCodeKey) ?? []
        used.append(fingerprint(link))
        UserDefaults.standard.set(used, forKey: Self.usedCodeKey)
        // Kept for Flash (sending by QR code with no network), which shares this pairing. It is
        // derived from the pairing secret and outlives it: the secret is dropped once the
        // computer accepts it over the network, and this key stays until the computer is
        // forgotten. A computer paired while the network was blocked has this key and nothing
        // else, which is enough: the computer takes a first flash sealed with it as the pairing.
        secrets.setSecret(link.flashKey, for: LinkSecretName.flash(id))
        if store.computer(id) != nil {
            // Pairing again keeps what this computer is known to hold.
            // Pairing again is the person answering Send, so it also turns sending back on.
            store.update(id) { computer in
                computer.pausedAt = nil
                computer.name = link.name
                computer.relay = link.relay
                computer.confirmed = false
                computer.needsPairing = false
                computer.lastError = nil
                computer.pairedAt = Date()
            }
        } else {
            store.add(PairedComputer(endpointID: id, name: link.name, relay: link.relay))
        }
        computers = store.computers()
        attach()
        sync(id, reason: .paired)
    }

    // MARK: The Computers screen

    func syncNow(_ endpointID: String) {
        sync(endpointID, reason: .manual)
    }

    /// Forgets what this computer was sent, so the next sync sends the whole library, and the
    /// next Everything flash starts from the first record.
    func sendEverythingAgain(_ endpointID: String) {
        // Off means nothing is sent; forgetting now would only be undone by nothing.
        guard store.computer(endpointID)?.isPaused == false else { return }
        store.forgetDeliveries(for: endpointID)
        computers = store.computers()
        flashRevision += 1
        sync(endpointID, reason: .manual)
    }

    /// The "Send to this computer" switch. Off cuts a running sync short (what was acknowledged
    /// stays delivered) and sends nothing more until it is on again. On sends what changed
    /// while it was off, deletions included, the way Zone coming to the foreground does.
    func setSending(_ on: Bool, to endpointID: String) {
        guard let computer = store.computer(endpointID), computer.isPaused == on else { return }
        let updated = store.setSending(on, to: endpointID)
        computers = store.computers()
        if on {
            if updated?.allowsSync(.foreground) == true { sync(endpointID, reason: .foreground) }
        } else {
            again[endpointID] = nil
            running[endpointID]?.cancel()
        }
    }

    /// The "Keep what I delete here" switch. On, this computer is never told about a delete
    /// made from now on, nor about one still waiting to be sent, so it keeps those copies for
    /// good. Off again, only deletes made after that are sent. A sync already running planned
    /// its deletions before the switch moved, so it is stopped and started again.
    func setKeepsDeleted(_ on: Bool, for endpointID: String) {
        guard let computer = store.computer(endpointID), computer.keepsDeleted != on else { return }
        store.setKeepsDeleted(on, for: endpointID, log: deletions)
        computers = store.computers()
        flashRevision += 1
        if on, let task = running[endpointID] {
            restarting.insert(endpointID)
            again[endpointID] = max(.foreground, again[endpointID] ?? .foreground)
            task.cancel()
        }
    }

    /// Stops sending to a computer. What it already holds stays there.
    func forget(_ endpointID: String) {
        running[endpointID]?.cancel()
        again[endpointID] = nil
        restarting.remove(endpointID)
        if flashTarget?.endpointID == endpointID { flashTarget = nil }
        store.remove(endpointID)
        secrets.setSecret(nil, for: LinkSecretName.pairing(endpointID))
        secrets.setSecret(nil, for: LinkSecretName.flash(endpointID))
        computers = store.computers()
        clips = store.clips.all()
        guard computers.isEmpty else { return }
        // The last one: back to holding nothing at all, the phone's own key included.
        detach()
        deletions.clear()
        store.clips.removeAll()
        clips = store.clips.all()
        secrets.setSecret(nil, for: LinkSecretName.phoneKey)
        let transport = transport
        Task.detached(priority: .utility) { await transport.shutdown() }
    }

    // MARK: Clips

    /// The computers a clip sent now would go to: every one whose sending is switched on.
    var clipTargets: [PairedComputer] { computers.filter { !$0.isPaused } }

    /// Endpoint ids to names, for what the Sent list says about each clip.
    var computerNames: [String: String] {
        Dictionary(computers.map { ($0.endpointID, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    /// Queues a piece of text for every computer whose sending is on and syncs with each of
    /// them at once, with no waiting. Returns as soon as it is saved in the outbox (nothing is
    /// on a computer yet: say "Sending", never "Sent"); `clipSettled` waits for each computer's
    /// answer. Throws `LinkClipFailure` for empty text, too much text, no computer to send to,
    /// or an outbox that could not be written (then nothing is queued or sent).
    @discardableResult
    func sendClip(_ text: String, source: LinkClipSource, to selected: String? = nil) throws -> LinkClip {
        let targets = clipTargets.map(\.endpointID).filter { selected == nil || $0 == selected }
        let clip = try store.clips.add(text, source: source, to: targets)
        clips = store.clips.all()
        flashRevision += 1
        for endpointID in targets { sync(endpointID, reason: .clip) }
        return clip
    }

    /// The clip once every sync that could carry it has ended, or after `seconds`: sent, or
    /// still waiting for a computer that could not be reached. Nil when it was removed
    /// meanwhile (a removed row, Delete everything): say `LinkClipCopy.removed`.
    func clipSettled(_ id: UUID, within seconds: TimeInterval) async -> LinkClip? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            guard let clip = store.clips.clip(id) else { return nil }
            let busy = clip.waiting.contains { running[$0] != nil || again[$0] != nil }
            if clip.isSent || !busy { return clip }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return store.clips.clip(id)
    }

    /// Takes a clip out of the list. Nothing is told to any computer.
    func removeClip(_ id: UUID) {
        store.clips.remove(id)
        clips = store.clips.all()
        flashRevision += 1
    }

    /// Delete everything: takes every clip off the phone, waiting ones and the Sent list. A
    /// running sync leaves a withdrawn clip out of every frame it has not written yet
    /// (`LinkComputerSync.stillToSend`). Nothing is told to any computer: one that already
    /// acknowledged a clip keeps it, and one that is mid-frame may still store it.
    @discardableResult
    func deleteAllClips() -> LinkClipRemoval {
        let removal = store.clips.removeAll()
        clips = store.clips.all()
        flashRevision += 1
        return removal
    }

    /// Clears the sent clips from the list. Waiting ones stay.
    func clearSentClips() {
        store.clips.removeSent()
        clips = store.clips.all()
        flashRevision += 1
    }

    // MARK: Flash

    /// What a Flash to one computer could carry.
    struct FlashCounts: Equatable, Sendable {
        /// Items this computer has not been sent yet, deletions included.
        var notYetSent: Int
        /// What Everything carries now: the whole library, plus the deletions this computer has
        /// not been told about, or what is left of them when earlier Everything flashes carried
        /// the first part (`PairedComputer.flashResume`).
        var everything: Int
        /// Everything from the first record, whatever earlier flashes carried.
        var everythingFromTheStart: Int

        /// True when Everything goes on from an earlier Everything flash.
        var everythingGoesOn: Bool { everything < everythingFromTheStart }
    }

    enum FlashFailure: Error, Equatable {
        /// The key made at pairing is gone or cannot be read (the phone has not been unlocked yet).
        case noKey
        case nothingToSend
        case tooLarge

        var plainMessage: String {
            switch self {
            case .noKey: return "Zone could not read the key it made when you paired this computer. Unlock this iPhone, or pair the computer again."
            case .nothingToSend: return "There is nothing to send."
            case .tooLarge: return "One item is too large to send by Flash."
            }
        }
    }

    /// How many items each choice would send. Reads the library off the main thread.
    func flashCounts(for endpointID: String) async -> FlashCounts {
        let store = store, deletions = deletions
        return await Task.detached(priority: .userInitiated) {
            // One read of the library and the log for all three.
            let library = LinkLibrary.read(), logged = deletions.all()
            func count(_ everything: Bool, fromTheStart: Bool = false) -> Int {
                store.flashItems(for: endpointID, everything: everything, library: library, deletions: logged,
                                 fromTheStart: fromTheStart).count
            }
            return FlashCounts(notYetSent: count(false), everything: count(true), everythingFromTheStart: count(true, fromTheStart: true))
        }.value
    }

    /// Seals the items for one computer and cuts them into frames. Nothing is marked as sent:
    /// a Flash goes one way, so only the person can say whether it arrived (`confirmFlash`).
    func flashPlan(for endpointID: String, everything: Bool, mode: LinkFlashMode = .color) async throws -> LinkFlashPlan {
        guard let key = secrets.secret(LinkSecretName.flash(endpointID)), key.count == 32 else { throw FlashFailure.noKey }
        let phone = phoneIdentity()
        let store = store, deletions = deletions
        var chunkBytes = mode.chunkBytes, rate = mode.framesPerSecond
        let codes = mode.codesPerPicture
        var pieces = LinkFlashFormat.planChunks
        #if DEBUG
        // `-zoneLinkFlashChunk 700 -zoneLinkFlashRate 20`: for measuring other sizes and speeds.
        // `-zoneLinkFlashPieces 8`: a smaller flash, so a small library is sent as several.
        let defaults = UserDefaults.standard
        if defaults.integer(forKey: "zoneLinkFlashChunk") > 0 { chunkBytes = defaults.integer(forKey: "zoneLinkFlashChunk") }
        if defaults.integer(forKey: "zoneLinkFlashRate") > 0 { rate = defaults.integer(forKey: "zoneLinkFlashRate") }
        if defaults.integer(forKey: "zoneLinkFlashPieces") > 0 { pieces = min(pieces, defaults.integer(forKey: "zoneLinkFlashPieces")) }
        #endif
        return try await Task.detached(priority: .userInitiated) { [chunkBytes, rate, codes, pieces] in
            let items = Self.flashItems(for: endpointID, everything: everything, store: store, deletions: deletions)
            do {
                return try LinkFlash.plan(items: items, phone: phone, key: key, chunkBytes: chunkBytes, maxChunks: pieces,
                                          framesPerSecond: rate, codesPerPicture: codes)
            } catch LinkFlash.Failure.nothingToSend {
                throw FlashFailure.nothingToSend
            } catch {
                throw FlashFailure.tooLarge
            }
        }.value
    }

    /// How a plan made earlier stands against the library now.
    enum FlashPlanState: Equatable, Sendable {
        /// The same choice would make the same plan.
        case same
        /// Nothing the plan carries has changed, but there is something new it does not carry.
        case current
        /// Something the plan carries was edited, deleted or taken back (`LinkFlashPlan.isCurrent`).
        case stale
    }

    func flashPlanState(_ plan: LinkFlashPlan, for endpointID: String, everything: Bool) async -> FlashPlanState {
        let store = store, deletions = deletions
        return await Task.detached(priority: .userInitiated) {
            let library = LinkLibrary.read()
            let sending = store.flashItems(for: endpointID, everything: everything, library: library, deletions: deletions.all())
            if plan.isMade(from: sending) { return .same }
            return plan.isCurrent(sending: sending, library: library) ? .current : .stale
        }.value
    }

    /// The person said the computer received the flash: its items now count as delivered, and
    /// an Everything flash moves where the next one goes on from.
    func confirmFlash(_ plan: LinkFlashPlan, everything: Bool, to endpointID: String) {
        guard store.computer(endpointID) != nil else { return }
        store.recordFlash(plan, everything: everything, to: endpointID)
        computers = store.computers()
        clips = store.clips.all()
        flashRevision += 1
        let store = store, deletions = deletions
        Task.detached(priority: .utility) {
            store.pruneDeletions(deletions, libraryIDs: Set(LinkLibrary.read().map(\.id)))
        }
    }

    /// The next Everything flash to this computer starts from the first record again.
    func restartFlashEverything(_ endpointID: String) {
        store.restartFlashEverything(for: endpointID)
        computers = store.computers()
        flashRevision += 1
    }

    nonisolated private static func flashItems(for endpointID: String, everything: Bool, store: LinkStore,
                                               deletions: LinkDeletionLog) -> [LinkItem] {
        store.flashItems(for: endpointID, everything: everything, library: LinkLibrary.read(), deletions: deletions.all())
    }

    // MARK: When to sync

    func scenePhaseChanged(active: Bool) {
        guard active, anySyncsAutomatically else { return }
        schedule(.foreground, after: Self.foregroundDelay)
    }

    private func libraryChanged() {
        // Before the check below: Flash is something the person starts, so it stays current
        // even for a computer whose sending is off.
        flashRevision += 1
        guard anySyncsAutomatically else { return }
        schedule(.changed, after: Self.changeDelay)
    }

    /// One timer for all computers. Each change restarts the wait, so a burst (a dictation
    /// saved, then marked inserted) is one send.
    private func schedule(_ reason: Reason, after delay: Duration) {
        let strongest = max(reason, debounceReason ?? reason)
        if debounce == nil { background.hold() }
        debounce?.cancel()
        debounceReason = strongest
        debounce = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.debounce = nil
            self.debounceReason = nil
            for endpointID in self.computers.due(for: strongest) {
                self.sync(endpointID, reason: strongest)
            }
            self.background.release()
        }
    }

    private func sync(_ endpointID: String, reason: Reason) {
        guard let computer = store.computer(endpointID), computer.allowsSync(reason) else { return }
        guard running[endpointID] == nil else {
            // One session per computer at a time. Whatever changed meanwhile goes in the next.
            again[endpointID] = max(reason, again[endpointID] ?? reason)
            return
        }
        syncing.insert(endpointID)
        background.hold()
        let phone = phoneIdentity()
        let store = store, deletions = deletions, secrets = secrets, transport = transport
        running[endpointID] = Task.detached(priority: .utility) { [weak self] in
            let result = await Self.run(computer: computer, reason: reason, phone: phone, store: store,
                                        deletions: deletions, secrets: secrets, transport: transport)
            await self?.finished(endpointID, reason: reason, result: result)
        }
    }

    private enum Ending: Sendable {
        /// Nothing was pending, so no connection was made.
        case nothingToSend
        case synced(LinkSessionOutcome)
        case failed(String, needsPairing: Bool)
        case cancelled
    }

    nonisolated private static func run(computer: PairedComputer, reason: Reason, phone: LinkPhone, store: LinkStore,
                                        deletions: LinkDeletionLog, secrets: LinkSecretStore,
                                        transport: LinkTransport) async -> Ending {
        var pairSecret: String?
        if !computer.confirmed {
            guard let data = secrets.secret(LinkSecretName.pairing(computer.endpointID)) else {
                return .failed(LinkSessionError.refused("bad_secret").plainMessage, needsPairing: true)
            }
            pairSecret = String(decoding: data, as: UTF8.self)
        } else if reason == .changed,
                  store.pendingCount(for: computer.endpointID, library: LinkLibrary.read(), deletions: deletions.all()) == 0 {
            return .nothingToSend
        }
        let delegate = LinkComputerSync(endpointID: computer.endpointID, store: store, deletions: deletions) { LinkLibrary.read() }
        do {
            let outcome = try await transport.sync(with: LinkPeer(endpointID: computer.endpointID, relay: computer.relay),
                                                   phone: phone, pairSecret: pairSecret, delegate: delegate)
            // The pairing secret has done its one job.
            secrets.setSecret(nil, for: LinkSecretName.pairing(computer.endpointID))
            store.pruneDeletions(deletions, libraryIDs: Set(LinkLibrary.read().map(\.id)))
            return .synced(outcome)
        } catch let error as LinkSessionError {
            if case .refused("bad_secret") = error { secrets.setSecret(nil, for: LinkSecretName.pairing(computer.endpointID)) }
            return .failed(error.plainMessage, needsPairing: error.needsPairing)
        } catch is CancellationError {
            return .cancelled
        } catch LinkTransportError.keyUnavailable {
            return .failed("Zone could not read its key. Unlock this iPhone and try again.", needsPairing: false)
        } catch {
            return .failed(LinkSessionError.unreachable("").plainMessage, needsPairing: false)
        }
    }

    private func finished(_ endpointID: String, reason: Reason, result: Ending) {
        running[endpointID] = nil
        syncing.remove(endpointID)
        let name = store.computer(endpointID)?.name ?? "the computer"
        switch result {
        case .nothingToSend:
            break
        case .synced(let outcome):
            store.update(endpointID) { computer in
                computer.lastSyncAt = Date()
                computer.needsPairing = false
                computer.lastError = outcome.tooLarge == 0 ? nil
                    : "\(outcome.tooLarge) \(outcome.tooLarge == 1 ? "item is" : "items are") too large to send."
            }
            if reason == .paired {
                notice = outcome.delivered == 0 ? "Paired with \(name). Nothing new to send."
                    : "Paired with \(name). Sent \(outcome.delivered.formatted()) \(outcome.delivered == 1 ? "item" : "items")."
            }
        case .failed(let message, let needsPairing):
            store.update(endpointID) { computer in
                computer.lastError = message
                computer.needsPairing = needsPairing
            }
            if reason == .paired {
                // The computer is saved either way. With no network between the two, Flash still works.
                notice = needsPairing ? message : "\(message) You can still send to \(name) with Flash, which needs no network."
            }
        case .cancelled:
            // Turning sending off is what cut it short when the computer is now off, and Zone
            // itself did when it is starting the sync again: neither is a problem.
            let expected = restarting.contains(endpointID)
            store.update(endpointID) { computer in
                computer.lastError = computer.isPaused || expected ? nil : "The last sync was cut short. Zone will finish it next time."
            }
        }
        restarting.remove(endpointID)
        computers = store.computers()
        clips = store.clips.all()
        // What it delivered is no longer "not sent yet", and a welcome may have forgotten all of it.
        if case .nothingToSend = result {} else { flashRevision += 1 }
        background.release()
        if let next = again.removeValue(forKey: endpointID), let computer = store.computer(endpointID),
           !computer.needsPairing, computer.allowsSync(next) {
            sync(endpointID, reason: next)
        }
    }

    /// iOS is about to suspend the app: stop the sessions cleanly. Acknowledged items stay
    /// delivered; the rest go next time.
    private func outOfBackgroundTime() {
        debounce?.cancel()
        debounce = nil
        debounceReason = nil
        for task in running.values { task.cancel() }
    }

    // MARK: Watching the library

    /// Starts watching for changes and deletions. Only called once a computer is paired.
    private func attach() {
        guard observers.isEmpty else { return }
        let deletions = deletions
        // Through the store, which spares the computers that keep what the person deletes.
        let store = store
        let record: @Sendable ([UUID], LinkKind, Date) -> Void = { [weak self] ids, kind, date in
            if !store.recordDeletion(ids, kind: kind, at: date, in: deletions) {
                Task { @MainActor in self?.notice = "Zone could not save the computer deletion requests. Unlock your iPhone and reopen Zone to try again." }
            }
        }
        TranscriptHistory.shared?.explicitDeletionSink = { ids, date in record(ids, .dictation, date) }
        notes.onDelete = { ids in record(ids, .note, Date()) }
        meetings.onDelete = { id in record([id], .meeting, Date()) }
        // No queue: the post returns at once and the hop to the main actor happens after, so a
        // store that posts while holding a lock never waits on the main thread.
        for name in [Notification.Name("ZoneLibraryDidChange"), MeetingStore.finishedMeetingDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in self?.libraryChanged() }
            })
        }
    }

    private func detach() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        TranscriptHistory.shared?.explicitDeletionSink = nil
        notes.onDelete = nil
        meetings.onDelete = nil
        debounce?.cancel()
        if debounce != nil { background.release() }
        debounce = nil
        debounceReason = nil
    }

    /// Who this phone says it is in `hello`. The computer trusts the connection's key, not this.
    private func phoneIdentity() -> LinkPhone {
        let defaults = UserDefaults.standard
        let install: String
        if let saved = defaults.string(forKey: Self.installKey) {
            install = saved
        } else {
            install = UUID().uuidString
            defaults.set(install, forKey: Self.installKey)
        }
        let info = Bundle.main.infoDictionary ?? [:]
        let app = "\(info["CFBundleShortVersionString"] as? String ?? "") (\(info["CFBundleVersion"] as? String ?? ""))"
        return LinkPhone(id: install, name: UIDevice.current.name, app: app)
    }
}

/// The library as Zone Link sends it, read from disk. Safe to call from any thread.
enum LinkLibrary {
    static func read() -> [LinkItem] {
        LinkEncoding.library(dictations: TranscriptHistory.shared?.records() ?? [],
                             notes: (try? LibraryNotesFile.read(at: NotesStore.fileURL)) ?? [],
                             meetings: MeetingStore.default.all())
    }
}

/// Asks iOS for time to finish when the app goes to the background, for as long as a sync is
/// waiting or running. Zone usually already runs there (its audio session while dictation is
/// armed); this covers the times it does not.
@MainActor
final class LinkBackgroundTime {
    var onExpire: (() -> Void)?
    private var holds = 0
    private var task: UIBackgroundTaskIdentifier = .invalid

    func hold() {
        holds += 1
        guard task == .invalid else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: "wtf.zayd.zone.link") { [weak self] in
            MainActor.assumeIsolated {
                self?.onExpire?()
                self?.holds = 0
                self?.end()
            }
        }
    }

    func release() {
        holds = max(0, holds - 1)
        if holds == 0 { end() }
    }

    private func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
