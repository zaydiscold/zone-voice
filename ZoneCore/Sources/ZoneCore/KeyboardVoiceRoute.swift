// by zayd/cold @ zayd.wtf
import Foundation

/// Read at the start of each keyboard dictation. The absent configuration always means local.
public struct KeyboardVoiceRoute: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case standard, webView, computer
    }
    public var mode: Mode = .standard
    public var endpoint = "" {
        didSet {
            if Self.origin(of: oldValue) != Self.origin(of: endpoint) { token = "" }
        }
    }

    private struct Origin: Equatable {
        let host: String
        let port: Int
    }

    private static func origin(of endpoint: String) -> Origin? {
        guard let url = URLComponents(string: endpoint), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return Origin(host: host, port: url.port ?? 443)
    }
    public var model = ""
    public var token = ""
    public init() {}

    public var providerURL: URL? {
        guard let parts = URLComponents(string: endpoint), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ![model, token].contains(where: { $0.rangeOfCharacter(from: .controlCharacters) != nil }) else { return nil }
        return parts.url
    }

    /// Recovery has no proof that an earlier recording was authorized for this endpoint.
    public func forRecording(startedWith original: Self?, retrying: Bool) -> Self {
        if mode == .computer && (retrying || original != self) { return .init() }
        return self
    }

    #if os(iOS)
    public static var group: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ZoneContract.appGroup)
    }
    // Restore protection once per process for configurations copied by developer tools.
    // Changing only metadata preserves a concurrent selection made in the app.
    private static let protectRestoredSettings: Void = {
        guard var directory = group?.appendingPathComponent("Library/Application Support/KeyboardVoice", isDirectory: true) else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete],
                                               ofItemAtPath: directory.appendingPathComponent("route.json").path)
    }()

    public static func load() -> Self {
        guard let url = group?.appendingPathComponent("Library/Application Support/KeyboardVoice/route.json") else { return .init() }
        _ = protectRestoredSettings
        guard let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return saved
    }
    public func save() throws {
        guard let group = Self.group else { throw CocoaError(.fileNoSuchFile) }
        if mode == .computer && providerURL == nil { throw URLError(.badURL) }
        var dir = group.appendingPathComponent("Library/Application Support/KeyboardVoice", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        var flags = URLResourceValues()
        flags.isExcludedFromBackup = true
        try dir.setResourceValues(flags)
        try JSONEncoder().encode(self).write(to: dir.appendingPathComponent("route.json"), options: [.atomic, .completeFileProtection])
    }
    #endif
}
