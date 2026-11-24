// by zayd/cold @ zayd.wtf

import Foundation

public enum QuickSetting: Codable, Equatable, Sendable {
    case quiet(enabled: Bool, wait: TimeInterval)
    case sounds(Bool)
    case graphic(MeterStyle)
    case hold(SpaceHold)

    public enum Key: String, Codable, Sendable, CaseIterable { case quiet, sounds, graphic, hold }
    public var key: Key {
        switch self {
        case .quiet: .quiet
        case .sounds: .sounds
        case .graphic: .graphic
        case .hold: .hold
        }
    }

    init(_ key: Key, from preferences: KeyboardPreferences) {
        switch key {
        case .quiet: self = .quiet(enabled: preferences.finishWhenQuiet, wait: preferences.quietWait)
        case .sounds: self = .sounds(preferences.soundsEnabled)
        case .graphic: self = .graphic(preferences.meterStyle)
        case .hold: self = .hold(preferences.spaceHold)
        }
    }

    public func apply(to preferences: inout KeyboardPreferences) {
        switch self {
        case let .quiet(enabled, wait):
            preferences.finishWhenQuiet = enabled
            preferences.quietWait = SilenceFinish.nearestChoice(wait)
        case let .sounds(on): preferences.soundsEnabled = on
        case let .graphic(style): preferences.meterStyle = style
        case let .hold(hold): preferences.spaceHold = hold
        }
    }
}

public struct QuickSettingRequest: Codable, Equatable, Sendable {
    public struct Stamp: Codable, Comparable, Sendable {
        public let time: Double
        public let id: UUID
        public init(at date: Date = Date(), after previous: Self? = nil) {
            time = max(date.timeIntervalSince1970, previous?.time.nextUp ?? -Double.infinity)
            id = UUID()
        }
        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.time == rhs.time ? lhs.id.uuidString < rhs.id.uuidString : lhs.time < rhs.time
        }
    }

    public let value: QuickSetting
    public let stamp: Stamp
    public let generation: QuickSettingRequest.Stamp?
    public init(_ value: QuickSetting, at date: Date = Date(), after previous: Stamp? = nil, generation: QuickSettingRequest.Stamp? = nil) {
        self.value = value
        self.generation = generation
        stamp = Stamp(at: date, after: previous)
    }

    public func isNewer(than stamps: [String: Stamp]) -> Bool {
        stamps[value.key.rawValue].map { $0 < stamp } ?? true
    }
}

/// Each tap has its own filename. Writers publish complete records by rename; the app
/// acknowledges only the IDs it read. A concurrent tap always has a different path.
public struct QuickSettingInbox: Sendable {
    public let directory: URL
    private let legacyFile: URL?
    public init(directory: URL, legacyFile: URL? = nil) {
        self.directory = directory
        self.legacyFile = legacyFile
    }

    private func file(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    public func submit(_ request: QuickSettingRequest) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(request).write(to: file(for: request.stamp.id), options: .atomic)
    }

    /// Compare against pending edits from other controllers as well as the published revision.
    public func submit(_ value: QuickSetting, known: KeyboardPreferences, at date: Date = Date()) throws -> QuickSettingRequest {
        let pending = try read()
        let effective = known.overlaying(pending)
        let request = QuickSettingRequest(value, at: date, after: effective.quickSettingStamps[value.key.rawValue],
                                          generation: known.quickSettingGeneration)
        try submit(request)
        // Scan after publishing so overlapping writers also remove the older record.
        let siblings = try records().filter { $0.value.key == value.key && $0.generation == request.generation }
        if let newest = siblings.last {
            prune(siblings.filter { $0.stamp < newest.stamp })
        }
        return request
    }

    public func read() throws -> [QuickSettingRequest] {
        // If an old record cannot yet be read, leave it for another attempt. New
        // records still drain independently.
        try? importLegacyFile()
        return try records()
    }

    private func records() throws -> [QuickSettingRequest] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                options: .skipsHiddenFiles)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        let decoder = JSONDecoder()
        return files.compactMap { url -> QuickSettingRequest? in
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url) else { return nil }
            guard let request = try? decoder.decode(QuickSettingRequest.self, from: data),
                  request.stamp.id == UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                try? quarantine(url)
                return nil
            }
            return request
        }.sorted { $0.stamp < $1.stamp }
    }

    /// A failed removal simply leaves an acknowledged ID for a later drain.
    public func prune(_ requests: [QuickSettingRequest]) {
        for request in requests { try? FileManager.default.removeItem(at: file(for: request.stamp.id)) }
    }

    private func quarantine(_ url: URL) throws {
        try FileManager.default.moveItem(at: url, to: url.deletingPathExtension()
            .appendingPathExtension(UUID().uuidString + ".invalid"))
    }

    // Preserve pending choices from the preceding review build. Its writer coordinates this file.
    private func importLegacyFile() throws {
        guard let legacyFile, FileManager.default.fileExists(atPath: legacyFile.path) else { return }
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: legacyFile, options: .forMerging, error: &coordinationError) { url in
            result = Result {
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                let data = try Data(contentsOf: url)
                guard let requests = try? JSONDecoder().decode([QuickSettingRequest].self, from: data) else {
                    try quarantine(url)
                    return
                }
                for request in requests {
                    try submit(request)
                }
                try FileManager.default.removeItem(at: url)
            }
        }
        if let coordinationError { throw coordinationError }
        try result?.get()
    }

    public func overlay(on snapshot: @autoclosure () -> KeyboardPreferences) -> KeyboardPreferences {
        // Sample the queue before the snapshot. A request pruned during this read is
        // already in the published snapshot that we read second.
        let pending = (try? read()) ?? []
        return snapshot().overlaying(pending)
    }
}

extension KeyboardPreferences {
    public func overlaying(_ pending: [QuickSettingRequest]) -> Self {
        var effective = self
        for request in pending where (request.generation == nil || request.generation == quickSettingGeneration) && request.isNewer(than: effective.quickSettingStamps) {
            request.value.apply(to: &effective)
            effective.quickSettingStamps[request.value.key.rawValue] = request.stamp
        }
        return effective
    }
}
