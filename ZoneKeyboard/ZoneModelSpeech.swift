import ExtensionFoundation
import Foundation
import ZoneCore

struct KeyboardWorkerIssue: Error, Sendable {
    let reason: String
    var detail: String? = nil
    var code: String? = nil
    var stage: String? = nil
    /// The remembered helper failure behind a skip, for the recording log.
    var extra: [String: String] = [:]

    init(_ reason: String, block: WorkerHealth.Block) {
        self.reason = reason
        extra = block.fields
    }

    init(_ reason: String, error: Error? = nil) {
        self.reason = reason
        if let error {
            detail = WorkerDiagnostic.error(error).localizedDescription
            code = JournalFormat.error(error)
            stage = (error as NSError).userInfo["workerStage"] as? String
        }
    }

    static func describe(_ error: Error) -> Self {
        if let issue = error as? Self { return issue }
        if let stalled = error as? Watchdog.Stalled {
            return Self(stalled.what == "Starting the speech worker" ? "startTimeout" : "recognitionTimeout", error: error)
        }
        let ns = error as NSError
        if ns.domain == SpeechHelperRefusal.domain, ns.code == SpeechHelperRefusal.tooLittleRoom {
            return Self("helperTooSmall", error: error)
        }
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteOutOfSpaceError: return Self("notEnoughRoom", error: error)
            case NSXPCConnectionInvalid, NSXPCConnectionInterrupted, NSXPCConnectionReplyInvalid:
                return Self("connectionError", error: error)
            default: break
            }
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOMEM) { return Self("memory", error: error) }
        return Self(ns.userInfo["workerStage"] == nil ? "workerError" : "modelPreparation", error: error)
    }

    var fields: [String: String] {
        var value = ["workerReason": reason]
        value["workerError"] = detail
        value["workerCode"] = code
        value["workerStage"] = stage
        value.merge(extra) { reason, _ in reason }
        return value
    }
}

@available(iOS 26, *)
@MainActor
final class ZoneModelSpeech {
    static let shared = ZoneModelSpeech()
    private var removalObserver: DarwinObservation?
    private let startupLimit: TimeInterval
    private let startForTest: (@MainActor () async throws -> Void)?

    init(startupLimit: TimeInterval = 8, startForTest: (@MainActor () async throws -> Void)? = nil) {
        self.startupLimit = startupLimit
        self.startForTest = startForTest
        removalObserver = DarwinNotifier.observe(.workerCacheRemoval) { [weak self] in self?.reset() }
    }

    private var process: AppExtensionProcess?
    private var connection: NSXPCConnection?
    private var opening: Task<Void, Error>?
    private var generation = UUID()
    private var startMs = 0
    private var workerPID: Int32?
    private var hostLease: FileHandle?
    private var preparation: Task<Void, Error>?
    private var preparationToken = UUID()
    private var prepared = false
    private var measuredUsable = false
    private var attemptedAppearance = false
    private var monitor: AppExtensionPoint.Monitor?
    /// What hosts are waiting on the helper for, newest last: "start", "warm", "recognize".
    private var waitingOn: [String] = []
    /// The generation whose helper was already counted as ended by iOS.
    private var countedGeneration: UUID?
    private var hidden = false
    private var helperLimitMB: Int?
    private var tidying: Task<Void, Never>?
    /// True while the lab runs the helper into its limit on purpose.
    private var labRunning = false

    /// Why a connection is opened. Only a dictation needs room for the model in the helper.
    enum Purpose { case dictation, tidy, lab }

    /// The remembered reason not to start the helper on this app build and iOS build.
    var blocked: WorkerHealth.Block? { WorkerHealth.block() }

    private var appID: String {
        Bundle.main.bundleIdentifier?.components(separatedBy: ".").dropLast().joined(separator: ".") ?? ""
    }

    private var discoveryIssue: KeyboardWorkerIssue?

    func discover() async {
        guard monitor == nil else { return }
        let point: AppExtensionPoint
        do { point = try AppExtensionPoint(identifier: workerPointID) }
        catch { discoveryIssue = KeyboardWorkerIssue("pointLookup", error: error); return }
        do { monitor = try await AppExtensionPoint.Monitor(appExtensionPoint: point); discoveryIssue = nil }
        catch { discoveryIssue = KeyboardWorkerIssue("monitorCreation", error: error) }
    }

    /// Whether Zone's speech model can hear a recording made in the keyboard. Not after iOS
    /// ended the helper, or the helper said it has too little memory, on this build.
    var ready: Bool {
        blocked == nil && (prepared || (measuredUsable && WorkerStorage.preparedForCurrentSystem)) && SharedMiniModel.verified
            && monitor?.identities.contains { $0.bundleIdentifier == appID + ".recognition" } == true
    }

    var readinessReason: String {
        do { try requireModel() } catch { return KeyboardWorkerIssue.describe(error).reason }
        if let blocked { return "helper" + blocked.reason.rawValue.prefix(1).uppercased() + blocked.reason.rawValue.dropFirst() }
        return ready ? "ready" : "notDiscovered"
    }

    /// Runs one call to the helper and remembers what is being waited for, so that a helper
    /// which goes away mid-call is known to have been ended by iOS, not released by Zone.
    private func waiting<T>(for stage: String, _ call: () async throws -> T) async throws -> T {
        let started = generation
        waitingOn.append(stage)
        defer { if let index = waitingOn.lastIndex(of: stage) { waitingOn.remove(at: index) } }
        do { return try await call() }
        catch {
            let ns = error as NSError
            let lost = ns.domain == NSCocoaErrorDomain
                && [NSXPCConnectionInvalid, NSXPCConnectionInterrupted, NSXPCConnectionReplyInvalid].contains(ns.code)
            // Zone's own release changes the generation first, so only iOS reaches this.
            if lost, generation == started { helperWentAway(during: stage) }
            throw error
        }
    }

    /// iOS ended the helper while a host waited on it. Remembered once, for this app build and
    /// iOS build, so the next dictation goes straight to the fallback with no wait.
    private func helperWentAway(during stage: String?, recording: UUID? = nil) {
        guard countedGeneration != generation else { return }
        countedGeneration = generation
        let counts = WorkerHealth.countsAsEnded(waitingOn: stage, hostVisible: !hidden,
                                                deviceEnforcesLimits: MemoryFootprint.available() != nil)
        var fields = MemoryFootprint.journalFields()
        fields["decision"] = labRunning ? "helperEndedInLab" : counts ? "helperEnded" : "helperGone"
        fields["waitingOn"] = stage
        fields["pid"] = workerPID.map(String.init)
        fields["helperLimitMB"] = helperLimitMB.map(String.init)
        if counts, !labRunning {
            fields.merge(WorkerHealth.remember(.ended, stage: stage, limitMB: helperLimitMB).fields) { _, block in block }
        }
        KeyboardLog.journal?.log("keyboardModelDecision", recording: recording, fields)
        KeyboardLog.journal?.flush()
    }

    private func requireModel() throws {
        guard let directory = SharedMiniModel.directory, FileManager.default.fileExists(atPath: directory.path)
        else { throw KeyboardWorkerIssue("modelNotShared") }
        guard SharedMiniModel.verified else { throw KeyboardWorkerIssue("modelNotVerified") }
    }

    private func decision(_ decision: String, id: UUID, issue: KeyboardWorkerIssue? = nil) {
        var fields = MemoryFootprint.journalFields()
        fields["decision"] = decision
        fields["pid"] = workerPID.map(String.init)
        fields["build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        fields["generation"] = generation.uuidString
        fields["marker"] = String(SharedMiniModel.verified)
        fields["identityCount"] = monitor.map { String($0.identities.count) }
        if let issue { fields.merge(issue.fields) { _, value in value } }
        KeyboardLog.journal?.log("keyboardModelDecision", recording: id, fields)
        if KeyboardLog.journal == nil { KeyboardLog.mic.info("Worker decision \(decision, privacy: .public)") }
    }

    private var idle: Task<Void, Never>?
    private var active = 0

    private func reset() {
        generation = UUID()
        preparationToken = UUID()
        preparation = nil
        prepared = false
        workerPID = nil
        opening?.cancel()
        opening = nil
        connection?.invalidate()
        connection = nil
        process?.invalidate()
        process = nil
        hostLease = nil
        idle?.cancel()
        idle = nil
    }

    func keyboardDidDisappear() {
        hidden = true
        if active == 0 { releaseIdleSession() }
    }

    /// Every appearance. Cheap when there is nothing to do: two reads of the shared defaults.
    /// When the helper may hold files it can never use (a first run on this build, or a
    /// preparation that was started), it is opened once so it can delete them. All of the work
    /// is in the helper's process, off the keyboard's main thread.
    func keyboardAppeared(prepares: Bool) {
        hidden = false
        guard SharedMiniModel.directory != nil else { return }
        if prepares, blocked == nil, !attemptedAppearance, SharedMiniModel.verified { return prepareOnAppearance() }
        guard WorkerStorage.needsTidy(), tidying == nil, active == 0, connection == nil, opening == nil else { return }
        tidying = Task {
            defer { tidying = nil }
            do {
                beginUse()
                defer { endUse() }
                try await connect(purpose: .tidy)
                KeyboardLog.journal?.log("keyboardHelperTidy", ["helperLimitMB": helperLimitMB.map(String.init) ?? "unknown",
                                                                "bytesLeft": String(WorkerStorage.bytes)])
            } catch {
                KeyboardLog.journal?.log("keyboardHelperTidy", ["error": KeyboardWorkerIssue.describe(error).reason])
            }
            if active == 0 { releaseIdleSession() }
        }
    }

    private func releaseIdleSession() {
        (connection?.remoteObjectProxyWithErrorHandler { _ in } as? SpeechWorkerService)?.endIdleSession()
        reset()
    }

    private func beginUse() {
        active += 1
        idle?.cancel()
    }

    private func endUse() {
        active -= 1
        guard active == 0 else { return }
        // Keep a short series of dictations warm, then give back the process.
        idle = Task {
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            if active == 0 { releaseIdleSession() }
        }
    }

    func connect(recording: UUID? = nil, purpose: Purpose = .dictation) async throws {
        if purpose == .dictation, let blocked { throw KeyboardWorkerIssue("helperSkipped", block: blocked) }
        if let opening { return try await opening.value }
        if connection != nil { return }
        let token = UUID()
        generation = token
        let task = Task {
            try await Watchdog.run(what: "Starting the speech worker", limit: startupLimit) {
                try await self.open(token, recording: recording, purpose: purpose)
            }
        }
        opening = task
        do {
            try await task.value
            if generation == token { opening = nil }
        } catch {
            if generation == token { reset() }
            throw error
        }
    }

    private func open(_ token: UUID, recording: UUID?, purpose: Purpose) async throws {
        if let startForTest { return try await startForTest() }
        let start = Date()
        await discover()
        if purpose != .tidy { try requireModel() }
        guard let identity = monitor?.identities.first(where: { $0.bundleIdentifier == appID + ".recognition" }) else {
            throw discoveryIssue ?? KeyboardWorkerIssue("notDiscovered")
        }
        guard let owner = try WorkerStorage.hostLease() else { throw KeyboardWorkerIssue("workerBusyInAnotherHost") }
        // Hold the launch lease even when an OS launch returns after its caller timed out.
        defer { withExtendedLifetime(owner) {} }
        if let recording, let directory = WorkerStorage.coordinationDirectory,
           try !WorkerStorage.reserveLaunch(for: recording, in: directory) { throw KeyboardWorkerIssue("launchBudget") }
        KeyboardLog.journal?.log("keyboardWorkerAttempt", recording: recording, ["phase": "launch",
            "identityCount": String(monitor?.identities.count ?? 0), "marker": String(SharedMiniModel.verified),
            "budgetSeconds": String(startupLimit), "generation": token.uuidString])
        if let recording { decision("launch", id: recording) }
        let interrupted: @Sendable () -> Void = {
            Task { @MainActor in
                guard self.generation == token else { return }
                if let recording { self.decision("interrupted", id: recording, issue: .init("connectionInterrupted")) }
                self.helperWentAway(during: self.waitingOn.last, recording: recording)
                self.reset()
            }
        }
        let process: AppExtensionProcess
        do { process = try await AppExtensionProcess(configuration: .init(appExtensionIdentity: identity, onInterruption: interrupted)) }
        catch { throw KeyboardWorkerIssue("startError", error: error) }
        guard generation == token, !Task.isCancelled else {
            process.invalidate()
            throw CancellationError()
        }
        let connection: NSXPCConnection
        do { connection = try process.makeXPCConnection() }
        catch { process.invalidate(); throw KeyboardWorkerIssue("connectionError", error: error) }
        connection.invalidationHandler = interrupted
        connection.interruptionHandler = interrupted
        connection.remoteObjectInterface = NSXPCInterface(with: SpeechWorkerService.self)
        connection.resume()
        self.process = process
        self.connection = connection
        self.hostLease = owner
        // The helper's first answer is what iOS allows it, before any model work. A helper too
        // small for the model also deletes what it can never use before it answers.
        let (pid, footprint, left): (Int32, UInt64, UInt64) = try await waiting(for: "start") {
            try await withCheckedThrowingContinuation { reply in
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ reply.resume(throwing: $0) }) as? SpeechWorkerService
                else { return reply.resume(throwing: CocoaError(.xpcConnectionInvalid)) }
                proxy.limits { pid, footprint, left in reply.resume(returning: (pid, footprint, left)) }
            }
        }
        guard generation == token else { throw KeyboardWorkerIssue("connectionInterrupted") }
        workerPID = pid
        let limit = WorkerHealth.reportedLimit(footprint: footprint, left: left)
        measuredUsable = WorkerHealth.hasRoom(limitBytes: limit)
        helperLimitMB = limit.map { Int($0 / 1_048_576) }
        KeyboardLog.journal?.log("keyboardWorkerConnected", recording: recording, [
            "pid": String(pid), "helperMB": MemoryFootprint.megabytes(footprint),
            "helperLimitMB": helperLimitMB.map(String.init) ?? "none"])
        startMs = Int(Date().timeIntervalSince(start) * 1000)
        guard purpose == .dictation, !WorkerHealth.hasRoom(limitBytes: limit) else { return }
        let block = WorkerHealth.remember(.tooLittleRoom, stage: "start", limitMB: helperLimitMB)
        var fields = block.fields
        fields["decision"] = "skipHelper"
        fields["neededMB"] = String(WorkerHealth.neededMB)
        KeyboardLog.journal?.log("keyboardModelDecision", recording: recording, fields)
        KeyboardLog.journal?.flush()
        throw KeyboardWorkerIssue("helperTooSmall", block: block)
    }

    private var recordingUses = Set<UUID>()

    func recordingBegan(_ id: UUID) {
        hidden = false
        // A helper iOS ends is not started again: no wait at Stop, nothing left on disk.
        guard blocked == nil, recordingUses.insert(id).inserted else { return }
        beginUse()
        _ = prepare(id)
    }

    func prepareOnAppearance() {
        guard !attemptedAppearance, SharedMiniModel.verified else { return }
        attemptedAppearance = true
        _ = prepare(UUID(), ahead: true)
    }

    private func prepare(_ id: UUID, ahead: Bool = false) -> Task<Void, Error> {
        if let preparation { return preparation }
        if prepared { return Task {} }
        let token = UUID()
        preparationToken = token
        beginUse() // Kept until the actual worker reply, independent of any dictation deadline.
        let task = Task<Void, Error> {
            defer {
                if preparationToken == token { preparation = nil }
                endUse()
            }
            do {
                try requireModel()
                try await connect(recording: ahead ? nil : id)
                guard let connection else { throw KeyboardWorkerIssue("connectionError") }
                decision(ahead ? "warmAhead" : "warm", id: id)
                // From here the helper may write a preparation it does not finish.
                WorkerStorage.markDirty()
                try await waiting(for: "warm") {
                    try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
                        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ reply.resume(throwing: $0) }) as? SpeechWorkerService
                        else { return reply.resume(throwing: CocoaError(.xpcConnectionInvalid)) }
                        proxy.warm(id.uuidString) { error in
                            if let error { reply.resume(throwing: error) } else { reply.resume() }
                        }
                    }
                }
                guard preparationToken == token else { throw KeyboardWorkerIssue("connectionInterrupted") }
                prepared = true
                decision("warmReady", id: id)
            } catch {
                let issue = KeyboardWorkerIssue.describe(error)
                // The helper refused by itself: remember it like the host's own check.
                if issue.reason == "helperTooSmall", blocked == nil {
                    WorkerHealth.remember(.tooLittleRoom, stage: "warm", limitMB: helperLimitMB)
                }
                decision("warmFailed", id: id, issue: issue)
                throw error
            }
        }
        preparation = task
        return task
    }

    func recordingFinished(_ id: UUID) {
        if recordingUses.remove(id) != nil { endUse() }
    }

    private func send(_ id: UUID, recording: UUID, submitted: @escaping @Sendable () -> Void) async throws -> WorkerTranscript {
        try await connect(recording: recording)
        guard let connection else { throw CocoaError(.xpcConnectionInvalid) }
        try Task.checkCancellation()
        WorkerStorage.markDirty()
        let data: Data = try await waiting(for: "recognize") {
            try await withCheckedThrowingContinuation { continuation in
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ continuation.resume(throwing: $0) }) as? SpeechWorkerService else {
                    continuation.resume(throwing: CocoaError(.xpcConnectionInvalid))
                    return
                }
                submitted()
                proxy.recognize(id.uuidString, recording: recording.uuidString) { data, error in
                    if let data { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: error ?? WorkerDiagnostic.error(CocoaError(.coderValueNotFound))) }
                }
            }
        }
        do { return try JSONDecoder().decode(WorkerTranscript.self, from: data) }
        catch { throw KeyboardWorkerIssue("invalidReply", error: error) }
    }

    /// The lab's measurement inside the helper. The helper is expected to be ended by iOS part
    /// way: its own recording log then holds the last stage it began.
    func labProbe(units: MiniMemoryProbeUnits, windows: Int, recording: UUID) async -> [String: String] {
        labRunning = true
        beginUse()
        defer { endUse(); labRunning = false }
        do {
            try await connect(recording: nil, purpose: .lab)
            guard let connection else { throw CocoaError(.xpcConnectionInvalid) }
            WorkerStorage.markDirty()
            var fields = ["helperLimitMB": helperLimitMB.map(String.init) ?? "none", "pid": workerPID.map(String.init) ?? "unknown"]
            let data: Data = try await waiting(for: "lab") {
                try await withCheckedThrowingContinuation { continuation in
                    guard let proxy = connection.remoteObjectProxyWithErrorHandler({ continuation.resume(throwing: $0) }) as? SpeechWorkerService else {
                        return continuation.resume(throwing: CocoaError(.xpcConnectionInvalid))
                    }
                    proxy.probe(units.rawValue, windows: windows, recording: recording.uuidString) { data, error in
                        if let data { continuation.resume(returning: data) }
                        else { continuation.resume(throwing: error ?? WorkerDiagnostic.error(CocoaError(.coderValueNotFound))) }
                    }
                }
            }
            fields.merge((try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]) { _, result in result }
            return fields
        } catch {
            return ["outcome": "helperEnded", "helperLimitMB": helperLimitMB.map(String.init) ?? "none",
                    "code": KeyboardWorkerIssue.describe(error).reason]
        }
    }

    func recognize(url: URL, id requestID: UUID, limit: Double, submitted: @escaping @Sendable () -> Void = {}) async throws -> LocalSpeech.Heard {
        hidden = false
        // Known not to work on this build: say so and return at once, so the fallback starts
        // with no wait and no helper is started.
        if let blocked {
            let issue = KeyboardWorkerIssue("helperSkipped", block: blocked)
            decision("skipHelper", id: requestID, issue: issue)
            throw issue
        }
        beginUse()
        defer { endUse() }
        let id = UUID()
        try requireModel()
        guard let staged = SharedMiniModel.recording(id) else { throw KeyboardWorkerIssue("groupUnavailable") }
        decision("tryWorker", id: requestID)
        let warming = prepare(requestID)
        do {
            try await Watchdog.run(what: "Waiting for Mini preparation", limit: min(8, limit / 3)) {
                try await warming.value
            }
        } catch let stalled as Watchdog.Stalled where stalled.what == "Waiting for Mini preparation" {
            throw KeyboardWorkerIssue("preparationContinues", error: stalled)
        }
        try Task.checkCancellation()
        let fm = FileManager.default
        try fm.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = staged.deletingPathExtension().appendingPathExtension("part")
        defer { try? fm.removeItem(at: temporary) }
        try fm.copyItem(at: url, to: temporary)
        guard let owner = KeyboardAudioFile.lock(temporary) else { throw CocoaError(.fileLocking) }
        defer { try? owner.close() }
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: temporary.path)
        try fm.moveItem(at: temporary, to: staged)
        defer { try? fm.removeItem(at: staged) }
        do {
            let result: WorkerTranscript = try await Watchdog.run(what: "Zone speech worker", limit: limit * 0.6) {
                try await self.send(id, recording: requestID, submitted: submitted)
            }
            var fields = result.fields
            fields["workerStartMs"] = String(startMs)
            fields["workerReason"] = "used"
            decision("used", id: requestID)
            return .init(text: result.text, module: "zoneMini", doubts: result.doubts, fields: fields)
        } catch {
            (connection?.remoteObjectProxyWithErrorHandler { _ in } as? SpeechWorkerService)?.cancel(id.uuidString)
            throw error
        }
    }
}
