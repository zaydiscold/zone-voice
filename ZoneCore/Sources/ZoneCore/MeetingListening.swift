// by zayd/cold @ zayd.wtf

import Foundation

/// Short stretches of one speaker's voice, played when the person names that speaker so they
/// can hear who "Speaker 2" is before typing a name.
public enum MeetingSpeakerSamples {
    /// Up to `count` clips of about `length` seconds each, spread over the meeting: the
    /// speaker's segments are split into `count` groups in time order and the longest of each
    /// group gives one clip. Segments under `minimum` seconds are skipped unless nothing longer
    /// exists. Each clip starts a fifth of a second into its segment, past the cut.
    public static func clips(for speaker: String, in segments: [MeetingSegment], count: Int = 3,
                             length: Double = 4, minimum: Double = 1.5) -> [ClosedRange<Double>] {
        clips(for: [speaker], in: segments, count: count, length: length, minimum: minimum)
    }

    /// The same for a person with several voices (`Meeting.voices(of:)`).
    public static func clips(for voices: Set<String>, in segments: [MeetingSegment], count: Int = 3,
                             length: Double = 4, minimum: Double = 1.5) -> [ClosedRange<Double>] {
        let theirs = segments
            .filter { $0.speaker.map(voices.contains) == true && $0.end > $0.start }
            .sorted { $0.start < $1.start }
        guard !theirs.isEmpty, count > 0 else { return [] }
        let long = theirs.filter { $0.end - $0.start >= minimum }
        let pool = long.isEmpty ? theirs : long
        let groups = min(count, pool.count)
        var picked: [MeetingSegment] = []
        for group in 0..<groups {
            let lower = group * pool.count / groups
            let upper = (group + 1) * pool.count / groups
            if let best = pool[lower..<upper].max(by: { ($0.end - $0.start) < ($1.end - $1.start) }) {
                picked.append(best)
            }
        }
        return picked.map { segment in
            let lead = min(0.2, (segment.end - segment.start) / 4)
            let start = segment.start + lead
            return start...min(segment.end, start + length)
        }
    }
}

/// How long transcription will take, told before and after recording. Learned from this
/// iPhone: every finished meeting records seconds of work per second of audio for its engine,
/// and the estimate uses the latest figure; until one exists a cautious default stands in.
public enum MeetingEstimate {
    /// Seconds of work per second of audio before this iPhone has finished a meeting.
    /// Simulator runs measured 0.25 to 0.4 for Moonshine Small (since retired); a phone is slower.
    public static let defaultRate = 0.6
    /// Diarization: published 60x real time on Apple silicon; budgeted at 20x plus model load.
    /// The second look (`MeetingSecondLook`) added 0.23 s per audio minute on an M4 Pro's Neural
    /// Engine and about 0.57 s on its CPU, against 0.60 s for the first pass on the CPU (AMI, 2026-11-18):
    /// budgeted at 60% more.
    public static let speakerRate = 0.08
    public static let speakerOverhead = 5.0

    public static func seconds(forAudio audio: Double, rate: Double?, labelsSpeakers: Bool) -> Double {
        let work = max(audio, 0) * max(rate ?? defaultRate, 0.01)
        return work + (labelsSpeakers ? max(audio, 0) * speakerRate + speakerOverhead : 0)
    }

    /// "under a minute", "about 4 minutes", "about 1 hour 10 minutes".
    public static func label(_ seconds: Double) -> String {
        if seconds < 60 { return "under a minute" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return minutes == 1 ? "about a minute" : "about \(minutes) minutes" }
        let hours = minutes / 60, rest = minutes % 60
        let hourText = hours == 1 ? "1 hour" : "\(hours) hours"
        return rest < 5 ? "about \(hourText)" : "about \(hourText) \(rest) minutes"
    }

    /// The next rate after a meeting finished: the measured figure, blended with the old one
    /// so one odd meeting (a short clip, a busy phone) does not swing the estimate.
    public static func updatedRate(previous: Double?, measuredSeconds: Double, audioSeconds: Double) -> Double? {
        guard audioSeconds >= 10, measuredSeconds > 0 else { return previous }
        // One odd run (a backgrounded app, a thermal stall) must not turn the next estimate into
        // hours: a phone transcribes somewhere between 50x and a third of real time.
        let measured = min(max(measuredSeconds / audioSeconds, 0.02), 3)
        guard let previous else { return measured }
        return previous * 0.4 + measured * 0.6
    }
}

/// 16 kHz mono float samples as a 16-bit PCM WAV file in memory, for AVAudioPlayer.
public enum PCMWave {
    static func header(bytes: Int, sampleRate: Int) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes))
        return data
    }

    public static func data(samples: [Float], sampleRate: Int = 16_000) -> Data {
        let bytes = samples.count * 2
        var data = header(bytes: bytes, sampleRate: sampleRate)
        data.reserveCapacity(44 + bytes)
        for sample in samples {
            let clamped = sample.isFinite ? min(max(sample, -1), 1) : 0
            withUnsafeBytes(of: Int16(clamped * Float(Int16.max)).littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
