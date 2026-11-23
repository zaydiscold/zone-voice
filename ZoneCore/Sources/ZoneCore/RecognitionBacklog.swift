// by zayd/cold @ zayd.wtf

import Foundation

public enum RecognitionFailure: LocalizedError, Equatable, Sendable {
    case overloaded
    case recognizer(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .overloaded: return "Speech recognition could not keep up. Recording stopped; any recognized text is saved in History."
        case .recognizer: return "Speech recognition stopped. Any recognized text is saved in History."
        case .cancelled: return "Dictation cancelled."
        }
    }
}

/// Limits audio waiting on inference, not the duration of a recording. Failure is sticky:
/// accepting later audio after dropping a chunk would produce a misleading complete transcript.
public final class RecognitionBacklog: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var pending = 0
    private var storedFailure: RecognitionFailure?

    public init(maxSamples: Int) { limit = max(1, maxSamples) }
    public var failure: RecognitionFailure? { lock.withLock { storedFailure } }
    public var pendingSamples: Int { lock.withLock { pending } }
    public var availableSamples: Int { lock.withLock { max(0, limit - pending) } }

    public func admit(_ count: Int) -> Bool {
        lock.withLock {
            guard storedFailure == nil else { return false }
            guard count >= 0, count <= limit - pending else {
                storedFailure = .overloaded
                return false
            }
            pending += count
            return true
        }
    }

    public func release(_ count: Int) { lock.withLock { pending = max(0, pending - max(0, count)) } }
    public func fail(_ error: Error) {
        lock.withLock {
            if storedFailure == nil {
                storedFailure = (error as? RecognitionFailure) ?? .recognizer(error.localizedDescription)
            }
        }
    }
    public func cancel() { lock.withLock { storedFailure = .cancelled } }
    public func check() throws { if let failure { throw failure } }
}
