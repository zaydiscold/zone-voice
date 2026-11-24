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
        // Clip, pad and order. Toward a neighbouring turn of another voice, padding stops at the
        // middle of the pause between them (or at the turn's edge when they touch): padding
        // across made the two chunks overlap, so a word at the change of speaker could be
        // transcribed twice, once under each name.
        let ordered = source.sorted { $0.start < $1.start }
        var clipped: [MeetingChunk] = ordered.indices.map { index in
            let turn = ordered[index]
            var start = turn.start - padding, end = turn.end + padding
            if index > 0, ordered[index - 1].speaker != turn.speaker {
                let previous = ordered[index - 1].end
                start = previous > turn.start ? turn.start : max(start, (previous + turn.start) / 2)
            }
            if index + 1 < ordered.count, ordered[index + 1].speaker != turn.speaker {
                let following = ordered[index + 1].start
                end = following < turn.end ? turn.end : min(end, (turn.end + following) / 2)
            }
            return MeetingChunk(start: max(from, start), end: min(to, end), speaker: turn.speaker)
        }
        .filter { $0.end - $0.start > 0.05 }
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
/// order of first appearance, numbered after the speakers a meeting already has. A voice that
/// matches an existing speaker's voice print (`MeetingVoices`) keeps that speaker's id, so a
/// resumed stretch does not turn a named person back into "Speaker 3".
public enum MeetingSpeakerLabels {
    public static func normalize(_ turns: [MeetingTurn], existing: [MeetingSpeaker],
                                 voices: [String: [Float]] = [:]) -> (turns: [MeetingTurn], speakers: [MeetingSpeaker]) {
        var next = (existing.compactMap { Int($0.id.dropFirst()) }.max() ?? 0) + 1
        let known = Dictionary(existing.compactMap { speaker in speaker.voice.map { (speaker.id, $0) } },
                               uniquingKeysWith: { first, _ in first })
        var mapping = MeetingVoices.match(voices, to: known)
        var added: [MeetingSpeaker] = []
        let relabeled = turns.sorted { $0.start < $1.start }.map { turn -> MeetingTurn in
            guard let raw = turn.speaker else { return turn }
            if mapping[raw] == nil {
                let id = "S\(next)"
                next += 1
                mapping[raw] = id
                added.append(MeetingSpeaker(id: id, voice: voices[raw]))
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
    /// The person speaking (`Meeting.person`), not the raw voice a line was labeled with.
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
        let distinct = Set(meeting.speakers.filter { $0.sharesName == true }.map(\.id))
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
            // A paragraph belongs to a person: a voice joined to someone continues their paragraph.
            let person = meeting.person(segment.speaker)
            if let last = out.last, !last.isGap,
               last.speaker == person || (last.speaker.map { !distinct.contains($0) } == true
                    && person.map { !distinct.contains($0) } == true
                    && meeting.speakerName(last.speaker) == meeting.speakerName(person)) {
                out[out.count - 1].text += " " + text
            } else {
                out.append(MeetingParagraph(speaker: person, start: segment.start, text: text))
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
