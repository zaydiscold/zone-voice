// by zayd/cold @ zayd.wtf

import LinkPresentation
import SwiftUI
import UserNotifications
import ZoneCore

/// Home keeps its header in place while each mode scrolls vertically inside its own page.
struct HomeView: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(MeetingCoordinator.self) private var meetings
    @AppStorage("zone.home.mode") private var mode: HomeMode = .transcribe
    // During a finger-driven swipe, SwiftUI reports provisional page IDs. Commit only
    // the final one. Programmatic jumps already have a destination and ignore intermediate IDs.
    @State private var swipePage: HomeMode?
    @State private var pageTravel = HomePageTravel()
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.colorSchemeContrast) private var contrast

    private var initialAnchor: UnitPoint {
        let pages = HomeMode.allCases
        let index = pages.firstIndex(of: mode) ?? 0
        return UnitPoint(x: CGFloat(index) / CGFloat(max(1, pages.count - 1)), y: 0)
    }

    private var scrollSelection: Binding<HomeMode?> {
        Binding(
            get: { swipePage ?? mode },
            set: { page in
                if swipePage != nil, let page { swipePage = page }
            }
        )
    }

    @Environment(AppSettings.self) private var settings
    @Environment(LinkCoordinator.self) private var link: LinkCoordinator?
    @Environment(WhatsNewGate.self) private var whatsNew: WhatsNewGate?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.sunShadow) private var sun
    @Environment(\.scenePhase) private var scenePhase
    @State private var noticeStatus: UNAuthorizationStatus = .notDetermined
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var practiceText = ""
    @AppStorage(ZoneNoticePermission.requestedKey) private var requestedNotices = false
    @AppStorage(ZoneNoticePermission.explainedKey) private var explainedNotices = false
    @State private var homeVisible = false
    @State private var heroVisible = true
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
                    if token != nil {
                        swipePage = nil
                        mode = .transcribe
                    }
                }
            GeometryReader { viewport in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(HomeMode.allCases, id: \.self) { page in
                            content(for: page)
                                .frame(width: viewport.size.width, height: viewport.size.height)
                                .id(page)
                                .accessibilityHidden(mode != page)
                        }
                    }
                    .scrollTargetLayout()
                    .onGeometryChange(for: CGFloat?.self) { geometry in
                        let width = viewport.size.width
                        guard width > 0 else { return nil }
                        let frame = geometry.frame(in: .named("home.pager"))
                        let distance = layoutDirection == .rightToLeft ? frame.maxX - width : -frame.minX
                        return min(max(0, distance / width), CGFloat(HomeMode.allCases.count - 1))
                    } action: { position in
                        pageTravel.position = position
                    }
                }
                .coordinateSpace(name: "home.pager")
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
                // At the leading edge even a sliver of the previous page can win the
                // selection during a short drag. Track the page under the viewport center.
                .scrollPosition(id: scrollSelection, anchor: .top)
                .defaultScrollAnchor(initialAnchor, for: .initialOffset)
                .onScrollPhaseChange { _, phase in
                    switch phase {
                    case .tracking, .interacting:
                        if swipePage == nil { swipePage = mode }
                    case .idle:
                        if let swipePage { mode = swipePage }
                        swipePage = nil
                    default:
                        break
                    }
                }
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
        .sheet(isPresented: $showsFeedback) { FeedbackView() }
        // What's New only opens over Home itself, never over a screen pushed on top of it.
        .onAppear {
            homeVisible = true
            whatsNew?.homeInFront = true
        }
        .onDisappear {
            homeVisible = false
            swipePage = nil
            whatsNew?.homeInFront = false
        }
        .onChange(of: readyForMilestone, initial: true) { _, ready in whatsNew?.homeReadyForNote = ready }
    }

    @ViewBuilder
    private func content(for page: HomeMode) -> some View {
        switch page {
        case .transcribe: transcribePage
        case .meeting: MeetingSpaceView(isActive: mode == .meeting)
        }
    }

    private var transcribePage: some View {
        GeometryReader { page in
        ScrollViewReader { reader in
        ScrollView {
            VStack(alignment: .leading, spacing: SectionBreak.spacing) {
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
                    .task(id: scenePhase) {
                        guard scenePhase == .active, !explainedNotices else { return }
                        noticeStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                    }
                if ZoneNoticePermission.needsExplanation(requested: requestedNotices, status: noticeStatus, explained: explainedNotices) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(ZoneNoticePermission.message)
                        Button("Got it") { explainedNotices = true }.buttonStyle(ZoneQuietButtonStyle())
                    }
                    .font(.subheadline)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Zone.card(scheme), in: RoundedRectangle(cornerRadius: 12))
                }
                HomeAudioRecoverySection(isActive: mode == .transcribe)
                HomeLibraryView(isActive: mode == .transcribe)
                // A short page settles its stats toward the bottom instead of leaving the lower
                // half empty; a long one simply scrolls.
                if settings.wordsDictated > 0 {
                    VStack(alignment: .leading, spacing: 0) {
                        Spacer(minLength: 0)
                        stats
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            // Less the composer bar pinned over the bottom edge (about 76 pt with its padding).
            .frame(minHeight: max(page.size.height - 76, 0), alignment: .top)
        }
        // Added to Notes on the Note saved page: Notes comes into view with the note lit up
        // (HomeLibraryView opens the section and lights it).
        .task(id: mode == .transcribe ? coordinator.noteReveal?.token : nil) {
            guard mode == .transcribe, coordinator.noteReveal != nil else { return }
            // Wait for the Notes section to expand. Leaving Transcribe cancels this reveal.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : Zone.motion) {
                reader.scrollTo(HomeLibraryView.notesAnchor, anchor: .top)
            }
        }
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .trailing, spacing: 8) {
                if !practiceText.isEmpty && !coordinator.activity.isBusy {
                    HStack(spacing: 8) {
                        Button("Copy") { Clipboard.copy(practiceText) }.buttonStyle(ZonePillButtonStyle())
                        Button("Clear") { practiceText = "" }.buttonStyle(ZonePillButtonStyle())
                    }
                    .transition(.opacity)
                }
                Composer(text: $practiceText, placeholder: "Test the mic here", isActive: mode == .transcribe,
                         showsMicLight: micLightsVisible)
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
                modeKeys
                Spacer(minLength: 0)
                headerIcons
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack { Spacer(); headerIcons }
                modeKeys
            }
        }
    }

    private var modeKeys: some View {
        HomeModeSwitch(
            mode: Binding(
                get: { mode },
                set: { requested in
                    swipePage = nil
                    mode = requested
                }
            ),
            travel: pageTravel,
            meetingRecording: meetings.isRecording,
            dictationRecording: coordinator.activity.isBusy && !coordinator.hasRecordingScreen && !coordinator.noteIsLive
        )
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
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

    private var micLightsVisible: Bool {
        homeVisible && mode == .transcribe && !showsFeedback && !coordinator.showsDictationScreen
    }

    // MARK: Hero

    /// The hero: the one thing Home is for. Big serif state with its light, one short line under
    /// it, one action. While recording it becomes "Listening" with the clock and the words as they
    /// arrive; the controls stay in the bar at the bottom, under the thumb, so nothing repeats.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                StatusDot(color: heroColor, hollow: !coordinator.isArmed && !coordinator.activity.isBusy
                          && !coordinator.isPreparingMicrophone, size: 14)
                Text(heroTitle)
                    .font(.zoneHeadline)
                    .foregroundStyle(Zone.ink(scheme))
                    .contentTransition(.opacity)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("home.standbyTitle")
            // Side by side normally; stacked at accessibility text sizes so nothing truncates.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    heroDetailText.lineLimit(1).fixedSize(horizontal: true, vertical: false)
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
        .onScrollVisibilityChange(threshold: 0.1) { heroVisible = $0 }
        .padding(.top, 4)
        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.45), value: heroTitle)
        .animation(Zone.motion, value: coordinator.liveTranscript.isEmpty)
    }

    /// The head card: a quiet surface lit from the same side as the keys by the state's color, so
    /// on, recording and off each read at a glance without more words.
    private var heroCard: some View {
        let shape = Zone.cardShape
        let light = UnitPoint(x: 0.5 - sun.dx / (2 * SunShadow.defaultMaxLength), y: 0)
        return shape
            .fill(Zone.card(scheme))
            .overlay {
                RadialGradient(colors: [heroColor.opacity(coordinator.isArmed || coordinator.activity.isBusy ? 0.20 : 0.06), .clear],
                               center: light, startRadius: 0, endRadius: 260)
                    .clipShape(shape)
                    .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.6), value: heroColor)
            }
            .overlay { if contrast == .increased { shape.strokeBorder(Zone.rule(scheme), lineWidth: 1) } }
            .sunShadow(scale: 1)
            .overlay {
                if micLightsVisible && heroVisible && !heroShowsNote {
                    MicLight(surface: .standby)
                }
            }
    }

    /// About four lines' worth from the end, starting at a word.
    static func tail(of text: String, limit: Int = 200) -> String {
        guard text.count > limit else { return text }
        let cut = text.suffix(limit)
        let start = cut.firstIndex(of: " ").map { cut.index(after: $0) } ?? cut.startIndex
        return "…" + cut[start...]
    }

    /// A note is recording or being saved. Its card at the top has the clock, the bars and the
    /// buttons, so the hero does not repeat "Listening" and a second clock under it: it names
    /// the note and carries what the card has no room for, the words as they arrive.
    private var heroShowsNote: Bool {
        switch coordinator.noteCard {
        case .recording, .saving: true
        default: false
        }
    }

    /// The hero's line under "Your note": how much has been heard so far.
    static func noteDetail(liveTranscript: String) -> String {
        let words = liveTranscript.split(whereSeparator: \.isWhitespace).count
        switch words {
        case 0: return "Your words appear here as you talk"
        case 1: return "1 word so far"
        default: return "\(words) words so far"
        }
    }

    private var heroTitle: String {
        if heroShowsNote { return "Your note" }
        switch coordinator.activity {
        case .recording: return coordinator.showsPaused ? "Paused" : "Listening"
        case .transcribing: return "Transcribing"
        default:
            if coordinator.isPreparingMicrophone && !coordinator.isArmed { return "Starting mic…" }
            return coordinator.isArmed ? "Standby on" : "Standby off"
        }
    }

    private var heroColor: Color {
        switch coordinator.activity {
        case .recording: return coordinator.showsPaused ? Zone.muted(scheme) : Zone.accentTone(scheme)
        case .transcribing: return Zone.accentTone(scheme)
        default:
            return coordinator.isArmed || coordinator.isPreparingMicrophone ? Zone.accentTone(scheme) : Zone.muted(scheme)
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
        case .recording where heroShowsNote, .transcribing where heroShowsNote:
            Text(Self.noteDetail(liveTranscript: coordinator.liveTranscript))
        case .recording(_, let startedAt):
            TimelineView(.animation(minimumInterval: 1, paused: mode != .transcribe)) { context in
                Text(context.date.timeIntervalSince(startedAt).countdownLabel)
            }
        case .transcribing:
            Text("Finishing transcript…")
        case _ where coordinator.isPreparingMicrophone && !coordinator.isArmed:
            Text("Getting the microphone ready")
        default:
            if coordinator.isArmed {
                // "Keyboard ready" only once the keyboard has reported in: until then the setup
                // list right under this still says the keyboard is missing (`HomeCopy`).
                let reported = coordinator.keyboardPresence?.hasFullAccess == true
                if let until = coordinator.armedUntil, !settings.inactivityPolicy.isUnbounded {
                    Text(HomeCopy.standby(keyboardReported: reported, left: until.timeIntervalSince(mode == .transcribe ? coordinator.now : .now).countdownLabel))
                } else {
                    Text(HomeCopy.standby(keyboardReported: reported, left: nil))
                }
            } else {
                Text(coordinator.modelIsReady ? "Turn on for an instant start and live words." : modelDetail)
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
                            sessionError = RecordingProblem.microphone.message(for: error)
                        }
                    }
                }
                .buttonStyle(ZoneInkPillButtonStyle())
                .disabled(!coordinator.modelIsReady || coordinator.isPreparingMicrophone)
            }
        }
    }

    // MARK: The number

    private var stats: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Announced like Notes and History: the same bold title in the same 44 pt row.
            Text("So far").font(.headline).frame(minHeight: 44).accessibilityAddTraits(.isHeader)
            HStack(alignment: .firstTextBaseline) {
                HeroNumber(text: settings.wordsDictated.formatted())
                Spacer()
                Button("Share") {
                    renderShareCard()
                    sharing = shareImage != nil
                }
                .buttonStyle(ZonePillButtonStyle())
            }
            Text(HomeCopy.wordsLabel(settings.wordsDictated))
                .font(.subheadline).foregroundStyle(Zone.muted(scheme))
            scaleLine
            if settings.sharesCompleted > 0 {
                // For you, not the card: how many people you have passed Zone to. It only counts up.
                Label(DictationStats.helpedLine(people: settings.sharesCompleted), systemImage: "heart.fill")
                    .font(.footnote.weight(.medium)).labelStyle(ZoneCueLabelStyle(scheme: scheme))
                    .contentTransition(.numericText())
            }
            // Rates need a little speech behind them; zeros on a first visit read as broken.
            if settings.wordsPerMinute > 0 {
                statRow.padding(.top, 8)
                Text("Savings compare recording time with typing the words you kept at 36.2 wpm.")
                    .font(.footnote).foregroundStyle(Zone.muted(scheme))
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
    /// Library of Alexandria, Wikipedia) and the cycle ends on where the count is saved.
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
                    .zoneAccentLink(scheme)
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
        HomeCopy.stats(wordsPerMinute: settings.wordsPerMinute, minutesSaved: settings.estimatedMinutesSaved)
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
    /// share 393 pt). Shown from 50 words or one minute.
    /// On the share card too, under its wave, without the day. Ends with the day it was spoken. On one line while it fits, the value under the label when not.
    @ViewBuilder private var longestLine: some View {
        if let longest = settings.longestDictation, longest.isDisplayable {
            let label = Text("Most words in one dictation").font(.caption).foregroundStyle(Zone.muted(scheme))
            let day = DictationStats.dayLabel(longest.date)
            let value = Text("\(longest.words.formatted()) \(longest.words == 1 ? "word" : "words") · \(DictationStats.durationLabel(seconds: longest.seconds)) · \(day)")
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
            .accessibilityLabel("Most words in one dictation")
            .accessibilityValue("\(Self.spokenDuration(longest.seconds)), \(longest.words.formatted()) \(longest.words == 1 ? "word" : "words"), \(day)")
        }
    }

    /// "8 minutes, 57 seconds" for VoiceOver, which reads "8:57" as a time of day or a ratio.
    private static func spokenDuration(_ seconds: Double) -> String {
        let whole = Int(min(max(seconds, 0), 1e12).rounded(.down))
        return Duration.seconds(whole).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }

    private func renderShareCard() {
        let card = ShareCard(words: settings.wordsDictated, items: statItems,
                             scale: scaleHeadline, variation: .random(in: .min ... .max),
                             longest: settings.longestDictation,
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
        mode == .transcribe && resumeSetup == nil && setupComplete
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
                    ProgressView(value: progress).frame(width: 72).tint(Zone.accentTone(scheme))
                default:
                    ProgressView().tint(Zone.accentTone(scheme))
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

/// The message and App Store link (ZoneLinks.invite), sent beside the card or on its own. Saving to
/// Photos, printing and contacts take the image alone; a paragraph there is clutter.
final class ShareInviteItem: NSObject, UIActivityItemSource {
    private let invite: String
    /// Pairing changes the invitation independently of the selected speech model.
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
    let items: [(value: String, label: String)]
    /// The comparison showing on Home when Share was tapped ("That's 1.2 Great Gatsbys.").
    var scale: String? = nil
    /// A fresh value per share: the same total draws a sibling wave, not a copy.
    var variation: UInt64 = 0
    /// The personal record, written under the wave the way a voice memo's length sits under
    /// its waveform. Length and words only: the day stays on Home.
    var longest: LongestDictation? = nil
    let scheme: ColorScheme
    let sun: SunShadow

    private var longestCaption: (length: String, words: String)? {
        guard let longest, longest.isDisplayable else { return nil }
        return (DictationStats.durationLabel(seconds: longest.seconds),
                "\(longest.words.formatted()) \(longest.words == 1 ? "word" : "words")")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("zone")
                    .font(.system(size: 34, weight: .semibold, design: .serif))
                    .foregroundStyle(Zone.ink(scheme))
                Spacer()
                Text("dictation stats")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Zone.muted(scheme))
            }
            Spacer(minLength: 0)
            Text(words.formatted())
                .font(.system(size: 132, weight: .semibold, design: .serif).monospacedDigit())
                .foregroundStyle(Zone.ink(scheme))
                .minimumScaleFactor(0.4)
                .lineLimit(1)
            Text(HomeCopy.wordsLabel(words))
                .font(.system(size: 24))
                .foregroundStyle(Zone.muted(scheme))
            if let scale {
                Text(scale)
                    .font(.system(size: 24, weight: .semibold, design: .serif))
                    .foregroundStyle(Zone.accentTone(scheme))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .padding(.top, 6)
            }
            waveform
                .frame(height: 72)
                .padding(.top, 30)
                .padding(.bottom, longestCaption == nil ? 40 : 10)
            if let longestCaption {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("most words in one go")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Zone.muted(scheme))
                    Spacer(minLength: 8)
                    Text("\(longestCaption.words) · \(longestCaption.length)")
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Zone.ink(scheme))
                }
                .lineLimit(1)
                .padding(.bottom, 22)
            }
            statsCard
            Text("Savings compare recording time with typing at 36.2 wpm.")
                .font(.system(size: 16))
                .foregroundStyle(Zone.muted(scheme))
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

    /// The same figures as Home, split by hairlines like Home's stat row. The shadow is
    /// the app's sun shadow at this phone's time of day, scaled for a 600 pt canvas.
    private var statsCard: some View {
        let shape = Zone.cardShape
        return HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                if index > 0 { Rectangle().fill(Zone.rule(scheme)).frame(width: 1) }
                stat(items[index].value, items[index].label)
            }
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
                context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(Zone.accentTone(scheme).opacity(age)))
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
        case .keyboard: return "Zone keyboard"
        case .appearance: return "Personalize"
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
        case .appearance:
            Form { PersonalizeSection() }
                .modifier(VoicePreviewPageVisibility())
                .scrollContentBackground(.hidden)
                .navigationTitle("Personalize")
                .zoneBackButton()
                .navigationBarTitleDisplayMode(.inline)
                .zoneScreen()
        case .backup: LibraryBackupView()
        }
    }
}
