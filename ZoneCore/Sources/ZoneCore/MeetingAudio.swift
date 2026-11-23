// by zayd/cold @ zayd.wtf

import Foundation

/// Writes one meeting audio part: PCM16 little-endian, 16 kHz mono, appended as it arrives.
///
/// Built for hours, not seconds. The audio thread only copies samples into a serial queue; the
/// queue encodes, writes and every `syncEvery` samples (5 s) forces the bytes to storage, so a
/// crash, a kill or a dead battery loses at most the last few seconds. Past `maxQueuedSamples`
/// of backlog (30 s, a stalled disk) new audio is dropped and counted rather than growing
/// memory or stopping the recording.
public final class MeetingAudioWriter: @unchecked Sendable {
    public static let syncEvery = 5 * 16_000
    private let queue = DispatchQueue(label: "wtf.zayd.zone.meeting-audio", qos: .utility)
    private let lock = NSLock()
    private let handle: FileHandle
    public let url: URL
    public let maxQueuedSamples: Int
    private var queuedSamples = 0
    private var closed = false
    private var storedFailure: Error?
    private var dropped = 0
    private var written = 0
    private var sinceSync = 0 // queue only
    private var finishResult: Result<Void, Error>?

    public var failure: Error? { lock.withLock { storedFailure } }
    /// Samples refused because the writer fell behind.
    public var droppedSamples: Int { lock.withLock { dropped } }
    /// Samples handed to the file so far (written, not necessarily synced).
    public var writtenSamples: Int { lock.withLock { written } }

    public init(url: URL, maxQueuedSamples: Int = 30 * 16_000) throws {
        self.url = url
        self.maxQueuedSamples = maxQueuedSamples
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw AudioRecoveryError.unavailable }
        }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        handle = try FileHandle(forWritingTo: url)
        let end = try handle.seekToEnd()
        // A part reopened after a crash can end in a torn half sample. Appending after it would
        // shift every later sample by one byte and turn the rest of the meeting into noise.
        if end % 2 == 1 {
            try handle.truncate(atOffset: end - 1)
            try handle.seekToEnd()
        }
    }

    /// Safe on the audio thread: no file IO, one lock, one enqueue.
    @discardableResult
    public func append(_ samples: [Float]) -> Int {
        guard !samples.isEmpty else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        guard !closed, storedFailure == nil else { return 0 }
        guard samples.count <= maxQueuedSamples - queuedSamples else {
            dropped += samples.count
            return 0
        }
        queuedSamples += samples.count
        queue.async { [self] in
            defer { lock.withLock { queuedSamples -= samples.count } }
            guard lock.withLock({ storedFailure == nil }) else { return }
            do {
                try handle.write(contentsOf: PCM16.encode(samples))
                lock.withLock { written += samples.count }
                sinceSync += samples.count
                if sinceSync >= Self.syncEvery {
                    try handle.synchronize()
                    sinceSync = 0
                }
            } catch {
                lock.withLock { if storedFailure == nil { storedFailure = error } }
            }
        }
        return samples.count
    }

    /// Writes everything accepted so far, syncs and closes. Idempotent.
    public func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            closed = true
            queue.async { [self] in
                if let finishResult { continuation.resume(with: finishResult); return }
                let result = Result<Void, Error> {
                    defer { try? handle.close() }
                    try handle.synchronize()
                    if let failure { throw failure }
                }
                finishResult = result
                continuation.resume(with: result)
            }
            lock.unlock()
        }
    }
}

/// Random-access reads across a meeting's audio parts as one continuous 16 kHz signal.
/// Never loads the whole recording: six hours of PCM16 is about 691 MB on disk.
public final class MeetingAudio: @unchecked Sendable {
    public enum ReadError: LocalizedError {
        case truncated
        public var errorDescription: String? { "The meeting audio changed or could not be read completely. The transcript was stopped to avoid missing speech." }
    }
    public static let sampleRate = 16_000
    private let lock = NSLock()
    private let parts: [(handle: FileHandle, start: Int, count: Int)]
    public let sampleCount: Int
    public var duration: Double { Double(sampleCount) / Double(Self.sampleRate) }

    public init(urls: [URL]) throws {
        var built: [(FileHandle, Int, Int)] = []
        var cursor = 0
        for url in urls {
            let size = ((try FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
            let count = size / 2
            guard count > 0 else { continue }
            built.append((try FileHandle(forReadingFrom: url), cursor, count))
            cursor += count
        }
        parts = built.map { (handle: $0.0, start: $0.1, count: $0.2) }
        sampleCount = cursor
    }

    deinit { for part in parts { try? part.handle.close() } }

    /// Samples `[offset, offset + count)`, clipped to the recording.
    public func read(offset: Int, count: Int) throws -> [Float] {
        let start = max(0, offset), end = min(sampleCount, offset + max(0, count))
        guard end > start else { return [] }
        var out = [Float](repeating: 0, count: end - start)
        try out.withUnsafeMutableBufferPointer { buffer in
            try copySamples(into: buffer.baseAddress!, offset: start, count: end - start)
        }
        return out
    }

    /// Fills `destination` with `count` samples from `offset`; past the end it writes silence.
    public func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws {
        lock.lock(); defer { lock.unlock() }
        var written = 0
        var position = offset
        while written < count {
            guard position < sampleCount, position >= 0,
                  let part = parts.first(where: { position >= $0.start && position < $0.start + $0.count }) else {
                destination.advanced(by: written).update(repeating: 0, count: count - written)
                return
            }
            let inPart = position - part.start
            let take = min(count - written, part.count - inPart)
            try part.handle.seek(toOffset: UInt64(inPart * 2))
            var data = Data()
            while data.count < take * 2 {
                guard let next = try part.handle.read(upToCount: take * 2 - data.count), !next.isEmpty else { break }
                data.append(next)
            }
            let got = data.count / 2
            data.withUnsafeBytes { raw in
                for index in 0..<got {
                    let low = UInt16(raw[index * 2]), high = UInt16(raw[index * 2 + 1])
                    destination[written + index] = Float(Int16(bitPattern: low | high << 8)) / 32_767
                }
            }
            guard got == take else { throw ReadError.truncated }
            written += take
            position += take
        }
    }

    /// Root-mean-square level per frame (default 100 ms), read in large blocks. For six hours
    /// this is 216,000 floats; the planner uses it to cut chunks at pauses and skip silence.
    public func levels(frameSamples: Int = 1_600, from: Int = 0, to: Int? = nil) throws -> [Float] {
        try Task.checkCancellation()
        guard frameSamples > 0 else { return [] }
        let end = min(to ?? sampleCount, sampleCount)
        var levels: [Float] = []
        levels.reserveCapacity(max(0, (end - from) / frameSamples + 1))
        var cursor = max(0, from)
        let block = frameSamples * 300
        while cursor < end {
            try Task.checkCancellation()
            let samples = try read(offset: cursor, count: min(block, end - cursor))
            if samples.isEmpty { break }
            var index = 0
            while index < samples.count {
                let stop = min(index + frameSamples, samples.count)
                var sum: Float = 0
                for value in samples[index..<stop] { sum += value * value }
                levels.append((sum / Float(stop - index)).squareRoot())
                index = stop
            }
            cursor += samples.count
        }
        return levels
    }
}
