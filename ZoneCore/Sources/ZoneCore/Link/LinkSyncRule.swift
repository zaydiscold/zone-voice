// by zayd/cold @ zayd.wtf

import Foundation

/// Why a sync with a computer runs. A stronger reason replaces a weaker one that is still waiting.
public enum LinkSyncReason: Int, Comparable, Sendable {
    /// Something in the library changed. Skipped without connecting when nothing is pending.
    case changed
    /// Zone came to the foreground, or the person turned sending back on.
    case foreground
    /// The person sent a clip: at once, with no waiting.
    case clip
    /// Sync now, or Send everything again.
    case manual
    /// The first sync after pairing: carries the pairing secret and reports back.
    case paired

    public static func < (a: LinkSyncReason, b: LinkSyncReason) -> Bool { a.rawValue < b.rawValue }
}

/// Which computers a sync may reach.
///
/// - A computer the person turned off gets nothing over the network, for any reason, Sync now
///   included. Pairing it again turns it back on first, so `paired` never meets a paused one.
/// - A computer that refused this phone (`needsPairing`) is not tried on its own; the person
///   can still try it with Sync now.
///
/// Flash is not a sync and is not governed here: it is something the person starts, so it
/// stays available while a computer is turned off.
extension PairedComputer {
    public func allowsSync(_ reason: LinkSyncReason) -> Bool {
        guard !isPaused else { return false }
        switch reason {
        case .changed, .foreground: return !needsPairing
        // Sending a clip is the person asking, like Sync now.
        case .clip, .manual, .paired: return true
        }
    }

    /// True when a change in the library, or Zone coming forward, would sync with this computer.
    public var syncsAutomatically: Bool { allowsSync(.changed) }
}

extension Array where Element == PairedComputer {
    /// The names of the computers that keep their copy of what the person deletes on the phone
    /// (`LinkCopy` says so wherever a delete is confirmed).
    public var keepingNames: [String] { filter(\.keepsDeleted).map(\.name) }

    /// The endpoint ids a sync for this reason goes to, in pairing order.
    public func due(for reason: LinkSyncReason) -> [String] {
        filter { $0.allowsSync(reason) }.map(\.endpointID)
    }
}
