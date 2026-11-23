// by zayd/cold @ zayd.wtf

import Foundation

/// A bounded, versioned note sent between the paired Watch and phone. Stable IDs make
/// retries safe; delivery receipts are separate from the transport's queued state.
struct CompanionNoteEnvelope: Codable, Equatable, Identifiable, Sendable {
    static let version = 1
    static let maximumTextBytes = 32_000
    static let maximumPayloadBytes = 40_000
    static let userInfoKey = "zoneNote"
    var schemaVersion = version
    let id: UUID
    let text: String
    let createdAt: Date

    init(id: UUID = UUID(), text: String, createdAt: Date = Date()) throws {
        self.id = id
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
        try validate()
    }

    func validate() throws {
        guard schemaVersion == Self.version else { throw CompanionNoteError.unsupportedVersion }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CompanionNoteError.empty }
        guard text.utf8.count <= Self.maximumTextBytes else { throw CompanionNoteError.tooLarge }
        guard createdAt.timeIntervalSinceReferenceDate.isFinite else { throw CompanionNoteError.invalidDate }
    }

    func userInfo() throws -> [String: Any] {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumPayloadBytes else { throw CompanionNoteError.tooLarge }
        return [Self.userInfoKey: data]
    }

    static func receive(_ userInfo: [String: Any]) throws -> Self {
        guard let data = userInfo[userInfoKey] as? Data else { throw CompanionNoteError.invalidPayload }
        guard data.count <= maximumPayloadBytes else { throw CompanionNoteError.tooLarge }
        let note = try JSONDecoder().decode(Self.self, from: data)
        try note.validate()
        return note
    }
}

enum CompanionNoteError: LocalizedError {
    case unsupportedVersion, empty, tooLarge, invalidDate, invalidPayload
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "Update Zone on both devices before transferring this note."
        case .empty: "Add some words before saving the note."
        case .tooLarge: "This note is too long to transfer from the Watch. Split it into shorter notes."
        case .invalidDate, .invalidPayload: "The note could not be read. It has not been imported."
        }
    }
}

struct CompanionNoteReceipt {
    let noteID: UUID
    var userInfo: [String: Any] { ["zoneNoteReceipt": noteID.uuidString, "zoneReceiptVersion": 1] }
    init(noteID: UUID) { self.noteID = noteID }
    init?(_ userInfo: [String: Any]) {
        guard userInfo["zoneReceiptVersion"] as? Int == 1,
              let raw = userInfo["zoneNoteReceipt"] as? String, let id = UUID(uuidString: raw) else { return nil }
        noteID = id
    }
}

struct WatchSavedNote: Codable, Equatable, Identifiable {
    enum Delivery: String, Codable { case savedOnWatch, queued, receivedOnPhone }
    let note: CompanionNoteEnvelope
    var delivery: Delivery = .savedOnWatch
    var id: UUID { note.id }
}

/// The Watch's source of truth. A mutation becomes visible only after its atomic write
/// succeeds. A malformed existing library is retained and reported, never replaced.
final class WatchNoteLedger {
    private let url: URL
    private(set) var notes: [WatchSavedNote]
    init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            notes = try JSONDecoder().decode([WatchSavedNote].self, from: Data(contentsOf: url))
            for saved in notes { try saved.note.validate() }
        } else { notes = [] }
    }

    func save(_ note: CompanionNoteEnvelope) throws {
        try note.validate()
        guard !notes.contains(where: { $0.id == note.id }) else { return }
        try commit([WatchSavedNote(note: note)] + notes)
    }

    func mark(_ id: UUID, delivery: WatchSavedNote.Delivery) throws {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        // A late transfer completion must not downgrade a persisted phone receipt.
        guard notes[index].delivery != .receivedOnPhone else { return }
        var next = notes
        next[index].delivery = delivery
        try commit(next)
    }

    private func commit(_ next: [WatchSavedNote]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: url, options: .atomic)
        notes = next
    }
}

struct CompanionShareItem: Codable, Identifiable, Equatable {
    enum Source: String, Codable { case note, dictation }
    let id: UUID
    let text: String
    let createdAt: Date
    var source: Source = .note
}

/// A local convenience snapshot for Messages, never the backup or authoritative library.
struct CompanionShareCache: Codable {
    static let maximumBytes = 2_000_000
    static let maximumItems = 80
    var schemaVersion = 1
    let updatedAt: Date
    let items: [CompanionShareItem]
    let omittedCount: Int
    static var url: URL? {
        #if os(iOS)
        let group = Bundle.main.object(forInfoDictionaryKey: "ZoneAppGroup") as? String ?? "group.wtf.zayd.zone"
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("Library/Application Support/messages-notes.json")
        #else
        return nil
        #endif
    }
    static func read(from url: URL) throws -> Self {
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw CompanionNoteError.tooLarge }
        let cache = try JSONDecoder().decode(Self.self, from: data)
        guard cache.schemaVersion == 1, cache.items.count <= maximumItems else { throw CompanionNoteError.unsupportedVersion }
        return cache
    }
}
