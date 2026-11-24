// by zayd/cold @ zayd.wtf

import AVFoundation
import SwiftUI
import ZoneCore

/// The walkthrough from install to the first dictation. One screen, five steps, and the step
/// shown is worked out from the app's real state every time it appears, so a person who leaves
/// for Settings, quits, or comes back tomorrow lands on the step they are actually on:
///
/// 1. the speech model is on the phone (asked for, with its real size, before downloading),
/// 2. the microphone is allowed,
/// 3. the Zone keyboard is added with Full Access (proved when the keyboard first runs, which it
///    does inside the practice box on this screen),
/// 4. one sentence has been dictated through the keyboard,
/// 5. a closing step that says how to use it anywhere.
///
/// Each step says what to do and why in two short lines, has one button, and turns into a
/// checked line saying what happened once it is done.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case model, microphone, keyboard, dictate, done
    }

    @Environment(AppSettings.self) private var settings
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    /// Leaves the walkthrough for this launch; it comes back next launch until a first dictation.
    var onLater: () -> Void = {}
    var onQuickSetup: () -> Void = {}

    @State private var micPermission: AVAudioApplication.recordPermission = AVAudioApplication.shared.recordPermission
    @State private var practiceText = ""
    @State private var visitedSettings = false
    @State private var skippedDictation = false
    /// Words counted when the dictation step was first shown in this visit; nil if it never was.
    @State private var wordsWhenDictateShown: Int?
    /// Set a few seconds after the app counts the first dictation, in case the keyboard's text
    /// never reaches the box, so the walkthrough cannot get stuck.
    @State private var insertionGraceOver = false
    @FocusState private var fieldFocused: Bool

    // MARK: State

    private var modelDone: Bool { coordinator.modelIsReady }
    private var micDone: Bool { micPermission == .granted }
    @State private var keyboardCheckBegan = Date()
    private var keyboardDone: Bool {
        coordinator.keyboardPresence?.seenDuringSetup(since: keyboardCheckBegan)?.hasFullAccess == true
    }
    private var dictateDone: Bool {
        if skippedDictation { return true }
        guard settings.wordsDictated > 0 else { return false }
        // Arriving with a dictation already done (a relaunch) counts at once. Dictating on this
        // step counts once the keyboard's words are in the box, so the box is not taken away
        // while the keyboard is still typing into it.
        guard let shownAt = wordsWhenDictateShown, settings.wordsDictated > shownAt else { return true }
        return !practiceText.isEmpty || insertionGraceOver
    }

    private var current: Step {
        if !modelDone { return .model }
        if !micDone { return .microphone }
        if !keyboardDone { return .keyboard }
        if !dictateDone { return .dictate }
        return .done
    }

    private func isDone(_ step: Step) -> Bool { step.rawValue < current.rawValue }

    // MARK: Body

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if current == .done {
                        finishStep.padding(.top, 28)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Step.allCases.filter { $0 != .done }, id: \.self) { step in
                                stepRow(step).id(step)
                                if step != .dictate { Hairline() }
                            }
                        }
                        .padding(.top, 20)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: current) { _, step in
                withAnimation(Zone.motion) { proxy.scrollTo(step, anchor: .top) }
            }
            // With the keyboard up, bring the step and its box into view above it.
            .onChange(of: fieldFocused) { _, focused in
                guard focused else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    withAnimation(Zone.motion) { proxy.scrollTo(current, anchor: .top) }
                }
            }
        }
        .statusBarBand()
        .safeAreaInset(edge: .bottom) {
            if !fieldFocused {
                actions.padding(.horizontal, 24).padding(.bottom, 12)
            }
        }
        .zoneScreen()
        .animation(Zone.motion, value: current)
        .onAppear {
            micPermission = AVAudioApplication.shared.recordPermission
            coordinator.prepareModelIfNeededForOnboarding()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            micPermission = AVAudioApplication.shared.recordPermission
            coordinator.refreshFromStore()
        }
        .onChange(of: current) { _, step in
            if step == .dictate {
                if wordsWhenDictateShown == nil { wordsWhenDictateShown = settings.wordsDictated }
                armForPractice()
                // The whole of this step happens in the keyboard, so bring it up.
                Task { try? await Task.sleep(for: .milliseconds(300)); fieldFocused = true }
            }
            if step == .done { fieldFocused = false; Haptics.success() }
        }
        .onChange(of: settings.wordsDictated) { _, _ in
            guard current == .dictate else { return }
            Task { try? await Task.sleep(for: .seconds(3)); insertionGraceOver = true }
        }
        .task {
            if current == .dictate {
                if wordsWhenDictateShown == nil { wordsWhenDictateShown = settings.wordsDictated }
                armForPractice()
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("zone").font(.zoneWordmark).foregroundStyle(Zone.ink(scheme))
                Spacer()
                if current != .done {
                    Button("Not now", action: onLater).buttonStyle(ZoneLinkButtonStyle())
                }
            }
            .padding(.top, 8)
            if current != .done {
                DisplayText("Talk anywhere you type.", size: 32)
                Text("No account. Zone transcribes on this iPhone by default.")
                    .font(.subheadline).foregroundStyle(Zone.muted(scheme))
                ShortcutHelpLink()
                Button("Set up one step at a time", action: onQuickSetup)
                    .buttonStyle(ZoneLinkButtonStyle())
                    .accessibilityIdentifier("setup.openLog")
            }
        }
    }

    // MARK: Steps

    @ViewBuilder
    private func stepRow(_ step: Step) -> some View {
        let done = isDone(step)
        let active = step == current
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                marker(step, done: done, active: active)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(step))
                        .font(.body.weight(active ? .semibold : .medium))
                        .foregroundStyle(active || done ? Zone.ink(scheme) : Zone.muted(scheme))
                    if done {
                        Text(doneLine(step)).font(.footnote).foregroundStyle(Zone.ink(scheme))
                    }
                }
            }
            if active {
                detail(step).padding(.leading, 34)
            }
        }
        .padding(.vertical, active ? 18 : 14)
        .opacity(active || done ? 1 : 0.55)
        .accessibilityElement(children: .contain)
    }

    private func marker(_ step: Step, done: Bool, active: Bool) -> some View {
        ZStack {
            Circle()
                .fill(done ? Zone.controlFill(scheme) : (active ? Zone.ink(scheme) : Color.clear))
                .overlay(Circle().strokeBorder(active || done ? .clear : Zone.rule(scheme), lineWidth: 1.5))
            if done {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Zone.controlInk(scheme))
            } else {
                Text("\(step.rawValue + 1)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(active ? Zone.onInk(scheme) : Zone.muted(scheme))
            }
        }
        .frame(width: 22, height: 22)
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
        .accessibilityLabel(done ? "Done" : "Step \(step.rawValue + 1)")
    }

    private func title(_ step: Step) -> String {
        switch step {
        case .model: return "Download the speech model"
        case .microphone: return "Allow microphone access"
        case .keyboard: return "Add the Zone keyboard"
        case .dictate: return "Try one sentence"
        case .done: return ""
        }
    }

    private func doneLine(_ step: Step) -> String {
        switch step {
        case .model: return "Model downloaded"
        case .microphone: return "Microphone allowed"
        case .keyboard: return "Keyboard ready"
        case .dictate: return skippedDictation ? "Skipped" : "Done"
        case .done: return ""
        }
    }

    private var model: SpeechModel { coordinator.selectedModel }

    @ViewBuilder
    private func detail(_ step: Step) -> some View {
        switch step {
        case .model: modelDetail
        case .microphone: microphoneDetail
        case .keyboard: keyboardDetail
        case .dictate: dictateDetail
        case .done: EmptyView()
        }
    }

    private func why(_ text: String) -> some View {
        Text(text).font(.subheadline).lineSpacing(3).foregroundStyle(Zone.muted(scheme)).fixedSize(horizontal: false, vertical: true)
    }

    // Step 1

    @ViewBuilder
    private var modelDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch coordinator.modelState {
            case .downloading(let progress, _):
                why("Downloading from \(model.downloadHost). Next step unlocks automatically.")
                ProgressView(value: progress).tint(Zone.accentTone(scheme)).scaleEffect(x: 1, y: 1.8, anchor: .center).padding(.vertical, 2)
                Text("\(Int(progress * 100))% of \(model.sizeLabel)")
                    .font(.footnote.monospacedDigit()).foregroundStyle(Zone.muted(scheme))
            case .loading:
                why("Loading model into memory.")
                ProgressView().tint(Zone.accentTone(scheme))
            case .failed(let message):
                why("Download stopped: \(message)")
                Text("Check your connection and try again.").font(.footnote).foregroundStyle(Zone.live)
            default:
                why(model.needsDownload
                    ? "One \(model.sizeLabel) download from \(model.downloadHost). This model works offline after download."
                    : "Uses Apple's built-in speech model. Nothing to download.")
            }
        }
    }

    // Step 2

    @ViewBuilder
    private var microphoneDetail: some View {
        if micPermission == .denied {
            why("Microphone access is off. Turn it on in Settings, then come back.")
        } else {
            why("iPhone asks for the mic next. An orange dot means the mic is in use.")
        }
    }

    // Step 3

    private var keyboardDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            why("Full Access lets the keyboard receive your words from Zone. If you choose a GPU server in Keyboard recognition, the keyboard can send finished recordings there.")
            VStack(alignment: .leading, spacing: 0) {
                instruction(1, "Open Settings → Apps → Zone.")
                instruction(2, "Tap Keyboards.")
                instruction(3, "Turn on Zone.")
                instruction(4, "Turn on Allow Full Access.")
                instruction(5, "Tap the box. Hold the globe key. Tap Zone.")
            }
            .zoneCard(padding: 12)
            practiceField(prompt: "Tap here, then 🌐 to switch to Zone")
            if !AppGroup.isReachable {
                // A build signed without its App Group: the keyboard can never reach this app, so
                // this step would wait forever with nothing on screen to say why.
                Text("This build is missing its shared App Group, so the keyboard cannot reach it. Set your team in Config/Local.xcconfig and rebuild.")
                    .font(.footnote).foregroundStyle(Zone.live)
            }
            if fieldFocused {
                Text("Using Zone's keys? Give it a second. If it asks for Full Access above the keys, check step 4.")
                    .font(.footnote).foregroundStyle(Zone.muted(scheme))
            }
        }
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)").font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(Zone.ink(scheme))
            Text(text).font(.subheadline).foregroundStyle(Zone.ink(scheme))
        }
        .padding(.vertical, 5)
    }

    // Step 4

    private var dictateDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            why("Tap the mic key on the right of Zone's strip, say a sentence, then tap Stop (■).")
            practiceField(prompt: practicePrompt)
        }
    }

    /// The empty box narrates the dictation, so talking into it never looks ignored.
    private var practicePrompt: String {
        switch coordinator.activity {
        case .recording: return "Listening… tap Stop (■) when done"
        case .transcribing: return "Transcribing…"
        default: return "Tap here to dictate"
        }
    }

    private func practiceField(prompt: String) -> some View {
        TextField(prompt, text: $practiceText, axis: .vertical)
            .font(.body)
            .foregroundStyle(Zone.ink(scheme))
            .lineLimit(1...4)
            .focused($fieldFocused)
            .padding(14)
            .frame(minHeight: 52)
            .background(Zone.field(scheme), in: Zone.fieldShape)
            .overlay(Zone.fieldShape
                .strokeBorder(fieldFocused ? Zone.accentStroke(scheme) : Zone.rule(scheme), lineWidth: fieldFocused ? 1.5 : 1))
    }

    // Step 5

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(Zone.accentTone(scheme))
            DisplayText("You're set.", size: 38)
            if !practiceText.isEmpty {
                Text(practiceText).font(.body).foregroundStyle(Zone.ink(scheme)).zoneCard()
                Text("Missed a word? Add names and terms in Settings → My words.")
                    .font(.footnote).foregroundStyle(Zone.muted(scheme))
            }
            Text("Using it in other apps").font(.headline).foregroundStyle(Zone.ink(scheme))
            VStack(alignment: .leading, spacing: 0) {
                instruction(1, "Open any app and tap a text field.")
                instruction(2, "Hold 🌐 to switch to Zone.")
                instruction(3, "Tap the mic key, talk, tap Stop (■).")
            }
            Text(settings.inactivityPolicy.micReadySummary)
                .font(.footnote).foregroundStyle(Zone.muted(scheme))
        }
    }

    // MARK: Bottom action

    @ViewBuilder
    private var actions: some View {
        switch current {
        case .model:
            switch coordinator.modelState {
            case .downloading, .loading:
                EmptyView()
            case .failed:
                Button("Try again") { coordinator.prepareModel() }.buttonStyle(ZonePrimaryButtonStyle())
            default:
                Button(model.needsDownload ? "Download \(model.sizeLabel)" : "Continue") { coordinator.prepareModel() }
                    .buttonStyle(ZonePrimaryButtonStyle())
            }
        case .microphone:
            if micPermission == .denied {
                Button("Open Settings") { openSettings() }.buttonStyle(ZonePrimaryButtonStyle())
            } else {
                // 5.1.1(iv): the pre-permission button must not say "Allow"; iOS asks that.
                Button("Continue") {
                    Task {
                        _ = await coordinator.requestMicrophonePermission()
                        micPermission = AVAudioApplication.shared.recordPermission
                    }
                }
                .buttonStyle(ZonePrimaryButtonStyle())
            }
        case .keyboard:
            Button("Open Settings") {
                visitedSettings = true
                openSettings()
            }
            .buttonStyle(ZonePrimaryButtonStyle())
        case .dictate:
            Button("Skip this") { skippedDictation = true }.buttonStyle(ZoneQuietButtonStyle(fullWidth: true))
        case .done:
            Button("Start using Zone") { finish() }.buttonStyle(ZonePrimaryButtonStyle())
        }
    }

    // MARK: Effects

    /// The keyboard's mic answers in place only while a session is on; the practice step turns
    /// one on so the first dictation takes the same path every later one will.
    private func armForPractice() {
        guard !coordinator.isArmed else { return }
        Task { try? await coordinator.armSession() }
    }

    private func finish() {
        Haptics.success()
        settings.hasCompletedOnboarding = true
        // The finish step promises the mic is on; make it true even after a relaunch.
        if !coordinator.isArmed { Task { try? await coordinator.armSession() } }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        keyboardCheckBegan = Date()
        UIApplication.shared.open(url)
    }
}

/// The product, shown: a message bubble that types itself while a waveform runs, on a loop.
/// Kept for the App Store screenshots and any later marketing surface.
struct DemoBubble: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let sentence = "Running ten minutes late, order me the usual?"
    private let words: [String]

    init() { words = sentence.split(separator: " ").map(String.init) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.12)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let cycle = 7.0
            let phase = reduceMotion ? 1.0 : t.truncatingRemainder(dividingBy: cycle) / cycle
            let speaking = phase < 0.62
            let shown = reduceMotion ? words.count : min(words.count, Int(Double(words.count + 1) * (phase / 0.62)))
            Text(words.prefix(shown).joined(separator: " "))
                .font(.body)
                .foregroundStyle(Zone.ink(scheme))
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 12)
                .background(Zone.field(scheme), in: Zone.fieldShape)
                .overlay(alignment: .trailing) {
                    Image(systemName: speaking ? "stop.fill" : "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Zone.controlInk(scheme))
                        .frame(width: 36, height: 36)
                        .background(Zone.controlFill(scheme), in: Circle())
                        .padding(.trailing, 4)
                }
        }
        .accessibilityElement()
        .accessibilityLabel("Demo: a sentence is dictated and typed into a message")
    }
}
