// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// The installed version's notes, shown once after an update (`WhatsNewGate` decides when).
/// A short list: one line per feature, then how many smaller changes there are. Read the full
/// notes opens the version's detailed page (the same one Settings > Version shows) inside the
/// sheet; Continue closes it; See all versions opens the history.
struct WhatsNewSheet: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    let note: ReleaseNote

    var body: some View {
        NavigationStack {
            ScrollView {
                WhatsNewHighlights(note: note)
                    .padding(.horizontal, 20)
                    .padding(.top, 28)
                    .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 2) {
                    Hairline()
                    Button("Continue") { dismiss() }
                        .buttonStyle(ZonePrimaryButtonStyle())
                        .padding(.top, 14)
                        .accessibilityIdentifier("whatsNew.continue")
                    NavigationLink("See all versions") {
                        VersionHistoryView(onDone: { dismiss() })
                    }
                    .buttonStyle(ZoneLinkButtonStyle())
                    .accessibilityIdentifier("whatsNew.allVersions")
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
                .background(Zone.paper(scheme))
            }
            // Never shown (the bar is hidden), but it names this page on the history's Back button.
            .navigationTitle("What's new")
            .zoneBackButton()
            .toolbar(.hidden, for: .navigationBar)
            .zoneScreen()
        }
        .tint(Zone.accentText(scheme))
        .accessibilityIdentifier("whatsNew.sheet")
    }
}

/// The sheet's list: the version, its summary, a line for each feature, and a way into the full notes.
private struct WhatsNewHighlights: View {
    @Environment(\.colorScheme) private var scheme
    let note: ReleaseNote

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow("What's new in Zone")
                HeroNumber(text: note.version.description)
                    .accessibilityLabel("Version \(note.version.description)")
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("releaseNotes.version")
                Text(note.summary)
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(Zone.ink(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(note.features.enumerated()), id: \.element.id) { index, feature in
                    if index > 0 { Hairline().padding(.leading, 52) }
                    WhatsNewLine(feature: feature)
                }
            }
            .zoneCard(padding: 16)

            NavigationLink {
                ReleaseNotesView(note: note)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Read the full notes")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Zone.ink(scheme))
                        Text(fullNotesDetail)
                            .font(.subheadline)
                            .foregroundStyle(Zone.muted(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Zone.muted(scheme))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .zoneCard(padding: 16)
            .accessibilityIdentifier("whatsNew.fullNotes")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Says what the full page adds: every feature in detail and, when there are any, the
    /// smaller changes the list leaves out.
    private var fullNotesDetail: String {
        switch note.fixes.count {
        case 0: "Every change in detail, and where to find it."
        case 1: "Every change in detail, plus 1 smaller fix."
        default: "Every change in detail, plus \(note.fixes.count) smaller fixes and improvements."
        }
    }
}

/// One feature as a line: its symbol, title, an optional label such as Beta, and one sentence.
private struct WhatsNewLine: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    let feature: ReleaseFeature

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if !typeSize.isAccessibilitySize {
                ReleaseSymbolTile(symbol: feature.symbol, side: 38)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(feature.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Zone.ink(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                    if let tag = feature.tag {
                        Text(tag.uppercased())
                            .font(.caption2.weight(.bold))
                            .tracking(0.5)
                            .foregroundStyle(Zone.accentText(scheme))
                            .fixedSize()
                            .accessibilityLabel(tag)
                    }
                }
                Text(feature.headline)
                    .font(.subheadline)
                    .foregroundStyle(Zone.muted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("whatsNew.line")
    }
}

/// Opens the What's New sheet over the root view when `WhatsNewGate` allows it.
///
/// It lives in its own modifier so the things it watches (whether a dictation is starting,
/// whether Home is in front) redraw only this, not the whole root view. Any change in them
/// restarts the short wait below, so the sheet opens only on a screen that has held still.
struct WhatsNewPresenter: ViewModifier {
    @Environment(AppSettings.self) private var settings
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(MeetingCoordinator.self) private var meetings
    @Environment(WhatsNewGate.self) private var gate
    @Environment(\.scenePhase) private var scenePhase
    /// The tour is up, or about to be.
    let tourIsUp: Bool

    private struct Watched: Equatable {
        var visit: Int
        var owed: Bool
        var milestoneOwed: Int?
        var homeReadyForNote: Bool
        var active: Bool
        var setupFinished: Bool
        var tourIsUp: Bool
        var recording: Bool
        var showsError: Bool
        var homeInFront: Bool
        var typing: Bool
    }

    private var recording: Bool {
        coordinator.isBusyForWhatsNew || meetings.isRecording || meetings.isStartingRecording || meetings.showsRecorder
    }

    private var showsError: Bool {
        coordinator.showsNotice || meetings.lastError != nil || meetings.recordingWarning != nil
    }

    private var watched: Watched {
        Watched(visit: gate.visit, owed: gate.owed != nil, milestoneOwed: settings.pendingMilestone?.mark,
                homeReadyForNote: gate.homeReadyForNote, active: scenePhase == .active,
                setupFinished: settings.hasCompletedOnboarding, tourIsUp: tourIsUp, recording: recording,
                showsError: showsError, homeInFront: gate.homeInFront, typing: gate.typing)
    }

    func body(content: Content) -> some View {
        @Bindable var gate = gate
        content
            .sheet(item: $gate.presented) { note in
                WhatsNewSheet(note: note)
                    .environment(gate)
                    .preferredColorScheme(settings.appearance.colorScheme)
            }
            .onAppear { gate.scenePhaseChanged(scenePhase, words: settings.wordsDictated) }
            .onChange(of: scenePhase) { _, phase in gate.scenePhaseChanged(phase, words: settings.wordsDictated) }
            .task(id: watched) { await offer() }
            #if DEBUG
            .onAppear {
                // Design review: `-zoneMilestone 10000` shows that mark's note on any simulator,
                // unless the record says it already came up.
                let forced = UserDefaults.standard.integer(forKey: "zoneMilestone")
                if forced > 0, settings.milestoneAcknowledged < forced { gate.forceMilestone(WordMilestones.note(for: forced)) }
            }
            #endif
    }

    /// What's New when its notes are owed; otherwise the word milestone note, when one is owed.
    /// Both wait for the same kind of moment; the note never shares a visit with What's New.
    @MainActor
    private func offer() async {
        let note = settings.pendingMilestone
        guard gate.owed != nil || (note != nil && gate.milestone == nil) else { return }
        let wait = gate.owed != nil ? gate.settleRemaining : gate.milestoneSettleRemaining
        try? await Task.sleep(for: .seconds(max(wait, 0.4)))
        guard !Task.isCancelled else { return }
        var moment = WhatsNewMoment()
        moment.setupFinished = settings.hasCompletedOnboarding
        moment.sceneActive = scenePhase == .active && UIApplication.shared.applicationState == .active
        moment.somethingPresented = tourIsUp || UIApplication.shared.showsPresentation
        moment.recording = recording
        moment.showsError = showsError
        if gate.owed != nil {
            gate.presentIfAllowed(moment)
        } else if let shown = withAnimation(Zone.motion, { gate.offerMilestone(note, moment) }) {
            settings.acknowledgeMilestone(shown.mark)
        }
    }
}
