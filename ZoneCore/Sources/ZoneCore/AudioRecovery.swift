// by zayd/cold @ zayd.wtf

import Foundation
import Darwin
import OSLog

public struct AudioRecoveryRecord: Codable, Identifiable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case recording, available, failed, retrying, textReady, noWords }
    public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var engine: String
    public var source: TranscriptSource
    public var state: State
    public var expiresAt: Date?
    public var message: String?
    public var text: String
    /// An explicit keyboard handoff keeps the original WAV until the person deletes it.
    public var keyboardHandoff: Bool? = nil
    public var audioBytes: Int64
    // Missing history means this recording predates attempt tracking.
    public var attempts: AudioAttempts?
    public var levels: RecoveryLevels?
    /// PCM length captured in the receipt before a successful recognition released its audio.
    public var recordedBytes: Int64? = nil
    public var audioSeconds: Double {
        let samples = max(max(audioBytes, recordedBytes ?? 0) / 2, Int64(levels?.samples ?? 0))
        return Double(samples) / 16_000
    }
}

public struct AudioAttempts: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case noWords, modelFailed, interrupted, transcribed
    }
    public var count: Int
    public var lastTry: Date?
    public var outcome: Outcome?
    // A retry of an older file only establishes a lower bound.
    public var earlierUnknown: Bool
}

public struct RecoveryLevels: Codable, Equatable, Sendable {
    public let peakDB: Double
    public let averageDB: Double
    public let activeSeconds: Double
    public let samples: Int
    public var soundsLikeSpeech: Bool { activeSeconds >= 0.2 }

    /// RMS above -48 dBFS in 20 ms windows. Music and noise can cross it too.
    public static func measure(_ url: URL) throws -> Self {
        let reader = try AudioRecoveryReader(url: url)
        var peak = 0.0, sum = 0.0, window = 0.0
        var total = 0, active = 0, count = 0
        func finishWindow() {
            if window >= Double(count) * pow(10, -4.8) { active += count }
            window = 0
            count = 0
        }
        while true {
            let chunk = try reader.read()
            if chunk.isEmpty { break }
            for sample in chunk {
                let value = Double(sample)
                peak = max(peak, abs(value))
                window += value * value
                sum += value * value
                total += 1
                count += 1
                if count == 320 { finishWindow() }
            }
        }
        if count > 0 { finishWindow() }
        guard total > 0 else { throw AudioRecoveryError.missingAudio }
        func db(_ value: Double) -> Double { 20 * log10(max(value, 0.000001)) }
        return Self(peakDB: db(peak), averageDB: db(sqrt(sum / Double(total))),
                    activeSeconds: Double(active) / 16_000, samples: total)
    }
}

public enum AudioRecoveryError: LocalizedError {
    case unavailable, writerOverloaded, emptyTranscript, missingAudio
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Free up space on your iPhone and try recording again."
        case .writerOverloaded: return "Storage could not keep up with recording. Check Home for audio and free up space before trying again."
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
    /// A deliberate note keeps every delivered sample, even when the model returns no words.
    public static let minimumNoteSeconds: Double = 1.0 / 16_000
    private let lock = NSRecursiveLock()
    private let fallbackDirectory: URL?
    public init(directory: URL, fallbackDirectory: URL? = nil) {
        self.directory = directory
        self.fallbackDirectory = fallbackDirectory
    }

    // A new process finds fallback recordings by their files, including text-only receipts.
    private func folder(for id: UUID) -> URL {
        if let fallbackDirectory, ["json", "pcm"].contains(where: {
            FileManager.default.fileExists(atPath: fallbackDirectory.appendingPathComponent(id.uuidString + "." + $0).path)
        }) { return fallbackDirectory }
        return directory
    }

    public func audioURL(_ id: UUID) -> URL { folder(for: id).appendingPathComponent(id.uuidString + ".pcm") }
    private func metadataURL(_ id: UUID) -> URL { folder(for: id).appendingPathComponent(id.uuidString + ".json") }

    public func begin(id: UUID, engine: String, source: TranscriptSource, attempting: Bool = false, now: Date = Date(), dateFromFirstSample: Bool = false) throws -> AudioRecoveryWriter {
        lock.lock(); defer { lock.unlock() }
        guard !FileManager.default.fileExists(atPath: audioURL(id).path),
              !FileManager.default.fileExists(atPath: metadataURL(id).path) else { throw CocoaError(.fileWriteFileExists) }
        let record = AudioRecoveryRecord(id: id, createdAt: now, updatedAt: now, engine: engine, source: source,
                                         state: .recording, expiresAt: nil, message: nil, text: "", audioBytes: 0,
                                         attempts: AudioAttempts(count: attempting ? 1 : 0, lastTry: attempting ? now : nil,
                                                                 outcome: nil, earlierUnknown: false))
        for target in [directory, fallbackDirectory].compactMap({ $0 }) {
            let metadata = target.appendingPathComponent(id.uuidString + ".json")
            do {
                try save(record, in: target)
                return try AudioRecoveryWriter(store: self, id: id, dateFromFirstSample: dateFromFirstSample)
            } catch {
                // This start owns these new paths and has not installed a microphone callback.
                try? FileManager.default.removeItem(at: metadata)
                try? FileManager.default.removeItem(at: target.appendingPathComponent(id.uuidString + ".pcm"))
            }
        }
        throw AudioRecoveryError.unavailable
    }

    /// Home uses its original recovery store, including older app-only files. A keyboard
    /// recording crosses from the group inbox only after its writer releases the file.
    public func importKeyboardAudio(from inbox: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: inbox.path) else { return }
        var firstError: Error?
        for url in try fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.creationDateKey]) {
            guard url.pathExtension == "wav", let id = KeyboardCapture.audioID(fromName: url.lastPathComponent),
                  let claim = KeyboardAudioFile.lock(url) else { continue }
            defer { try? claim.close() }
            do {
                try prepareDirectory()
                try importKeyboardFile(url, id: id, handle: claim)
            } catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }

    private func importKeyboardFile(_ url: URL, id: UUID, handle: FileHandle) throws {
        let fm = FileManager.default
        let handoff = url.lastPathComponent == KeyboardCapture.handoffName(id)
        let original = directory.appendingPathComponent(id.uuidString + ".wav")
        func finishImport() throws {
            if handoff && !fm.fileExists(atPath: original.path) { try fm.moveItem(at: url, to: original) }
            else { try fm.removeItem(at: url) }
        }
        let staged = directory.appendingPathComponent(".keyboard-" + id.uuidString)
        defer { try? fm.removeItem(at: staged) }
        try KeyboardAudioFile.prepareToRead(url, handle: handle)
        guard fm.createFile(atPath: staged.path, contents: nil) else { throw AudioRecoveryError.unavailable }
        let output = try FileHandle(forWritingTo: staged)
        defer { try? output.close() }
        try KeyboardAudioFile.convert(url, to: output)
        lock.lock()
        defer { lock.unlock() }
        guard fm.fileExists(atPath: url.path) else { return } // An explicit erase won during conversion.
        // A writer can leave a zero-byte PCM, or a successful receipt can have released it.
        // Publish the converted handoff before retiring the inbox WAV in either case.
        func installPCMIfNeeded() throws {
            guard bytes(id) < 2 else { return }
            let destination = audioURL(id)
            try output.synchronize()
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: destination)
            }
        }
        if var existing = try? read(id), (existing.state == .textReady && !existing.text.isEmpty) || bytes(id) >= 2 {
            // Import was interrupted after publishing this ID. Preserve any newer retry or text receipt.
            if handoff, bytes(id) < 2 {
                guard try output.offset() >= 2 else { throw AudioRecoveryError.missingAudio }
                try installPCMIfNeeded()
            }
            if handoff, existing.keyboardHandoff != true || existing.expiresAt != nil {
                existing.keyboardHandoff = true
                existing.expiresAt = nil
                try save(existing)
            }
            try finishImport()
            return
        }
        guard try output.offset() >= 2 || !handoff else { throw AudioRecoveryError.missingAudio }
        if try output.offset() >= 2 {
            try installPCMIfNeeded()
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            var record = AudioRecoveryRecord(id: id, createdAt: created, updatedAt: Date(), engine: "zoneMini",
                source: .keyboard, state: .available, expiresAt: handoff ? nil : Date().addingTimeInterval(Self.failedRetention),
                message: "Your keyboard recording was saved. Tap to transcribe it.", text: "", keyboardHandoff: handoff, audioBytes: bytes(id))
            do { record.attempts = try KeyboardAudioAttempts.read(from: url) }
            catch {
                Logger(subsystem: "wtf.zayd.zone", category: "AudioRecovery").error("Could not read keyboard attempt history: \((error as NSError).code, privacy: .public)")
            }
            try save(record)
        }
        try finishImport()
    }

    /// The keyboard can save its transcript while a newer field prevents publishing the
    /// insertion. Its retained WAV then reaches the app. Keep the existing words and engine.
    public func reconcileKeyboardHandoffs(with history: TranscriptHistory) throws {
        let finished: Set<TranscriptStatus> = [.finished, .inserted, .offered, .dismissed]
        let handoffs = try records().filter { $0.keyboardHandoff == true && ($0.state == .available || $0.state == .textReady) }
        guard !handoffs.isEmpty else { return }
        let transcripts = history.records(withIDs: Set(handoffs.map(\.id)))
        for record in handoffs {
            guard let transcript = transcripts[record.id], transcript.source == .keyboard,
                  finished.contains(transcript.status),
                  !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            lock.lock()
            defer { lock.unlock() }
            guard var current = try? read(record.id), current.keyboardHandoff == true else { continue }
            if current.state == .available {
                try complete(record.id, text: transcript.text, engine: transcript.engine)
            } else if current.state == .textReady, current.engine == "zoneMini",
                      current.text == transcript.text, current.engine != transcript.engine {
                // Older releases imported the WAV before associating its actual recognizer.
                current.engine = transcript.engine
                try save(current)
            }
        }
    }

    private func recordingFiles(requireAllFolders: Bool = false) throws -> [URL] {
        var files: [URL] = []
        var firstError: Error?
        var readable = false
        for folder in [directory, fallbackDirectory].compactMap({ $0 }) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            do {
                files += try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])
                readable = true
            } catch { if firstError == nil { firstError = error } }
        }
        if let firstError, requireAllFolders || !readable { throw firstError }
        return files
    }

    public func records() throws -> [AudioRecoveryRecord] {
        lock.lock(); defer { lock.unlock() }
        let files = try recordingFiles()
        let ids = Set(files.compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) })
        return ids.compactMap { id in
            if var record = try? read(id) {
                record.recordedBytes = max(record.recordedBytes ?? 0, record.audioBytes)
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
                if (record.attempts?.count ?? 0) > 0, record.attempts?.outcome == nil { record.attempts?.outcome = .interrupted }
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
            if record.keyboardHandoff == true { continue }
            if record.state == .textReady {
                try removeAudio(record.id) // Also repairs a crash between receipt commit and unlink.
                continue
            }
            // No clamping of far-future expiries: this process cannot tell a clock that ran ahead
            // when the record was written from one that is behind now, and clamping in the second
            // case deletes the only copy of a failed recording early. A visible card that lives
            // too long is the safer error.
            guard record.state == .failed || record.state == .noWords || record.state == .available, let expiry = record.expiresAt, expiry <= now else { continue }
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

    /// A visible Home card and at least one complete sample survived the final write.
    public func hasRetainedAudio(_ id: UUID) -> Bool {
        lock.withLock {
            guard let record = try? read(id), [.failed, .available, .noWords].contains(record.state) else { return false }
            return bytes(id) >= 2
        }
    }

    public func markFailed(_ id: UUID, text: String, message: String, outcome: AudioAttempts.Outcome = .modelFailed, now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        var record = try read(id)
        guard record.state != .textReady || record.text.isEmpty else { return }
        if (record.attempts?.count ?? 0) > 0, record.attempts?.outcome == nil { record.attempts?.outcome = outcome }
        record.state = .failed
        record.updatedAt = now
        record.expiresAt = now.addingTimeInterval(Self.failedRetention)
        if !text.isEmpty { record.text = text }
        record.message = message
        record.audioBytes = bytes(id)
        try save(record)
    }

    /// Scan off the main thread and outside the writer lock. Recheck before committing
    /// so deleting or retrying the recording during a scan cannot restore stale metadata.
    @discardableResult public func fillLevels(_ id: UUID) throws -> RecoveryLevels? {
        let needsLevels = try lock.withLock {
            let record = try read(id)
            return [.failed, .noWords, .available].contains(record.state) && record.levels == nil && bytes(id) >= 2
        }
        guard needsLevels else { return try lock.withLock { try read(id).levels } }
        let levels = try RecoveryLevels.measure(audioURL(id))
        return try lock.withLock {
            var record = try read(id)
            guard [.failed, .noWords, .available].contains(record.state), record.levels == nil, bytes(id) / 2 == levels.samples else { return record.levels }
            record.levels = levels
            try save(record)
            return levels
        }
    }

    /// Writes a temporary playable copy for the share sheet. The caller removes it on dismissal.
    public func exportWave(_ id: UUID) throws -> URL {
        let input = try FileHandle(forReadingFrom: audioURL(id))
        defer { try? input.close() }
        let length = try input.seekToEnd() / 2 * 2
        guard length >= 2, length <= UInt32.max - 36 else { throw AudioRecoveryError.unavailable }
        try input.seek(toOffset: 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Recording-" + UUID().uuidString + ".wav")
        do {
            let header = PCMWave.header(bytes: Int(length), sampleRate: 16_000)
            #if os(iOS)
            try header.write(to: url, options: [.withoutOverwriting, .completeFileProtection])
            #else
            try header.write(to: url, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            #endif
            let output = try FileHandle(forWritingTo: url)
            defer { try? output.close() }
            try output.seekToEnd()
            var left = length
            while left > 0 {
                guard let data = try input.read(upToCount: Int(min(65_536, left))), !data.isEmpty else {
                    throw AudioRecoveryError.missingAudio
                }
                try output.write(contentsOf: data)
                left -= UInt64(data.count)
            }
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Loading a model for a saved clip takes ownership but does not count as a try.
    public func prepareRetry(_ id: UUID, now: Date = Date()) throws -> AudioRecoveryRecord {
        lock.lock(); defer { lock.unlock() }
        var record = try read(id)
        guard bytes(id) >= 2 else { throw AudioRecoveryError.missingAudio }
        record.state = .retrying
        record.expiresAt = nil
        record.updatedAt = now
        try save(record)
        return record
    }

    fileprivate func firstLiveSubmission(_ id: UUID, now: Date) throws {
        lock.lock(); defer { lock.unlock() }
        var record = try read(id)
        guard record.attempts?.count == 0 else { return }
        record.attempts = AudioAttempts(count: 1, lastTry: now, outcome: nil, earlierUnknown: false)
        try save(record)
    }

    public func beginRetry(_ id: UUID, now: Date = Date()) throws -> AudioRecoveryRecord {
        lock.lock(); defer { lock.unlock() }
        var record = try read(id)
        guard bytes(id) >= 2 else { throw AudioRecoveryError.missingAudio }
        var attempts = record.attempts ?? AudioAttempts(count: 0, lastTry: nil, outcome: nil, earlierUnknown: true)
        attempts.count += 1
        attempts.lastTry = now
        attempts.outcome = nil
        record.attempts = attempts
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
    /// `shortUnder` is how brief "short" is. A voice note passes `minimumNoteSeconds`: a note is
    /// something the person meant to keep, so even a five second reminder the model heard no
    /// words in keeps its audio for a retry. Only an empty file goes.
    public func complete(_ id: UUID, text: String, engine: String? = nil, discardShortEmpty: Bool = false,
                         shortUnder: Double = AudioRecoveryStore.minimumRetainedSeconds, now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        // A replay must preserve the first committed words. An intentional retry first enters .retrying.
        if let previous = try? read(id), previous.state == .textReady, !previous.text.isEmpty {
            if previous.keyboardHandoff != true { try removeAudio(id) }
            return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if discardShortEmpty, Double(bytes(id) / 2) / 16_000 < shortUnder {
                try discard(id)
                return
            }
            var record = try read(id)
            if (record.attempts?.count ?? 0) > 0, record.attempts?.outcome == nil { record.attempts?.outcome = .noWords }
            record.state = .noWords
            record.updatedAt = now
            record.audioBytes = bytes(id)
            record.expiresAt = now.addingTimeInterval(Self.failedRetention)
            record.message = "No words heard. Your audio is saved."
            try save(record)
            if discardShortEmpty { return }
            throw AudioRecoveryError.emptyTranscript
        }
        var record = try read(id)
        record.attempts?.outcome = .transcribed
        record.state = .textReady
        if let engine { record.engine = engine }
        record.text = text
        record.updatedAt = now
        record.expiresAt = nil
        record.message = nil
        let remainingBytes = bytes(id)
        record.recordedBytes = max(record.recordedBytes ?? 0, record.audioBytes, remainingBytes)
        record.audioBytes = remainingBytes
        try save(record)
        if record.keyboardHandoff != true { try removeAudio(id) }
    }

    /// Call only after retained History/Notes is durable, or an explicit use/dismiss/delete.
    public func eraseRecordings() throws {
        lock.lock()
        defer { lock.unlock() }
        var firstError: Error?
        for file in try recordingFiles(requireAllFolders: true)
        where ["pcm", "json", "wav"].contains(file.pathExtension) && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
            do { try FileManager.default.removeItem(at: file) }
            catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }

    public func discard(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        // A keyboard handoff can put the original WAV in shared storage while the PCM
        // and receipt are still in the fallback directory. Keep receipts until audio is gone.
        for ext in ["pcm", "wav", "json"] {
            for folder in [directory, fallbackDirectory].compactMap({ $0 }) {
                let url = folder.appendingPathComponent(id.uuidString).appendingPathExtension(ext)
                if unlink(url.path) != 0 {
                    let code = errno
                    guard code == ENOENT || code == ENOTDIR else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
                    }
                }
            }
        }
    }

    public func consumeTextReceipt(_ id: UUID, matching text: String? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard let record = try? read(id), record.state == .textReady, record.keyboardHandoff != true,
              text == nil || text == record.text else { return }
        try discard(id)
    }

    fileprivate func progress(_ id: UUID, firstSample: Date? = nil, now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        var record = try read(id)
        if let firstSample { record.createdAt = firstSample }
        record.audioBytes = bytes(id)
        record.updatedAt = now
        try save(record)
    }
    /// Metadata that cannot be decoded and has no audio beside it is invisible to `records()`
    /// and would otherwise stay on disk forever.
    private func removeUnreadableEmptyMetadata(activeIDs: Set<UUID>) {
        guard let files = try? recordingFiles() else { return }
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
        var record = try JSONDecoder().decode(AudioRecoveryRecord.self, from: Data(contentsOf: metadataURL(id)))
        // An older interrupted handoff may have archived the original without flagging the receipt.
        if record.keyboardHandoff != true, record.source == .keyboard,
           FileManager.default.fileExists(atPath: directory.appendingPathComponent(id.uuidString + ".wav").path) {
            record.keyboardHandoff = true
            record.expiresAt = nil
        }
        return record
    }
    private func prepareDirectory(_ target: URL? = nil) throws {
        let directory = target ?? self.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
    }
    private func save(_ record: AudioRecoveryRecord, in target: URL? = nil) throws {
        let directory = target ?? folder(for: record.id)
        let url = directory.appendingPathComponent(record.id.uuidString + ".json")
        try prepareDirectory(directory)
        let data = try JSONEncoder().encode(record)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
    private func removeAudio(_ id: UUID) throws {
        if FileManager.default.fileExists(atPath: audioURL(id).path) { try FileManager.default.removeItem(at: audioURL(id)) }
    }
}

/// A bounded background writer. No file IO or whole-utterance accumulation on the audio thread.
public final class AudioRecoveryWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "wtf.zayd.zone.audio-recovery", qos: .userInitiated)
    private let lock = NSLock()
    private let store: AudioRecoveryStore
    private let id: UUID
    private let handle: FileHandle
    public let submission: AudioModelSubmission
    private var accepted = 0
    private var written = 0
    public var acceptedSamples: Int { lock.withLock { accepted } }
    public var flushedSamples: Int { lock.withLock { written } }
    private let dateFromFirstSample: Bool
    private var queuedSamples = 0
    private var closed = false
    private var storedFailure: Error?
    private var sinceMetadata = 0 // writer queue only
    private var writeFailed = false
    private var finishResult: Result<Void, Error>?
    public let maxQueuedSamples: Int
    public var failure: Error? { lock.withLock { storedFailure } }

    fileprivate init(store: AudioRecoveryStore, id: UUID, dateFromFirstSample: Bool, maxQueuedSamples: Int = 160_000) throws {
        self.dateFromFirstSample = dateFromFirstSample
        self.store = store; self.id = id; self.maxQueuedSamples = maxQueuedSamples
        submission = AudioModelSubmission { try store.firstLiveSubmission(id, now: Date()) }
        guard FileManager.default.createFile(atPath: store.audioURL(id).path, contents: nil) else { throw AudioRecoveryError.unavailable }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: store.audioURL(id).path)
        #endif
        handle = try FileHandle(forWritingTo: store.audioURL(id))
    }

    public func append(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        guard !samples.isEmpty, !closed, storedFailure == nil else { return }
        guard samples.count <= maxQueuedSamples - queuedSamples else {
            storedFailure = AudioRecoveryError.writerOverloaded
            return
        }
        let firstSample = accepted == 0 ? Date() : nil
        if firstSample != nil { PressTiming.mark("firstAppend") }
        accepted += samples.count
        queuedSamples += samples.count
        // Enqueue while admission is locked so finish cannot overtake accepted samples.
        queue.async { [self] in
            defer { lock.withLock { queuedSamples -= samples.count } }
            guard !writeFailed else { return }
            do {
                let data = PCM16.encode(samples)
                try handle.write(contentsOf: data)
                sinceMetadata += samples.count
                let total = lock.withLock {
                    written += samples.count
                    return written
                }
                if total == samples.count { PressTiming.mark("written") }
                try handle.synchronize()
                if total == samples.count { PressTiming.mark("synced") }
                if total == samples.count || sinceMetadata >= 32_000 {
                    sinceMetadata = 0
                    // The metadata's byte count is a hint (`records()` re-reads the file size), so
                    // a failed refresh must not stop the PCM, which is the actual safety net.
                    try? store.progress(id, firstSample: dateFromFirstSample ? firstSample : nil)
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

public final class AudioModelSubmission: @unchecked Sendable {
    private let lock = NSLock()
    private var write: (@Sendable () throws -> Void)?

    public init(_ write: @escaping @Sendable () throws -> Void) { self.write = write }

    public func record() throws {
        try lock.withLock {
            try write?()
            write = nil
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
