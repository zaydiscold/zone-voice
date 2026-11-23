// by zayd/cold @ zayd.wtf

import LinkPresentation
import SwiftUI
import ZoneCore

/// Home has two spaces under one header, switched like ChatGPT's modes: Transcribe (dictation)
/// and Meeting (a recorder that writes a transcript after). Transcribe is one screen with one
/// anchor: is the mic key live, and for how long. Below it the number worth bragging about,
/// setup rows only while something is missing, notes, and the composer pinned to the bottom.
struct HomeView: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(MeetingCoordinator.self) private var meetings
    @AppStorage("zone.home.mode") private var mode: HomeMode = .transcribe
    @Environment(AppSettings.self) private var settings
    @Environment(LinkCoordinator.self) private var link: LinkCoordinator?
    @Environment(WhatsNewGate.self) private var whatsNew: WhatsNewGate?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.sunShadow) private var sun
    @State private var practiceText = ""
    @State private var cleaningPractice = false
    @State private var sessionError: String?
    @State private var shareImage: UIImage?
    @State private var sharing = false
    @State private var settingsShortcut: SettingsShortcut?
    @State private var scaleIndex = 0
    @State private var showsFeedback = false
    /// Set while the walkthrough was put off with "Not now"; Home then leads with a way back.
    var resumeSetup: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .onChange(of: coordinator.noteReveal?.token, initial: true) { _, token in
                    // Notes live on the Transcribe page.
                    if token != nil, mode != .transcribe { withAnimation(Zone.motion) { mode = .transcribe } }
                }
            ZStack {
                switch mode {
                case .transcribe: transcribePage.transition(.opacity)
                case .meeting: MeetingSpaceView().transition(.opacity)
                case .cleanup: Color.clear
                }
                CleanupView(isActive: mode == .cleanup)
                    .opacity(mode == .cleanup ? 1 : 0)
                    .allowsHitTesting(mode == .cleanup)
                    .accessibilityHidden(mode != .cleanup)
            }
        }
        .navigationDestination(item: $settingsShortcut) { $0.destination }
        .zoneScreen()
        // Never shown (the bar is hidden), but it names Home in the menu that appears when the
        // Back button on History, Settings or any other pushed screen is held. Without it that
        // menu opened with one blank row.
        .navigationTitle("Home")
        .zoneBackButton()
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $cleaningPractice) { CleanupSheet(text: practiceText) }
        .sheet(isPresented: $showsFeedback) { FeedbackView() }
        // What's New only opens over Home itself, never over a screen pushed on top of it.
        .onAppear { whatsNew?.homeInFront = true }
        .onDisappear { whatsNew?.homeInFront = false }
        .onChange(of: readyForMilestone, initial: true) { _, ready in whatsNew?.homeReadyForNote = ready }
        #if DEBUG
        .onAppear {
            // Design review: `-zoneHomeMode meeting` opens on the Meeting space.
            if let raw = UserDefaults.standard.string(forKey: "zoneHomeMode"), let forced = HomeMode(rawValue: raw) { mode = forced }
        }
        #endif
    }

    private var transcribePage: some View {
        GeometryReader { page in
        ScrollViewReader { reader in
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                if let resumeSetup {
                    resumeCard(resumeSetup)
                }
                if !setupComplete && resumeSetup == nil {
                    setup
                }
                // At the start of a visit the person began, on an idle, set-up Home (WhatsNewGate).
                if let note = whatsNew?.milestone {
                    MilestoneCard(note: note) {
                        showsFeedback = true
                        putAwayMilestone(note)
                    } close: {
                        withAnimation(Zone.motion) { putAwayMilestone(note) }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                HomeNotice()
                HomeAudioRecoverySection()
                HomeLibraryView()
                // A short page settles its stats toward the bottom instead of leaving the lower
                // half empty; a long one simply scrolls.
                Spacer(minLength: 8)
                if settings.wordsDictated > 0 {
                    stats
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            // Less the composer bar pinned over the bottom edge (about 76 pt with its padding).
            .frame(minHeight: max(page.size.height - 76, 0), alignment: .top)
        }
        // Added to Notes on the Note saved page: Notes comes into view with the note lit up
        // (HomeLibraryView opens the section and lights it).
        .onChange(of: coordinator.noteReveal?.token, initial: true) { _, token in
            guard token != nil else { return }
            Task { @MainActor in
                // One pass for the section to open before scrolling to it.
                try? await Task.sleep(for: .milliseconds(120))
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.5)) {
                    reader.scrollTo(HomeLibraryView.notesAnchor, anchor: .top)
                }
            }
        }
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .trailing, spacing: 8) {
                if !practiceText.isEmpty && !coordinator.activity.isBusy {
                    HStack(spacing: 8) {
                        Button("Cleanup") { cleaningPractice = true }.buttonStyle(ZonePillButtonStyle())
                        Button("Copy") { Clipboard.copy(practiceText) }.buttonStyle(ZonePillButtonStyle())
                        Button("Clear") { practiceText = "" }.buttonStyle(ZonePillButtonStyle())
                    }
                    .transition(.opacity)
                }
                Composer(text: $practiceText, placeholder: "Test the mic here")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .animation(Zone.motion, value: practiceText.isEmpty)
        }
        }
        .statusBarBand()
    }

    // MARK: Header

    /// The mode switch on the page's leading edge, History and Settings on the trailing one.
    /// At accessibility text sizes the switch drops under the icons instead of squeezing.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 8) {
                HomeModeSwitch(mode: $mode, recording: meetings.isRecording)
                headerIcons
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack { Spacer(); headerIcons }
                HomeModeSwitch(mode: $mode, recording: meetings.isRecording)
            }
        }
    }

    private var headerIcons: some View {
        HStack(spacing: 0) {
            NavigationLink {
                HistoryView()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Zone.ink(scheme))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("History")
            NavigationLink {
                SettingsView()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Zone.ink(scheme))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("home.settings")
            // Hold the gear for the settings people come back to, one tap from Home.
            .contextMenu {
                ForEach(SettingsShortcut.allCases, id: \.self) { shortcut in
                    Button { settingsShortcut = shortcut } label: { Label(shortcut.title, systemImage: shortcut.symbol) }
                }
            }
        }
        // The gear's glyph, not its 44 pt hit area, meets the page edge.
        .padding(.trailing, -10)
    }

    // MARK: Hero

    /// The hero: the one thing Home is for. Big serif state with its light, one short line under
    /// it, one action. While recording it becomes "Listening" with the clock and the words as they
    /// arrive; the controls stay in the bar at the bottom, under the thumb, so nothing repeats.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                StatusDot(color: heroColor, pulses: heroPulses, hollow: !coordinator.isArmed && !coordinator.activity.isBusy, size: 14)
                Text(heroTitle)
                    .font(.zoneHeadline)
                    .foregroundStyle(Zone.ink(scheme))
                    .contentTransition(.opacity)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .accessibilityElement(children: .combine)
            // Side by side normally; stacked at accessibility text sizes so nothing truncates.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    heroDetailText.lineLimit(1)
                    Spacer(minLength: 8)
                    heroAction
                }
                VStack(alignment: .leading, spacing: 10) {
                    heroDetailText
                    heroAction
                }
            }
            if case .recording = coordinator.activity, !coordinator.liveTranscript.isEmpty {
                // The newest words, not the first ones: a long recording's whole text was laid
                // out every second to show its opening four lines (a 1 s hang at 1,390 words,
                // MetricKit 2026-11-03 12:10).
                Text(Self.tail(of: coordinator.liveTranscript))
                    .font(.body)
                    .foregroundStyle(Zone.ink(scheme))
                    .lineLimit(4, reservesSpace: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
                    .accessibilityLabel("Latest words: \(Self.tail(of: coordinator.liveTranscript))")
            }
            if coordinator.isHeld, let hold = coordinator.holdNotice {
                // A status, not a failure: the recording is kept and continues by itself.
                Text(hold).font(.footnote).foregroundStyle(Zone.muted(scheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let sessionError {
                Text(sessionError).font(.footnote).foregroundStyle(Zone.live)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { heroCard }
        .padding(.top, 4)
        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.45), value: heroTitle)
        .animation(Zone.motion, value: coordinator.liveTranscript.isEmpty)
    }

    /// The head card: a quiet surface lit from its top-right corner by the state's color, so
    /// on, recording and off each read at a glance without more words.
    private var heroCard: some View {
        let shape = Zone.cardShape
        return shape
            .fill(Zone.card(scheme))
            .overlay {
                RadialGradient(colors: [heroColor.opacity(coordinator.isArmed || coordinator.activity.isBusy ? 0.28 : 0.08), .clear],
                               center: .topTrailing, startRadius: 0, endRadius: 260)
                    .clipShape(shape)
                    .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.6), value: heroColor)
            }
            .overlay(shape.strokeBorder(Zone.rule(scheme), lineWidth: 1))
            .sunShadow(scale: 1)
    }

    /// About four lines' worth from the end, starting at a word.
    static func tail(of text: String, limit: Int = 200) -> String {
        guard text.count > limit else { return text }
        let cut = text.suffix(limit)
        let start = cut.firstIndex(of: " ").map { cut.index(after: $0) } ?? cut.startIndex
        return "…" + cut[start...]
    }

    private var heroTitle: String {
        switch coordinator.activity {
        case .recording: return coordinator.showsPaused ? "Paused" : "Listening"
        case .transcribing: return "Transcribing"
        default: return coordinator.isArmed ? "Standby on" : "Standby off"
        }
    }

    private var heroColor: Color {
        switch coordinator.activity {
        case .recording: return coordinator.showsPaused ? Zone.muted(scheme) : Zone.accentGraphic(scheme)
        case .transcribing: return Zone.accentGraphic(scheme)
        default: return coordinator.isArmed ? Zone.accentGraphic(scheme) : Zone.muted(scheme)
        }
    }

    private var heroPulses: Bool {
        switch coordinator.activity {
        case .recording: return !coordinator.showsPaused
        case .transcribing: return true
        default: return coordinator.isArmed
        }
    }

    private var heroDetailText: some View {
        heroDetail
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(Zone.muted(scheme))
            .contentTransition(.numericText())
    }

    @ViewBuilder
    private var heroDetail: some View {
        switch coordinator.activity {
        case .recording(_, let startedAt):
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(context.date.timeIntervalSince(startedAt).countdownLabel)
            }
        case .transcribing:
            Text("Finishing transcript…")
        default:
            if coordinator.isArmed {
                if let until = coordinator.armedUntil, !settings.inactivityPolicy.isUnbounded {
                    Text("Keyboard ready · \(until.timeIntervalSince(coordinator.now).countdownLabel) left")
                } else {
                    Text("Keyboard ready")
                }
            } else {
                Text(coordinator.modelIsReady ? "Turn on so the keyboard mic starts instantly" : "Finish setup below")
            }
        }
    }

    @ViewBuilder
    private var heroAction: some View {
        if !coordinator.activity.isBusy {
            if coordinator.isArmed {
                Button("Turn off") { coordinator.endSession(reason: .user) }
                    .buttonStyle(ZonePillButtonStyle())
            } else {
                Button("Turn on") {
                    Haptics.start()
                    Task {
                        do {
                            sessionError = nil
                            try await coordinator.armSession(chosenByPerson: true)
                        } catch is CancellationError {
                            // Off superseded this startup; keep the user's requested state.
                        } catch {
                            sessionError = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(ZoneInkPillButtonStyle())
                .disabled(!coordinator.modelIsReady)
            }
        }
    }

    // MARK: The number

    private var stats: some View {
        VStack(alignment: .leading, spacing: 8) {
            Hairline()
            Eyebrow("So far").padding(.top, 12)
            HStack(alignment: .firstTextBaseline) {
                HeroNumber(text: settings.wordsDictated.formatted())
                Spacer()
                Button("Share") {
                    renderShareCard()
                    sharing = shareImage != nil
                }
                .buttonStyle(ZonePillButtonStyle())
            }
            Text(settings.wordsDictated == 1 ? "word dictated" : "words dictated")
                .font(.subheadline).foregroundStyle(Zone.muted(scheme))
            scaleLine
            if settings.sharesCompleted > 0 {
                // For you, not the card: how many people you have passed Zone to. It only counts up.
                Label(DictationStats.helpedLine(people: settings.sharesCompleted), systemImage: "heart.fill")
                    .font(.footnote.weight(.medium)).foregroundStyle(Zone.accentText(scheme))
                    .contentTransition(.numericText())
            }
            // Rates need a little speech behind them; zeros on a first visit read as broken.
            if settings.wordsPerMinute > 0 {
                statRow.padding(.top, 8)
            }
            longestLine
        }
        // Rendered on the Share tap and freed when the sheet closes: the card is 5.8 MB of
        // pixels that most visits never need.
        .background(ShareSheet(isPresented: $sharing, items: shareImage.map { [ShareCardItem(image: $0), ShareInviteItem(sendsToComputer: link?.isPaired ?? false)] } ?? []) { completed, activity in
            shareImage = nil
            if completed, ShareSheet.reachesSomeone(activity) { withAnimation(Zone.motion) { settings.recordShare() } }
        })
    }

    /// The total held up against a text people know. A tap moves to the next one (Hamlet, the
    /// Library of Alexandria, Wikipedia) and the cycle ends on where the words were heard.
    /// Whatever is showing goes on the share card.
    @ViewBuilder private var scaleLine: some View {
        let lines = WordScale.cycle(words: settings.wordsDictated)
        if !lines.isEmpty {
            Button {
                Haptics.tap()
                withAnimation(Zone.motion) { scaleIndex = (scaleIndex + 1) % lines.count }
            } label: {
                Text(lines[scaleIndex % lines.count])
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Zone.accentText(scheme))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .id(scaleIndex % lines.count)
                    .transition(.opacity)
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows another comparison")
        }
    }

    private var scaleHeadline: String? {
        let lines = WordScale.cycle(words: settings.wordsDictated)
        return lines.isEmpty ? nil : lines[scaleIndex % lines.count]
    }

    /// The narrowest gap between two stat columns. Equal thirds with no gap ran "time saved vs
    /// typing" into "shared. Ever." on a 393 pt iPhone: the label is 115 pt in a 118 pt third.
    private static let statGap: CGFloat = 16

    private var statItems: [(value: String, label: String)] {
        [("\(settings.wordsPerMinute)", "words / min"),
         (DictationStats.timeLabel(minutes: minutesSaved), "saved vs typing"),
         ("0 bytes", "uploaded")]
    }

    /// Each column as wide as its text and the spare width between them, so every label stays
    /// on one line. When that is too wide (a narrow or zoomed screen, larger text) the columns
    /// split the width evenly and wrap, still a full gap apart; at accessibility sizes they stack.
    private var statRow: some View {
        let items = statItems
        let wrapped = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Self.statGap))
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(items.indices, id: \.self) { index in
                    if index > 0 { Spacer(minLength: Self.statGap) }
                    statCell(value: items[index].value, label: items[index].label).fixedSize()
                }
            }
            wrapped {
                ForEach(items.indices, id: \.self) { index in
                    statCell(value: items[index].value, label: items[index].label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func statCell(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .serif, weight: .semibold).monospacedDigit())
                .foregroundStyle(Zone.ink(scheme))
            Text(label).font(.caption).foregroundStyle(Zone.muted(scheme)).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// The personal record, under the stats: one quiet line, not a fourth column (three already
    /// share 393 pt). Only from a minute up, so a first short dictation never reads "0:04".
    /// Not on the share card. On one line while it fits, the value under the label when not.
    @ViewBuilder private var longestLine: some View {
        if let longest = settings.longestDictation, longest.seconds >= 60 {
            let label = Text("Longest dictation").font(.caption).foregroundStyle(Zone.muted(scheme))
            let value = Text("\(DictationStats.durationLabel(seconds: longest.seconds)) · \(longest.words.formatted()) \(longest.words == 1 ? "word" : "words")")
                .font(.footnote.weight(.medium).monospacedDigit()).foregroundStyle(Zone.ink(scheme))
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) { label; value }.fixedSize()
                VStack(alignment: .leading, spacing: 2) {
                    label.fixedSize(horizontal: false, vertical: true)
                    value.fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Longest dictation")
            .accessibilityValue("\(Self.spokenDuration(longest.seconds)), \(longest.words.formatted()) \(longest.words == 1 ? "word" : "words")")
        }
    }

    /// "8 minutes, 57 seconds" for VoiceOver, which reads "8:57" as a time of day or a ratio.
    private static func spokenDuration(_ seconds: Double) -> String {
        let whole = Int(min(max(seconds, 0), 1e12).rounded(.down))
        return Duration.seconds(whole).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }

    private var minutesSaved: Int {
        DictationStats.minutesSaved(words: settings.wordsDictated, secondsSpoken: settings.secondsDictated)
    }

    private func renderShareCard() {
        let card = ShareCard(words: settings.wordsDictated, wordsPerMinute: settings.wordsPerMinute,
                             minutesSaved: minutesSaved, scale: scaleHeadline, variation: .random(in: .min ... .max),
                             scheme: scheme, sun: sun)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 1.8 // 1080 x 1350, the 4:5 post size feeds expect.
        shareImage = renderer.uiImage
        #if DEBUG
        // Design review: `-zoneExportShareCard` writes the rendered card to Documents.
        if ProcessInfo.processInfo.arguments.contains("-zoneExportShareCard"), let data = shareImage?.pngData(),
           let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? data.write(to: docs.appendingPathComponent("share-card.png"))
        }
        #endif
    }

    // MARK: Setup

    /// Closing or answering the note puts it away for good. The mark was already recorded when
    /// it came up; recording it again covers the design-review override.
    private func putAwayMilestone(_ note: MilestoneNote) {
        settings.acknowledgeMilestone(note.mark)
        whatsNew?.putAwayMilestone()
    }

    /// The milestone note only comes onto a Home with nothing left to set up, on its Transcribe
    /// page: never above the setup steps, and never the first thing a new person sees.
    private var readyForMilestone: Bool {
        resumeSetup == nil && setupComplete && mode == .transcribe
    }

    private func resumeCard(_ resume: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text("Setup isn't finished").font(.body.weight(.semibold)).foregroundStyle(Zone.ink(scheme))
            Spacer(minLength: 8)
            Button("Continue", action: resume).buttonStyle(ZonePillButtonStyle())
        }
        .zoneCard(padding: 14)
    }


    private var setupComplete: Bool {
        coordinator.modelIsReady
            && coordinator.microphonePermission == .granted
            && coordinator.keyboardPresence?.hasFullAccess == true
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow("Finish setup")
            SetupRow(title: "Speech model", detail: modelDetail, done: coordinator.modelIsReady) {
                switch coordinator.modelState {
                case .missing:
                    Button("Download \(coordinator.selectedModel.sizeLabel)") { coordinator.prepareModel() }.buttonStyle(ZonePillButtonStyle())
                case .failed:
                    Button("Retry") { coordinator.prepareModel() }.buttonStyle(ZonePillButtonStyle())
                case .downloading(let progress, _):
                    ProgressView(value: progress).frame(width: 72).tint(Zone.accentGraphic)
                default:
                    ProgressView().tint(Zone.accentGraphic)
                }
            }
            SetupRow(title: "Microphone", detail: microphoneDetail, done: coordinator.microphonePermission == .granted) {
                if coordinator.microphonePermission == .denied {
                    Button("Settings") { openSettings() }.buttonStyle(ZonePillButtonStyle())
                } else {
                    Button("Set up") { Task { _ = await coordinator.requestMicrophonePermission() } }
                        .buttonStyle(ZonePillButtonStyle())
                }
            }
            SetupRow(title: "Keyboard", detail: keyboardDetail, done: coordinator.keyboardPresence?.hasFullAccess == true) {
                Button("Settings") { openSettings() }.buttonStyle(ZonePillButtonStyle())
            }
        }
    }

    // MARK: Labels

    private var modelDetail: String {
        switch coordinator.modelState {
        case .missing: return "\(coordinator.selectedModel.sizeLabel) from \(coordinator.selectedModel.downloadHost). Offline after download."
        case .downloading(let progress, _): return "Downloading · \(Int(progress * 100))% of \(coordinator.selectedModel.sizeLabel)"
        case .loading: return "Loading…"
        case .ready: return "Ready"
        case .failed(let message): return message
        }
    }

    private var microphoneDetail: String {
        coordinator.microphonePermission == .denied ? "Turned off. Enable in Settings." : "Needed for dictation."
    }

    private var keyboardDetail: String {
        guard let presence = coordinator.keyboardPresence else {
            return "Settings → Apps → Zone → Keyboards: turn on Zone and Allow Full Access."
        }
        return presence.hasFullAccess ? "Ready" : "Allow Full Access in Settings → Apps → Zone → Keyboards."
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// The card as one share item: the image goes out, and the sheet's header previews the card
/// itself with the caption as its title (a bare text item would take over the preview).
final class ShareCardItem: NSObject, UIActivityItemSource {
    let image: UIImage
    init(image: UIImage) { self.image = image }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { image }
    func activityViewController(_ controller: UIActivityViewController, itemForActivityType type: UIActivity.ActivityType?) -> Any? { image }
    func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = ZoneLinks.pitch
        metadata.imageProvider = NSItemProvider(object: image)
        metadata.iconProvider = NSItemProvider(object: image)
        return metadata
    }
}

/// The message and both links (ZoneLinks.invite), sent beside the card or on its own. Saving to
/// Photos, printing and contacts take the image alone; a paragraph there is clutter.
final class ShareInviteItem: NSObject, UIActivityItemSource {
    private let invite: String
    /// `sendsToComputer`: a computer is paired, so "nothing leaves your phone" is not said.
    init(sendsToComputer: Bool) { invite = ZoneLinks.invite(sendsToComputer: sendsToComputer) }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { invite }
    func activityViewController(_ controller: UIActivityViewController, itemForActivityType type: UIActivity.ActivityType?) -> Any? {
        let imageOnly: Set<UIActivity.ActivityType> = [.saveToCameraRoll, .print, .assignToContact]
        if let type, imageOnly.contains(type) { return nil }
        return invite
    }
    func activityViewController(_ controller: UIActivityViewController, subjectForActivityType type: UIActivity.ActivityType?) -> String {
        "Zone, a voice keyboard for iPhone"
    }
    func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = "Share Zone"
        metadata.originalURL = ZoneLinks.appStore
        metadata.url = ZoneLinks.appStore
        return metadata
    }
}

/// The system share sheet with a completion report, so a share that actually went out can be counted.
///
/// Presented from UIKit, the way the sheet expects, not hosted as the content of a SwiftUI
/// `.sheet`. On iOS 26 a `UIActivityViewController` used as a representable's own view controller
/// inside a SwiftUI sheet draws nothing: the sheet slides up empty and stays empty (iOS 26.2
/// simulator, 2026-11-06, and a friend's phone). Sits invisibly behind the Share button; flipping
/// `isPresented` presents the sheet from this view's controller, and the completion handler
/// (also called on a swipe-down dismissal) resets it.
struct ShareSheet: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let items: [Any]
    let onFinish: (Bool, UIActivity.ActivityType?) -> Void

    /// Copy, Save Image, Print and the like keep the card on this phone; they are not a share.
    static func reachesSomeone(_ activity: UIActivity.ActivityType?) -> Bool {
        guard let activity else { return false }
        let local: Set<UIActivity.ActivityType> = [.copyToPasteboard, .saveToCameraRoll, .print, .assignToContact,
                                                   .addToReadingList, .markupAsPDF, .openInIBooks]
        return !local.contains(activity) && !activity.rawValue.contains("SaveToFiles")
    }

    final class Coordinator {
        var presenting = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let host = UIViewController()
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        return host
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        guard isPresented, !items.isEmpty, !context.coordinator.presenting, host.view.window != nil else { return }
        context.coordinator.presenting = true
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        let coordinator = context.coordinator
        controller.completionWithItemsHandler = { activity, completed, _, _ in
            coordinator.presenting = false
            isPresented = false
            onFinish(completed, activity)
        }
        // iPad presents it as a popover and needs an anchor.
        controller.popoverPresentationController?.sourceView = host.view
        controller.popoverPresentationController?.sourceRect = host.view.bounds
        host.present(controller, animated: true)
    }
}

/// The shareable card, rendered with ImageRenderer at 1.8x (1080 x 1350, a 4:5 post). It is the
/// app's own page, not a poster: paper, ink and the one accent, with the stats on a card that
/// casts the same hard sun shadow as every card in the app. The waveform is the live meter's
/// capsules, drawn by a small synth voiced by the word count.
struct ShareCard: View {
    let words: Int
    let wordsPerMinute: Int
    let minutesSaved: Int
    /// The comparison showing on Home when Share was tapped ("That's 1.2 Great Gatsbys.").
    var scale: String? = nil
    /// A fresh value per share: the same total draws a sibling wave, not a copy.
    var variation: UInt64 = 0
    let scheme: ColorScheme
    let sun: SunShadow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("zone")
                    .font(.system(size: 34, weight: .semibold, design: .serif))
                    .foregroundStyle(Zone.ink(scheme))
                Spacer()
                Text("on-device dictation")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Zone.muted(scheme))
            }
            Spacer(minLength: 0)
            Text(words.formatted())
                .font(.system(size: 132, weight: .semibold, design: .serif).monospacedDigit())
                .foregroundStyle(Zone.ink(scheme))
                .minimumScaleFactor(0.4)
                .lineLimit(1)
            Text(words == 1 ? "word dictated" : "words dictated")
                .font(.system(size: 24))
                .foregroundStyle(Zone.muted(scheme))
            if let scale {
                Text(scale)
                    .font(.system(size: 24, weight: .semibold, design: .serif))
                    .foregroundStyle(Zone.accentText(scheme))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .padding(.top, 6)
            }
            waveform
                .frame(height: 72)
                .padding(.top, 30)
                .padding(.bottom, 40)
            statsCard
            HStack(spacing: 8) {
                Circle().fill(Zone.accentGraphic).frame(width: 7, height: 7)
                Text("100% on-device speech recognition.")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Zone.accentText(scheme))
            }
            .padding(.top, 24)
        }
        .padding(44)
        .frame(width: 600, height: 750)
        .background(paper)
        .environment(\.colorScheme, scheme)
    }

    /// Flat paper with a faint ruling, the way the app's pages are flat paper.
    private var paper: some View {
        ZStack {
            Zone.paper(scheme)
            VStack(spacing: 22) {
                ForEach(0..<34, id: \.self) { _ in Rectangle().fill(Zone.ink(scheme).opacity(0.035)).frame(height: 1) }
            }
        }
    }

    /// The three numbers on one card, split by hairlines like Home's stat row. The shadow is
    /// the app's sun shadow at this phone's time of day, scaled for a 600 pt canvas.
    private var statsCard: some View {
        let shape = Zone.cardShape
        return HStack(spacing: 0) {
            stat("\(wordsPerMinute)", "words / min")
            Rectangle().fill(Zone.rule(scheme)).frame(width: 1)
            stat(DictationStats.timeLabel(minutes: minutesSaved), "time saved")
            Rectangle().fill(Zone.rule(scheme)).frame(width: 1)
            stat("0 bytes", "uploaded")
        }
        .fixedSize(horizontal: false, vertical: true)
        .background {
            shape.fill(Zone.card(scheme))
                .shadow(color: .black.opacity(sun.alpha * (scheme == .dark ? 0.55 : 0.18)), radius: 0,
                        x: sun.dx * 3, y: sun.dy * 3)
        }
        .overlay(shape.strokeBorder(Zone.rule(scheme), lineWidth: 1))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .serif).monospacedDigit())
                .foregroundStyle(Zone.ink(scheme))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label).font(.system(size: 14)).foregroundStyle(Zone.muted(scheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    /// The live meter's capsules, older bars dimmer on the left, voiced by ShareWave.
    private var waveform: some View {
        Canvas { context, size in
            let bars = ShareWave.bars(count: 44, words: words, variation: variation)
            let pitch = size.width / CGFloat(bars.count)
            let width = pitch * 0.42
            for (index, level) in bars.enumerated() {
                let height = max(width, size.height * CGFloat(level))
                let rect = CGRect(x: CGFloat(index) * pitch + (pitch - width) / 2, y: (size.height - height) / 2,
                                  width: width, height: height)
                let age = 0.45 + 0.55 * Double(index) / Double(max(bars.count - 1, 1))
                context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(Zone.accent.opacity(age)))
            }
        }
    }
}

/// The gear's long-press menu: settings people return to, opened straight from Home.
enum SettingsShortcut: CaseIterable, Hashable {
    case myWords, speechModel, keyboard, appearance, backup

    var title: String {
        switch self {
        case .myWords: return "My words"
        case .speechModel: return "Speech model"
        case .keyboard: return "Keyboard"
        case .appearance: return "Appearance"
        case .backup: return "Backup and export"
        }
    }

    var symbol: String {
        switch self {
        case .myWords: return "character.book.closed"
        case .speechModel: return "waveform"
        case .keyboard: return "keyboard"
        case .appearance: return "circle.lefthalf.filled"
        case .backup: return "externaldrive"
        }
    }

    @MainActor @ViewBuilder var destination: some View {
        switch self {
        case .myWords: PersonalWordsView()
        case .speechModel: ModelLibraryView()
        case .keyboard: KeyboardSettingsView()
        case .appearance: AppearanceSettingsView()
        case .backup: LibraryBackupView()
        }
    }
}
