// by zayd/cold @ zayd.wtf

import AVFoundation
import SwiftUI
import ZoneCore

/// Setup as a session: a log where each line appears when this iPhone confirms it, one live line
/// that rewrites itself while something runs (the download with its size and speed, the first
/// dictation as it is heard), and one question at a time at the bottom, answered with a key.
///
/// It reads the same state as `OnboardingView` (the model's state, the record permission, the
/// keyboard's presence record, the dictations themselves). The download
/// starts on the first answer and runs while the rest is asked.
///
struct SetupTerminalView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var glyphColumn: CGFloat = 22

    var onLater: () -> Void = {}
    var onDone: () -> Void = {}

    @State private var session = SetupSession()
    @State private var micPermission = AVAudioApplication.shared.recordPermission
    @State private var practiceText = ""
    @State private var firstDictation: String?
    @State private var keyboardCheckBegan = Date()
    @State private var returnedFromSettings = false
    @State private var launchFailure: String?
    @State private var setupNoteRequest: UUID?
    private var buttonPressed: Bool {
        guard let setupNoteRequest else { return false }
        return coordinator.notes.notes.contains { $0.recordingID == setupNoteRequest }
    }
    /// The last result before the dictation step was asked, so an older one never counts.
    @State private var resultBeforeAsking: UUID??
    @FocusState private var fieldFocused: Bool
    #if DEBUG
    @State private var standIn = SetupKeyboardStandIn.ifRequested()
    #endif

    // MARK: Facts

    private var model: SpeechModel { coordinator.selectedModel }

    private var facts: SetupFacts {
        let presence = coordinator.keyboardPresence?.seenDuringSetup(since: keyboardCheckBegan)
        return SetupFacts(model: modelFact, modelBytes: model.approximateDownloadBytes, microphone: microphoneFact,
                   keyboardAdded: presence != nil || keyboardListed, fullAccess: presence?.hasFullAccess,
                   recording: recordingFact, firstDictation: firstDictation, buttonPressed: buttonPressed)
    }

    @State private var keyboardListed = false

    private func checkKeyboardList() {
        guard let bundle = Bundle.main.bundleIdentifier else { return }
        let prefix = bundle + ".keyboard"
        keyboardListed = UserDefaults.standard.stringArray(forKey: "AppleKeyboards")?.contains {
            $0 == prefix || $0.hasPrefix(prefix + "-")
        } == true
    }

    private var modelFact: SetupFacts.Model {
        switch coordinator.modelState {
        case .missing: return .missing
        case .downloading(let progress, _): return .downloading(fraction: progress)
        case .loading: return .loading
        case .ready: return .ready
        case .failed(let message): return .failed(message)
        }
    }

    private var microphoneFact: SetupFacts.Microphone {
        switch micPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }

    private var recordingFact: SetupFacts.Recording {
        switch coordinator.activity {
        case .recording: return .listening(coordinator.liveTranscript)
        case .transcribing: return .recognizing
        case .idle, .finished, .failed: return .idle
        }
    }

    // MARK: Body

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    log
                    if typeSize.isAccessibilitySize {
                        promptView.padding(.top, 24)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: session.lines.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: session.prompt) { _, _ in scrollToEnd(proxy) }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                scrollToEnd(proxy)
            }
            // At the largest sizes the box is in the log, under the live line: as the heard words
            // grow, it would slide under the keyboard.
            .onChange(of: session.live?.detail) { _, _ in if fieldFocused { scrollToEnd(proxy) } }
        }
        .safeAreaInset(edge: .bottom) {
            if !typeSize.isAccessibilitySize {
                promptView
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
                    .padding(.bottom, 12)
                    .background(Zone.paper(scheme).ignoresSafeArea(edges: .bottom))
                    .overlay(alignment: .top) { Hairline() }
            }
        }
        .statusBarBand()
        .background(Zone.paper(scheme).ignoresSafeArea())
        .tint(Zone.inlineInk(scheme))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: session.lines.count)
        .animation(reduceMotion ? nil : Zone.motion, value: session.prompt)
        .onAppear {
            micPermission = AVAudioApplication.shared.recordPermission
            #if DEBUG
            standIn?.begin()
            #endif
            checkKeyboardList()
            coordinator.refreshFromStore()
            coordinator.prepareModelIfNeededForOnboarding()
            session.observe(facts, at: Date())
            promptChanged(to: session.prompt)
        }
        .onChange(of: facts) { _, next in session.observe(next, at: Date()) }
        .onChange(of: session.prompt) { _, prompt in promptChanged(to: prompt) }
        .onChange(of: session.lines.count) { _, _ in announceLastLine() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            micPermission = AVAudioApplication.shared.recordPermission
            checkKeyboardList()
            coordinator.refreshFromStore()
        }
        .onChange(of: coordinator.lastResult?.requestID) { _, _ in noteResult() }
        .onChange(of: coordinator.lastSetupIntentNote) { _, current in
            if session.prompt == .actionButton, current != nil {
                setupNoteRequest = current
            }
        }
        .onChange(of: coordinator.noteCard) { _, phase in
            guard session.prompt == .actionButton else { return }
            if case .failed(let reason) = phase { launchFailure = reason }
            if case .starting = phase { launchFailure = nil }
        }
        .onChange(of: fieldFocused) { _, focused in
            #if DEBUG
            if focused { standIn?.keyboardAppeared() }
            #endif
        }
        .task {
            // The download's speed and a stall are worked out from time passing, not only from
            // progress reports.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                session.observe(facts, at: Date())
            }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, after delay: Duration = .milliseconds(60)) {
        Task {
            try? await Task.sleep(for: delay)
            withAnimation(reduceMotion ? nil : Zone.motion) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    // MARK: Header and log

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("zone").font(.zoneWordmark).foregroundStyle(Zone.ink(scheme))
                Spacer()
                if !session.isFinished {
                    Button("Not now", action: onLater).buttonStyle(ZoneLinkButtonStyle())
                }
            }
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(Zone.muted(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
        .padding(.bottom, 18)
    }

    /// How much is left, then the promise the log keeps.
    private var subtitle: String {
        let promise = "Each line appears when this iPhone confirms it."
        switch session.remaining {
        case 0: return promise
        case 1: return "1 step left. " + promise
        case let left: return "\(left) steps left. " + promise
        }
    }

    private var log: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(session.lines) { line in
                lineRow(line)
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 6)))
            }
            if let live = session.live {
                lineRow(live)
                    .accessibilityAddTraits(.updatesFrequently)
                    .transition(.opacity)
            }
        }
    }

    private func lineRow(_ line: SetupLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            glyph(line.kind)
                .frame(width: glyphColumn, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(line.kind == .said ? "\u{201C}\(line.text)\u{201D}" : line.text)
                    .font(line.kind == .said ? .system(.title3, design: .serif) : .body)
                    .foregroundStyle(line.kind == .note ? Zone.muted(scheme) : Zone.ink(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = line.detail {
                    Text(detail)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(line.kind == .problem ? Zone.live : Zone.muted(scheme))
                        .contentTransition(.numericText())
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let fraction = line.fraction {
                    ProgressTrack(fraction: fraction).padding(.top, 4)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(line))
        .accessibilityIdentifier("setup.line.\(line.id)")
    }

    @ViewBuilder
    private func glyph(_ kind: SetupLine.Kind) -> some View {
        switch kind {
        case .done:
            Image(systemName: "checkmark").font(Font.body.weight(.bold)).foregroundStyle(Zone.accentTone(scheme))
        case .working:
            StatusDot(color: Zone.accentTone(scheme), pulses: true, size: 7)
                .frame(width: 14, height: 14)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
        case .problem:
            Image(systemName: "exclamationmark").font(Font.body.weight(.bold)).foregroundStyle(Zone.live)
        case .said:
            Image(systemName: "waveform").font(Font.body.weight(.semibold)).foregroundStyle(Zone.accentTone(scheme))
        case .note:
            Image(systemName: "arrow.turn.down.right").font(.footnote).foregroundStyle(Zone.muted(scheme))
        }
    }

    private func spoken(_ line: SetupLine) -> String {
        let lead: String
        switch line.kind {
        case .done: lead = "Done: "
        case .working: lead = ""
        case .problem: lead = "Problem: "
        case .said: lead = "You said: "
        case .note: lead = ""
        }
        return lead + line.text + (line.detail.map { ". \($0)" } ?? "")
    }

    private func announceLastLine() {
        guard let line = session.lines.last, line.kind != .note else { return }
        AccessibilityNotification.Announcement(spoken(line)).post()
    }

    // MARK: Prompt

    @ViewBuilder
    private var promptView: some View {
        let prompt = session.prompt
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(question(prompt))
                    .font(.headline)
                    .foregroundStyle(Zone.ink(scheme))
                    .accessibilityAddTraits(.isHeader)
                if let why = why(prompt) {
                    Text(why)
                        .font(.subheadline)
                        .foregroundStyle(Zone.muted(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let path = settingsPath(prompt) {
                SettingsPath(steps: path)
            }
            if showsPracticeBox(prompt) {
                practiceField(prompt)
            }
            if !(fieldFocused && prompt == .dictate) {
                keys(prompt)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.prompt")
    }

    private func question(_ prompt: SetupPrompt) -> String {
        switch prompt {
        case .downloadModel: return model.needsDownload ? "Download the speech model?" : "Use Apple's speech model?"
        case .retryDownload: return "The download stopped"
        case .microphone: return "Let Zone hear you?"
        case .microphoneDenied: return "Turn on the microphone"
        case .addKeyboard: return "Add the Zone keyboard"
        case .switchToKeyboard: return "Switch to Zone once"
        case .fullAccessOff: return "Allow Full Access"
        case .waitForModel: return "Almost there"
        case .dictate: return "Say something"
        case .actionButton: return SetupDevice.hasActionButton ? "One button for voice notes?" : "Try a voice note?"
        case .finish: return "You're set"
        }
    }

    private func why(_ prompt: SetupPrompt) -> String? {
        switch prompt {
        case .downloadModel:
            return model.needsDownload
                ? "\(model.sizeLabel) from \(model.downloadHost), once. Then Zone works offline. Keep setting up while it downloads."
                : "Nothing to download."
        case .retryDownload(let message):
            return "\(message) Check your connection and try again."
        case .microphone:
            return "iOS asks next. Zone uses the mic for dictation, voice notes and meetings."
        case .microphoneDenied:
            return "It is off for Zone. Turn it on in Settings, then come back."
        case .addKeyboard:
            return returnedFromSettings ? "Tap the box. Hold the globe key. Tap Zone." : "Turn on Zone. Turn on Allow Full Access."
        case .switchToKeyboard:
            return "Tap the box. Hold the globe key. Tap Zone."
        case .fullAccessOff:
            return "The keyboard is added, but it cannot receive your words without Full Access."
        case .waitForModel:
            return "The speech model is getting ready. You can try dictation later."
        case .dictate:
            return "Tap the mic key in Zone's strip, say a sentence, then tap Stop (■)."
        case .actionButton:
            return launchFailure ?? (SetupDevice.hasActionButton ? "Hold the Action Button to start a note. Hold again to save." : "Tap Voice note in Control Center.")
        case .finish:
            return "In any app, tap a text field, hold \u{1F310}, pick Zone and tap the mic."
        }
    }

    private func settingsPath(_ prompt: SetupPrompt) -> [String]? {
        switch prompt {
        case .addKeyboard, .fullAccessOff: return ["Settings", "Apps", "Zone", "Keyboards"]
        case .microphoneDenied: return ["Settings", "Apps", "Zone", "Microphone"]
        case .actionButton: return nil
        default: return nil
        }
    }

    private func showsPracticeBox(_ prompt: SetupPrompt) -> Bool {
        switch prompt {
        case .addKeyboard, .switchToKeyboard, .dictate: return true
        default: return false
        }
    }

    private func practiceField(_ prompt: SetupPrompt) -> some View {
        TextField(boxPrompt(prompt), text: $practiceText, axis: .vertical)
            .font(.body)
            .foregroundStyle(Zone.ink(scheme))
            .lineLimit(1...4)
            .focused($fieldFocused)
            .padding(14)
            .frame(minHeight: 52)
            .background(Zone.field(scheme), in: Zone.fieldShape)
            .overlay(Zone.fieldShape.strokeBorder(fieldFocused ? Zone.accentStroke(scheme) : Zone.rule(scheme),
                                                  lineWidth: fieldFocused ? 1.5 : 1))
            .accessibilityIdentifier("setup.practice")
    }

    private func boxPrompt(_ prompt: SetupPrompt) -> String {
        switch prompt {
        case .addKeyboard: return "Added it already? Tap here, then \u{1F310}"
        case .switchToKeyboard: return "Tap here, then hold \u{1F310}"
        default: return "Your words land here"
        }
    }

    @ViewBuilder
    private func keys(_ prompt: SetupPrompt) -> some View {
        switch prompt {
        case .downloadModel:
            Button(model.needsDownload ? "Download \(model.sizeLabel)" : "Continue") {
                session.answer(.download, at: Date())
                coordinator.prepareModel()
            }
            .buttonStyle(ZonePrimaryButtonStyle())
        case .retryDownload:
            Button("Try again") {
                session.answer(.download, at: Date())
                coordinator.prepareModel()
            }
            .buttonStyle(ZonePrimaryButtonStyle())
        case .microphone:
            // 5.1.1(iv): the pre-permission button must not say "Allow"; iOS asks that.
            Button("Continue") {
                Task {
                    _ = await coordinator.requestMicrophonePermission()
                    micPermission = AVAudioApplication.shared.recordPermission
                }
            }
            .buttonStyle(ZonePrimaryButtonStyle())
        case .microphoneDenied, .addKeyboard, .fullAccessOff:
            Button("Open Settings") { openSettings() }.buttonStyle(ZonePrimaryButtonStyle())
        case .switchToKeyboard:
            EmptyView()
        case .dictate, .waitForModel:
            Button("Skip this") { session.answer(.skipDictation, at: Date()) }
                .buttonStyle(ZoneQuietButtonStyle(fullWidth: true))
        case .actionButton:
            ShortcutHelpLink()
            Button("Skip for now") { session.answer(.skipActionButton, at: Date()) }
                .buttonStyle(ZoneQuietButtonStyle(fullWidth: true))
        case .finish:
            Button("Start using Zone") { finish() }.buttonStyle(ZonePrimaryButtonStyle())
        }
    }

    // MARK: Effects

    private func promptChanged(to prompt: SetupPrompt) {
        switch prompt {
        case .switchToKeyboard:
            focusField()
        case .dictate:
            if resultBeforeAsking == nil { resultBeforeAsking = .some(coordinator.lastResult?.requestID) }
            // The keyboard's mic answers in place only while a session is on.
            if !coordinator.isArmed { Task { try? await coordinator.armSession() } }
            focusField()
            #if DEBUG
            standIn?.dictate(coordinator: coordinator) { practiceText += $0 }
            #endif
        case .finish:
            fieldFocused = false
            session.finish(at: Date())
            Haptics.success()
        default:
            break
        }
    }

    private func focusField() {
        Task { try? await Task.sleep(for: .milliseconds(300)); fieldFocused = true }
    }

    /// A dictation counts once it finished after the step was asked, with words in it.
    private func noteResult() {
        guard firstDictation == nil, session.prompt == .dictate, !coordinator.lastResultWasNote,
              case .some(let before) = resultBeforeAsking,
              let result = coordinator.lastResult, result.requestID != before else { return }
        let words = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        firstDictation = words
    }

    private func finish() {
        Haptics.success()
        settings.hasCompletedOnboarding = true
        if !coordinator.isArmed { Task { try? await coordinator.armSession() } }
        onDone()
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        keyboardCheckBegan = Date()
        returnedFromSettings = true
        UIApplication.shared.open(url)
    }
}

/// "Settings › Apps › Zone › Keyboards" as small keys, so the way through Settings reads at a
/// glance and wraps at large text sizes.
private struct SettingsPath: View {
    @Environment(\.colorScheme) private var scheme
    let steps: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(spacing: 6) {
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Zone.muted(scheme))
                    }
                    Text(step)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Zone.ink(scheme))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Zone.card(scheme), in: Zone.keyShape)
                        .overlay(Zone.keyShape.strokeBorder(Zone.rule(scheme), lineWidth: 1))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(steps.joined(separator: ", then "))
    }
}

/// A thin progress rule in the accent on a hairline track.
private struct ProgressTrack: View {
    @Environment(\.colorScheme) private var scheme
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
            ZStack(alignment: .leading) {
                shape.fill(Zone.rule(scheme))
                shape.fill(Zone.accentTone(scheme))
                    .frame(width: max(4, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// The Debug launch argument that shows this setup.
enum SetupTerminalLaunch {
    /// Shown only in Debug builds launched with `-zoneSetupTerminal`.
    static var isRequested: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-zoneSetupTerminal")
        #else
        false
        #endif
    }
}
