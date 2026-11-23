// by zayd/cold @ zayd.wtf

import Foundation

/// What Zone remembers so a version's notes are offered once: which marketing versions are
/// settled, and the newest version this copy has run. One JSON record, replaced whole.
public struct WhatsNewState: Codable, Equatable, Sendable {
    /// Marketing versions whose notes were shown, or that never owed any (the version of a
    /// fresh install). Build numbers are not kept: a new TestFlight build of the same version
    /// does not show its notes again.
    public var settled: [String]
    /// The newest marketing version this copy of Zone has run.
    public var newest: String?

    public init(settled: [String] = [], newest: String? = nil) {
        self.settled = settled
        self.newest = newest
    }

    public func isSettled(_ version: AppVersion) -> Bool {
        settled.contains { AppVersion($0) == version }
    }

    public mutating func settle(_ version: AppVersion) {
        if !isSettled(version) { settled.append(version.description) }
        if let known = newest.flatMap(AppVersion.init), known >= version { return }
        newest = version.description
    }
}

/// Everything about one moment that decides whether the What's New sheet may open. The app
/// fills it in; `WhatsNewPolicy.mayPresent` answers.
public struct WhatsNewMoment: Equatable, Sendable {
    /// The setup walkthrough is finished (not merely put off with "Not now").
    public var setupFinished = false
    /// Zone is the active app.
    public var sceneActive = false
    /// Home is the screen on top: nothing is pushed over it.
    public var homeInFront = false
    /// A sheet, a full-screen cover, an alert or the tour is up.
    public var somethingPresented = false
    /// A dictation, a note or a meeting is recording, being recognized, starting, or getting the
    /// microphone ready, or one of the recording screens is up.
    public var recording = false
    /// An error or a warning is on screen.
    public var showsError = false
    /// The person is typing in Zone (its keyboard is up).
    public var typing = false
    /// Seconds since this visit began: since Zone last came to the front from the background.
    public var sinceOpened: TimeInterval = 0
    /// Seconds between the last thing that opened or drove Zone without the person tapping its
    /// icon (the keyboard, a link, a Shortcut, the Action Button, a control, a Live Activity)
    /// and the start of this visit. Negative when it came after the visit began. Nil for never.
    public var automationBeforeOpen: TimeInterval?

    public init() {}
}

/// When a version's notes are owed, and when the sheet may open.
///
/// The sheet is for someone who opened Zone on their own and is looking at Home. The keyboard
/// opens Zone many times a day only to start the microphone, and Shortcuts, the Action Button,
/// controls and Live Activities open it to record. A sheet there would sit between the person
/// and their dictation, so every one of those visits is left alone and the notes wait for the
/// next time the person opens Zone themselves.
public enum WhatsNewPolicy {
    /// A visit counts as opened by something else when that something ran this long before it,
    /// or at any time after it began.
    public static let automationShadow: TimeInterval = 15
    /// The screen must hold still this long before the sheet opens, so a link or a Shortcut that
    /// arrives just after Zone comes forward is seen first.
    public static let settle: TimeInterval = 1.0
    /// The sheet only opens at the start of a visit. Past this, the person is doing something,
    /// and the notes wait for the next visit.
    public static let window: TimeInterval = 8

    /// At launch: brings the record up to date and says which version's notes are owed.
    ///
    /// - Parameters:
    ///   - state: the saved record; nil on the first launch that keeps one.
    ///   - installed: the app's marketing version; nil when the bundle has none readable.
    ///   - setupFinished: the setup walkthrough was already finished when this launch began.
    ///   - library: the bundled notes.
    /// - Returns: the record to save, and the version to show notes for (nil for none).
    public static func launch(_ state: WhatsNewState?, installed: AppVersion?, setupFinished: Bool,
                              library: ReleaseNotesLibrary) -> (state: WhatsNewState, owed: AppVersion?) {
        var next = state ?? WhatsNewState()
        guard let installed else { return (next, nil) }
        // Someone who has not finished setup has no "before" to compare with: a fresh install,
        // or an update that arrived before they ever used Zone. Nothing is new to them.
        guard setupFinished else {
            next.settle(installed)
            return (next, nil)
        }
        // An older version installed over a newer one (possible in TestFlight) is not an update.
        let known = next.newest.flatMap(AppVersion.init)
        if let known, installed < known { return (next, nil) }
        if known != installed { next.newest = installed.description }
        if next.isSettled(installed) { return (next, nil) }
        // A version without notes owes nothing. It stays unsettled, so the record never claims
        // notes were shown that did not exist.
        guard library.note(for: installed) != nil else { return (next, nil) }
        // Setup is finished and this version is not settled: an update. That includes the first
        // launch that keeps a record at all, by someone updating from a version that kept none.
        return (next, installed)
    }

    /// True when this visit was the person's own doing.
    public static func openedByPerson(_ moment: WhatsNewMoment) -> Bool {
        guard let gap = moment.automationBeforeOpen else { return true }
        return gap > automationShadow
    }

    /// True when the sheet may open right now.
    public static func mayPresent(_ moment: WhatsNewMoment) -> Bool {
        guard moment.setupFinished, moment.sceneActive, moment.homeInFront else { return false }
        guard !moment.somethingPresented, !moment.recording, !moment.showsError, !moment.typing else { return false }
        guard openedByPerson(moment) else { return false }
        return moment.sinceOpened >= settle && moment.sinceOpened <= window
    }
}

/// The What's New record in `UserDefaults`: the app's own, so it goes when Zone is deleted.
public final class WhatsNewStore {
    public static let key = "zone.whatsNew"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Nil until a launch has saved one.
    public var state: WhatsNewState? {
        get {
            guard let data = defaults.data(forKey: Self.key) else { return nil }
            return try? JSONDecoder().decode(WhatsNewState.self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: Self.key)
                return
            }
            defaults.set(data, forKey: Self.key)
        }
    }

    /// The notes for this version were shown.
    public func settle(_ version: AppVersion) {
        var next = state ?? WhatsNewState()
        next.settle(version)
        state = next
    }
}
