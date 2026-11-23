// by zayd/cold @ zayd.wtf

import Foundation

/// One recorded meeting: its audio on disk, where transcription has got to, and the transcript.
///
/// Audio is one or more PCM16 little-endian 16 kHz mono parts (the same framing as audio
/// recovery), played back to back. A meeting gains a part when a recording resumes after an
/// interruption or when two meetings are merged. Durations always come from the files, never
/// from a counter, so a crash can never make the metadata claim audio that is not there.
public struct Meeting: Codable, Identifiable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case recording, recorded, transcribing, done, failed
    }

    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var status: Status
    public var parts: [MeetingAudioPart]
    public var segments: [MeetingSegment]
    public var speakers: [MeetingSpeaker]
    /// Speaker turns from diarization over the audio not yet transcribed, kept so an
    /// interrupted transcription resumes without diarizing again. Nil when none ran.
    public var turns: [MeetingTurn]?
    /// Seconds of audio, from the start, that transcription has finished. Resumes from here.
    public var transcribedThrough: Double
    /// Last progress fraction published while transcribing, 0...1.
    public var progress: Double
    /// The engine that wrote the transcript.
    public var engine: String?
    /// The speaker model that labeled it, or nil when speakers were not labeled.
    public var diarizer: String?
    /// Optional user hint for a fresh speaker pass; older recordings decode as automatic.
    public var expectedSpeakerCount: Int?
    public var speakerCountHint: Int? {
        guard let expectedSpeakerCount, (1...8).contains(expectedSpeakerCount) else { return nil }
        return expectedSpeakerCount
    }
    /// A failure, or a note such as "speakers were not labeled".
    public var message: String?
    /// Recording safety stops and write failures survive transcription retries.
    public var recordingNotice: String?
    /// Why a completed speaker pass has no labels, retained across pause/resume.
    public var speakerNotice: String?
    /// Where the recording lost the microphone (a call, Siri, an alarm) and for how long, in
    /// meeting time. Nil on meetings recorded before gaps were kept.
    public var gaps: [MeetingGap]?

    public var duration: Double { parts.reduce(0) { $0 + $1.seconds } }

    public init(id: UUID = UUID(), title: String, createdAt: Date, status: Status = .recording) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.status = status
        self.parts = []
        self.segments = []
        self.speakers = []
        self.turns = nil
        self.transcribedThrough = 0
        self.progress = 0
        self.engine = nil
        self.diarizer = nil
        self.message = nil
    }

    /// The default title: "Meeting, Nov 1 at 3:04 PM".
    public static func defaultTitle(for date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        let day = formatter.string(from: date)
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return "Meeting, \(day) at \(formatter.string(from: date))"
    }

    /// Display name for a speaker id: the person's name, "Me", or "Speaker N".
    public func speakerName(_ id: String?) -> String? {
        guard let id else { return nil }
        guard let speaker = speakers.first(where: { $0.id == id }) else { return id }
        if let name = speaker.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        if speaker.isMe { return "Me" }
        let number = speakers.firstIndex(where: { $0.id == id }).map { $0 + 1 } ?? 0
        return "Speaker \(number)"
    }
}

public struct MeetingAudioPart: Codable, Equatable, Sendable {
    public var fileName: String
    public var bytes: Int64
    public var seconds: Double { Double(bytes / 2) / 16_000 }
    public init(fileName: String, bytes: Int64) {
        self.fileName = fileName
        self.bytes = bytes
    }
}

public struct MeetingSegment: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var speaker: String?
    public var text: String
    public init(start: Double, end: Double, speaker: String?, text: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }
}

public struct MeetingSpeaker: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String?
    public var isMe: Bool
    public init(id: String, name: String? = nil, isMe: Bool = false) {
        self.id = id
        self.name = name
        self.isMe = isMe
    }
}

/// One stretch of one voice, in seconds from the start of the meeting.
public struct MeetingTurn: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var speaker: String?
    public init(start: Double, end: Double, speaker: String?) {
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

public enum MeetingStoreError: LocalizedError, Equatable {
    case notFound, stillRecording, busy, sameMeeting, noAudio, transcriptChanged
    public var errorDescription: String? {
        switch self {
        case .notFound: return "That meeting is no longer on this iPhone."
        case .stillRecording: return "Stop the recording first."
        case .busy: return "Wait for the transcript to finish first."
        case .sameMeeting: return "Pick a different meeting to merge."
        case .noAudio: return "This meeting has no audio."
        case .transcriptChanged: return "The transcript changed while you were editing. Open the editor again to keep the latest version."
        }
    }
}

/// Meetings on disk: `<directory>/<id>/meeting.json` plus the PCM parts beside it.
///
/// Thread-safe; every call takes one lock. Metadata writes are atomic and synced. Audio files
/// are app-private, excluded from backups and readable after first unlock, so a recording that
/// continues with the screen locked never loses access to its own file.
public final class MeetingStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSRecursiveLock()

    public init(directory: URL) { self.directory = directory }

    public static let `default`: MeetingStore = {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return MeetingStore(directory: support.appendingPathComponent("Meetings", isDirectory: true))
    }()

    // MARK: Reading

    public func all() -> [Meeting] {
        lock.lock(); defer { lock.unlock() }
        guard let folders = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return folders.compactMap { UUID(uuidString: $0.lastPathComponent) }
            .compactMap { try? load($0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Backup enumeration is strict: a damaged metadata file must not silently hide its audio.
    public func backupMeetings() throws -> [Meeting] {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
        return try folders.filter { UUID(uuidString: $0.lastPathComponent) != nil }.map { folder in
            guard try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw LibraryBackupError.invalidDocument
            }
            return try load(UUID(uuidString: folder.lastPathComponent)!)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    public func meeting(_ id: UUID) throws -> Meeting {
        lock.lock(); defer { lock.unlock() }
        return try load(id)
    }

    public func folder(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }

    /// The meeting's audio parts in playback order.
    public func audioURLs(_ meeting: Meeting) -> [URL] {
        meeting.parts.map { folder(meeting.id).appendingPathComponent($0.fileName) }
    }

    public func audio(_ id: UUID) throws -> MeetingAudio {
        let meeting = try self.meeting(id)
        guard meeting.duration > 0 else { throw MeetingStoreError.noAudio }
        return try MeetingAudio(urls: audioURLs(meeting))
    }

    // MARK: Recording

    /// Creates a meeting in the recording state and opens its first audio part.
    public func beginRecording(title: String? = nil, now: Date = Date()) throws -> (Meeting, MeetingAudioWriter) {
        lock.lock(); defer { lock.unlock() }
        var meeting = Meeting(title: title ?? Meeting.defaultTitle(for: now), createdAt: now)
        try prepare(folder(meeting.id))
        let part = MeetingAudioPart(fileName: "part-1.pcm", bytes: 0)
        meeting.parts = [part]
        try save(meeting)
        do {
            let writer = try MeetingAudioWriter(url: folder(meeting.id).appendingPathComponent(part.fileName))
            return (meeting, writer)
        } catch {
            try? delete(meeting.id)
            throw error
        }
    }

    /// Opens a new part on a meeting, for a recording that resumes after an interruption.
    public func continueRecording(_ id: UUID, now: Date = Date()) throws -> MeetingAudioWriter {
        lock.lock(); defer { lock.unlock() }
        var meeting = try refreshed(id)
        let name = nextPartName(in: meeting)
        meeting.parts.append(MeetingAudioPart(fileName: name, bytes: 0))
        meeting.status = .recording
        meeting.updatedAt = now
        try save(meeting)
        return try MeetingAudioWriter(url: folder(id).appendingPathComponent(name))
    }

    /// Closes the recording: sizes come from the files, empty parts are dropped.
    @discardableResult
    public func finishRecording(_ id: UUID, now: Date = Date(), recordingNotice: String? = nil) throws -> Meeting {
        lock.lock(); defer { lock.unlock() }
        var meeting = try refreshed(id)
        for part in meeting.parts where part.bytes < 2 {
            try? FileManager.default.removeItem(at: folder(id).appendingPathComponent(part.fileName))
        }
        meeting.parts.removeAll { $0.bytes < 2 }
        meeting.status = meeting.transcribedThrough >= meeting.duration - 0.05 && !meeting.segments.isEmpty ? .done : .recorded
        if let recordingNotice { meeting.recordingNotice = recordingNotice }
        meeting.updatedAt = now
        try save(meeting)
        return meeting
    }

    /// On launch: any meeting still marked recording (or transcribing) by a process that is
    /// gone becomes a recorded meeting with the audio that reached the disk. Returns the ids.
    @discardableResult
    public func recoverInterrupted(activeIDs: Set<UUID> = [], now: Date = Date()) -> [UUID] {
        lock.lock(); defer { lock.unlock() }
        var recovered: [UUID] = []
        for meeting in all() where !activeIDs.contains(meeting.id) {
            if repairParts(meeting.id, now: now) { recovered.append(meeting.id) }
        }
        for meeting in all() where !activeIDs.contains(meeting.id) {
            guard meeting.status == .recording || meeting.status == .transcribing else { continue }
            guard var fresh = try? refreshed(meeting.id) else { continue }
            if fresh.status == .recording {
                for part in fresh.parts where part.bytes < 2 {
                    try? FileManager.default.removeItem(at: folder(fresh.id).appendingPathComponent(part.fileName))
                }
                fresh.parts.removeAll { $0.bytes < 2 }
                fresh.message = "Zone closed while this was recording. Everything up to the last few seconds was saved."
            }
            // An interrupted transcription keeps its finished segments and resumes later.
            fresh.status = .recorded
            fresh.updatedAt = now
            if fresh.parts.isEmpty && fresh.segments.isEmpty {
                try? delete(fresh.id)
                continue
            }
            try? save(fresh)
            if !recovered.contains(fresh.id) { recovered.append(fresh.id) }
        }
        return recovered
    }

    /// Makes a finished meeting's part list match its folder after a crash in the middle of a
    /// merge: part files nobody lists (moved in, metadata not yet saved) are appended in order,
    /// and listed parts whose file is gone (moved out) are dropped, so the audio is neither
    /// orphaned on disk nor claimed by a meeting that can no longer open it. A meeting left with
    /// no audio and no transcript is deleted. Returns true when something changed.
    private func repairParts(_ id: UUID, now: Date) -> Bool {
        guard var meeting = try? load(id), meeting.status != .recording else { return false }
        let folder = self.folder(id)
        let listed = Set(meeting.parts.map(\.fileName))
        let missing = meeting.parts.filter { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.fileName).path) }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let orphans = files.compactMap { name -> (Int, String)? in
            guard !listed.contains(name), name.hasPrefix("part-"), name.hasSuffix(".pcm"),
                  let number = Int(name.dropFirst(5).dropLast(4)) else { return nil }
            return (number, name)
        }.sorted { $0.0 < $1.0 }
        guard !missing.isEmpty || !orphans.isEmpty else { return false }
        let missingNames = Set(missing.map(\.fileName))
        // Audio after a dropped part shifts earlier, so a transcript past that point no longer
        // lines up and is redone. When only trailing parts went (the usual merge crash), the
        // transcript is kept as text: its audio now lives in the other meeting.
        if let first = meeting.parts.firstIndex(where: { missingNames.contains($0.fileName) }),
           meeting.parts[first...].contains(where: { !missingNames.contains($0.fileName) }) {
            let keptPrefix = meeting.parts[..<first].reduce(0) { $0 + $1.seconds }
            if meeting.transcribedThrough > keptPrefix {
                meeting.segments.removeAll { $0.end > keptPrefix + 0.05 }
                meeting.transcribedThrough = keptPrefix
            }
        }
        meeting.parts.removeAll { missingNames.contains($0.fileName) }
        meeting.transcribedThrough = min(meeting.transcribedThrough, meeting.duration)
        for (_, name) in orphans {
            let size = ((try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.size]) as? NSNumber)?.int64Value ?? 0
            guard size >= 2 else {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
                continue
            }
            meeting.parts.append(MeetingAudioPart(fileName: name, bytes: size - size % 2))
        }
        if meeting.parts.isEmpty && meeting.segments.isEmpty {
            try? delete(id)
            return false
        }
        let total = meeting.duration
        if meeting.status == .done || meeting.status == .failed, meeting.transcribedThrough < total - 0.05 {
            meeting.status = .recorded
        }
        meeting.turns = nil
        meeting.progress = total > 0 ? min(meeting.transcribedThrough / total, 1) : 0
        meeting.message = orphans.isEmpty
            ? "Some audio of this meeting was moved by a merge that did not finish. The transcript is kept."
            : "Recovered audio from a merge that did not finish. Transcribe to include it."
        meeting.updatedAt = now
        try? save(meeting)
        return true
    }

    // MARK: Editing

    /// Applies `change` to the stored meeting and saves it atomically.
    @discardableResult
    public func update(_ id: UUID, now: Date = Date(), _ change: (inout Meeting) throws -> Void) throws -> Meeting {
        lock.lock(); defer { lock.unlock() }
        var meeting = try load(id)
        try change(&meeting)
        meeting.updatedAt = now
        try save(meeting)
        return meeting
    }

    public func rename(_ id: UUID, to title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try update(id) { $0.title = trimmed }
    }

    public func renameSpeaker(_ id: UUID, speaker: String, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try update(id) { meeting in
            guard let index = meeting.speakers.firstIndex(where: { $0.id == speaker }) else { return }
            meeting.speakers[index].name = trimmed.isEmpty ? nil : trimmed
        }
    }

    /// Marks one speaker as the phone's owner; only one speaker can be "me". Pass nil to clear.
    public func setMe(_ id: UUID, speaker: String?) throws {
        try update(id) { meeting in
            for index in meeting.speakers.indices {
                meeting.speakers[index].isMe = meeting.speakers[index].id == speaker
            }
        }
    }

    /// Throws away the transcript so the whole meeting is transcribed again.
    public func resetTranscript(_ id: UUID, expectedSpeakerCount: Int? = nil) throws {
        try update(id) { meeting in
            guard meeting.status != .recording else { throw MeetingStoreError.stillRecording }
            guard meeting.status != .transcribing else { throw MeetingStoreError.busy }
            meeting.expectedSpeakerCount = expectedSpeakerCount.flatMap { (1...8).contains($0) ? $0 : nil }
            meeting.segments = []
            meeting.turns = nil
            meeting.transcribedThrough = 0
            meeting.progress = 0
            meeting.message = nil
            meeting.speakerNotice = nil
            meeting.status = .recorded
            // A fresh diarization numbers voices from scratch and cannot know which new number
            // is which old name, so the old speakers go with the old transcript.
            meeting.speakers = []
        }
    }

    /// Saves corrections without replacing speaker labels, timings, audio or newly recognized
    /// text. A stale editor cannot overwrite a transcript that has been regenerated meanwhile.
    public func editTranscript(_ id: UUID, original: [MeetingSegment], texts: [String]) throws -> Meeting {
        try update(id) { meeting in
            guard meeting.status != .recording else { throw MeetingStoreError.stillRecording }
            guard meeting.status != .transcribing else { throw MeetingStoreError.busy }
            guard meeting.segments == original, texts.count == original.count else { throw MeetingStoreError.transcriptChanged }
            for index in texts.indices { meeting.segments[index].text = texts[index].trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    public func delete(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        let url = folder(id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
            Self.announceFinishedChange()
        }
    }

    // MARK: Merge

    /// Joins two meetings into one, earlier first: the later meeting's audio parts move into
    /// the earlier meeting's folder and play after its audio, its segments shift by the earlier
    /// meeting's duration, and its speakers are renumbered so the two never collide (a speaker
    /// marked "me" or sharing a name with one in the earlier meeting becomes that speaker).
    /// The later meeting is deleted. A transcript is kept only where it is a continuous
    /// prefix of the joined audio, so transcription resumes at the first untranscribed second.
    @discardableResult
    public func merge(_ firstID: UUID, _ secondID: UUID, now: Date = Date()) throws -> Meeting {
        lock.lock(); defer { lock.unlock() }
        guard firstID != secondID else { throw MeetingStoreError.sameMeeting }
        let one = try refreshed(firstID), two = try refreshed(secondID)
        for meeting in [one, two] {
            if meeting.status == .recording { throw MeetingStoreError.stillRecording }
            if meeting.status == .transcribing { throw MeetingStoreError.busy }
        }
        let ordered = one.createdAt <= two.createdAt ? (one, two) : (two, one)
        var earlier = ordered.0
        let later = ordered.1
        let offset = earlier.duration
        let earlierComplete = earlier.transcribedThrough >= offset - 0.05
        let laterComplete = later.transcribedThrough >= later.duration - 0.05

        // Audio: move the later parts in under fresh names. An empty or missing part has nothing
        // to move. If a move fails, the ones already moved go back, so a failed merge leaves both
        // meetings as they were instead of orphaning audio in the earlier folder.
        var moved: [MeetingAudioPart] = []
        var undo: [(from: URL, to: URL)] = []
        do {
            for part in later.parts where part.bytes >= 2 {
                let name = nextPartName(in: earlier, extra: moved)
                let source = folder(later.id).appendingPathComponent(part.fileName)
                let target = folder(earlier.id).appendingPathComponent(name)
                try FileManager.default.moveItem(at: source, to: target)
                undo.append((target, source))
                moved.append(MeetingAudioPart(fileName: name, bytes: part.bytes))
            }
        } catch {
            for step in undo.reversed() { try? FileManager.default.moveItem(at: step.from, to: step.to) }
            throw error
        }
        // A crash from here until the later meeting is deleted is repaired on the next launch
        // by `recoverInterrupted` (see `repairParts`).

        // Speakers: map the later meeting's ids into the earlier meeting's space.
        var mapping: [String: String] = [:]
        var speakers = earlier.speakers
        var nextNumber = (speakers.compactMap { Int($0.id.dropFirst()) }.max() ?? 0) + 1
        for speaker in later.speakers {
            if speaker.isMe, let me = speakers.first(where: { $0.isMe }) {
                mapping[speaker.id] = me.id
            } else if let name = speaker.name?.lowercased(), !name.isEmpty,
                      let same = speakers.first(where: { $0.name?.lowercased() == name }) {
                mapping[speaker.id] = same.id
            } else {
                let newID = "S\(nextNumber)"
                nextNumber += 1
                mapping[speaker.id] = newID
                var copy = speaker
                copy.id = newID
                if copy.isMe && speakers.contains(where: { $0.isMe }) { copy.isMe = false }
                speakers.append(copy)
            }
        }
        // A segment voice the later meeting does not list would otherwise keep its raw id and
        // could land on a different person of the earlier meeting with the same id.
        for raw in Set(later.segments.compactMap(\.speaker)).sorted() where mapping[raw] == nil {
            let newID = "S\(nextNumber)"
            nextNumber += 1
            mapping[raw] = newID
            speakers.append(MeetingSpeaker(id: newID))
        }
        let shifted = later.segments.map {
            MeetingSegment(start: $0.start + offset, end: $0.end + offset,
                           speaker: $0.speaker.flatMap { mapping[$0] ?? $0 }, text: $0.text)
        }

        earlier.parts += moved
        earlier.recordingNotice = [earlier.recordingNotice, later.recordingNotice]
            .compactMap { $0 }.joined(separator: "\n")
        if earlier.recordingNotice?.isEmpty == true { earlier.recordingNotice = nil }
        earlier.speakers = speakers
        let laterGaps = (later.gaps ?? []).map { MeetingGap(at: $0.at + offset, seconds: $0.seconds, reason: $0.reason) }
        if !laterGaps.isEmpty { earlier.gaps = (earlier.gaps ?? []) + laterGaps }
        // Only a transcribed prefix can be resumed: when the earlier meeting is unfinished, the
        // later transcript cannot sit after its gap and is redone with the rest.
        if earlierComplete {
            earlier.transcribedThrough = offset
            if laterComplete {
                earlier.segments += shifted
                earlier.transcribedThrough = offset + later.duration
            }
        }
        earlier.turns = nil
        // The hint described one recording, not the newly combined set of voices.
        earlier.expectedSpeakerCount = nil
        earlier.speakerNotice = nil
        let total = earlier.duration
        earlier.status = earlier.transcribedThrough >= total - 0.05 && !earlier.segments.isEmpty ? .done : .recorded
        earlier.progress = total > 0 ? min(earlier.transcribedThrough / total, 1) : 0
        // Each part was diarized on its own, so one voice can carry two numbers.
        earlier.message = earlier.status == .done && !one.speakers.isEmpty && !two.speakers.isEmpty
            ? "Speakers in each part are numbered separately. Give the same person the same name, or Transcribe again to match voices across the whole meeting (names start over)."
            : nil
        earlier.updatedAt = now
        do { try save(earlier) } catch {
            for step in undo.reversed() { try? FileManager.default.moveItem(at: step.from, to: step.to) }
            throw error
        }
        try delete(later.id)
        return earlier
    }

    // MARK: Private

    /// The stored meeting with part sizes re-read from disk.
    private func refreshed(_ id: UUID) throws -> Meeting {
        var meeting = try load(id)
        for index in meeting.parts.indices {
            let url = folder(id).appendingPathComponent(meeting.parts[index].fileName)
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
            meeting.parts[index].bytes = size - size % 2
        }
        return meeting
    }

    private func nextPartName(in meeting: Meeting, extra: [MeetingAudioPart] = []) -> String {
        let used = Set((meeting.parts + extra).map(\.fileName))
        var number = meeting.parts.count + extra.count + 1
        while used.contains("part-\(number).pcm")
                || FileManager.default.fileExists(atPath: folder(meeting.id).appendingPathComponent("part-\(number).pcm").path) {
            number += 1
        }
        return "part-\(number).pcm"
    }

    private func metadataURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("meeting.json") }

    private func load(_ id: UUID) throws -> Meeting {
        guard let data = try? Data(contentsOf: metadataURL(id)) else { throw MeetingStoreError.notFound }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Meeting.self, from: data)
    }

    private func save(_ meeting: Meeting) throws {
        try prepare(folder(meeting.id))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(meeting)
        #if os(iOS)
        try data.write(to: metadataURL(meeting.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: metadataURL(meeting.id), options: .atomic)
        #endif
        let handle = try FileHandle(forWritingTo: metadataURL(meeting.id))
        defer { try? handle.close() }
        try handle.synchronize()
        if meeting.status == .done { Self.announceFinishedChange() }
    }

    /// Posted when a meeting with a finished transcript is saved, and when a meeting is deleted.
    /// Not posted for a recording or a transcription in progress, which save many times a minute.
    public static let finishedMeetingDidChange = Notification.Name("ZoneFinishedMeetingDidChange")

    /// Posted from another queue: a store call holds the store's lock, and an observer that
    /// waits on another thread must never be able to wait on that lock.
    private static func announceFinishedChange() {
        DispatchQueue.global(qos: .utility).async {
            NotificationCenter.default.post(name: finishedMeetingDidChange, object: nil)
        }
    }

    private func prepare(_ url: URL) throws {
        for target in [directory, url] {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = target
            try mutable.setResourceValues(values)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                  ofItemAtPath: target.path)
            #endif
        }
    }
}
