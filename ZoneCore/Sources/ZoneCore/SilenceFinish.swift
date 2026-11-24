// by zayd/cold @ zayd.wtf

import Foundation

/// Decides when a dictation has gone quiet for long enough to finish by itself. Off unless the
/// person turns it on (Settings > Finish when quiet), because a pause to think is part of
/// dictating: in 1,085 real dictations 28% held a 2 second pause between words, 6.5% a 10 second
/// one and 1.4% a 30 second one.
///
/// Feed it the meter level (`AdaptiveLevelScale`, 0...1) about 20 times a second with monotonic
/// seconds. It never finishes before it has heard a voice, so a slow start is safe, and a new
/// speech-level sound starts the wait over.
///
/// The fifth percentile of the last minute estimates the room. A small margin over it
/// tolerates a steady fan or music bed. Two louder samples are needed to hear speech.
/// A gap freezes observed quiet time until the microphone supplies another sample.
///
/// Replay of the measured dictations with the timer enabled. "Ended early" is a pause before
/// more words. "Near speech" includes a stop before the first word, inside a word, or too soon
/// after one (more than two seconds of the wait left). Run scripts/quiet-eval/measure.py to verify.
///
/// Wait    Ended early       Near speech
/// 2 s     208 (19.2%)      45
/// 3 s     134 (12.4%)      30
/// 5 s     85 (7.8%)      11
/// 6 s     69 (6.4%)      13
/// 7 s     57 (5.3%)      8
/// 10 s     31 (2.9%)      7
/// 30 s     4 (0.4%)      0
public struct SilenceFinish: Sendable {
    /// Choices for Settings.
    /// 2, 6 and 7 came back on November 22: Zayd wants to try them on his own phone to find his
    /// wait (he suspects 6). The replay above includes all seven choices.
    public static let waitChoices: [TimeInterval] = [2, 3, 5, 6, 7, 10, 30]
    public static let defaultWait: TimeInterval = 5

    public static let customWaitRange: ClosedRange<TimeInterval> = 1...60

    public static func nearestChoice(_ wait: TimeInterval) -> TimeInterval {
        guard wait.isFinite, wait > 0 else { return defaultWait }
        return min(max(wait.rounded(), customWaitRange.lowerBound), customWaitRange.upperBound)
    }

    /// The keyboard offers presets plus the saved time, even while quiet finish is off.
    public static func waitChoices(including wait: TimeInterval) -> [TimeInterval] {
        let current = nearestChoice(wait)
        return waitChoices.contains(current) ? waitChoices : (waitChoices + [current]).sorted()
    }

    /// "5 seconds", "1 minute".
    public static func waitLabel(_ wait: TimeInterval) -> String {
        if wait == 1 { return "1 second" }
        if wait < 60 { return "\(Int(wait)) seconds" }
        let minutes = Int(wait / 60)
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    public enum Reading: Equatable, Sendable {
        /// No voice yet. Quiet before the first word never ends a dictation.
        case waitingForVoice
        /// Sound within the last moment.
        case hearing
        /// Quiet since the last sound; this long until it finishes.
        case quiet(remaining: TimeInterval)
        /// Quiet for the whole wait: finish now. Reported once, then the wait starts over.
        case finish
    }

    public let wait: TimeInterval

    /// How long the quiet lasts before the recording's surfaces say "Quiet": two seconds, or
    /// half a shorter wait. Sooner than this, every breath between sentences would flash it.
    public static func noticeDelay(wait: TimeInterval) -> TimeInterval { min(2, wait / 2) }

    /// Whether a quiet with `remaining` left of `wait` has lasted long enough to say so.
    public static func saysQuiet(remaining: TimeInterval, wait: TimeInterval) -> Bool {
        wait - remaining >= noticeDelay(wait: wait)
    }

    /// The whole seconds the keyboard and the dictation screen count down ("Finishing in 3"):
    /// from the moment "Quiet" is said, so a breath never flashes a number, and only over the
    /// last five seconds of a longer wait. Nil otherwise. A 5 s wait counts 3, 2, 1; a 3 s wait 2, 1.
    public static func countdown(remaining: TimeInterval, wait: TimeInterval) -> Int? {
        guard remaining > 0, remaining <= 5, saysQuiet(remaining: remaining, wait: wait) else { return nil }
        return Int(remaining.rounded(.up))
    }

    static let fixedBar: Float = -43.6
    static let aboveRoom: Float = 6
    static let underVoice: Float = 10
    static let memory: TimeInterval = 60
    /// A sound is two loud samples among the last six (about 0.3 s), so one click is not a voice.
    static let loudNeeded = 2, loudWindow = 6
    /// Samples further apart than this mean the microphone was away (a call, a pause). The
    /// time in between is not judged.
    static let longestStep: TimeInterval = 1

    private var bins = [Int](repeating: 0, count: 51)   // -50...0 dBFS, 1 dB each
    private var history: [(at: TimeInterval, bin: Int)] = []
    private var historyStart = 0
    // A short reply can occupy less than 5% of the minute. Keep the quieter of two
    // adjacent speech samples for the current wait so the room does not become the voice.
    private var previousDB: Float?
    private var pairedDB: Float?
    private var recentVoice: (db: Float, at: TimeInterval)?
    private var recentLoud: [Bool] = []
    private var heardVoice = false
    private var lastSound: TimeInterval = 0
    private var lastSample: TimeInterval?
    private var firstVoiceDB: Float?
    private var voiceHasVaried = false
    private var steadyBand: (low: Float, high: Float, since: TimeInterval)?
    private var onNewFloor = false

    /// A steady sound has a narrow envelope over many actual meter samples. The
    /// first unchanging sound alone cannot establish both a voice and its new floor.
    private mutating func followsSteadyFloor(_ db: Float, at now: TimeInterval) -> Bool {
        guard heardVoice else { return false }
        if firstVoiceDB == nil { firstVoiceDB = previousDB ?? db }
        if let firstVoiceDB, abs(db - firstVoiceDB) > 3 { voiceHasVaried = true }
        guard voiceHasVaried else { return false }
        if let band = steadyBand, max(band.high, db) - min(band.low, db) <= 2.5 {
            steadyBand = (min(band.low, db), max(band.high, db), band.since)
            if !onNewFloor, now - band.since >= 1.25 {
                lastSound = min(lastSound, band.since)
                recentLoud.removeAll()
                onNewFloor = true
            }
        } else {
            steadyBand = (db, db, now)
            onNewFloor = false
        }
        return onNewFloor
    }

    public init(wait: TimeInterval = SilenceFinish.defaultWait) {
        self.wait = max(wait, 1)
    }

    /// The meter level as dBFS, the inverse of `AdaptiveLevelScale.map`.
    public static func decibels(forLevel level: Float) -> Float {
        let span = AdaptiveLevelScale.ceilingDecibels - AdaptiveLevelScale.floorDecibels
        return AdaptiveLevelScale.floorDecibels + span * pow(min(max(level, 0), 1), 1 / AdaptiveLevelScale.curve)
    }

    /// Starts the wait over without forgetting the room: after a pause or an interruption.
    public mutating func restartWait(at now: TimeInterval) {
        lastSound = now
        lastSample = now
        recentLoud.removeAll()
        previousDB = nil
        pairedDB = nil
        recentVoice = nil
        steadyBand = nil
        onNewFloor = false
    }

    public mutating func sample(level: Float, at now: TimeInterval) -> Reading {
        guard level.isFinite, now.isFinite else { return heardVoice ? .hearing : .waitingForVoice }
        if let last = lastSample, now - last > Self.longestStep || now < last {
            if let band = steadyBand { steadyBand = (band.low, band.high, band.since + (now - last)) }
            lastSound += now - last
            recentLoud.removeAll()
            previousDB = nil
            pairedDB = nil
        }
        lastSample = now

        let decibels = Self.decibels(forLevel: level)
        let bin = Int(decibels.rounded()) - Int(AdaptiveLevelScale.floorDecibels)
        bins[min(max(bin, 0), 50)] += 1
        history.append((now, min(max(bin, 0), 50)))
        while historyStart < history.count, now - history[historyStart].at > Self.memory {
            bins[history[historyStart].bin] -= 1
            historyStart += 1
        }
        if historyStart > 4_096 {
            history.removeFirst(historyStart)
            historyStart = 0
        }

        let room = percentile(5)
        // A recording can begin mid-word, before there is a room sample. Two initially
        // loud samples followed by a distinct drop establish that the first sound ended.
        if !heardVoice, let pairedDB, pairedDB > Self.fixedBar, pairedDB - decibels >= Self.underVoice {
            heardVoice = true
            lastSound = now
        }
        if let previousDB {
            let paired = min(previousDB, decibels)
            pairedDB = paired
            if paired >= room + Self.aboveRoom + Self.underVoice {
                recentVoice = (paired, now)
            }
        }
        let steady = followsSteadyFloor(decibels, at: now)
        previousDB = decibels
        if let voice = recentVoice, now - voice.at > wait + Self.longestStep { recentVoice = nil }
        recentLoud.append(!steady && decibels > bar)
        if recentLoud.count > Self.loudWindow { recentLoud.removeFirst() }
        if recentLoud.lazy.filter({ $0 }).count >= Self.loudNeeded {
            heardVoice = true
            lastSound = now
            return .hearing
        }
        guard heardVoice else { return .waitingForVoice }
        let remaining = wait - (now - lastSound)
        guard remaining <= 0 else { return .quiet(remaining: remaining) }
        lastSound = now
        return .finish
    }

    /// What the wait was judged against, for the recording log: the room, the voice and the
    /// bar between them in dBFS, and the share of the last minute's samples that passed the
    /// bar. A recording that ended while someone was still talking shows here as a voice that
    /// sat too close to the room (a car's microphone, 2026-11-22), which the words alone cannot.
    public var journalFields: [String: String] {
        let total = history.count - historyStart
        let threshold = bar
        let floor = Int(AdaptiveLevelScale.floorDecibels)
        let loud = total > 0 ? history[historyStart...].lazy.filter { Float($0.bin + floor) > threshold }.count : 0
        return ["roomDB": String(Int(percentile(5).rounded())), "voiceDB": String(Int(percentile(95).rounded())),
                "barDB": String(Int(threshold.rounded())), "samples": String(total),
                "loudShare": total > 0 ? String(format: "%.2f", Double(loud) / Double(total)) : "0"]
    }

    /// The level a sample must pass to count as sound, in dBFS.
    var bar: Float {
        let room = percentile(5), voice = max(percentile(95), recentVoice?.db ?? Self.fixedBar)
        return max(Self.fixedBar, min(room + Self.aboveRoom, max(room + 3, voice - Self.underVoice)))
    }

    private func percentile(_ percent: Int) -> Float {
        let total = history.count - historyStart
        guard total > 0 else { return 0 }
        let needed = Double(total) * Double(percent) / 100
        var seen = 0
        for (index, count) in bins.enumerated() {
            seen += count
            if seen > 0, Double(seen) >= needed { return Float(index) + AdaptiveLevelScale.floorDecibels }
        }
        return 0
    }
}
