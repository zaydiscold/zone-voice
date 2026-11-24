// by zayd/cold @ zayd.wtf

import Foundation

/// Whether the keyboard's speech helper may be asked to hold Zone's speech model.
///
/// On an iPhone, iOS gives the helper a hard 35 MB of memory and ends it the moment the model
/// makes its first prediction (iPhone 15 Pro, iOS 27.0, November 22, 2026: eight launches, eight
/// kills). Starting it again cannot help: it is ended for its size, not for being slow. Each
/// attempt cost the person seconds before the iPhone's own speech model could start, and a kill
/// during preparation left a 1.2 GB temporary file behind.
///
/// So one failure is remembered in the App Group for this app build and this iOS build, and
/// every host (the keyboard, the app) goes straight to the fallback after it. A new app build
/// or a new iOS build gets one new try, since either can change the limit.
public enum WorkerHealth {
    /// The app build and iOS build a decision was made on.
    public struct Build: Codable, Equatable, Sendable {
        public var app: String
        public var os: String

        public init(app: String, os: String) {
            self.app = app
            self.os = os
        }

        /// The running bundle's build number (one number for the app and its extensions) and the
        /// iOS build, such as "24A5390f".
        public static var current: Build {
            let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
            let version = ProcessInfo.processInfo.operatingSystemVersionString
            return Build(app: app, os: CompiledModelCache.osBuild(fromVersionString: version) ?? version)
        }
    }

    public enum Reason: String, Codable, Sendable {
        /// iOS ended the helper while a host waited for its answer.
        case ended
        /// The helper said how much memory iOS gives it, and it is less than the model needs.
        case tooLittleRoom
    }

    public struct Block: Codable, Equatable, Sendable {
        public var reason: Reason
        /// What the host was waiting for when the helper went away: "start", "warm", "recognize".
        public var stage: String?
        /// The helper's memory limit in MiB when it reported one.
        public var limitMB: Int?
        public var build: Build
        public var at: Date

        public init(reason: Reason, stage: String? = nil, limitMB: Int? = nil, build: Build, at: Date) {
            self.reason = reason
            self.stage = stage
            self.limitMB = limitMB
            self.build = build
            self.at = at
        }

        /// For the recording log: numbers and fixed words only.
        public var fields: [String: String] {
            var fields = ["helperBlock": reason.rawValue, "helperBlockedBuild": build.app, "helperBlockedOS": build.os,
                          "helperBlockedAt": String(Int(at.timeIntervalSince1970))]
            fields["helperStage"] = stage
            fields["helperLimitMB"] = limitMB.map(String.init)
            return fields
        }
    }

    public static let key = "speechHelperBlock"

    /// The App Group's defaults, which the app, the keyboard and the helper all read.
    public static var shared: UserDefaults? { UserDefaults(suiteName: AppGroup.identifier) }

    /// The remembered failure, if it was made on this app build and iOS build. One made on
    /// another build is forgotten here, which is how a new build gets its one new try.
    public static func block(in defaults: UserDefaults? = shared, build: Build = .current) -> Block? {
        guard let defaults, let data = defaults.data(forKey: key) else { return nil }
        guard let block = try? JSONDecoder().decode(Block.self, from: data), block.build == build else {
            defaults.removeObject(forKey: key)
            return nil
        }
        return block
    }

    @discardableResult
    public static func remember(_ reason: Reason, stage: String? = nil, limitMB: Int? = nil,
                                in defaults: UserDefaults? = shared, build: Build = .current,
                                now: Date = Date()) -> Block {
        let block = Block(reason: reason, stage: stage, limitMB: limitMB, build: build, at: now)
        if let data = try? JSONEncoder().encode(block) { defaults?.set(data, forKey: key) }
        return block
    }

    public static func forget(in defaults: UserDefaults? = shared) {
        defaults?.removeObject(forKey: key)
    }

    /// The least memory the helper must be allowed before it is asked to hold Fluid Speech Mini
    /// on the processor. Measured on a Mac with the same Core ML processor path
    /// (`MiniMemoryProbe`, November 22, 2026): the model adds 91 MB at its peak, the first
    /// encoder prediction, on top of a helper that weighs about 14 MB before any model work.
    /// That is 105 MB; half as much again is kept as room for the iPhone to differ. The
    /// iPhone's 35 MB is far below it.
    public static let neededMB = 160

    /// `limitBytes` is the helper's footprint plus what iOS says is left. Nil means the system
    /// reports no limit (the simulator), which is allowed.
    public static func reportedLimit(footprint: UInt64, left: UInt64) -> UInt64? {
        #if targetEnvironment(simulator) || os(macOS)
        if left == 0 { return nil }
        #endif
        guard footprint > 0 else { return 0 }
        return footprint + left
    }

    public static func hasRoom(limitBytes: UInt64?) -> Bool {
        guard let limitBytes else { return true }
        return limitBytes >= UInt64(neededMB) * 1_048_576
    }

    /// Whether an interruption counts as iOS ending the helper. Only on a device that enforces
    /// limits, only while the host was waiting for an answer, and only while the keyboard was on
    /// screen: a host that was hidden may simply have lost its helper with it.
    public static func countsAsEnded(waitingOn stage: String?, hostVisible: Bool, deviceEnforcesLimits: Bool) -> Bool {
        stage != nil && hostVisible && deviceEnforcesLimits
    }
}
