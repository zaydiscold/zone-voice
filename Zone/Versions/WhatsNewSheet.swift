// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// The installed version's notes, shown once after an update (`WhatsNewGate` decides when).
/// Short on purpose: the version, its name, and the few starred changes. All changes opens the
/// version's full page (the grouped list Settings > About > Version shows) inside the sheet; Continue
/// closes it; See all versions opens the history.
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
        .tint(Zone.inlineInk(scheme))
        .accessibilityIdentifier("whatsNew.sheet")
    }
}

/// The sheet's content: the version and its name, the starred changes, and the way into the rest.
private struct WhatsNewHighlights: View {
    @Environment(\.colorScheme) private var scheme
    let note: ReleaseNote

    var body: some View {
        let highlights = note.highlights
        VStack(alignment: .leading, spacing: 0) {
            ReleaseNotesHeader(note: note, eyebrow: "What's new in Zone")
                .padding(.bottom, 20)

            if !highlights.isEmpty {
                Hairline()
                ForEach(Array(highlights.enumerated()), id: \.offset) { index, highlight in
                    if index > 0 { Hairline().padding(.leading, WhatsNewLine.inset) }
                    WhatsNewLine(highlight: highlight)
                }
                Hairline()
            }

            NavigationLink {
                ReleaseNotesView(note: note)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(allChanges)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Zone.ink(scheme))
                        Text(note.groups.map(\.title).joined(separator: ", "))
                            .font(.subheadline)
                            .foregroundStyle(Zone.muted(scheme))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Zone.muted(scheme))
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("whatsNew.fullNotes")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var allChanges: String {
        note.count == 1 ? "The 1 change" : "All \(note.count) changes"
    }
}

/// One starred change as a line: its group's picture, then its name and sentence.
private struct WhatsNewLine: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Where the text starts, so the hairlines between lines begin under it.
    static let inset: CGFloat = 46
    let highlight: ReleaseHighlight

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if !typeSize.isAccessibilitySize {
                ReleaseSymbolTile(symbol: highlight.group.symbol, side: 32)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(highlight.item.title ?? highlight.group.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Zone.ink(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                    if let tag = highlight.item.tag {
                        Text(tag.uppercased())
                            .font(.caption2.weight(.bold))
                            .tracking(0.5)
                            .zoneAccentBadge(scheme)
                            .fixedSize()
                            .accessibilityLabel(tag)
                    }
                }
                Text(highlight.item.text)
                    .font(.subheadline)
                    .foregroundStyle(Zone.muted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
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
