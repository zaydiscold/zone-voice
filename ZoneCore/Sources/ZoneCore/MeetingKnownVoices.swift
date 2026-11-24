// by zayd/cold @ zayd.wtf

import Foundation

/// People named in earlier meetings, recognized by voice in a new one.
///
/// Nothing is stored apart from the meetings: each meeting keeps its speakers' voice prints
/// (`MeetingSpeaker.voice`) beside the names typed for them, so the people Zone knows are read
/// from the meetings on every pass. Deleting a meeting or clearing a name forgets that voice.
///
/// Measured 2026-11-18 (scripts/meeting-eval/enroll.py and the voices probe):
/// - AMI, four series of four meetings with the same four people: a book learned from one meeting
///   named everyone right in the other three at `threshold` (0 wrong, 0 strangers named).
/// - Across a change of microphone and day (a phone meeting against 150 of the owner's own
///   dictations recorded elsewhere), the same voice averaged over about a minute of speech scored
///   0.69 or more in 95% of draws and 0.76 or more with two minutes; strangers scored at most
///   0.20 and the other person in the meeting 0.18. Two different people recorded in the same
///   room scored up to 0.62, which is why `threshold` sits above it and below the same-meeting
///   0.75 (`MeetingVoices.sameVoice`) that same-room calibration chose.
public enum MeetingKnownVoices {
    /// A voice is someone known at this similarity or above.
    public static let threshold = 0.70
    /// A speaker with less speech than this has a noisy print and is left unnamed.
    public static let minimumSpeech = 15.0

    public struct Person: Equatable, Sendable {
        /// As last typed; nil for "me" when no name was given.
        public var name: String?
        public var isMe: Bool
        /// The mean of their unit prints over the meetings they were named in, unit length.
        /// Empty for "me" known only from voice setup.
        public var voice: [Float]
        public var meetings: Int
        /// "Me" only: voice setup's print (`VoiceProfile.meetingVoice`).
        public var setupVoice: [Float]?
        /// "Me" only: voice setup's whisper, counted only at `VoiceSetup.whisperThreshold`.
        public var whisperVoice: [Float]?

        public init(name: String?, isMe: Bool, voice: [Float], meetings: Int,
                    setupVoice: [Float]? = nil, whisperVoice: [Float]? = nil) {
            self.name = name
            self.isMe = isMe
            self.voice = voice
            self.meetings = meetings
            self.setupVoice = setupVoice
            self.whisperVoice = whisperVoice
        }

        /// The prints the person is recognized by at the usual threshold.
        public var voices: [[Float]] { (voice.isEmpty ? [] : [voice]) + (setupVoice.map { [$0] } ?? []) }

        public var isEmpty: Bool { voices.isEmpty && whisperVoice == nil }

        /// How much `print` sounds like this person: the best of their prints, the whisper's only
        /// when it reaches `VoiceSetup.whisperThreshold`.
        public func similarity(_ print: [Float]) -> Double {
            var best = voices.map { MeetingVoices.similarity($0, print) }.max() ?? -1
            if let whisperVoice {
                let whisper = MeetingVoices.similarity(whisperVoice, print)
                if whisper >= VoiceSetup.whisperThreshold { best = max(best, whisper) }
            }
            return best
        }
    }

    /// Everyone someone named or marked "me" in `meetings` whose voice print was kept, newest
    /// spelling of each name, and "me" from voice setup when `profile` is given. Speakers Zone
    /// named itself (`recognized`) are skipped.
    public static func people(in meetings: [Meeting], excluding: UUID? = nil, profile: VoiceProfile? = nil) -> [Person] {
        var people = learned(in: meetings, excluding: excluding)
        // Setup needs its normal voice; a whisper alone names nobody.
        guard let setup = profile?.meetingVoice else { return people }
        let whisper = profile?.whisperVoice
        if let index = people.firstIndex(where: { $0.isMe }) {
            // A print from another speaker model cannot be compared with these.
            let size = people[index].voice.count
            people[index].setupVoice = setup.count == size ? setup : nil
            people[index].whisperVoice = whisper?.count == size ? whisper : nil
        } else {
            people.insert(Person(name: nil, isMe: true, voice: [], meetings: 0, setupVoice: setup,
                                 whisperVoice: whisper?.count == setup.count ? whisper : nil), at: 0)
        }
        return people
    }

    private static func learned(in meetings: [Meeting], excluding: UUID?) -> [Person] {
        var sums: [String: (person: Person, sum: [Double], at: Date)] = [:]
        for meeting in meetings where meeting.id != excluding {
            for voiced in meeting.speakers {
                // A voice joined to someone is that person: it teaches under their name.
                guard let voice = voiced.voice, !voice.isEmpty, let owner = meeting.person(voiced.id),
                      let speaker = meeting.speakers.first(where: { $0.id == owner }), speaker.recognized != true else { continue }
                let name = clean(speaker.name)
                guard speaker.isMe || name != nil else { continue }
                let key = speaker.isMe ? "\u{0}me" : name!.lowercased()
                let unit = MeetingSecondLook.unit(voice)
                if var entry = sums[key] {
                    // A print from another speaker model cannot be averaged with this one.
                    guard entry.sum.count == unit.count else { continue }
                    for index in unit.indices { entry.sum[index] += unit[index] }
                    entry.person.meetings += 1
                    if meeting.createdAt > entry.at, let name {
                        entry.person.name = name
                        entry.at = meeting.createdAt
                    }
                    sums[key] = entry
                } else {
                    sums[key] = (Person(name: name, isMe: speaker.isMe, voice: [], meetings: 1), unit,
                                 name == nil ? .distantPast : meeting.createdAt)
                }
            }
        }
        return sums.keys.sorted().compactMap { key in
            guard var entry = sums[key] else { return nil }
            entry.person.voice = MeetingSecondLook.unit(entry.sum.map(Float.init)).map(Float.init)
            return entry.person
        }
    }

    /// `speakers` with the unnamed ones whose voice matches someone in `people` named after
    /// them and marked `recognized`. One person per speaker and one speaker per person, most
    /// similar pair first; nobody already named in this meeting, and no second "me".
    public static func recognize(_ speakers: [MeetingSpeaker], turns: [MeetingTurn], people: [Person],
                                 threshold: Double = threshold, minimumSpeech: Double = minimumSpeech) -> [MeetingSpeaker] {
        var speech: [String: Double] = [:]
        for turn in turns { if let id = turn.speaker { speech[id, default: 0] += max(0, turn.end - turn.start) } }
        let present = Set(speakers.compactMap { clean($0.name)?.lowercased() })
        let meTaken = speakers.contains { $0.isMe }
        var candidates: [String: [Float]] = [:]
        // A voice already joined to someone is not a stranger to name.
        for speaker in speakers where !speaker.isMe && clean(speaker.name) == nil && speaker.sameAs == nil {
            guard let voice = speaker.voice, !voice.isEmpty, speech[speaker.id, default: 0] >= minimumSpeech else { continue }
            candidates[speaker.id] = voice
        }
        var known: [Int] = []
        for (index, person) in people.enumerated() where !person.isEmpty {
            if person.isMe ? meTaken : person.name.map({ present.contains($0.lowercased()) }) ?? true { continue }
            known.append(index)
        }
        guard !candidates.isEmpty, !known.isEmpty else { return speakers }
        // One-to-one, most similar pair first, as `MeetingVoices.match` does, with each person
        // scored by the best of their prints.
        var pairs: [(similarity: Double, speaker: String, person: Int)] = []
        for (id, voice) in candidates {
            for index in known {
                let similarity = people[index].similarity(voice)
                if similarity >= threshold { pairs.append((similarity, id, index)) }
            }
        }
        pairs.sort { $0.similarity != $1.similarity ? $0.similarity > $1.similarity : ($0.speaker, $0.person) < ($1.speaker, $1.person) }
        var matches: [String: Int] = [:]
        var taken = Set<Int>()
        for pair in pairs where matches[pair.speaker] == nil && !taken.contains(pair.person) {
            matches[pair.speaker] = pair.person
            taken.insert(pair.person)
        }
        return speakers.map { speaker in
            guard let index = matches[speaker.id] else { return speaker }
            var named = speaker
            named.name = people[index].name
            named.isMe = people[index].isMe
            named.recognized = true
            return named
        }
    }

    /// A finished meeting where voice setup now hears the person, and which speaker it is.
    public struct MeMatch: Equatable, Sendable {
        public var meeting: UUID
        public var speaker: String
        public init(meeting: UUID, speaker: String) {
            self.meeting = meeting
            self.speaker = speaker
        }
    }

    /// Finished meetings with nobody marked "me" where one unnamed speaker sounds like the
    /// person from voice setup, decided exactly as a new meeting would be (`recognize`). The
    /// person chooses to apply them; nothing changes here.
    public static func findMe(in meetings: [Meeting], profile: VoiceProfile,
                              threshold: Double = threshold, minimumSpeech: Double = minimumSpeech) -> [MeMatch] {
        guard profile.meetingVoice != nil else { return [] }
        var out: [MeMatch] = []
        for meeting in meetings where meeting.status == .done && !meeting.speakers.contains(where: { $0.isMe }) {
            let me = people(in: meetings, excluding: meeting.id, profile: profile).filter(\.isMe)
            guard !me.isEmpty else { continue }
            let turns = meeting.turns ?? meeting.segments.map { MeetingTurn(start: $0.start, end: $0.end, speaker: $0.speaker) }
            let named = recognize(meeting.speakers, turns: turns, people: me, threshold: threshold, minimumSpeech: minimumSpeech)
            if let speaker = named.first(where: { $0.isMe && $0.recognized == true }) {
                out.append(MeMatch(meeting: meeting.id, speaker: speaker.id))
            }
        }
        return out
    }

    private static func clean(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
