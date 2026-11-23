// by zayd/cold @ zayd.wtf

import Foundation

public struct AudioRecoveryRecord: Codable, Identifiable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case recording, failed, retrying, textReady }
    public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var engine: String
    public var source: TranscriptSource
    public var state: State
    public var expiresAt: Date?
    public var message: String?
    public var text: String
    public var audioBytes: Int64
    public var audioSeconds: Double { Double(audioBytes / 2) / 16_000 }
}

public enum AudioRecoveryError: LocalizedError {
    case unavailable, writerOverloaded, emptyTranscript, missingAudio
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Couldn't save temporary audio. Live dictation continues, though audio recovery may be incomplete."
        case .writerOverloaded: return "Storage couldn't keep up with temporary audio. Live dictation continues, though recovery may be incomplete."
        case .emptyTranscript: return "No speech recognized. Audio was saved so you can retry."
        case .missingAudio: return "Saved audio is empty and can't be retried."
        }
    }
}

/// App-private PCM16 little-endian, 16kHz mono. Metadata is atomic; PCM needs no finalized header.
/// Completed text receipts survive a History failure/Off until used; only failed audio expires.
public final class AudioRecoveryStore: @unchecked Sendable {
    public let directory: URL
    /// A week. Only real failures are kept (short empty takes are discarded), audio is about
    /// 1.9 MB a minute and excluded from backups, so a forgiving window costs little.
    public static let failedRetention: TimeInterval = 604_800
    /// Below this, a recording that recognized nothing was a mis-tap or silence: there is
    /// nothing to recover, so it is deleted instead of becoming a recovery card. Longer silent
    /// results are kept, because an engine fault on real speech is worth one retry.
    public static let minimumRetainedSeconds: Double = 8
    private let lock = NSRecursiveLock()
    public init(directory: URL) { self.directory = directory }
    public func audioURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".pcm") }
    private func metadataURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }

    public func begin(id: UUID, engine: String, source: TranscriptSource, now: Date = Date()) throws -> AudioRecoveryWriter {
        lock.lock(); defer { lock.unlock() }
        try prepareDirectory()
        guard !FileManager.default.fileExists(atPath: audioURL(id).path) else { throw CocoaError(.fileWriteFileExists) }
        let record = AudioRecoveryRecord(id: id, createdAt: now, updatedAt: now, engine: engine, source: source,
                                         state: .recording, expiresAt: nil, message: nil, text: "", audioBytes: 0)
        try save(record)
        do { return try AudioRecoveryWriter(store: self, id: id) }
        catch {
            try? discard(id) // Creation failed before any samples could be accepted.
            throw error
        }
    }

    public func records() throws -> [AudioRecoveryRecord] {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
        let ids = Set(files.compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) })
        return ids.compactMap { id in
            if var record = try? read(id) {
                record.audioBytes = bytes(id)
                return record
            }
            // An interrupted atomic metadata write must not hide an otherwise usable PCM file.
            guard bytes(id) > 0 else { return nil }
            let date = (try? audioURL(id).resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            return AudioRecoveryRecord(id: id, createdAt: date, updatedAt: date, engine: "", source: .app,
                                       state: .recording, expiresAt: nil, message: "Recovered an interrupted recording.", text: "", audioBytes: bytes(id))
        }.sorted { $0.createdAt > $1.createdAt }
    }

    public func recoverAbandoned(now: Date = Date(), activeIDs: Set<UUID> = []) throws {
        lock.lock(); defer { lock.unlock() }
        removeUnreadableEmptyMetadata(activeIDs: activeIDs)
        for var record in try records() where !activeIDs.contains(record.id) {
            // Killed before the first buffer reached the disk: no audio and no text, so there is
            // nothing to retry. Kept, it became a week-long card whose Retry always failed.
            if (record.state == .recording || record.state == .retrying), record.audioBytes < 2,
               record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try discard(record.id)
                continue
            }
            if record.state == .recording || record.state == .retrying {
                record.state = .failed
                record.updatedAt = now
                record.expiresAt = now.addingTimeInterval(Self.failedRetention)
                record.message = record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? Self.closedMessage : Self.closedWithTextMessage
                try save(record)
            }
        }
        try expire(now: now, activeIDs: activeIDs)
    }

    public func expire(now: Date = Date(), activeIDs: Set<UUID> = []) throws {
        lock.lock(); defer { lock.unlock() }
        for var record in try records() where !activeIDs.contains(record.id) {
            if record.state == .textReady {
                try removeAudio(record.id) // Also repairs a crash between receipt commit and unlink.
                continue
            }
            // No clamping of far-future expiries: this process cannot tell a clock that ran ahead
            // when the record was written from one that is behind now, and clamping in the second
            // case deletes the only copy of a failed recording early. A visible card that lives
            // too long is the safer error.
            guard record.state == .failed, let expiry = record.expiresAt, expiry <= now else { continue }
            if !record.text.isEmpty {
                record.state = .textReady
                record.expiresAt = nil
                record.message = "Temporary audio expired. Recognized text is still saved."
                try save(record)
                try removeAudio(record.id)
            } else {
                try discard(record.id)
            }
        }
    }

    /// The app ended (killed, crashed, out of memory) during a recording and nothing was saved
    /// as text beyond History's last progress save.
    public static let closedMessage = "Zone closed mid-recording. Transcribe the saved audio to recover your words."
    /// Same, after an interruption had already saved what was recognized up to it.
    public static let closedWithTextMessage = "Zone closed mid-recording. Partial text was saved; transcribe the audio again for the rest."

    /// Saves the text recognized so far into a recording still in progress, without changing its
    /// state, so a kill while an interruption holds it still has its words next launch.
    public func checkpoint(_ id: UUID, text: String, now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        var record = try read(id)
        record.text = text
        record.updatedAt = now
        record.audioBytes = bytes(id)
        try save(record)
    }

    public func markFailed(_ id: UUID, text: String, message: String, now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        var record = try read(id)
        record.state = .failed
        record.updatedAt = now
        record.expiresAt = now.addingTimeInterval(Self.failedRetention)
        if !text.isEmpty { record.text = text }
        record.message = message
        record.audioBytes = bytes(id)
        try save(record)
    }

    public func beginRetry(_ id: UUID, now: Date = Date()) throws -> AudioRecoveryRecord {
        lock.lock(); defer { lock.unlock() }
        var record = try read(id)
        guard bytes(id) >= 2 else { throw AudioRecoveryError.missingAudio }
        record.state = .retrying
        record.expiresAt = nil
        record.updatedAt = now
        try save(record)
        record.audioBytes = bytes(id)
        return record
    }

    /// Never removes PCM before a nonempty final transcript has an atomic, synced receipt.
    /// Empty text from a short recording discards it quietly; from a long one it throws
    /// `emptyTranscript` and keeps the audio for a retry.
    /// `discardShortEmpty` is for a live dictation only: a retry of saved audio that comes back
    /// empty keeps its audio, because it is the only copy and another engine may hear it.
    public func complete(_ id: UUID, text: String, discardShortEmpty: Bool = false, now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if discardShortEmpty, Double(bytes(id) / 2) / 16_000 < Self.minimumRetainedSeconds {
                try discard(id)
                return
            }
            try markFailed(id, text: "", message: AudioRecoveryError.emptyTranscript.localizedDescription, now: now)
            throw AudioRecoveryError.emptyTranscript
        }
        var record = try read(id)
        record.state = .textReady
        record.text = text
        record.updatedAt = now
        record.expiresAt = nil
        record.message = nil
        record.audioBytes = bytes(id)
        try save(record)
        try removeAudio(id)
    }

    /// Call only after retained History/Notes is durable, or an explicit use/dismiss/delete.
    public func discard(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try removeAudio(id)
        if FileManager.default.fileExists(atPath: metadataURL(id).path) { try FileManager.default.removeItem(at: metadataURL(id)) }
    }

    public func consumeTextReceipt(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard let record = try? read(id), record.state == .textReady else { return }
        try discard(id)
    }

    fileprivate func progress(_ id: UUID, now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        var record = try read(id)
        record.audioBytes = bytes(id)
        record.updatedAt = now
        try save(record)
    }
    /// Metadata that cannot be decoded and has no audio beside it is invisible to `records()`
    /// and would otherwise stay on disk forever.
    private func removeUnreadableEmptyMetadata(activeIDs: Set<UUID>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !activeIDs.contains(id),
                  (try? read(id)) == nil, bytes(id) < 2 else { continue }
            try? discard(id)
        }
    }
    private func bytes(_ id: UUID) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: audioURL(id).path)[.size]) as? NSNumber)?.int64Value ?? 0
    }
    private func read(_ id: UUID) throws -> AudioRecoveryRecord {
        try JSONDecoder().decode(AudioRecoveryRecord.self, from: Data(contentsOf: metadataURL(id)))
    }
    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
    }
    private func save(_ record: AudioRecoveryRecord) throws {
        try prepareDirectory()
        let data = try JSONEncoder().encode(record)
        #if os(iOS)
        try data.write(to: metadataURL(record.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: metadataURL(record.id), options: .atomic)
        #endif
        let handle = try FileHandle(forWritingTo: metadataURL(record.id))
        defer { try? handle.close() }
        try handle.synchronize()
    }
    private func removeAudio(_ id: UUID) throws {
        if FileManager.default.fileExists(atPath: audioURL(id).path) { try FileManager.default.removeItem(at: audioURL(id)) }
    }
}

/// A bounded background writer. No file IO or whole-utterance accumulation on the audio thread.
public final class AudioRecoveryWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "wtf.zayd.zone.audio-recovery", qos: .utility)
    private let lock = NSLock()
    private let store: AudioRecoveryStore
    private let id: UUID
    private let handle: FileHandle
    private var queuedSamples = 0
    private var closed = false
    private var storedFailure: Error?
    private var sinceSync = 0 // writer queue only
    private var writeFailed = false
    private var finishResult: Result<Void, Error>?
    public let maxQueuedSamples: Int
    public var failure: Error? { lock.withLock { storedFailure } }

    fileprivate init(store: AudioRecoveryStore, id: UUID, maxQueuedSamples: Int = 160_000) throws {
        self.store = store; self.id = id; self.maxQueuedSamples = maxQueuedSamples
        guard FileManager.default.createFile(atPath: store.audioURL(id).path, contents: nil) else { throw AudioRecoveryError.unavailable }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: store.audioURL(id).path)
        #endif
        handle = try FileHandle(forWritingTo: store.audioURL(id))
    }

    public func append(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, storedFailure == nil else { return }
        guard samples.count <= maxQueuedSamples - queuedSamples else {
            storedFailure = AudioRecoveryError.writerOverloaded
            return
        }
        queuedSamples += samples.count
        // Enqueue while admission is locked so finish cannot overtake accepted samples.
        queue.async { [self] in
            defer { lock.withLock { queuedSamples -= samples.count } }
            guard !writeFailed else { return }
            do {
                let data = PCM16.encode(samples)
                try handle.write(contentsOf: data)
                sinceSync += samples.count
                if sinceSync >= 32_000 {
                    try handle.synchronize()
                    sinceSync = 0
                    // The metadata's byte count is a hint (`records()` re-reads the file size), so
                    // a failed refresh must not stop the PCM, which is the actual safety net.
                    try? store.progress(id)
                }
            } catch {
                writeFailed = true
                lock.withLock { if storedFailure == nil { storedFailure = error } }
            }
        }
    }

    public func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            closed = true
            queue.async { [self] in
                if let finishResult { continuation.resume(with: finishResult); return }
                let result = Result<Void, Error> {
                    defer { try? handle.close() }
                    try handle.synchronize()
                    try? store.progress(id) // A hint only; see `append`.
                    if let failure { throw failure }
                }
                finishResult = result
                continuation.resume(with: result)
            }
            lock.unlock()
        }
    }
}

/// Crash-tolerant framing: an incomplete trailing byte is ignored, never interpreted as a sample.
public enum PCM16 {
    public static func encode(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let value = sample.isFinite ? min(max(sample, -1), 1) : 0
            let integer = Int16((value * 32_767).rounded())
            let bits = UInt16(bitPattern: integer)
            data.append(UInt8(truncatingIfNeeded: bits))
            data.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        return data
    }
    public static func decode(_ data: Data) -> [Float] {
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count - bytes.count % 2, by: 2).map {
            Float(Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)) / 32_767
        }
    }
}

/// Bounded retry reads; no whole-recording allocation, and an odd final byte is ignored.
public final class AudioRecoveryReader: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    public init(url: URL) throws { handle = try FileHandle(forReadingFrom: url) }
    deinit { try? handle.close() }
    public func read(maxSamples: Int = 4_096) throws -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let count = min(4_096, max(1, maxSamples)) * 2
        var data = Data()
        while data.count < count {
            guard let next = try handle.read(upToCount: count - data.count), !next.isEmpty else { break }
            data.append(next)
        }
        // A lone byte is discarded only after actual EOF, not a short intermediate read.
        return PCM16.decode(data)
    }
}
