// by zayd/cold @ zayd.wtf

import Foundation
import ZoneCore

/// Cleanup, an on-device rewrite with the Fluid-1-Pico model, was taken out in 1.0.6: few people
/// used it, and it did not work for testers who tried it. What it left on the phone is handled here.
///
/// - The model (about 372 MB, plus any half-finished download) is deleted at launch. It was only
///   ever a download, so nothing of the person's is lost.
/// - The saved cleanups (each original and its cleaned text, in `CleanupHistory`) are the person's
///   words, so they are not deleted by themselves. Your data's deletes still take them.
/// - The automatic-cleanup setting is removed, so a dictation is never rewritten.
enum RetiredCleanup {
    static let automaticKey = "zone.cleanup.automatic"

    static var archive: CleanupArchive {
        CleanupArchive(directory: applicationSupport.appendingPathComponent("CleanupHistory", isDirectory: true))
    }

    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Idempotent and cheap: one existence check when there is nothing left. A failed delete is
    /// retried on the next launch.
    static func sweep(in support: URL = applicationSupport, defaults: UserDefaults = .standard,
                      canReadProtectedData: () -> Bool = { ProtectedDataProbe.standard.isAvailable() }) {
        guard canReadProtectedData() else { return }
        let fileManager = FileManager.default
        defaults.removeObject(forKey: automaticKey)
        let model = support.appendingPathComponent("Cleanup", isDirectory: true)
        guard fileManager.fileExists(atPath: model.path) else { return }
        do {
            try fileManager.removeItem(at: model)
            Journal.log("retiredCleanupModelDeleted")
        } catch {
            Journal.log("retiredCleanupModelDeleteFailed", ["error": JournalFormat.error(error)])
        }
    }
}
