// by zayd/cold @ zayd.wtf

import Observation
import SwiftUI
import UIKit
import ZoneCore

/// Who opened Zone. Everything that brings Zone forward, or drives it, without the person
/// tapping its icon reports here: the keyboard's dictate link and its requests, pairing and
/// Live Activity links, Shortcuts, the Action Button, controls and widgets. What's New reads
/// it to stay out of the way of all of them (see `WhatsNewPolicy`).
@MainActor
enum AppEntry {
    /// System uptime of the last such event. Uptime, not the clock: it cannot jump.
    private(set) static var lastAutomationAt: TimeInterval?
    /// What it was, for the recording log.
    private(set) static var lastAutomationSource: String?

    static func noteAutomation(_ source: String) {
        lastAutomationAt = ProcessInfo.processInfo.systemUptime
        lastAutomationSource = source
    }
}

/// Shows a version's notes once after an update, and only to someone who opened Zone
/// themselves and is looking at an idle Home.
///
/// At launch it works out whether notes are owed (`WhatsNewPolicy.launch`). RootView then asks
/// `mayPresent` whenever what is on screen changes; the answer is yes only at the start of a
/// visit the person began. A visit begins when Zone comes forward from the background. If the
/// keyboard, a link, a Shortcut or a control opened Zone, or a recording is running, the notes
/// stay owed and wait for the next visit.
@MainActor
@Observable
final class WhatsNewGate {
    /// Every version's notes, newest first, and the version this copy of Zone is.
    let library: ReleaseNotesLibrary
    let installed: AppVersion?
    /// The build number, shown small on the history screen.
    let build: String
    /// The notes owed since the last update. Nil once shown, and when nothing is owed.
    private(set) var owed: ReleaseNote?
    /// The notes on screen as the What's New sheet.
    var presented: ReleaseNote?
    /// Bumped each time Zone comes forward from the background.
    private(set) var visit = 0
    /// Home is the top screen of its stack. HomeView keeps this current.
    var homeInFront = false
    /// Zone's own keyboard is up: the person is typing.
    private(set) var typing = false
    /// Home has nothing left to set up and shows its Transcribe page. HomeView keeps this current.
    var homeReadyForNote = false
    /// The word milestone note on Home this visit (`WordMilestones`). It comes up at most once
    /// per mark, at the start of a visit the person began, and goes when it is closed or
    /// answered, or when Zone goes to the background.
    private(set) var milestone: MilestoneNote?

    @ObservationIgnored private let store: WhatsNewStore
    @ObservationIgnored private var visitOpenedAt: TimeInterval = 0
    @ObservationIgnored private var wasInBackground = true
    @ObservationIgnored private var loggedWait = false
    @ObservationIgnored private var keyboardObservers: [NSObjectProtocol] = []
    /// The word count when this visit began; a mark passed after it waits for the next visit.
    @ObservationIgnored private var wordsAtVisitStart = 0
    /// The visit What's New opened in, so the milestone note never shares it.
    @ObservationIgnored private var whatsNewVisit: Int?

    init(setupFinished: Bool, store: WhatsNewStore = WhatsNewStore(), bundle: Bundle = .main) {
        self.store = store
        let info = bundle.infoDictionary ?? [:]
        var version = info["CFBundleShortVersionString"] as? String ?? ""
        build = info["CFBundleVersion"] as? String ?? ""
        #if DEBUG
        WhatsNewDebug.prepare(store: store)
        if let pretend = WhatsNewDebug.version { version = pretend }
        #endif
        installed = AppVersion(version)
        let folder = bundle.resourceURL?.appendingPathComponent("ReleaseNotes", isDirectory: true)
        let loaded = folder.map { ReleaseNotesLibrary.load(folder: $0) }
            ?? (library: ReleaseNotesLibrary([]), problems: ["no ReleaseNotes folder in the bundle"])
        library = loaded.library
        for problem in loaded.problems { ZoneLog.coordinator.error("release notes: \(problem, privacy: .public)") }

        let result = WhatsNewPolicy.launch(store.state, installed: installed, setupFinished: setupFinished, library: library)
        store.state = result.state
        owed = library.note(for: result.owed)

        let center = NotificationCenter.default
        keyboardObservers = [
            center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.typing = true }
            },
            center.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.typing = false }
            },
        ]
    }

    /// The versions the history screen lists: this one and everything before it.
    var history: [ReleaseNote] { library.history(installed: installed) }

    /// Scene phase from the root view. Only a return from the background starts a visit, so a
    /// Control Center or notification bounce never counts as opening Zone.
    /// - Parameter words: the running word count, kept as the visit's starting count.
    func scenePhaseChanged(_ phase: ScenePhase, words: Int) {
        switch phase {
        case .background:
            wasInBackground = true
            milestone = nil
        case .active:
            guard wasInBackground else { return }
            wasInBackground = false
            visitOpenedAt = ProcessInfo.processInfo.systemUptime
            wordsAtVisitStart = words
            visit += 1
        default:
            break
        }
    }

    /// Seconds until the sheet could first open in this visit, for the caller's wait.
    var settleRemaining: TimeInterval { remaining(until: WhatsNewPolicy.settle) }

    /// Seconds until the milestone note could first come up in this visit.
    var milestoneSettleRemaining: TimeInterval { remaining(until: WordMilestones.settle) }

    private func remaining(until settle: TimeInterval) -> TimeInterval {
        max(0, settle - (ProcessInfo.processInfo.systemUptime - visitOpenedAt))
    }

    /// Fills in the parts of the moment this gate keeps: how long ago the visit began, and
    /// whether something other than the person opened or drove Zone around it.
    func moment(_ base: WhatsNewMoment) -> WhatsNewMoment {
        var moment = base
        moment.homeInFront = homeInFront
        moment.typing = typing
        moment.sinceOpened = visit == 0 ? 0 : ProcessInfo.processInfo.systemUptime - visitOpenedAt
        moment.automationBeforeOpen = AppEntry.lastAutomationAt.map { visitOpenedAt - $0 }
        return moment
    }

    /// Opens the sheet if notes are owed and this moment allows it. The version is recorded as
    /// shown at once, so a crash or a kill with the sheet up never shows it twice.
    @discardableResult
    func presentIfAllowed(_ base: WhatsNewMoment) -> Bool {
        guard let note = owed, presented == nil else { return false }
        let moment = moment(base)
        if !WhatsNewPolicy.openedByPerson(moment), !loggedWait {
            // Once per launch, so the recording log can answer "why did I not see What's New?"
            // without filling up on days when only the keyboard opens Zone.
            loggedWait = true
            Journal.log("whatsNewWaits", ["version": note.version.description,
                "openedBy": AppEntry.lastAutomationSource ?? "unknown",
                "secondsBeforeOpen": moment.automationBeforeOpen.map { String(format: "%.2f", $0) } ?? "none"])
        }
        guard WhatsNewPolicy.mayPresent(moment) else { return false }
        store.settle(note.version)
        owed = nil
        presented = note
        whatsNewVisit = visit
        Journal.log("whatsNewShown", ["version": note.version.description])
        return true
    }
}

extension WhatsNewGate {
    /// Puts `pending` on Home if this moment allows it (`WordMilestones.mayShow`) and returns
    /// it; the caller then records the mark, so a crash or a kill never shows it twice.
    @discardableResult
    func offerMilestone(_ pending: MilestoneNote?, _ base: WhatsNewMoment) -> MilestoneNote? {
        guard let pending, milestone == nil, owed == nil, presented == nil, homeReadyForNote else { return nil }
        guard WordMilestones.mayShow(mark: pending.mark, moment: moment(base), wordsAtVisitStart: wordsAtVisitStart,
                                     whatsNewThisVisit: whatsNewVisit == visit) else { return nil }
        milestone = pending
        Journal.log("milestoneShown", ["mark": String(pending.mark)])
        return pending
    }

    /// Closed, or answered with Tell Zayd.
    func putAwayMilestone() {
        milestone = nil
    }

    #if DEBUG
    /// Design review and UI tests: `-zoneMilestone 10000` puts that mark's note on Home at once.
    func forceMilestone(_ note: MilestoneNote) {
        milestone = note
    }
    #endif
}

extension UIApplication {
    /// True while a sheet, a full-screen cover, an alert or a share sheet is up in any of
    /// Zone's windows.
    @MainActor var showsPresentation: Bool {
        connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            .contains { $0.rootViewController?.presentedViewController != nil }
    }
}

#if DEBUG
/// Development builds only: drive the version screens without waiting for a real update.
///
/// - `-zoneVersion 1.0.4` makes Zone act as that marketing version (the history lists up to
///   it, and its notes are the ones owed).
/// - `-zoneWhatsNewAfter 1.0.3` rewrites the record as if that version's notes were the last
///   ones seen, so the installed version reads as an update.
/// - `-zoneWhatsNewForget` deletes the record, as on the first launch that keeps one.
/// - `-zoneWhatsNewIntent` performs the Voice note intent a moment after launch, the way the
///   Action Button does, to check that What's New stays away. `-zoneWhatsNewClipIntent` does
///   the same with the Send to Computer intent.
enum WhatsNewDebug {
    private static func value(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static var version: String? { value("-zoneVersion") }

    static func prepare(store: WhatsNewStore) {
        if ProcessInfo.processInfo.arguments.contains("-zoneWhatsNewForget") { store.state = nil }
        if let last = value("-zoneWhatsNewAfter") { store.state = WhatsNewState(settled: [last], newest: last) }
    }

    @MainActor static func runIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-zoneWhatsNewIntent") {
            try? await Task.sleep(for: .milliseconds(300))
            // The simulator has no model and no Live Activity, so the press itself fails; what
            // matters is that it went through the door every Shortcut and control uses.
            _ = try? await DictateNoteIntent().perform()
        }
        if arguments.contains("-zoneWhatsNewClipIntent") {
            try? await Task.sleep(for: .milliseconds(300))
            // With no computer paired it answers "Pair a computer first", after the same door.
            _ = try? await SendToComputerIntent.send("What's New check")
        }
    }
}
#endif
