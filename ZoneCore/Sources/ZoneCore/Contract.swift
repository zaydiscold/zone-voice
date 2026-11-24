// by zayd/cold @ zayd.wtf

import Foundation

/// Constants both processes must agree on. Change them in one place.
public enum ZoneContract {
    /// App Group shared by the app and the keyboard extension. Resolved per build (`AppGroup`), so
    /// Zone signed under any team still shares one container.
    public static var appGroup: String { AppGroup.identifier }
    /// URL scheme the keyboard uses to open the app for a cold-start dictation.
    public static let urlScheme = "zone"
    /// Bump when a stored shape changes incompatibly; readers refuse unknown schemas.
    public static let schemaVersion = 1
    /// Prefix for every Darwin notification name.
    /// Follows the App Group (`wtf.zayd.zone.` for the default build), so two copies of Zone on one phone,
    /// say a friend's own build beside a TestFlight one, never wake each other's processes.
    public static let darwinPrefix = String(appGroup.dropFirst("group.".count)) + "."

    private static let dictateHost = "dictate"
    private static let requestQuery = "request"

    /// `zone://dictate?request=<uuid>`: the app opens, arms the session and records for this request.
    public static func dictateURL(requestID: UUID) -> URL {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = dictateHost
        components.queryItems = [URLQueryItem(name: requestQuery, value: requestID.uuidString)]
        // Components built from constants always produce a URL.
        return components.url!
    }

    /// `zone://home`: just opens the app (the keyboard's wordmark uses it).
    public static var homeURL: URL { Destination.home.url }

    public enum Destination: String, Hashable, Sendable {
        case home, notes, settings

        public var url: URL { URL(string: "\(ZoneContract.urlScheme)://\(rawValue)")! }

        public init?(url: URL) {
            guard url.scheme == ZoneContract.urlScheme, let host = url.host else { return nil }
            self.init(rawValue: host)
        }
    }

    /// The request id carried by a dictate URL, or nil for any other URL.
    public static func requestID(from url: URL) -> UUID? {
        guard url.scheme?.lowercased() == urlScheme,
              url.host?.lowercased() == dictateHost,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let raw = items.first(where: { $0.name == requestQuery })?.value
        else { return nil }
        return UUID(uuidString: raw)
    }
}

/// Cross-process wake-up pings. They carry no payload; receivers read the store.
public enum DarwinName: String, CaseIterable, Sendable {
    /// Keyboard wrote a new `DictationRequest`.
    case requestChanged
    /// Keyboard wrote a `DictationControl` (stop or cancel).
    case controlChanged
    /// App wrote a `DictationStatus`.
    case statusChanged
    /// App wrote a `DictationResult`.
    case resultReady
    /// Keyboard inserted or dismissed a result; app clears its temporary text receipt.
    case payloadConsumed
    /// The app or keyboard committed a dictation stats receipt.
    case statsChanged
    /// App wrote a `SessionState` (armed, ended, model ready).
    case sessionChanged
    /// The keyboard came on screen. The app warms the speech model if it has sat idle, so a
    /// dictation started a moment later does not wait behind the warm-up.
    case keyboardShown
    /// Presence only. No field text crosses between processes.
    case queryEmojiStrip, emojiStripVisible, emojiStripHidden
    case quickSettingsPublished
    case quickSettingChanged
    /// Settings requested removal of the keyboard worker cache.
    case workerCacheRemoval
    #if DEBUG && targetEnvironment(simulator)
    case debugKeyboardInterrupt, debugKeyboardResume
    #endif

    public var cfName: CFString {
        (ZoneContract.darwinPrefix + rawValue) as CFString
    }
}
