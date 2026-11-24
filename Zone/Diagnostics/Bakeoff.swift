// by zayd/cold @ zayd.wtf

import AVFoundation
import Darwin
import Foundation
import Observation
import os
import UIKit
import ZoneCore

// The engine bakeoff. Diagnostics only.
//
// Fairness rules the code enforces:
// - Every engine hears the same ten WAV files, recorded once through the production capture tap.
// - Audio is fed in 100 ms pieces at real-time pace, as the microphone would deliver it, so a
//   streaming engine gets to work while "the user is talking" and a batch engine does not.
// - Stop-to-text is timed from the last fed piece to the returned text, as in the keyboard.
// - One untimed warm-up utterance per engine absorbs first-inference compilation; its latency
//   is reported separately as the cold number.
// - Only one engine is resident at a time; the previous one is unloaded before the next loads.

/// The ten scripted dictations. The tester reads them in their own words; the reference is then
/// corrected once to what they actually said.
struct BakeoffPrompt: Identifiable, Sendable {
    let id: Int
    let category: String
    let script: String
    let instruction: String

    static let all: [BakeoffPrompt] = [
        BakeoffPrompt(id: 1, category: "names",
                      script: "Text Saba Nafees and Elaine Chen that the Dahlsson review moved to Thursday.",
                      instruction: "Normal voice, phone at normal distance."),
        BakeoffPrompt(id: 2, category: "numbers",
                      script: "The invoice total is four hundred twelve dollars and thirty cents, due on the twenty first.",
                      instruction: "Normal voice."),
        BakeoffPrompt(id: 3, category: "negation",
                      script: "I did not say we should cancel it, I said we should not rush it.",
                      instruction: "Normal voice."),
        BakeoffPrompt(id: 4, category: "question",
                      script: "Can you send me the address before six thirty tonight?",
                      instruction: "Ask it like a question."),
        BakeoffPrompt(id: 5, category: "pause",
                      script: "Pick up eggs, milk and coffee. Actually, skip the milk.",
                      instruction: "Stop for two full seconds after \"coffee\"."),
        BakeoffPrompt(id: 6, category: "background noise",
                      script: "Running a little late, should be there in about fifteen minutes.",
                      instruction: "Play music or a TV at normal room volume while you speak."),
        BakeoffPrompt(id: 7, category: "jargon",
                      script: "Push the fix to the main branch and rerun the Xcode build on the iPhone fifteen Pro.",
                      instruction: "Normal voice."),
        BakeoffPrompt(id: 8, category: "mixed numbers",
                      script: "My flight is United nine eighty seven, gate B twelve, boarding at seven forty five.",
                      instruction: "Normal voice."),
        BakeoffPrompt(id: 9, category: "long casual",
                      script: "Honestly the new keyboard feels faster than Wispr Flow, but it still needs work on names like Zayd and Hooke.",
                      instruction: "Relaxed, conversational pace."),
        BakeoffPrompt(id: 10, category: "noise, quiet voice",
                      script: "Remind me to call Mom tomorrow morning about the dentist appointment.",
                      instruction: "Quieter voice with a fan, tap or kitchen noise running."),
    ]
}

// MARK: Files

/// Clips, references and reports live in Documents/Bakeoff so they can be pulled off the
/// phone with `xcrun devicectl device copy from --domain-type appDataContainer`.
enum BakeoffFiles {
    static var directory: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bakeoff", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func clipURL(_ id: Int) -> URL {
        directory.appendingPathComponent(String(format: "clip-%02d.wav", id))
    }

    static var referencesURL: URL { directory.appendingPathComponent("references.json") }

    static func hasClip(_ id: Int) -> Bool { FileManager.default.fileExists(atPath: clipURL(id).path) }

    static func writeClip(_ samples: [Float], id: Int) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let url = clipURL(id)
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            buffer.floatChannelData![0].update(from: pointer.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }

    static func readClip(_ id: Int) throws -> [Float] {
        try TestClip.samples(from: clipURL(id))
    }

    static func loadReferences() -> [Int: String] {
        guard let data = try? Data(contentsOf: referencesURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in Int(key).map { ($0, value) } })
    }

    static func saveReferences(_ references: [Int: String]) {
        let encoded = Dictionary(uniqueKeysWithValues: references.map { (String($0.key), $0.value) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(encoded) {
            try? data.write(to: referencesURL, options: .atomic)
        }
    }

    static func writeReport<T: Encodable>(_ report: T, prefix: String) throws -> URL {
        try writeReport(report, to: reportURL(prefix: prefix))
    }

    static func reportURL(prefix: String) -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return directory.appendingPathComponent("\(prefix)-\(stamp).json")
    }

    /// Writes (or overwrites) one report file; the accuracy pass rewrites its file after every
    /// engine so a run that dies part way still leaves the engines it finished.
    @discardableResult
    static func writeReport<T: Encodable>(_ report: T, to url: URL) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: url, options: .atomic)
        return url
    }

    static func reports() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" && $0.lastPathComponent != "references.json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}

// MARK: Probes

/// Process-level resource readings. These cover our process only: Apple's recognizer runs in
/// a system daemon and Neural Engine time is not CPU time, so energy comes from Power Profiler.
enum ResourceProbe {
    /// The number iOS uses for jetsam decisions (what Xcode's memory gauge shows).
    static func physFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// User plus system CPU seconds consumed by this process so far.
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return user + system
    }

    static var deviceModel: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static var thermalState: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

/// Samples the footprint every 20 ms on a utility queue and keeps the maximum.
final class PeakMemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private var timer: DispatchSourceTimer?

    func start() {
        lock.lock()
        peak = ResourceProbe.physFootprint()
        lock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let value = ResourceProbe.physFootprint()
            self.lock.lock()
            if value > self.peak { self.peak = value }
            self.lock.unlock()
        }
        timer.resume()
        self.timer = timer
    }

    @discardableResult
    func stop() -> UInt64 {
        timer?.cancel()
        timer = nil
        lock.lock()
        defer { lock.unlock() }
        return max(peak, ResourceProbe.physFootprint())
    }
}

// MARK: Report types

struct ClipResult: Codable, Sendable {
    let clip: Int
    let category: String
    let reference: String
    let hypothesis: String
    let wer: WordErrorRate
    let audioSeconds: Double
    let stopToTextMs: Double
    let cpuSeconds: Double
    let appState: String
    let error: String?
}

struct EngineResult: Codable, Sendable {
    let engine: EngineKind
    let displayName: String
    let bytesOnDisk: Int64
    let loadSeconds: Double
    let coldStopToTextMs: Double?
    let footprintBeforeLoad: UInt64
    let footprintAfterLoad: UInt64
    let peakFootprint: UInt64
    let thermalStart: String
    let thermalEnd: String
    let clips: [ClipResult]
    let error: String?

    var pooledWER: WordErrorRate { WordErrorRate.pooled(clips.map(\.wer)) }
    var medianStopToTextMs: Double? { Self.percentile(clips.filter { $0.error == nil }.map(\.stopToTextMs), 0.5) }
    var p90StopToTextMs: Double? { Self.percentile(clips.filter { $0.error == nil }.map(\.stopToTextMs), 0.9) }
    /// CPU seconds spent per second of audio, our process only.
    var cpuPerAudioSecond: Double? {
        let audio = clips.reduce(0) { $0 + $1.audioSeconds }
        guard audio > 0 else { return nil }
        return clips.reduce(0) { $0 + $1.cpuSeconds } / audio
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[index]
    }
}

struct DeviceSnapshot: Codable, Sendable {
    let model: String
    let systemVersion: String
    let lowPowerMode: Bool
    let batteryState: String
    let batteryLevel: Float

    @MainActor
    static func now() -> DeviceSnapshot {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let state: String
        switch device.batteryState {
        case .unplugged: state = "unplugged"
        case .charging: state = "charging"
        case .full: state = "full"
        default: state = "unknown"
        }
        return DeviceSnapshot(
            model: ResourceProbe.deviceModel, systemVersion: device.systemVersion,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            batteryState: state, batteryLevel: device.batteryLevel)
    }
}

struct AccuracyReport: Codable, Sendable {
    let kind = "accuracy"
    let startedAt: Date
    let finishedAt: Date
    let device: DeviceSnapshot
    let engines: [EngineResult]
}

struct EnergyRunReport: Codable, Sendable {
    let kind = "energy"
    let engine: EngineKind
    let mode: String
    let startedAt: Date
    let finishedAt: Date
    let deviceStart: DeviceSnapshot
    let deviceEnd: DeviceSnapshot
    let cpuSeconds: Double
    let peakFootprint: UInt64
    let utterances: [ClipResult]
}

// MARK: Runner

@MainActor
@Observable
final class BakeoffRunner {
    enum EnergyMode: String, CaseIterable, Identifiable {
        /// Zone stays on screen for the whole run.
        case foreground
        /// A 15 s countdown to switch to Messages; dictations run with Zone in the background,
        /// the warm path's situation.
        case background
        var id: String { rawValue }
    }

    private(set) var status = ""
    private(set) var isRunning = false
    private(set) var lastAccuracy: AccuracyReport?
    private(set) var lastReportURL: URL?
    private(set) var energyLog: [String] = []
    private var cancelled = false
    /// `-zoneBakeoffColdStart <seconds>`: before every timed clip, drop the compiled model's
    /// pages from memory the way iOS does under memory pressure, then idle this long. Measures
    /// the phone's "first dictation after a pause" case.
    var coldStartIdle: TimeInterval?

    static let signposter = OSSignposter(subsystem: "wtf.zayd.zone", category: "bakeoff")
    /// Five-minute matched energy session: one clip every 30 s.
    static let energyDuration: TimeInterval = 300
    static let energySpacing: TimeInterval = 30

    func cancel() { cancelled = true }

    // MARK: Accuracy pass

    /// `syntheticClip` runs every slot from the bundled test clip held in memory, so the tester's
    /// recorded clips and references are never touched and the report is named
    /// `accuracy-synthetic-...`. `corpus` runs a labeled set of someone else's speech instead
    /// (LibriSpeech and the like); its report is named
    /// `corpus-<name>-...` so the model library never mistakes it for the tester's voice.
    func runAccuracy(engines: [EngineKind], references: [Int: String], coordinator: DictationCoordinator,
                     syntheticClip: [Float]? = nil, corpus: BakeoffCorpus? = nil) async {
        guard !isRunning, coordinator.beginModelDiagnostics() else { return }
        defer { coordinator.endModelDiagnostics() }
        isRunning = true
        cancelled = false
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            isRunning = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
        currentCoordinator = coordinator
        let originalEngine = coordinator.engineKind
        let started = Date()
        let device = DeviceSnapshot.now()
        let clips: [(BakeoffPrompt, [Float])] = corpus?.clips ?? BakeoffPrompt.all.compactMap { prompt in
            if let syntheticClip { return (prompt, syntheticClip) }
            guard let samples = try? BakeoffFiles.readClip(prompt.id) else { return nil }
            return (prompt, samples)
        }
        let references: [Int: String] = if let corpus {
            Dictionary(uniqueKeysWithValues: corpus.clips.map { ($0.0.id, $0.0.script) })
        } else if syntheticClip != nil {
            Dictionary(uniqueKeysWithValues: BakeoffPrompt.all.map { ($0.id, TestClip.transcript) })
        } else {
            references
        }
        let prefix = corpus.map { "corpus-\($0.name)" } ?? (syntheticClip == nil ? "accuracy" : "accuracy-synthetic")
        let reportURL = BakeoffFiles.reportURL(prefix: prefix)
        guard !clips.isEmpty else {
            status = "Record the clips first."
            return
        }
        var results: [EngineResult] = []
        for kind in engines where !cancelled {
            results.append(await measure(kind, clips: clips, references: references, coordinator: coordinator))
            // Partial report after every engine: a screen lock, a crash or a pulled cable
            // still leaves every engine finished so far.
            let partial = AccuracyReport(startedAt: started, finishedAt: Date(), device: device, engines: results)
            lastReportURL = try? BakeoffFiles.writeReport(partial, to: reportURL)
        }
        let report = AccuracyReport(startedAt: started, finishedAt: Date(), device: device, engines: results)
        lastAccuracy = report
        lastReportURL = try? BakeoffFiles.writeReport(report, to: reportURL)
        status = cancelled ? "Cancelled; partial report saved." : "Done. Report saved."
        await coordinator.switchEngine(to: originalEngine, persist: false)
    }

    private func measure(_ kind: EngineKind, clips: [(BakeoffPrompt, [Float])], references: [Int: String],
                         coordinator: DictationCoordinator) async -> EngineResult {
        status = "\(kind.shortName): loading"
        let thermalStart = ResourceProbe.thermalState
        // Unload whatever is resident first so the baseline is the app without a model.
        coordinator.unloadEngine()
        try? await Task.sleep(for: .milliseconds(500))
        let before = ResourceProbe.physFootprint()
        let sampler = PeakMemorySampler()
        sampler.start()
        let loadStart = Date()
        await coordinator.switchEngine(to: kind, persist: false)
        await coordinator.prepareModelAndWait()
        let loadSeconds = Date().timeIntervalSince(loadStart)
        guard coordinator.modelIsReady else {
            sampler.stop()
            var reason = "not ready"
            if case .failed(let message) = coordinator.modelState { reason = message }
            return EngineResult(engine: kind, displayName: kind.displayName, bytesOnDisk: coordinator.engineBytesOnDisk,
                                loadSeconds: loadSeconds, coldStopToTextMs: nil, footprintBeforeLoad: before,
                                footprintAfterLoad: ResourceProbe.physFootprint(), peakFootprint: sampler.stop(),
                                thermalStart: thermalStart, thermalEnd: ResourceProbe.thermalState, clips: [], error: reason)
        }
        let afterLoad = ResourceProbe.physFootprint()

        // Untimed warm-up on the first clip; its latency is the cold number.
        status = "\(kind.shortName): warm-up"
        let warm = await transcribe(clips[0].1, kind: kind)
        var results: [ClipResult] = []
        for (prompt, samples) in clips where !cancelled {
            status = "\(kind.shortName): clip \(prompt.id) of \(clips.count)"
            if let idle = coldStartIdle {
                let evicted = CompiledProgramEvictor.evict()
                ZoneLog.coordinator.notice("bakeoff cold start: evicted \(evicted.files) programs, \(evicted.bytes / 1_000_000) MB, resident \(evicted.residentBefore, format: .fixed(precision: 0))% to \(evicted.residentAfter, format: .fixed(precision: 0))%")
                try? await Task.sleep(for: .seconds(idle))
            }
            let outcome = await transcribe(samples, kind: kind)
            let reference = references[prompt.id] ?? prompt.script
            results.append(ClipResult(
                clip: prompt.id, category: prompt.category, reference: reference, hypothesis: outcome.text,
                wer: WordErrorRate.score(reference: reference, hypothesis: outcome.text),
                audioSeconds: Double(samples.count) / 16_000, stopToTextMs: outcome.stopToText * 1000,
                cpuSeconds: outcome.cpu, appState: outcome.appState, error: outcome.error))
        }
        return EngineResult(
            engine: kind, displayName: kind.displayName, bytesOnDisk: coordinator.engineBytesOnDisk,
            loadSeconds: loadSeconds, coldStopToTextMs: warm.error == nil ? warm.stopToText * 1000 : nil,
            footprintBeforeLoad: before, footprintAfterLoad: afterLoad, peakFootprint: sampler.stop(),
            thermalStart: thermalStart, thermalEnd: ResourceProbe.thermalState, clips: results, error: nil)
    }

    struct Outcome {
        var text = ""
        var stopToText: TimeInterval = 0
        var cpu: Double = 0
        var appState = ""
        var error: String?
    }

    /// Feeds one clip at real-time pace, then times stop-to-text.
    private func transcribe(_ samples: [Float], kind: EngineKind) async -> Outcome {
        var outcome = Outcome()
        outcome.appState = Self.appState
        let cpuStart = ResourceProbe.cpuSeconds()
        let state = Self.signposter.beginInterval("utterance", id: Self.signposter.makeSignpostID(), "\(kind.rawValue)")
        defer { Self.signposter.endInterval("utterance", state) }
        do {
            guard let session = try currentCoordinator?.makeBenchmarkUtterance() else {
                throw SpeechEngineError.notReady
            }
            defer { session.cancel() }
            let piece = 1_600
            var index = 0
            let clock = ContinuousClock()
            let start = clock.now
            while index < samples.count {
                let end = min(index + piece, samples.count)
                // A microphone hands over a piece when its last sample has been captured, so
                // wait for that moment before feeding. Pacing against the wall clock keeps
                // scheduling jitter from accumulating. The stop timer starts right after the
                // last piece, as when the user taps stop at the end of speech.
                let due = start + .milliseconds(Int(Double(end) / 16.0))
                try await Task.sleep(until: due, clock: clock)
                if let failure = session.failure { throw failure }
                session.feed(Array(samples[index..<end]))
                index = end
            }
            let stop = Date()
            outcome.text = try await session.finish()
            outcome.stopToText = Date().timeIntervalSince(stop)
        } catch {
            outcome.error = RecordingProblem.transcribe.message(for: error)
        }
        outcome.cpu = ResourceProbe.cpuSeconds() - cpuStart
        return outcome
    }

    /// Set while a run is in progress so `transcribe` can reach the coordinator.
    private weak var currentCoordinator: DictationCoordinator?

    static var appState: String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    // MARK: Energy run

    /// Five matched minutes with the session armed and one recorded clip replayed through the
    /// engine every 30 s. Start Power Profiler before tapping, stop it when this reports done.
    func runEnergy(mode: EnergyMode, coordinator: DictationCoordinator) async {
        guard !isRunning, coordinator.beginModelDiagnostics() else { return }
        defer { coordinator.endModelDiagnostics() }
        isRunning = true
        cancelled = false
        energyLog = []
        defer { isRunning = false }
        currentCoordinator = coordinator
        let kind = coordinator.engineKind
        let clips: [(BakeoffPrompt, [Float])] = BakeoffPrompt.all.compactMap { prompt in
            (try? BakeoffFiles.readClip(prompt.id)).map { (prompt, $0) }
        }
        guard !clips.isEmpty else {
            status = "Record the clips first."
            return
        }
        do {
            try await coordinator.armSession()
        } catch {
            status = RecordingProblem.microphone.message(for: error)
            return
        }
        if mode == .background {
            for remaining in stride(from: 15, to: 0, by: -1) where !cancelled {
                status = "Switch to Messages now: \(remaining) s"
                try? await Task.sleep(for: .seconds(1))
            }
        }
        let deviceStart = DeviceSnapshot.now()
        let started = Date()
        let cpuStart = ResourceProbe.cpuSeconds()
        let sampler = PeakMemorySampler()
        sampler.start()
        let interval = Self.signposter.beginInterval("energy-run", id: Self.signposter.makeSignpostID(), "\(kind.rawValue) \(mode.rawValue)")
        var utterances: [ClipResult] = []
        let count = Int(Self.energyDuration / Self.energySpacing)
        for slot in 0..<count where !cancelled {
            let due = started.addingTimeInterval(Double(slot) * Self.energySpacing + 2)
            let wait = due.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            let (prompt, samples) = clips[slot % clips.count]
            status = "Energy run: dictation \(slot + 1) of \(count)"
            let outcome = await transcribe(samples, kind: kind)
            let reference = BakeoffFiles.loadReferences()[prompt.id] ?? prompt.script
            utterances.append(ClipResult(
                clip: prompt.id, category: prompt.category, reference: reference, hypothesis: outcome.text,
                wer: WordErrorRate.score(reference: reference, hypothesis: outcome.text),
                audioSeconds: Double(samples.count) / 16_000, stopToTextMs: outcome.stopToText * 1000,
                cpuSeconds: outcome.cpu, appState: outcome.appState, error: outcome.error))
            energyLog.append("\(slot + 1) [\(outcome.appState)] \(Int(outcome.stopToText * 1000)) ms \(outcome.error ?? outcome.text)")
        }
        let end = started.addingTimeInterval(Self.energyDuration)
        if !cancelled, end.timeIntervalSinceNow > 0 {
            status = "Energy run: idle until the five minutes are up"
            try? await Task.sleep(for: .seconds(end.timeIntervalSinceNow))
        }
        Self.signposter.endInterval("energy-run", interval)
        let report = EnergyRunReport(
            engine: kind, mode: mode.rawValue, startedAt: started, finishedAt: Date(),
            deviceStart: deviceStart, deviceEnd: DeviceSnapshot.now(),
            cpuSeconds: ResourceProbe.cpuSeconds() - cpuStart, peakFootprint: sampler.stop(),
            utterances: utterances)
        lastReportURL = try? BakeoffFiles.writeReport(report, prefix: "energy-\(kind.rawValue)-\(mode.rawValue)")
        coordinator.endSession(reason: .user)
        status = cancelled ? "Energy run cancelled; partial report saved." : "Energy run done. Stop Power Profiler now."
    }
}

// MARK: Headless run

/// `-zoneBakeoff all` (or a comma list of engine raw values) runs the accuracy pass at launch
/// and writes the report, so a device run needs no taps:
/// `xcrun devicectl device process launch --device <id> wtf.zayd.zone -zoneBakeoff all`.
/// `-zoneBakeoffSeedTestClip` runs every slot from the bundled synthetic clip instead, for
/// exercising the harness before real clips exist. It writes nothing into the clip slots or
/// references, and its report is named `accuracy-synthetic-...`.
/// A labeled set of clips from a folder holding `manifest.json`:
/// `[{"file": "x.wav", "reference": "...", "category": "..."}]`, 16 kHz mono WAVs beside it.
struct BakeoffCorpus {
    let name: String
    let clips: [(BakeoffPrompt, [Float])]

    struct Entry: Decodable {
        let file: String
        let reference: String
        let category: String
    }

    init(directory: URL, limit: Int? = nil) throws {
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        var entries = try JSONDecoder().decode([Entry].self, from: data)
        if let limit { entries = Array(entries.prefix(limit)) }
        name = directory.lastPathComponent
        clips = try entries.enumerated().map { index, entry in
            let prompt = BakeoffPrompt(id: index + 1, category: entry.category, script: entry.reference, instruction: "")
            return (prompt, try TestClip.samples(from: directory.appendingPathComponent(entry.file)))
        }
    }
}

@MainActor
enum BakeoffAutorun {
    private static var runner: BakeoffRunner?

    static func runIfRequested(coordinator: DictationCoordinator) async {
        // Launch arguments drive the measurement harness in development builds only; a shipped
        // build ignores them.
        #if !DEBUG
        return
        #endif
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-zoneLongDictation"), flag + 1 < arguments.count,
           let seconds = Double(arguments[flag + 1]) {
            await LongDictationProbe.run(seconds: seconds, coordinator: coordinator)
            return
        }
        guard let flag = arguments.firstIndex(of: "-zoneBakeoff"), flag + 1 < arguments.count else { return }
        let list = arguments[flag + 1]
        let engines = list == "all"
            ? EngineKind.allCases.filter(\.isAvailableOnThisOS)
            : list.split(separator: ",").compactMap { EngineKind(rawValue: String($0)) }
        var synthetic = arguments.contains("-zoneBakeoffSeedTestClip") ? try? TestClip.samples() : nil
        // `-zoneBakeoffTrailingSilence 3` appends seconds of quiet to the synthetic clip, the
        // condition that made the retired Moonshine Tiny repeat its last word. A real microphone
        // never delivers exact zeros, so `-zoneBakeoffNoiseRMS 0.005` makes that quiet room noise
        // (uniform white noise at the given RMS; 0 keeps digital silence).
        if let index = arguments.firstIndex(of: "-zoneBakeoffTrailingSilence"), index + 1 < arguments.count,
           let seconds = Double(arguments[index + 1]), synthetic != nil {
            let rms = arguments.firstIndex(of: "-zoneBakeoffNoiseRMS")
                .flatMap { $0 + 1 < arguments.count ? Float(arguments[$0 + 1]) : nil } ?? 0
            // Uniform noise on [-a, a] has RMS a / sqrt(3).
            let amplitude = rms * Float(3).squareRoot()
            var generator = SystemRandomNumberGenerator()
            synthetic! += (0..<Int(seconds * 16_000)).map { _ in
                amplitude == 0 ? 0 : Float.random(in: -amplitude...amplitude, using: &generator)
            }
        }
        let runner = BakeoffRunner()
        self.runner = runner
        if let index = arguments.firstIndex(of: "-zoneBakeoffColdStart"), index + 1 < arguments.count {
            runner.coldStartIdle = Double(arguments[index + 1])
        }
        // `-zoneBakeoffWarmUp off` measures without the dictation-start warm-up (the old behavior).
        if let index = arguments.firstIndex(of: "-zoneBakeoffWarmUp"), index + 1 < arguments.count {
            ParakeetEngine.warmUpEnabled = arguments[index + 1] != "off"
        }
        // `-zoneBakeoffReadahead off` keeps the warm-up but skips reading the compiled program
        // back first, the behavior before November 18.
        if let index = arguments.firstIndex(of: "-zoneBakeoffReadahead"), index + 1 < arguments.count {
            ParakeetEngine.readaheadEnabled = arguments[index + 1] != "off"
        }
        // `-zoneBakeoffSpelledLetters 3` decodes Fluid Mini with FluidAudio's spelled-letter
        // repeat rule at that margin in logits (off in the app; see ParakeetEngine).
        if let index = arguments.firstIndex(of: "-zoneBakeoffSpelledLetters"), index + 1 < arguments.count {
            ParakeetEngine.spelledLetterRepeatMargin = Float(arguments[index + 1])
        }
        ZoneLog.coordinator.notice("bakeoff options: cold start \(runner.coldStartIdle.map { String($0) } ?? "off", privacy: .public), warm-up \(ParakeetEngine.warmUpEnabled ? "on" : "off", privacy: .public), readahead \(ParakeetEngine.readaheadEnabled ? "on" : "off", privacy: .public), spelled-letter margin \(ParakeetEngine.spelledLetterRepeatMargin.map { String($0) } ?? "off", privacy: .public)")
        // `-zoneBakeoffCorpus /path/to/folder` (a simulator can read the Mac's disk) runs a
        // labeled corpus; `-zoneBakeoffCorpusLimit 20` takes its first clips only.
        var corpus: BakeoffCorpus?
        if let index = arguments.firstIndex(of: "-zoneBakeoffCorpus"), index + 1 < arguments.count {
            let limit = arguments.firstIndex(of: "-zoneBakeoffCorpusLimit")
                .flatMap { $0 + 1 < arguments.count ? Int(arguments[$0 + 1]) : nil }
            do {
                corpus = try BakeoffCorpus(directory: URL(fileURLWithPath: arguments[index + 1]), limit: limit)
            } catch {
                ZoneLog.coordinator.error("bakeoff corpus failed to load: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        ZoneLog.coordinator.info("bakeoff autorun: \(engines.map(\.rawValue).joined(separator: ","), privacy: .public)")
        // The launch cleanup of retired models refuses model diagnostics while it runs, and
        // `runAccuracy` then returns without a report. Wait for it instead of skipping the run.
        while coordinator.isDeletingModels { try? await Task.sleep(for: .milliseconds(100)) }
        await runner.runAccuracy(engines: engines, references: BakeoffFiles.loadReferences(),
                                 coordinator: coordinator, syntheticClip: synthetic, corpus: corpus)
        ZoneLog.coordinator.info("bakeoff autorun finished: \(runner.lastReportURL?.lastPathComponent ?? "no report", privacy: .public)")
    }
}

/// Debug harness for unlimited-length dictation: `-zoneLongDictation 600` with
/// `ZONE_SIM_CLIP=/path/long.wav` records through the real coordinator path for that long,
/// logging memory and text growth every 15 s to `Documents/Bakeoff/long-<stamp>.json`, then
/// stops. Kill the app midway to test that the transcript history keeps what was said.
@MainActor
enum LongDictationProbe {
    struct Sample: Codable {
        let seconds: Double
        let footprint: UInt64
        let characters: Int
    }

    struct Report: Codable {
        let engine: EngineKind
        var samples: [Sample] = []
        var finalText: String?
        var finalAudioSeconds: Double?
        var stopToTextMs: Double?
    }

    static func run(seconds: Double, coordinator: DictationCoordinator) async {
        await coordinator.prepareModelAndWait()
        var report = Report(engine: coordinator.engineKind)
        let url = BakeoffFiles.reportURL(prefix: "long")
        await coordinator.startAppDictation(contextBefore: nil)
        let started = Date()
        while Date().timeIntervalSince(started) < seconds {
            try? await Task.sleep(for: .seconds(15))
            report.samples.append(Sample(seconds: Date().timeIntervalSince(started),
                                         footprint: ResourceProbe.physFootprint(),
                                         characters: coordinator.liveTextSoFar.count))
            try? BakeoffFiles.writeReport(report, to: url)
        }
        let stop = Date()
        await coordinator.stopDictation()
        report.stopToTextMs = Date().timeIntervalSince(stop) * 1000
        report.finalText = coordinator.lastResult?.text
        report.finalAudioSeconds = coordinator.lastResult?.audioSeconds
        try? BakeoffFiles.writeReport(report, to: url)
        ZoneLog.coordinator.info("long dictation finished: \(report.finalText?.count ?? 0) characters")
    }
}

/// Drops the page cache behind this app's compiled Core ML programs, which iOS does to a
/// backgrounded app under memory pressure. `msync(MS_INVALIDATE)` on a fresh mapping evicts the
/// file's clean pages for every mapping, Core ML's included; the next inference faults them
/// back in from disk. Measured on a Mac: 1.22 GB from 100% to 0% resident, 1.5 to 1.7 s to
/// read back.
enum CompiledProgramEvictor {
    struct Outcome {
        var files = 0
        var bytes: Int64 = 0
        var residentBefore: Double = 0
        var residentAfter: Double = 0
    }

    static func evict() -> Outcome {
        var outcome = Outcome()
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let bundleID = Bundle.main.bundleIdentifier else { return outcome }
        let root = caches.appendingPathComponent(bundleID).appendingPathComponent(CompiledModelCache.directoryName)
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return outcome }
        var largest: (bytes: Int64, before: Double, after: Double) = (0, 0, 0)
        for case let url as URL in files where url.pathExtension == "bnnsir" {
            let fd = open(url.path, O_RDONLY)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_size > 0 else { continue }
            let length = Int(info.st_size)
            guard let map = mmap(nil, length, PROT_READ, MAP_SHARED, fd, 0), map != MAP_FAILED else { continue }
            defer { munmap(map, length) }
            let before = residency(map, length)
            msync(map, length, MS_INVALIDATE)
            let after = residency(map, length)
            outcome.files += 1
            outcome.bytes += Int64(length)
            if Int64(length) > largest.bytes { largest = (Int64(length), before, after) }
        }
        outcome.residentBefore = largest.before
        outcome.residentAfter = largest.after
        return outcome
    }

    /// Percent of the mapping's pages in memory.
    private static func residency(_ map: UnsafeMutableRawPointer, _ length: Int) -> Double {
        let page = Int(getpagesize())
        let pages = (length + page - 1) / page
        var vector = [CChar](repeating: 0, count: pages)
        guard mincore(map, length, &vector) == 0 else { return -1 }
        return 100 * Double(vector.filter { $0 & 1 != 0 }.count) / Double(pages)
    }
}
