// by zayd/cold @ zayd.wtf

import Foundation

/// Holds back building a value until the files it reads can be read (`ProtectedDataProbe`).
/// Zone's whole app (settings, the dictation coordinator, What's New, the review clock) is
/// built through one, so a process iOS starts before the first unlock after a restart reads and
/// writes nothing until the person unlocks, then starts on their real settings.
@MainActor
public final class UnlockGate<Value> {
    /// The built value; nil while waiting for the first unlock.
    public private(set) var value: Value?
    /// When the gate first found the data locked, nil if it never waited.
    public let waitedSince: Date?
    private let isAvailable: () -> Bool
    private let build: () -> Value

    public init(now: Date = Date(), isAvailable: @escaping () -> Bool, build: @escaping () -> Value) {
        self.isAvailable = isAvailable
        self.build = build
        if isAvailable() {
            value = build()
            waitedSince = nil
        } else {
            waitedSince = now
        }
    }

    /// Something suggests the data may be readable now (the unlock notification, a wake):
    /// builds if the probe agrees. Never builds twice.
    @discardableResult
    public func check() -> Value? {
        if value == nil, isAvailable() { value = build() }
        return value
    }

    /// Zone is on screen or opening a link, so the phone is unlocked whatever the probe says.
    /// Builds now rather than leave the person looking at an empty app.
    public func force() -> Value {
        if let value { return value }
        let built = build()
        value = built
        return built
    }
}
