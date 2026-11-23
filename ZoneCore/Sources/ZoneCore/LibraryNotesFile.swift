// by zayd/cold @ zayd.wtf

import Foundation

/// Existing note bytes must decode before any write. A bad load is never an empty library.
public enum LibraryNotesFile {
    public static func read(at url: URL) throws -> [LibraryNote] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([LibraryNote].self, from: Data(contentsOf: url))
    }

    public static func write(_ notes: [LibraryNote], to url: URL) throws {
        _ = try read(at: url)
        let data = try JSONEncoder().encode(notes)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
}
