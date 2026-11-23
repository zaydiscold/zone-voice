// by zayd/cold @ zayd.wtf

import Foundation
import ZoneCore

enum SpeechEngineError: LocalizedError {
    case notReady
    case utteranceClosed
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .notReady: return "The speech model is not loaded yet."
        case .utteranceClosed: return "This dictation has already finished."
        case .unavailable(let reason): return reason
        }
    }
}

/// The one internal boundary behind which the engine can be swapped without touching
/// capture, coordination or UI. Every implementation keeps the same contract: one
/// `UtteranceSession` per dictation, all native work on one serial queue (or actor).
protocol SpeechEngine: AnyObject {
    var kind: EngineKind { get }
    var isReady: Bool { get }
    /// True when nothing needs downloading before `prepare()` can load the model.
    func assetsPresent() -> Bool
    /// Bytes this engine keeps on disk in our container (0 for system-managed assets).
    func bytesOnDisk() -> Int64
    /// Deletes downloaded assets. System-managed assets are left alone.
    func removeAssets() throws
    /// Fetches the assets without loading the model, for the model library.
    func downloadAssets(progress: @escaping @Sendable (Double, String) -> Void) async throws
    /// Downloads assets if missing and loads the model. Safe to call repeatedly.
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws
    /// Biases recognition toward the unusual words in `text` (names, jargon) for the next
    /// utterances. Pass an empty string to clear. Engines that cannot bias ignore it.
    func setContextHints(_ text: String)
    /// Explicit user vocabulary, independent of permission to use surrounding typed text.
    func setPersonalWords(_ words: [String])
    /// Starts one dictation. Feed 16 kHz mono samples, then `finish()` for the text.
    func beginUtterance() throws -> UtteranceSession
    /// Releases the model. The next `prepare()` reloads it.
    func unload()
    /// Waits for native decoder work and cleanup before its files can be removed.
    func unloadAndWait() async
    /// A dictation is likely soon (the keyboard just appeared): bring a model that has sat idle
    /// back into memory now. Does nothing when the model is warm, not loaded, or busy.
    func prewarm()
}

extension SpeechEngine {
    func prewarm() {}
}

extension SpeechEngine {
    func setPersonalWords(_ words: [String]) {}
    func unloadAndWait() async { unload() }
}

/// One recognizer run. The requirements live in ZoneCore (`RecognitionSession`) so the
/// recording's segmenting can be tested there; every engine's session is one of these.
protocol UtteranceSession: RecognitionSession {}

extension SegmentedRecognition: UtteranceSession {}
extension LexiconRecognitionSession: UtteranceSession {}

/// Every engine configuration the app can run. One `SpeechModel` can have several (CPU only
/// versus CPU and Neural Engine); Diagnostics and the bakeoff pick configurations, the model
/// library in Settings picks models.
///
/// Moonshine's configurations were removed on 2026-11-18 with the Moonshine package. A saved
/// raw value from them ("moonshineTinySingleThread") no longer decodes, so `selected` falls back
/// to `recommended`; history keeps engine names as plain strings and is unaffected.
enum EngineKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case parakeetCPU
    case parakeetANE
    case fluidMiniCPU
    case fluidMiniANE
    case appleSpeech
    case appleDictation

    /// The product default since 2026-11-03 and, since 2026-11-18, the only product engine:
    /// Fluid Speech Mini on the CPU. Most accurate engine in Zone's own simulator run (3.7% WER
    /// on 50 LibriSpeech test-other clips, doc 21) and 0.17 to 0.59 s stop-to-text warm on an
    /// iPhone 15 Pro.
    static let `default`: EngineKind = .fluidMiniCPU

    var id: String { rawValue }

    var model: SpeechModel {
        switch self {
        case .parakeetCPU, .parakeetANE: return .parakeet110m
        case .fluidMiniCPU, .fluidMiniANE: return .fluidSpeechMini
        case .appleSpeech: return .appleSpeech
        case .appleDictation: return .appleDictation
        }
    }

    var displayName: String {
        switch self {
        case .parakeetCPU, .fluidMiniCPU: return model.displayName + ", CPU only"
        case .parakeetANE, .fluidMiniANE: return model.displayName + ", CPU and Neural Engine"
        default: return model.displayName
        }
    }

    /// Short label for tables and logs.
    var shortName: String {
        switch self {
        case .parakeetCPU, .fluidMiniCPU: return model.shortName + " CPU"
        case .parakeetANE, .fluidMiniANE: return model.shortName + " ANE"
        default: return model.shortName
        }
    }

    /// In-process Neural Engine work while backgrounded fails hard on iOS 27 without the
    /// Background Inference entitlement, which a free Personal
    /// Team cannot provision. Apple's engines run in a system process; whether the gate
    /// reaches them is hypothesis H1, measured by the bakeoff rather than assumed.
    var usesNeuralEngineInProcess: Bool { self == .parakeetANE || self == .fluidMiniANE }

    var isAvailableOnThisOS: Bool {
        switch self {
        case .appleSpeech, .appleDictation:
            if #available(iOS 26.0, *) { return true }
            return false
        default:
            // Fluid Speech Mini's model card requires iOS 18, Zone's minimum since 2026-11-18.
            return true
        }
    }

    func makeEngine() -> SpeechEngine {
        switch self {
        case .parakeetCPU: return ParakeetEngine(model: .tdtCtc110m, useNeuralEngine: false)
        case .parakeetANE: return ParakeetEngine(model: .tdtCtc110m, useNeuralEngine: true)
        case .fluidMiniCPU: return ParakeetEngine(model: .fluidSpeechMini, useNeuralEngine: false)
        case .fluidMiniANE: return ParakeetEngine(model: .fluidSpeechMini, useNeuralEngine: true)
        case .appleSpeech, .appleDictation:
            if #available(iOS 26.0, *) {
                return AppleSpeechEngine(module: self == .appleSpeech ? .speech : .dictation)
            }
            return UnavailableEngine(kind: self, reason: "Apple's on-device recognizer needs iOS 26.")
        }
    }

    private static let defaultsKey = "zone.diagnostics.engine"

    /// The first-run engine on every iPhone: Fluid Speech Mini (`.default`). Until 2026-11-18
    /// phones before the A17 Pro started on Moonshine Tiny ("Light"); Zayd retired it for one
    /// model everywhere. No phone older than the 15 Pro has been measured with Fluid Speech Mini
    /// yet, so the first reports from one belong in `docs/research`.
    static var recommended: EngineKind { .default }

    /// The engine Diagnostics selected, or the recommendation. Retired choices migrate.
    /// A release build has no Diagnostics, so it always runs the product engine: a choice saved
    /// by an older build that had one (Apple's recognizer, a Neural Engine variant) moves back.
    static var selected: EngineKind {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let kind = EngineKind(rawValue: raw), kind.isAvailableOnThisOS else { return .recommended }
            #if !DEBUG
            if kind != .default {
                UserDefaults.standard.set(EngineKind.default.rawValue, forKey: defaultsKey)
                return .default
            }
            #endif
            if kind.model.isRetired {
                let replacement = SpeechModel.retirementReplacement.productEngine
                UserDefaults.standard.set(replacement.rawValue, forKey: defaultsKey)
                return replacement
            }
            return kind
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

/// A recognizer as the user sees it in the model library: one download.
///
/// Moonshine's three models stay as retired IDs only so the launch cleanup can find and delete
/// their old downloads (`assetDirectory`, `makeEngine`); the app no longer contains their engine.
enum SpeechModel: String, CaseIterable, Identifiable, Sendable {
    case moonshineTiny
    case moonshineSmall
    case moonshineMedium
    case parakeet110m
    case fluidSpeechMini
    case appleSpeech
    case appleDictation

    var id: String { rawValue }

    /// Keep historical IDs so upgrades can remove their files and read old diagnostics.
    var isRetired: Bool {
        switch self {
        case .moonshineTiny, .moonshineSmall, .moonshineMedium, .parakeet110m: return true
        case .fluidSpeechMini, .appleSpeech, .appleDictation: return false
        }
    }

    /// True for a retired model whose engine was removed from the app; only its files remain.
    var isFilesOnly: Bool {
        self == .moonshineTiny || self == .moonshineSmall || self == .moonshineMedium
    }

    /// The model the library offers: one, Fluid Speech Mini.
    static var offered: [SpeechModel] { [.fluidSpeechMini] }
    static var retired: [SpeechModel] { allCases.filter(\.isRetired) }

    /// Where a retired choice moves to.
    static var retirementReplacement: SpeechModel { .fluidSpeechMini }

    /// The engine that owns this model's files: its product engine, or for a files-only retired
    /// model one that can measure and delete its old download and nothing else.
    func makeEngine() -> SpeechEngine {
        guard isFilesOnly else { return productEngine.makeEngine() }
        return RetiredModelFiles(kind: productEngine, directory: assetDirectory)
    }

    var displayName: String {
        switch self {
        case .moonshineTiny: return "Moonshine Tiny Streaming"
        case .moonshineSmall: return "Moonshine Small Streaming"
        case .moonshineMedium: return "Moonshine Medium Streaming"
        case .parakeet110m: return "Parakeet TDT-CTC 110M"
        case .fluidSpeechMini: return "Fluid Speech Mini"
        case .appleSpeech: return "Apple SpeechTranscriber"
        case .appleDictation: return "Apple DictationTranscriber"
        }
    }

    var shortName: String {
        switch self {
        case .moonshineTiny: return "Moonshine Tiny"
        case .moonshineSmall: return "Moonshine Small"
        case .moonshineMedium: return "Moonshine Medium"
        case .parakeet110m: return "Parakeet 110M"
        case .fluidSpeechMini: return "Fluid Mini"
        case .appleSpeech: return "Apple Speech"
        case .appleDictation: return "Apple Dictation"
        }
    }

    var language: String { "English" }

    /// Download, decimal bytes. Moonshine (retired): sums of the v0.1.5 manifest without the
    /// optional word-timestamp decoder; Parakeet: doc 08's file audit; Fluid Mini: its model card.
    /// Apple's are system assets.
    var approximateDownloadBytes: Int64 {
        switch self {
        case .moonshineTiny: return 45_233_659
        case .moonshineSmall: return 142_300_974
        case .moonshineMedium: return 269_141_623
        case .parakeet110m: return 227_468_698
        case .fluidSpeechMini: return 253_000_000
        case .appleSpeech, .appleDictation: return 0
        }
    }

    /// Extra storage iOS uses to prepare the model the first time it loads, decimal bytes.
    /// Fluid Mini: 1,284,184,974 bytes measured on an iPhone on November 8, 2026, rounded up.
    /// Zero where it has not been measured; the library then shows only measured storage.
    var approximatePreparedBytes: Int64 {
        switch self {
        case .fluidSpeechMini: return 1_300_000_000
        default: return 0
        }
    }

    var license: String {
        switch self {
        case .moonshineTiny, .moonshineSmall, .moonshineMedium: return "MIT"
        case .parakeet110m: return "CC BY 4.0"
        case .fluidSpeechMini: return "CC BY 4.0"
        case .appleSpeech, .appleDictation: return "Built into iOS"
        }
    }

    /// The configuration the warm path uses for this model. Neural Engine variants fail in the
    /// background without a paid-team entitlement, so the product default is the CPU one.
    /// A files-only retired model has no engine left; it names the one that replaced it.
    var productEngine: EngineKind {
        switch self {
        case .moonshineTiny, .moonshineSmall, .moonshineMedium: return .fluidMiniCPU
        case .parakeet110m: return .parakeetCPU
        case .fluidSpeechMini: return .fluidMiniCPU
        case .appleSpeech: return .appleSpeech
        case .appleDictation: return .appleDictation
        }
    }

    var isAvailableOnThisOS: Bool { productEngine.isAvailableOnThisOS }

}

/// Stands in for an engine the OS cannot run, so selection never crashes.
final class UnavailableEngine: SpeechEngine {
    let kind: EngineKind
    private let reason: String
    init(kind: EngineKind, reason: String) {
        self.kind = kind
        self.reason = reason
    }
    var isReady: Bool { false }
    func assetsPresent() -> Bool { false }
    func bytesOnDisk() -> Int64 { 0 }
    func removeAssets() throws {}
    func downloadAssets(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        throw SpeechEngineError.unavailable(reason)
    }
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        throw SpeechEngineError.unavailable(reason)
    }
    func setContextHints(_ text: String) {}
    func beginUtterance() throws -> UtteranceSession { throw SpeechEngineError.unavailable(reason) }
    func unload() {}
}

/// The files of a retired model whose engine is gone (Moonshine): enough to report and delete
/// an old download, never to load or download one. `kind` is the engine that replaced it.
final class RetiredModelFiles: SpeechEngine {
    let kind: EngineKind
    private let directory: URL?
    init(kind: EngineKind, directory: URL?) {
        self.kind = kind
        self.directory = directory
    }
    var isReady: Bool { false }
    func assetsPresent() -> Bool { false }
    func bytesOnDisk() -> Int64 { directory.map { DiskUsage.bytes(at: $0) } ?? 0 }
    func removeAssets() throws {
        guard let directory, FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }
    func downloadAssets(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        throw SpeechEngineError.unavailable("This model was retired.")
    }
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        throw SpeechEngineError.unavailable("This model was retired.")
    }
    func setContextHints(_ text: String) {}
    func beginUtterance() throws -> UtteranceSession { throw SpeechEngineError.unavailable("This model was retired.") }
    func unload() {}
}

/// Directory size helper shared by engines that download into our container.
enum DiskUsage {
    static func bytes(at directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }
}
