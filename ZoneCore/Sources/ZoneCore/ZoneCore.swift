// by zayd/cold @ zayd.wtf

import Foundation

/// Shared, process-independent pieces of Zone: the keyboard/app contract and
/// every rule that can be unit-tested without a device.
public enum ZoneCore {
    /// Schema version of the cross-process contract. Bump when a stored shape changes.
    public static let version = "0.1.0"
}
