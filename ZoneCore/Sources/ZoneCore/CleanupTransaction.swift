// by zayd/cold @ zayd.wtf

import Foundation

public enum CleanupTransaction {
    /// Recognition, history, and notes do not participate in this transaction. Its only output
    /// is a verified, recoverable candidate; any error leaves the caller free to use raw text.
    public static func run(original: String, id: UUID = UUID(), archive: CleanupArchive,
                           transform: @Sendable (String) async throws -> String) async throws -> String {
        try Task.checkCancellation()
        var entry = CleanupArchive.Entry(id: id, original: original)
        try archive.save(entry)
        let result = try await transform(original)
        try Task.checkCancellation()
        guard CleanupPolicy.isSafe(original: original, candidate: result) else { throw Failure.changedWords }
        entry.cleaned = result
        try archive.save(entry)
        return result
    }

    public enum Failure: Error { case changedWords }
}
