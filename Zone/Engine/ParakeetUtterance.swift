import Foundation
import CoreML
import FluidAudio
import ZoneFluidAudio
import ZoneCore

enum MiniModelLoader {
    static func load(at directory: URL, units: MLComputeUnits) throws -> AsrModels {
        let config = MLModelConfiguration()
        config.computeUnits = units
        return try AsrModels.loadLocal(from: directory, version: .v3, configuration: config, encoderComputeUnits: units)
    }

    static func manager(at directory: URL, repeatMargin: Float?) -> AsrManager {
        let margin = repeatMargin.flatMap { FluidMiniJointTopK.isInstalled(in: directory) ? $0 : nil }
        return AsrManager(config: ASRConfig(tdtConfig: TdtConfig(spelledLetterRepeatMargin: margin)))
    }
}

/// One dictation: buffer while talking, trim silence, decode once on finish.
/// One dictation for a batch model. Audio is cut into segments of about 20 s at pauses
/// between words (`RollingSegmenter`) and each segment is decoded in the background while the
/// person keeps talking, one at a time and in order. Memory stays flat however long the
/// dictation runs, `textSoFar` grows segment by segment, and the wait after stop covers only
/// the last segment.
final class ParakeetUtterance: RecognitionSession {
    private let session: RollingRecognitionSession

    @TaskLocal private static var submission: AudioModelSubmission?

    init(decode: @escaping MiniComputeRouter.Decode, submission: AudioModelSubmission? = nil) {
        session = RollingRecognitionSession { segment in
            try await Self.$submission.withValue(submission) { try await decode(segment) }
        }
    }

    static func decoder(manager: AsrManager, decoderLayers: Int, lane: SerialRecognitionDecoder,
                        allowed: @escaping @Sendable () -> Bool = { true }) -> MiniComputeRouter.Decode {
        { segment in
            let doubts = SegmentDoubts()
            let text = try await lane.run {
                let audio = SilenceTrimmer.trim(segment)
                guard !audio.isEmpty else { return "" }
                let padded = audio.count < 16_000 ? audio + [Float](repeating: 0, count: 16_000 - audio.count) : audio
                // A fresh decoder state per segment, on purpose. Carrying the previous segment's
                // state across the cut raised WER from 12.96% to 14.65% on 394 of Zayd's dictations
                // (245 worse, 40 better) and blanked or clipped segment openings; priming with the last
                // ten pieces was also worse (docs/research/2026-11-18-model-lab.md). FluidAudio ignores
                // this state anyway for a segment over 15 s, which it decodes in fresh windows.
                var state = TdtDecoderState.make(decoderLayers: decoderLayers)
                guard allowed() else { throw CancellationError() }
                try Self.submission?.record()
                let result = try await manager.transcribe(padded, decoderState: &state)
                // The joint's probability for each piece it emitted: the words it was least sure of
                // can be offered for a one-tap fix in the keyboard (`DoubtfulWords`).
                let pieces = (result.tokenTimings ?? []).map { (piece: $0.token, confidence: $0.confidence) }
                doubts.set(DoubtfulWords.candidates(DoubtfulWords.words(pieces: pieces)))
                return SegmentText.cleaned(result.text)
            }
            return RecognizedSegment(text: text, doubts: doubts.value)
        }
    }

    var audioSeconds: Double { session.audioSeconds }
    var textSoFar: String { session.textSoFar }
    var failure: Error? { session.failure }
    var doubtfulWords: [DoubtfulWord] { session.doubtfulWords }
    var availableAudioSamples: Int { session.availableSamples }
    func feed(_ samples: [Float]) { session.feed(samples) }
    func finish() async throws -> String { try await session.finish() }
    func cancel() { session.cancel() }
}

/// Carries one segment's doubtful words out of the decode lane, which returns only text.
private final class SegmentDoubts: @unchecked Sendable {
    private let lock = NSLock()
    private var words: [DoubtfulWord] = []
    func set(_ words: [DoubtfulWord]) { lock.withLock { self.words = words } }
    var value: [DoubtfulWord] { lock.withLock { words } }
}

/// Drops leading and trailing silence before a batch decode, keeping a margin so soft word
/// edges survive. Energy gate on 20 ms frames, relative to the loudest frame so a quiet
/// speaker is not trimmed away. Only digital silence is discarded.
enum SilenceTrimmer {
    static func trim(_ samples: [Float], frame: Int = 320, margin: Int = 4_800) -> [Float] {
        guard samples.count > frame * 4 else { return samples }
        let frames = (samples.count + frame - 1) / frame
        var energies = [Float](repeating: 0, count: frames)
        for index in 0..<frames {
            var sum: Float = 0
            let base = index * frame
            let count = min(frame, samples.count - base)
            for offset in 0..<count {
                let value = samples[base + offset]
                sum += value * value
            }
            energies[index] = (sum / Float(count)).squareRoot()
        }
        let loudest = energies.max() ?? 0
        guard loudest > 0 else { return [] }
        let threshold = loudest * 0.05
        guard let first = energies.firstIndex(where: { $0 >= threshold }),
              let last = energies.lastIndex(where: { $0 >= threshold }) else { return [] }
        let start = max(0, first * frame - margin)
        let end = min(samples.count, (last + 1) * frame + margin)
        return Array(samples[start..<end])
    }
}
