// by zayd/cold @ zayd.wtf

import CryptoKit
import Foundation

/// A JSON value carried as it is, for an item's `extra`.
public enum LinkJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([LinkJSON])
    case object([String: LinkJSON])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([LinkJSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: LinkJSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// The label agents filter on.
public enum LinkKind: String, Codable, Sendable, CaseIterable {
    /// Something spoken into a text field or the app.
    case dictation
    /// A voice note saved in Zone's own library.
    case note
    /// A recorded meeting with a transcript.
    case meeting
    /// Text the person sent to the computer on purpose (`LinkClip`). Not part of the library.
    case clip
}

/// One library record as the computer stores it (Zone Link protocol, "Items"). The same object
/// travels over every carrier, so nothing in here knows how it is sent.
///
/// A deletion is the short form: `id`, `kind`, `deleted` and `updated_at` only.
public struct LinkItem: Equatable, Sendable, Codable {
    /// The record's UUID, uppercase with hyphens.
    public var id: String
    public var kind: LinkKind
    /// Dictations: the raw `TranscriptSource`, passed through unchanged. Clips: how it was sent.
    public var source: String?
    /// Unix seconds. Nil on a deletion.
    public var createdAt: Double?
    /// Unix seconds. On a deletion, when the person deleted it.
    public var updatedAt: Double
    public var text: String?
    /// Meetings only.
    public var title: String?
    /// Recorded audio seconds when known.
    public var durationS: Double?
    public var engine: String?
    public var status: String?
    public var extra: [String: LinkJSON]
    /// A short hash of everything above. The computer stores it and never reads it.
    public var rev: String?
    public var deleted: Bool

    public init(id: String, kind: LinkKind, source: String? = nil, createdAt: Double?, updatedAt: Double,
                text: String?, title: String? = nil, durationS: Double? = nil, engine: String? = nil,
                status: String? = nil, extra: [String: LinkJSON] = [:], rev: String? = nil, deleted: Bool = false) {
        self.id = id
        self.kind = kind
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.text = text
        self.title = title
        self.durationS = durationS
        self.engine = engine
        self.status = status
        self.extra = extra
        self.rev = rev
        self.deleted = deleted
    }

    /// The person deleted this record: the computer drops the text and keeps the row.
    public static func deletion(id: String, kind: LinkKind, at: Double) -> LinkItem {
        LinkItem(id: id, kind: kind, createdAt: nil, updatedAt: at, text: nil, deleted: true)
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, source, text, title, engine, status, extra, rev, deleted
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case durationS = "duration_s"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(LinkKind.self, forKey: .kind)
        deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        updatedAt = try container.decode(Double.self, forKey: .updatedAt)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        createdAt = try container.decodeIfPresent(Double.self, forKey: .createdAt)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        durationS = try container.decodeIfPresent(Double.self, forKey: .durationS)
        engine = try container.decodeIfPresent(String.self, forKey: .engine)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        extra = try container.decodeIfPresent([String: LinkJSON].self, forKey: .extra) ?? [:]
        rev = try container.decodeIfPresent(String.self, forKey: .rev)
    }

    /// Fields with no value are written as `null`, as the protocol's example shows them, so a
    /// reader never has to tell "missing" from "empty".
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(updatedAt, forKey: .updatedAt)
        if deleted {
            try container.encode(true, forKey: .deleted)
            return
        }
        try container.encode(source, forKey: .source)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(text, forKey: .text)
        try container.encode(title, forKey: .title)
        try container.encode(durationS, forKey: .durationS)
        try container.encode(engine, forKey: .engine)
        try container.encode(status, forKey: .status)
        try container.encode(extra, forKey: .extra)
        if let rev { try container.encode(rev, forKey: .rev) }
    }

    /// The bytes that go on the wire: keys sorted, so the same record always encodes the same.
    public func encoded() throws -> Data {
        try LinkItem.encoder.encode(self)
    }

    /// This item with `rev` set from its content. Two records with the same content get the
    /// same `rev` on any launch, which is what lets the phone skip what the computer has.
    public func stamped() -> LinkItem {
        var copy = self
        copy.rev = nil
        let bytes = (try? copy.encoded()) ?? Data(copy.id.utf8)
        copy.rev = SHA256.hash(data: bytes).prefix(8).map { String(format: "%02x", $0) }.joined()
        return copy
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}

/// Turns the app's records into items. Records that are still being recorded, or that have no
/// words, are left out: they are sent once they are finished.
public enum LinkEncoding {
    /// Statuses of a dictation that is still in progress. Everything else in the history file is
    /// a finished dictation: inserted, offered, dismissed, saved as a note, cut off and so on.
    /// A cut-off record is final text too: it is whatever was saved, and a later retry of the
    /// same recording replaces it under the same id.
    public static let unfinishedStatuses: Set<TranscriptStatus> = [.recording, .paused]

    public static func item(_ record: TranscriptRecord) -> LinkItem? {
        guard !unfinishedStatuses.contains(record.status) else { return nil }
        let text = record.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var extra: [String: LinkJSON] = [:]
        if let recovered = record.recoveredFrom { extra["recovered_from"] = .number(seconds(recovered)) }
        if let destination = record.destination, !destination.isEmpty { extra["destination"] = .string(destination) }
        if let interruptions = record.interruptions { extra["interruptions"] = .number(Double(interruptions)) }
        return LinkItem(id: record.id.uuidString, kind: .dictation, source: record.source.rawValue,
                        createdAt: seconds(record.createdAt), updatedAt: seconds(record.updatedAt), text: text,
                        durationS: known(record.audioSeconds), engine: record.engine.isEmpty ? nil : record.engine,
                        status: record.status.rawValue, extra: extra).stamped()
    }

    public static func item(_ note: LibraryNote) -> LinkItem? {
        let text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return LinkItem(id: note.id.uuidString, kind: .note, createdAt: seconds(note.createdAt),
                        updatedAt: seconds(note.editedAt ?? note.createdAt), text: text).stamped()
    }

    /// A meeting is sent once its transcript is done. The text is one line per segment,
    /// `Speaker name: words` where the speaker is known, and `extra.segments` keeps the timing.
    public static func item(_ meeting: Meeting) -> LinkItem? {
        guard meeting.status == .done else { return nil }
        let spoken = meeting.segments
            .sorted { $0.start < $1.start }
            .map { (segment: $0, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.text.isEmpty }
        guard !spoken.isEmpty else { return nil }
        let lines = spoken.map { entry -> String in
            guard let name = meeting.speakerName(entry.segment.speaker) else { return entry.text }
            return "\(name): \(entry.text)"
        }
        let segments = spoken.map { entry -> LinkJSON in
            .object([
                "speaker": meeting.speakerName(entry.segment.speaker).map(LinkJSON.string) ?? .null,
                "start": .number(finite(entry.segment.start)),
                "end": .number(finite(entry.segment.end)),
                "text": .string(entry.text),
            ])
        }
        var extra: [String: LinkJSON] = ["segments": .array(segments)]
        if let diarizer = meeting.diarizer, !diarizer.isEmpty { extra["diarizer"] = .string(diarizer) }
        let title = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return LinkItem(id: meeting.id.uuidString, kind: .meeting, createdAt: seconds(meeting.createdAt),
                        updatedAt: seconds(meeting.updatedAt), text: lines.joined(separator: "\n"),
                        title: title.isEmpty ? nil : title, durationS: known(meeting.duration),
                        engine: meeting.engine, status: meeting.status.rawValue, extra: extra).stamped()
    }

    /// The whole library as items, in no particular order.
    public static func library(dictations: [TranscriptRecord], notes: [LibraryNote], meetings: [Meeting]) -> [LinkItem] {
        let saved = Set(notes.compactMap(\.recordingID))
        let history = dictations.filter { $0.status != .note && !saved.contains($0.id) }
        return history.compactMap { item($0) } + notes.compactMap { item($0) } + meetings.compactMap { item($0) }
    }

    /// Unix seconds, the protocol's clock.
    public static func seconds(_ date: Date) -> Double { finite(date.timeIntervalSince1970) }

    private static func known(_ seconds: Double) -> Double? {
        seconds.isFinite && seconds > 0 ? seconds : nil
    }

    /// JSON has no infinity or NaN; a damaged number becomes zero instead of failing the item.
    private static func finite(_ value: Double) -> Double { value.isFinite ? value : 0 }
}
