// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// The cold-path screen: the keyboard opened Zone because dictation was off. Record, stop, then
/// show the text and the way back. There is no public API to return the person automatically, so
/// the way back is the loudest thing on the finished screen: an arrow pointing at the "◀ app"
/// button iOS puts in the top-left corner. The vocabulary is the keyboard's: waveform, timer,
/// X and checkmark.
struct DictationView: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var scheme
    /// True once this screen has seen a dictation start. An idle state after that means it was
    /// cancelled or refused, never "starting".
    @State private var sawActivity = false
    /// Idle for this long with nothing starting means the request was refused or lost.
    @State private var startTimedOut = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("zone").font(.zoneWordmark).foregroundStyle(Zone.ink(scheme))
                Spacer()
                if isBusy {
                    // The recording keeps going; a strip over the app brings this screen back.
                    Button("Hide") { coordinator.hideRecordingScreen() }
                        .buttonStyle(ZoneLinkButtonStyle())
                        .accessibilityLabel("Hide. Recording continues")
                } else {
                    Button("Close") { coordinator.dismissDictationScreen() }
                        .buttonStyle(ZoneLinkButtonStyle())
                        .accessibilityIdentifier("dictation.close")
                }
            }
            .padding(.top, 8)
            if showsWayBack {
                wayBack.padding(.top, 12).transition(.opacity)
            }
            Spacer()
            switch coordinator.activity {
            case .recording, .transcribing:
                LiveSurface(onCancel: { coordinator.cancelDictation() }) {
                    Task { await coordinator.stopDictation() }
                }
            case .finished(let result, _):
                finished(result)
            case .failed(let message):
                failed(message)
            case .idle:
                if !coordinator.modelIsReady {
                    preparing
                } else if coordinator.needsFreshKeyboardTap {
                    Text("Speech model ready. Go back and tap the mic again.")
                } else if sawActivity || startTimedOut {
                    stopped
                } else {
                    HStack(spacing: 10) { ProgressView().tint(Zone.accentTone(scheme)); Text("Starting").foregroundStyle(Zone.muted(scheme)) }
                }
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 24)
        .zoneScreen()
        .animation(Zone.motion, value: coordinator.activity.isBusy)
        .animation(Zone.motion, value: showsWayBack)
        .onChange(of: coordinator.activity) { _, activity in
            if activity != .idle { sawActivity = true }
        }
        .task(id: coordinator.modelIsReady) {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            if coordinator.activity == .idle { startTimedOut = true }
        }
    }

    private var isBusy: Bool { coordinator.activity.isBusy }

    /// Shown whenever there is nothing left to do here but go back.
    private var showsWayBack: Bool {
        switch coordinator.activity {
        case .finished: return true
        case .idle: return coordinator.modelIsReady && (coordinator.needsFreshKeyboardTap || sawActivity || startTimedOut)
        default: return false
        }
    }

    /// Points at iOS's own "◀ app" button in the status bar, the only way back iOS allows.
    private var wayBack: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.up.left")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Zone.accentTone(scheme))
            VStack(alignment: .leading, spacing: 2) {
                Text("Tap ◀ in the top-left corner")
                    .font(.headline).foregroundStyle(Zone.ink(scheme))
                Text("Returns to your previous app.")
                    .font(.subheadline).foregroundStyle(Zone.muted(scheme))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func finished(_ result: DictationResult) -> some View {
        let written = coordinator.textForRecoveryCopy(result.text)
        return VStack(alignment: .leading, spacing: 16) {
            DisplayText(result.text.isEmpty ? "Nothing heard" : "Done")
            if result.text.isEmpty {
                Text("Nothing was typed. Head back and tap the mic to try again.")
                    .font(.body).foregroundStyle(Zone.muted(scheme))
            } else {
                Text(written)
                    .font(.body)
                    .foregroundStyle(Zone.ink(scheme))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .zoneCard()
                Text("Switch back and the keyboard inserts this automatically, or shows Insert if your cursor moved. \(settings.inactivityPolicy.micReadySummary)")
                    .font(.subheadline).foregroundStyle(Zone.muted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Copy text") {
                    Clipboard.copy(written)
                    coordinator.confirmKept(result.requestID, text: written)
                }
                    .buttonStyle(ZoneQuietButtonStyle())
            }
        }
    }

    /// Cancelled with X, or the request never started. Nothing was kept.
    private var stopped: some View {
        VStack(alignment: .leading, spacing: 12) {
            DisplayText("Cancelled")
            Text(sawActivity
                 ? "Nothing was saved. The mic is warm now, so tap it back in your app."
                 : "Dictation didn't start. Go back and tap the mic again.")
                .font(.body).foregroundStyle(Zone.muted(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            DisplayText("Dictation failed")
            Text(message).font(.body).foregroundStyle(Zone.muted(scheme))
            Button("Close") { coordinator.dismissDictationScreen() }
                .buttonStyle(ZonePrimaryButtonStyle())
        }
    }

    private var preparing: some View {
        VStack(alignment: .leading, spacing: 14) {
            DisplayText(coordinator.modelState == .missing ? "Get the speech model" : "Loading model")
            switch coordinator.modelState {
            case .missing:
                Text("After the download, return to the keyboard and tap the mic again.")
                Button("Download \(coordinator.selectedModel.sizeLabel)") { coordinator.prepareModel() }
                    .buttonStyle(ZonePrimaryButtonStyle())
            case .downloading(let progress, _):
                ProgressView(value: progress).tint(Zone.accentTone(scheme))
                Text("Downloading speech model · \(Int(progress * 100))% of \(coordinator.selectedModel.sizeLabel).")
                    .font(.footnote).foregroundStyle(Zone.muted(scheme))
            case .failed(let message):
                Text(message).font(.footnote).foregroundStyle(Zone.live)
                Button("Try again") { coordinator.prepareModel() }.buttonStyle(ZonePrimaryButtonStyle())
            default:
                ProgressView().tint(Zone.accentTone(scheme))
                Text(startTimedOut ? "The model is still loading. You can close this screen and try the mic again." : "Loading speech model.")
                    .font(.footnote).foregroundStyle(Zone.muted(scheme))
            }
        }
    }
}

/// Headline, the big timer, the waveform, and the two exits level with it.
struct LiveSurface: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var scheme
    @Environment(AppSettings.self) private var settings
    let onCancel: () -> Void
    let onStop: () -> Void
    @State private var confirmingDiscard = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if case .recording(_, let startedAt) = coordinator.activity {
                HStack(spacing: 10) {
                    StatusDot(color: Zone.accentTone(scheme), pulses: settings.micLightStyle == .off && !coordinator.showsPaused,
                              hollow: coordinator.showsPaused)
                    DisplayText(coordinator.showsPaused ? "Paused" : "Listening")
                }
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    HeroNumber(text: context.date.timeIntervalSince(startedAt).countdownLabel)
                        .accessibilityLabel("Recording for \(context.date.timeIntervalSince(startedAt).countdownLabel)")
                }
            } else {
                DisplayText("Transcribing")
            }
            HStack(spacing: 12) {
                if coordinator.activity.isRecording {
                    RoundAction(symbol: "xmark", label: "Cancel dictation") { confirmingDiscard = true }
                        .accessibilityIdentifier("dictation.cancel")
                }
                if settings.meterStyle == .wave || coordinator.activity.isRecording {
                    LiveWave(live: coordinator.activity.isRecording)
                        .accessibilityHidden(true)
                        .frame(height: 64)
                } else {
                    SignalLevelMeter(levels: coordinator.recentLevels, color: UIColor(Zone.muted(scheme)), barPitch: 7)
                        .accessibilityHidden(true).frame(height: 48)
                }
                if coordinator.activity.isRecording {
                    RoundAction(symbol: "checkmark", label: "Stop and keep the words", prominent: true, action: onStop)
                        .accessibilityIdentifier("dictation.stop")
                }
            }
            .padding(12)
            .background {
                if settings.micLightStyle == .glow && !reduceTransparency {
                    RoundedRectangle(cornerRadius: 26)
                        .fill(LinearGradient(colors: [Zone.accentTone(scheme).opacity(0.11), Zone.card(scheme)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
            .overlay { MicLight(surface: .listening) }
            if !coordinator.activity.isRecording {
                EmptyView()
            } else if let hold = coordinator.holdNotice {
                Text(hold).font(.footnote).foregroundStyle(Zone.live)
                Button("Resume") { Task { await coordinator.resumeHeldRecording(trigger: "app") } }
                    .buttonStyle(ZoneInkPillButtonStyle())
            } else if coordinator.isPaused {
                Button("Resume recording") { coordinator.togglePause() }
                    .buttonStyle(ZoneInkPillButtonStyle())
            } else {
                if let seconds = coordinator.quietFinishIn {
                    Text("Quiet. Finishing in \(seconds)…")
                        .font(.footnote).monospacedDigit().foregroundStyle(Zone.ink(scheme))
                        .accessibilityLabel("Quiet. Finishing in \(seconds) seconds")
                } else {
                    Text(coordinator.hearsNothing ? "Listening. The mic is quiet." : "Talk normally. Tap ✓ when you're done, X to throw it away.")
                        .font(.footnote).foregroundStyle(coordinator.hearsNothing ? Zone.live : Zone.muted(scheme))
                }
            }
        }
        .confirmsDiscard($confirmingDiscard, onDiscard: onCancel)
    }
}
