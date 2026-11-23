// by zayd/cold @ zayd.wtf

import Foundation

/// Free-space checks before a download or a long recording, so a full phone says so up front
/// instead of failing halfway (failure map L10, L11). The manifest already declares the
/// DiskSpace reason E174.1 for this.
enum DiskSpace {
    struct NotEnough: LocalizedError {
        let what: String
        let needed: Int64
        let available: Int64
        var errorDescription: String? {
            "There isn't enough space on this iPhone for \(what): it needs \(needed.byteCountLabel) free and "
                + "\(available.byteCountLabel) is. Free up some space, then try again."
        }
    }

    /// Bytes the system will make available for something the person asked for, or nil when
    /// the volume cannot say (then nothing is refused).
    static func available() -> Int64? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Throws unless `bytes` plus a margin (the larger of 50 MB and a fifth of the download) fit.
    static func ensureRoom(for bytes: Int64, what: String) throws {
        guard bytes > 0, let available = available() else { return }
        let needed = bytes + max(50_000_000, bytes / 5)
        if available < needed { throw NotEnough(what: what, needed: needed, available: available) }
    }
}
