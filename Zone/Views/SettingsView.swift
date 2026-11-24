// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

extension AppSettings {
    var spaceHoldTalkHint: String {
        let hint = "Hold to talk, let go to insert. Slide sideways to move the cursor."
        return !KeyboardSpeechAssets.isSupported || !dictatesInKeyboard ? hint + " Works while Standby is on." : hint
    }
}

struct SettingsView: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var scheme
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var sharingZone = false
    @State private var showsShareCode = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Search settings", text: $query)
                        .focused($searchFocused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .accessibilityIdentifier("settings.search")
                    if !query.isEmpty {
                        Button { query = ""; searchFocused = true } label: {
                            Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Clear search")
                    }
                }
            }
            .listRowBackground(Zone.card(scheme))
            Section {
                if matches(.keyboard) {
                    NavigationLink {
                        KeyboardSettingsView()
                    } label: {
                        Text("Zone keyboard")
                    }
                    .accessibilityIdentifier("settings.keyboard")
                }
                if matches(.handles) {
                    VStack(alignment: .leading, spacing: 0) {
                        Toggle("Say “at” to tag names", isOn: $settings.handleRecognition)
                            .accessibilityHint(HandleHelp.meaning)
                        SettingsNote("Name tagging", HandleHelp.example(settings.handleRecognition), detail: HandleHelp.meaning)
                    }
                }
                if matches(.shortcuts) {
                    NavigationLink(SetupDevice.hasActionButton ? "Action Button and Shortcuts" : "Shortcuts and Back Tap") { ShortcutHelpView() }
                }
            } header: {
                if query.isEmpty { Text("Keyboard and shortcuts") }
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                if matches(.style) {
                    NavigationLink {
                        TextStyleSettingsView()
                    } label: {
                        LabeledContent("Text style", value: settings.defaultTextStyle.label)
                    }
                    .accessibilityIdentifier("settings.textStyle")
                }
                if matches(.numbers) {
                    NavigationLink("Numbers") { NumbersSettingsView() }
                        .accessibilityIdentifier("settings.numbers")
                }
                if matches(.words) {
                    NavigationLink("My words") { PersonalWordsView() }
                }
                if matches(.microphone) {
                    NavigationLink("Microphone and timing") { DictationSettingsView() }
                }
                if matches(.options) {
                    NavigationLink("Dictation options") { DictationOptionsView() }
                        .accessibilityIdentifier("settings.dictationOptions")
                }
                if matches(.model) {
                    NavigationLink {
                        ModelLibraryView()
                    } label: {
                        LabeledContent("Speech model", value: coordinator.selectedModel.shortName)
                    }
                    .accessibilityIdentifier("settings.speechModel")
                }
            } header: {
                if query.isEmpty { Text("Dictation") }
            }
            .listRowBackground(Zone.card(scheme))

            if SettingsSubject.personalize.contains(where: matches) {
                PersonalizeSection(query: query)
            }

            Section {
                if matches(.computers) {
                    NavigationLink("Computers (Beta)") { ComputersView() }
                        .accessibilityIdentifier("settings.computers")
                }
            } header: {
                if query.isEmpty { Text("Library") }
            }
            .listRowBackground(Zone.card(scheme))

            if matches(.share) {
                Section {
                    Button { sharingZone = true } label: {
                        Label("Share Zone with a friend", systemImage: "testtube.2")
                    }
                    // Hold for the App Store link, or a code a friend scans from this screen.
                    .contextMenu {
                        Button { showsShareCode = true } label: { Label("Show QR code", systemImage: "qrcode") }
                        Button { Clipboard.copy(ZoneLinks.appStore.absoluteString); Haptics.success() } label: {
                            Label("Copy App Store link", systemImage: "link")
                        }
                    }
                    .sheet(isPresented: $showsShareCode) { ShareCodeSheet() }
                    .background(ShareSheet(isPresented: $sharingZone, items: [ZoneLinks.appStore]) { completed, activity in
                        if completed, ShareSheet.reachesSomeone(activity) { settings.recordShare() }
                    })
                } footer: {
                    SettingsNote("Share Zone with a friend", "Hold for more ways to share.", detail: "Hold to copy the App Store link or show a QR code.")
                }
                .listRowBackground(Zone.card(scheme))
            }

            Section {
                if matches(.data) {
                    NavigationLink("Your data") { YourDataMenuView() }
                        .accessibilityIdentifier("settings.yourData")
                }
                if matches(.help) {
                    NavigationLink("Help") { HelpSettingsView() }
                        .accessibilityIdentifier("settings.help")
                }
                if matches(.about) {
                    NavigationLink("About") { AboutSettingsView() }
                        .accessibilityIdentifier("settings.about")
                }
            }
            .listRowBackground(Zone.card(scheme))
            if !SettingsSubject.allCases.contains(where: matches) {
                Text("No matching settings").foregroundStyle(.secondary).listRowBackground(Zone.card(scheme))
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollContentBackground(.hidden)
        .modifier(VoicePreviewPageVisibility())
        .tint(Zone.inlineInk(scheme))
        .navigationTitle("Settings")
        .zoneBackButton()
        .zoneScreen()
    }

    private func matches(_ subject: SettingsSubject) -> Bool { subject.matches(query) }
}

enum HandleHelp {
    static let meaning = "With tagging on, “at Kevin” writes @kevin. With it off, the words stay plain. “At sign Kevin” always writes @kevin."

    static func example(_ enabled: Bool) -> String {
        enabled ? "At Kevin → @kevin" : "At Kevin → plain words"
    }
}

private enum SettingsSubject: String, CaseIterable {
    case keyboard = "Zone keyboard setup keyboard recognition Fluid Speech Mini WebKit Zone Link GPU provider local download Full Access allow open Zone in iPhone settings keyboards hold the space bar hold to talk move the cursor sounds and haptics start stop sound vibration keyboard microphone dictate without opening Zone never use Apple's fallback speech model download swipe typing beta learn from swipe corrections reset learning swipe trail rainbow road one-handed keyboard thumb left right width typing auto-capitalization autocorrect suggestions smart punctuation follow shift paste key suggest emoji for words emoji by colon :pizza hide the Z style button"
    case handles = "Say at to tag names name tagging smart @handles at sign Kevin plain words"
    case shortcuts = "Action Button and Shortcuts Siri Back Tap Controls Control Center Lock Screen voice note dictate and copy toggle Zone bring back Zone's island get last dictation shortcut"
    case style = "Text style default keyboard styles Formal Excited Casual Very casual"
    case numbers = "Numbers number format follow text style always digits words under ten Formal Excited Casual also in Very casual ordinal numbers 1st 2nd 3rd as numbers"
    case words = "My words personal vocabulary learn from corrections learn names learning learned saved @handles add a handle spelling pronunciation heard as import or export words paste a word list open from files export my words as CSV"
    case microphone = "Microphone and timing standby keep microphone ready turn on when Zone opens while dictating when the keyboard closes finish when quiet wait for silence custom seconds timer how it works"
    case options = "Dictation options spoken corrections scratch that and no wait check unsure words caps lock drops punctuation smiley face writes California Mode filler words remove like speed up speech in Zone faster dictation advanced"
    case model = "Speech model Fluid Mini English on this iPhone download remove old models model library free up storage clear helper how your words get here accuracy"
    case preview = "Personalize Keyboard preview look layout"
    case scheme = "Personalize Color scheme appearance theme match iPhone light dark"
    case accent = "Personalize Accent color swatches"
    case graphic = "Personalize Voice graphic live preview meter visualizer Scope by Hex Christopher Langton"
    case micLight = "Personalize Mic light brightness listening glow clear edge off"
    case island = "Personalize Zone in the Dynamic Island preview buttons times clock live tell me if it ends notifications reminder show as banners open iOS Settings"
    case meeting = "Personalize Meeting appearance timer animate numbers pace gentle brisk waveform style"
    case order = "Personalize Home list order Notes first History first"
    case computers = "Computers Beta Keyboard GPU provider Zone Link pair a computer connected last sync now last flash items sent send everything again forget this computer send to this computer paste link get Zone for your computer offline QR transfer Mac desktop"
    case share = "Share Zone with a friend show QR code copy App Store link invite"
    case data = "Your data dictation history clipboard history copies passwords images pinned backup and export import a Zone backup restore files library storage back up now automatic backups choose backup folder last saved delete data retention older than by age dates delete this range reset speaking stats delete everything"
    case help = "Help take the tour onboarding send feedback tell Zayd email contact what's new updates release notes recording log diagnostics"
    case about = "About version history privacy acknowledgements acknowledgments credits FUTO Swipe rate Zone on the App Store a note from Zayd"

    static let personalize: [Self] = [.preview, .scheme, .accent, .graphic, .micLight, .island, .meeting, .order]

    func matches(_ query: String) -> Bool {
        if query.isEmpty { return true }
        let choices: [String]
        switch self {
        case .accent: choices = AccentChoice.allCases.map(\.label)
        case .graphic: choices = MeterStyle.allCases.map(\.label)
        case .keyboard: choices = DictationSounds.Set.allCases.map(\.label)
        case .meeting: choices = MeetingWaveStyle.allCases.map(\.title)
        default: choices = []
        }
        func normalized(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .replacingOccurrences(of: "’", with: "").replacingOccurrences(of: "'", with: "")
        }
        let haystack = normalized(([rawValue] + choices).joined(separator: " "))
        let tokens = normalized(query).split { !$0.isLetter && !$0.isNumber && $0 != "@" && $0 != ":" }
        return tokens.isEmpty ? query.allSatisfy(\.isWhitespace) : tokens.allSatisfy { haystack.contains($0) }
    }
}

private struct YourDataMenuView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(LinkCoordinator.self) private var link

    var body: some View {
        Form {
            Section {
                NavigationLink("Dictation history") { HistoryView() }
                NavigationLink("Clipboard history") { ClipboardHistoryView() }
                    .accessibilityIdentifier("settings.clipboard")
                NavigationLink("Backup and export") { LibraryBackupView() }
                NavigationLink("Delete data") { YourDataView() }
            } footer: {
                SettingsNote("Your data", "Where your words are stored.", detail: LinkCopy.yourDataFooter(link.computers.map(\.name)))
            }
            .listRowBackground(Zone.card(scheme))
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Your data")
        .zoneBackButton()
        .navigationBarTitleDisplayMode(.inline)
        .zoneScreen()
    }
}

private struct HelpSettingsView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(WhatsNewGate.self) private var whatsNew
    @State private var showsUpdates = false
    @State private var showsTour = false
    @State private var showsFeedback = false

    var body: some View {
        Form {
            Section {
                Button("Take the tour") { showsTour = true }
                // Say it or type it; it leaves as an email from the person's own mail app.
                Button("Send feedback") { showsFeedback = true }
                    .accessibilityIdentifier("settings.feedback")
                if whatsNew.history.first != nil {
                    Button("What’s New") { showsUpdates = true }
                } else {
                    NavigationLink("What’s New") { VersionHistoryView() }
                }
                // What happened to each recording, with no words in it; shareable, so a tester can
                // send it when a recording misbehaves.
                NavigationLink("Recording log") { RecordingLogView() }
                // Measurement tools for development builds only; App Review guideline 2.5.19
                // treats hidden or undocumented features in a shipped build as grounds for removal.
                #if DEBUG
                NavigationLink("Diagnostics") { DiagnosticsView() }
                #endif
            }
            .listRowBackground(Zone.card(scheme))
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Help")
        .zoneBackButton()
        .navigationBarTitleDisplayMode(.inline)
        .zoneScreen()
        .sheet(isPresented: $showsUpdates) {
            if let note = whatsNew.history.first { WhatsNewSheet(note: note) }
        }
        .sheet(isPresented: $showsTour) { TourView() }
        .sheet(isPresented: $showsFeedback) { FeedbackView() }
    }
}

private struct AboutSettingsView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(WhatsNewGate.self) private var whatsNew

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    VersionHistoryView()
                } label: {
                    LabeledContent("Version", value: version)
                }
                .accessibilityHint("Opens the version history")
                .accessibilityIdentifier("settings.version")
                NavigationLink("Privacy") { PrivacyView() }
                NavigationLink("A note from Zayd") { AboutView() }
                // The person's own tap opens the App Store's review sheet. Zone never asks for
                // this itself; Apple's prompt does (ReviewPrompter).
                Button("Rate Zone on the App Store") { UIApplication.shared.open(ZoneLinks.writeReview) }
                    .accessibilityIdentifier("settings.rate")
                NavigationLink("Acknowledgements") { AcknowledgementsView() }
                    .accessibilityIdentifier("Acknowledgments")
            }
            .listRowBackground(Zone.card(scheme))
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("About")
        .zoneBackButton()
        .navigationBarTitleDisplayMode(.inline)
        .zoneScreen()
    }

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let marketing = whatsNew.installed?.description ?? info["CFBundleShortVersionString"] as? String ?? ""
        return "\(marketing) (\(info["CFBundleVersion"] as? String ?? ""))"
    }
}

/// What dictation writes beyond the text style: spoken corrections, unsure words, caps lock,
/// faces, ordinals and filler words. Name tagging is on the main Settings screen.
private struct DictationOptionsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Scratch that and no wait", isOn: $settings.spokenCorrections)
            } header: {
                Text("Spoken corrections")
            } footer: {
                SettingsNote("Scratch that and no wait", "Correct yourself as you speak.", detail: "Say “meet Tuesday, scratch that, Wednesday” to write **meet Wednesday**.", points: [
                    "**“Scratch that” alone** undoes your last dictation. Tap Redo or check History to bring it back.",
                    "**History keeps** the full raw transcript.",
                    "**Read before you send:** it can trim more than you meant.",
                ])
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                Toggle("Check unsure words", isOn: $settings.checksDoubtfulWords)
            } header: {
                Text("Unsure words")
            } footer: {
                SettingsNote("Check unsure words", "Tap a flagged word to fix it.", detail: "Flags up to three low-confidence words in the keyboard strip after you dictate. Tap one to swap it.", points: [
                    "**Learns from picks:** chosen fixes move to the top next time, and kept words get flagged less.",
                    "**Rare:** only when Zone is more likely wrong than right, so most dictations show none.",
                    "Works on words written by Zone’s speech model.",
                ])
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                Toggle("Caps lock drops punctuation", isOn: $settings.capsLockDropsPunctuation)
            } header: {
                Text("Caps lock")
            } footer: {
                SettingsNote("Caps lock drops punctuation", "Dictate in all caps with fewer marks.", detail: "Double-tap Shift to dictate IN ALL CAPS.", points: [
                    "**On:** skips commas, periods, and apostrophes while keeping ? and !.",
                    "**Off:** all caps with normal punctuation.",
                ])
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                Toggle("Smiley face writes :)", isOn: $settings.spokenEmoticons)
            } header: {
                Text("Faces")
            } footer: {
                SettingsNote("Smiley face writes :)", "Say a face to type it.", detail: "Say “see you soon smiley face” to write **see you soon :)**.", points: [
                    "**Casual styles only.** Formal and excited write the words out.",
                    "**Supports** smiley/happy, winky, sad/frowny, crying, kissy, tongue, laughing **:D**, and upside down **(:**.",
                    "**Phrases like “a smiley face”** stay plain words.",
                ])
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                SettingsPicker("California Mode", value: settings.californiaMode.label, selection: $settings.californiaMode) {
                    ForEach(CaliforniaMode.allCases, id: \.self) { mode in Text(mode.label).tag(mode) }
                }
                .tint(Zone.inlineInk(scheme))
            } header: {
                Text("Filler words")
            } footer: {
                SettingsNote("California Mode", "Remove filler uses of “like”.", detail: "Strips filler “like” from dictation: “it was, like, so good” becomes **it was so good**.", points: [
                    "**Light** catches obvious fillers (“I was like really tired”).",
                    "**Aggressive** catches edge cases (“it took like five minutes”).",
                    "**Real uses stay:** “I like pizza”, “looks like rain”, “I was like, no way”.",
                    "**Read before you send:** it can cut a word you meant.",
                    "**History keeps** the unedited transcript.",
                ])
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                Toggle("Speed up speech in Zone", isOn: $settings.fasterDictation)
            } header: {
                Text("Advanced")
            } footer: {
                SettingsNote("Speed up speech in Zone", "Only in Zone.", detail: "Dictate or start a note with Zone on screen. No boost in other apps. Off, Zone’s Mini speech model uses the main chip (CPU). On, the Neural Engine can help once a second copy of Mini is ready.", startsExpanded: true) {
                    SpeechSpeedTable()
                }
            }
            .listRowBackground(Zone.card(scheme))
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Dictation options")
        .zoneBackButton()
        .navigationBarTitleDisplayMode(.inline)
        .zoneScreen()
    }
}

/// The four styles, each with the same sentence written its way by the code that writes a
/// dictation (`TextStyle.example`), so a style can be chosen by reading it.
private struct TextStyleSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Form {
            Section {
                ForEach(TextStyle.allCases, id: \.self) { style in
                    Button {
                        settings.defaultTextStyle = style
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(style.label)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Zone.ink(scheme))
                                Text(style.example(autoCapitalization: settings.autoCapitalizationEnabled))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                                .foregroundStyle(Zone.accentTone(scheme))
                                .opacity(style == settings.defaultTextStyle ? 1 : 0)
                                .accessibilityHidden(true)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("textStyle.\(style.rawValue)")
                    .accessibilityAddTraits(style == settings.defaultTextStyle ? .isSelected : [])
                }
            } header: {
                Text("Default style")
            } footer: {
                SettingsNote("Keyboard styles", "", detail: settings.hideHomeButton ? "Hold the mic to choose a style." : "Tap Z on the keyboard to choose a style for your next dictation.")
            }
            .listRowBackground(Zone.card(scheme))
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Text style")
        .zoneBackButton()
        .navigationBarTitleDisplayMode(.inline)
        .zoneScreen()
    }
}

private struct DictationSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var scheme
    @State private var editingQuietWait = false
    @State private var showingQuietGuide = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                SettingsPicker("Keep microphone ready", value: settings.inactivityPolicy.label, selection: $settings.sessionTimeout) {
                    ForEach(InactivityPolicy.presets, id: \.timeout) { policy in
                        Text(policy.label).tag(policy.isUnbounded ? 0 : policy.timeout)
                    }
                }
                .tint(Zone.inlineInk(scheme))
                Toggle("Turn on when Zone opens", isOn: $settings.startsSessionOnOpen)
            } header: {
                Text("Standby")
            } footer: {
                SettingsNote("Keep microphone ready", "Choose how long the mic stays ready.", detail: "The keyboard mic starts right away. Choose how long it stays ready.", points: [
                    "**Auto-stops** after this much idle time.",
                    "**Never interrupts** an active dictation or meeting.",
                    "**Paused dictations** wait at least 5 minutes before saving.",
                ])
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                SettingsPicker("When the keyboard closes", value: DictationLimits.hiddenKeyboardLabel(settings.hiddenKeyboardGrace), selection: $settings.hiddenKeyboardGrace) {
                    ForEach(DictationLimits.hiddenKeyboardChoices, id: \.self) { grace in
                        Text(DictationLimits.hiddenKeyboardLabel(grace)).tag(grace)
                    }
                }
                .tint(Zone.inlineInk(scheme))
                Toggle("Finish when quiet", isOn: $settings.finishWhenQuiet)
                    .onChange(of: settings.finishWhenQuiet) { _, on in
                        if on, !UserDefaults.standard.bool(forKey: QuietFinishGuideView.seenKey) { showingQuietGuide = true }
                    }
                if settings.finishWhenQuiet {
                    SettingsPicker("Wait for silence", value: editingQuietWait ? "Custom" : SilenceFinish.waitLabel(settings.finishWhenQuietWait), selection: Binding<TimeInterval?>(
                        get: { editingQuietWait ? nil : settings.finishWhenQuietWait },
                        set: { wait in
                            editingQuietWait = wait == nil
                            if let wait { settings.finishWhenQuietWait = wait }
                        }
                    )) {
                        ForEach(SilenceFinish.waitChoices(including: settings.finishWhenQuietWait), id: \.self) { wait in
                            Text(SilenceFinish.waitLabel(wait)).tag(Optional(wait))
                        }
                        Text("Custom").tag(nil as TimeInterval?)
                    }
                    .tint(Zone.inlineInk(scheme))
                    if editingQuietWait {
                        Stepper(SilenceFinish.waitLabel(settings.finishWhenQuietWait),
                                value: $settings.finishWhenQuietWait, in: SilenceFinish.customWaitRange, step: 1)
                            .accessibilityIdentifier("settings.customQuietWait")
                    }
                }
                Button("How it works") { showingQuietGuide = true }
                    .buttonStyle(ZoneLinkButtonStyle())
            } header: {
                Text("While dictating")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsNote("When the keyboard closes", "Keep recording when you leave the keyboard.", detail: "Keep dictating when the keyboard closes, like viewing a full-screen photo or switching apps.", points: [
                        "**Stop anytime** from the Dynamic Island or Lock Screen.",
                        "**Until I stop** requires Live Activities (otherwise caps at 5 minutes).",
                        "**Auto-stopped dictations** are saved in History.",
                    ])
                    SettingsNote("Finish when quiet", "Silence ends dictation only.", detail: "Stop talking and your words go in. Notes don’t stop this way.", points: [
                        "**Waits for your first word.** Speaking again restarts the timer.",
                        "The default wait is 5 seconds. Choose Custom for any whole second from 1 to 60.",
                    ])
                }
            }
            .listRowBackground(Zone.card(scheme))
        }
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $showingQuietGuide) {
            QuietFinishGuideView().presentationDetents([.large])
        }
        .navigationTitle("Microphone and timing")
        .zoneBackButton()
        .navigationBarTitleDisplayMode(.inline)
        .zoneScreen()
    }
}

struct KeyboardSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var scheme

    @State private var recognitionMode = KeyboardVoiceRoute.Mode.standard

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                LabeledContent("Full Access", value: accessStatus)
                Button(coordinator.keyboardPresence?.hasFullAccess == false ? "Allow Full Access" : "Open Zone in iPhone Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            } footer: {
                SettingsNote("Full Access", "Enable Zone in iPhone Settings.", detail: "Open **Settings → Apps → Zone → Keyboards**, enable Zone and **Allow Full Access**, then open the keyboard once.", points: [
                    "**Full Access** lets the keyboard receive dictated text from the Zone app locally.",
                ])
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    SettingsPicker("Hold the space bar", value: settings.spaceHold.label, selection: $settings.spaceHold) {
                        Text(SpaceHold.moveCursor.label).tag(SpaceHold.moveCursor)
                        Text(SpaceHold.talk.label).tag(SpaceHold.talk)
                    }
                    .tint(Zone.inlineInk(scheme))
                    .accessibilityIdentifier("keyboard.spaceHold")
                    if settings.spaceHold == .talk {
                        SettingsNote("Hold to talk", "Let go to insert.", detail: settings.spaceHoldTalkHint)
                    }
                }
                NavigationLink {
                    FeedbackSettingsView()
                } label: {
                    Label("Sounds and haptics", systemImage: "speaker.wave.2")
                }
                .accessibilityIdentifier("settings.soundsAndHaptics")
            }
            .listRowBackground(Zone.card(scheme))

            if KeyboardSpeechAssets.isSupported {
                Section {
                    Toggle("Dictate without opening Zone", isOn: $settings.dictatesInKeyboard)
                        .accessibilityIdentifier("keyboard.dictatesInKeyboard")
                    NavigationLink("Keyboard recognition") { KeyboardVoiceSettings() }
                    Toggle(KeyboardModelCopy.neverAppleTitle, isOn: $settings.neverAppleSpeech)
                        .accessibilityIdentifier("keyboard.neverAppleSpeech")
                    if !settings.neverAppleSpeech && settings.dictatesInKeyboard {
                        Button("Download Apple’s fallback speech model") {
                            Task { await settings.refreshKeyboardSpeechInForeground(downloadRequested: true) }
                        }
                    }
                } header: {
                    Text("Keyboard microphone")
                } footer: {
                    SettingsNote("Dictate without opening Zone", "Use the keyboard mic on iOS 26.",
                                 detail: KeyboardModelCopy.settingsNote(mode: recognitionMode, enabled: settings.dictatesInKeyboard,
                                                                      neverApple: settings.neverAppleSpeech))
                        .accessibilityIdentifier("keyboard.modelNote")
                }
                .listRowBackground(Zone.card(scheme))
            }

            Section {
                Toggle("Swipe typing (Beta)", isOn: $settings.swipeTypingEnabled)
                if settings.swipeTypingEnabled {
                    Toggle("Learn from swipe corrections", isOn: $settings.swipeLearningEnabled)
                    Button("Reset swipe learning") { settings.resetSwipeLearning() }
                    Picker("Swipe trail", selection: $settings.swipeTrailStyle) {
                        ForEach(SwipeTrailStyle.allCases, id: \.self) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .tint(Zone.inlineInk(scheme))
                    .accessibilityIdentifier("keyboard.swipeTrail")
                    SettingsNote("Swipe typing", "Slide across letters to type.", detail: "Slide across keys to write words.", points: [
                        "**Fix a word:** tap an alternative in the strip, or backspace and retype.",
                        "**Learning** adapts locally to your fixes; Reset applies next time the keyboard opens.",
                        "**Trail** follows your keyboard color, or Rainbow Road turns through every color as you swipe.",
                    ])
                }
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                Toggle("One-handed keyboard", isOn: $settings.oneHandedEnabled)
                    .accessibilityIdentifier("keyboard.oneHanded")
                if settings.oneHandedEnabled {
                    Picker("Thumb", selection: $settings.oneHandedSide) {
                        ForEach(OneHandedSide.allCases, id: \.self) { side in
                            Text(side.label).tag(side)
                        }
                    }
                    .tint(Zone.inlineInk(scheme))
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("keyboard.oneHandedSide")
                    VStack(alignment: .leading, spacing: 10) {
                        OneHandedPreview(side: settings.oneHandedSide, width: settings.oneHandedWidth)
                        HStack {
                            Text("Width")
                            Spacer()
                            Text("\(Int((settings.oneHandedWidth * 100).rounded()))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.oneHandedWidth, in: OneHandedLayout.widthRange, step: 0.01) {
                            Text("Width")
                        } minimumValueLabel: {
                            Image(systemName: "arrow.right.and.line.vertical.and.arrow.left").accessibilityLabel("Narrower")
                        } maximumValueLabel: {
                            Image(systemName: "arrow.left.and.line.vertical.and.arrow.right").accessibilityLabel("Wider")
                        }
                        .accessibilityValue("\(Int((settings.oneHandedWidth * 100).rounded())) percent")
                        .accessibilityIdentifier("keyboard.oneHandedWidth")
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("One-handed")
            } footer: {
                SettingsNote("One-handed keyboard", "Bring the keys closer to one thumb.", detail: "Moves the keys toward one thumb on larger iPhones.", points: [
                    "**Hold 123** on the keyboard and slide to left, full width or right.",
                    "**Beside the keys,** the top button switches sides and the arrow goes back to full width.",
                    "**80%** matches Apple's one-handed keyboard. Your choice stays until you change it.",
                ])
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                Toggle("Auto-Capitalization", isOn: $settings.autoCapitalizationEnabled)
                Toggle("Autocorrect", isOn: $settings.autocorrectEnabled)
                Toggle("Suggestions", isOn: $settings.showSuggestions)
                Toggle("Smart punctuation", isOn: $settings.smartPunctuation)
                Toggle("Follow Shift", isOn: $settings.dictationFollowsShift)
            } header: {
                Text("Typing")
            } footer: {
                SettingsNote("Typing", "Follow Shift starts dictation with the keyboard’s Shift state.", detail: "Follow Shift matches the first letter of dictation to Shift. In Casual, Auto-Capitalization keeps capitals for names, I and acronyms. Turn it off for lowercase.")
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                Toggle("Paste key", isOn: $settings.showsPasteKey)
                Toggle("Suggest emoji for words", isOn: $settings.emojiPredictions)
                Toggle("Emoji key", isOn: $settings.showsEmojiKey)
                Toggle("Hide the Z style button", isOn: $settings.hideHomeButton)
                    .accessibilityIdentifier("keyboard.hideHomeButton")
                SettingsNote("Emoji by colon", "Type :pizza, then tap 🍕", keepsExampleVisible: true, detail: "Type a colon at the start of a word, then at least two letters. Tap the emoji to insert it. Colon search works even with word suggestions off. Passwords, addresses and number fields keep literal text.")
            } header: {
                Text("Keys")
            } footer: {
                let styleHint = settings.hideHomeButton
                    ? "With the Z hidden, hold the mic to open the menu at Text style."
                    : "Tap Z for Home, Notes, text styles and Settings."
                SettingsNote("Keys", styleHint, detail: "\(styleHint) Picking a style also rewrites the dictation you just made if it is still at the cursor. Hold an emoji for skin tones.")
            }
            .listRowBackground(Zone.card(scheme))
        }
        .scrollContentBackground(.hidden)
        .onAppear { recognitionMode = KeyboardVoiceRoute.load().mode }
        .navigationTitle("Zone keyboard")
        .zoneBackButton()
        .navigationBarTitleDisplayMode(.inline)
        .zoneScreen()
    }

    private var accessStatus: String {
        guard let presence = coordinator.keyboardPresence else { return "Open the keyboard to check" }
        return presence.hasFullAccess ? "On" : "Off"
    }
}

/// Shared by the top-level form and the Home shortcut.
struct PersonalizeSection: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var scheme

    var query = ""

    var body: some View {
        @Bindable var settings = settings
        Section {
            if SettingsSubject.preview.matches(query) {
                KeyboardLookPreview()
            }
            if SettingsSubject.scheme.matches(query) {
                Picker(selection: $settings.appearance) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                } label: {
                    Label("Color scheme", systemImage: "circle.lefthalf.filled")
                }
                .tint(Zone.inlineInk(scheme))
            }
            if SettingsSubject.accent.matches(query) {
                Picker("Accent", selection: $settings.accent) {
                    ForEach(AccentChoice.allCases, id: \.self) { choice in
                        HStack {
                            Circle().fill(Color(hex: choice.darkHex))
                                .overlay(Circle().strokeBorder(Color(hex: choice.lightHex), lineWidth: 3))
                                .frame(width: 22, height: 22)
                                .accessibilityIgnoresInvertColors()
                            Text(choice.label).foregroundStyle(Zone.ink(scheme))
                        }
                        .tag(choice)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.accent")
                .tint(Zone.inlineInk(scheme))
            }
            if SettingsSubject.graphic.matches(query) {
                PersonalizeVoiceRow()
                    .tint(Zone.inlineInk(scheme))
            }
            if SettingsSubject.micLight.matches(query) {
                Picker(selection: $settings.micLightStyle) {
                    ForEach(MicLightStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                } label: {
                    Label("Mic light", systemImage: "capsule")
                }
                .tint(Zone.inlineInk(scheme))
                .accessibilityValue(settings.micLightStyle.label)
                .accessibilityIdentifier("settings.micLight")
            }
            if SettingsSubject.island.matches(query) {
                NavigationLink {
                    IslandSettingsView()
                } label: {
                    LabeledContent {
                        HStack(spacing: 6) {
                            if settings.islandWhileReady && !dynamicTypeSize.isAccessibilitySize {
                                IslandLookPreview(look: settings.islandStyle.look, accent: settings.accent,
                                                  words: settings.wordsDictated, still: true)
                                    .accessibilityHidden(true)
                                    .scaleEffect(0.42)
                                    .frame(width: 53, height: 14)
                            }
                            Text(islandSummary)
                        }
                    } label: {
                        Label("Dynamic Island", systemImage: "capsule.fill")
                    }
                }
                .accessibilityIdentifier("settings.island")
            }
            if SettingsSubject.meeting.matches(query) {
                NavigationLink {
                    MeetingAppearanceView()
                } label: {
                    Label("Meeting appearance", systemImage: "waveform.path")
                }
                .accessibilityIdentifier("settings.meetingAppearance")
            }
            if SettingsSubject.order.matches(query) {
                Picker(selection: $settings.notesFirst) {
                    Text("Notes first").tag(true)
                    Text("History first").tag(false)
                } label: {
                    Label("Home list order", systemImage: "house")
                }
                .tint(Zone.inlineInk(scheme))
            }
        } header: {
            Text("Personalize")
        } footer: {
            if settings.meterStyle == .scope && SettingsSubject.graphic.matches(query) {
                SettingsNote("Hex", "Oscilloscope by Christopher Langton", detail: "Oscilloscope by Christopher Langton, adapted from Hex.")
            }
        }
        .pickerStyle(.menu)
        .listRowBackground(Zone.card(scheme))
    }

    private var islandSummary: String {
        guard settings.islandWhileReady else { return "Off" }
        guard AppSettings.showsIslandGallery else { return "On" }
        return settings.islandStyle.look.title
    }

}

private struct FeedbackSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Start and stop sounds", isOn: $settings.soundsEnabled)
                if settings.soundsEnabled {
                    SettingsPicker("Sound", value: settings.soundSet.label, selection: $settings.soundSet) {
                        ForEach(DictationSounds.Set.allCases) { set in
                            Text(set.label).tag(set)
                        }
                    }
                    .tint(Zone.inlineInk(scheme))
                    .onChange(of: settings.soundSet) { _, set in coordinator.previewSound(set) }
                }
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                HStack {
                    Toggle("Haptics", isOn: $settings.hapticsEnabled)
                    SettingsNote("Haptics", "", detail: "Feel a tap when dictation starts or stops and when you press a key.")
                }
            }
            .listRowBackground(Zone.card(scheme))
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Sounds and haptics")
        .zoneBackButton()
        .navigationBarTitleDisplayMode(.inline)
        .zoneScreen()
    }
}

private struct SpeechSpeedTable: View {
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("With the switch on").font(.headline)
            row("Dictation or notes in Zone", "Can use both chips if ready when you start.")
            row("Keyboard in another app", "No boost, even with Zone on standby or closed.")
            row("Action Button away from Zone", "No boost while locked or in another app.")
            row("Meetings", "Each part can use both chips if Zone is on screen when it turns that part into text.")
            Text("The extra copy uses more memory. You can record while it warms up. If it fails, Zone tries again on the CPU. That can take longer.")
        }
    }

    private func row(_ title: String, _ effect: String) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        return VStack(alignment: .leading, spacing: 8) {
            Divider()
            layout {
                Text(title).fontWeight(.medium).frame(maxWidth: .infinity, alignment: .leading)
                Text(effect).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct SettingsPicker<Selection: Hashable, Options: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    let value: String
    @Binding var selection: Selection
    @ViewBuilder let options: () -> Options

    init(_ title: String, value: String, selection: Binding<Selection>, @ViewBuilder options: @escaping () -> Options) {
        self.title = title
        self.value = value
        _selection = selection
        self.options = options
    }

    var body: some View {
        if typeSize.isAccessibilitySize {
            Menu {
                Picker(title, selection: $selection, content: options).pickerStyle(.inline)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).foregroundStyle(.primary)
                    HStack(alignment: .firstTextBaseline) {
                        Text(value).fixedSize(horizontal: false, vertical: true)
                        Image(systemName: "chevron.up.chevron.down").font(.footnote).accessibilityHidden(true)
                    }
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityLabel(title)
            .accessibilityValue(value)
        } else {
            Picker(title, selection: $selection, content: options)
        }
    }
}

/// A short setting summary with an accessible button for the full explanation.
struct SettingsNote<Extra: View>: View {
    @State private var showing = false
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    let summary: String

    let lead: String
    let points: [String]

    let extra: Extra
    let startsExpanded: Bool
    let keepsExampleVisible: Bool

    init(_ summary: String, points: [String]) where Extra == EmptyView {
        self.init("Setting details", summary, points: points)
    }

    init(_ title: String, _ summary: String, keepsExampleVisible: Bool = false, detail: String = "", points: [String] = [],
         startsExpanded: Bool = false, @ViewBuilder extra: () -> Extra = { EmptyView() }) {
        self.keepsExampleVisible = keepsExampleVisible
        self.extra = extra()
        self.startsExpanded = startsExpanded
        self.title = title
        self.summary = summary
        self.lead = detail
        self.points = points
    }

    var body: some View {
        HStack {
            if !summary.isEmpty {
                ViewThatFits(in: .horizontal) {
                    Text(summary).font(.footnote).foregroundStyle(.secondary).fixedSize()
                    if keepsExampleVisible {
                        Text(summary).font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Color.clear.frame(width: 0, height: 0)
                    }
                }
                Spacer(minLength: 4)
            }
            Button { showing = true } label: {
                Image(systemName: "info.circle")
                    .font(.body)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("About \(title)")
        }
        .sheet(isPresented: $showing) {
            NavigationStack {
                ScrollView {
                    details.frame(maxWidth: .infinity, alignment: .leading).padding()
                }
                .navigationTitle(title)
                .zoneScreen()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ZoneBarItem(.confirmationAction) { Button("Done") { showing = false } }
                }
            }
            .presentationDetents(startsExpanded || typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(lead.isEmpty ? summary : lead))
                .fixedSize(horizontal: false, vertical: true)
            extra
            if !points.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(points, id: \.self) { point in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Circle().frame(width: 3.5, height: 3.5)
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                                .accessibilityHidden(true)
                            Text(LocalizedStringKey(point))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .font(.body)
    }
}
