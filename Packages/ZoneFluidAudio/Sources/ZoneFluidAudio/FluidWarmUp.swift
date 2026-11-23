// by zayd/cold @ zayd.wtf

import FluidAudio

/// How much silence the speech engine's warm-up decodes (`ParakeetEngine.warmUp`) to bring the
/// model's compiled program back into memory after idle.
///
/// FluidAudio pads anything up to 15 s to the encoder's one fixed 240,000-sample window, so a
/// shorter warm-up runs the same encoder: on the Mac CPU, 4,800, 16,000 and 240,000 samples cost
/// the same. Below FluidAudio's 0.3 s minimum (4,800 samples) `transcribe` throws
/// `invalidAudioData` before any model runs, so a 2,560-sample warm-up pages nothing in and the
/// next real decode pays the whole page-in. See docs/research/2026-11-18-model-lab.md.
public enum FluidWarmUp {
    public static let samples = 16_000

    /// True when a warm-up of `samples` reaches the encoder in a single window: at least
    /// FluidAudio's minimum and no more than one window.
    public static var reachesTheModel: Bool {
        samples >= ASRConstants.minimumRequiredSamples(forSampleRate: ASRConstants.sampleRate)
            && samples <= ASRConstants.maxModelSamples
    }
}
