import Foundation

final class RetryingResource<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: Value?
    private let read: () -> Value?

    init(_ read: @escaping () -> Value?) { self.read = read }

    func value() -> Value? {
        lock.withLock {
            if let cached { return cached }
            cached = read()
            return cached
        }
    }
}
