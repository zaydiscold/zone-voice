// by zayd/cold @ zayd.wtf

import Foundation

/// Availability without reading the contents.
@MainActor public protocol ClipboardSource: AnyObject {
    var changeCount: Int { get }
    var hasText: Bool { get }
}

public enum AutomaticClipboardValue: Sendable {
    case text(String)
    case image(ClipboardImage)
}

public struct AutomaticClipboardSnapshot: Sendable {
    public let count: Int
    public let hasContent: Bool
    public let types: [String]

    public init(count: Int, hasContent: Bool, types: [String]) {
        self.count = count
        self.hasContent = hasContent
        self.types = types
    }

    /// With an unchanged board the count is the entire probe. A fresh availability result
    /// is cacheable only when the count is still the same after reading the supported flags.
    static func availability(reusing cached: Self?, allowed: () -> Bool,
                             changeCount: () -> Int, hasContent: () -> Bool) -> Self? {
        guard allowed() else { return nil }
        let count = changeCount()
        guard allowed() else { return nil }
        if let cached, cached.count == count { return cached }
        let supported = hasContent()
        guard allowed(), changeCount() == count else { return nil }
        return .init(count: count, hasContent: supported, types: [])
    }
}

/// The automatic path never consults the synchronous clipboard getters on MainActor.
@MainActor public protocol AutomaticClipboardSource: ClipboardSource {
    /// Availability for the keyboard, including when it only offers the system Paste button.
    func inspectAvailability(reusing cached: AutomaticClipboardSnapshot?, allowed: @escaping @Sendable () -> Bool, _ done: @escaping @MainActor @Sendable (AutomaticClipboardSnapshot?) -> Void)
    func inspect(ignoring count: Int?, allowed: @escaping @Sendable () -> Bool, _ done: @escaping @MainActor @Sendable (AutomaticClipboardSnapshot?) -> Void)
    func readCopy(for count: Int, skipsSecrets: Bool, allowed: @escaping @Sendable () -> Bool,
                  _ done: @escaping @MainActor @Sendable (Int, AutomaticClipboardValue?) -> Void)
}

public extension AutomaticClipboardSource {
    func inspectAvailability(reusing cached: AutomaticClipboardSnapshot?, allowed: @escaping @Sendable () -> Bool, _ done: @escaping @MainActor @Sendable (AutomaticClipboardSnapshot?) -> Void) {
        inspect(ignoring: nil, allowed: allowed, done)
    }
}

private final class ClipboardReadPermission: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    var isActive: Bool { lock.withLock { active } }
    func revoke() { lock.withLock { active = false } }
}

/// The last clipboard change Zone has dealt with, shared by the app and the keyboard so neither
/// reads a copy the other already handled.
public protocol ClipboardSeenStore: AnyObject {
    var seenChangeCount: Int? { get set }
    /// The change counted as made for a password, code or card field. Only the copy now on the
    /// board can be pasted, so one number is enough.
    var privateChangeCount: Int? { get set }
    /// The keyboard's last look was in a password, code or card field and it has not looked
    /// anywhere else since (not even as it went away). Until it does, whatever is on the board
    /// may have been copied there, so neither the keyboard nor the app keeps it.
    var secretFieldOpen: Bool { get set }
}

/// `ClipboardSeenStore` in the App Group's defaults.
public final class SharedClipboardSeenStore: ClipboardSeenStore, @unchecked Sendable {
    static let key = "zone.clipboard.seenChangeCount"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public convenience init?() {
        guard let defaults = UserDefaults(suiteName: ZoneContract.appGroup) else { return nil }
        self.init(defaults: defaults)
    }

    // UserDefaults is thread safe. Check the app's published consent inside the disk transaction.
    func allowsAutomaticWrite(count: Int, filtered: Bool) -> Bool {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = defaults.data(forKey: SharedStoreKey.keyboardPreferences),
              let settings = try? decoder.decode(KeyboardPreferences.self, from: data),
              settings.clipboardAutomatic, settings.clipboardHistoryEnabled else { return false }
        return !settings.clipboardSkipsSecrets || (filtered && !secretFieldOpen && privateChangeCount != count)
    }

    // A previous keyboard instance can finish its asynchronous exit after the next one appears.
    // Only the latest field observer may update the shared privacy markers from a delayed reply.
    fileprivate var fieldObserver: String? {
        get { defaults.string(forKey: "zone.clipboard.fieldObserver") }
        set { defaults.set(newValue, forKey: "zone.clipboard.fieldObserver") }
    }

    public var privateChangeCount: Int? {
        get { defaults.object(forKey: "zone.clipboard.privateChangeCount") as? Int }
        set { defaults.set(newValue, forKey: "zone.clipboard.privateChangeCount") }
    }

    public var secretFieldOpen: Bool {
        get { defaults.bool(forKey: "zone.clipboard.secretFieldOpen") }
        set {
            if newValue { defaults.set(true, forKey: "zone.clipboard.secretFieldOpen") } else { defaults.removeObject(forKey: "zone.clipboard.secretFieldOpen") }
        }
    }

    public var seenChangeCount: Int? {
        get { defaults.object(forKey: Self.key) as? Int }
        set {
            if let newValue { defaults.set(newValue, forKey: Self.key) } else { defaults.removeObject(forKey: Self.key) }
        }
    }
}

/// One tap on a paste button, bound to the board change it was made on. Each accepted tap gets
/// its own token and carries it to its own delivery, so two pastes whose text arrives in the
/// reverse order, or a look that runs while the text is still loading, can never lend one paste
/// another change's count. A change count is metadata: noting one makes iOS ask nothing.
public struct ClipboardPasteToken: Equatable, Sendable {
    /// The board's change count when the tap arrived.
    public let changeCount: Int
    /// The change the keyboard had last looked at when the tap arrived. Nil in the app, which
    /// never looks at the board by itself.
    public let observedChangeCount: Int?

    public init(changeCount: Int, observedChangeCount: Int? = nil) {
        self.changeCount = changeCount
        self.observedChangeCount = observedChangeCount
    }
}

/// Tracks clipboard availability and receives manual or separately opted-in automatic deliveries.
///
@MainActor public final class ClipboardCapture {
    public struct Settings: Equatable, Sendable {
        public var enabled: Bool
        public var skipsSecrets: Bool
        public var automatic: Bool
        public init(enabled: Bool, skipsSecrets: Bool, automatic: Bool = false) {
            self.automatic = automatic
            self.enabled = enabled
            self.skipsSecrets = skipsSecrets
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// Clipboard history is off.
        case off
        /// Nothing new since the last look.
        case unchanged
        /// New, and not text (an image, a file): nothing to keep.
        case notText
        case skipped(ClipboardSkip)
        /// New text is there and waits for a tap on the system paste button.
        case waitingForTap
        case saved(ClipboardEntry)
        case alreadySaved(ClipboardEntry)
        /// The list could not be read or written now (the phone is locked, or storage failed). The
        /// copy is tried again later, not at every look.
        case failed
        /// The keyboard is in a user name or email field: nothing is read here, and the copy is
        /// looked at again in the next ordinary field.
        case heldBack
        /// The board changed after Zone last looked (or during the paste), so Zone cannot say
        /// which field the copy was made in. The paste itself goes in; nothing is kept now. The
        /// keyboard's next look offers the copy as usual if it is in an ordinary field then.
        case changedSinceLook
    }

    private let source: ClipboardSource
    private let history: ClipboardHistory
    private let seen: ClipboardSeenStore
    /// Stable metadata for this keyboard. Every look still checks the board count and applies
    /// the current field's privacy rules, including on a cache hit.
    private var lastAvailability: AutomaticClipboardSnapshot?
    private struct FieldLook: Equatable {
        let settings: Settings
        let field: ClipboardField
        let leaving: Bool
    }
    private let observerID = UUID().uuidString
    private var lastFieldLook: FieldLook?
    private var fieldPermission: ClipboardReadPermission?
    private struct PendingFieldLook {
        let run: @MainActor () -> Void
        let discard: @MainActor () -> Void
    }
    private var nextFieldLook: PendingFieldLook?
    private var inspecting = false
    private var readPermission = ClipboardReadPermission()
    private var automaticAttempt: Int?
    private var retryWriteAfter: Date?
    private var automaticFilter = false
    private var automaticWrite: Task<ClipboardAddResult, Never>?
    private var automaticInFlight: Int?
    private var automaticGeneration: UInt = 0
    private let clock: () -> Date
    /// True while new text waits for a tap (`Outcome.waitingForTap`), until it is saved or replaced.
    public private(set) var hasUnsavedCopy = false

    public init(source: ClipboardSource, history: ClipboardHistory, seen: ClipboardSeenStore,
                clock: @escaping () -> Date = Date.init) {
        self.source = source
        self.history = history
        self.seen = seen
        self.clock = clock
    }

    /// Check availability without requesting a copy. A slow pasteboard service must never
    /// hold the keyboard's main actor. Publish a secret field immediately so the app also
    /// holds the copy until the worker can identify the change at the field boundary.
    public func check(_ settings: Settings, field: ClipboardField = .ordinary, leaving: Bool = false,
                      done: (@MainActor (Outcome) -> Void)? = nil) {
        if !settings.enabled || !settings.automatic || leaving || (settings.skipsSecrets && field != .ordinary) {
            cancelAutomaticRead()
        }
        guard settings.enabled else { cancelFieldCheck(); done?(.off); return }
        let look = FieldLook(settings: settings, field: field, leaving: leaving)
        let shared = seen as? SharedClipboardSeenStore
        if let shared {
            if !leaving && (lastFieldLook == nil || lastFieldLook?.leaving == true) {
                if field == .secret, !seen.secretFieldOpen { seen.secretFieldOpen = true }
                shared.fieldObserver = observerID
            }
            guard shared.fieldObserver == observerID else { done?(.unchanged); return }
        }
        if look != lastFieldLook {
            fieldPermission?.revoke()
            lastFieldLook = look
        }
        if field == .secret, !seen.secretFieldOpen { seen.secretFieldOpen = true }
        if let permission = fieldPermission {
            // At most one IPC outstanding and one replacement, even when the timer keeps firing.
            guard !permission.isActive else { done?(.unchanged); return }
            nextFieldLook?.discard()
            nextFieldLook = PendingFieldLook(run: { [weak self] in
                guard let self else { done?(.unchanged); return }
                self.check(settings, field: field, leaving: leaving, done: done)
            }, discard: { done?(.unchanged) })
            return
        }
        guard let board = source as? AutomaticClipboardSource else {
            if let snapshot = AutomaticClipboardSnapshot.availability(reusing: lastAvailability, allowed: { true },
                    changeCount: { source.changeCount }, hasContent: { source.hasText }) {
                finishFieldCheck(snapshot, look: look, done: done)
            } else { done?(.unchanged) }
            return
        }
        let permission = ClipboardReadPermission()
        fieldPermission = permission
        let previouslySeen = seen.seenChangeCount
        board.inspectAvailability(reusing: lastAvailability, allowed: { permission.isActive }) { [weak self] snapshot in
            guard let self else { done?(.unchanged); return }
            self.fieldPermission = nil
            let next = self.nextFieldLook
            self.nextFieldLook = nil
            guard shared == nil || shared?.fieldObserver == self.observerID else {
                done?(.unchanged)
                next?.discard()
                return
            }
            if permission.isActive, let snapshot {
                if self.seen.seenChangeCount != previouslySeen && self.seen.seenChangeCount != snapshot.count {
                    // The other process handled another copy while this probe was in transit.
                    self.check(settings, field: field, leaving: leaving, done: done)
                    return
                }
                self.finishFieldCheck(snapshot, look: look, done: done)
            } else { done?(.unchanged) }
            next?.run()
        }
    }

    /// Withdraw a pending look when access or the history preference changes. Keep a shared
    /// open secret mark until an eligible keyboard observes the boundary count.
    public func cancelFieldCheck() {
        fieldPermission?.revoke()
        nextFieldLook?.discard()
        nextFieldLook = nil
        lastFieldLook = nil
        lastAvailability = nil
        hasUnsavedCopy = false
    }

    private func finishFieldCheck(_ snapshot: AutomaticClipboardSnapshot, look: FieldLook,
                                  done: (@MainActor (Outcome) -> Void)?) {
        let settings = look.settings
        let field = look.field
        let count = snapshot.count
        lastAvailability = snapshot
        let isPrivate = Self.notePrivacy(of: count, field: field, seen: seen)
        if look.leaving, seen.secretFieldOpen { seen.secretFieldOpen = false }
        guard count != seen.seenChangeCount else { hasUnsavedCopy = false; done?(.unchanged); return }
        guard snapshot.hasContent else {
            seen.seenChangeCount = count
            hasUnsavedCopy = false
            done?(.notText)
            return
        }
        if settings.skipsSecrets && isPrivate {
            seen.seenChangeCount = count
            hasUnsavedCopy = false
            history.noteSkip(.privateField)
            done?(.skipped(.privateField))
            return
        }
        guard !settings.skipsSecrets || field == .ordinary else { hasUnsavedCopy = false; done?(.heldBack); return }
        hasUnsavedCopy = true
        done?(.waitingForTap)
    }

    /// Text that came through a paste button (Zone's Paste key, or Save in the panel): the tap
    /// was the permission, so iOS asked nothing. The text always goes into the field; this only
    /// decides whether Zone also keeps it.
    ///
    /// The board's change count is read now, not taken from the last look: the look runs once a
    /// second, and a copy made since would otherwise be judged by the copy before it. A first tap
    /// is kept without waiting for a look. A change marked private is still skipped while
    /// filtering is on.
    ///
    /// `token` is the one `notePasteTap()` gave this paste's tap. With it, the paste is kept only
    /// when the board still holds the change the tap was made on (`changedSinceLook` otherwise).
    /// Without one, the tap and the text are taken to arrive together.
    @discardableResult
    public func keepPasted(_ text: String, image: ClipboardImage? = nil, settings: Settings, field: ClipboardField = .ordinary, types: [String] = [],
                           route: ClipboardRoute = .pasteKey, token: ClipboardPasteToken? = nil) -> Outcome {
        guard settings.enabled else { return .off }
        if lastFieldLook != nil, let shared = seen as? SharedClipboardSeenStore,
           shared.fieldObserver != observerID {
            return .changedSinceLook
        }
        let count = source.changeCount
        // A queued pre-tap snapshot cannot vouch for a newer copy after this delivery.
        fieldPermission?.revoke()
        nextFieldLook?.discard()
        nextFieldLook = nil
        var isPrivate = Self.notePrivacy(of: count, field: field, seen: seen)
        if let token, seen.privateChangeCount == token.changeCount { isPrivate = true }
        let skip = ClipboardPolicy.skipBeforeReading(types: types, field: isPrivate ? .secret : field, skipsSecrets: settings.skipsSecrets)
        if let token, token.changeCount != count { return skip.map(Outcome.skipped) ?? .changedSinceLook }
        if let reason = skip {
            // One copy is counted once, however many times it is pasted.
            if reason != .own, seen.seenChangeCount != count { history.noteSkip(reason) }
            seen.seenChangeCount = count
            hasUnsavedCopy = false
            return .skipped(reason)
        }
        // Filtering also covers pastes into sign-in fields.
        guard !settings.skipsSecrets || field == .ordinary else { return .heldBack }
        return keep(text, image: image, settings: settings, changeCount: count, route: route)
    }

    /// The app has no field of its own to vouch for the copy. In both processes, keep
    /// the keyboard's private-field marks intact. A refusal gets one attempt per change.
    public func captureAutomatically(route: ClipboardRoute,
                                     eligibility: @escaping @MainActor () -> Settings?,
                                     done: @escaping @MainActor (Outcome) -> Void = { _ in }) {
        guard let settings = eligibility(), settings.enabled, settings.automatic,
              let board = source as? AutomaticClipboardSource else { return }
        if automaticInFlight != nil, automaticFilter != settings.skipsSecrets { cancelAutomaticRead() }
        guard !inspecting else { return }
        inspecting = true
        let generation = automaticGeneration
        let retryingWrite = retryWriteAfter.map { clock() >= $0 } ?? false
        let permission = readPermission
        board.inspect(ignoring: retryingWrite ? nil : automaticAttempt, allowed: { permission.isActive }) { [weak self] snapshot in
            guard let self else { return }
            self.inspecting = false
            guard generation == self.automaticGeneration, let snapshot,
                  let settings = eligibility(), settings.enabled, settings.automatic else { return }
            self.capture(snapshot, from: board, route: route, settings: settings, eligibility: eligibility, done: done)
        }
    }

    private func capture(_ snapshot: AutomaticClipboardSnapshot, from board: AutomaticClipboardSource,
                         route: ClipboardRoute, settings: Settings, eligibility: @escaping @MainActor () -> Settings?,
                         done: @escaping @MainActor (Outcome) -> Void) {
        let count = snapshot.count
        if let active = automaticInFlight, active != count { cancelAutomaticRead() }
        guard count != seen.seenChangeCount, snapshot.hasContent,
              (!settings.skipsSecrets || (!seen.secretFieldOpen && seen.privateChangeCount != count)) else { return }
        let types = snapshot.types
        automaticAttempt = count
        retryWriteAfter = nil
        if let reason = ClipboardPolicy.skipBeforeReading(types: types, field: .ordinary, skipsSecrets: settings.skipsSecrets) {
            if reason != .own {
                let permission = readPermission
                Task.detached(priority: .utility) { [history] in
                    history.noteSkip(reason, canStore: { permission.isActive })
                }
            }
            seen.seenChangeCount = count
            hasUnsavedCopy = false
            done(.skipped(reason))
            return
        }
        let generation = automaticGeneration
        automaticInFlight = count
        automaticFilter = settings.skipsSecrets
        let permission = readPermission
        let marks = seen as? SharedClipboardSeenStore
        board.readCopy(for: count, skipsSecrets: settings.skipsSecrets, allowed: {
            permission.isActive && (marks?.allowsAutomaticWrite(count: count, filtered: settings.skipsSecrets) ?? true)
        }) { [weak self] deliveredCount, value in
            Task { @MainActor in
                guard let self, generation == self.automaticGeneration, self.automaticInFlight == count else { return }
                guard let current = eligibility(), current.enabled, current.automatic,
                      deliveredCount == count, self.seen.seenChangeCount != count else {
                    self.automaticInFlight = nil
                    return
                }
                // The provider can carry privacy markers absent from the board snapshot.
                // Reacquire under the new policy, including when the old read returned nil.
                if current.skipsSecrets != settings.skipsSecrets {
                    self.cancelAutomaticRead()
                    self.captureAutomatically(route: route, eligibility: eligibility, done: done)
                    return
                }
                guard let value else {
                    self.automaticInFlight = nil
                    return
                }
                let privateCopy = self.seen.secretFieldOpen || self.seen.privateChangeCount == count
                let skip = ClipboardPolicy.skipBeforeReading(types: types, field: privateCopy ? .secret : .ordinary,
                                                            skipsSecrets: current.skipsSecrets)
                let now = self.clock()
                let sharedMarks = self.seen as? SharedClipboardSeenStore
                let canStore: @Sendable () -> Bool = {
                    !Task.isCancelled && (sharedMarks?.allowsAutomaticWrite(count: count, filtered: settings.skipsSecrets) ?? true)
                }
                let write = Task.detached(priority: .utility) { [history = self.history] in
                    guard !Task.isCancelled else { return ClipboardAddResult.failed }
                    if let skip {
                        if skip != .own { history.noteSkip(skip) }
                        return .skipped(skip)
                    }
                    switch value {
                    case .text(let text): return history.add(text, route: route, skipsSecrets: current.skipsSecrets, now: now, canStore: canStore)
                    case .image(let picture): return history.addImage(picture, route: route, now: now, canStore: canStore)
                    }
                }
                self.automaticWrite = write
                let result = await write.value
                guard self.automaticGeneration == generation, self.automaticInFlight == count else { return }
                self.automaticInFlight = nil
                self.automaticWrite = nil
                if result == .failed {
                    // Storage may be temporarily protected. A refusal to read stays latched.
                    self.retryWriteAfter = self.clock().addingTimeInterval(30)
                } else {
                    self.hasUnsavedCopy = false
                    self.seen.seenChangeCount = count
                }
                switch result {
                case .saved(let entry): done(.saved(entry))
                case .alreadySaved(let entry): done(.alreadySaved(entry))
                case .skipped(let reason): done(.skipped(reason))
                case .failed: done(.failed)
                }
            }
        }
    }

    public func cancelAutomaticRead() {
        guard inspecting || automaticInFlight != nil || automaticWrite != nil else { return }
        readPermission.revoke()
        readPermission = ClipboardReadPermission()
        automaticWrite?.cancel()
        automaticWrite = nil
        automaticGeneration &+= 1
        if automaticInFlight != nil { automaticAttempt = nil }
        automaticInFlight = nil
    }

    /// A paste button was tapped: the token binds this paste to the board's change now. Reads the
    /// change count only.
    public func notePasteTap() -> ClipboardPasteToken {
        ClipboardPasteToken(changeCount: source.changeCount, observedChangeCount: lastAvailability?.count)
    }

    private func keep(_ text: String, image: ClipboardImage? = nil, settings: Settings, changeCount: Int?, route: ClipboardRoute) -> Outcome {
        let outcome = Self.add(text, image: image, settings: settings, history: history, seen: seen, changeCount: changeCount, route: route, now: clock())
        if outcome != .failed { hasUnsavedCopy = false }
        return outcome
    }

    private static func add(_ text: String, image: ClipboardImage? = nil, settings: Settings, history: ClipboardHistory, seen: ClipboardSeenStore,
                            changeCount: Int?, route: ClipboardRoute, now: Date) -> Outcome {
        let result = image.map { history.addImage($0, route: route, now: now) } ?? history.add(text, route: route, skipsSecrets: settings.skipsSecrets, now: now)
        switch result {
        case .saved(let entry):
            seen.seenChangeCount = changeCount
            return .saved(entry)
        case .alreadySaved(let entry):
            seen.seenChangeCount = changeCount
            return .alreadySaved(entry)
        case .skipped(let reason):
            seen.seenChangeCount = changeCount
            return .skipped(reason)
        case .failed:
            return .failed
        }
    }

    /// Records what the keyboard's field says about the copy now on the board, and answers
    /// whether that copy counts as made for a password, code or card field.
    ///
    /// In such a field the copy is marked, and so is the field itself (`secretFieldOpen`). At the
    /// keyboard's next look in another field, whatever is then on the board is marked too: it may
    /// have been copied in the field just left, after the last look there. That look closes the
    /// field, as does the look the keyboard makes as it goes away (`check(leaving:)`). If neither
    /// comes (the keyboard's process ended first), the field stays open and neither the keyboard
    /// nor the app keeps anything until the keyboard looks again.
    static func notePrivacy(of count: Int, field: ClipboardField, seen: ClipboardSeenStore) -> Bool {
        if field == .secret {
            if seen.privateChangeCount != count { seen.privateChangeCount = count }
            if !seen.secretFieldOpen { seen.secretFieldOpen = true }
            return true
        }
        if seen.secretFieldOpen {
            seen.privateChangeCount = count
            seen.secretFieldOpen = false
        }
        return seen.privateChangeCount == count
    }

    /// Text from a paste control or an automatic read. The app uses what the keyboard left in the shared
    /// store and from two change counts: the board's when the tap arrived and when the text did.
    /// A change count is metadata; reading one makes iOS ask nothing.
    ///
    /// With filtering on, Zone skips a copy the keyboard marked private, anything while the keyboard's last look was
    /// in a password, code or card field it never reported leaving, a copy the app cannot match
    /// to one change (the board moved during the paste), and everything when the shared store is
    /// out of reach (the keyboard's marks cannot be read then).
    @discardableResult
    public static func keepDelivered(_ text: String, image: ClipboardImage? = nil, types: [String], tappedChangeCount: Int?, deliveredChangeCount: Int,
                                     settings: Settings, history: ClipboardHistory, seen: ClipboardSeenStore?,
                                     route: ClipboardRoute = .saved, now: Date = Date()) -> Outcome {
        guard settings.enabled else { return .off }
        guard let seen else { return .failed }
        let count = tappedChangeCount ?? deliveredChangeCount
        let isPrivate = seen.secretFieldOpen || seen.privateChangeCount == count || seen.privateChangeCount == deliveredChangeCount
        let skip = ClipboardPolicy.skipBeforeReading(types: types, field: isPrivate ? .secret : .ordinary, skipsSecrets: settings.skipsSecrets)
        guard count == deliveredChangeCount else { return skip.map(Outcome.skipped) ?? .changedSinceLook }
        if let reason = skip {
            if reason != .own, seen.seenChangeCount != count { history.noteSkip(reason) }
            seen.seenChangeCount = count
            return .skipped(reason)
        }
        return add(text, image: image, settings: settings, history: history, seen: seen, changeCount: count, route: route, now: now)
    }

    /// `keepDelivered` for one paste's own token (`ClipboardPasteToken`), taken at its tap.
    @discardableResult
    public static func keepDelivered(_ text: String, image: ClipboardImage? = nil, types: [String], token: ClipboardPasteToken, deliveredChangeCount: Int,
                                     settings: Settings, history: ClipboardHistory, seen: ClipboardSeenStore?,
                                     route: ClipboardRoute = .saved, now: Date = Date()) -> Outcome {
        keepDelivered(text, image: image, types: types, tappedChangeCount: token.changeCount, deliveredChangeCount: deliveredChangeCount,
                      settings: settings, history: history, seen: seen, route: route, now: now)
    }
}

#if os(iOS)
import UIKit
import UniformTypeIdentifiers

public final class SystemClipboard: AutomaticClipboardSource {
    // A synchronous pasteboard XPC can stall even when it only requests the change count.
    // One serial lane contains that stall. ClipboardCapture coalesces timer and notification probes.
    private nonisolated static let queue = DispatchQueue(label: "wtf.zayd.zone.clipboard-reader", qos: .utility)
    private let pasteboard: @Sendable () -> UIPasteboard

    public init() { pasteboard = { UIPasteboard.general } }
    init(pasteboard: @escaping @Sendable () -> UIPasteboard) { self.pasteboard = pasteboard }

    public var changeCount: Int { UIPasteboard.general.changeCount }
    public var hasText: Bool { Self.hasSupportedContent(UIPasteboard.general) }
    private nonisolated static func hasSupportedContent(_ board: UIPasteboard) -> Bool {
        board.hasImages || board.hasStrings || board.hasURLs || board.contains(pasteboardTypes: [UTType.rtf.identifier], inItemSet: nil)
    }

    public var types: [String] { UIPasteboard.general.types(forItemSet: nil)?.flatMap { $0 } ?? [] }

    public func inspectAvailability(reusing cached: AutomaticClipboardSnapshot?, allowed: @escaping @Sendable () -> Bool, _ done: @escaping @MainActor @Sendable (AutomaticClipboardSnapshot?) -> Void) {
        let pasteboard = self.pasteboard
        Self.queue.async {
            guard allowed() else { Task { @MainActor in done(nil) }; return }
            let board = pasteboard()
            let snapshot = AutomaticClipboardSnapshot.availability(reusing: cached, allowed: allowed,
                changeCount: { board.changeCount }, hasContent: { Self.hasSupportedContent(board) })
            Task { @MainActor in done(snapshot) }
        }
    }

    public func inspect(ignoring known: Int?, allowed: @escaping @Sendable () -> Bool, _ done: @escaping @MainActor @Sendable (AutomaticClipboardSnapshot?) -> Void) {
        let pasteboard = self.pasteboard
        Self.queue.async {
            guard allowed() else { Task { @MainActor in done(nil) }; return }
            let board = pasteboard()
            guard allowed() else { Task { @MainActor in done(nil) }; return }
            let count = board.changeCount
            var result: AutomaticClipboardSnapshot?
            if count != known, allowed() {
                let types = board.types(forItemSet: nil)?.flatMap { $0 } ?? []
                let hasContent = board.hasStrings || board.hasURLs || board.hasImages || types.contains(UTType.rtf.identifier)
                if board.changeCount == count { result = .init(count: count, hasContent: hasContent, types: types) }
            }
            Task { @MainActor [result] in done(result) }
        }
    }

    public func readCopy(for count: Int, skipsSecrets: Bool, allowed: @escaping @Sendable () -> Bool,
                         _ done: @escaping @MainActor @Sendable (Int, AutomaticClipboardValue?) -> Void) {
        let pasteboard = self.pasteboard
        Self.queue.async {
            guard allowed() else { Task { @MainActor in done(count, nil) }; return }
            let board = pasteboard()
            guard allowed(), board.changeCount == count, allowed() else { Task { @MainActor in done(count, nil) }; return }
            let providers = board.itemProviders
            let types = providers.flatMap(\.registeredTypeIdentifiers)
            guard allowed(), board.changeCount == count, allowed(),
                  ClipboardPolicy.skipBeforeReading(types: types, field: .ordinary, skipsSecrets: skipsSecrets) == nil else {
                Task { @MainActor in done(count, nil) }
                return
            }
            let finish: @Sendable (AutomaticClipboardValue?) -> Void = { value in
                Self.queue.async {
                    guard allowed() else { Task { @MainActor in done(count, nil) }; return }
                    let delivered = board.changeCount
                    let current = delivered == count && allowed() ? value : nil
                    Task { @MainActor in done(delivered, current) }
                }
            }
            ClipboardPasteText.loadCopy(from: providers, includeImages: true, allowed: allowed, then: finish)
        }
    }
}
#endif
