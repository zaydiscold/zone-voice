// by zayd/cold @ zayd.wtf

import Foundation
#if canImport(notify)
import notify
#endif

/// Durable state shared by the app and the keyboard. Each property is one record; writers
/// replace whole records so readers never see a half-updated shape.
public protocol SharedStore: AnyObject {
    var request: DictationRequest? { get set }
    var status: DictationStatus? { get set }
    var result: DictationResult? { get set }
    var control: DictationControl? { get set }
    var session: SessionState? { get set }
    var ledger: InsertionLedger { get set }
    var keyboardPresence: KeyboardPresence? { get set }
    /// Microphone level 0...1 while recording, written about eight times a second for the keyboard's waveform.
    var level: Float { get set }
    /// The keyboard's last style pick (see `TextStylePolicy`). Read the style in effect with
    /// `effectiveTextStyle()`, never this directly.
    var textStyle: TextStyle { get set }
    /// When the keyboard picked `textStyle`; nil once the app's setting is the newer choice.
    var textStylePickedAt: Date? { get set }
    /// The default style, chosen in the app.
    var defaultTextStyle: TextStyle { get set }
    /// Autocorrect and haptics switches, owned by the app, honored by the keyboard.
    var keyboardPreferences: KeyboardPreferences { get set }
    /// Dictations the keyboard has inserted, counted up to a small number: the strip teaches with a
    /// full-width "Tap to talk" until the user has done it a few times.
    var dictationsInserted: Int { get set }
    /// The keyboard's last face, type or dictate, chosen with the toggle key on the keyboard.
    var keyboardMode: KeyboardMode { get set }
}

/// Keys inside the App Group `UserDefaults` suite.
enum SharedStoreKey {
    static let request = "zone.request"
    static let status = "zone.status"
    static let result = "zone.result"
    static let control = "zone.control"
    static let session = "zone.session"
    static let ledger = "zone.ledger"
    static let keyboardPresence = "zone.keyboardPresence"
    static let level = "zone.level"
    static let textStyle = "zone.textStyle"
    static let keyboardPreferences = "zone.keyboardPreferences"
    /// New on 2026-11-19, when picks stopped lapsing after 15 minutes. A pick saved under the old
    /// `zone.textStyleActiveAt` had already lapsed for the user, so it must not come back.
    static let textStylePickedAt = "zone.textStylePickedAt"
    static let dictationsInserted = "zone.dictationsInserted"
    static let defaultTextStyle = "zone.defaultTextStyle"
    static let keyboardMode = "zone.keyboardMode"
}

/// App Group backed store. Values are JSON blobs so a schema bump cannot leave a reader
/// decoding half-matching keys; an undecodable blob reads as nil.
///
/// `session` is the exception to "every set is a write". Its heartbeat, refreshed every 3 s while
/// the microphone is kept ready and every second while recording, travels in a `SessionPulse`
/// (a notify state word, as the live level does in `LevelChannel`), and the defaults record is
/// rewritten only when something else in it changes or `sessionRecordRefresh` has passed. Readers
/// get the record with the newer of the two heartbeats. Each defaults write is a cfprefsd round
/// trip and a rewrite of the App Group's preferences file: 1,200 an hour in standby, 3,600 an hour
/// while recording, for a timestamp only the keyboard reads.
public final class UserDefaultsSharedStore: SharedStore {
    /// The longest the session record goes without a rewrite while nothing in it changes. A
    /// reader without the pulse still sees the app as alive within this.
    public static let sessionRecordRefresh: TimeInterval = 60

    private let defaults: UserDefaults
    private let pulse: SessionPulse
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// - Parameter suiteName: the App Group identifier, or any suite name in tests. The session
    ///   pulse is named after it, so a test suite never sees the app's heartbeat.
    public init(suiteName: String = ZoneContract.appGroup) {
        // `UserDefaults(suiteName:)` only returns nil for the standard bundle identifier.
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
        self.pulse = SessionPulse(name: suiteName + ".session-pulse")
    }

    public var request: DictationRequest? {
        get { read(SharedStoreKey.request) }
        set { write(newValue, SharedStoreKey.request) }
    }
    public var status: DictationStatus? {
        get { read(SharedStoreKey.status) }
        set { write(newValue, SharedStoreKey.status) }
    }
    public var result: DictationResult? {
        get { read(SharedStoreKey.result) }
        set { write(newValue, SharedStoreKey.result) }
    }
    public var control: DictationControl? {
        get { read(SharedStoreKey.control) }
        set { write(newValue, SharedStoreKey.control) }
    }
    public var session: SessionState? {
        get {
            guard var record: SessionState = read(SharedStoreKey.session) else { return nil }
            if let beat = pulse.last, beat > record.heartbeat { record.heartbeat = beat }
            return record
        }
        set {
            guard let newValue else { return write(nil as SessionState?, SharedStoreKey.session) }
            // The pulse first, so a reader that sees the new record also sees its heartbeat.
            let pulsed = pulse.beat(newValue.heartbeat)
            if pulsed, let stored: SessionState = read(SharedStoreKey.session),
               stored.matchesApartFromHeartbeat(newValue) {
                let age = newValue.heartbeat.timeIntervalSince(stored.heartbeat)
                // A heartbeat earlier than the record's means the clock moved back: rewrite, so a
                // reader without the pulse does not keep a future heartbeat.
                if age >= 0, age < Self.sessionRecordRefresh { return }
            }
            write(newValue, SharedStoreKey.session)
        }
    }
    public var ledger: InsertionLedger {
        get { read(SharedStoreKey.ledger) ?? InsertionLedger() }
        set { write(newValue, SharedStoreKey.ledger) }
    }
    public var keyboardPresence: KeyboardPresence? {
        get { read(SharedStoreKey.keyboardPresence) }
        set { write(newValue, SharedStoreKey.keyboardPresence) }
    }
    public var level: Float {
        get { defaults.float(forKey: SharedStoreKey.level) }
        set { defaults.set(newValue, forKey: SharedStoreKey.level) }
    }
    public var textStyle: TextStyle {
        get { defaults.string(forKey: SharedStoreKey.textStyle).flatMap(TextStyle.init(rawValue:)) ?? .casual }
        set { defaults.set(newValue.rawValue, forKey: SharedStoreKey.textStyle) }
    }
    public var textStylePickedAt: Date? {
        get { defaults.object(forKey: SharedStoreKey.textStylePickedAt) as? Date }
        set { defaults.set(newValue, forKey: SharedStoreKey.textStylePickedAt) }
    }
    public var defaultTextStyle: TextStyle {
        get { defaults.string(forKey: SharedStoreKey.defaultTextStyle).flatMap(TextStyle.init(rawValue:)) ?? .casual }
        set { defaults.set(newValue.rawValue, forKey: SharedStoreKey.defaultTextStyle) }
    }
    public var keyboardPreferences: KeyboardPreferences {
        get { read(SharedStoreKey.keyboardPreferences) ?? KeyboardPreferences() }
        set { write(newValue, SharedStoreKey.keyboardPreferences) }
    }
    /// The app's record itself, nil when the App Group gave nothing back. The keyboard tells that
    /// apart from a record of defaults (`LastKeyboardPreferences`).
    public var storedKeyboardPreferences: KeyboardPreferences? {
        read(SharedStoreKey.keyboardPreferences)
    }

    public var dictationsInserted: Int {
        get { defaults.integer(forKey: SharedStoreKey.dictationsInserted) }
        set { defaults.set(newValue, forKey: SharedStoreKey.dictationsInserted) }
    }

    public var keyboardMode: KeyboardMode {
        get { defaults.string(forKey: SharedStoreKey.keyboardMode).flatMap(KeyboardMode.init(rawValue:)) ?? .type }
        set { defaults.set(newValue.rawValue, forKey: SharedStoreKey.keyboardMode) }
    }

    private func read<T: Decodable>(_ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T?, _ key: String) {
        guard let value, let data = try? encoder.encode(value) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}

/// The newest heartbeat of the app's session, outside the shared defaults file: a notify state
/// word (64 bits held by notifyd, readable by any process with the name) carrying milliseconds
/// since 1970. Setting it is about 8 us on the M4 Mac against about 77 us for a defaults write
/// (`LevelChannel`), and it touches no disk. A name nobody holds reads as no heartbeat, which is
/// what a dead app should look like. Nothing here is a secret: like the Darwin pings, any process
/// could post it, and the worst a forged beat does is make the keyboard try the warm path once and
/// then report that Zone did not answer.
public final class SessionPulse: @unchecked Sendable {
    public let name: String
    private let lock = NSLock()
    private var token: Int32?

    public init(name: String) { self.name = name }

    /// Records `date` as the newest heartbeat. False when notify is unavailable, so the caller
    /// keeps writing the defaults record every time.
    @discardableResult
    public func beat(_ date: Date) -> Bool {
        #if canImport(notify)
        guard let token = registered() else { return false }
        let milliseconds = max(0, (date.timeIntervalSince1970 * 1000).rounded())
        return notify_set_state(token, UInt64(milliseconds)) == NOTIFY_STATUS_OK
        #else
        return false
        #endif
    }

    /// The newest heartbeat any process recorded under this name, nil when there is none.
    public var last: Date? {
        #if canImport(notify)
        guard let token = registered() else { return nil }
        var state: UInt64 = 0
        guard notify_get_state(token, &state) == NOTIFY_STATUS_OK, state > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(state) / 1000)
        #else
        return nil
        #endif
    }

    #if canImport(notify)
    /// One token per pulse for the life of the process; registering is the expensive part.
    private func registered() -> Int32? {
        lock.lock(); defer { lock.unlock() }
        if let token { return token }
        var fresh: Int32 = NOTIFY_TOKEN_INVALID
        guard notify_register_check(name, &fresh) == NOTIFY_STATUS_OK else { return nil }
        token = fresh
        return fresh
    }
    #endif

    deinit {
        #if canImport(notify)
        if let token { notify_cancel(token) }
        #endif
    }
}

extension SessionState {
    /// Same session apart from the heartbeat. The record stores dates to the second
    /// (ISO 8601), so `armedUntil` is compared to within one.
    func matchesApartFromHeartbeat(_ other: SessionState) -> Bool {
        guard isArmed == other.isArmed, modelReady == other.modelReady else { return false }
        switch (armedUntil, other.armedUntil) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a.timeIntervalSince(b)) < 1
        default: return false
        }
    }
}

/// Test double with the same contract.
public final class InMemorySharedStore: SharedStore {
    public var request: DictationRequest?
    public var status: DictationStatus?
    public var result: DictationResult?
    public var control: DictationControl?
    public var session: SessionState?
    public var ledger = InsertionLedger()
    public var keyboardPresence: KeyboardPresence?
    public var level: Float = 0
    public var textStyle: TextStyle = .casual
    public var keyboardPreferences = KeyboardPreferences()
    public var dictationsInserted = 0
    public var textStylePickedAt: Date?
    public var defaultTextStyle: TextStyle = .casual
    public var keyboardMode: KeyboardMode = .type

    public init() {}
}
