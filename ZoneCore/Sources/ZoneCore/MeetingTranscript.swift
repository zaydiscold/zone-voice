// by zayd/cold @ zayd.wtf

import Foundation

/// A stretch of meeting audio handed to the speech engine as one utterance.
public struct MeetingChunk: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var speaker: String?
    public init(start: Double, end: Double, speaker: String?) {
        self.start = start
        self.end = end
        self.speaker = speaker
    }
    public var duration: Double { end - start }
}

/// Turns speaker turns (or one undivided stretch) into engine-sized chunks.
///
/// Dictation engines are tuned for seconds to a minute of speech; a meeting is hours. Chunks of
/// at most `maxSeconds` keep every engine in its comfort zone and give the transcript
/// timestamps. Long turns are cut at the quietest moment between `minSplitSeconds` and
/// `maxSeconds` so a word is rarely split; chunks with no sound above `silenceLevel` are
/// skipped, which on a real meeting saves a good share of the work.
public enum MeetingChunkPlanner {
    /// Do not transcribe across a missing stretch of audio: each side needs its own timestamp
    /// and paragraph, even though PCM parts are played back to back on disk.
    public static func splitting(_ chunks: [MeetingChunk], at boundaries: [Double]) -> [MeetingChunk] {
        chunks.flatMap { chunk -> [MeetingChunk] in
            let cuts = [chunk.start] + Array(Set(boundaries.filter { $0.isFinite && $0 > chunk.start && $0 < chunk.end })).sorted() + [chunk.end]
            return zip(cuts, cuts.dropFirst()).map { MeetingChunk(start: $0.0, end: $0.1, speaker: chunk.speaker) }
        }
    }
    public static func plan(turns: [MeetingTurn], levels: [Float], frameSeconds: Double = 0.1,
                            from: Double, to: Double, maxSeconds: Double = 28, minSplitSeconds: Double = 12,
                            mergeGap: Double = 0.8, padding: Double = 0.15, silenceLevel: Float = 0.004) -> [MeetingChunk] {
        guard to > from else { return [] }
        let source = turns.isEmpty ? [MeetingTurn(start: from, end: to, speaker: nil)] : turns
        // Clip, pad and order.
        var clipped: [MeetingChunk] = source
            .map { MeetingChunk(start: max(from, $0.start - padding), end: min(to, $0.end + padding), speaker: $0.speaker) }
            .filter { $0.end - $0.start > 0.05 }
            .sorted { $0.start < $1.start }
        // Merge neighbours from the same voice while they fit in one chunk.
        var merged: [MeetingChunk] = []
        for chunk in clipped {
            if var last = merged.last, last.speaker == chunk.speaker,
               chunk.start - last.end <= mergeGap, chunk.end - last.start <= maxSeconds {
                last.end = max(last.end, chunk.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(chunk)
            }
        }
        // Speaker detection is not a speech gate. A quiet or brief voice can be missed by
        // the diarizer even though the speech engine can recognize it. Keep audible gaps
        // as unlabeled audio rather than silently deleting those words or guessing a voice.
        if !turns.isEmpty {
            var uncovered: [MeetingChunk] = []
            var through = from
            for chunk in merged {
                if chunk.start - through >= 0.3 {
                    uncovered.append(MeetingChunk(start: through, end: chunk.start, speaker: nil))
                }
                through = max(through, chunk.end)
            }
            if to - through >= 0.3 {
                uncovered.append(MeetingChunk(start: through, end: to, speaker: nil))
            }
            for gap in uncovered {
                if levels.isEmpty {
                    merged.append(gap) // No level profile: preserve audio, as in the unlabeled path.
                    continue
                }
                let first = max(0, Int((gap.start / frameSeconds).rounded(.down)))
                let last = min(levels.count - 1, Int((gap.end / frameSeconds).rounded(.up)) - 1)
                guard first <= last else { continue }
                let audible = (first...last).filter { levels[$0] >= silenceLevel }
                guard let onset = audible.first, let end = audible.last else { continue }
                merged.append(MeetingChunk(start: max(gap.start, Double(onset) * frameSeconds - padding),
                                           end: min(gap.end, Double(end + 1) * frameSeconds + padding),
                                           speaker: nil))
            }
            merged.sort { $0.start < $1.start }
        }
        clipped = []
        // Split long ones at the quietest frame.
        for chunk in merged {
            var start = chunk.start
            while chunk.end - start > maxSeconds {
                let cut = quietest(levels: levels, frameSeconds: frameSeconds,
                                   from: start + min(minSplitSeconds, maxSeconds / 2), to: start + maxSeconds)
                clipped.append(MeetingChunk(start: start, end: cut, speaker: chunk.speaker))
                start = cut
            }
            clipped.append(MeetingChunk(start: start, end: chunk.end, speaker: chunk.speaker))
        }
        return clipped.filter { $0.duration >= 0.3 && loudest(levels: levels, frameSeconds: frameSeconds, in: $0) >= silenceLevel }
    }

    static func quietest(levels: [Float], frameSeconds: Double, from: Double, to: Double) -> Double {
        let first = max(0, Int((from / frameSeconds).rounded(.up)))
        let last = min(levels.count - 1, Int((to / frameSeconds).rounded(.down)))
        guard first <= last else { return to }
        var best = first
        for index in first...last where levels[index] < levels[best] { best = index }
        return Double(best) * frameSeconds
    }

    static func loudest(levels: [Float], frameSeconds: Double, in chunk: MeetingChunk) -> Float {
        guard !levels.isEmpty else { return .infinity } // No profile: never skip.
        let first = max(0, Int(chunk.start / frameSeconds))
        let last = min(levels.count - 1, Int(chunk.end / frameSeconds))
        guard first <= last else { return 0 }
        return levels[first...last].max() ?? 0
    }
}

/// Diarizer labels ("0", "SPEAKER_01", anything) become this app's stable "S1", "S2" ids in
/// order of first appearance, numbered after the speakers a meeting already has.
public enum MeetingSpeakerLabels {
    public static func normalize(_ turns: [MeetingTurn], existing: [MeetingSpeaker]) -> (turns: [MeetingTurn], speakers: [MeetingSpeaker]) {
        var next = (existing.compactMap { Int($0.id.dropFirst()) }.max() ?? 0) + 1
        var mapping: [String: String] = [:]
        var added: [MeetingSpeaker] = []
        let relabeled = turns.sorted { $0.start < $1.start }.map { turn -> MeetingTurn in
            guard let raw = turn.speaker else { return turn }
            if mapping[raw] == nil {
                let id = "S\(next)"
                next += 1
                mapping[raw] = id
                added.append(MeetingSpeaker(id: id))
            }
            return MeetingTurn(start: turn.start, end: turn.end, speaker: mapping[raw])
        }
        return (relabeled, existing + added)
    }
}

/// Plain text for the share sheet (Teams, Mail, Notes): title, date and length, then one
/// paragraph per change of speaker with its start time.
/// One block of the transcript: consecutive segments from the same voice.
public struct MeetingParagraph: Equatable, Identifiable, Sendable {
    public var speaker: String?
    public var start: Double
    public var text: String
    /// A stretch the recording missed (`MeetingGap`), shown between the paragraphs around it.
    public var isGap: Bool
    private var ordinal: Int
    public init(speaker: String?, start: Double, text: String, isGap: Bool = false, ordinal: Int = 0) {
        self.speaker = speaker
        self.start = start
        self.text = text
        self.isGap = isGap
        self.ordinal = ordinal
    }
    public var id: String { (isGap ? "gap-\(ordinal)-" : "") + String(start) }
}

public enum MeetingExport {
    /// Consecutive segments from one speaker joined into a paragraph, in time order.
    public static func paragraphs(_ meeting: Meeting) -> [MeetingParagraph] {
        var out: [MeetingParagraph] = []
        var pending = (meeting.gaps ?? []).sorted { $0.at < $1.at }
        for segment in meeting.segments.sorted(by: { $0.start < $1.start }) {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            while let gap = pending.first, gap.at <= segment.start + 0.05 {
                out.append(MeetingParagraph(speaker: nil, start: gap.at, text: gap.label, isGap: true, ordinal: out.count))
                pending.removeFirst()
            }
            // A gap starts a fresh paragraph, even when the same person keeps speaking.
            if let last = out.last, !last.isGap,
               last.speaker == segment.speaker
                || (last.speaker != nil && segment.speaker != nil
                    && meeting.speakerName(last.speaker) == meeting.speakerName(segment.speaker)) {
                out[out.count - 1].text += " " + text
            } else {
                out.append(MeetingParagraph(speaker: segment.speaker, start: segment.start, text: text))
            }
        }
        for gap in pending {
            out.append(MeetingParagraph(speaker: nil, start: gap.at, text: gap.label, isGap: true, ordinal: out.count))
        }
        return out
    }

    public static func text(_ meeting: Meeting, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        var lines = [meeting.title, "\(formatter.string(from: meeting.createdAt)), \(durationLabel(meeting.duration))", ""]
        if let notice = meeting.recordingNotice { lines.append(notice); lines.append("") }
        for paragraph in paragraphs(meeting) {
            if paragraph.isGap {
                lines.append("[\(timestamp(paragraph.start))] (\(paragraph.text))")
            } else if let name = meeting.speakerName(paragraph.speaker) {
                lines.append("[\(timestamp(paragraph.start))] \(name): \(paragraph.text)")
            } else {
                lines.append("[\(timestamp(paragraph.start))] \(paragraph.text)")
            }
            lines.append("")
        }
        if meeting.segments.isEmpty { lines.append("(No transcript yet.)") }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// "4:05" under an hour, "1:02:09" from an hour.
    public static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3_600, minutes = total / 60 % 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    /// "48 min", "1 h 12 min", "35 s".
    public static func durationLabel(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total) s" }
        let hours = total / 3_600, minutes = total / 60 % 60
        return hours > 0 ? "\(hours) h \(minutes) min" : "\(minutes) min"
    }
}
