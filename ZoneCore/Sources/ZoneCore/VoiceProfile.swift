// by zayd/cold @ zayd.wtf

import Foundation

/// The voice prints voice setup made (`VoiceSetup`): one per part the person recorded.
///
/// Only the prints are kept: 256 numbers per part, from which no words or audio can be
/// recovered. The recording itself is never written to disk. A profile made by another speaker
/// model cannot be compared with this one's prints and is ignored until the setup is redone.
public struct VoiceProfile: Codable, Equatable, Sendable {
    public struct Print: Codable, Equatable, Sendable {
        public var part: VoiceSetup.Part
        /// Unit length.
        public var voice: [Float]
        /// Seconds of speech it was made from.
        public var seconds: Double
        public var recordedAt: Date

        public init(part: VoiceSetup.Part, voice: [Float], seconds: Double, recordedAt: Date) {
            self.part = part
            self.voice = MeetingSecondLook.unit(voice).map(Float.init)
            self.seconds = seconds
            self.recordedAt = recordedAt
        }
    }

    public static let currentVersion = 1
    public var version: Int
    /// The speaker model the prints came from (`MeetingDiarizer.modelName` in the app).
    public var model: String
    public var prints: [Print]
    public var createdAt: Date

    public init(model: String, prints: [Print], createdAt: Date) {
        version = Self.currentVersion
        self.model = model
        self.prints = prints
        self.createdAt = createdAt
    }

    public func print(_ part: VoiceSetup.Part) -> Print? { prints.first { $0.part == part } }

    public var parts: [VoiceSetup.Part] { prints.map(\.part) }

    /// Seconds of speech per part.
    public var seconds: [VoiceSetup.Part: Double] {
        Dictionary(prints.map { ($0.part, $0.seconds) }, uniquingKeysWith: +)
    }

    /// The print meetings compare speakers with (`MeetingKnownVoices`): reading, talking and the
    /// far part as one mean, weighted by speech; nil without any of them.
    ///
    /// Measured (scripts/meeting-eval/voice-setup.py, EARS, 12 people, 134 one-minute meetings
    /// with the phone behind the speaker): reading and talking named the speaker in 91% at 0.70;
    /// the far part averaged in, 93% (71% at 0.75), with strangers at most 0.37; kept apart and
    /// matched on the better of the two, 91% (65%), strangers up to 0.43. On AMI the mean also kept
    /// strangers lower (0.48 against 0.52), every speaker named in both.
    public var meetingVoice: [Float]? {
        let voiced = prints.filter { $0.part != .whisper }
        guard let dimension = voiced.first?.voice.count else { return nil }
        var sum = [Double](repeating: 0, count: dimension)
        for print in voiced where print.voice.count == dimension {
            for index in sum.indices { sum[index] += Double(print.voice[index]) * print.seconds }
        }
        return MeetingSecondLook.unit(sum.map(Float.init)).map(Float.init)
    }

    /// The whisper's print, matched only at `VoiceSetup.whisperThreshold`: from a normal voice it
    /// recognizes 8% of someone's whispering at 0.70, from their whisper 92%, but two different
    /// people's whispers reached 0.68.
    public var whisperVoice: [Float]? { print(.whisper)?.voice }

    /// The voiced parts (read, talk, far) that sound like someone other than the rest: below
    /// `VoiceSetup.samePerson` against the mean of the others. Needs two or more voiced parts; the
    /// whisper is never judged, since a whisper sounds unlike its own speaker's voice.
    public static func strangers(in prints: [Print]) -> Set<VoiceSetup.Part> {
        let voiced = prints.filter { $0.part != .whisper }
        guard voiced.count >= 2 else { return [] }
        var out = Set<VoiceSetup.Part>()
        for print in voiced {
            let others = voiced.filter { $0.part != print.part && $0.voice.count == print.voice.count }
            guard !others.isEmpty else { continue }
            var sum = [Double](repeating: 0, count: print.voice.count)
            for other in others { for index in sum.indices { sum[index] += Double(other.voice[index]) } }
            if MeetingVoices.similarity(print.voice, sum.map(Float.init)) < VoiceSetup.samePerson { out.insert(print.part) }
        }
        // Two parts that disagree only with each other: neither can be blamed.
        return out.count == voiced.count ? Set(voiced.map(\.part)) : out
    }

    /// How alike two of the prints are (cosine), for the summary after setup.
    public func similarity(_ a: VoiceSetup.Part, _ b: VoiceSetup.Part) -> Double? {
        guard let x = print(a), let y = print(b) else { return nil }
        return MeetingVoices.similarity(x.voice, y.voice)
    }
}

/// One profile on disk, `<directory>/voice-profile.json`. Thread-safe. Kept out of backups and
/// readable only after the phone has been unlocked once, like the meetings it names.
public final class VoiceProfileStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL) { self.directory = directory }

    public static let `default`: VoiceProfileStore = {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return VoiceProfileStore(directory: support.appendingPathComponent("Voice", isDirectory: true))
    }()

    public var url: URL { directory.appendingPathComponent("voice-profile.json") }

    /// The saved profile; nil when there is none or it cannot be read.
    public func load() -> VoiceProfile? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let profile = try? decoder.decode(VoiceProfile.self, from: data),
              profile.version <= VoiceProfile.currentVersion else { return nil }
        return profile
    }

    /// The saved profile when it came from `model`; prints from another model mean nothing here.
    public func load(model: String) -> VoiceProfile? {
        load().flatMap { $0.model == model ? $0 : nil }
    }

    public func save(_ profile: VoiceProfile) throws {
        try locked { try write(profile) }
        // Outside the lock: an observer may read the profile at once.
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    public func delete() throws {
        try locked {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func locked(_ body: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        try body()
    }

    private func write(_ profile: VoiceProfile) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folder = directory
        try folder.setResourceValues(values)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(profile)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    public static let didChange = Notification.Name("ZoneVoiceProfileDidChange")
}
