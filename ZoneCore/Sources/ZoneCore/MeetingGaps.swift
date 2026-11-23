// by zayd/cold @ zayd.wtf

import Foundation

/// A stretch of a meeting that was not recorded because iOS took the microphone: a phone call,
/// Siri, an alarm, another app that records. `at` is meeting time (seconds of recorded audio
/// before the gap), so it sits between the transcript paragraphs around it; `seconds` is how
/// long the microphone was gone on the clock.
public struct MeetingGap: Codable, Equatable, Sendable {
    public var at: Double
    public var seconds: Double
    public var reason: String
    public init(at: Double, seconds: Double, reason: String) {
        self.at = at
        self.seconds = seconds
        self.reason = reason
    }

    /// "Not recorded for 1 min 20 s: a call or another app had the microphone."
    public var label: String {
        let total = max(1, Int(seconds.rounded()))
        let minutes = total / 60, remainder = total % 60
        let duration = minutes == 0 ? "\(total) s" : "\(minutes) min" + (remainder == 0 ? "" : " \(remainder) s")
        return "Not recorded for \(duration): \(Self.cause(reason))."
    }

    /// iOS reports almost every interruption as "default", calls included; the words say what
    /// it can have been rather than guess.
    static func cause(_ reason: String) -> String {
        switch reason {
        case "builtInMicMuted": return "the microphone was muted"
        case "routeDisconnected": return "the microphone was disconnected"
        case "mediaServicesReset": return "iOS restarted its audio system"
        case "inputStalled", "restartFailed": return "the microphone stopped sending audio"
        case "suspended": return "iOS paused Zone"
        default: return "a call, Siri, an alarm or another app had the microphone"
        }
    }
}

/// Turns an interruption's start and end into a gap. Pure, so it is tested without audio.
public struct MeetingGapTracker: Sendable {
    private var openedAt: Date?
    private var audioAt: Double = 0
    private var reason = "default"

    public init() {}

    public var isOpen: Bool { openedAt != nil }

    /// The microphone went away with `audioSeconds` of the meeting recorded. A second begin
    /// while one is open (a call, then the media server resets) keeps the first start.
    public mutating func began(at now: Date, audioSeconds: Double, reason: String) {
        guard openedAt == nil else { return }
        openedAt = now
        audioAt = max(0, audioSeconds)
        self.reason = reason
    }

    /// The microphone is back. Under a quarter second is not worth a line in the transcript.
    public mutating func ended(at now: Date) -> MeetingGap? {
        guard let start = openedAt else { return nil }
        openedAt = nil
        let seconds = now.timeIntervalSince(start)
        guard seconds >= 0.25 else { return nil }
        return MeetingGap(at: audioAt, seconds: seconds, reason: reason)
    }

    /// The meeting stopped while the microphone was still gone: the gap runs to the stop.
    public mutating func close(at now: Date) -> MeetingGap? { ended(at: now) }
}

/// Which meetings to transcribe when Zone launches. Recorded meetings always. A failed one is
/// retried once per new build of Zone: a failure caused by a bug (every meeting on the phone
/// failed with "The speech model did not respond" until build 2026110408 fixed the stall) must
/// not stay failed after the fix ships, yet a meeting that fails for its own reason must not
/// retry on every launch.
public enum MeetingLaunchQueue {
    public static func ids(_ meetings: [Meeting], currentBuild: String, lastRetriedBuild: String?) -> [UUID] {
        let retryFailed = lastRetriedBuild != currentBuild
        return meetings
            .filter { $0.status == .recorded || (retryFailed && $0.status == .failed && $0.duration > 0) }
            .sorted { $0.createdAt < $1.createdAt }
            .map(\.id)
    }
}

/// How often a held meeting asks for the microphone back when iOS does not say the
/// interruption ended: soon at first (most interruptions are a few seconds), then every 30 s
/// for as long as the meeting stays held.
public enum MeetingResumeSchedule {
    public static func delay(attempt: Int) -> Double {
        let first: [Double] = [2, 5, 10, 20]
        return attempt >= 0 && attempt < first.count ? first[attempt] : 30
    }
}

/// The meeting's work as one 0...1 figure for iOS's background progress: finding speakers is
/// the first fifth when it runs, transcription the rest. Never moves backwards.
public struct MeetingOverallProgress: Sendable {
    public private(set) var value: Double = 0
    public init() {}
    public mutating func update(phase: String, fraction: Double) -> Double {
        let f = min(max(fraction, 0), 1)
        let next: Double
        switch phase {
        case "Finding speakers": next = 0.2 * f
        case "Transcribing": next = 0.2 + 0.8 * f
        default: next = value
        }
        value = max(value, next)
        return value
    }
}
