// by zayd/cold @ zayd.wtf

import Foundation

/// A second, finer pass over the diarizer's speaker turns.
///
/// The diarizer labels speech in turns that can run for half a minute, so a quick exchange
/// inside one ("How did all that go?" / "It went really well.") lands under one name. The second
/// look slides a short window over the stretch, compares each window's voice print with every
/// speaker's voice print from the first pass, and decodes the most likely speaker per 100 ms
/// frame (Viterbi, with a cost per change of speaker and a small pull toward the first pass's
/// label). It also names audible stretches the first pass left without a speaker, which used to
/// reach the transcript as unlabeled lines.
///
/// Measured on 16 AMI test meetings (single distant microphone, the closest public match to a
/// phone on a table; scripts/meeting-eval): time under the wrong speaker fell from 3.9% to 3.2%
/// of speech, and audible stretches left without a speaker fell from 16.6% to 15.7%. Without
/// the first pass's pull the windows alone did far worse (9.8%), which is why
/// `prior` is there. Pure logic: the voice prints come in from the caller.
public enum MeetingSecondLook {
    public struct Parameters: Equatable, Sendable {
        /// Window length and step, seconds. A 0.75 s step scored as well as 0.5 s (3.26% against
        /// 3.22% under the wrong speaker) with a third fewer windows to embed; 2 s windows were no
        /// better than 1.5 s. Embedding costs about 0.34 s per minute of audio on an M4 Pro's
        /// Neural Engine and 0.85 s on its CPU at a 0.5 s step.
        public var width: Double = 1.5
        public var hop: Double = 0.75
        /// A window is embedded only with this much audible sound in it, seconds.
        public var minimumSpeech: Double = 0.5
        /// Score lost per change of speaker; a pause of `pauseSeconds` or more makes it cheaper.
        public var switchCost: Double = 0.35
        public var pauseSeconds: Double = 0.5
        public var pauseSwitchFactor: Double = 0.3
        /// Bonus for the first pass's label on a frame.
        public var prior: Double = 0.06
        /// An audible frame outside the first pass's turns is named only at this similarity.
        public var floor: Double = 0.2
        /// A change of speaker between touching turns moves to the quietest frame this close.
        public var snapReach: Double = 0.2
        /// Touching turns shorter than this join their longer neighbour.
        public var shortest: Double = 0.5
        public var frameSeconds: Double = 0.1
        public var silenceLevel: Float = 0.004
        public init() {}
    }

    /// The windows to embed over `[from, to)`, in meeting time. `levels` are RMS levels of
    /// `frameSeconds` frames from the start of the meeting.
    public static func windows(levels: [Float], from: Double, to: Double,
                               parameters p: Parameters = Parameters()) -> [Range<Double>] {
        guard to - from >= p.width / 2, p.hop > 0 else { return [] }
        var out: [Range<Double>] = []
        var centre = from + p.width / 2
        while centre < to - 0.2 {
            let start = max(from, centre - p.width / 2), end = min(to, centre + p.width / 2)
            let first = max(0, Int(start / p.frameSeconds))
            let last = min(levels.count, max(first + 1, Int(end / p.frameSeconds)))
            if first < last {
                var audible = 0
                for index in first..<last where levels[index] >= p.silenceLevel { audible += 1 }
                if Double(audible) * p.frameSeconds >= p.minimumSpeech { out.append(start..<end) }
            }
            centre += p.hop
        }
        return out
    }

    /// Relabeled, non-overlapping turns over `[from, to)`. `embeddings[i]` is the voice print of
    /// `windows[i]`; `voices` maps each first-pass speaker id to its voice print. Returns the
    /// first pass unchanged when there is nothing to compare with.
    public static func relabel(turns: [MeetingTurn], windows: [Range<Double>], embeddings: [[Float]],
                               voices: [String: [Float]], levels: [Float], from: Double, to: Double,
                               parameters p: Parameters = Parameters()) -> [MeetingTurn] {
        let speakers = voices.keys.sorted()
        let labeled = Set(turns.compactMap(\.speaker))
        guard !speakers.isEmpty, labeled.isSubset(of: Set(speakers)), windows.count == embeddings.count,
              let dimension = voices[speakers[0]]?.count, dimension > 0,
              voices.values.allSatisfy({ $0.count == dimension }),
              embeddings.allSatisfy({ $0.count == dimension }), to > from else { return turns }
        let prints = speakers.map { unit(voices[$0]!) }
        let k = speakers.count
        let frame = p.frameSeconds
        let base = Int((from / frame).rounded(.down))
        let n = max(0, Int((to / frame).rounded(.up)) - base)
        guard n > 0 else { return turns }

        // Frame scores: the mean cosine of the windows covering a frame, weighted toward the
        // window's centre.
        var score = [Double](repeating: 0, count: n * k)
        var weight = [Double](repeating: 0, count: n)
        for (window, vector) in zip(windows, embeddings) {
            let v = unit(vector)
            let sims = prints.map { dot($0, v) }
            let first = max(0, Int((window.lowerBound / frame).rounded(.down)) - base)
            let last = min(n, Int((window.upperBound / frame).rounded(.up)) - base)
            let mid = (window.lowerBound + window.upperBound) / 2, half = (window.upperBound - window.lowerBound) / 2
            guard first < last, half > 0 else { continue }
            for index in first..<last {
                let time = (Double(base + index) + 0.5) * frame
                let w = max(0.05, 1 - abs(time - mid) / half)
                weight[index] += w
                for j in 0..<k { score[index * k + j] += w * sims[j] }
            }
        }
        for index in 0..<n where weight[index] > 0 {
            for j in 0..<k { score[index * k + j] /= weight[index] }
        }

        // The first pass's label per frame.
        var firstPass = [Int](repeating: -1, count: n)
        let order = Dictionary(uniqueKeysWithValues: speakers.enumerated().map { ($1, $0) })
        for turn in turns {
            guard let speaker = turn.speaker, let j = order[speaker] else { continue }
            let first = max(0, Int((turn.start / frame).rounded(.down)) - base)
            let last = min(n, Int((turn.end / frame).rounded(.up)) - base)
            if first < last { for index in first..<last { firstPass[index] = j } }
        }

        // Speech: wherever the first pass heard a voice, or an audible frame a window covers
        // that sounds like someone.
        var speech: [Int] = []
        for index in 0..<n {
            if firstPass[index] >= 0 { speech.append(index); continue }
            let absolute = base + index
            guard weight[index] > 0, absolute < levels.count, levels[absolute] >= p.silenceLevel else { continue }
            var best = -Double.infinity
            for j in 0..<k { best = max(best, score[index * k + j]) }
            if best >= p.floor { speech.append(index) }
        }
        guard !speech.isEmpty else { return turns }

        func emission(_ index: Int, _ j: Int) -> Double {
            score[index * k + j] + (firstPass[index] == j ? p.prior : 0)
        }
        // Viterbi over speech frames; a silent frame carries the path across.
        var best = (0..<k).map { emission(speech[0], $0) }
        var back = [Int](repeating: 0, count: speech.count * k)
        for t in 1..<speech.count {
            let gap = Double(speech[t] - speech[t - 1] - 1) * frame
            let cost = gap < p.pauseSeconds ? p.switchCost : p.switchCost * p.pauseSwitchFactor
            var leader = 0
            for j in 1..<k where best[j] > best[leader] { leader = j }
            let move = best[leader] - cost
            var next = [Double](repeating: 0, count: k)
            for j in 0..<k {
                if best[j] >= move {
                    next[j] = best[j]; back[t * k + j] = j
                } else {
                    next[j] = move; back[t * k + j] = leader
                }
                next[j] += emission(speech[t], j)
            }
            best = next
        }
        var labels = [Int](repeating: -1, count: n)
        var j = 0
        for candidate in 1..<k where best[candidate] > best[j] { j = candidate }
        for t in stride(from: speech.count - 1, through: 0, by: -1) {
            labels[speech[t]] = j
            j = back[t * k + j]
        }

        var out: [MeetingTurn] = []
        for index in 0..<n where labels[index] >= 0 {
            let start = max(from, Double(base + index) * frame), end = min(to, Double(base + index + 1) * frame)
            guard end > start else { continue }
            let speaker = speakers[labels[index]]
            if let last = out.last, last.speaker == speaker, abs(last.end - start) < 1e-6 {
                out[out.count - 1].end = end
            } else {
                out.append(MeetingTurn(start: start, end: end, speaker: speaker))
            }
        }
        return absorbShort(snap(out, levels: levels, parameters: p), shortest: p.shortest)
    }

    /// Moves each change of speaker between touching turns to the quietest frame within
    /// `snapReach`, never past the middle of either turn, so a chunk cut falls between words.
    static func snap(_ turns: [MeetingTurn], levels: [Float], parameters p: Parameters) -> [MeetingTurn] {
        guard p.snapReach > 0, turns.count > 1, !levels.isEmpty else { return turns }
        var out = turns
        for index in 1..<out.count {
            let a = out[index - 1], b = out[index]
            guard a.speaker != b.speaker, b.start - a.end <= 0.05 else { continue }
            let low = max(b.start - p.snapReach, (a.start + a.end) / 2)
            let high = min(b.start + p.snapReach, (b.start + b.end) / 2)
            let first = Int((low / p.frameSeconds).rounded(.up))
            let last = min(Int((high / p.frameSeconds).rounded(.down)), levels.count - 1)
            guard first <= last, first >= 0 else { continue }
            var quietest = first
            for frame in first...last where levels[frame] < levels[quietest] { quietest = frame }
            let cut = (Double(quietest) + 0.5) * p.frameSeconds
            out[index - 1].end = cut
            out[index].start = cut
        }
        return out.filter { $0.end - $0.start > 1e-6 }
    }

    /// A turn shorter than `shortest` that touches another joins its longer touching neighbour:
    /// on its own it is too short to transcribe well, and the planner drops chunks under 0.3 s.
    static func absorbShort(_ turns: [MeetingTurn], shortest: Double) -> [MeetingTurn] {
        var out = turns
        var changed = true
        while changed {
            changed = false
            for index in out.indices where out[index].end - out[index].start < shortest {
                let turn = out[index]
                let previous = index > 0 && turn.start - out[index - 1].end <= 0.05 ? index - 1 : nil
                let next = index + 1 < out.count && out[index + 1].start - turn.end <= 0.05 ? index + 1 : nil
                guard previous != nil || next != nil else { continue }
                let host: Int
                if let previous, let next {
                    host = out[previous].end - out[previous].start >= out[next].end - out[next].start ? previous : next
                } else {
                    host = previous ?? next!
                }
                if host < index { out[host].end = turn.end } else { out[host].start = turn.start }
                out.remove(at: index)
                changed = true
                break
            }
        }
        var merged: [MeetingTurn] = []
        for turn in out {
            if let last = merged.last, last.speaker == turn.speaker, turn.start - last.end <= 0.05 {
                merged[merged.count - 1].end = turn.end
            } else {
                merged.append(turn)
            }
        }
        return merged
    }

    static func unit(_ v: [Float]) -> [Double] {
        let norm = v.reduce(0) { $0 + Double($1) * Double($1) }.squareRoot()
        return v.map { Double($0) / max(norm, 1e-9) }
    }

    static func dot(_ a: [Double], _ b: [Double]) -> Double {
        var sum = 0.0
        for index in a.indices { sum += a[index] * b[index] }
        return sum
    }
}

/// Voice prints across recordings: a resumed meeting's new stretch and a merged meeting are
/// diarized on their own, so the same person arrives under a new number. Matching their voice
/// prints keeps one person under one name.
///
/// Calibrated on AMI's four-meeting series, which share their four people (scripts/meeting-eval
/// match.py): the same person in two recordings scored 0.85 cosine or more in 95% of pairs, and
/// two different people never above 0.62. 0.75 sits between with room on both sides.
public enum MeetingVoices {
    public static let sameVoice = 0.75

    public static func similarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        return MeetingSecondLook.dot(MeetingSecondLook.unit(a), MeetingSecondLook.unit(b))
    }

    /// One-to-one matches, most similar pair first, each at `threshold` or above:
    /// new id → existing id.
    public static func match(_ new: [String: [Float]], to existing: [String: [Float]],
                             threshold: Double = sameVoice) -> [String: String] {
        var pairs: [(Double, String, String)] = []
        for (a, va) in new {
            for (b, vb) in existing {
                let s = similarity(va, vb)
                if s >= threshold { pairs.append((s, a, b)) }
            }
        }
        pairs.sort { $0.0 != $1.0 ? $0.0 > $1.0 : ($0.1, $0.2) < ($1.1, $1.2) }
        var out: [String: String] = [:]
        var taken = Set<String>()
        for (_, a, b) in pairs where out[a] == nil && !taken.contains(b) {
            out[a] = b
            taken.insert(b)
        }
        return out
    }
}
