// by zayd/cold @ zayd.wtf

import Foundation

/// What Zone remembers for Apple's rating prompt: when it first ran with this record, how many
/// recordings have ended well, and the version it last asked in. One JSON record, replaced
/// whole, like the shared store's.
public struct ReviewPromptState: Codable, Equatable, Sendable {
    /// The first launch that kept this record. Older installs start counting from the update.
    public var firstSeenAt: Date?
    /// Dictations, notes and meetings that finished with words and no error, from any surface
    /// (the keyboard's dictations are recognized in the app, so they count here too).
    public var successes: Int
    /// The marketing version Zone last asked in. Zone asks at most once per version; iOS itself
    /// shows the prompt at most three times a year and may show nothing.
    public var lastAskedVersion: String?

    public init(firstSeenAt: Date? = nil, successes: Int = 0, lastAskedVersion: String? = nil) {
        self.firstSeenAt = firstSeenAt
        self.successes = successes
        self.lastAskedVersion = lastAskedVersion
    }
}

/// When to ask for a rating. Apple's prompt only, never a "do you like Zone?" screen first
/// (App Review Guideline 5.6.1), and only right after something worked.
public enum ReviewPromptPolicy {
    /// Recordings that ended well before the first ask.
    public static let minimumSuccesses = 3
    /// Two days of use before the first ask, so a first afternoon's test run never gets it.
    public static let minimumAge: TimeInterval = 2 * 86_400

    /// True when this moment of success may ask. The caller has just finished a recording well;
    /// this decides whether the history around it qualifies.
    /// - Parameters:
    ///   - isRecording: a dictation, note or meeting is recording or recognizing right now.
    ///   - showsError: an error or warning is on screen.
    public static func shouldAsk(_ state: ReviewPromptState, now: Date, appVersion: String,
                                 isRecording: Bool, showsError: Bool) -> Bool {
        guard !isRecording, !showsError else { return false }
        guard state.successes >= minimumSuccesses else { return false }
        // A clock set backwards reads as too soon, never as old enough.
        guard let first = state.firstSeenAt, now.timeIntervalSince(first) >= minimumAge else { return false }
        let version = appVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty, state.lastAskedVersion != version else { return false }
        return true
    }
}

/// The rating prompt's record in a `UserDefaults` suite, the App Group's in the app.
public final class ReviewPromptStore {
    static let key = "zone.reviewPrompt"
    private let defaults: UserDefaults

    /// - Parameter suiteName: the App Group identifier, or any suite name in tests.
    public init(suiteName: String = ZoneContract.appGroup) {
        // `UserDefaults(suiteName:)` only returns nil for the standard bundle identifier.
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    public var state: ReviewPromptState {
        get {
            guard let data = defaults.data(forKey: Self.key),
                  let state = try? Self.decoder.decode(ReviewPromptState.self, from: data) else { return ReviewPromptState() }
            return state
        }
        set {
            guard let data = try? Self.encoder.encode(newValue) else { return }
            defaults.set(data, forKey: Self.key)
        }
    }

    /// At launch: starts the two-day clock the first time, and never moves it after that.
    public func noteLaunch(now: Date = Date()) {
        var current = state
        guard current.firstSeenAt == nil else { return }
        current.firstSeenAt = now
        state = current
    }

    /// A recording ended well. Returns the updated record.
    @discardableResult
    public func recordSuccess(now: Date = Date()) -> ReviewPromptState {
        var current = state
        if current.firstSeenAt == nil { current.firstSeenAt = now }
        current.successes = current.successes == Int.max ? Int.max : current.successes + 1
        state = current
        return current
    }

    /// Zone handed the request to iOS in this version, whether or not iOS showed anything.
    public func markAsked(version: String) {
        var current = state
        current.lastAskedVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        state = current
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
