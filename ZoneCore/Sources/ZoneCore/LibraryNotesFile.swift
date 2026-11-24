// by zayd/cold @ zayd.wtf

import Foundation

/// Existing note bytes must decode before any write. A bad load is never an empty library.
public enum LibraryNotesFile {
    public static func read(at url: URL) throws -> [LibraryNote] {
        do { return try JSONDecoder().decode([LibraryNote].self, from: Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
    }

    public static func write(_ notes: [LibraryNote], to url: URL, replacing expected: [LibraryNote]? = nil,
                             beforeReplacing: (() throws -> Void)? = nil) throws {
        let data = try JSONEncoder().encode(notes)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { file in
            do {
                let current = try read(at: file)
                if let expected, current != expected { throw CocoaError(.fileWriteFileExists) }
                guard let beforeReplacing else { return try write(data, to: file) }
                // Prepare the replacement before mutating linked records. A conflict, an
                // unreadable library or a full disk must leave the original records intact.
                let manager = FileManager.default
                let staging = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                              appropriateFor: file, create: true)
                defer { try? manager.removeItem(at: staging) }
                let replacement = staging.appendingPathComponent(file.lastPathComponent)
                try write(data, to: replacement)
                try beforeReplacing()
                // Same-volume atomic rename. If it fails the canonical note still exists
                // and the same idempotent linked-record cleanup can be retried.
                guard rename(replacement.path, file.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            } catch { writeError = error }
        }
        if let error = writeError ?? coordinationError { throw error }
    }

    private static func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
}
