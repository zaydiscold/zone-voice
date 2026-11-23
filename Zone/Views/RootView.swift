// by zayd/cold @ zayd.wtf

import StoreKit
import SwiftUI
import ZoneCore

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(MeetingCoordinator.self) private var meetings
    @Environment(LinkCoordinator.self) private var link
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview
    /// "Not now" in the walkthrough hides it for this launch only; it returns on the next launch
    /// until the person finishes it.
    @State private var setupDeferred = false
    /// The tour opens once, the first time Home shows after setup (see TourView).
    @State private var showsTour = false
    /// The sun for every card's shadow, worked out on each activation (see SunShadowModifier).
    @State private var sun = SunShadow.now()
    /// Home's navigation stack, renewed to pop back to Home.
    @State private var homeStackID = UUID()
    /// A rating ask held back by the note card or the Note saved page: it is asked again when
    /// the page is closed and no note is under way (see `askForReview`).
    @State private var reviewOwedAfterNote = false
    @State private var reviewRetries = 0
    @Environment(WhatsNewGate.self) private var whatsNew: WhatsNewGate?

    var body: some View {
        @Bindable var coordinator = coordinator
        @Bindable var meetings = meetings
        Group {
            if settings.hasCompletedOnboarding || setupDeferred {
                // Stacked above, not a safe-area inset: Home draws its own header under a hidden
                // navigation bar, and an inset on the stack slid the strip over that header.
                VStack(spacing: 0) {
                    RecordingStrip()
                    // Room for the note card, which floats in its own window above this one.
                    Color.clear
                        .frame(height: coordinator.noteCard == nil ? 0 : NoteCardOverlay.shared.reservedHeight)
                        .background(Zone.paper(settings.appearance.colorScheme ?? systemScheme).ignoresSafeArea(edges: .top))
                        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: coordinator.noteCard == nil)
                        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: NoteCardOverlay.shared.reservedHeight)
                    NavigationStack {
                        HomeView(resumeSetup: settings.hasCompletedOnboarding ? nil : { setupDeferred = false })
                    }
                    // A new identity pops whatever was pushed over Home, for Added to Notes.
                    .id(homeStackID)
                }
            } else {
                OnboardingView(onLater: { setupDeferred = true })
            }
        }
        // The Note saved page sits in Zone's own view tree rather than presenting over it, so
        // nothing it does can block a screen that must present (the keyboard's dictation
        // screen, a meeting) and nothing presented can block it from closing.
        .overlay {
            if let page = coordinator.notePage {
                NoteSavedPage(page: page)
                    .id(page.noteID)
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.9), value: coordinator.notePage?.noteID)
        // The note card has a window of its own above this one (NoteCardWindow).
        .background(NoteCardWindowInstaller(coordinator: coordinator, settings: settings))
        .onChange(of: coordinator.noteReveal) { _, reveal in
            // Added to Notes from a screen pushed over Home: back to Home first.
            guard reveal != nil, whatsNew?.homeInFront == false else { return }
            homeStackID = UUID()
        }
        .tint(Zone.accentText(settings.appearance.colorScheme ?? systemScheme))
        .preferredColorScheme(settings.appearance.colorScheme)
        .onAppear { AccentStore.shared.applyToWindows() }
        .fullScreenCover(isPresented: $coordinator.showsDictationScreen) {
            DictationView()
                .preferredColorScheme(settings.appearance.colorScheme)
        }
        .fullScreenCover(isPresented: $meetings.showsRecorder) {
            MeetingRecorderView()
                .preferredColorScheme(settings.appearance.colorScheme)
        }
        .sheet(isPresented: $showsTour) {
            TourView()
                .preferredColorScheme(settings.appearance.colorScheme)
        }
        .task(id: settings.hasCompletedOnboarding) { await offerTour() }
        .onReceive(NotificationCenter.default.publisher(for: DictateIntent.requested)) { _ in
            _ = DictateIntent.takePendingRequest()
            coordinator.beginShortcutDictation()
        }
        .onReceive(NotificationCenter.default.publisher(for: DictateNoteIntent.requested)) { _ in
            _ = DictateNoteIntent.takePendingRequest()
            coordinator.beginNoteDictation()
        }
        .onAppear {
            coordinator.scenePhaseChanged(scenePhase)
            link.scenePhaseChanged(active: scenePhase == .active)
            if DictateNoteIntent.takePendingRequest() {
                coordinator.beginNoteDictation()
            } else if DictateIntent.takePendingRequest() {
                coordinator.beginShortcutDictation()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            coordinator.scenePhaseChanged(phase)
            if phase != .inactive { meetings.scenePhaseChanged(active: phase == .active) }
            link.scenePhaseChanged(active: phase == .active)
            if phase == .active {
                let now = SunShadow.now()
                if now != sun { sun = now }
            }
        }
        .environment(\.sunShadow, sun)
        .task {
            // The light moves while the app stays open: sunset, moonrise. Five minutes moves a
            // shadow by a fraction of a point.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                let now = SunShadow.now()
                if now != sun { sun = now }
            }
        }
        .modifier(LibraryBackupAutosave())
        .task(id: coordinator.reviews.askRequests) { await askForReview() }
        .task(id: reviewRetries) { if reviewRetries > 0 { await askForReview() } }
        .onChange(of: coordinator.notePage == nil && coordinator.noteCard == nil) { _, clear in
            guard clear, reviewOwedAfterNote else { return }
            reviewOwedAfterNote = false
            reviewRetries += 1
        }
        .modifier(LinkPairingPrompts())
        .modifier(WhatsNewPresenter(tourIsUp: showsTour))
        .modifier(QuickActionHandler())
    }
}

extension RootView {
    /// After setup, once: never over a dictation or note a shortcut just opened, and never again
    /// after it has been shown, finished or skipped.
    @MainActor
    fileprivate func offerTour() async {
        guard settings.hasCompletedOnboarding,
              !UserDefaults.standard.bool(forKey: TourView.seenKey) else { return }
        try? await Task.sleep(for: .milliseconds(600))
        guard !coordinator.showsDictationScreen, coordinator.noteCard == nil, coordinator.notePage == nil,
              !meetings.showsRecorder else { return }
        showsTour = true
    }

    /// Apple's rating prompt after a dictation, note or meeting finished well on screen. A short
    /// pause lets the words land first; then everything is checked again, because a new
    /// recording, an error or leaving Zone in that pause each cancel the ask, and so do the Send
    /// feedback screen and the milestone note on Home: someone being asked how it is going is
    /// not asked for stars in the same breath. After a note the ask waits for the Note saved
    /// page to close. iOS decides whether the prompt appears.
    @MainActor
    fileprivate func askForReview() async {
        guard coordinator.reviews.askRequests > 0 else { return }
        try? await Task.sleep(for: .seconds(1.5))
        guard !Task.isCancelled, scenePhase == .active, UIApplication.shared.applicationState == .active,
              !showsTour, !FeedbackSession.isOpen, whatsNew?.milestone == nil else { return }
        // Never over a note: the Note saved page is where the person edits, deletes or presses
        // for the next note, and a run of notes must not be interrupted. Asked when it closes.
        if coordinator.notePage != nil || coordinator.noteCard != nil {
            reviewOwedAfterNote = true
            return
        }
        var failed = false
        if case .failed = coordinator.activity { failed = true }
        let isRecording = coordinator.activity.isBusy || coordinator.retryingAudioID != nil || meetings.isRecording
        let showsError = failed || coordinator.audioRecoveryWarning != nil || coordinator.holdNotice != nil
            || coordinator.autoStopNotice != nil || meetings.lastError != nil || meetings.recordingWarning != nil
        guard coordinator.reviews.claimAsk(isRecording: isRecording, showsError: showsError) else { return }
        requestReview()
    }
}

/// While a hidden keyboard or Shortcut dictation runs, a strip across the top of every page: what
/// is happening, for how long, the way back to the recording screen (tap anywhere) and the
/// checkmark to finish without going back. The keyboard's vocabulary again, on the app's card
/// surface. A note has its own, larger card (NoteCard) instead.
struct RecordingStrip: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if coordinator.hasRecordingScreen, !coordinator.showsDictationScreen {
                strip
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                    .background(Zone.paper(scheme).ignoresSafeArea(edges: .top))
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Zone.motion, value: coordinator.hasRecordingScreen)
        .animation(Zone.motion, value: coordinator.showsDictationScreen)
    }

    private var strip: some View {
        let shape = Zone.cardShape
        return HStack(spacing: 12) {
            Button { coordinator.showRecordingScreen() } label: {
                HStack(spacing: 10) {
                    StatusDot(color: Zone.accentGraphic, pulses: true)
                    label
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Zone.ink(scheme))
                        .contentTransition(.numericText())
                    Spacer(minLength: 8)
                    Text("Open").font(.footnote.weight(.medium)).foregroundStyle(Zone.accentText(scheme))
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the recording screen")
            if case .recording = coordinator.activity {
                RoundAction(symbol: "checkmark", label: "Stop and keep the words", prominent: true, diameter: 36) {
                    Task { await coordinator.stopDictation() }
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background { shape.fill(Zone.card(scheme)).sunShadow(scale: 0.8) }
        .overlay(shape.strokeBorder(Zone.accentGraphic.opacity(0.45), lineWidth: 1))
    }

    @ViewBuilder
    private var label: some View {
        switch coordinator.activity {
        case .recording(_, let startedAt):
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                let title = coordinator.showsPaused ? "Paused" : "Listening"
                Text("\(title) · \(context.date.timeIntervalSince(startedAt).countdownLabel)")
            }
        default:
            Text("Recognizing")
        }
    }
}
