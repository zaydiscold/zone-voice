// by zayd/cold @ zayd.wtf

import Foundation

/// A computer this phone sends its library to.
public struct PairedComputer: Codable, Equatable, Identifiable, Sendable {
    /// The computer's iroh endpoint id. This is who the phone dials, and the key iroh checks.
    public var endpointID: String
    public var name: String
    public var relay: String?
    /// The computer's database UUID, from its last `welcome`.
    public var computerID: String?
    public var os: String?
    public var version: String?
    public var pairedAt: Date
    /// False until the computer has accepted the pairing secret.
    public var confirmed: Bool
    /// The last sync that ended with every frame acknowledged.
    public var lastSyncAt: Date?
    /// The last Flash the person said the computer received.
    public var lastFlashAt: Date?
    /// Items this computer acknowledged since pairing. A resent item counts again; a deletion does not count.
    public var itemsSent: Int
    /// Items the computer said it holds, from its last `welcome`.
    public var itemsOnComputer: Int?
    /// Why the last attempt failed, in plain words. Nil after a good sync.
    public var lastError: String?
    /// The computer refused this phone (it forgot it, or the pairing code was no good). Zone
    /// stops trying on its own until the person pairs again or taps Sync now.
    public var needsPairing: Bool
    /// When the person turned off sending to this computer. Nil means on, which is also what
    /// a computer saved before this switch existed reads as. While off, nothing is sent over
    /// the network; what the computer was sent is kept, so turning it back on sends only what
    /// changed meanwhile, deletions included.
    public var pausedAt: Date?
    /// When the person turned on "Keep what I delete here" for this computer. Nil means off,
    /// which is also what a computer saved before this switch existed reads as. While on, a
    /// delete on the phone is never sent to this computer, so it keeps its copy; which
    /// deletions are spared is written on each one (`LinkDeletion.keptBy`), so turning this off
    /// later does not send them after all.
    public var keepsDeletedSince: Date?
    /// Where the next Everything flash goes on from, when the library is larger than one flash:
    /// after the last record the previous Everything flash carried and the person confirmed.
    /// Nil starts from the first record, which is also what a computer saved before this
    /// existed reads as (`LinkStore.flashItems`).
    public var flashResume: LinkFlashResume?

    public var id: String { endpointID }

    public var isPaused: Bool { pausedAt != nil }

    /// True while this computer keeps its copy of what the person deletes on the phone.
    public var keepsDeleted: Bool { keepsDeletedSince != nil }

    public init(endpointID: String, name: String, relay: String? = nil, pairedAt: Date = Date()) {
        self.endpointID = endpointID
        self.name = name
        self.relay = relay
        self.pairedAt = pairedAt
        self.confirmed = false
        self.itemsSent = 0
        self.needsPairing = false
    }
}

/// Where secrets go. The app keeps them in the Keychain; tests keep them in memory.
public protocol LinkSecretStore: Sendable {
    func secret(_ name: String) -> Data?
    /// Nil removes it. Returns false when the secret could not be saved.
    @discardableResult func setSecret(_ value: Data?, for name: String) -> Bool
}

public enum LinkSecretName {
    /// The phone's own iroh secret key: its identity to every paired computer.
    public static let phoneKey = "phone-key"
    /// The one-use pairing secret, kept only until the computer accepts it.
    public static func pairing(_ endpointID: String) -> String { "pair." + endpointID }
    /// The key for Flash (protocol carrier 2), derived from the pairing secret and kept.
    public static func flash(_ endpointID: String) -> String { "flash." + endpointID }
}

public final class LinkMemorySecrets: LinkSecretStore, @unchecked Sendable {
    private var values: [String: Data] = [:]
    private let lock = NSLock()
    public init() {}
    public func secret(_ name: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return values[name]
    }
    @discardableResult public func setSecret(_ value: Data?, for name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        values[name] = value
        return true
    }
}

/// The paired computers and, for each, what it has been sent. Files in one folder:
/// `computers.json` and one `delivery-<endpoint id>.json` per computer. No secrets live here.
public final class LinkStore: @unchecked Sendable {
    public let directory: URL
    /// Text the person sent on purpose, waiting for its computers (`LinkClip`).
    public let clips: LinkClipOutbox
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
        self.clips = LinkClipOutbox(fileURL: directory.appendingPathComponent("clips.json"))
    }

    /// The record of what the person deleted on purpose, beside the rest.
    public var deletionLogURL: URL { directory.appendingPathComponent("deletions.json") }

    private var computersURL: URL { directory.appendingPathComponent("computers.json") }

    private func deliveryURL(_ endpointID: String) -> URL {
        directory.appendingPathComponent("delivery-\(endpointID).json")
    }

    // MARK: Computers

    public func computers() -> [PairedComputer] {
        lock.lock(); defer { lock.unlock() }
        return readComputers()
    }

    public func computer(_ endpointID: String) -> PairedComputer? {
        computers().first { $0.endpointID == endpointID }
    }

    /// Adds a computer, or replaces the one with the same endpoint id (pairing again).
    public func add(_ computer: PairedComputer) {
        lock.lock(); defer { lock.unlock() }
        var all = readComputers()
        all.removeAll { $0.endpointID == computer.endpointID }
        all.append(computer)
        writeComputers(all)
    }

    @discardableResult
    public func update(_ endpointID: String, _ change: (inout PairedComputer) -> Void) -> PairedComputer? {
        lock.lock(); defer { lock.unlock() }
        var all = readComputers()
        guard let index = all.firstIndex(where: { $0.endpointID == endpointID }) else { return nil }
        change(&all[index])
        writeComputers(all)
        return all[index]
    }

    /// Turns sending to a computer on or off. Off keeps its delivery state untouched.
    @discardableResult
    public func setSending(_ on: Bool, to endpointID: String, at date: Date = Date()) -> PairedComputer? {
        update(endpointID) { computer in
            if on {
                computer.pausedAt = nil
            } else if computer.pausedAt == nil {
                computer.pausedAt = date
            }
        }
    }

    /// The "Keep what I delete here" switch. On, every deletion still waiting in `log` is
    /// spared for this computer for good, and so is every one recorded while it stays on
    /// (`recordDeletion`). Off changes nothing that was spared: only later deletes are sent.
    @discardableResult
    public func setKeepsDeleted(_ on: Bool, for endpointID: String, log: LinkDeletionLog, at date: Date = Date()) -> PairedComputer? {
        let updated = update(endpointID) { computer in
            if !on {
                computer.keepsDeletedSince = nil
            } else if computer.keepsDeletedSince == nil {
                computer.keepsDeletedSince = date
            }
        }
        if on, updated != nil { log.spare(endpointID) }
        return updated
    }

    /// Writes down records the person deleted on purpose, sparing the computers that keep
    /// their copies at this moment.
    public func recordDeletion(_ ids: [UUID], kind: LinkKind, at date: Date = Date(), in log: LinkDeletionLog) {
        log.record(ids, kind: kind, at: date, keptBy: computers().filter(\.keepsDeleted).map(\.endpointID))
    }

    /// The deletions one computer is still to be told about: none while it keeps what the
    /// person deletes, and never one it was spared.
    public func deletions(for endpointID: String, from all: [LinkDeletion]) -> [LinkDeletion] {
        guard computer(endpointID)?.keepsDeleted != true else { return [] }
        return all.filter { !$0.isKept(by: endpointID) }
    }

    /// What to send one computer now: the clips waiting for it first, so they never wait
    /// behind a long library, then `LinkDeliveryState.pending` without the deletions it is spared.
    public func pending(for endpointID: String, library: [LinkItem], deletions all: [LinkDeletion]) -> [LinkItem] {
        clips.pending(for: endpointID)
            + delivery(for: endpointID).pending(library: library, deletions: deletions(for: endpointID, from: all))
    }

    /// A computer has these items for certain: an acknowledged Link frame, or a Flash the
    /// person said arrived. Library items count as delivered and clips stop waiting for it.
    /// Returns how many library items the computer was given to keep.
    @discardableResult
    public func acknowledge(_ items: [LinkItem], by endpointID: String, at date: Date = Date()) -> Int {
        updateDelivery(for: endpointID) { $0.acknowledge(items) }
        clips.acknowledge(items, by: endpointID, at: date)
        // "Items sent" counts what the computer was given to keep from the library, not what
        // it was told to delete and not clips.
        return items.filter { !$0.deleted && $0.kind != .clip }.count
    }

    /// Forgets a computer and everything remembered about what it holds.
    public func remove(_ endpointID: String) {
        lock.lock(); defer { lock.unlock() }
        var all = readComputers()
        all.removeAll { $0.endpointID == endpointID }
        writeComputers(all)
        try? FileManager.default.removeItem(at: deliveryURL(endpointID))
        clips.forget(endpointID)
    }

    // MARK: Delivery state

    public func delivery(for endpointID: String) -> LinkDeliveryState {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: deliveryURL(endpointID)),
              let state = try? JSONDecoder().decode(LinkDeliveryState.self, from: data) else { return LinkDeliveryState() }
        return state
    }

    /// Changes one computer's delivery state in a single step. A computer that has been
    /// forgotten keeps nothing: a session still finishing for it cannot bring its file back.
    @discardableResult
    public func updateDelivery<T>(for endpointID: String, _ change: (inout LinkDeliveryState) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        var state = LinkDeliveryState()
        if let data = try? Data(contentsOf: deliveryURL(endpointID)),
           let saved = try? JSONDecoder().decode(LinkDeliveryState.self, from: data) {
            state = saved
        }
        let result = change(&state)
        if readComputers().contains(where: { $0.endpointID == endpointID }) {
            write(state, to: deliveryURL(endpointID))
        }
        return result
    }

    // MARK: Files

    private func readComputers() -> [PairedComputer] {
        guard let data = try? Data(contentsOf: computersURL) else { return [] }
        return (try? JSONDecoder().decode([PairedComputer].self, from: data)) ?? []
    }

    private func writeComputers(_ computers: [PairedComputer]) {
        write(computers, to: computersURL)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: Self.writeOptions)
    }

    /// Readable after the first unlock, so a sync that starts with the phone locked can still
    /// read what it has sent and save what was acknowledged.
    static var writeOptions: Data.WritingOptions {
        #if os(iOS)
        return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        return [.atomic]
        #endif
    }
}
