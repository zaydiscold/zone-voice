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

    init(engine: SpeechEngine? = nil) {
        #if DEBUG && targetEnvironment(simulator)
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-zoneSeedKeyboardRequest"),
           let next = ProcessInfo.processInfo.arguments.dropFirst(index + 1).first,
           let id = UUID(uuidString: next) {
            let store = UserDefaultsSharedStore()
            let generation = store.ledger.droppedGeneration + 1
            store.request = DictationRequest(id: id, generation: generation, createdAt: Date(), inputSession: nil, contextBefore: nil)
            store.status = DictationStatus(requestID: id, generation: generation, phase: .requested, updatedAt: Date(), message: nil)
        }
        #endif
        PressTiming.mark("graph")
        _ = ParakeetEngine.Model.initialMigration
        Task.detached(priority: .utility) { SharedMiniModel.sweepRecordings() }
        let settings = AppSettings()
        self.settings = settings
        // Read before anything can finish setup: a launch that begins in setup is a fresh install.
        whatsNew = WhatsNewGate(setupFinished: settings.hasCompletedOnboarding)
        PressTiming.mark("coordinator")
        #if DEBUG
        let coordinator = DictationCoordinator(settings: settings, engine: engine ?? ScriptedSpeech.engineIfRequested())
        #else
        let coordinator = DictationCoordinator(settings: settings)
        #endif
        PressTiming.mark("coordinatorDone")
        self.coordinator = coordinator
        coordinator.publishMicrophoneGrant()
        let meetings = MeetingCoordinator(dictation: coordinator)
        self.meetings = meetings
        link = LinkCoordinator(notes: coordinator.notes, meetings: meetings)
        PhoneNoteBridge.shared.start(importNote: { envelope in
            try coordinator.notes.importWatch(envelope)
        }, exportNotes: {
            try coordinator.notes.backupNotes().map {
                CompanionShareItem(id: $0.id, text: $0.text, createdAt: $0.createdAt)
            }
        })
        MetricsRecorder.shared.start()
        // Starts the rating prompt's two-day clock on the first launch that has it.
        PressTiming.mark("graphDone")
        coordinator.reviews.noteLaunch()
        // A dictation left in progress by a crash or a kill becomes a cut-off history record.
        DictationCoordinator.history {
            _ = $0.recoverCutOff(activeWindow: 0, pausedWindow: 0)
            $0.purgeExpired()
        }
        coordinator.refreshStats()
    }

    func open(_ url: URL) {
        guard !LinkPairingLink.isPairingURL(url) else { return }
        // A URL opens a specific task in Zone.
        AppEntry.noteAutomation("url:\(url.host ?? "")")
        if url.host == "meeting" {
            if meetings.isRecording { meetings.showsRecorder = true }
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
    @ObservationIgnored private var pendingURL: URL?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    #if DEBUG
    private var holdsFirstForeground = ProcessInfo.processInfo.arguments.contains("-zoneShowUnlockScreen")
    #endif

    init(probe: ProtectedDataProbe = .standard) {
        _ = DictationCoordinator.processStart // Starts the app clock before settings and model checks.
        #if DEBUG
        // `-ZoneLockedLaunch`: the probe answers locked, as before the first unlock, so the
        // simulator can show that the wait ends on Home when Zone comes to the screen.
        let pretendsLocked = ProcessInfo.processInfo.arguments.contains("-ZoneLockedLaunch") || ProcessInfo.processInfo.arguments.contains("-zoneShowUnlockScreen")
        #else
        let pretendsLocked = false
        #endif
        var firstProbe = true
        gate = UnlockGate(isAvailable: {
            defer { firstProbe = false }
            return !(pretendsLocked && firstProbe) && probe.isAvailable()
        }, build: { AppGraph() })
        graph = gate.value
        Self.current = self
        guard graph == nil else {
            ZoneIntentHost.restoreNoteFailure()
            return
        }
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
                MainActor.assumeIsolated { self?.onScreen(trigger: "active") }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onScreen(trigger: "foreground") }
            },
        ]
        #if DEBUG
        if holdsFirstForeground {
            observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.holdsFirstForeground = false }
            })
        }
        #endif
    }

    func onScreen(trigger: String) {
        #if DEBUG
        if holdsFirstForeground { return }
        #endif
        check(trigger: trigger)
    }

    /// Builds if the probe says the files can be read now.
    func check(trigger: String) {
        guard graph == nil, gate.check() != nil else { return }
        adopt(trigger: trigger)
    }

    func open(_ url: URL) {
        pendingURL = url
        check(trigger: "url")
        openPendingURL()
    }

    private func openPendingURL() {
        guard let graph, let url = pendingURL else { return }
        pendingURL = nil
        graph.open(url)
    }

    /// An intent (the Action Button, a control, the island) is about to look for Zone. A
    /// suspended process can miss the unlock notification, so check before it does.
    static func wake(trigger: String) {
        current?.check(trigger: trigger)
    }

    static func wakeForRecording(trigger: String) throws {
        wake(trigger: trigger)
        if let current, current.graph == nil {
            throw DictationCoordinator.ShortcutFailure(message: "Unlock your iPhone, then press again.")
        }
    }

    /// What an intent says when it finds no Zone: still locked since the restart, or never set up.
    static func missingMessage(otherwise: String) -> String {
        if let current, current.graph == nil { return "Unlock your iPhone, then press again." }
        return otherwise
    }

    private func adopt(trigger: String) {
        graph = gate.value
        openPendingURL()
        ZoneIntentHost.restoreNoteFailure()
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
            .overlay {
                VStack(spacing: 12) {
                    Text("zone").font(.zoneWordmark)
                    Label("Unlock your iPhone once to open Zone.", systemImage: "lock").font(.body)
                }.padding()
            }
            .onAppear { if scenePhase == .active { onScreen() } }
            .onChange(of: scenePhase) { _, phase in if phase == .active { onScreen() } }
    }
}
