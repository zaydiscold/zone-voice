// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(LinkCoordinator.self) private var link
    @Environment(WhatsNewGate.self) private var whatsNew
    @Environment(\.colorScheme) private var scheme
    @State private var showsTour = false
    @State private var showsFeedback = false
    @State private var sharingZone = false
    @State private var showsShareCode = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                NavigationLink {
                    ModelLibraryView()
                } label: {
                    LabeledContent("Speech model", value: coordinator.selectedModel.shortName)
                }
                .accessibilityIdentifier("settings.speechModel")
                Picker("Text style", selection: $settings.defaultTextStyle) {
                    ForEach(TextStyle.allCases, id: \.self) { style in
                        Text(style.label).tag(style)
                    }
                }
                NavigationLink("My words") { PersonalWordsView() }
                NavigationLink {
                    HandlesSettingsView()
                } label: {
                    LabeledContent("@ Handles", value: settings.handleRecognition ? "Smart @ on" : "At sign")
                }
                NavigationLink {
                    DictationSettingsView()
                } label: {
                    LabeledContent("Microphone and timing", value: settings.inactivityPolicy.label)
                }
            } header: {
                Text("Dictation")
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                NavigationLink {
                    KeyboardSettingsView()
                } label: {
                    LabeledContent("Keyboard", value: keyboardStatus)
                }
                NavigationLink("Action Button and Shortcuts") { ShortcutHelpView() }
                NavigationLink {
                    ComputersView()
                } label: {
                    LabeledContent("Computers (Beta)", value: computersStatus)
                }
                .accessibilityIdentifier("settings.computers")
            } header: {
                Text("Setup")
            } footer: {
                if coordinator.keyboardPresence?.hasFullAccess != true {
                    Text("Open Keyboard to finish setup and allow Full Access.")
                }
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                NavigationLink {
                    AppearanceSettingsView()
                } label: {
                    LabeledContent("Appearance", value: settings.appearance.label)
                }
                NavigationLink {
                    IslandSettingsView()
                } label: {
                    LabeledContent("Dynamic Island", value: settings.islandLook.title)
                }
                NavigationLink("Meeting appearance") { MeetingAppearanceView() }
                NavigationLink {
                    FeedbackSettingsView()
                } label: {
                    LabeledContent("Sounds and haptics", value: feedbackSummary)
                }
            } header: {
                Text("Personalize")
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                NavigationLink {
                    ExperimentalSettingsView()
                } label: {
                    LabeledContent("Experimental", value: experimentalSummary)
                }
            } footer: {
                Text("Early features still being tuned.")
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                Button("Take the tour") { showsTour = true }
                    .foregroundStyle(Zone.ink(scheme))
                // Say it or type it; it leaves as an email from the person's own mail app.
                Button("Send feedback") { showsFeedback = true }
                    .foregroundStyle(Zone.ink(scheme))
                    .accessibilityIdentifier("settings.feedback")
                // What happened to each recording, with no words in it; shareable, so a tester can
                // send it when a recording misbehaves.
                NavigationLink("Recording log") { RecordingLogView() }
                // Measurement tools for development builds only; App Review guideline 2.5.19
                // treats hidden or undocumented features in a shipped build as grounds for removal.
                #if DEBUG
                NavigationLink("Diagnostics") { DiagnosticsView() }
                #endif
            } header: {
                Text("Help")
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                // The message and both links, no card: works before the first dictation too.
                Button { sharingZone = true } label: {
                    Label("Share Zone with a friend", systemImage: "square.and.arrow.up")
                }
                .foregroundStyle(Zone.ink(scheme))
                // Hold for the links on their own, or a code a friend scans from this screen.
                .contextMenu {
                    Button { showsShareCode = true } label: { Label("Show QR code", systemImage: "qrcode") }
                    Button { Clipboard.copy(ZoneLinks.appStore.absoluteString); Haptics.success() } label: {
                        Label("Copy App Store link", systemImage: "link")
                    }
                    Button { Clipboard.copy(ZoneLinks.testFlight.absoluteString); Haptics.success() } label: {
                        Label("Copy beta link", systemImage: "testtube.2")
                    }
                }
                .sheet(isPresented: $showsShareCode) { ShareCodeSheet() }
                .background(ShareSheet(isPresented: $sharingZone, items: [ShareInviteItem(sendsToComputer: link.isPaired)]) { completed, activity in
                    if completed, ShareSheet.reachesSomeone(activity) { settings.recordShare() }
                })
            } footer: {
                Text("Shares the App Store and TestFlight beta links. Hold it for a QR code or just the links.")
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                NavigationLink("Dictation history") { HistoryView() }
                NavigationLink("Backup and export") { LibraryBackupView() }
                NavigationLink("Delete data") { YourDataView() }
            } header: {
                Text("Your data")
            } footer: {
                Text(LinkCopy.yourDataFooter(link.computers.map(\.name)))
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                NavigationLink("A note from Zayd") { AboutView() }
                // The person's own tap opens the App Store's review sheet. Zone never asks for
                // this itself; Apple's prompt does (ReviewPrompter).
                Button("Rate Zone on the App Store") { UIApplication.shared.open(ZoneLinks.writeReview) }
                    .foregroundStyle(Zone.ink(scheme))
                    .accessibilityIdentifier("settings.rate")
                NavigationLink {
                    VersionHistoryView()
                } label: {
                    LabeledContent("Version", value: version)
                }
                .accessibilityHint("Opens the version history")
                .accessibilityIdentifier("settings.version")
                NavigationLink("Privacy") { PrivacyView() }
                NavigationLink("Acknowledgments") {
                    ScrollView { Text(SwipeNeuralScorer.notices).font(.caption2).foregroundStyle(.secondary).padding() }
                        .navigationTitle("Acknowledgments")
                        .zoneBackButton()
                }
            } header: {
                Text("About")
            } footer: {
                // The FUTO Model Weights License requires this line to stay visible in Settings or About.
                Text("Swipe typing powered by FUTO Swipe.").font(.caption2)
            }
            .listRowBackground(Zone.card(scheme))
        }
        .scrollContentBackground(.hidden)
        .tint(Zone.accentText(scheme))
        .navigationTitle("Settings")
        .zoneBackButton()
        .sheet(isPresented: $showsTour) { TourView() }
        .sheet(isPresented: $showsFeedback) { FeedbackView() }
        .zoneScreen()
    }

    private var keyboardStatus: String {
        guard let presence = coordinator.keyboardPresence else { return "Finish setup" }
        return presence.hasFullAccess ? "Full Access on" : "Needs Full Access"
    }

    private var computersStatus: String {
        let paired = link.computers.count
        let paused = link.computers.filter(\.isPaused).count
        if paired == 0 { return "Off" }
        if paused == paired { return "Paused" }
        return paused == 0 ? "\(paired) paired" : "\(paired) paired, \(paused) paused"
    }

    private var feedbackSummary: String {
        switch (settings.soundsEnabled, settings.hapticsEnabled) {
        case (true, true): return "Both on"
        case (true, false): return "Sounds on"
        case (false, true): return "Haptics on"
        case (false, false): return "Off"
        }
    }

    private var experimentalSummary: String {
        let on = [settings.handleRecognition, settings.spokenCorrections, settings.capsLockDropsPunctuation,
                  settings.spokenEmoticons, settings.smallOrdinals, settings.checksDoubtfulWords,
                  settings.californiaMode != .off].filter { $0 }.count
        return on == 0 ? "Off" : "\(on) on"
    }

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let marketing = whatsNew.installed?.description ?? info["CFBundleShortVersionString"] as? String ?? ""
        return "\(marketing) (\(info["CFBundleVersion"] as? String ?? ""))"
    }
}

private struct ExperimentalSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Smart @", isOn: $settings.handleRecognition)
                NavigationLink("@ Handles") { HandlesSettingsView() }
            } header: {
                Text("Dictation")
            } footer: {
                SettingsNote("Say “at Kevin” to write **@kevin** without saying “at sign”.", points: [
                    "**Off:** only saying “at sign” writes an @ handle.",
                ])
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                Toggle("Scratch that and no wait (Beta)", isOn: $settings.spokenCorrections)
            } header: {
                Text("Spoken corrections")
            } footer: {
                SettingsNote("Say “meet Tuesday, scratch that, Wednesday” to write **meet Wednesday**.", points: [
                    "**“Scratch that” alone** undoes your last dictation. Tap Redo or check History to bring it back.",
                    "**History keeps** the full raw transcript.",
                    "**Beta:** double-check before sending in case it trims too much.",
                ])
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                Toggle("Check unsure words (Beta)", isOn: $settings.checksDoubtfulWords)
            } header: {
                Text("Unsure words")
            } footer: {
                SettingsNote("Flags up to three low-confidence words in the keyboard strip after you dictate. Tap one to swap it.", points: [
                    "**Learns from picks:** chosen fixes move to the top next time, and kept words get flagged less.",
                    "**Rare:** only when Zone is more likely wrong than right, so most dictations show none.",
                    "**Fluid Speech Mini only.**",
                ])
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                Toggle("Caps lock drops punctuation (Beta)", isOn: $settings.capsLockDropsPunctuation)
            } header: {
                Text("Caps lock")
            } footer: {
                SettingsNote("Double-tap Shift to dictate IN ALL CAPS.", points: [
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
                SettingsNote("Say “see you soon smiley face” to write **see you soon :)**.", points: [
                    "**Casual styles only.** Formal and excited write the words out.",
                    "**Supports** smiley/happy, winky, sad/frowny, crying, kissy, tongue, laughing **:D**, and upside down **(:**.",
                    "**Phrases like “a smiley face”** stay plain words.",
                ])
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                Toggle("1st, 2nd, 3rd as numbers", isOn: $settings.smallOrdinals)
            } header: {
                Text("Ordinal numbers")
            } footer: {
                SettingsNote("10th and up are always digits. Turn this on to write 1st through 9th as digits too (“May **3rd**”, “came in **2nd**”).", points: [
                    "**Idioms stay words:** “wait a second”, “at first”, and “on second thought”.",
                ])
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                Picker("California Mode (Beta)", selection: $settings.californiaMode) {
                    ForEach(CaliforniaMode.allCases, id: \.self) { mode in Text(mode.label).tag(mode) }
                }
            } header: {
                Text("Filler words")
            } footer: {
                SettingsNote("Strips filler “like” from dictation: “it was, like, so good” becomes **it was so good**.", points: [
                    "**Light** catches obvious fillers (“I was like really tired”).",
                    "**Aggressive** catches edge cases (“it took like five minutes”).",
                    "**Real uses stay:** “I like pizza”, “looks like rain”, “I was like, no way”.",
                    "**Beta:** it can cut a word you meant, so read before you send.",
                    "**History keeps** the unedited transcript.",
                ])
            }
            .listRowBackground(Zone.card(scheme))
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Experimental")
        .zoneBackButton()
        .navigationBarTitleDisplayMode(.inline)
        .zoneScreen()
    }
}

/// Two layers: "at sign" always tags; Smart @ (experimental) also tags a bare "at" and a name.
private struct HandlesSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var draft = ""
    @State private var error: String?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                LabeledContent("“At sign” + a name", value: "Always on")
            } header: {
                Text("Say at sign")
            } footer: {
                SettingsNote("Say “at sign Kevin” to write **@kevin**.", points: [
                    "**Always active** whether Smart @ is on or off.",
                    "**Spell unusual handles:** “at sign T X M” writes **@txm**.",
                    "**“The at sign”** stays plain words.",
                ])
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                ForEach(settings.handles, id: \.self) { handle in
                    Text("@" + handle)
                }
                .onDelete { offsets in
                    // The list can change under the swipe (the keyboard learns a handle), so an offset may be stale.
                    let removed = offsets.compactMap { settings.handles.indices.contains($0) ? settings.handles[$0] : nil }
                    save { try settings.removeHandles(removed) }
                }
                TextField("Add a handle", text: $draft)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onSubmit(addHandle)
                Button("Add handle", action: addHandle)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Your handles")
            } footer: {
                SettingsNote("Save **zayd**, and “at zayd” writes **@zayd**.", points: [
                    "**Requires Smart @** (or say “at sign zayd” anytime).",
                    "**Matches split speech** when recognition breaks a handle into words or drops a doubled letter.",
                    "**Auto-learns** any handle you dictate with “at sign” while Smart @ is on.",
                    "**Private:** handles stay on this iPhone. Swipe left to delete one.",
                ])
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                Toggle("Smart @ (Experimental)", isOn: $settings.handleRecognition)
            } header: {
                Text("Smart @")
            } footer: {
                SettingsNote("Say “at Kevin” to write **@kevin**, or spell it: “at T X M” writes **@txm**.", points: [
                    "**Recognizes** common names, My words, and saved handles.",
                    "**Normal phrases stay normal:** “leave at will”, “at everyone”, and “at here” stay words.",
                    "**Experimental:** double-check before sending.",
                ])
            }
            .listRowBackground(Zone.card(scheme))
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("@ Handles")
        .zoneBackButton()
        .navigationBarTitleDisplayMode(.inline)
        .zoneScreen()
        .onAppear { settings.refreshHandles() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { settings.refreshHandles() }
        }
        .alert("Your handles", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func addHandle() {
        guard let normalized = PersonalVocabulary.normalizedHandles([draft]).first else {
            error = "Use letters, numbers, underscores, or periods, with at least one letter."
            return
        }
        do {
            try settings.addHandle(normalized)
            draft = ""
        } catch {
            self.error = "Couldn't save handle. Try again."
        }
    }

    private func save(_ change: () throws -> Void) {
        do { try change() } catch { self.error = "Couldn't save handles. Try again." }
    }
}

private struct DictationSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var scheme
    @State private var showingQuietGuide = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Keep microphone ready", selection: $settings.sessionTimeout) {
                    ForEach(InactivityPolicy.presets, id: \.timeout) { policy in
                        Text(policy.label).tag(policy.isUnbounded ? 0 : policy.timeout)
                    }
                }
                Toggle("Turn on when Zone opens", isOn: $settings.startsSessionOnOpen)
            } footer: {
                SettingsNote("Keeps the mic ready so keyboard dictation starts instantly, without opening Zone.", points: [
                    "**Auto-stops** after this much idle time.",
                    "**Never interrupts** an active dictation or meeting.",
                    "**Paused dictations** wait at least 5 minutes before saving.",
                ])
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                Picker("Keyboard hidden", selection: $settings.hiddenKeyboardGrace) {
                    ForEach(DictationLimits.hiddenKeyboardChoices, id: \.self) { grace in
                        Text(DictationLimits.hiddenKeyboardLabel(grace)).tag(grace)
                    }
                }
            } header: {
                Text("While dictating")
            } footer: {
                SettingsNote("Keep dictating when the keyboard closes, like viewing a full-screen photo or switching apps.", points: [
                    "**Stop anytime** from the Dynamic Island or Lock Screen.",
                    "**Until I stop** requires Live Activities (otherwise caps at 5 minutes).",
                    "**Auto-stopped dictations** are saved in History.",
                ])
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                Toggle("Finish when quiet", isOn: $settings.finishWhenQuiet)
                    .onChange(of: settings.finishWhenQuiet) { _, on in
                        if on, !UserDefaults.standard.bool(forKey: QuietFinishGuideView.seenKey) { showingQuietGuide = true }
                    }
                if settings.finishWhenQuiet {
                    Picker("After", selection: $settings.finishWhenQuietWait) {
                        ForEach(SilenceFinish.waitChoices, id: \.self) { wait in
                            Text(SilenceFinish.waitLabel(wait)).tag(wait)
                        }
                    }
                }
                Button("How it works") { showingQuietGuide = true }
            } footer: {
                SettingsNote("Stop talking and the dictation finishes by itself, as if you tapped ✓.", points: [
                    "**Waits for your first word**, and any sound starts the wait over.",
                    "**Shorter waits** can end a dictation while you think. 30 seconds never did in our tests.",
                ])
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                Toggle("Learn names from the text box", isOn: $settings.usesTypedTextAsHints)
            } footer: {
                Text("Uses nearby text in the field to recognize names locally.")
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

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                LabeledContent("Full Access", value: accessStatus)
                Button("Open iOS keyboard settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            } footer: {
                SettingsNote("Open **Settings → Apps → Zone → Keyboards**, enable Zone and **Allow Full Access**, then open the keyboard once.", points: [
                    "**Full Access** lets the keyboard receive dictated text from the Zone app locally.",
                ])
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                Toggle("Hide the Z", isOn: $settings.hideHomeButton)
                    .accessibilityIdentifier("keyboard.hideHomeButton")
            } header: {
                Text("Appearance")
            } footer: {
                // Says where the styles went the moment the Z is hidden.
                SettingsNote(settings.hideHomeButton
                    ? "With the Z hidden, **hold the microphone** to choose the style for your next dictation."
                    : "Tap the Z on the keyboard to choose the style for your next dictation. Holding the microphone does the same.", points: [
                    "**Open Zone** anytime by holding the keyboard icon.",
                ])
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                Toggle("Swipe typing (Beta)", isOn: $settings.swipeTypingEnabled)
                if settings.swipeTypingEnabled {
                    Toggle("Learn from swipe corrections", isOn: $settings.swipeLearningEnabled)
                    Button("Reset swipe learning") { settings.resetSwipeLearning() }
                    SettingsNote("Slide across keys to write words.", points: [
                        "**Fix a word:** tap an alternative in the strip, or backspace and retype.",
                        "**Learning** adapts locally to your fixes; Reset applies next time the keyboard opens.",
                    ])
                }
                Toggle("Auto-Capitalization", isOn: $settings.autoCapitalizationEnabled)
                Toggle("Autocorrect", isOn: $settings.autocorrectEnabled)
                Toggle("Suggestions", isOn: $settings.showSuggestions)
                Toggle("Smart punctuation", isOn: $settings.smartPunctuation)
                Toggle("Paste key", isOn: $settings.showsPasteKey)
                Toggle("Emoji key", isOn: $settings.showsEmojiKey)
            } header: {
                Text("Typing")
            } footer: {
                SettingsNote("Turn off **Auto-Capitalization** to keep typed fixes lowercase.", points: [
                    "**Shift and text replacements** keep your chosen casing.",
                    "**Emoji key** sits left of space; hold an emoji for skin tones.",
                ])
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                Toggle("Follow Shift", isOn: $settings.dictationFollowsShift)
                Picker("Hold space", selection: $settings.spaceHold) {
                    ForEach(SpaceHold.allCases, id: \.self) { choice in Text(choice.label).tag(choice) }
                }
                .accessibilityIdentifier("keyboard.spaceHold")
            } header: {
                Text("Dictation")
            } footer: {
                SettingsNote("Matches dictation's starting case to the **Shift** key.", points: [
                    "**Names, I, and acronyms** stay capitalized; very casual stays lowercase.",
                    "**Off:** text style and surrounding punctuation decide.",
                    "**Hold space: Talk** records while you hold space and types it when you let go. Slide sideways to move the cursor. Works while Zone keeps the mic ready.",
                ])
            }
            .listRowBackground(Zone.card(scheme))        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Keyboard")
        .zoneBackButton()
        .navigationBarTitleDisplayMode(.inline)
        .zoneScreen()
    }

    private var accessStatus: String {
        guard let presence = coordinator.keyboardPresence else { return "Open the keyboard to check" }
        return presence.hasFullAccess ? "On" : "Off"
    }
}

struct AppearanceSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(Appearance.allCases) { appearance in
                        Text(appearance.label).tag(appearance)
                    }
                }
                AccentSwatches(selection: $settings.accent)
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                Picker("Voice graphic", selection: $settings.meterStyle) {
                    ForEach(MeterStyle.allCases, id: \.self) { style in Text(style.label).tag(style) }
                }
                if settings.meterStyle == .scope {
                    Text("Scope is the visualizer from Hex, by Christopher Langton, used with thanks.")
                        .font(.footnote)
                        .foregroundStyle(Zone.muted(scheme))
                }
                Picker("Home starts with", selection: $settings.notesFirst) {
                    Text("Notes").tag(true)
                    Text("History").tag(false)
                }
            } header: {
                Text("Layout")
            }
            .listRowBackground(Zone.card(scheme))
        }
        .scrollContentBackground(.hidden)
        // Load-bearing: without the rebuild the pickers' values keep the old accent (checked on the
        // simulator 2026-11-18; `AccentStore.applyToWindows` alone does not retint them).
        .id(settings.accent)
        .navigationTitle("Appearance")
        .zoneBackButton()
        .navigationBarTitleDisplayMode(.inline)
        .zoneScreen()
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
                    Picker("Sound", selection: $settings.soundSet) {
                        ForEach(DictationSounds.Set.allCases) { set in
                            Text(set.label).tag(set)
                        }
                    }
                    .onChange(of: settings.soundSet) { _, set in coordinator.previewSound(set) }
                }
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                Toggle("Haptics", isOn: $settings.hapticsEnabled)
            } footer: {
                Text("Haptics when dictation starts and stops, and on key presses.")
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

/// Named swatches wrap instead of squeezing additional choices into one row.
private struct AccentSwatches: View {
    @Binding var selection: AccentChoice
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Accent")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 12)], spacing: 12) {
                ForEach(AccentChoice.allCases, id: \.self) { choice in
                    Button { selection = choice } label: {
                        VStack(spacing: 6) {
                            Circle()
                                .fill(Color(hex: choice.hex))
                                .frame(width: 32, height: 32)
                                .overlay {
                                    if selection == choice {
                                        Image(systemName: "checkmark")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(Color(hex: choice.foregroundHex))
                                    }
                                }
                            Text(choice.label).font(.caption).foregroundStyle(Zone.ink(scheme))
                        }
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(choice.label)
                    .accessibilityAddTraits(selection == choice ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// A settings footer people actually read: one plain lead sentence, then short points that
/// each open with a **bold label**, so the eye can scan the labels and stop. Strings are
/// Markdown, for bold names of settings and the words a person would say.
struct SettingsNote: View {
    let lead: String
    let points: [String]

    init(_ lead: String, points: [String] = []) {
        self.lead = lead
        self.points = points
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(lead))
                .fixedSize(horizontal: false, vertical: true)
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
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }
}
