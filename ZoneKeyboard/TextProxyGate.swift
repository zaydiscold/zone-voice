// by zayd/cold @ zayd.wtf

import OSLog
import UIKit
import ZoneCore

/// The field's input traits, read from the host in one batch: each `UITextDocumentProxy`
/// property once. Every trait the keyboard uses is derived here, the same way the getters on
/// `KeyboardViewController` used to derive them on every call.
struct FieldTraits: Equatable {
    var returnKeyLabel = "return"
    var autocapitalizesSentences = true
    var fieldNeverCapitalizes = false
    var allowsAutocorrection = true
    var allowsSwipeTyping = true
    var allowsEmojiShortcodes = true
    /// Smart punctuation may curl quotes and join dashes here (`SmartPunctuation`).
    var allowsSmartQuotes = true
    var allowsSmartDashes = true
    var prefersNumbers = false
    var fieldKeys: [String] = []
    var capitalization = FieldCapitalization.sentences
    var isSearchField = false
    var dimsReturnWhenEmpty = false
    var explicitDarkAppearance: Bool?
    /// False on every Face ID iPhone, so a fresh process's first frame matches them.
    var needsGlobeKey = false
    /// An email address field, which `KeyboardViewController` hands to the next keyboard.
    var isEmailField = false
    /// A verification code field. iOS offers the code from Messages above its own keyboard and
    /// gives a custom keyboard no way to receive it, so this field is handed off too.
    var isCodeField = false
    var handsOffToSystemKeyboard: Bool { isEmailField || isCodeField }
    /// What a fresh copy may be in this field (`ClipboardCapture`): a secret in a password, code or
    /// card field, perhaps one in a user name or email field, anything in the rest.
    var clipboardField = ClipboardField.ordinary

    /// The proxy properties one batch reads, for the read accounting in `TextProxyGate`.
    static let proxyReadsPerBatch = 10

    init() {}

    /// Reads each of the proxy's ten trait properties exactly once. `needsGlobeKey` is the
    /// controller's `needsInputModeSwitchKey`, which reads the same document state.
    @MainActor init(reading proxy: UITextDocumentProxy, needsGlobeKey: Bool) {
        let autocorrection = proxy.autocorrectionType
        let keyboard = proxy.keyboardType ?? .default
        let secure = proxy.isSecureTextEntry == true
        let contentType = proxy.textContentType ?? nil
        let returnKey = proxy.returnKeyType ?? .default
        let autocapitalization = proxy.autocapitalizationType
        let enablesReturn = proxy.enablesReturnKeyAutomatically
        let appearance = proxy.keyboardAppearance
        let smartQuotes = proxy.smartQuotesType ?? .default
        let smartDashes = proxy.smartDashesType ?? .default

        // The field wants exact characters, not words: a password, a user name, a code, an
        // address or a number. Neither autocorrect nor swipe belongs there. Web forms often mark a
        // phone or card number by its content type alone (`autocomplete="tel"` on a text input),
        // so those count even on the default keyboard.
        let literalKeyboards: Set<UIKeyboardType> = [.URL, .emailAddress, .numberPad, .decimalPad, .phonePad, .asciiCapableNumberPad]
        let literalContent: Set<UITextContentType> = [.username, .password, .newPassword, .oneTimeCode, .emailAddress, .URL,
                                                      .telephoneNumber, .creditCardNumber, .creditCardSecurityCode]
        let takesLiteralText = secure || literalKeyboards.contains(keyboard)
            || contentType.map { literalContent.contains($0) } == true

        // A search or address bar: its words are names and fragments, left as typed.
        allowsAutocorrection = autocorrection != .no && keyboard != .webSearch && !takesLiteralText
        allowsSwipeTyping = !takesLiteralText

        // Where Apple's keyboard leaves punctuation alone (measured on iOS 26.2): web and email
        // address keyboards and the other literal fields. A field with autocorrection off still
        // gets both, so this does not follow `allowsAutocorrection`.
        let plainPunctuationKeyboards: Set<UIKeyboardType> = [.numbersAndPunctuation, .asciiCapable]
        let smartPunctuation = !takesLiteralText && !plainPunctuationKeyboards.contains(keyboard)
        allowsSmartQuotes = smartPunctuation && smartQuotes != .no
        allowsSmartDashes = smartPunctuation && smartDashes != .no

        switch returnKey {
        case .go: returnKeyLabel = "go"
        case .google, .search, .yahoo: returnKeyLabel = "search"
        case .join: returnKeyLabel = "join"
        case .next: returnKeyLabel = "next"
        case .route: returnKeyLabel = "route"
        case .send: returnKeyLabel = "send"
        case .done: returnKeyLabel = "done"
        case .emergencyCall: returnKeyLabel = "call"
        case .continue: returnKeyLabel = "continue"
        default: returnKeyLabel = "return"
        }

        switch keyboard {
        case .numberPad, .decimalPad, .phonePad, .numbersAndPunctuation, .asciiCapableNumberPad: prefersNumbers = true
        default: prefersNumbers = false
        }

        switch keyboard {
        case .URL: fieldKeys = [".", "/"]
        case .twitter: fieldKeys = ["@", "#"]
        default: fieldKeys = []
        }

        switch autocapitalization ?? .sentences {
        case .none: capitalization = .none
        case .words: capitalization = .words
        case .allCharacters: capitalization = .allCharacters
        default: capitalization = .sentences
        }
        autocapitalizesSentences = (autocapitalization ?? .sentences) == .sentences
        fieldNeverCapitalizes = autocapitalization == UITextAutocapitalizationType.none

        switch returnKey {
        case .search, .google, .yahoo: isSearchField = true
        default: isSearchField = keyboard == .webSearch || keyboard == .URL
        }

        allowsEmojiShortcodes = !takesLiteralText && !prefersNumbers
            && keyboard != .asciiCapable
        if #available(iOS 17.0, *) {
            let cardContent: Set<UITextContentType> = [.creditCardExpiration, .creditCardExpirationMonth,
                .creditCardExpirationYear, .creditCardType]
            if contentType.map({ cardContent.contains($0) }) == true { allowsEmojiShortcodes = false }
        }
        dimsReturnWhenEmpty = enablesReturn == true

        switch appearance {
        case .dark: explicitDarkAppearance = true
        case .light: explicitDarkAppearance = false
        default: explicitDarkAppearance = nil
        }

        self.needsGlobeKey = needsGlobeKey
        isEmailField = keyboard == .emailAddress || contentType == .emailAddress
        isCodeField = contentType == .oneTimeCode

        var secretContent: Set<UITextContentType> = [.password, .newPassword, .oneTimeCode, .creditCardNumber]
        if #available(iOS 17.0, *) {
            secretContent.formUnion([.creditCardSecurityCode, .creditCardExpiration, .creditCardExpirationMonth,
                                     .creditCardExpirationYear, .creditCardName, .creditCardGivenName,
                                     .creditCardMiddleName, .creditCardFamilyName, .creditCardType])
        }
        if secure || contentType.map({ secretContent.contains($0) }) == true {
            clipboardField = .secret
        } else if isEmailField || contentType == .username {
            clipboardField = .signIn
        }
    }
}

/// Decides when the host's document may be read through `textDocumentProxy`, keeps the reads to
/// a minimum, and leaves a trace in the recording log when the keyboard drops input.
///
/// The crash this guards against: UIKit replaces the proxy's document state on its XPC thread
/// (`-[UIInputViewController _didResetDocumentState]`) without a lock, then waits on the main
/// queue to deliver the host callbacks. A main-thread proxy read during the replacement lands on
/// a freed object inside `-[_UITextDocumentInterface _controllerState]`. Phone crash reports:
/// four in `viewWillAppear` (2026-10-31 to 2026-11-04) and, after reads waited for the document
/// to be live, one more on 2026-11-08 inside `viewDidAppear` (build 2026110813). SYKeyboard
/// (SNMac/SYKeyboard #180, #181, #198, #200) caught the same race in Crashlytics and reached the
/// same conclusion: the race is inside UIKit, so a keyboard can only make fewer reads and keep
/// them out of the appearance transitions, when the host sends its state.
///
/// The rules:
/// - Nothing reads the proxy between `viewWillAppear` and going live, or after
///   `viewWillDisappear`. Reads in that time answer from the last live ones.
/// - The document goes live on the first host callback (UIKit delivers those after it has
///   replaced the state), the first touch or write, or `didAppearFallback` after
///   `viewDidAppear`: no longer inside `viewDidAppear` itself, where the Nov 8 crash read.
/// - The trait properties are read once per field, in one batch (`FieldTraits`), and again only
///   when the model refreshes traits after a host callback or the document identifier changes.
///   Ordinary keystrokes read no traits.
/// - The document identifier is read at most once per main-queue turn, and again after any host
///   callback.
@MainActor
final class TextProxyGate {
    enum Trigger: String {
        case textWillChange, textDidChange, selectionWillChange, selectionDidChange
        case touch, write, didAppear
    }

    enum Write: String {
        case insert, deleteBackward, adjustTextPosition
    }

    /// Between `viewWillAppear` and `viewWillDisappear`.
    private(set) var isOnScreen = false
    /// The host's document can be read (see the type's comment).
    private(set) var isLive = false
    /// The last traits read while live. Answered as is while not live, so the first frame of an
    /// appearance keeps the last field's return key, globe and layer instead of flashing defaults.
    private(set) var traits = FieldTraits()
    /// The last document identifier read while live.
    private(set) var lastSession: String?

    /// Proxy reads made, for tests and the read budget: trait properties and identifiers.
    private(set) var traitReads = 0
    private(set) var sessionReads = 0

    private let readTraits: () -> FieldTraits
    private let readSession: () -> String?
    /// Runs work on the main queue after a delay (zero: the next turn).
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private let now: () -> TimeInterval
    private let journal: RecordingJournal?
    /// Whether the keyboard's view is in a window and not hidden, for the log.
    var viewState: () -> (inWindow: Bool, hidden: Bool) = { (false, false) }
    /// Runs once each time the document goes live, after the traits are read.
    var onLive: (Trigger) -> Void = { _ in }
    var onClipboardFieldChange: (() -> Void)?

    init(readTraits: @escaping () -> FieldTraits,
         readSession: @escaping () -> String?,
         schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
         },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         journal: RecordingJournal? = KeyboardLog.journal) {
        self.readTraits = readTraits
        self.readSession = readSession
        self.schedule = schedule
        self.now = now
        self.journal = journal
    }

    // MARK: Lifecycle

    /// Bumped on every `viewWillAppear`, so a go-live deferred from one appearance's
    /// `viewDidAppear` never fires inside the next one's transition.
    private var appearance = 0

    func willAppear() {
        appearance += 1
        visit.record("wA", at: now())
        if visit.sawWillDisappear { visit.reappeared = true }
        visit.droppedWriteLogged = false
        visit.offTouchLogged = false
        isOnScreen = true
        isLive = false
        cachedSession = nil
    }

    /// How long after `viewDidAppear` the document goes live when no host callback or touch made
    /// it live first. On the iOS 26.2 simulator the host's first callback (`textWillChange`, the
    /// sign of a document-state reset) arrived 10 to 13 ms after `viewDidAppear`, so neither
    /// `viewDidAppear` nor the next main-queue turn is past the reset; a read there is what
    /// crashed on 2026-11-08. Until this fires, the keys show the last field's traits, and a
    /// touch goes live at once.
    static let didAppearFallback: TimeInterval = 0.15

    /// Goes live `didAppearFallback` later unless a host callback or touch did first, then runs
    /// `then` (still only while this appearance is on screen).
    func didAppear(then: @escaping () -> Void = {}) {
        visit.record("dA", at: now())
        if !visit.sawWillAppear { visit.unpaired = true }
        let generation = appearance
        schedule(Self.didAppearFallback) { [weak self] in
            guard let self, self.appearance == generation else { return }
            self.goLive(.didAppear)
            if self.isLive { then() }
        }
    }

    func willDisappear() {
        visit.record("wD", at: now())
        visit.sawWillDisappear = true
        isOnScreen = false
        isLive = false
        cachedSession = nil
    }

    /// Ends the visit and writes its line to the recording log when something about it was off.
    func didDisappear() {
        visit.record("dD", at: now())
        if let fields = visit.summary(firstOfProcess: !Self.loggedVisitThisProcess) {
            Self.loggedVisitThisProcess = true
            journal?.log("keyboardVisit", fields)
        }
        visit = Visit()
    }

    /// A host callback: UIKit has applied the host's document state, so it proves the document
    /// is live; any identifier read before it may be stale, and so may the traits.
    /// - Returns: true when this callback made the document live (the caller's own refresh is
    ///   then already done).
    @discardableResult
    func hostCallback(_ trigger: Trigger) -> Bool {
        cachedSession = nil
        traitsCurrent = false
        guard isOnScreen else {
            visit.offCallbacks += 1
            return false
        }
        if !visit.sawCallback {
            visit.sawCallback = true
            visit.record("cb:\(trigger.rawValue)", at: now())
        }
        let wasLive = isLive
        goLive(trigger)
        return !wasLive && isLive
    }

    /// A key, the strip or the mic was touched. Touches reach the keys only once the keyboard is
    /// on screen and interactive, so the document is live; a touch while off screen is logged,
    /// not trusted (see `offScreenTouch`).
    func touched() {
        guard isOnScreen else { return offScreenTouch() }
        goLive(.touch)
    }

    /// Whether a write may reach the proxy now. Writes go through the same document state as
    /// reads. A dropped write is logged, and recorded in the recording log once per appearance.
    func canWrite(_ write: Write) -> Bool {
        goLive(.write)
        if isLive { return true }
        visit.droppedWrites += 1
        KeyboardLog.typing.error("text proxy write while the keyboard is off screen: dropped (\(write.rawValue, privacy: .public))")
        if !visit.droppedWriteLogged {
            visit.droppedWriteLogged = true
            journal?.log("keyboardDroppedWrite", context(op: write.rawValue))
        }
        return false
    }

    // MARK: Reads

    /// The host's document identifier, read at most once per main-queue turn while live. A
    /// changed identifier means another field: its traits are read again.
    func session() -> String? {
        guard isLive else { return lastSession }
        if let cachedSession { return cachedSession }
        let session = readSession()
        sessionReads += 1
        lastSession = session
        cachedSession = .some(session)
        schedule(0) { [weak self] in self?.cachedSession = nil }
        if session != traitsSession { readTraitBatch(session: session) }
        return session
    }

    /// Reads the traits again if a host callback came since they were read. The model calls this
    /// when it refreshes traits, which it does for host changes that are not its own echoes.
    func reloadTraitsIfStale() {
        guard isLive, !traitsCurrent else { return }
        // A changed identifier already read them again.
        let session = session()
        if !traitsCurrent { readTraitBatch(session: session) }
    }

    // MARK: Private

    /// `.some(nil)` caches "no session"; nil means read it.
    private var cachedSession: String??
    /// The identifier the traits were read for.
    private var traitsSession: String?
    /// No host callback since the traits were read.
    private var traitsCurrent = false

    private func goLive(_ trigger: Trigger) {
        guard isOnScreen, !isLive else { return }
        isLive = true
        visit.record("live:\(trigger.rawValue)", at: now())
        KeyboardLog.typing.info("document live: \(trigger.rawValue, privacy: .public), visit \(self.visit.sequence, privacy: .public)")
        let session = readSession()
        sessionReads += 1
        lastSession = session
        cachedSession = .some(session)
        schedule(0) { [weak self] in self?.cachedSession = nil }
        readTraitBatch(session: session)
        onLive(trigger)
    }

    private func readTraitBatch(session: String?) {
        let previousField = traits.clipboardField
        traits = readTraits()
        traitReads += FieldTraits.proxyReadsPerBatch
        traitsSession = session
        traitsCurrent = true
        if traits.clipboardField != previousField { onClipboardFieldChange?() }
    }

    private func offScreenTouch() {
        visit.offTouches += 1
        KeyboardLog.typing.error("key touched while the keyboard is off screen: not live")
        // Not made live here: after `viewWillDisappear` the host may be resetting the document
        // (SYKeyboard #180 crashed reading in exactly that window). Logged so a cancelled
        // dismissal that leaves the keys visible but dead shows in the recording log.
        guard !visit.offTouchLogged else { return }
        visit.offTouchLogged = true
        journal?.log("keyboardDroppedWrite", context(op: "touch"))
    }

    private func context(op: String) -> [String: String] {
        let view = viewState()
        var fields = [
            "op": op,
            "onScreen": String(isOnScreen),
            "live": String(isLive),
            "inWindow": String(view.inWindow),
            "hidden": String(view.hidden),
            "seq": visit.sequence,
        ]
        if let last = visit.lastEvent {
            fields["since"] = last.name
            fields["sinceMs"] = String(Int(((now() - last.at) * 1000).rounded()))
        }
        return fields
    }

    // MARK: Visit

    /// One stay of the keyboard, from `viewWillAppear` to `viewDidDisappear`, kept in memory as a
    /// short sequence ("wA dA+310 live:didAppear+311 wD+5400 dD+5650", milliseconds since the
    /// visit began). Written to the recording log only when something was off, plus once per
    /// process as a baseline, so ordinary use costs no log lines.
    private var visit = Visit()
    private static var loggedVisitThisProcess = false

    /// Forgets that this process logged a visit, for tests.
    static func resetForTesting() { loggedVisitThisProcess = false }

    struct Visit {
        static let maxEvents = 24
        private(set) var events: [(name: String, at: TimeInterval)] = []
        private(set) var start: TimeInterval?
        var sawWillAppear = false
        var sawDidAppear = false
        var sawWillDisappear = false
        var sawCallback = false
        var reappeared = false
        var unpaired = false
        var droppedWrites = 0
        var offTouches = 0
        var offCallbacks = 0
        var droppedWriteLogged = false
        var offTouchLogged = false
        private var wentLive = false
        private var truncated = 0

        var lastEvent: (name: String, at: TimeInterval)? { events.last }

        mutating func record(_ name: String, at time: TimeInterval) {
            if start == nil { start = time }
            if name == "wA" { sawWillAppear = true }
            if name == "dA" { sawDidAppear = true }
            if name.hasPrefix("live:") { wentLive = true }
            guard events.count < Self.maxEvents else { truncated += 1; return }
            events.append((name, time))
        }

        var sequence: String {
            guard let start else { return "" }
            let parts = events.enumerated().map { index, event in
                index == 0 ? event.name : "\(event.name)+\(Int(((event.at - start) * 1000).rounded()))"
            }
            return (parts + (truncated > 0 ? ["more:\(truncated)"] : [])).joined(separator: " ")
        }

        /// The fields to log, or nil for an ordinary visit (unless it is the process's first).
        func summary(firstOfProcess: Bool) -> [String: String]? {
            var anomalies: [String] = []
            if droppedWrites > 0 { anomalies.append("droppedWrites") }
            if offTouches > 0 { anomalies.append("offScreenTouches") }
            if reappeared { anomalies.append("reappeared") }
            if unpaired { anomalies.append("didAppearWithoutWillAppear") }
            // Shown (didAppear) and never readable: every key in that stay was dead.
            if sawDidAppear, !wentLive { anomalies.append("neverLive") }
            guard !anomalies.isEmpty || firstOfProcess else { return nil }
            return [
                "seq": sequence,
                "anomalies": anomalies.isEmpty ? "none" : anomalies.joined(separator: ","),
                "droppedWrites": String(droppedWrites),
                "offScreenTouches": String(offTouches),
                "offScreenCallbacks": String(offCallbacks),
            ]
        }
    }
}
