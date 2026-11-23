// by zayd/cold @ zayd.wtf

import Foundation

/// Conservative product limits, not a claim of a completed device endurance test.
public enum MeetingRecordingSafety {
    public static let maximumSeconds: Double = 6 * 3_600
    public static let maximumSpeakerSeconds: Double = 2 * 3_600
    /// When the recorder and the Lock Screen start saying when the recording will stop.
    public static let countdownSeconds: Double = 10 * 60
    public static let reserveBytes: Int64 = 100_000_000
    public static let warningBytes: Int64 = 300_000_000
    public static let limitMessage = "Recording saved at the six hour limit. Start another meeting to keep recording."
    public static let storageMessage = "Recording saved because this iPhone is running low on storage. Free up space before recording again."
    public static var speakerLimitMessage: String {
        "Speaker labels are limited to \(speakerLabel) of audio per meeting. This longer recording is transcribed without speaker labels."
    }
    /// A resumed or merged meeting whose new stretch alone is past the speaker limit.
    public static var speakerLimitPartMessage: String {
        "Speaker labels cover up to \(speakerLabel) at a time. The newest part of this recording is transcribed without speaker labels."
    }

    /// "6 hours": the recording ceiling as the app says it, so copy follows the constant.
    public static var maximumLabel: String { hoursLabel(maximumSeconds) }
    /// "2 hours": how much audio speaker labels cover.
    public static var speakerLabel: String { hoursLabel(maximumSpeakerSeconds) }

    private static func hoursLabel(_ seconds: Double) -> String {
        let hours = Int(seconds / 3_600)
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    /// Minutes of audio that fit before the storage reserve, when that is shorter than the
    /// ceiling; nil when the full recording fits or the volume will not say.
    public static func storageMinutes(hoursOfSpace: Double?) -> Int? {
        guard let hours = hoursOfSpace, hours * 3_600 < maximumSeconds else { return nil }
        return max(0, Int(hours * 60))
    }

    public static func shouldStop(availableBytes: Int64?) -> Bool {
        availableBytes.map { $0 <= reserveBytes } ?? false
    }
}

/// Per-recording sample ownership. Old callbacks cannot count toward a new recording, and
/// the final buffer is trimmed before enqueue so the duration ceiling holds off screen too.
public final class MeetingCaptureProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var samples = 0
    private var paused = false
    private var closed = false
    private let maximumSamples: Int
    public init(maximumSamples: Int = Int(MeetingRecordingSafety.maximumSeconds * 16_000)) {
        self.maximumSamples = max(0, maximumSamples)
    }
    public var sampleCount: Int { lock.withLock { samples } }
    public var reachedLimit: Bool { lock.withLock { samples >= maximumSamples } }
    public func setPaused(_ value: Bool) { lock.withLock { paused = value } }
    public func close() { lock.withLock { closed = true } }

    public func append(_ input: [Float], to writer: MeetingAudioWriter) {
        lock.withLock {
            guard !paused, !closed else { return }
            let count = min(input.count, maximumSamples - samples)
            guard count > 0 else { return }
            let chunk = count == input.count ? input : Array(input.prefix(count))
            samples += writer.append(chunk)
        }
    }
}
