// by zayd/cold @ zayd.wtf

import AVFoundation
import Foundation
import ZoneCore
import Speech

/// Apple's on-device speech model (iOS 26): `SpeechTranscriber` or `DictationTranscriber`.
///
/// No weights ship in our bundle: the language asset is installed and shared by the system,
/// and recognition runs out of process. A `SpeechAnalyzer` finishes for good once finalized,
/// so every utterance builds its own analyzer; that setup runs while the user is already
/// talking (audio waits in an `AsyncStream`), never after the stop. Analyzers are created with
/// `.processLifetime` retention and one `prepareToAnalyze` runs at load, so the system keeps
/// the model resident for the session instead of reloading it per utterance (H9 in doc 13).
///
/// `DictationTranscriber` is the system dictation model with the `.shortForm` hint and is the
/// only one of the two where contextual strings measurably help.
@available(iOS 26.0, *)
final class AppleSpeechEngine: SpeechEngine {
    enum Module: Sendable {
        case speech
        case dictation
    }

    private let module: Module
    private let lock = NSLock()
    private var ready = false
    private var locale: Locale?
    private var analyzerFormat: AVAudioFormat?
    private var hints: [String] = []

    init(module: Module) {
        self.module = module
    }

    var kind: EngineKind { module == .speech ? .appleSpeech : .appleDictation }

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready
    }

    /// The asset is system-managed; `prepare()` installs it when needed.
    func assetsPresent() -> Bool { true }
    func bytesOnDisk() -> Int64 { 0 }
    func removeAssets() throws {}

    /// Installing the system asset is the whole download; nothing is loaded into our process.
    func downloadAssets(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        let english = Locale(identifier: "en-US")
        let locale = module == .speech
            ? await SpeechTranscriber.supportedLocale(equivalentTo: english)
            : await DictationTranscriber.supportedLocale(equivalentTo: english)
        guard let locale else { throw SpeechEngineError.unavailable("Apple's speech model does not support English here.") }
        let prepared = Self.makeModule(module, locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [prepared.module]) {
            progress(0, "system speech asset")
            try await request.downloadAndInstall()
        }
        progress(1, "done")
    }

    static let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)

    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        if isReady { return }
        let english = Locale(identifier: "en-US")
        let locale: Locale?
        switch module {
        case .speech:
            guard SpeechTranscriber.isAvailable else {
                throw SpeechEngineError.unavailable("SpeechTranscriber is not available on this device.")
            }
            locale = await SpeechTranscriber.supportedLocale(equivalentTo: english)
        case .dictation:
            locale = await DictationTranscriber.supportedLocale(equivalentTo: english)
        }
        guard let locale else {
            throw SpeechEngineError.unavailable("Apple's speech model does not support English here.")
        }
        let warm = Self.makeModule(module, locale: locale)
        if await AssetInventory.status(forModules: [warm.module]) != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [warm.module]) {
            progress(0, "system speech asset")
            try await request.downloadAndInstall()
        }
        progress(1, "loading")
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [warm.module])
        let analyzer = SpeechAnalyzer(modules: [warm.module], options: Self.options)
        try await analyzer.prepareToAnalyze(in: format)
        await analyzer.cancelAndFinishNow()
        lock.lock()
        self.locale = locale
        analyzerFormat = format
        ready = true
        lock.unlock()
    }

    /// Names, numbers and capitalized terms from the typed text go in as contextual strings.
    /// Only `DictationTranscriber` uses them; `SpeechTranscriber` ignores them.
    private var personalWords: [String] = []

    func setPersonalWords(_ words: [String]) {
        lock.withLock { personalWords = Array(words.prefix(100)) }
    }

    func setContextHints(_ text: String) {
        let words = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count > 2 && ($0.first?.isUppercase == true || $0.contains(where: \.isNumber)) }
        lock.lock()
        var seen = Set<String>()
        // Explicit terms are preserved verbatim, including lowercase vocabulary and phrases.
        let unique = (personalWords + words.reversed()).filter { seen.insert($0.lowercased()).inserted }
        hints = module == .dictation ? Array(unique.prefix(100)) : []
        lock.unlock()
    }

    func beginUtterance() throws -> UtteranceSession {
        try beginUtterance(submission: nil)
    }

    func beginUtterance(submission: AudioModelSubmission?) throws -> UtteranceSession {
        lock.lock()
        defer { lock.unlock() }
        guard ready, let locale else { throw SpeechEngineError.notReady }
        return AppleSpeechUtterance(module: Self.makeModule(module, locale: locale), format: analyzerFormat, hints: hints, submission: submission)
    }

    func unload() {
        lock.lock()
        ready = false
        lock.unlock()
    }

    /// A fresh module plus a task that drains its results into one string. Final results only:
    /// volatile partials would be thrown away by the keyboard anyway.
    struct PreparedModule {
        let module: any SpeechModule
        /// Collects final results; the callback gets the text so far after each one.
        let collect: @Sendable (@escaping @Sendable (String) -> Void) async throws -> String
    }

    static func makeModule(_ module: Module, locale: Locale) -> PreparedModule {
        switch module {
        case .speech:
            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
            return PreparedModule(module: transcriber) { progress in
                var parts: [String] = []
                for try await result in transcriber.results {
                    parts.append(String(result.text.characters))
                    progress(join(parts))
                }
                return join(parts)
            }
        case .dictation:
            let transcriber = DictationTranscriber(
                locale: locale, contentHints: [.shortForm], transcriptionOptions: [.punctuation],
                reportingOptions: [], attributeOptions: [])
            return PreparedModule(module: transcriber) { progress in
                var parts: [String] = []
                for try await result in transcriber.results {
                    parts.append(String(result.text.characters))
                    progress(join(parts))
                }
                return join(parts)
            }
        }
    }

    /// Lines join like rolling segments: a mid-sentence line break keeps no capital.
    static func join(_ parts: [String]) -> String { SegmentText.join(parts) }
}

@available(iOS 26.0, *)
final class AppleSpeechUtterance: UtteranceSession {
    private let lock = NSLock()
    private var fedSamples = 0
    private var closed = false
    // Closing input to flush is different from cancelling inference. In particular, Cancel
    // must still reach the analyzer after finish() has closed input and is awaiting results.
    private var cancelled = false
    private let backlog = RecognitionBacklog(maxSamples: 10 * 16_000)
    var failure: Error? { backlog.failure }
    var availableAudioSamples: Int { backlog.availableSamples }
    private let continuation: AsyncStream<(AnalyzerInput, Int)>.Continuation
    private let converter: SampleConverter
    private let run: Task<(SpeechAnalyzer, Task<String, Error>), Error>
    private let progress = TextBox()

    init(module: AppleSpeechEngine.PreparedModule, format: AVAudioFormat?, hints: [String], submission: AudioModelSubmission? = nil) {
        let (stream, continuation) = AsyncStream<(AnalyzerInput, Int)>.makeStream(bufferingPolicy: .bufferingOldest(256))
        self.continuation = continuation
        converter = SampleConverter(target: format)
        let progress = progress
        let backlog = backlog
        run = Task {
            let analyzer = SpeechAnalyzer(modules: [module.module], options: AppleSpeechEngine.options)
            if !hints.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = hints
                try? await analyzer.setContext(context)
            }
            let collector = Task<String, Error> {
                do { return try await module.collect { progress.set($0) } }
                catch { backlog.fail(error); throw error }
            }
            do {
                try await analyzer.start(inputSequence: stream.map { input, count in
                    backlog.release(count)
                    if count > 0 { try submission?.record() }
                    return input
                })
                return (analyzer, collector)
            } catch {
                backlog.fail(error)
                collector.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }
        }
    }

    var audioSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(fedSamples) / 16_000
    }

    var textSoFar: String { progress.value }

    func feed(_ samples: [Float]) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        fedSamples += samples.count
        lock.unlock()
        guard backlog.admit(samples.count) else { return }
        if let buffer = converter.buffer(from: samples) {
            switch continuation.yield((AnalyzerInput(buffer: buffer), samples.count)) {
            case .enqueued: break
            case .dropped:
                backlog.release(samples.count)
                backlog.fail(RecognitionFailure.overloaded)
            case .terminated:
                backlog.release(samples.count)
            @unknown default:
                backlog.release(samples.count)
                backlog.fail(RecognitionFailure.overloaded)
            }
        } else {
            backlog.release(samples.count)
            backlog.fail(RecognitionFailure.recognizer("Audio conversion failed"))
        }
    }

    func finish() async throws -> String {
        lock.lock()
        guard !closed else {
            lock.unlock()
            throw SpeechEngineError.utteranceClosed
        }
        closed = true
        lock.unlock()
        continuation.finish()
        let (analyzer, collector) = try await run.value
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let text = try await collector.value
        try backlog.check()
        return text
    }

    func cancel() {
        lock.lock()
        let wasCancelled = cancelled
        cancelled = true
        closed = true
        lock.unlock()
        guard !wasCancelled else { return }
        backlog.cancel()
        continuation.finish()
        Task { [run] in
            if let (analyzer, collector) = try? await run.value {
                await analyzer.cancelAndFinishNow()
                collector.cancel()
            }
        }
    }
}

/// Wraps our 16 kHz mono Float32 samples in the buffer format the analyzer asked for.
final class SampleConverter: @unchecked Sendable {
    private static let source = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let target: AVAudioFormat
    private let converter: AVAudioConverter?

    init(target: AVAudioFormat?) {
        let target = target ?? Self.source
        self.target = target
        converter = target == Self.source ? nil : AVAudioConverter(from: Self.source, to: target)
    }

    func buffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let input = AVAudioPCMBuffer(pcmFormat: Self.source, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            input.floatChannelData![0].update(from: pointer.baseAddress!, count: samples.count)
        }
        guard let converter else { return input }
        let ratio = target.sampleRate / Self.source.sampleRate
        let capacity = AVAudioFrameCount(Double(samples.count) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        return error == nil ? output : nil
    }
}

/// A string shared between the result collector and readers on other threads.
final class TextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    var value: String { lock.withLock { text } }
    func set(_ value: String) { lock.withLock { text = value } }
}
