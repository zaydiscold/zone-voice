// by zayd/cold @ zayd.wtf

#if canImport(CoreML)
import CoreML
import Foundation

/// Loads Fluid Speech Mini's four parts one at a time and runs each once, writing the process's
/// memory before and after every stage. It answers one question on a real iPhone: how much
/// memory does Zone's speech model cost in this process, and at which stage?
///
/// It needs nothing but Core ML, so the same code runs in the keyboard, in the speech helper, in
/// an audio unit and on a Mac. It writes no words: the inputs are silence. It is a measurement,
/// not a dictation path.
///
/// The guard matters more than the measurement: a keyboard that iOS ends takes the person's
/// typing surface with it. Before each stage the probe compares what iOS says is left with what
/// that stage is expected to cost plus a margin, and stops cleanly when there is not enough. A
/// watcher samples memory during each stage, so the peak is known, not only the resting value.
public enum MiniMemoryProbe {
    /// The four parts, in the order they are loaded and run.
    public static let parts = ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"]

    public struct Options: Sendable {
        public var directory: URL
        public var units: MiniMemoryProbeUnits
        /// Encoder passes. One pass is up to 15 seconds of speech; four is a minute.
        public var windows: Int
        /// Memory that must stay free beyond a stage's expected cost, in MiB.
        public var marginMB: Int
        /// Expected cost of a stage in MiB, by stage name. Unknown stages count as `defaultCostMB`.
        public var costMB: [String: Int]
        public var defaultCostMB: Int
        /// Off only in a process that may be ended without harm (the helper, the audio unit),
        /// where finding the stage iOS ends it at is the point. Always on in the keyboard.
        public var guarded: Bool

        public init(directory: URL, units: MiniMemoryProbeUnits, windows: Int = 4, marginMB: Int = 20,
                    costMB: [String: Int] = MiniMemoryProbe.expectedCostMB, defaultCostMB: Int = 4,
                    guarded: Bool = true) {
            self.directory = directory
            self.units = units
            self.windows = max(1, min(windows, 8))
            self.marginMB = marginMB
            self.costMB = costMB
            self.defaultCostMB = defaultCostMB
            self.guarded = guarded
        }
    }

    /// What each stage is expected to add on the processor, from the Mac measurement of
    /// November 22, 2026 (`docs/research/2026-11-22-own-model-phone-limits.md`). An iPhone
    /// measurement replaces these. They only decide whether a stage may start.
    public static let expectedCostMB: [String: Int] = [
        "load.Preprocessor": 6, "load.Encoder": 54, "load.Decoder": 13, "load.JointDecisionv3": 4,
        "predict.Preprocessor": 4, "predict.Encoder": 55, "predict.Decoder": 2, "predict.JointDecisionv3": 2,
    ]

    public struct Step: Sendable {
        public enum Phase: String, Sendable { case begin, end, stopped, failed }
        public var name: String
        public var phase: Phase
        /// Footprint now, in bytes (`phys_footprint`, the number iOS ends a process on).
        public var footprint: UInt64?
        /// Highest footprint seen during the stage, in bytes. On `end` only.
        public var peak: UInt64?
        /// What iOS says is left before the limit, nil where it reports none.
        public var left: UInt64?
        public var ms: Int?
        public var detail: String?

        /// For the recording log.
        public var fields: [String: String] {
            var fields = ["stage": name, "phase": phase.rawValue]
            fields["mb"] = footprint.map(MemoryFootprint.megabytes)
            fields["peakMB"] = peak.map(MemoryFootprint.megabytes)
            fields["leftMB"] = left.map(MemoryFootprint.megabytes)
            if let footprint, let left { fields["limitMB"] = MemoryFootprint.megabytes(footprint + left) }
            fields["ms"] = ms.map(String.init)
            fields["detail"] = detail
            return fields
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// Every stage ran.
        case completed
        /// The guard refused a stage: not enough memory left for it.
        case stoppedForRoom(stage: String)
        case failed(stage: String, code: String)

        public var name: String {
            switch self {
            case .completed: return "completed"
            case .stoppedForRoom: return "stoppedForRoom"
            case .failed: return "failed"
            }
        }
    }

    public struct Result: Sendable {
        public var outcome: Outcome
        /// Highest footprint over the whole run, in bytes.
        public var peak: UInt64
        /// Footprint before anything was loaded.
        public var start: UInt64
        /// Footprint after everything was let go.
        public var end: UInt64
        public var totalMs: Int

        public var fields: [String: String] {
            var fields = ["outcome": outcome.name, "startMB": MemoryFootprint.megabytes(start),
                          "peakMB": MemoryFootprint.megabytes(peak), "endMB": MemoryFootprint.megabytes(end),
                          "costMB": MemoryFootprint.megabytes(peak > start ? peak - start : 0), "totalMs": String(totalMs)]
            switch outcome {
            case .completed: break
            case .stoppedForRoom(let stage): fields["stoppedAt"] = stage
            case .failed(let stage, let code): fields["stoppedAt"] = stage; fields["code"] = code
            }
            return fields
        }
    }

    /// Whether a stage may start with `left` bytes before the limit. No reported limit allows it.
    public static func mayStart(_ stage: String, left: UInt64?, options: Options) -> Bool {
        guard options.guarded, let left else { return true }
        let need = (options.costMB[stage] ?? options.defaultCostMB) + options.marginMB
        return left >= UInt64(need) * 1_048_576
    }

    /// Runs on the calling thread and blocks it: call from a background queue, never from the
    /// keyboard's main thread. `note` is called before and after every stage, on this thread;
    /// write it to disk and flush before returning, so a process iOS ends leaves its last stage.
    public static func run(_ options: Options, footprint: @escaping @Sendable () -> UInt64? = MemoryFootprint.current,
                           left: @escaping @Sendable () -> UInt64? = MemoryFootprint.available,
                           note: (Step) -> Void) -> Result {
        let clock = ProcessInfo.processInfo
        let began = clock.systemUptime
        let start = footprint() ?? 0
        let watcher = PeakWatcher(read: footprint)
        var models: [String: MLModel] = [:]
        var outputs: [String: MLFeatureValue] = [:]
        var outcome = Outcome.completed

        /// One guarded, timed stage. Returns false when the run must stop.
        func stage(_ name: String, detail: String? = nil, _ work: () throws -> Void) -> Bool {
            let room = left()
            guard mayStart(name, left: room, options: options) else {
                note(Step(name: name, phase: .stopped, footprint: footprint(), left: room, detail: "notEnoughRoom"))
                outcome = .stoppedForRoom(stage: name)
                return false
            }
            note(Step(name: name, phase: .begin, footprint: footprint(), left: room, detail: detail))
            let at = clock.systemUptime
            watcher.beginStage()
            do {
                try autoreleasepool { try work() }
                let ms = Int((clock.systemUptime - at) * 1000)
                note(Step(name: name, phase: .end, footprint: footprint(), peak: watcher.endStage(), left: left(), ms: ms))
                return true
            } catch {
                let code = JournalFormat.error(error)
                note(Step(name: name, phase: .failed, footprint: footprint(), peak: watcher.endStage(), left: left(),
                          ms: Int((clock.systemUptime - at) * 1000), detail: code))
                outcome = .failed(stage: name, code: code)
                return false
            }
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = options.units == .cpu ? .cpuOnly : .cpuAndNeuralEngine

        run: do {
            for part in parts {
                let url = options.directory.appendingPathComponent(part + ".mlmodelc")
                guard stage("load." + part, { models[part] = try MLModel(contentsOf: url, configuration: configuration) })
                else { break run }
            }
            for part in parts {
                guard let model = models[part] else { continue }
                let passes = part == "Encoder" ? options.windows : 1
                for pass in 1...passes {
                    let ok = stage("predict." + part, detail: passes > 1 ? "pass \(pass) of \(passes)" : nil) {
                        let input = try inputs(for: model, known: outputs)
                        let output = try model.prediction(from: input)
                        for name in output.featureNames { outputs[name] = output.featureValue(for: name) }
                    }
                    guard ok else { break run }
                }
            }
        }
        // Let everything go, whatever happened, and say what the process settles at.
        outputs.removeAll()
        models.removeAll()
        let end = footprint() ?? 0
        note(Step(name: "released", phase: .end, footprint: end, left: left()))
        return Result(outcome: outcome, peak: max(watcher.stop(), start, end), start: start, end: end,
                      totalMs: Int((clock.systemUptime - began) * 1000))
    }

    /// Silence in the shape each input declares. An earlier part's output is used where the
    /// names match (the preprocessor's features feed the encoder), and a `_length` input is set
    /// to the full length of what it measures.
    static func inputs(for model: MLModel, known: [String: MLFeatureValue]) throws -> MLDictionaryFeatureProvider {
        var values: [String: MLFeatureValue] = [:]
        var lengths: [String: MLMultiArray] = [:]
        var sizes: [String: Int] = [:]
        for (name, description) in model.modelDescription.inputDescriptionsByName {
            if let ready = known[name], ready.type == description.type { values[name] = ready; continue }
            guard let constraint = description.multiArrayConstraint else {
                throw CocoaError(.featureUnsupported)
            }
            let array = try MLMultiArray(shape: constraint.shape, dataType: constraint.dataType)
            array.withUnsafeMutableBytes { pointer, _ in
                if let base = pointer.baseAddress { memset(base, 0, pointer.count) }
            }
            if name.hasSuffix("_length") { lengths[name] = array } else { sizes[name] = constraint.shape.last?.intValue ?? 1 }
            values[name] = MLFeatureValue(multiArray: array)
        }
        for (name, array) in lengths {
            let stem = String(name.dropLast("_length".count))
            // "audio_length" measures "audio_signal"; "mel_length" measures "mel".
            let measured = sizes.first { $0.key == stem || $0.key.hasPrefix(stem) }?.value ?? 1
            array[0] = NSNumber(value: measured)
        }
        return try MLDictionaryFeatureProvider(dictionary: values)
    }
}

/// Samples the footprint every 10 ms on its own thread while a stage runs: Core ML's loads and
/// predictions are single calls, so the peak inside them is invisible to the caller.
final class PeakWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private let read: @Sendable () -> UInt64?
    private var stagePeak: UInt64 = 0
    private var overall: UInt64 = 0
    private var running = true

    init(read: @escaping @Sendable () -> UInt64?) {
        self.read = read
        let thread = Thread { [weak self] in
            while let self, self.sample() { Thread.sleep(forTimeInterval: 0.01) }
        }
        thread.name = "wtf.zayd.zone.peak-watcher"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func sample() -> Bool {
        let now = read() ?? 0
        return lock.withLock {
            stagePeak = max(stagePeak, now)
            overall = max(overall, now)
            return running
        }
    }

    func beginStage() {
        let now = read() ?? 0
        lock.withLock { stagePeak = now; overall = max(overall, now) }
    }

    func endStage() -> UInt64 {
        _ = sample()
        return lock.withLock { stagePeak }
    }

    func stop() -> UInt64 {
        _ = sample()
        return lock.withLock { running = false; return overall }
    }
}
#endif
