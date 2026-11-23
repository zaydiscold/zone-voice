// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// Everything Zone builds at launch. Built once, and only once its files can be read
/// (`AppLaunch`): every object here reads preferences or the library when it is made.
@MainActor
final class AppGraph {
    let settings: AppSettings
    let coordinator: DictationCoordinator
    let meetings: MeetingCoordinator
    let link: LinkCoordinator
    let whatsNew: WhatsNewGate

    init() {
        let settings = AppSettings()
        self.settings = settings
        // Read before anything can finish setup: a launch that begins in setup is a fresh install.
        whatsNew = WhatsNewGate(setupFinished: settings.hasCompletedOnboarding)
        #if DEBUG
        let coordinator = DictationCoordinator(settings: settings, engine: ScriptedSpeech.engineIfRequested())
        #else
        let coordinator = DictationCoordinator(settings: settings)
        #endif
        self.coordinator = coordinator
        let meetings = MeetingCoordinator(dictation: coordinator)
        self.meetings = meetings
        link = LinkCoordinator(notes: coordinator.notes, meetings: meetings)
        PhoneNoteBridge.shared.start(importNote: { envelope in
            _ = try coordinator.notes.importBackup([
                LibraryNote(id: envelope.id, text: envelope.text, createdAt: envelope.createdAt)
            ])
        }, exportNotes: {
            try coordinator.notes.backupNotes().map {
                CompanionShareItem(id: $0.id, text: $0.text, createdAt: $0.createdAt)
            }
        })
        MetricsRecorder.shared.start()
        // Starts the rating prompt's two-day clock on the first launch that has it.
        coordinator.reviews.noteLaunch()
        // A dictation left in progress by a crash or a kill becomes a cut-off history record.
        DictationCoordinator.history {
            _ = $0.recoverCutOff(activeWindow: 0, pausedWindow: 0)
            $0.purgeExpired()
        }
        // Once ever: the longest dictation from history saved before the record existed. On the
        // history queue, after the cut-off recovery so those count, and only the one small
        // result comes back to the main actor.
        if settings.needsLongestBackfill {
            DictationCoordinator.history { history in
                let found = DictationStats.longest(in: history.records())
                Task { @MainActor in settings.backfillLongest(historyLongest: found) }
            }
        }
    }

    func open(_ url: URL) {
        // The keyboard's dictate link, a Live Activity tap, a pairing link: none of them is the
        // person opening Zone to look around.
        AppEntry.noteAutomation("url:\(url.host ?? "")")
        if url.host == "meeting" {
            if meetings.isRecording { meetings.showsRecorder = true }
        } else if LinkPairingLink.isPairingURL(url) {
            // A pairing link from outside only asks the question. See LinkCoordinator.
            link.offerPairing(url.absoluteString)
        } else {
            coordinator.handle(url: url)
        }
    }
}

/// Builds `AppGraph` once the phone has been unlocked since it started.
///
/// After a restart iOS can start Zone in the background before the first unlock. Its
/// preferences then read as missing, and a Zone built then ran on the defaults for the whole
/// life of the process: violet everywhere, the Chime cue, the first-run model, What's New and
/// the review clock treating it as a fresh install, and the keyboard's settings record
/// republished as defaults (Zayd's phone, 2026-11-19). Now such a process waits, and builds
/// when the phone is unlocked, when Zone comes to the screen, or when a link opens it.
@MainActor
@Observable
final class AppLaunch {
    private(set) var graph: AppGraph?
    /// The one launch, for intents: they run in this process and find Zone through statics.
    @ObservationIgnored private(set) static weak var current: AppLaunch?
    @ObservationIgnored private let gate: UnlockGate<AppGraph>
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(probe: ProtectedDataProbe = .standard) {
        #if DEBUG
        // `-ZoneLockedLaunch`: the probe answers locked, as before the first unlock, so the
        // simulator can show that the wait ends on Home when Zone comes to the screen.
        let pretendsLocked = ProcessInfo.processInfo.arguments.contains("-ZoneLockedLaunch")
        #else
        let pretendsLocked = false
        #endif
        gate = UnlockGate(isAvailable: { !pretendsLocked && probe.isAvailable() }, build: { AppGraph() })
        graph = gate.value
        Self.current = self
        guard graph == nil else { return }
        // Nothing may be logged here: the recording log is one of the locked files.
        ZoneLog.coordinator.notice("launched before the first unlock: waiting to build Zone")
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check(trigger: "unlock") }
            },
            // A suspended process misses the unlock notification; the next wake checks again.
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.force(trigger: "active") }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.force(trigger: "foreground") }
            },
        ]
    }

    /// Builds if the probe says the files can be read now.
    func check(trigger: String) {
        guard graph == nil, gate.check() != nil else { return }
        adopt(trigger: trigger)
    }

    /// Zone is on screen or a link opened it: the phone is unlocked, so build now.
    @discardableResult
    func force(trigger: String) -> AppGraph {
        if let graph { return graph }
        let built = gate.force()
        adopt(trigger: trigger)
        return built
    }

    /// An intent (the Action Button, a control, the island) is about to look for Zone. A
    /// suspended process can miss the unlock notification, so check before it does.
    static func wake(trigger: String) {
        current?.check(trigger: trigger)
    }

    /// What an intent says when it finds no Zone: still locked since the restart, or never set up.
    static func missingMessage(otherwise: String) -> String {
        if let current, current.graph == nil { return "Unlock your iPhone, then press again." }
        return otherwise
    }

    private func adopt(trigger: String) {
        graph = gate.value
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        let waited = gate.waitedSince.map { String(Int(Date().timeIntervalSince($0).rounded())) } ?? "0"
        Journal.log("launchWaitedForUnlock", ["trigger": trigger, "waitedSeconds": waited])
    }
}

/// What a Zone started before the first unlock shows if it reaches the screen before it has
/// built: a plain background, for the moment it takes to build.
struct WaitingForUnlockView: View {
    @Environment(\.scenePhase) private var scenePhase
    let onScreen: () -> Void

    var body: some View {
        Color(uiColor: .systemBackground)
            .ignoresSafeArea()
            .onAppear { if scenePhase == .active { onScreen() } }
            .onChange(of: scenePhase) { _, phase in if phase == .active { onScreen() } }
    }
}
