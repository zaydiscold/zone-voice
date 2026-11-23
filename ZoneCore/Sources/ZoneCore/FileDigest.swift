// by zayd/cold @ zayd.wtf

import CryptoKit
import Foundation

/// The hash a downloaded model file must match, as Hugging Face records it: the SHA-256 of
/// the content for files stored in Git LFS (every weight file), or the git blob SHA-1 for
/// small files kept in git itself (metadata, MIL text, vocabularies).
public enum FileDigest: Sendable, Equatable, Codable {
    case sha256(String)
    case gitBlob(String)

    /// Reads the file in 1 MB pieces, so a 233 MB encoder never sits in memory at once.
    public func matches(fileAt url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        switch self {
        case .sha256(let expected):
            var hasher = SHA256()
            try Self.stream(handle) { hasher.update(data: $0) }
            return Self.hex(hasher.finalize()) == expected.lowercased()
        case .gitBlob(let expected):
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            var hasher = Insecure.SHA1()
            hasher.update(data: Data("blob \(size)\u{0}".utf8))
            try Self.stream(handle) { hasher.update(data: $0) }
            return Self.hex(hasher.finalize()) == expected.lowercased()
        }
    }

    private static func stream(_ handle: FileHandle, _ body: (Data) -> Void) throws {
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            body(chunk)
        }
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
