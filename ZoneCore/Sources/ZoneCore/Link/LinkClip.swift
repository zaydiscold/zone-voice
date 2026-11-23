// by zayd/cold @ zayd.wtf

import Foundation

/// How a clip was sent (Zone Link protocol, "Clips").
public enum LinkClipSource: String, Codable, Sendable, CaseIterable {
    /// What was on the phone's clipboard.
    case clipboard
    /// Shared from another app.
    case share
    /// The Send to Computer shortcut.
    case shortcut
    /// Typed into Zone.
    case typed
}

/// A piece of text the person chose to send to their computers: a paste bin, phone to computer.
///
/// A clip is not part of the library. It waits here until every computer it was meant for has
/// acknowledged it, then stays a while as a line in the Sent list, and deleting it is never
/// sent anywhere.
public struct LinkClip: Codable, Equatable, Identifiable, Sendable {
    /// The most a clip may hold, in bytes of UTF-8 (the protocol's 256 kB).
    public static let maxBytes = 256_000
    /// How much of a clip stays on the phone for the Sent list once every computer has it.
    public static let previewCharacters = 160

    public var id: UUID
    /// The whole text while a computer is still waiting for it. Once every computer has it,
    /// only the first `previewCharacters`: a sent clip is the computer's to keep, not the phone's.
    public var text: String
    public var source: LinkClipSource
    public var createdAt: Date
    /// The size of what was sent, in bytes of UTF-8.
    public var bytes: Int
    /// Endpoint ids of the computers that have not acknowledged it yet.
    public var waiting: [String]
    /// Endpoint ids of the computers that acknowledged it.
    public var sentTo: [String]
    /// When the last computer acknowledged it.
    public var sentAt: Date?

    public init(id: UUID = UUID(), text: String, source: LinkClipSource, createdAt: Date = Date(), waiting: [String]) {
        self.id = id
        self.text = text
        self.source = source
        self.createdAt = createdAt
        self.bytes = text.utf8.count
        self.waiting = waiting
        self.sentTo = []
    }

    /// True once no computer is waiting for it.
    public var isSent: Bool { waiting.isEmpty }

    /// The clip as the computer stores it: an ordinary item of kind `clip`.
    public var item: LinkItem {
        let at = LinkEncoding.seconds(createdAt)
        return LinkItem(id: id.uuidString, kind: .clip, source: source.rawValue, createdAt: at, updatedAt: at,
                        text: text).stamped()
    }

    /// One line for the Sent list: the start of the text, on one line.
    public var preview: String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return line.count > Self.previewCharacters ? String(line.prefix(Self.previewCharacters)) + "…" : line
    }
}

public enum LinkClipFailure: Error, Equatable {
    /// Nothing but spaces and line breaks.
    case empty
    /// More than `LinkClip.maxBytes`.
    case tooLarge(bytes: Int)
    /// No paired computer has sending switched on.
    case noComputer

    /// What the person is told. Plain words.
    public var plainMessage: String {
        switch self {
        case .empty: return "Nothing to send."
        case .tooLarge: return "Too large for one clip (max \(LinkClip.maxBytes / 1000) kB)."
        case .noComputer: return "No active computer. Enable Send to this computer in Settings → Computers."
        }
    }
}

/// The clips waiting for a computer, and the last few that were sent. One file, `clips.json`,
/// beside the rest of what Zone Link keeps. Safe to use from any thread.
public final class LinkClipOutbox: @unchecked Sendable {
    /// How many sent clips are kept for the Sent list. Waiting clips are always kept.
    public static let sentKept = 20

    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Checks a text before it is queued: not empty, not over the limit. The text itself is
    /// sent exactly as given.
    public static func check(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LinkClipFailure.empty }
        let bytes = text.utf8.count
        guard bytes <= LinkClip.maxBytes else { throw LinkClipFailure.tooLarge(bytes: bytes) }
    }

    /// Queues a clip for these computers. It stays until each of them acknowledges it.
    @discardableResult
    public func add(_ text: String, source: LinkClipSource, to endpointIDs: [String], at date: Date = Date(),
                    id: UUID = UUID()) throws -> LinkClip {
        try Self.check(text)
        var targets: [String] = []
        for endpointID in endpointIDs where !targets.contains(endpointID) { targets.append(endpointID) }
        guard !targets.isEmpty else { throw LinkClipFailure.noComputer }
        let clip = LinkClip(id: id, text: text, source: source, createdAt: date, waiting: targets)
        change { $0.append(clip) }
        return clip
    }

    /// Every clip, newest first: the Sent list.
    public func all() -> [LinkClip] {
        lock.lock(); defer { lock.unlock() }
        return read().sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
    }

    public func clip(_ id: UUID) -> LinkClip? {
        lock.lock(); defer { lock.unlock() }
        return read().first { $0.id == id }
    }

    /// The clips one computer is still to be sent, oldest first, as items.
    public func pending(for endpointID: String) -> [LinkItem] {
        lock.lock(); defer { lock.unlock() }
        return read().filter { $0.waiting.contains(endpointID) }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
            .map(\.item)
    }

    /// True while any clip waits for this computer.
    public func hasPending(for endpointID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return read().contains { $0.waiting.contains(endpointID) }
    }

    /// A computer acknowledged these items (or the person said a Flash arrived): the clips
    /// among them stop waiting for it. Items of other kinds are ignored.
    public func acknowledge(_ items: [LinkItem], by endpointID: String, at date: Date = Date()) {
        let ids = Set(items.filter { $0.kind == .clip }.compactMap { UUID(uuidString: $0.id) })
        guard !ids.isEmpty else { return }
        change { clips in
            for index in clips.indices where ids.contains(clips[index].id) && clips[index].waiting.contains(endpointID) {
                clips[index].waiting.removeAll { $0 == endpointID }
                clips[index].sentTo.append(endpointID)
                if clips[index].waiting.isEmpty { Self.settle(&clips[index], at: date) }
            }
        }
    }

    /// Takes a clip off the phone. Nothing is told to any computer: one that has it keeps it,
    /// and one still waiting for it never gets it.
    public func remove(_ id: UUID) {
        change { $0.removeAll { $0.id == id } }
    }

    /// Clears the Sent list. Clips still waiting for a computer stay.
    public func removeSent() {
        change { $0.removeAll(where: \.isSent) }
    }

    /// A computer was forgotten: nothing waits for it any more. A clip that waited only for
    /// it, and reached no other computer, is dropped.
    public func forget(_ endpointID: String, at date: Date = Date()) {
        change { clips in
            for index in clips.indices where clips[index].waiting.contains(endpointID) {
                clips[index].waiting.removeAll { $0 == endpointID }
                if clips[index].waiting.isEmpty, !clips[index].sentTo.isEmpty { Self.settle(&clips[index], at: date) }
            }
            clips.removeAll { $0.waiting.isEmpty && $0.sentTo.isEmpty }
        }
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Every computer has it: keep the time and a short preview, not the whole text.
    private static func settle(_ clip: inout LinkClip, at date: Date) {
        clip.sentAt = date
        if clip.text.count > LinkClip.previewCharacters {
            clip.text = String(clip.text.prefix(LinkClip.previewCharacters))
        }
    }

    private func change(_ body: (inout [LinkClip]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var clips = read()
        let before = clips
        body(&clips)
        // The newest `sentKept` sent clips stay; older sent ones go. Waiting ones always stay.
        let sent = clips.filter(\.isSent).sorted { ($0.sentAt ?? $0.createdAt) > ($1.sentAt ?? $1.createdAt) }
        if sent.count > Self.sentKept {
            let dropped = Set(sent.dropFirst(Self.sentKept).map(\.id))
            clips.removeAll { dropped.contains($0.id) }
        }
        guard clips != before else { return }
        if clips.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(clips) else { return }
        try? data.write(to: fileURL, options: LinkStore.writeOptions)
        // A clip is often a code or a password, on its way to a computer and nothing more: out
        // of the iPhone's own backups, like History. An atomic write makes a new file, so this
        // is set again after every write.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = fileURL
        try? url.setResourceValues(values)
    }

    private func read() -> [LinkClip] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([LinkClip].self, from: data)) ?? []
    }
}

/// What the Sent list and the shortcut say about a clip.
public enum LinkClipCopy {
    public static let row = "Send text to your computer"
    public static let rowNote = "Send a link, code, or clipboard snippet straight to your computer."
    public static let sent = "Sent"

    /// "Sent", or "Waiting for Studio Mac", or both when one computer has it and another does
    /// not. `names` maps endpoint ids to computer names.
    public static func status(_ clip: LinkClip, names: [String: String]) -> String {
        let waiting = list(clip.waiting.map { names[$0] ?? "the computer" })
        guard !clip.waiting.isEmpty else { return sent }
        guard !clip.sentTo.isEmpty else { return "Waiting for \(waiting)" }
        return "Sent to \(list(clip.sentTo.map { names[$0] ?? "the computer" })). Waiting for \(waiting)"
    }

    /// One sentence for the shortcut's answer and the sheet, after a send was tried.
    public static func outcome(_ clip: LinkClip, names: [String: String]) -> String {
        if clip.isSent {
            return "Sent to \(list(clip.sentTo.map { names[$0] ?? "the computer" }))."
        }
        let waiting = list(clip.waiting.map { names[$0] ?? "the computer" })
        let rest = "Zone could not reach \(waiting) just now. It is saved and goes with the next sync."
        guard !clip.sentTo.isEmpty else { return rest }
        return "Sent to \(list(clip.sentTo.map { names[$0] ?? "the computer" })). \(rest)"
    }

    /// "Studio Mac", "Studio Mac and ThinkPad", "A, B and C".
    public static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return "the computer"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }
}
