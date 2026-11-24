// by zayd/cold @ zayd.wtf

import Foundation

/// A hidden switch for measuring where Zone's speech model fits on a real iPhone.
///
/// It is a file, not a setting: `Library/Application Support/Lab/own-model.json` in the App
/// Group. Nothing in the app writes it, so a tester cannot turn it on. A developer copies it to
/// the phone with `devicectl device copy to`. It names the build it is for and stops working on
/// any other build, so it cannot follow the phone into a later update.
///
/// Each dictation the keyboard records by itself then runs the next step of the plan after its
/// words are written, and every stage's memory and time go to the recording log (`ownModelLab`).
public struct OwnModelLab: Codable, Equatable, Sendable {
    public struct Step: Codable, Equatable, Sendable {
        public enum Place: String, Codable, Sendable {
            /// Inside the keyboard's own process.
            case keyboard
            /// Inside the speech helper (the ExtensionKit extension).
            case helper
            /// Inside the lab's audio unit extension, when the build carries one.
            case audioUnit
        }
        public var place: Place
        public var units: MiniMemoryProbeUnits
        /// Encoder passes to run. One pass is up to 15 seconds of speech.
        public var windows: Int?

        public init(place: Place, units: MiniMemoryProbeUnits, windows: Int? = nil) {
            self.place = place
            self.units = units
            self.windows = windows
        }
    }

    /// The app build this file is for (`CFBundleVersion`).
    public var build: String
    public var plan: [Step]

    public init(build: String, plan: [Step]) {
        self.build = build
        self.plan = plan
    }

    public static let relativePath = "Library/Application Support/Lab/own-model.json"
    static let progressKey = "ownModelLabProgress"

    public static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)?
            .appendingPathComponent(relativePath)
    }

    /// The plan, only when the file exists, parses and names this build.
    public static func read(from url: URL? = fileURL, build: String = WorkerHealth.Build.current.app) -> OwnModelLab? {
        guard let url, let data = try? Data(contentsOf: url),
              let lab = try? JSONDecoder().decode(OwnModelLab.self, from: data),
              lab.build == build, !lab.plan.isEmpty else { return nil }
        return lab
    }

    /// Takes the next step and records that it started, before it runs: a step that gets the
    /// process ended must not run again on the next dictation.
    public func takeNextStep(in defaults: UserDefaults? = WorkerHealth.shared) -> (index: Int, step: Step)? {
        guard let defaults else { return nil }
        let saved = defaults.dictionary(forKey: Self.progressKey)
        let done = (saved?["build"] as? String) == build ? (saved?["done"] as? Int ?? 0) : 0
        guard done < plan.count else { return nil }
        defaults.set(["build": build, "done": done + 1], forKey: Self.progressKey)
        return (done, plan[done])
    }

    /// True while any step of this build's plan is still to run, so the lab may reach the
    /// helper even after the helper was written off for ordinary dictation.
    public func hasStepsLeft(in defaults: UserDefaults? = WorkerHealth.shared) -> Bool {
        let saved = defaults?.dictionary(forKey: Self.progressKey)
        let done = (saved?["build"] as? String) == build ? (saved?["done"] as? Int ?? 0) : 0
        return done < plan.count
    }
}

/// Where Core ML may run the model. Kept apart from Core ML so the file format needs no import.
public enum MiniMemoryProbeUnits: String, Codable, Sendable {
    /// The processor only: what Zone uses today.
    case cpu
    /// The processor and the Neural Engine.
    case neuralEngine
}
