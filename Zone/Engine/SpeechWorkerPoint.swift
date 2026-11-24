import ExtensionFoundation

@available(iOS 26.0, *)
enum SpeechWorkerPoint: ExtensionPointDefining {
    @AppExtensionPoint.Definition
    static var worker: AppExtensionPoint {
        AppExtensionPoint.Name("speechworker")
        AppExtensionPoint.Scope(restriction: .application)
        AppExtensionPoint.UserInterface(false)
    }
}

import Foundation
import ZoneCore

/// The app's side of the keyboard's speech helper: its storage, and the rule that it is never
/// asked to prepare Zone's speech model where iOS would end it for that.
enum WorkerCacheClient {
    static func clear() async {
        WorkerStorage.requestRemoval()
        DarwinNotifier.post(.workerCacheRemoval)
        await contact(clear: true)
    }

    @MainActor private static var scheduled = false

    /// At every launch, and whenever the model is confirmed in the App Group. Cheap when there
    /// is nothing to do: with the helper already written off for this build and its cache
    /// known to be clean, the helper is not started at all.
    @MainActor static func modelShared() {
        guard !scheduled else { return }
        let wantsKeyboardDictation = UserDefaults.standard.object(forKey: "zone.settings.dictatesInKeyboard") as? Bool ?? true
        let prepare = wantsKeyboardDictation && WorkerHealth.block() == nil
            && SharedMiniModel.verified && !WorkerStorage.preparedForCurrentSystem
        guard prepare || WorkerStorage.needsTidy() else { return }
        scheduled = true
        Task.detached(priority: .utility) {
            await contact(clear: false, prepare: prepare)
            await MainActor.run { scheduled = false }
        }
    }

    static func contact(clear: Bool, prepare: Bool = false) async {
        guard #available(iOS 26, *) else { return }
        let id = UUID()
        var waitingForWarm = false
        do {
            guard let lease = try WorkerStorage.hostLease() else { return }
            defer { try? lease.close() }
            let process = try await Watchdog.run(what: "Opening the model helper", limit: 10) {
                let monitor = try await AppExtensionPoint.Monitor(appExtensionPoint: SpeechWorkerPoint.worker)
                guard let identity = monitor.identities.first(where: { $0.bundleIdentifier == (Bundle.main.bundleIdentifier ?? "") + ".recognition" })
                else { throw CocoaError(.fileNoSuchFile) }
                return try await AppExtensionProcess(configuration: .init(appExtensionIdentity: identity))
            }
            defer { process.invalidate() }
            let connection = try process.makeXPCConnection()
            connection.remoteObjectInterface = NSXPCInterface(with: SpeechWorkerService.self)
            connection.resume()
            defer { connection.invalidate() }
            // First: what iOS allows the helper. A helper too small for the model deletes what
            // it can never use before it answers, so this one call is also the cleanup.
            let before = WorkerStorage.bytes
            let (pid, footprint, left): (Int32, UInt64, UInt64) = try await Watchdog.run(what: "Asking the model helper", limit: 10) {
                try await withCheckedThrowingContinuation { done in
                    guard let service = connection.remoteObjectProxyWithErrorHandler({ done.resume(throwing: $0) }) as? SpeechWorkerService
                    else { return done.resume(throwing: CocoaError(.xpcConnectionInvalid)) }
                    service.limits { pid, footprint, left in done.resume(returning: (pid, footprint, left)) }
                }
            }
            let limit = WorkerHealth.reportedLimit(footprint: footprint, left: left)
            let hasRoom = WorkerHealth.hasRoom(limitBytes: limit)
            var fields = ["pid": String(pid), "helperMB": MemoryFootprint.megabytes(footprint),
                          "helperLimitMB": limit.map(MemoryFootprint.megabytes) ?? "none", "hasRoom": String(hasRoom),
                          "bytesBefore": String(before), "bytesLeft": String(WorkerStorage.bytes)]
            if !hasRoom, WorkerHealth.block() == nil {
                fields.merge(WorkerHealth.remember(.tooLittleRoom, stage: "start", limitMB: limit.map { Int($0 / 1_048_576) }).fields) { _, block in block }
            }
            Journal.log("appHelperLimits", recording: id, fields)
            if !clear && !hasRoom { return }
            if prepare && hasRoom && WorkerHealth.block() == nil && SharedMiniModel.verified && !WorkerStorage.preparedForCurrentSystem {
                Journal.log("appWorkerPreparation", recording: id)
                WorkerStorage.markDirty()
                waitingForWarm = true
                // A foreground preparation can outlast a keyboard request. Hold ownership until its reply.
                try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                    guard let service = connection.remoteObjectProxyWithErrorHandler({ done.resume(throwing: $0) }) as? SpeechWorkerService
                    else { return done.resume(throwing: CocoaError(.xpcConnectionInvalid)) }
                    service.warm(id.uuidString) { error in
                        if let error { done.resume(throwing: error) } else { done.resume() }
                    }
                }
                return
            }
            try await Watchdog.run(what: "Keyboard model storage", limit: 10) {
                try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                    guard let service = connection.remoteObjectProxyWithErrorHandler({ done.resume(throwing: $0) }) as? SpeechWorkerService
                    else { return done.resume(throwing: CocoaError(.xpcConnectionInvalid)) }
                    if clear {
                        service.clearCache { removed in
                            if removed { WorkerStorage.bytes = 0; WorkerStorage.strandedBytes = 0 }
                            done.resume()
                        }
                    } else {
                        service.cacheSize { bytes in WorkerStorage.bytes = bytes; done.resume() }
                    }
                }
            }
        } catch {
            let failure = error as NSError
            if waitingForWarm, MemoryFootprint.available() != nil, failure.domain == NSCocoaErrorDomain,
               [NSXPCConnectionInterrupted, NSXPCConnectionInvalid].contains(failure.code) {
                WorkerHealth.remember(.ended, stage: "warm")
            }
            Journal.log("appWorkerContactError", recording: id, ["code": JournalFormat.error(error)])
        }
    }
}
