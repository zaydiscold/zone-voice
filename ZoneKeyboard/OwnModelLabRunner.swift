// by zayd/cold @ zayd.wtf

import AudioToolbox
import AVFoundation
import Foundation
import ZoneCore

/// Runs the next step of the hidden lab (`OwnModelLab`) after a dictation the keyboard recorded
/// by itself, once its words are written. Without the lab file in the App Group this is one
/// failed file read per dictation and nothing else.
///
/// Each step measures Zone's speech model in one place (the keyboard, the helper, the lab's audio
/// unit) and writes every stage's memory and time to the recording log as `ownModelLab`.
@MainActor
enum OwnModelLabRunner {
    private static var running = false
    /// Set before the keyboard prepares the model in its own process, so the 1.2 GB it writes
    /// to the keyboard's cache is removed even if iOS ends the keyboard part way.
    static let cacheFlag = "zone.lab.keyboardCacheDirty"

    private static func log(_ id: UUID, _ fields: [String: String]) {
        KeyboardLog.journal?.log("ownModelLab", recording: id, fields)
        KeyboardLog.journal?.flush()
    }

    static func afterDictation(recording id: UUID) {
        guard !running, let lab = OwnModelLab.read(), SharedMiniModel.verified,
              let directory = SharedMiniModel.directory, let next = lab.takeNextStep() else { return }
        running = true
        let step = next.step
        // First act of the step: what this process weighs and what iOS allows it.
        var planned = MemoryFootprint.journalFields()
        planned.merge(["phase": "planned", "step": String(next.index), "of": String(lab.plan.count),
                       "place": step.place.rawValue, "units": step.units.rawValue]) { _, value in value }
        log(id, planned)
        Task {
            defer { running = false }
            var result: [String: String]
            switch step.place {
            case .keyboard:
                result = await inKeyboard(directory: directory, step: step, id: id)
            case .helper:
                if #available(iOS 26, *) {
                    result = await ZoneModelSpeech.shared.labProbe(units: step.units, windows: step.windows ?? 4, recording: id)
                } else {
                    result = ["outcome": "needsiOS26"]
                }
            case .audioUnit:
                result = await OwnModelLabUnit.run(units: step.units, windows: step.windows ?? 4, recording: id)
            }
            result.merge(["phase": "result", "step": String(next.index), "place": step.place.rawValue,
                          "units": step.units.rawValue]) { _, value in value }
            result["keyboardMB"] = MemoryFootprint.current().map(MemoryFootprint.megabytes)
            log(id, result)
        }
    }

    /// In the keyboard's own process, guarded: a stage starts only with its expected cost and a
    /// margin free, so the probe backs out instead of getting the keyboard ended.
    private static func inKeyboard(directory: URL, step: OwnModelLab.Step, id: UUID) async -> [String: String] {
        UserDefaults.standard.set(true, forKey: cacheFlag)
        let options = MiniMemoryProbe.Options(directory: directory, units: step.units, windows: step.windows ?? 4, marginMB: 20)
        let journal = KeyboardLog.journal
        let result = await Task.detached(priority: .userInitiated) {
            MiniMemoryProbe.run(options) { stage in
                var fields = stage.fields
                fields["place"] = "keyboard"
                journal?.log("ownModelLab", recording: id, fields)
                journal?.flush()
            }
        }.value
        await removeKeyboardCache()
        return result.fields
    }

    /// Every appearance: one read of the keyboard's own defaults when the lab never ran.
    static func tidyKeyboardCache() {
        guard !running, UserDefaults.standard.bool(forKey: cacheFlag) else { return }
        Task { await removeKeyboardCache() }
    }

    private static func removeKeyboardCache() async {
        let freed = await Task.detached(priority: .utility) { () -> Int64 in
            guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
                  let bundle = Bundle.main.bundleIdentifier else { return 0 }
            let root = caches.appendingPathComponent(bundle).appendingPathComponent(CompiledModelCache.directoryName)
            return (try? WorkerStorage.removeEverything(in: root)) ?? -1
        }.value
        if freed >= 0 { UserDefaults.standard.set(false, forKey: cacheFlag) }
        KeyboardLog.journal?.log("ownModelLabCache", ["place": "keyboard", "freedBytes": String(freed)])
    }
}

/// The lab's audio unit, when the installed build carries one (`project-lab.yml`). The keyboard
/// starts it in a process of its own and talks to it over the unit's message channel.
@MainActor
enum OwnModelLabUnit {
    private static var unit: AUAudioUnit?

    static var description: AudioComponentDescription {
        AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: fourCharacters("zlab"),
                                  componentManufacturer: fourCharacters("Zayd"), componentFlags: 0, componentFlagsMask: 0)
    }

    private static func fourCharacters(_ text: String) -> FourCharCode {
        text.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    static func run(units: MiniMemoryProbeUnits, windows: Int, recording: UUID) async -> [String: String] {
        guard !AVAudioUnitComponentManager.shared().components(matching: description).isEmpty else {
            return ["outcome": "unitNotInBuild"]
        }
        do {
            let started = ProcessInfo.processInfo.systemUptime
            let unit: AUAudioUnit
            if let existing = Self.unit { unit = existing } else {
                unit = try await AUAudioUnit.instantiate(with: description, options: [.loadOutOfProcess])
                Self.unit = unit
            }
            let channel = unit.messageChannel(for: "lab")
            guard let call = channel.callAudioUnit else { return ["outcome": "unitHasNoChannel"] }
            var fields = ["startMs": String(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))]
            // The unit's first answer: what it weighs and what iOS allows it, before any model work.
            for (key, value) in call(["limits": true]) { fields["unit" + String(describing: key)] = String(describing: value) }
            guard let job = call(["probe": units.rawValue, "windows": windows, "recording": recording.uuidString])["job"] as? String else {
                fields["outcome"] = "unitRefused"
                return fields
            }
            for _ in 0..<600 {
                try await Task.sleep(for: .milliseconds(200))
                let reply = call(["poll": job])
                if reply.isEmpty { fields["outcome"] = "unitEnded"; Self.unit = nil; return fields }
                if reply["pending"] != nil { continue }
                for (key, value) in reply { fields[String(describing: key)] = String(describing: value) }
                return fields
            }
            fields["outcome"] = "unitTimedOut"
            return fields
        } catch {
            Self.unit = nil
            return ["outcome": "unitFailed", "code": JournalFormat.error(error)]
        }
    }
}
