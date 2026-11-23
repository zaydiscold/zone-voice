// by zayd/cold @ zayd.wtf

import Foundation

/// A record the person deleted on purpose, waiting to be told to the computers that have it.
public struct LinkDeletion: Codable, Equatable, Sendable {
    public var id: String
    public var kind: LinkKind
    /// Unix seconds.
    public var at: Double
    /// Endpoint ids of the computers that keep their copy of this record: "Keep what I delete
    /// here" was on for them when it was deleted, or was turned on before they were told.
    /// They are never sent this deletion, even after the switch is turned off. Nil in logs
    /// written before the switch existed, which reads as none.
    public var keptBy: [String]?

    public init(id: String, kind: LinkKind, at: Double, keptBy: [String]? = nil) {
        self.id = id
        self.kind = kind
        self.at = at
        self.keptBy = keptBy
    }

    public func isKept(by endpointID: String) -> Bool {
        keptBy?.contains(endpointID) ?? false
    }
}

/// What one computer's database is known to hold: the `rev` each item was acknowledged at.
///
/// The phone is the sender and the source of truth, so this is the whole of "sync state": an
/// item whose current `rev` differs from the acknowledged one is sent again, and nothing else is.
public struct LinkDeliveryState: Codable, Equatable, Sendable {
    /// The database this state describes. Nil before the first welcome.
    public var computerID: String?
    /// Item id to the `rev` the computer acknowledged.
    public var delivered: [String: String]
    /// IDs the computer may hold without a current revision receipt, including sends awaiting
    /// acknowledgement and receipts reset by a full resend. Explicit deletions still apply.
    public var attempted: Set<String>

    public init(computerID: String? = nil, delivered: [String: String] = [:], attempted: Set<String> = []) {
        self.computerID = computerID
        self.delivered = delivered
        self.attempted = attempted
    }

    private enum CodingKeys: String, CodingKey { case computerID, delivered, attempted }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        computerID = try container.decodeIfPresent(String.self, forKey: .computerID)
        delivered = try container.decodeIfPresent([String: String].self, forKey: .delivered) ?? [:]
        attempted = try container.decodeIfPresent(Set<String>.self, forKey: .attempted) ?? []
    }

    /// Applies a `welcome`. A different database, or `resend_all`, forgets everything that was
    /// sent, so the next plan is the whole library. Returns true when it forgot. Call it through
    /// `LinkStore.adopt`, which also starts an Everything flash round over when it forgets.
    @discardableResult
    public mutating func adopt(computerID id: String, resendAll: Bool) -> Bool {
        let changed = computerID != nil && computerID != id
        let forget = changed || resendAll
        if changed {
            delivered = [:]
            attempted = []
        } else if resendAll {
            forgetDeliveries()
        }
        computerID = id
        return forget
    }

    /// Forgets what was sent, keeping the computer: "Send everything again". Call it through
    /// `LinkStore.forgetDeliveries`, which also starts an Everything flash round over.
    public mutating func forgetDeliveries() {
        // Reset the revision comparison for live items. This same database can still
        // hold a deleted record until it acknowledges the deletion.
        attempted.formUnion(delivered.keys)
        delivered = [:]
    }

    /// True when the computer has, or may have, this item.
    public func mayHave(_ id: String) -> Bool {
        delivered[id] != nil || attempted.contains(id)
    }

    /// What to send now: every item the computer does not have at its current `rev`, then a
    /// deletion for every record the person deleted that the computer has or may have.
    ///
    /// A record that is simply gone from the library (history retention aged it out) is not in
    /// `deletions`, so nothing is sent for it: the computer is the long-term copy.
    public func pending(library: [LinkItem], deletions: [LinkDeletion]) -> [LinkItem] {
        let changed = library
            .filter { $0.rev == nil || delivered[$0.id] != $0.rev }
            .sorted { ($0.updatedAt, $0.id) < ($1.updatedAt, $1.id) }
        let present = Set(library.map(\.id))
        var seen = Set<String>()
        let gone = deletions
            .filter { !present.contains($0.id) && mayHave($0.id) && seen.insert($0.id).inserted }
            .sorted { ($0.at, $0.id) < ($1.at, $1.id) }
            .map { LinkItem.deletion(id: $0.id, kind: $0.kind, at: $0.at) }
        return changed + gone
    }

    /// Call before a frame goes out. Clips are not library records and are kept track of in
    /// the clip outbox, so they leave no mark here.
    public mutating func willSend(_ items: [LinkItem]) {
        for item in items where item.kind != .clip { attempted.insert(item.id) }
    }

    /// Call when the frame's `ack` arrives: only now do its items count as delivered.
    public mutating func acknowledge(_ items: [LinkItem]) {
        for item in items where item.kind != .clip {
            attempted.remove(item.id)
            if item.deleted {
                delivered[item.id] = nil
            } else if let rev = item.rev {
                delivered[item.id] = rev
            }
        }
    }
}

/// The small log of records the person deleted on purpose.
///
/// Only an explicit delete writes here (one dictation, a date range, everything, a note, a
/// meeting). History retention never does, which is the whole difference between "delete this
/// on my computer too" and "the phone stopped keeping it".
public final class LinkDeletionLog: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()
    /// Far more than anyone deletes between two syncs; the oldest go first.
    public static let capacity = 20_000

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// - Parameter keptBy: the computers that keep their copies of these records
    ///   (`LinkStore.recordDeletion` fills it in).
    public func record(_ ids: [UUID], kind: LinkKind, at date: Date = Date(), keptBy: [String] = []) {
        guard !ids.isEmpty else { return }
        let at = LinkEncoding.seconds(date)
        change { entries in
            let known = Set(entries.map(\.id))
            entries += ids.map(\.uuidString).filter { !known.contains($0) }
                .map { LinkDeletion(id: $0, kind: kind, at: at, keptBy: keptBy.isEmpty ? nil : keptBy) }
            if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        }
    }

    /// Spares one computer every deletion written down so far: it keeps those copies for good.
    public func spare(_ endpointID: String) {
        change { entries in
            for index in entries.indices where !entries[index].isKept(by: endpointID) {
                entries[index].keptBy = (entries[index].keptBy ?? []) + [endpointID]
            }
        }
    }

    public func all() -> [LinkDeletion] {
        lock.lock(); defer { lock.unlock() }
        return read()
    }

    /// Drops the entries no paired computer needs any more.
    public func prune(keeping keep: (LinkDeletion) -> Bool) {
        change { entries in entries.removeAll { !keep($0) } }
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func change(_ body: (inout [LinkDeletion]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var entries = read()
        let before = entries
        body(&entries)
        guard entries != before else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: LinkStore.writeOptions)
    }

    private func read() -> [LinkDeletion] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([LinkDeletion].self, from: data)) ?? []
    }
}
