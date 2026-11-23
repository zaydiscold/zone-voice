// by zayd/cold @ zayd.wtf

import Foundation

/// One recognizer run over a stretch of audio: the app's engines (Fluid Speech,
/// Parakeet, Apple) each provide one per utterance.
public protocol RecognitionSession: AnyObject {
    /// Seconds of audio fed so far.
    var audioSeconds: Double { get }
    /// What has been recognized so far, for saving a long dictation as it goes; may lag the
    /// audio and is not the final text (finish() is).
    var textSoFar: String { get }
    /// Sticky failure while recording; the coordinator stops capture and preserves partial text.
    var failure: Error? { get }
    /// Offline diagnostics wait for room; microphone capture cannot block and fails on overload.
    var availableAudioSamples: Int { get }
    func feed(_ samples: [Float])
    /// Flushes the engine and returns the final text (may be empty).
    func finish() async throws -> String
    /// Discards everything; the result is never produced.
    func cancel()
    /// Words the engine was unsure of, in spoken order (`DoubtfulWords`). Empty for engines that
    /// report no confidence.
    var doubtfulWords: [DoubtfulWord] { get }
}

/// Engines without confidence report none. A session that wraps another must forward its
/// `doubtfulWords` itself, or this default hides the inner engine's words (it did, in
/// `LexiconRecognitionSession`, until 2026-11-16).
public extension RecognitionSession {
    var doubtfulWords: [DoubtfulWord] { [] }
}

/// One recording as a run of recognizer utterances, one per stretch between interruptions.
/// An interruption closes the open utterance, so everything heard before it is recognized and
/// final, and the resume opens the next; the recording's text is their join. To the coordinator
/// it is a single `RecognitionSession`, so stop, progress saves and failure handling are unchanged.
///
/// Engines run one utterance at a time, so the next one opens only after the closing one has
/// finished decoding. Audio that arrives in between (the microphone came back first) waits in
/// `pending` and goes to the next utterance before any newer audio. The recovery file gets every
/// sample regardless; it is written before this is fed.
public final class SegmentedRecognition: RecognitionSession, @unchecked Sendable {
    /// Two minutes of 16 kHz audio. Past it, waiting audio is dropped from recognition (the
    /// recovery file still has it) instead of growing without bound.
    public static let pendingLimit = 16_000 * 120
    private static let flushChunk = 4_096

    private let lock = NSLock()
    private var current: RecognitionSession?
    /// The utterance being closed: still counted in `textSoFar` until its words are final.
    private var closingSession: RecognitionSession?
    private var closedText = ""
    private var closedDoubts: [DoubtfulWord] = []
    private var closedSeconds: Double = 0
    private var pending: [Float] = []
    private var pendingStart = 0
    private var droppedSamples = 0
    private var closing: Task<Void, Never>?
    private var opening: Task<Void, Error>?
    private var cancelled = false
    private var stats = Stats()

    public struct Stats: Equatable, Sendable {
        public var segments = 1
        /// Utterances whose final decode failed; what they had recognized is kept.
        public var failedSegments = 0
        public var droppedSeconds: Double = 0
    }

    public init(first: RecognitionSession) {
        current = first
    }

    public var isOpen: Bool { lock.withLock { current != nil } }
    /// No utterance open or closing and no audio waiting: every word heard is final.
    public var isSettled: Bool { lock.withLock { current == nil && closingSession == nil && pending.count == pendingStart } }
    public var summary: Stats { lock.withLock { var s = stats; s.droppedSeconds = Double(droppedSamples) / 16_000; return s } }

    public var audioSeconds: Double {
        lock.withLock {
            closedSeconds + (closingSession?.audioSeconds ?? 0) + (current?.audioSeconds ?? 0)
                + Double(pending.count - pendingStart) / 16_000
        }
    }

    public var doubtfulWords: [DoubtfulWord] {
        lock.withLock { closedDoubts + (closingSession?.doubtfulWords ?? []) + (current?.doubtfulWords ?? []) }
    }

    public var textSoFar: String {
        lock.withLock {
            SegmentText.join(SegmentText.join(closedText, closingSession?.textSoFar ?? ""), current?.textSoFar ?? "")
        }
    }

    public var failure: Error? { lock.withLock { current?.failure } }

    public var availableAudioSamples: Int {
        lock.withLock { current?.availableAudioSamples ?? max(0, Self.pendingLimit - (pending.count - pendingStart)) }
    }

    /// Audio thread. Inside the lock, so a flush of waiting audio can never be overtaken.
    public func feed(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return }
        if let current {
            current.feed(samples)
        } else if pending.count - pendingStart + samples.count <= Self.pendingLimit {
            pending.append(contentsOf: samples)
        } else {
            droppedSamples += samples.count
        }
    }

    /// Ends the open utterance and waits until its words are final. Safe to call when none is open.
    public func closeSegment() async {
        if let earlier = lock.withLock({ closing }) { await earlier.value }
        let session: RecognitionSession? = lock.withLock {
            let open = current
            current = nil
            closingSession = open
            return open
        }
        guard let session else { return }
        let task = Task { [self] in
            var text: String
            do {
                text = try await session.finish()
            } catch {
                // Keep what it had recognized; the coordinator offers the audio for a retry.
                text = session.textSoFar
                lock.withLock { stats.failedSegments += 1 }
            }
            lock.withLock {
                closedText = SegmentText.join(closedText, text)
                closedDoubts += session.doubtfulWords
                closedSeconds += session.audioSeconds
                closingSession = nil
            }
        }
        lock.withLock { closing = task }
        await task.value
    }

    /// Opens the next utterance once the previous one is closed, feeds it the audio that waited,
    /// then lets new audio straight through.
    public func openSegment(_ make: @escaping @MainActor () throws -> RecognitionSession) async throws {
        let task = Task { [self] in
            if let earlier = lock.withLock({ closing }) { await earlier.value }
            guard !lock.withLock({ cancelled || current != nil }) else { return }
            let session = try await MainActor.run { try make() }
            while true {
                let chunk: [Float]? = lock.withLock {
                    let waiting = pending.count - pendingStart
                    guard waiting > 0 else {
                        // Nothing waits: from here the audio thread feeds this utterance directly.
                        pending = []
                        pendingStart = 0
                        current = session
                        stats.segments += 1
                        return nil
                    }
                    let end = pendingStart + min(waiting, Self.flushChunk)
                    let next = Array(pending[pendingStart..<end])
                    pendingStart = end
                    return next
                }
                guard let chunk else { break }
                while session.availableAudioSamples < chunk.count {
                    if let failure = session.failure { throw failure }
                    try await Task.sleep(for: .milliseconds(5))
                }
                session.feed(chunk)
            }
        }
        lock.withLock { opening = task }
        try await task.value
    }

    public func finish() async throws -> String {
        if let opening = lock.withLock({ opening }) { _ = try? await opening.value }
        if let closing = lock.withLock({ closing }) { await closing.value }
        // The open utterance stays `current` while it decodes, so a failure here still leaves
        // its partial words in `textSoFar` for the coordinator to keep.
        if let session = lock.withLock({ current }) {
            let text = try await session.finish()
            lock.withLock {
                closedText = SegmentText.join(closedText, text)
                closedDoubts += session.doubtfulWords
                closedSeconds += session.audioSeconds
                current = nil
            }
        }
        return lock.withLock { closedText }
    }

    public func cancel() {
        let sessions: [RecognitionSession] = lock.withLock {
            cancelled = true
            let open = [current, closingSession].compactMap { $0 }
            current = nil
            pending = []
            pendingStart = 0
            return open
        }
        lock.withLock { opening }?.cancel()
        for session in sessions { session.cancel() }
    }
}
