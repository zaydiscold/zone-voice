// by zayd/cold @ zayd.wtf

import Foundation

/// What the phone says about setup at one moment, read by the app from the same places the
/// walkthrough reads: the model's state, the record permission, iOS's list of keyboards, the
/// keyboard's own presence record and the dictations counted.
public struct SetupFacts: Equatable, Sendable {
    public enum Model: Equatable, Sendable {
        case missing
        case downloading(fraction: Double)
        case loading
        case ready
        case failed(String)
    }

    public enum Microphone: Equatable, Sendable {
        case undetermined, granted, denied
    }

    public enum Recording: Equatable, Sendable {
        case idle
        /// The words recognized so far, live.
        case listening(String)
        case recognizing
    }

    public var model: Model
    /// The model's download size; 0 for a model built into iOS.
    public var modelBytes: Int64
    public var microphone: Microphone
    /// iOS lists Zone's keyboard among the person's keyboards.
    public var keyboardAdded: Bool
    /// What the keyboard said the last time it ran; nil until it has run once.
    public var fullAccess: Bool?
    public var recording: Recording
    /// The words of the first dictation made during setup, once it has landed.
    public var firstDictation: String?
    /// The Action Button or a control started a voice note during setup.
    public var buttonPressed: Bool

    public init(model: Model, modelBytes: Int64, microphone: Microphone, keyboardAdded: Bool,
                fullAccess: Bool?, recording: Recording = .idle, firstDictation: String? = nil,
                buttonPressed: Bool = false) {
        self.model = model
        self.modelBytes = modelBytes
        self.microphone = microphone
        self.keyboardAdded = keyboardAdded
        self.fullAccess = fullAccess
        self.recording = recording
        self.firstDictation = firstDictation
        self.buttonPressed = buttonPressed
    }
}

/// One line of the setup log. Lines are only ever added, each for something the phone reported,
/// so the log reads back as what actually happened.
public struct SetupLine: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Something finished and checked.
        case done
        /// Under way; only the live line has this kind.
        case working
        /// Went wrong, with what to do in `detail`.
        case problem
        /// The person's own words.
        case said
        /// A choice the person made (a skip).
        case note
    }

    public let id: String
    public let kind: Kind
    public let text: String
    public let detail: String?
    /// 0...1 for a line that measures something (the download).
    public let fraction: Double?

    public init(id: String, kind: Kind, text: String, detail: String? = nil, fraction: Double? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.detail = detail
        self.fraction = fraction
    }
}

/// The one question setup asks now. Exactly one at a time, always the next thing that is not
/// done, so the person never has to work out where they are.
public enum SetupPrompt: Equatable, Sendable {
    case downloadModel
    case retryDownload(String)
    case microphone
    case microphoneDenied
    case addKeyboard
    /// iOS lists the keyboard but it has not run: it has to come up once in the practice box.
    case switchToKeyboard
    case fullAccessOff
    /// Everything for a dictation is in place except the model, which is still on its way.
    case waitForModel
    case dictate
    case actionButton
    case finish
}

/// What the person tapped, as far as the log needs to know.
public enum SetupAnswer: Equatable, Sendable {
    case download
    case skipDictation
    case skipActionButton
}

/// The setup session: the log of lines, the live line that rewrites itself in place, and the
/// question to ask now. It only describes; the app performs every action and reports back
/// through `observe`.
public struct SetupSession: Equatable, Sendable {
    public private(set) var lines: [SetupLine] = []
    public private(set) var startedAt: Date?
    public private(set) var finishedAt: Date?
    private var facts: SetupFacts?
    private var downloadConsented = false
    private var skippedDictation = false
    private var skippedButton = false
    private var meter = DownloadMeter()
    /// When this session first saw the download move; nil when the model was already here.
    private var downloadStartedAt: Date?

    public init() {}

    // MARK: Reading

    public var prompt: SetupPrompt {
        guard let facts else { return .downloadModel }
        switch facts.model {
        case .missing where !downloadConsented: return .downloadModel
        case .failed(let message): return .retryDownload(message)
        default: break
        }
        switch facts.microphone {
        case .undetermined: return .microphone
        case .denied: return .microphoneDenied
        case .granted: break
        }
        switch facts.fullAccess {
        case .some(false): return .fullAccessOff
        case .none: return facts.keyboardAdded ? .switchToKeyboard : .addKeyboard
        case .some(true): break
        }
        if facts.firstDictation == nil, !skippedDictation {
            return facts.model == .ready ? .dictate : .waitForModel
        }
        if !facts.buttonPressed, !skippedButton { return .actionButton }
        return .finish
    }

    /// The line that is under way, rewritten in place as it moves: the download, the load, or
    /// the dictation being heard. Nil when nothing is running.
    public var live: SetupLine? {
        guard let facts else { return nil }
        switch facts.recording {
        case .listening(let words):
            return SetupLine(id: "live.listening", kind: .working, text: "Listening",
                             detail: words.isEmpty ? "Say a sentence, then tap Stop (■)" : words)
        case .recognizing:
            return SetupLine(id: "live.recognizing", kind: .working, text: "Writing it down")
        case .idle:
            break
        }
        switch facts.model {
        case .downloading(let fraction):
            return SetupLine(id: "live.download", kind: .working, text: "Downloading the speech model",
                             detail: meter.label(fraction: fraction, total: facts.modelBytes), fraction: fraction)
        case .loading:
            return SetupLine(id: "live.loading", kind: .working, text: "Getting the speech model ready")
        default:
            return nil
        }
    }

    /// Steps not done or skipped yet, of the five: the model, the microphone, the keyboard with
    /// Full Access, a first dictation and the button.
    public var remaining: Int {
        guard let facts else { return 5 }
        return [
            facts.model != .ready,
            facts.microphone != .granted,
            facts.fullAccess != true,
            facts.firstDictation == nil && !skippedDictation,
            !facts.buttonPressed && !skippedButton,
        ].filter { $0 }.count
    }

    public var isFinished: Bool { finishedAt != nil }

    /// "48 s", the time from the first line to the last.
    public var elapsedLabel: String? {
        guard let startedAt, let finishedAt else { return nil }
        return Self.durationLabel(finishedAt.timeIntervalSince(startedAt))
    }

    // MARK: Changes

    public mutating func observe(_ next: SetupFacts, at now: Date) {
        let previous = facts
        facts = next
        if startedAt == nil { startedAt = now }
        if case .downloading(let fraction) = next.model { meter.sample(fraction: fraction, total: next.modelBytes, at: now) }
        modelLines(previous: previous, next: next, now: now)
        microphoneLines(previous: previous, next: next)
        keyboardLines(previous: previous, next: next)
        if let words = next.firstDictation, previous?.firstDictation == nil {
            append(SetupLine(id: "said", kind: .said, text: words))
            let count = words.split(whereSeparator: \.isWhitespace).count
            append(SetupLine(id: "dictation.done", kind: .done, text: "First dictation typed",
                             detail: count == 1 ? "1 word" : "\(count) words"))
        }
        if next.buttonPressed, previous?.buttonPressed != true {
            append(SetupLine(id: "button.done", kind: .done, text: "Your button started a voice note"))
        }
    }

    public mutating func answer(_ answer: SetupAnswer, at now: Date) {
        switch answer {
        case .download:
            downloadConsented = true
            meter = DownloadMeter()
            downloadStartedAt = nil
        case .skipDictation:
            skippedDictation = true
            append(SetupLine(id: "dictation.skipped", kind: .note, text: "Skipped the first dictation"))
        case .skipActionButton:
            skippedButton = true
            append(SetupLine(id: "button.skipped", kind: .note, text: "No button for now",
                             detail: "Settings, Action Button, Controls, then Zone"))
        }
    }

    public mutating func finish(at now: Date) {
        guard finishedAt == nil else { return }
        finishedAt = now
        append(SetupLine(id: "finished", kind: .done, text: "Zone is ready",
                         detail: elapsedLabel.map { "Set up in \($0)" }))
    }

    // MARK: Lines

    private mutating func modelLines(previous: SetupFacts?, next: SetupFacts, now: Date) {
        if case .downloading = next.model, downloadStartedAt == nil { downloadStartedAt = now }
        switch next.model {
        case .ready:
            guard previous?.model != .ready else { return }
            if let downloadStartedAt {
                append(SetupLine(id: "model.done", kind: .done, text: "Speech model downloaded",
                                 detail: "\(Self.bytesLabel(next.modelBytes)) in \(Self.durationLabel(now.timeIntervalSince(downloadStartedAt)))"))
            } else {
                append(SetupLine(id: "model.done", kind: .done,
                                 text: next.modelBytes == 0 ? "Speech uses Apple's built-in model" : "Speech model is on this iPhone"))
            }
        case .failed(let message):
            guard previous?.model != next.model else { return }
            append(SetupLine(id: "model.failed.\(lines.count)", kind: .problem, text: "The download stopped",
                             detail: message))
            meter = DownloadMeter()
            downloadStartedAt = nil
        case .missing, .downloading, .loading:
            break
        }
    }

    private mutating func microphoneLines(previous: SetupFacts?, next: SetupFacts) {
        switch next.microphone {
        case .granted:
            append(SetupLine(id: "microphone.done", kind: .done, text: "Microphone allowed"))
        case .denied:
            guard previous?.microphone != .denied else { return }
            append(SetupLine(id: "microphone.denied.\(lines.count)", kind: .problem, text: "The microphone is off",
                             detail: "Turn it on for Zone in Settings, then come back"))
        case .undetermined:
            break
        }
    }

    private mutating func keyboardLines(previous: SetupFacts?, next: SetupFacts) {
        if next.keyboardAdded || next.fullAccess != nil {
            append(SetupLine(id: "keyboard.added", kind: .done, text: "Zone keyboard added"))
        }
        switch next.fullAccess {
        case .some(true):
            append(SetupLine(id: "keyboard.fullAccess", kind: .done, text: "Full Access on",
                             detail: "The keyboard can receive your words"))
        case .some(false):
            guard previous?.fullAccess != .some(false) else { return }
            append(SetupLine(id: "keyboard.fullAccessOff.\(lines.count)", kind: .problem, text: "Full Access is off",
                             detail: "The keyboard cannot receive your words without it"))
        case .none:
            break
        }
    }

    /// Adds a line once: a line whose id is already in the log is never printed again.
    private mutating func append(_ line: SetupLine) {
        guard !lines.contains(where: { $0.id == line.id }) else { return }
        lines.append(line)
    }

    // MARK: Labels

    static func bytesLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func durationLabel(_ seconds: TimeInterval) -> String {
        let whole = max(1, Int(seconds.rounded()))
        if whole < 60 { return "\(whole) s" }
        let minutes = whole / 60, rest = whole % 60
        return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
    }
}

/// Size, speed and time left for the download, from the progress reports themselves. Speed is
/// taken over the last few seconds so a stall shows as a stall, not as an old average.
struct DownloadMeter: Equatable, Sendable {
    private struct Sample: Equatable, Sendable {
        let at: Date
        let bytes: Double
    }

    static let window: TimeInterval = 4
    private var samples: [Sample] = []

    mutating func sample(fraction: Double, total: Int64, at now: Date) {
        let bytes = max(0, min(1, fraction)) * Double(total)
        if let last = samples.last, bytes < last.bytes { samples.removeAll() }
        samples.append(Sample(at: now, bytes: bytes))
        // The oldest sample inside the window stays, plus one just before it, so a report every
        // few seconds still gives a speed.
        while samples.count > 2, now.timeIntervalSince(samples[1].at) > Self.window { samples.removeFirst() }
    }

    /// Bytes a second over the window, or nil before there is a second of reports to go on.
    var bytesPerSecond: Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let span = last.at.timeIntervalSince(first.at)
        guard span >= 1 else { return nil }
        return max(0, (last.bytes - first.bytes) / span)
    }

    /// "42% · 106 of 253 MB · 8.1 MB/s · about 18 s left"
    func label(fraction: Double, total: Int64) -> String {
        let clamped = max(0, min(1, fraction))
        let done = Int64(clamped * Double(total))
        var parts = ["\(Int(clamped * 100))%", "\(Self.megabytes(done)) of \(SetupSession.bytesLabel(total))"]
        if let speed = bytesPerSecond {
            if speed < 1 {
                parts.append("waiting for the network")
            } else {
                parts.append("\(SetupSession.bytesLabel(Int64(speed)))/s")
                let left = (Double(total) - Double(done)) / speed
                if left >= 1 { parts.append("about \(SetupSession.durationLabel(left)) left") }
            }
        }
        return parts.joined(separator: " · ")
    }

    /// Whole decimal megabytes without the unit, so "106 of 253 MB" says MB once and does not
    /// flicker through decimals.
    private static func megabytes(_ bytes: Int64) -> String {
        String(bytes / 1_000_000)
    }
}

public extension KeyboardPresence {
    func seenDuringSetup(since start: Date, now: Date = Date()) -> Self? {
        // The shared store writes ISO dates with whole-second precision.
        let firstSecond = floor(start.timeIntervalSince1970)
        return lastSeen.timeIntervalSince1970 >= firstSecond && lastSeen <= now ? self : nil
    }
}

public extension SetupFacts {
    /// Called once capture has started, with the source of that exact request.
    static func setupRecordingID(_ id: UUID, isNote: Bool, fromIntent: Bool) -> UUID? {
        isNote && fromIntent ? id : nil
    }
}
