// by zayd/cold @ zayd.wtf

import Foundation

/// Removes its own handler when cancelled or deallocated; other observers of the same name
/// are untouched.
public final class DarwinObservation {
    private var name: DarwinName?
    private let token: UUID

    fileprivate init(name: DarwinName, token: UUID) {
        self.name = name
        self.token = token
    }

    deinit {
        cancel()
    }

    public func cancel() {
        guard let name else { return }
        self.name = nil
        DarwinNotifier.remove(name, token: token)
    }
}

/// Posts and observes Darwin notifications between the app and the keyboard.
///
/// The CoreFoundation callback is a C function pointer and cannot capture Swift state, so
/// handlers live in a lock-protected registry keyed by the full notification name, with one
/// token per observation so a dying observer never removes a live one.
public enum DarwinNotifier {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: [UUID: @MainActor () -> Void]] = [:]

    private static let callback: CFNotificationCallback = { _, _, cfName, _, _ in
        guard let cfName else { return }
        let key = cfName.rawValue as String
        lock.lock()
        let current = handlers[key].map { Array($0.values) } ?? []
        lock.unlock()
        guard !current.isEmpty else { return }
        // The Darwin center delivers on the main run loop already; an extra async hop costs
        // seconds in a backgrounded app whose main queue iOS throttles.
        if Thread.isMainThread {
            MainActor.assumeIsolated { current.forEach { $0() } }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { current.forEach { $0() } }
            }
        }
    }

    public static func post(_ name: DarwinName) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name.cfName),
            nil, nil, true)
    }

    /// Registers `handler` for `name`. Handlers run on the main thread.
    public static func observe(_ name: DarwinName, handler: @escaping @MainActor () -> Void) -> DarwinObservation {
        let key = name.cfName as String
        let token = UUID()
        lock.lock()
        let first = (handlers[key]?.isEmpty ?? true)
        handlers[key, default: [:]][token] = handler
        lock.unlock()
        if first {
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                nil,
                callback,
                name.cfName,
                nil,
                .deliverImmediately)
        }
        return DarwinObservation(name: name, token: token)
    }

    fileprivate static func remove(_ name: DarwinName, token: UUID) {
        let key = name.cfName as String
        lock.lock()
        handlers[key]?.removeValue(forKey: token)
        let last = handlers[key]?.isEmpty ?? true
        if last { handlers.removeValue(forKey: key) }
        lock.unlock()
        if last {
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                nil,
                CFNotificationName(name.cfName),
                nil)
        }
    }
}
