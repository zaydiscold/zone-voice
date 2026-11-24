// by zayd/cold @ zayd.wtf

import Darwin
import Foundation

/// Where a mic tap records when Zone is not keeping the microphone ready ("Dictate without
/// opening Zone", on by default). The keyboard can record by itself through a hidden web view, so the tap does
/// not have to open Zone and come back; this decides when it may.
///
/// It never competes with the app. An app that is running its capture engine (a meeting, a
/// note, a dictation) stamps a heartbeat, and a tap then goes to the app as it always has, so
/// a second recorder cannot take the microphone from a recording in progress.
public enum KeyboardCapture {
    public enum Route: Equatable, Sendable {
        /// Record in the keyboard.
        case keyboard
        /// Hand the request to the app: the warm ping or, with no session, opening Zone.
        case app
    }

    /// A heartbeat this recent means the app's capture engine is running right now.
    public static let appHeartbeatTolerance: TimeInterval = 8
    /// After this many dictations in a row that failed here (the microphone never started, or
    /// the words could not be recognized), the keyboard stops trying for `holdOff`: if iOS
    /// closes the route, every dictation must not cost a failed attempt first.
    public static let failuresBeforeHoldOff = 2
    public static let holdOff: TimeInterval = 3600
    /// How long the app gets to answer the posted request before the keyboard records itself.
    public static let probe: Duration = .milliseconds(200)

    /// Memory the keyboard must have left below iOS's limit to start its first recording: the
    /// web view, its page and WebKit's first capture cost 7 to 13 MB within a second. iOS ends
    /// a keyboard that passes its limit and drops the person to the system keyboard, which
    /// anomalyco/hex's testers hit on 4 GB iPhones (#2045, where these numbers come from).
    public static let memoryToStart: UInt64 = 32 * 1_048_576
    /// The same once the page is loaded, when only the capture itself is still to come.
    public static let memoryToStartLoaded: UInt64 = 24 * 1_048_576

    /// Whether the keyboard has room to record. Where the system reports no limit (nil: the
    /// simulator), it does.
    public static func hasMemory(available: UInt64?, pageLoaded: Bool) -> Bool {
        guard let available else { return true }
        return available >= (pageLoaded ? memoryToStartLoaded : memoryToStart)
    }

    /// Whether Zone may use the microphone, as far as the keyboard can tell. A keyboard process
    /// keeps the permission it read when it started, so one opened before the person allowed
    /// the microphone reads "not asked" until iOS restarts it; the app publishes its own
    /// reading with its time. A definite keyboard reading wins over an older app reading. WebKit still checks
    /// for itself, and a refusal there is an ordinary failed start (anomalyco/hex #2071).
    public struct PermissionObservation {
        private var previous: Bool?
        private var appAtChange: MicrophoneReading?
        private var hasObserved = false

        public init() {}

        public mutating func allowed(keyboard: Bool?, app: MicrophoneReading?) -> Bool {
            if !hasObserved || keyboard != previous {
                hasObserved = true
                previous = keyboard
                appAtChange = app
            }
            guard let keyboard else { return app?.granted == true }
            if let app, app != appAtChange { return app.granted }
            return keyboard
        }
    }

    /// The route for a tap, before anything is posted.
    /// - Parameter speechAssetInstalled: the app found Apple's speech asset installed
    ///   (`SharedStore.keyboardSpeechReady`). Without it the keyboard would record, then fail to
    ///   recognize, so the tap opens Zone, which fetches the asset.
    /// - Parameter hasMemory: `hasMemory(available:pageLoaded:)`. Short of it the tap opens Zone
    ///   rather than risk the keyboard being ended mid-start.
    public static func route(enabled: Bool, systemSupports: Bool, microphoneGranted: Bool, speechAssetInstalled: Bool,
                             hasMemory: Bool = true, appHeartbeat: Date?, failures: Failures, now: Date) -> Route {
        guard enabled, systemSupports, microphoneGranted, speechAssetInstalled, hasMemory else { return .app }
        if let appHeartbeat, abs(now.timeIntervalSince(appHeartbeat)) <= appHeartbeatTolerance { return .app }
        if failures.holdsOff(now: now) { return .app }
        return .keyboard
    }

    /// The route once the app has had `probe` to answer the request. Silence means no app
    /// process took it; `needsApp` is the app saying it cannot start the microphone from the
    /// background. Any other answer is the app handling the request, and the keyboard steps back.
    public static func routeAfterProbe(phase: DictationPhase?) -> Route {
        switch phase {
        case nil, .requested, .needsApp: return .keyboard
        default: return .app
        }
    }

    /// How long recognition of a recording may take once the microphone is off: a minute,
    /// more for long audio, never past five. The app gives its own recognizer the same.
    public static func recognitionLimit(audioSeconds: Double) -> TimeInterval {
        guard audioSeconds.isFinite else { return 60 }
        return min(max(60, audioSeconds / 2), 300)
    }

    /// Only digital silence skips both models. Even one nonzero block can hold a quiet word.
    public static func isSilent(peak: Float) -> Bool {
        !peak.isFinite || peak <= 0
    }

    /// The longest a recording in the keyboard runs, the app's own limit.
    public static let maximumLength: TimeInterval = DictationLimits.standard.maximumLength
    /// How long a paused recording in the keyboard is held before it finishes and keeps its
    /// words: the app's shortest pause limit (`InactivityPolicy.minimumPauseLimit`).
    public static let pauseLimit: TimeInterval = InactivityPolicy.minimumPauseLimit

    public enum LimitDecision: Equatable, Sendable {
        case keepRecording
        case reachedMaximum
        case pausedTooLong
    }

    /// Whether a recording in the keyboard should stop by itself and keep its words.
    public static func limitDecision(now: Date, startedAt: Date, pausedSince: Date?) -> LimitDecision {
        if now.timeIntervalSince(startedAt) >= maximumLength { return .reachedMaximum }
        if let pausedSince, now.timeIntervalSince(pausedSince) >= pauseLimit { return .pausedTooLong }
        return .keepRecording
    }

    /// Whether the keyboard's own result may go into the shared store. It never replaces a
    /// different request or result that came after it (one the app is serving for another tap);
    /// the words are in History either way.
    public static func mayPublish(local: DictationRequest, storedRequest: DictationRequest?,
                                  storedResult: DictationResult?) -> Bool {
        if let storedRequest, storedRequest.id != local.id, storedRequest.createdAt > local.createdAt { return false }
        if let storedResult, storedResult.requestID != local.id, storedResult.createdAt > local.createdAt { return false }
        return true
    }

    /// The generation the keyboard's own result is published under. Its request never reached
    /// the app, so no cancel of the app's work applies to it; a cancel on another keyboard
    /// controller that happened to share its number must not make it read as cancelled.
    public static func publishedGeneration(of request: DictationRequest, ledger: InsertionLedger) -> Int {
        max(request.generation, ledger.droppedGeneration + 1)
    }

    /// Temporary recordings are `zone-keyboard-<id>.wav`; a recognition that failed keeps its
    /// file as `zone-keyboard-retry-<id>.wav` for one more try.
    public static func eraseRecordings(in directory: URL) throws {
        let manager = FileManager.default
        for url in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where url.lastPathComponent.hasPrefix(recordingPrefix) && url.pathExtension == "wav" {
            try manager.removeItem(at: url)
        }
    }

    public static var group: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)
    }

    private static func libraryState(_ group: URL) -> URL {
        group.appendingPathComponent("Library/Application Support/KeyboardLibrary", isDirectory: true)
    }

    public static func eraseEpoch(in group: URL?) -> Data? {
        guard let group else { return nil }
        return (try? Data(contentsOf: libraryState(group).appendingPathComponent("keyboard-library-generation")))
            ?? (try? Data(contentsOf: group.appendingPathComponent("keyboard-library-generation")))
    }

    private static func withLibraryLock<T>(in group: URL, _ body: () throws -> T) throws -> T {
        let folder = libraryState(group)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = open(folder.appendingPathComponent("keyboard-library.lock").path,
                      O_CREAT | O_RDWR | O_EXLOCK | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        return try body()
    }

    public static func whileLibraryCurrent(in group: URL?, epoch: Data?, _ body: () -> Bool) -> Bool {
        guard let group else { return false }
        return (try? withLibraryLock(in: group) {
            guard !hasEraseRequest(in: group), eraseEpoch(in: group) == epoch else { return false }
            return body()
        }) == true
    }

    public static func requestAudioErase(in group: URL) throws {
        try withLibraryLock(in: group) {
            try Data(UUID().uuidString.utf8).write(to: libraryState(group).appendingPathComponent("keyboard-library-generation"), options: .atomic)
            try Data().write(to: libraryState(group).appendingPathComponent("erase-keyboard-audio"), options: .atomic)
            let inbox = group.appendingPathComponent("Library/Application Support/KeyboardAudio")
            if FileManager.default.fileExists(atPath: inbox.path) { try eraseRecordings(in: inbox) }
            let staging = group.appendingPathComponent("Library/Caches/WorkerAudio")
            do { try FileManager.default.removeItem(at: staging) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { }
        }
    }

    private static func eraseRequests(in group: URL) -> [URL] {
        [libraryState(group), group].map { $0.appendingPathComponent("erase-keyboard-audio") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func hasEraseRequest(in group: URL) -> Bool { !eraseRequests(in: group).isEmpty }

    public static func finishAudioErase(in group: URL, temporary: URL, cancel: () -> Void) throws {
        guard hasEraseRequest(in: group) else { return }
        try withLibraryLock(in: group) {
            let requests = eraseRequests(in: group)
            guard !requests.isEmpty else { return }
            cancel()
            try eraseRecordings(in: temporary)
            for file in requests { try FileManager.default.removeItem(at: file) }
        }
    }

    public static let recordingPrefix = "zone-keyboard-"
    public static let retryPrefix = "zone-keyboard-retry-"
    /// A kept recording older than this is removed unretried, like an unused result.
    public static let retryKeptFor: TimeInterval = InsertionDecider.maxAge

    public static func handoffName(_ id: UUID) -> String { "zone-keyboard-finish-\(id.uuidString).wav" }

    public static func recordingName(_ id: UUID) -> String { "\(recordingPrefix)\(id.uuidString).wav" }
    public static func retryName(_ id: UUID) -> String { "\(retryPrefix)\(id.uuidString).wav" }

    public static func audioID(fromName name: String) -> UUID? {
        if name.hasPrefix("zone-keyboard-finish-"), name.hasSuffix(".wav") {
            return UUID(uuidString: String(name.dropFirst("zone-keyboard-finish-".count).dropLast(4)))
        }
        if let id = retryID(fromName: name) { return id }
        guard name.hasPrefix(recordingPrefix), name.hasSuffix(".wav") else { return nil }
        return UUID(uuidString: String(name.dropFirst(recordingPrefix.count).dropLast(4)))
    }

    /// The id of a kept recording's file name, nil for any other file.
    public static func retryID(fromName name: String) -> UUID? {
        guard name.hasPrefix(retryPrefix), name.hasSuffix(".wav") else { return nil }
        return UUID(uuidString: String(name.dropFirst(retryPrefix.count).dropLast(4)))
    }

    /// The page is loaded when the keyboard appears, ahead of any tap, only for someone who
    /// dictated in the keyboard this recently: a first dictation then has just the microphone
    /// left to open (anomalyco/hex #2089 measured 862 ms to first audio without, 227 ms with),
    /// and someone who only types never pays for a web view.
    public static let preloadsFor: TimeInterval = 14 * 24 * 3600

    /// Whether to load the page as the keyboard appears.
    public static func preloads(route: Route, lastDictatedHere: Date?, now: Date) -> Bool {
        guard route == .keyboard, let lastDictatedHere else { return false }
        let age = now.timeIntervalSince(lastDictatedHere)
        return age >= 0 && age < preloadsFor
    }

    /// The engine name History keeps for a dictation the keyboard recorded by itself
    /// (`EngineKind.appleSpeech`'s raw value; the keyboard does not link the app's engine list).
    public static let historyEngine = "appleSpeech"

    public static func historyEngine(for module: String) -> String {
        switch module {
        case "speech": return historyEngine
        case "dictation": return "appleDictation"
        default: return module
        }
    }

    /// What History says under a dictation the keyboard recorded by itself, so a word that
    /// reads differently from Zone's own model is explained. Nil for every other dictation.
    public static func historyNote(engine: String, source: TranscriptSource) -> String? {
        if source == .keyboard, engine == "fluidMiniWeb" { return "Recognized on iPhone with Fluid Speech Mini in WebKit." }
        if source == .keyboard, engine == "zoneLinkGPU" { return "Recognized by your Zone Link GPU provider." }
        if source == .keyboard, engine == "zoneMini" { return "Recorded in the keyboard with Zone's speech model." }
        guard source == .keyboard, [historyEngine, "appleDictation"].contains(engine) else { return nil }
        return "Recorded in the keyboard with Apple's speech model."
    }

    /// Dictations that failed in a row, kept in the keyboard's own defaults.
    public struct Failures: Codable, Equatable, Sendable {
        public var count: Int
        public var last: Date?

        public init(count: Int = 0, last: Date? = nil) {
            self.count = count
            self.last = last
        }

        public func holdsOff(now: Date) -> Bool {
            guard count >= KeyboardCapture.failuresBeforeHoldOff, let last else { return false }
            let age = now.timeIntervalSince(last)
            // A clock moved back must not hold the keyboard off forever.
            return age >= 0 && age < KeyboardCapture.holdOff
        }

        public mutating func recordFailure(now: Date) {
            // A failure after the hold-off ran out starts a new count.
            if let last, now.timeIntervalSince(last) >= KeyboardCapture.holdOff { count = 0 }
            count += 1
            last = now
        }

        public mutating func recordSuccess() {
            count = 0
            last = nil
        }
    }

    /// One block of microphone samples as a 0...1 meter value on Zone's own scale, so the
    /// keyboard's graphic moves the same whether the app or the keyboard recorded.
    public static func level(rootMeanSquare: Float) -> Float {
        guard rootMeanSquare.isFinite, rootMeanSquare > 0 else { return 0 }
        var scale = AdaptiveLevelScale()
        return scale.map(decibels: 20 * log10(min(rootMeanSquare, 1)), elapsed: 0)
    }
}

/// A permission reading from one install. Store fractions of a second so two changes within
/// one second stay in order even in the shared store's whole-second date format.
public struct MicrophoneReading: Codable, Sendable, Equatable {
    public let granted: Bool
    public let install: String
    private let timestamp: TimeInterval
    public var at: Date { Date(timeIntervalSince1970: timestamp) }

    init(granted: Bool, at: Date, install: String) {
        self.granted = granted
        self.install = install
        self.timestamp = at.timeIntervalSince1970
    }
}
