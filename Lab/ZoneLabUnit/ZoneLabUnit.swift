// by zayd/cold @ zayd.wtf

import AudioToolbox
import AVFoundation
import CoreAudioKit
import Foundation
import ZoneCore

/// Lab only. Never part of a build that goes to testers: it is added by `project-lab.yml`, not
/// `project.yml`.
///
/// An audio unit that does no audio work. It answers two questions on a real iPhone: how much
/// memory does iOS give an audio unit extension that the keyboard starts, and does Zone's speech
/// model fit in it? The keyboard talks to it over the unit's message channel.
final class ZoneLabUnitFactory: NSObject, AUAudioUnitFactory {
    func beginRequest(with context: NSExtensionContext) {}

    func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        try ZoneLabUnit(componentDescription: componentDescription, options: [])
    }
}

enum UnitJournal {
    static let log = RecordingJournal.shared(process: "unit")

    static func write(_ name: String, _ id: UUID? = nil, _ fields: [String: String]) {
        var fields = fields
        fields["pid"] = String(ProcessInfo.processInfo.processIdentifier)
        log?.log(name, recording: id, fields)
        log?.flush()
    }
}

final class ZoneLabUnit: AUAudioUnit {
    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!
    private let channel = ZoneLabUnitChannel()

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        // First act, before anything else: what this process weighs and what iOS allows it.
        var first = MemoryFootprint.journalFields()
        first["phase"] = "launched"
        first["place"] = "audioUnit"
        UnitJournal.write("ownModelLab", nil, first)
        try super.init(componentDescription: componentDescription, options: options)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [try AUAudioUnitBus(format: format)])
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [try AUAudioUnitBus(format: format)])
    }

    override var inputBusses: AUAudioUnitBusArray { inputs }
    override var outputBusses: AUAudioUnitBusArray { outputs }
    override var internalRenderBlock: AUInternalRenderBlock {
        { _, _, _, _, _, _, _ in noErr }
    }

    override func messageChannel(for channelName: String) -> AUMessageChannel { channel }
}

final class ZoneLabUnitChannel: NSObject, AUMessageChannel {
    var callHostBlock: CallHostBlock?
    private let lock = NSLock()
    private var results: [String: [String: String]] = [:]

    /// `limits`: footprint and limit now. `probe`: start the memory measurement and answer a job
    /// id (it takes longer than a call should block). `poll`: the job's result once it has one.
    func callAudioUnit(_ message: [AnyHashable: Any]) -> [AnyHashable: Any] {
        if message["limits"] != nil {
            var fields = MemoryFootprint.journalFields()
            fields["pid"] = String(ProcessInfo.processInfo.processIdentifier)
            return fields
        }
        if let id = message["poll"] as? String {
            return lock.withLock { results[id] } ?? ["pending": "true"]
        }
        guard let raw = message["probe"] as? String, let units = MiniMemoryProbeUnits(rawValue: raw),
              let directory = SharedMiniModel.directory else { return [:] }
        let recording = (message["recording"] as? String).flatMap(UUID.init(uuidString:))
        let windows = message["windows"] as? Int ?? 4
        let job = UUID().uuidString
        Thread.detachNewThread { [self] in
            // This process is expendable, so the guard is off: the point is to find its limit.
            let options = MiniMemoryProbe.Options(directory: directory, units: units, windows: windows, guarded: false)
            let result = MiniMemoryProbe.run(options) { stage in
                var fields = stage.fields
                fields["place"] = "audioUnit"
                UnitJournal.write("ownModelLab", recording, fields)
            }
            // Whatever it prepared is of no use to anyone: remove it before answering.
            if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
               let bundle = Bundle.main.bundleIdentifier {
                _ = try? WorkerStorage.removeEverything(
                    in: caches.appendingPathComponent(bundle).appendingPathComponent(CompiledModelCache.directoryName))
            }
            lock.withLock { results[job] = result.fields }
        }
        return ["job": job]
    }
}
