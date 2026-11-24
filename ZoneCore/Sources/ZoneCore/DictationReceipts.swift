import Foundation

/// Numeric accounting in the coordinated History archive. Text retention can be off, a retry
/// can replace a transcript, and the keyboard can confirm or undo delivery after the app exits.
struct DictationReceipts: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var start: Double
        var words: Int
        var seconds: Double
        var kept: Int?
        // A late recovery has a recent History and delivery window but keeps its original
        // start for the reset fence, session membership and personal record.
        var recoveredAt: Double?
        var rankOnly: Bool?
        var permanent: Int?

        var isValid: Bool {
            (1...10_000_000).contains(words) && start.isFinite && seconds > 0 && seconds < 31_536_000
                && (recoveredAt?.isFinite ?? true)
                && (kept.map { (0...words).contains($0) } ?? true)
                && (permanent.map { (0...words).contains($0) } ?? true)
        }
    }

    var entries: [String: Entry] = [:]
    var reset: Double?
    // Presence, including zero, is the migration marker that travels with the archive.
    var unmatchedWords: Int?
    var unmatchedSeconds: Double?

    // Only old test builds compacted receipts. Keep their lifetime-only figures when
    // upgrading. New recordings always retain their UUID for retries and additive imports.
    private var unmatchedCount = 0
    private var unmatchedKept = 0
    private var unmatchedMeasuredSeconds = 0.0
    private var unmatchedLongest: Entry?

    // While seeded, the unmatched fields are the transferred phone's snapshot.
    // Every receipt in entries was recorded after that snapshot.
    private var seededBaseline = false
    private var unmatchedSavedMinutes = 0

    private enum CodingKeys: String, CodingKey {
        case entries, reset, unmatchedWords, unmatchedSeconds, unmatchedCount, unmatchedKept
        case seededBaseline, unmatchedSavedMinutes, unmatchedMeasuredSeconds, unmatchedLongest, prefixes, statsMigrated
    }

    private enum LegacyKeys: String, CodingKey {
        case first, through, count, words, kept, seconds, measuredSeconds, longest
    }

    private func encodeHeader(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        if seededBaseline { try fields.encode(true, forKey: .seededBaseline) }
        if unmatchedSavedMinutes > 0 { try fields.encode(unmatchedSavedMinutes, forKey: .unmatchedSavedMinutes) }
        try fields.encodeIfPresent(reset, forKey: .reset)
        if unmatchedWords != nil { try fields.encode(true, forKey: .statsMigrated) }
        try fields.encodeIfPresent(unmatchedWords, forKey: .unmatchedWords)
        try fields.encodeIfPresent(unmatchedSeconds, forKey: .unmatchedSeconds)
        if unmatchedCount > 0 { try fields.encode(unmatchedCount, forKey: .unmatchedCount) }
        if unmatchedKept > 0 { try fields.encode(unmatchedKept, forKey: .unmatchedKept) }
        if unmatchedMeasuredSeconds > 0 { try fields.encode(unmatchedMeasuredSeconds, forKey: .unmatchedMeasuredSeconds) }
        try fields.encodeIfPresent(unmatchedLongest, forKey: .unmatchedLongest)
    }

    func encode(to encoder: Encoder) throws {
        try encodeHeader(to: encoder)
        if !entries.isEmpty {
            var fields = encoder.container(keyedBy: CodingKeys.self)
            try fields.encode(entries, forKey: .entries)
        }
    }

    func appendJSON(to data: inout Data, encoder: JSONEncoder) throws {
        var header = self
        header.entries = [:]
        let bytes = try encoder.encode(header)
        data.append(bytes.dropLast())
        if bytes.count > 2 { data.append(UInt8(ascii: ",")) }
        data.append(contentsOf: #""entries":{"#.utf8)
        var first = true
        for (id, entry) in entries {
            if !first { data.append(UInt8(ascii: ",")) }
            data.append(try encoder.encode(id))
            data.append(UInt8(ascii: ":"))
            data.append(try encoder.encode(entry))
            first = false
        }
        data.append(contentsOf: "}}".utf8)
    }

    init() {}

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        if let list = try? fields.nestedContainer(keyedBy: ReceiptKey.self, forKey: .entries) {
            for key in list.allKeys {
                guard let id = UUID(uuidString: key.stringValue),
                      let entry = try? list.decode(Entry.self, forKey: key),
                      entry.isValid else { continue }
                entries[id.uuidString] = entry
            }
        }
        if let value = try? fields.decode(Double.self, forKey: .reset), value.isFinite { reset = value }
        if fields.contains(.unmatchedWords) || (try? fields.decode(Bool.self, forKey: .statsMigrated)) == true {
            let value = (try? fields.decode(Int.self, forKey: .unmatchedWords)) ?? 0
            unmatchedWords = min(max(0, value), 1_000_000_000_000)
        }
        if let value = try? fields.decode(Double.self, forKey: .unmatchedSeconds), value.isFinite {
            unmatchedSeconds = min(max(0, value), 1e12)
        }
        seededBaseline = unmatchedWords != nil && (try? fields.decode(Bool.self, forKey: .seededBaseline)) == true
        unmatchedSavedMinutes = min(1_000_000_000_000, max(0, (try? fields.decode(Int.self, forKey: .unmatchedSavedMinutes)) ?? 0))
        let words = unmatchedWords ?? 0
        // After transfer reconciliation, independent residuals need not belong to the
        // same recordings (all words may be matched while kept credit is still missing).
        unmatchedCount = min(1_000_000_000_000, max(0, (try? fields.decode(Int.self, forKey: .unmatchedCount)) ?? 0))
        unmatchedKept = min(1_000_000_000_000, max(0, (try? fields.decode(Int.self, forKey: .unmatchedKept)) ?? 0))
        unmatchedMeasuredSeconds = min(1e12, max(0, (try? fields.decode(Double.self, forKey: .unmatchedMeasuredSeconds)) ?? 0))
        considerLongest(try? fields.decode(Entry.self, forKey: .unmatchedLongest))
        if let list = try? fields.nestedContainer(keyedBy: ReceiptKey.self, forKey: .prefixes), !list.allKeys.isEmpty {
            unmatchedWords = words
            for key in list.allKeys where UUID(uuidString: key.stringValue) != nil {
                guard let old = try? list.nestedContainer(keyedBy: LegacyKeys.self, forKey: key),
                      let first = try? old.decode(Double.self, forKey: .first),
                      let through = try? old.decode(Double.self, forKey: .through),
                      first.isFinite, through.isFinite, first <= through,
                      let words = try? old.decode(Int.self, forKey: .words), (0...1_000_000_000_000).contains(words),
                      let count = try? old.decode(Int.self, forKey: .count), (0...words).contains(count),
                      let kept = try? old.decode(Int.self, forKey: .kept), (0...words).contains(kept),
                      let seconds = try? old.decode(Double.self, forKey: .seconds), (0...1e12).contains(seconds),
                      let measured = try? old.decode(Double.self, forKey: .measuredSeconds), (0...seconds).contains(measured)
                else { continue }
                unmatchedWords = min(1_000_000_000_000, (unmatchedWords ?? 0) + words)
                unmatchedSeconds = min(1e12, (unmatchedSeconds ?? 0) + seconds)
                unmatchedCount = min(1_000_000_000_000, unmatchedCount + count)
                unmatchedKept = min(1_000_000_000_000, unmatchedKept + kept)
                unmatchedMeasuredSeconds = min(1e12, unmatchedMeasuredSeconds + measured)
                considerLongest(try? old.decode(Entry.self, forKey: .longest))
            }
        }
    }

    private mutating func considerLongest(_ candidate: Entry?) {
        guard let candidate, candidate.isValid else { return }
        if let best = unmatchedLongest, best.words > candidate.words ||
            (best.words == candidate.words && best.start <= candidate.start) { return }
        unmatchedLongest = candidate
    }

    private struct ReceiptKey: CodingKey {
        var stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { return nil }
    }

    mutating func finish(id: UUID, start: Date, words: Int, seconds: Double,
                         recoveryDate: Date?, awaitingNote: Bool) {
        let time = start.timeIntervalSince1970
        guard time > (reset ?? -.infinity), words > 0, seconds.isFinite, seconds > 0 else { return }
        if var previous = entries[id.uuidString] {
            guard let recoveryDate else { return }
            previous.recoveredAt = recoveryDate.timeIntervalSince1970
            previous.words = words
            previous.seconds = seconds
            previous.kept = previous.kept.map { min($0, words) }
            previous.permanent = previous.permanent.map { min($0, words) }
            entries[id.uuidString] = previous
        } else {
            entries[id.uuidString] = Entry(start: time, words: words, seconds: seconds, kept: awaitingNote ? nil : 0,
                                           recoveredAt: recoveryDate?.timeIntervalSince1970)
        }
    }

    mutating func delivery(id: UUID, kept: Int, permanent: Bool = false) {
        guard let entry = entries[id.uuidString] else { return }
        let count = min(entry.words, max(0, kept))
        if permanent { entries[id.uuidString]?.permanent = max(entry.permanent ?? 0, count) }
        else { entries[id.uuidString]?.kept = count }
    }

    mutating func migrate(words: Int, seconds: Double, history: [TranscriptRecord]) {
        guard unmatchedWords == nil else { return }
        var remainingWords = reset == nil ? words : 0
        var remainingSeconds = reset == nil ? seconds : 0
        for record in history.sorted(by: { $0.createdAt > $1.createdAt }) {
            guard entries[record.id.uuidString] == nil, record.status != .cutOff,
                  record.status != .recording, record.status != .paused, record.source != .remote,
                  record.recoveredFrom == nil, record.audioSeconds.isFinite, record.audioSeconds > 0 else { continue }
            let count = record.wordCount
            guard count > 0 else { continue }
            if KeyboardCapture.historyNote(engine: record.engine, source: record.source) != nil {
                guard remainingWords > 0 else { break }
                entries[record.id.uuidString] = Entry(start: record.createdAt.timeIntervalSince1970, words: count,
                                                      seconds: record.audioSeconds, kept: nil, rankOnly: true)
                continue
            }
            // Old resets left no timestamp. Never add pre-reset words beyond the old counter.
            guard count <= remainingWords, record.audioSeconds <= remainingSeconds + 0.001 else { break }
            entries[record.id.uuidString] = Entry(start: record.createdAt.timeIntervalSince1970, words: count,
                                                  seconds: record.audioSeconds, kept: nil)
            remainingWords -= count
            remainingSeconds = max(0, remainingSeconds - record.audioSeconds)
        }
        unmatchedWords = remainingWords
        unmatchedSeconds = unmatchedSeconds ?? remainingSeconds
    }

    mutating func seedIfEmpty(from cache: DictationTotals?) {
        guard entries.isEmpty, unmatchedWords == nil, reset == nil,
              let cache, cache != DictationTotals() else { return }
        unmatchedWords = cache.words
        unmatchedSeconds = cache.seconds
        unmatchedCount = cache.count
        unmatchedKept = cache.kept
        unmatchedMeasuredSeconds = cache.measuredSeconds
        unmatchedSavedMinutes = cache.legacySavedMinutes
        if let record = cache.longest {
            considerLongest(Entry(start: record.date.timeIntervalSince1970, words: record.words,
                                  seconds: record.seconds, kept: nil))
        }
        seededBaseline = true
    }

    mutating func clear(at date: Date) {
        self = Self()
        reset = date.timeIntervalSince1970
        unmatchedWords = 0
        unmatchedSeconds = 0
    }

    mutating func restore(_ incoming: Self, accumulating: Bool = false) {
        // A backup made on a transferred phone can itself contain the provisional baseline.
        // Reconcile in the same direction whether that backup is local or incoming.
        if incoming.seededBaseline && !seededBaseline && reset == nil {
            var imported = incoming
            imported.restore(self, accumulating: accumulating)
            self = imported
            return
        }
        let adoptsBaseline = entries.isEmpty && (unmatchedWords ?? 0) == 0 && reset == nil && !seededBaseline
        if seededBaseline {
            var past = incoming
            // Accumulated backups can also contain this phone's post-transfer receipts.
            past.entries = incoming.entries.filter { entries[$0.key] == nil }
            if past.totals() != DictationTotals() { reconcileSeed(with: past) }
        }
        if !accumulating && adoptsBaseline { reset = incoming.reset }
        if accumulating { reset = nil }
        if reset == nil || adoptsBaseline {
            if let words = incoming.unmatchedWords { unmatchedWords = max(words, unmatchedWords ?? 0) }
            if let seconds = incoming.unmatchedSeconds { unmatchedSeconds = max(seconds, unmatchedSeconds ?? 0) }
            unmatchedCount = max(unmatchedCount, incoming.unmatchedCount)
            unmatchedKept = max(unmatchedKept, incoming.unmatchedKept)
            unmatchedMeasuredSeconds = max(unmatchedMeasuredSeconds, incoming.unmatchedMeasuredSeconds)
            unmatchedSavedMinutes = max(unmatchedSavedMinutes, incoming.unmatchedSavedMinutes)
            considerLongest(incoming.unmatchedLongest)
        }
        for (id, entry) in incoming.entries where entry.start > (reset ?? -.infinity) {
            if var current = entries[id] {
                if let recovery = entry.recoveredAt, recovery > (current.recoveredAt ?? -.infinity) {
                    current.words = entry.words
                    current.seconds = entry.seconds
                    current.recoveredAt = recovery
                    current.kept = current.kept.map { min($0, current.words) }
                    current.permanent = current.permanent.map { min($0, current.words) }
                }
                if let kept = entry.kept { current.kept = min(current.words, max(kept, current.kept ?? 0)) }
                if let kept = entry.permanent { current.permanent = min(current.words, max(kept, current.permanent ?? 0)) }
                entries[id] = current
            } else {
                entries[id] = entry
            }
        }
    }

    private mutating func reconcileSeed(with incoming: Self) {
        let accounted = incoming.totals(entriesOnly: true)
        unmatchedWords = max(0, (unmatchedWords ?? 0) - accounted.words)
        unmatchedSeconds = max(0, (unmatchedSeconds ?? 0) - accounted.seconds)
        unmatchedCount = max(0, unmatchedCount - accounted.count)
        unmatchedKept = max(0, unmatchedKept - accounted.kept)
        unmatchedMeasuredSeconds = max(0, unmatchedMeasuredSeconds - accounted.measuredSeconds)
        // Previous builds cached only rounded minutes. Replace that credit as detailed
        // backup measurements become available.
        if unmatchedSavedMinutes > 0 {
            let totals = incoming.totals()
            let detailedMinutes = DictationStats.minutesSaved(words: totals.kept, secondsSpoken: totals.measuredSeconds)
            unmatchedSavedMinutes = max(0, unmatchedSavedMinutes - detailedMinutes)
        }
        // A backup exported after a previous transfer may still be waiting for its
        // original receipt archive. Preserve that provenance through another transfer.
        seededBaseline = incoming.seededBaseline
    }

    func totals(since: Date? = nil, entriesOnly: Bool = false) -> DictationTotals {
        var result = DictationTotals()
        if since == nil && !entriesOnly {
            result.legacySavedMinutes = unmatchedSavedMinutes
            result.words = unmatchedWords ?? 0
            result.seconds = unmatchedSeconds ?? 0
            result.count = unmatchedCount
            result.kept = unmatchedKept
            result.measuredSeconds = unmatchedMeasuredSeconds
            if let best = unmatchedLongest {
                result.longest = LongestDictation(seconds: best.seconds, words: best.words,
                                                  date: Date(timeIntervalSince1970: best.start))
            }
        }
        for entry in entries.values where entry.start >= (since?.timeIntervalSince1970 ?? -.infinity) {
            let date = Date(timeIntervalSince1970: entry.start)
            result.longest = DictationStats.longest(result.longest, after: entry.seconds, words: entry.words, at: date)
            guard entry.rankOnly != true else { continue }
            result.count += 1
            result.words += entry.words
            result.seconds += entry.seconds
            if entry.kept != nil || entry.permanent != nil {
                result.kept += max(entry.kept ?? 0, entry.permanent ?? 0)
                result.measuredSeconds += entry.seconds
            }
        }
        return result
    }
}

public struct DictationTotals: Codable, Equatable, Sendable {
    public var count = 0, words = 0, kept = 0
    public var seconds = 0.0, measuredSeconds = 0.0
    public var legacySavedMinutes = 0
    public var minutesSaved: Int {
        legacySavedMinutes + DictationStats.minutesSaved(words: kept, secondsSpoken: measuredSeconds)
    }
    public var longest: LongestDictation?
    public init() {}
}
