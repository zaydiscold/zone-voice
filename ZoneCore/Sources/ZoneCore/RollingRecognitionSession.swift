// by zayd/cold @ zayd.wtf

import Foundation

/// Batch recognition with ordered rolling segments, bounded queued audio and explicit failure.
/// Recognized text grows with the recording; raw audio is released after each segment and is
/// never written to disk. The injected decoder lets tests exercise real queue/error behavior.
public final class RollingRecognitionSession: @unchecked Sendable {
    private let lock = NSLock()
    private let segmenter: RollingSegmenter
    private let decode: @Sendable ([Float]) async throws -> RecognizedSegment
    private let backlog: RecognitionBacklog
    private var buffer: [Float] = []
    private var totalSamples = 0
    private var segments: [String] = []
    private var doubts: [[DoubtfulWord]] = []
    private var closed = false
    private var chain: Task<Void, Never>?
    private var activeDecode: Task<RecognizedSegment, Error>?

    public convenience init(segmenter: RollingSegmenter = RollingSegmenter(), maxQueuedSeconds: Double = 48,
                            decode: @escaping @Sendable ([Float]) async throws -> String) {
        self.init(segmenter: segmenter, maxQueuedSeconds: maxQueuedSeconds,
                  decodeSegment: { RecognizedSegment(text: try await decode($0)) })
    }

    /// For an engine that also reports which words it was unsure of.
    public init(segmenter: RollingSegmenter = RollingSegmenter(), maxQueuedSeconds: Double = 48,
                decodeSegment: @escaping @Sendable ([Float]) async throws -> RecognizedSegment) {
        self.segmenter = segmenter
        self.decode = decodeSegment
        backlog = RecognitionBacklog(maxSamples: Int(maxQueuedSeconds * 16_000))
    }

    public var failure: RecognitionFailure? { backlog.failure }
    public var pendingSamples: Int { backlog.pendingSamples }
    public var availableSamples: Int { backlog.availableSamples }
    public var audioSeconds: Double { lock.withLock { Double(totalSamples) / 16_000 } }
    public var textSoFar: String { SegmentText.join(lock.withLock { segments }) }
    public var doubtfulWords: [DoubtfulWord] { lock.withLock { doubts.flatMap { $0 } } }

    public func feed(_ samples: [Float]) {
        lock.withLock {
            guard !closed else { return }
            totalSamples += samples.count
            guard backlog.admit(samples.count) else { return }
            buffer.append(contentsOf: samples)
            while let cut = segmenter.cut(buffer), cut > 0 {
                let segment = Array(buffer.prefix(cut))
                buffer.removeFirst(cut)
                enqueue(segment)
            }
        }
    }

    /// Called with lock held. Each task owns its audio until decoding ends or it is skipped.
    private func enqueue(_ segment: [Float]) {
        let previous = chain
        chain = Task { [weak self, backlog, decode] in
            defer { backlog.release(segment.count) }
            await previous?.value
            do {
                try backlog.check()
                let job = Task { try await decode(segment) }
                self?.lock.withLock {
                    self?.activeDecode = job
                    if backlog.failure != nil { job.cancel() }
                }
                defer { self?.lock.withLock { self?.activeDecode = nil } }
                let decoded = try await job.value
                try self?.lock.withLock {
                    try backlog.check()
                    self?.segments.append(decoded.text)
                    self?.doubts.append(decoded.doubts)
                }
            } catch { backlog.fail(error) }
        }
    }

    public func finish() async throws -> String {
        let pending: Task<Void, Never>? = try lock.withLock {
            guard !closed else { throw RecognitionFailure.cancelled }
            closed = true
            if !buffer.isEmpty {
                let rest = buffer
                buffer = []
                enqueue(rest)
            }
            return chain
        }
        await pending?.value
        try backlog.check()
        return textSoFar
    }

    public func cancel() {
        lock.withLock {
            closed = true
            backlog.cancel()
            activeDecode?.cancel()
            backlog.release(buffer.count)
            buffer = []
        }
    }
}

/// One decoded segment: its text and the words in it the engine was unsure of.
public struct RecognizedSegment: Sendable {
    public var text: String
    public var doubts: [DoubtfulWord]

    public init(text: String, doubts: [DoubtfulWord] = []) {
        self.text = text
        self.doubts = doubts
    }
}
