// by zayd/cold @ zayd.wtf

import CryptoKit
import Foundation

/// What `zone pair` shows as a QR code:
/// `zone://pair?v=1&n=<endpoint id>&s=<secret>&name=<computer name>&r=<relay url>`.
///
/// A pairing link decides where the whole library goes, so parsing is strict: anything that is
/// not exactly the documented shape is refused, and the name is cleaned before it is shown.
public struct LinkPairingLink: Equatable, Sendable {
    /// The computer's iroh endpoint id: 64 lowercase hex characters (iroh's text form), or the
    /// 52-character base32 form iroh also reads.
    public let endpointID: String
    /// 32 random bytes as 64 lowercase hex characters. Confirmed once per phone. Older links carry no expiry.
    public let secret: String
    /// The computer's name, for the confirmation and the list. Never empty.
    public let name: String
    /// Set when the computer is pinned to one relay.
    public let relay: String?
    public let expiresAt: Date?

    public enum Failure: Error, Equatable {
        case notAPairingLink
        case unsupportedVersion
        case badEndpoint
        case badSecret
        case badRelay
    }

    public static let maxLength = 2048
    public static let maxNameLength = 60

    public init(endpointID: String, secret: String, name: String, relay: String? = nil, expiresAt: Date? = nil) {
        self.endpointID = endpointID
        self.secret = secret
        self.name = name
        self.relay = relay
        self.expiresAt = expiresAt
    }

    /// True for any `zone://pair` URL, valid or not, so the app can say why a bad one failed
    /// instead of handing it to the dictation URL handler.
    public static func isPairingURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "zone" && url.host?.lowercased() == "pair"
    }

    public static func parse(_ text: String) throws -> LinkPairingLink {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maxLength,
              let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "zone", components.host?.lowercased() == "pair",
              let items = components.queryItems else { throw Failure.notAPairingLink }

        func value(_ name: String) throws -> String? {
            let matches = items.filter { $0.name == name }
            // The same field twice is two answers to one question.
            guard matches.count <= 1 else { throw Failure.notAPairingLink }
            return matches.first?.value
        }

        guard let version = try value("v") else { throw Failure.notAPairingLink }
        guard version == "1" else { throw Failure.unsupportedVersion }
        guard let endpoint = try value("n"), let endpointID = normalizedEndpointID(endpoint) else { throw Failure.badEndpoint }
        guard let secret = try value("s"), isSecret(secret) else { throw Failure.badSecret }
        var relay: String?
        if let raw = try value("r"), !raw.isEmpty {
            guard raw.utf8.count <= 512, let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http", url.host?.isEmpty == false else { throw Failure.badRelay }
            relay = raw
        }
        var expiresAt: Date?
        if items.contains(where: { $0.name == "exp" }) {
            guard let raw = try value("exp"), !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }),
                  let seconds = Int64(raw), seconds <= 253402300799 else { throw Failure.notAPairingLink }
            expiresAt = Date(timeIntervalSince1970: TimeInterval(seconds))
        }
        return LinkPairingLink(endpointID: endpointID, secret: secret, name: cleanedName(try value("name")), relay: relay, expiresAt: expiresAt)
    }

    public static func parse(_ url: URL) throws -> LinkPairingLink {
        try parse(url.absoluteString)
    }

    /// 64 hex characters (returned lowercase), or 52 characters of lowercase base32.
    static func normalizedEndpointID(_ text: String) -> String? {
        let hex = Set("0123456789abcdef")
        let base32 = Set("abcdefghijklmnopqrstuvwxyz234567")
        let lowered = text.lowercased()
        if lowered.count == 64, lowered.allSatisfy(hex.contains) { return lowered }
        if text.count == 52, text.allSatisfy(base32.contains) { return text }
        return nil
    }

    static func isSecret(_ text: String) -> Bool {
        let hex = Set("0123456789abcdef")
        return text.count == 64 && text.allSatisfy(hex.contains)
    }

    /// One line, no control characters, at most 60 characters: the name is shown in the question
    /// "Send your Zone library to ...?", and a link from a stranger must not be able to rewrite
    /// that question with line breaks or a wall of text.
    static func cleanedName(_ raw: String?) -> String {
        let scalars = (raw ?? "").unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) ? " " : Character(scalar)
        }
        let collapsed = String(scalars).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let name = String(collapsed.prefix(maxNameLength))
        return name.isEmpty ? "Unnamed computer" : name
    }

    /// The pairing secret as bytes.
    public var secretBytes: Data {
        var bytes = Data(capacity: 32)
        var index = secret.startIndex
        while index < secret.endIndex {
            let next = secret.index(index, offsetBy: 2)
            bytes.append(UInt8(secret[index..<next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }

    /// The key that seals a Flash (carrier 2), derived by both sides at pairing and kept:
    /// HKDF-SHA256 over the pairing secret, empty salt, info "zone-flash/1", 32 bytes.
    public var flashKey: Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secretBytes), salt: Data(),
                                         info: Data("zone-flash/1".utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }
}
