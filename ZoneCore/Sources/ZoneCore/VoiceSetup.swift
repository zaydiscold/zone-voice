// by zayd/cold @ zayd.wtf

import Foundation

/// Teaching Zone your voice, on purpose: a few minutes of guided speech that becomes the voice
/// print meetings recognize you by (`VoiceProfile`, `MeetingKnownVoices`).
///
/// Without it Zone learns you only from a meeting where you tapped "This is me". The setup asks
/// for the voice meetings actually hear: reading aloud for coverage of every sound, talking
/// freely for your conversational voice, a whisper, and speech from across the room, which is
/// where the phone sits in a meeting. Pure logic: the app records, measures and embeds.
public enum VoiceSetup {
    public enum Part: String, Codable, CaseIterable, Sendable {
        case read, talk, whisper, far
    }

    public struct Step: Equatable, Sendable {
        public var part: Part
        public var title: String
        /// One line under the title: what to do.
        public var instruction: String
        /// Where to hold the phone, said before recording starts.
        public var placement: String
        /// Text to read or whisper; empty for free talk (`talkPrompts` or `farPrompt` instead).
        public var script: String
        /// Seconds of speech that finish the step.
        public var target: Double
        /// Seconds of speech that make a usable print if the person stops early.
        public var minimum: Double
        /// Seconds of countdown before recording, for putting the phone down.
        public var countdown: Int
        /// The step can be skipped; the first two cannot both be.
        public var skippable: Bool
    }

    /// The read-aloud passage. Written for Zone, so it carries no copyright: short and long
    /// words, numbers, a question that rises and a statement that falls, and every vowel.
    public static let passage = """
    Here is how my voice sounds on an ordinary day. I'm reading this out loud so Zone can \
    learn it, the way a friend learns to pick you out of a crowded room.

    Some words are short, like cat, yes and go. Others take longer, like thoroughly, \
    particularly and enthusiastic. Numbers sound different again: seven, thirty-three, \
    a hundred and twelve. When I ask a question, does my voice go up at the end? When I'm \
    sure of something, it comes down.

    Yesterday I walked past a bakery, a bike shop and a park where two dogs were chasing a \
    red ball. The weather changed three times before lunch. I thought about what to cook \
    for dinner, the email I still owe someone, and a song that has been stuck in my head \
    all week.

    Zone keeps a voice print, not this recording, and it stays on this iPhone. The next \
    time I'm in a meeting, it should know which voice is mine.
    """

    /// Questions shown one at a time while the person talks freely, so nobody runs dry.
    public static let talkPrompts = [
        "What have you done so far today?",
        "What's the next thing you have to do?",
        "Describe where you are right now.",
        "What did you last eat? Was it any good?",
        "Who did you talk to recently, and about what?",
        "What are you looking forward to this week?",
        "Explain what you do to someone who has never heard of it.",
        "What's something you changed your mind about lately?",
    ]

    /// Seconds of speech each talk prompt stays up before the next one.
    public static let promptSeconds = 9.0

    public static let whisperScript = """
    This is my quiet voice, the one for a library, a sleeping baby, or a meeting I should \
    not be talking in. Even when I whisper, Zone, this is still me.
    """

    /// What to talk about from across the room. Nobody can read a script on a phone six feet
    /// away, so this is read once, large, before the phone goes down.
    public static let farPrompt = "Talk about your plans for this week until Zone chimes."

    public static let steps: [Step] = [
        Step(part: .read, title: "Read aloud",
             instruction: "Read at your normal pace. Stumbles are fine; keep going.",
             placement: "Hold your phone the way you would for a voice message.",
             script: passage, target: 45, minimum: 25, countdown: 0, skippable: true),
        Step(part: .talk, title: "Talk about your day",
             instruction: "No script. Talk the way you would to a friend. New questions appear as you go.",
             placement: "Hold your phone the way you would for a voice message.",
             script: "", target: 30, minimum: 15, countdown: 0, skippable: true),
        Step(part: .whisper, title: "Whisper",
             instruction: "Whisper this, without using your voice.",
             placement: "Keep the phone close, about a hand's width from your mouth.",
             script: whisperScript, target: 8, minimum: 5, countdown: 0, skippable: true),
        Step(part: .far, title: "From across the room",
             instruction: "Put the phone down across the table or behind you, and talk at your normal volume.",
             placement: "About six feet away, where a phone sits in a meeting. A chime starts it and another ends it.",
             script: "", target: 18, minimum: 10, countdown: 5, skippable: true),
    ]

    public static func step(_ part: Part) -> Step { steps.first { $0.part == part }! }

    /// Two parts of one person's setup below this similarity sound like two people. Measured
    /// (scripts/meeting-eval/voice-setup.py, EARS, 12 people): one person's talking and far parts
    /// scored 0.91 and 0.85 or more against their reading and talking; two different people at
    /// most 0.42.
    public static let samePerson = 0.5

    /// A whisper's print names someone only at this similarity. Measured on whispered sentences:
    /// 92% of the person's own at 0.75 and 83% at 0.80; strangers' whispers up to 0.68.
    public static let whisperThreshold = 0.80

    /// The setup can be saved once reading and talking together reach this much speech.
    public static let minimumVoiced = 25.0

    /// True when `seconds` (speech per part) make a profile worth saving: enough of the person's
    /// normal voice, read or talked. Whisper and far alone never do.
    public static func canSave(_ seconds: [Part: Double]) -> Bool {
        seconds[.read, default: 0] + seconds[.talk, default: 0] >= minimumVoiced
    }

    /// The talk prompt to show after `speech` seconds of talking.
    public static func prompt(after speech: Double) -> String {
        talkPrompts[min(talkPrompts.count - 1, max(0, Int(speech / promptSeconds)))]
    }
}

/// Which 100 ms frames of a setup recording are speech. Levels come from `VoiceSetupLevels`,
/// above 150 Hz.
///
/// A fixed level misses a whisper and the far step, which arrive at a tenth of a normal voice's
/// level, and counts a noisy room as speech. The meter follows the room instead: its floor is the
/// quietest 5% of the last 30 s (nobody speaks that long without breath pauses and quiet
/// syllables filling more than that), and a frame is speech when it is `ratio` times the floor
/// and at least `minimumLevel`.
public struct VoiceSetupMeter: Equatable, Sendable {
    public static let frameSeconds = 0.1
    public var ratio: Float = 3
    /// -70 dB: above a phone microphone's own hiss once the rumble is filtered out.
    public var minimumLevel: Float = 0.0003
    /// Frames the floor looks back over.
    public var window = 300
    /// The floor's percentile of those frames.
    public var percentile = 0.05
    /// The floor until the meter has heard a second of the room, or less when it was quieter.
    public var quietRoom: Float = 0.001
    public private(set) var speechSeconds: Double = 0
    /// One flag per frame fed: true for speech.
    public private(set) var speech: [Bool] = []
    /// Each frame's level.
    public private(set) var levels: [Float] = []

    public init() {}

    public var frames: Int { levels.count }

    /// The room's level now.
    public var floor: Float {
        let recent = levels.suffix(window)
        guard recent.count >= 10 else { return min(quietRoom, recent.min() ?? quietRoom) }
        return recent.sorted()[Int(Double(recent.count) * percentile)]
    }

    /// Feeds one frame's RMS level; returns whether it is speech.
    @discardableResult
    public mutating func add(_ level: Float) -> Bool {
        levels.append(level)
        let isSpeech = level >= max(minimumLevel, floor * ratio)
        speech.append(isSpeech)
        if isSpeech { speechSeconds += Self.frameSeconds }
        return isSpeech
    }

    /// A level for the wave, 0...1, on a wider scale than dictation's so a whisper still moves:
    /// -70 dB to -10 dB, the high-passed level.
    public static func display(_ level: Float) -> Float {
        let decibels = 20 * log10(max(level, 1e-7))
        let x = min(max((decibels + 70) / 60, 0), 1)
        return pow(x, 1.2)
    }

    /// The RMS level of `samples`.
    public static func level(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Stretches to embed, in seconds from the start: speech frames joined across pauses shorter
    /// than `bridge`, padded by one frame, cut into pieces of at most `piece` seconds, and none
    /// shorter than `shortest`. The speaker model sees whole words this way, and no silence long
    /// enough to dilute the print.
    public func spans(bridge: Double = 0.5, piece: Double = 5, shortest: Double = 1.5) -> [Range<Double>] {
        let frame = Self.frameSeconds
        var regions: [Range<Double>] = []
        var start: Int?
        var lastSpeech = -1
        let bridgeFrames = Int((bridge / frame).rounded())
        for (index, isSpeech) in speech.enumerated() where isSpeech {
            if let first = start, index - lastSpeech > bridgeFrames + 1 {
                regions.append(Double(first) * frame..<Double(lastSpeech + 1) * frame)
                start = index
            } else if start == nil {
                start = index
            }
            lastSpeech = index
        }
        if let first = start { regions.append(Double(first) * frame..<Double(lastSpeech + 1) * frame) }
        let end = Double(speech.count) * frame
        var out: [Range<Double>] = []
        for region in regions {
            let padded = max(0, region.lowerBound - frame)..<min(end, region.upperBound + frame)
            let length = padded.upperBound - padded.lowerBound
            guard length >= shortest else { continue }
            let count = max(1, Int((length / piece).rounded(.up)))
            let step = length / Double(count)
            for index in 0..<count {
                out.append(padded.lowerBound + Double(index) * step..<padded.lowerBound + Double(index + 1) * step)
            }
        }
        return out
    }
}

/// A setup recording's 100 ms frame levels, measured above 150 Hz.
///
/// Rooms rumble (air conditioning, traffic, a hand on the phone) far below speech, and a whisper
/// has almost nothing below 1 kHz. Measured across the whole band, a whisper sat 5 dB over the
/// rumble of an EARS studio recording and the meter heard 12 to 22% of it; above 150 Hz it heard
/// 61 to 77%, against about 80% that is speech (scripts/meeting-eval/voice-setup.py, `meter`).
public struct VoiceSetupLevels: Sendable {
    public static let frameSamples = 1_600
    public static let cutoff = 150.0
    public static let sampleRate = 16_000.0

    // Second-order Butterworth high-pass (RBJ cookbook, Q = 1/sqrt 2).
    private let b0, b1, b2, a1, a2: Float
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
    private var sum: Float = 0
    private var count = 0

    public init(cutoff: Double = VoiceSetupLevels.cutoff, sampleRate: Double = VoiceSetupLevels.sampleRate) {
        let w = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w) / (2 * 0.5.squareRoot())
        let a0 = 1 + alpha
        b0 = Float((1 + cos(w)) / 2 / a0)
        b1 = Float(-(1 + cos(w)) / a0)
        b2 = b0
        a1 = Float(-2 * cos(w) / a0)
        a2 = Float((1 - alpha) / a0)
    }

    /// Feeds samples; returns the RMS level of each 100 ms frame they completed.
    public mutating func add<C: Collection>(_ samples: C) -> [Float] where C.Element == Float {
        var levels: [Float] = []
        for x in samples {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            sum += y * y
            count += 1
            if count == Self.frameSamples {
                levels.append((sum / Float(count)).squareRoot())
                sum = 0
                count = 0
            }
        }
        return levels
    }
}

public extension VoiceSetup {
    /// One part's voice print from its pieces' prints: their mean, weighted by length, after
    /// dropping pieces that do not sound like the rest (a cough, a door, someone else talking).
    /// A piece is dropped when its similarity to the mean of the others is below `outlier`; the
    /// mean is then taken again. Nil when nothing is left.
    static func print(of embeddings: [[Float]], seconds: [Double], outlier: Double = 0.35) -> [Float]? {
        guard embeddings.count == seconds.count, let dimension = embeddings.first?.count, dimension > 0,
              embeddings.allSatisfy({ $0.count == dimension }) else { return nil }
        let units = embeddings.map(MeetingSecondLook.unit)
        func mean(_ indices: [Int]) -> [Double]? {
            guard !indices.isEmpty else { return nil }
            var sum = [Double](repeating: 0, count: dimension)
            for index in indices {
                for d in 0..<dimension { sum[d] += units[index][d] * seconds[index] }
            }
            return MeetingSecondLook.unit(sum.map(Float.init))
        }
        var kept = Array(units.indices)
        if units.count >= 3 {
            var sum = [Double](repeating: 0, count: dimension)
            for index in kept { for d in 0..<dimension { sum[d] += units[index][d] * seconds[index] } }
            kept = kept.filter { index in
                // Leave-one-out: the piece against everything else.
                var others = sum
                for d in 0..<dimension { others[d] -= units[index][d] * seconds[index] }
                return MeetingSecondLook.dot(MeetingSecondLook.unit(others.map(Float.init)), units[index]) >= outlier
            }
        }
        return mean(kept).map { $0.map(Float.init) }
    }
}
