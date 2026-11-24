// by zayd/cold @ zayd.wtf

import Foundation

/// The current handoff, its last admitted recording ID, and its insertion receipt share one
/// atomic write. A completion never changes ownership to a different recording.
struct DictationMailbox {
    struct Record: Codable, Equatable {
        var owner: UUID?
        var admittedAt: Date?
        var withdrawnID: UUID?
        var appGenerationAtTransfer: Int?
        var request: DictationRequest?
        var status: DictationStatus?
        var result: DictationResult?
        var ledger = InsertionLedger()

        mutating func admit(_ next: DictationRequest?) -> Bool {
            if let next {
                guard withdrawnID != next.id else { return false }
                if next.id == owner {
                    guard let current = request, next.generation >= current.generation else { return false }
                } else {
                    // Generation numbers are local to each keyboard controller. The tap's
                    // creation date survives a delayed writer and still orders different IDs.
                    if let latest = admittedAt ?? request?.tappedAt, next.tappedAt <= latest { return false }
                    owner = next.id
                    admittedAt = next.tappedAt
                    withdrawnID = nil
                    appGenerationAtTransfer = nil
                    status = nil
                    result = nil
                }
            }
            request = next
            return true
        }

        mutating func publish(_ final: DictationResult, for original: DictationRequest) -> Bool {
            guard withdrawnID != original.id, original.id == final.requestID, original.generation == final.generation,
                  owner == original.id || (owner == nil && admittedAt.map { original.tappedAt > $0 } != false),
                  request.map({ $0.generation <= final.generation }) ?? true,
                  ledger.consumedResultID != original.id, final.generation > ledger.droppedGeneration else { return false }
            owner = original.id
            admittedAt = original.tappedAt
            request = original
            result = final
            return true
        }

        mutating func clearPayloads(for id: UUID) {
            if result?.requestID == id { result = nil }
            if request?.id == id { request = request?.withoutContext() }
        }

        mutating func claim(_ offered: DictationResult, explicit: Bool, now: Date) -> Bool {
            guard owner == offered.requestID, withdrawnID != owner else { return false }
            return ledger.claim(offered, current: result, explicit: explicit, now: now)
        }
    }

    let file: URL?
    let legacy: () -> Record
    let removeLegacy: () -> Void

    /// Atomic replacement lets readers see a complete snapshot. Only writers need coordination.
    private func read(at url: URL) throws -> Record {
        do { return try JSONDecoder().decode(Record.self, from: Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return legacy() }
    }

    var snapshot: Record {
        guard let file else { return legacy() }
        return (try? read(at: file)) ?? Record()
    }

    @discardableResult
    func update(_ change: (inout Record) -> Bool) -> Bool {
        guard let file else { return false }
        do {
            var directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #if os(iOS)
            if try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup != true {
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try directory.setResourceValues(values)
            }
            #endif
        } catch { return false }
        var coordinationError: NSError?
        var committed = false
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forMerging, error: &coordinationError) { url in
            do {
                var record = try read(at: url)
                guard change(&record) else { return }
                let data = try JSONEncoder().encode(record)
                #if os(iOS)
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                #else
                try data.write(to: url, options: .atomic)
                #endif
                removeLegacy()
                committed = true
            } catch { return }
        }
        return coordinationError == nil && committed
    }
}
