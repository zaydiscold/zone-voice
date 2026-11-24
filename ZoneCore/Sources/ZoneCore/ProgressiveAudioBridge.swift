// by zayd/cold @ zayd.wtf

import Foundation

/// The microphone writes the recovery file independently. Until the model catches up,
/// replay only the committed prefix, in order, without holding the tap's lock during I/O.
public final class ProgressiveAudioBridge: RecognitionSession, @unchecked Sendable {
    private let lock = NSLock()
    private let writer: AudioRecoveryWriter
    private let url: URL
    private var samples = 0
    private var model: RecognitionSession?
    private var live = false
    private var cancelled = false
    private var finishing = false
    private var error: Error?
    private var drain: Task<Void, Never>?
    private var first: Date?
    public var firstSample: Date? { lock.withLock { first } }
    public init(writer: AudioRecoveryWriter, url: URL) {
        self.writer = writer
        self.url = url
    }

    public var audioSeconds: Double { lock.withLock { Double(samples) / 16_000 } }
    public var availableAudioSamples: Int { Int.max }
    public var failure: Error? { lock.withLock { error ?? model?.failure } }
    public var textSoFar: String { lock.withLock { model }?.textSoFar ?? "" }
    public var doubtfulWords: [DoubtfulWord] { lock.withLock { model }?.doubtfulWords ?? [] }

    /// Called by a single serial tap, immediately after the corresponding writer.append.
    public func feed(_ block: [Float]) {
        guard !block.isEmpty else { return }
        let target: RecognitionSession? = lock.withLock {
            guard !cancelled, error == nil else { return nil }
            if first == nil { first = Date() }
            samples += block.count
            if live { return model }
            return nil
        }
        target?.feed(block)
    }

    public func fail(_ cause: Error) { lock.withLock { error = cause } }

    public func attach(_ session: RecognitionSession) {
        let accepted = lock.withLock {
            guard !cancelled, model == nil, error == nil else { return false }
            model = session
            drain = Task.detached(priority: .userInitiated) { [self] in
                do { try await catchUp(session) }
                catch { fail(error) }
            }
            return true
        }
        if !accepted { session.cancel() }
    }

    private func catchUp(_ session: RecognitionSession) async throws {
        let reader = try AudioRecoveryReader(url: url)
        var cursor = 0
        while true {
            try Task.checkCancellation()
            if let failure { throw failure }
            if let failure = writer.failure { throw failure }
            let available = session.availableAudioSamples
            let (end, handedOff) = lock.withLock {
                if cursor == samples, finishing || available >= 4096 {
                    live = true
                }
                return (samples, live)
            }
            if handedOff { return }
            if end == cursor {
                try await Task.sleep(for: .milliseconds(5))
                continue
            }
            var block: [Float] = []
            let count = min(4096, available, end - cursor, writer.flushedSamples - cursor)
            if count > 0 { block = try reader.read(maxSamples: count) }
            if block.isEmpty {
                try await Task.sleep(for: .milliseconds(5))
            } else {
                session.feed(block)
                cursor += block.count
            }
        }
    }

    public func finish() async throws -> String {
        lock.withLock { finishing = true }
        while true {
            try Task.checkCancellation()
            if let failure { throw failure }
            let (stopped, ready) = lock.withLock { (cancelled, live ? model : nil) }
            if stopped { throw CancellationError() }
            if let ready { return try await ready.finish() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    public func cancel() {
        let target = lock.withLock {
            cancelled = true
            drain?.cancel()
            return model
        }
        target?.cancel()
    }
}

/// The simulator timing run opts in. The rows contain monotonic time and stage names only.
public enum PressTiming {
    #if DEBUG
    private static let enabled = ProcessInfo.processInfo.environment["ZONE_PRESS_TIMING"] == "1"
    #endif
    public static func mark(_ stage: String) {
        #if DEBUG
        if enabled { print("COLDTRACE \(stage) \(ProcessInfo.processInfo.systemUptime)") }
        #endif
    }
}
