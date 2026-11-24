// by zayd/cold @ zayd.wtf

import Foundation

/// People and the voices that are them.
///
/// The speaker model numbers voices per recording, so one person can come out as two speakers:
/// after two recordings are merged, or when the model splits one voice. Joining never rewrites
/// the transcript. The joined voice keeps its own id on its lines and points at the person
/// (`MeetingSpeaker.sameAs`), every name is read through `Meeting.person`, and separating is
/// clearing that pointer. Copy, share, the paired computer and the list all read
/// `Meeting.speakerName`, so they follow without knowing about any of this.
public extension Meeting {
    /// The speaker whose name a voice's lines show under: itself, or the one it was joined to.
    func person(_ id: String?) -> String? {
        guard var current = id else { return nil }
        var seen: Set<String> = [current]
        while let next = speakers.first(where: { $0.id == current })?.sameAs,
              speakers.contains(where: { $0.id == next }), seen.insert(next).inserted {
            current = next
        }
        return current
    }

    /// One entry per person, in the order their first voice was heard.
    var people: [MeetingSpeaker] { speakers.filter { person($0.id) == $0.id } }

    /// Every voice that is this person, the person's own first.
    func voices(of person: String) -> [MeetingSpeaker] {
        guard let key = self.person(person) else { return [] }
        return speakers.filter { self.person($0.id) == key }.sorted { ($0.id == key ? 0 : 1) < ($1.id == key ? 0 : 1) }
    }

    /// Seconds of transcript under one voice.
    func speechSeconds(ofVoice voice: String) -> Double {
        segments.reduce(0) { $0 + ($1.speaker == voice ? max(0, $1.end - $1.start) : 0) }
    }

    /// Seconds of transcript under a person, all their voices together.
    func speechSeconds(of person: String) -> Double {
        let ids = Set(voices(of: person).map(\.id))
        return segments.reduce(0) { $0 + ($1.speaker.map(ids.contains) == true ? max(0, $1.end - $1.start) : 0) }
    }

    /// Something a voice said, to tell people apart at a glance: its first line with at least
    /// `words` words, else its longest. Nil when it has no lines.
    func sampleLine(ofVoice voice: String, words: Int = 5) -> MeetingSegment? {
        let theirs = segments.filter { $0.speaker == voice && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
        return theirs.first { $0.text.split(whereSeparator: \.isWhitespace).count >= words }
            ?? theirs.max { $0.text.count < $1.text.count }
    }

    /// The voice of a person that says the most, for a sample when the person has several.
    func mainVoice(of person: String) -> String? {
        voices(of: person).max { speechSeconds(ofVoice: $0.id) < speechSeconds(ofVoice: $1.id) }?.id
    }

    /// The person already carrying `name` (as shown), other than `person`.
    func personNamed(_ name: String, except person: String) -> MeetingSpeaker? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }
        let own = self.person(person)
        return people.first { $0.id != own && $0.name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted }
    }

    /// The person marked "me", other than `person`.
    func me(except person: String? = nil) -> MeetingSpeaker? {
        let own = self.person(person)
        return people.first { $0.isMe && $0.id != own }
    }
}

/// Changes to who is who. Each works on a copy of the meeting, so the store applies it under
/// its lock and the same rules are testable without one. None of them ever leaves a person
/// who had a name or "me" without it unless the caller asked for exactly that.
public enum MeetingSpeakerEdit {
    private static func clean(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// `voice` and everyone already joined to it become `target`. The target's name stands;
    /// where it has none it takes the joined one, and "me" comes along. False when they
    /// already are one person or either is missing.
    @discardableResult
    public static func join(_ voice: String, into target: String, in meeting: inout Meeting) -> Bool {
        guard let from = meeting.person(voice), let to = meeting.person(target), from != to,
              let source = meeting.speakers.firstIndex(where: { $0.id == from }),
              let destination = meeting.speakers.firstIndex(where: { $0.id == to }) else { return false }
        let joined = meeting.speakers[source]
        if clean(meeting.speakers[destination].name) == nil, let name = clean(joined.name) {
            meeting.speakers[destination].name = name
            meeting.speakers[destination].recognized = joined.recognized
        }
        if joined.isMe, !meeting.speakers[destination].isMe {
            meeting.speakers[destination].isMe = true
            if clean(meeting.speakers[destination].name) == nil { meeting.speakers[destination].recognized = joined.recognized }
        }
        for index in meeting.speakers.indices where meeting.person(meeting.speakers[index].id) == from {
            meeting.speakers[index].sameAs = to
            meeting.speakers[index].name = nil
            meeting.speakers[index].isMe = false
            meeting.speakers[index].recognized = nil
        }
        return true
    }

    /// A joined voice becomes its own, unnamed speaker again. False when it was not joined.
    @discardableResult
    public static func separate(_ voice: String, in meeting: inout Meeting) -> Bool {
        guard let index = meeting.speakers.firstIndex(where: { $0.id == voice }), meeting.speakers[index].sameAs != nil else { return false }
        meeting.speakers[index].sameAs = nil
        return true
    }

    /// Names the person a voice belongs to; an empty name clears it. Saving confirms a name
    /// Zone recognized.
    public static func rename(_ voice: String, to name: String, in meeting: inout Meeting) {
        guard let key = meeting.person(voice), let index = meeting.speakers.firstIndex(where: { $0.id == key }) else { return }
        meeting.speakers[index].name = clean(name)
        meeting.speakers[index].recognized = nil
    }

    /// Marks the person a voice belongs to as the phone's owner. When someone else already is,
    /// the two are the same person and are joined: "me" is never taken from anyone here.
    /// Nil clears "me".
    public static func setMe(_ voice: String?, in meeting: inout Meeting) {
        guard let voice else { return moveMe(to: nil, in: &meeting) }
        guard let key = meeting.person(voice) else { return }
        guard let speaker = meeting.people.first(where: { $0.id == key }) else { return }
        if let me = meeting.me(except: key) {
            if let name = clean(speaker.name), let other = clean(me.name),
               name.caseInsensitiveCompare(other) != .orderedSame { return }
            join(key, into: me.id, in: &meeting)
        } else {
            moveMe(to: key, in: &meeting)
        }
    }

    /// Makes the person a voice belongs to the only "me", taking it from whoever had it. For
    /// when the earlier "me" was wrong. Nil clears "me".
    public static func moveMe(to voice: String?, in meeting: inout Meeting) {
        let key = meeting.person(voice)
        for index in meeting.speakers.indices {
            let isMe = key != nil && meeting.speakers[index].id == key
            // Moving "me" is a choice made here, not a recognition. A speaker recognized as
            // "me" who is not loses the name that came with it too, or that name would be
            // learned from the wrong voice.
            if isMe != meeting.speakers[index].isMe {
                if !isMe, meeting.speakers[index].recognized == true { meeting.speakers[index].name = nil }
                meeting.speakers[index].recognized = nil
            }
            meeting.speakers[index].isMe = isMe
        }
    }

    /// Puts back an earlier list of speakers (Undo), when it still describes the same voices:
    /// a transcript made again since has other voices, and is left alone. False then.
    @discardableResult
    public static func restore(_ speakers: [MeetingSpeaker], in meeting: inout Meeting) -> Bool {
        guard Set(speakers.map(\.id)) == Set(meeting.speakers.map(\.id)) else { return false }
        // Voice prints may have been filled in since; names and joins go back, prints stay.
        let prints = Dictionary(meeting.speakers.compactMap { speaker in speaker.voice.map { (speaker.id, $0) } },
                                uniquingKeysWith: { first, _ in first })
        meeting.speakers = speakers.map { speaker in
            var restored = speaker
            if restored.voice == nil { restored.voice = prints[speaker.id] }
            return restored
        }
        return true
    }
}

/// Matching the voices of merged recordings.
///
/// Each recording was labeled on its own, so after a merge the later recording's speakers are
/// compared with the earlier ones by voice print and the matches joined. Two speakers of one
/// recording are never joined to each other or to the same person: the speaker model already
/// heard them as different people in the same room.
public enum MeetingVoiceMatch {
    /// A suggestion is offered from this similarity up; a join is made on its own only from
    /// `MeetingVoices.sameVoice`.
    public static let suggestion = 0.5
    /// Most stretches listened to for one voice's print, and the most seconds of each.
    public static let minimumPrintSeconds = 4.0
    public static let printSpans = 8
    public static let printSpanSeconds = 10.0

    /// The stretches to make a voice's print from when the speaker model's own was not kept:
    /// its longest lines, each cut to its middle `seconds`. Short interjections say least about
    /// a voice and overlap other people most, so they are left out while longer lines exist.
    public static func spans(forVoice voice: String, in segments: [MeetingSegment], limit: Int = printSpans,
                             seconds: Double = printSpanSeconds, minimum: Double = 1.5) -> [Range<Double>] {
        let theirs = segments.filter { $0.speaker == voice && $0.end - $0.start > 0.3 }
        let long = theirs.filter { $0.end - $0.start >= minimum }
        let useful = long.reduce(0.0) { $0 + min(seconds, $1.end - $1.start) } >= minimumPrintSeconds
        return (useful ? long : theirs)
            .sorted { ($0.end - $0.start, $1.start) > ($1.end - $1.start, $0.start) }
            .prefix(limit)
            .map { segment -> Range<Double> in
                let length = min(seconds, segment.end - segment.start)
                let start = segment.start + (segment.end - segment.start - length) / 2
                return start..<(start + length)
            }
            .sorted { $0.lowerBound < $1.lowerBound }
    }

    /// Voices that still need a print before the waiting groups can be matched: the ones with
    /// lines and no print. Empty when nothing waits.
    public static func voicesNeedingPrints(in meeting: Meeting) -> [String] {
        guard let groups = meeting.speakerGroupsToMatch, !groups.isEmpty else { return [] }
        return meeting.speakers.filter { speaker in
            !usablePrint(speaker.voice) && meeting.segments.contains { $0.speaker == speaker.id }
        }.map(\.id)
    }

    public static func usablePrint(_ voice: [Float]?) -> Bool {
        guard let voice else { return false }
        return voice.allSatisfy(\.isFinite) && voice.contains { $0 != 0 }
    }

    /// Shown on a merged meeting when some voice could not be matched to anyone.
    public static let unmatchedMessage = "Zone could not tell whether some speakers in the two recordings are the same person. Open Speakers to combine them."

    public struct Outcome: Equatable, Sendable {
        /// Later voice → the person it was joined to.
        public var joined: [String: String] = [:]
        /// Later people left on their own, with the closest earlier person when one is close
        /// enough to suggest.
        public var unmatched: [String: String?] = [:]
        public init() {}
    }

    /// Joins each waiting group's people to the people who were there before it, one to one,
    /// closest pair first, at `threshold` or above; then clears the waiting list. A person
    /// someone named differently from their match is never joined: typed names win.
    @discardableResult
    public static func resolve(_ meeting: inout Meeting, threshold: Double = MeetingVoices.sameVoice) -> Outcome {
        var outcome = Outcome()
        var carried = meeting.voiceReviewCandidates ?? [:]
        var review: [String: Set<String>] = [:]
        let groups = meeting.speakerGroupsToMatch ?? []
        meeting.speakerGroupsToMatch = nil
        for (index, group) in groups.enumerated() {
            let later = Set(groups[index...].joined())
            let members = Set(group)
            // A retry replaces this group's comparisons against earlier recordings. Unanswered pairs
            // inside a recording that was itself merged still belong to that recording.
            for id in group {
                carried[id] = carried[id]?.filter(later.contains)
            }
            // People of this recording still on their own, and the earlier people nobody of
            // this recording is already joined to.
            let incoming = meeting.people.filter { members.contains($0.id) }
            let taken = Set(meeting.speakers.filter { members.contains($0.id) }.compactMap { meeting.person($0.id) })
            let earlier = meeting.people.filter { !later.contains($0.id) && !taken.contains($0.id) }
            let hasContrast = Set(group.compactMap { meeting.person($0) }).count > 1 ||
                meeting.people.filter { !later.contains($0.id) }.count > 1
            var pairs: [(similarity: Double, from: String, to: String)] = []
            var closest: [String: (similarity: Double, to: String)] = [:]
            for candidate in incoming {
                for person in earlier where compatible(candidate, person) {
                    let similarity = Self.similarity(meeting, candidate.id, person.id)
                    pairs.append((similarity, candidate.id, person.id))
                    if similarity >= suggestion, similarity > (closest[candidate.id]?.similarity ?? -1) {
                        closest[candidate.id] = (similarity, person.id)
                    }
                }
            }
            pairs.sort { $0.similarity != $1.similarity ? $0.similarity > $1.similarity : ($0.from, $0.to) < ($1.from, $1.to) }
            var used = Set<String>()
            // Require a clear lead in both directions. A high score shared by two
            // different speakers is a question for the listener.
            for pair in pairs where hasContrast && pair.similarity >= threshold {
                let contested = pairs.contains { rival in
                    (rival.from == pair.from && rival.to != pair.to || rival.to == pair.to && rival.from != pair.from)
                        && (rival.similarity == -1 || rival.similarity > pair.similarity - 0.08)
                }
                guard !contested else { continue }
                if MeetingSpeakerEdit.join(pair.from, into: pair.to, in: &meeting) {
                    outcome.joined[pair.from] = pair.to
                    used.insert(pair.to)
                }
            }
            // Someone left over is only a question while an earlier person is left over too:
            // with everyone earlier accounted for, a further voice is simply a new person.
            let left = earlier.filter { !used.contains($0.id) }
            for candidate in incoming where outcome.joined[candidate.id] == nil {
                guard left.contains(where: { compatible(candidate, $0) }) else { continue }
                let near = closest[candidate.id].flatMap { used.contains($0.to) ? nil : $0.to }
                outcome.unmatched[candidate.id] = .some(near)
                review[candidate.id] = Set(left.filter { compatible(candidate, $0) }.map(\.id))
            }
        }
        for pair in openPairs(carried, in: meeting) {
            review[pair.from, default: []].insert(pair.to)
        }
        meeting.voiceReviewCandidates = review.isEmpty ? nil : review.mapValues { $0.sorted() }
        return outcome
    }

    public struct ReviewPair: Hashable, Sendable {
        public let from: String
        public let to: String
    }

    /// Resolve both ends through subsequent joins, including older choices carried through
    /// another merge. Once the source matches one of its alternatives, that row is answered.
    static func openPairs(_ candidates: [String: [String]], in meeting: Meeting) -> Set<ReviewPair> {
        guard !candidates.isEmpty else { return [] }
        let people = meeting.people
        let indices = Dictionary(people.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var pairs = Set<ReviewPair>()
        for (sourceID, targets) in candidates {
            guard let root = meeting.person(sourceID), let source = indices[root] else { continue }
            let roots = targets.compactMap { meeting.person($0) }.compactMap { indices[$0] }
            guard !roots.contains(source) else { continue }
            for target in roots where compatible(people[source], people[target]) {
                // Joining a voice to an older recording can reverse an inherited pair.
                pairs.insert(ReviewPair(from: people[max(source, target)].id, to: people[min(source, target)].id))
            }
        }
        return pairs
    }

    /// Include unscored alternatives for listening. Only suggest pairs with voice evidence.
    public static func reviewPairs(in meeting: Meeting) -> [ReviewPair] {
        let scores = openPairs(meeting.voiceReviewCandidates ?? [:], in: meeting).map { pair in
            (pair, similarity(meeting, pair.from, pair.to))
        }
        return scores.sorted { a, b in
            a.1 != b.1 ? a.1 > b.1 : (a.0.from, a.0.to) < (b.0.from, b.0.to)
        }.map { $0.0 }
    }

    /// A chain of individually valid pairs can connect two different names through an unnamed
    /// person. Check the names after each join before publishing any of the edits.
    private static func joinReviewedPair(_ pair: ReviewPair, in meeting: inout Meeting) -> Bool {
        guard let from = meeting.person(pair.from), let to = meeting.person(pair.to),
              let source = meeting.speakers.first(where: { $0.id == from }),
              let target = meeting.speakers.first(where: { $0.id == to }),
              compatible(source, target) else { return false }
        return MeetingSpeakerEdit.join(from, into: to, in: &meeting)
    }

    public static func reviewedSpeakers(for selected: Set<ReviewPair>, in meeting: Meeting) -> [MeetingSpeaker]? {
        guard Set(selected.map(\.from)).count == selected.count,
              Set(selected.map(\.to)).count == selected.count else { return nil }
        var result = meeting
        for pair in selected {
            guard joinReviewedPair(pair, in: &result) else { return nil }
        }
        return result.speakers
    }

    public static func suggestedPairs(in meeting: Meeting) -> Set<ReviewPair> {
        var proposed = meeting
        var selected = Set<ReviewPair>()
        for pair in reviewPairs(in: meeting) where similarity(meeting, pair.from, pair.to) >= suggestion {
            if !selected.contains(where: { $0.from == pair.from || $0.to == pair.to }),
               joinReviewedPair(pair, in: &proposed) {
                selected.insert(pair)
            }
        }
        return selected
    }

    /// The earlier people a person most sounds like, closest first, from `suggestion` up: the
    /// order "Same person as" offers them in.
    public static func closest(to person: String, in meeting: Meeting) -> [(person: String, similarity: Double)] {
        guard let key = meeting.person(person) else { return [] }
        return meeting.people.filter { $0.id != key }
            .map { ($0.id, similarity(meeting, key, $0.id)) }
            .filter { $0.1 >= suggestion }
            .sorted { $0.1 > $1.1 }
            .map { (person: $0.0, similarity: $0.1) }
    }

    /// How alike two people sound: the best pair of their voices' prints. -1 with no prints.
    public static func similarity(_ meeting: Meeting, _ a: String, _ b: String) -> Double {
        var best = -1.0
        for first in meeting.voices(of: a) {
            guard let print = first.voice, usablePrint(print) else { continue }
            for second in meeting.voices(of: b) {
                guard let other = second.voice, usablePrint(other) else { continue }
                best = max(best, MeetingVoices.similarity(print, other))
            }
        }
        return best
    }

    static func compatible(_ a: MeetingSpeaker, _ b: MeetingSpeaker) -> Bool {
        func named(_ speaker: MeetingSpeaker) -> String? {
            let name = speaker.name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            return name.isEmpty ? nil : name
        }
        if let first = named(a), let second = named(b), first != second { return false }
        return true
    }
}
