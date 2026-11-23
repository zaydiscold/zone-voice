// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// One line of the setup checklist: a check state, what it is, and the single action that
/// fixes it while it is missing.
struct SetupRow<Action: View>: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    let detail: String
    let done: Bool
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(done ? Zone.accentGraphic(scheme) : Zone.rule(scheme))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(Zone.ink(scheme))
                Text(detail).font(.footnote).foregroundStyle(Zone.muted(scheme))
            }
            Spacer(minLength: 8)
            if !done {
                action
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? "Done" : "Not done")
    }
}

/// The X beside a live recording throws the audio and the words away, so it always asks
/// first, in the same words as a meeting's Cancel. The question goes away with the recording:
/// if it stops or is saved while the alert is up, Discard has nothing left to delete.
struct DiscardRecordingConfirmation: ViewModifier {
    @Environment(DictationCoordinator.self) private var coordinator
    @Binding var isPresented: Bool
    let onDiscard: () -> Void

    func body(content: Content) -> some View {
        content
            .alert("Discard this recording?", isPresented: $isPresented) {
                Button("Discard", role: .destructive) {
                    guard case .recording = coordinator.activity else { return }
                    onDiscard()
                }
                Button("Keep recording", role: .cancel) {}
            } message: {
                Text("Deletes this audio and transcript.")
            }
            .onChange(of: coordinator.activity.isRecording) { _, recording in
                if !recording { isPresented = false }
            }
    }
}

extension View {
    func confirmsDiscard(_ isPresented: Binding<Bool>, onDiscard: @escaping () -> Void) -> some View {
        modifier(DiscardRecordingConfirmation(isPresented: isPresented, onDiscard: onDiscard))
    }
}

/// The in-app composer: a text field with the mic beside it. While recording it becomes
/// X, the waveform with a timer, and the checkmark. Shared by Home and onboarding.
struct Composer: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var scheme
    @Binding var text: String
    var placeholder = "Say something"
    /// The composer on the Send feedback screen. While that screen is up it alone takes the
    /// dictated words; the composers underneath (Home's) leave them be.
    var forFeedback = false
    @State private var confirmingDiscard = false

    var body: some View {
        Group {
            // A note is run from its card at the top; the bar stays a field until it is done.
            switch coordinator.noteIsLive ? .idle : coordinator.activity {
            case .recording(_, let startedAt):
                HStack(spacing: 12) {
                    RoundAction(symbol: "xmark", label: "Cancel dictation", diameter: 44) { confirmingDiscard = true }
                    LiveWave()
                        .frame(height: 36)
                    if coordinator.showsPaused {
                        Text("Paused").font(.subheadline).foregroundStyle(Zone.accentText(scheme))
                    } else {
                        TimelineView(.periodic(from: startedAt, by: 1)) { context in
                            Text(context.date.timeIntervalSince(startedAt).countdownLabel)
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(Zone.muted(scheme))
                                .accessibilityLabel("Recording for \(context.date.timeIntervalSince(startedAt).countdownLabel)")
                        }
                    }
                    RoundAction(symbol: coordinator.showsPaused ? "play.fill" : "pause.fill",
                                label: coordinator.showsPaused ? "Resume recording" : "Pause recording", diameter: 44) {
                        coordinator.togglePause()
                    }
                    RoundAction(symbol: "checkmark", label: "Stop and keep the words", prominent: true, diameter: 44) {
                        Task { await coordinator.stopDictation() }
                    }
                }
                .frame(minHeight: 52)
                .confirmsDiscard($confirmingDiscard) { coordinator.cancelDictation() }
            case .transcribing:
                HStack(spacing: 12) {
                    Group {
                        if settings.meterStyle.isDrawn || settings.meterStyle == .scope {
                            VoiceArt(style: settings.meterStyle, level: 0, live: false,
                                     ink: UIColor(Zone.muted(scheme)), accent: UIColor(Zone.muted(scheme)))
                        } else if settings.meterStyle == .bars {
                            SignalLevelMeter(levels: [], color: UIColor(Zone.muted(scheme)), shape: .swell)
                        } else {
                            FlowingWave(levels: [], color: UIColor(Zone.muted(scheme)))
                        }
                    }
                    .frame(height: 36)
                    Text("Transcribing").font(.subheadline).foregroundStyle(Zone.muted(scheme))
                }
                .frame(minHeight: 52)
            default:
                // The field is exactly the button's height on one line, so the button sits dead
                // center with the same 8 pt inset on every side; with more lines it stays at the
                // bottom, under the thumb.
                HStack(alignment: .bottom, spacing: 12) {
                    TextField(placeholder, text: $text, axis: .vertical)
                        .font(.body)
                        .foregroundStyle(Zone.ink(scheme))
                        .lineLimit(1...6)
                        .frame(minHeight: 44)
                        .padding(.leading, 10)
                    MicButton(diameter: 44) {
                        Haptics.start()
                        Task { await coordinator.startAppDictation(contextBefore: text) }
                    }
                    .disabled(!coordinator.modelIsReady || coordinator.noteIsLive)
                    .opacity(coordinator.modelIsReady && !coordinator.noteIsLive ? 1 : 0.45)
                }
            }
        }
        .padding(8)
        .composerSurface()
        .animation(Zone.motion, value: coordinator.activity.isBusy)
        .onChange(of: coordinator.activity, initial: true) { _, activity in
            if case .finished(let result, let origin) = activity, origin == .app, !coordinator.lastResultWasNote, !coordinator.lastResultWasAudioRetry,
               FeedbackSession.isOpen == forFeedback {
                let inserted = coordinator.textStyle.insertion(of: result.text, contextBefore: text, fieldCapitalizesSentences: true, personalWords: coordinator.personalWords,
                                                            mentions: settings.handleRecognition, handles: coordinator.handles, systemWords: coordinator.systemWords,
                                                            spokenCorrections: settings.spokenCorrections, emoticons: settings.spokenEmoticons, smallOrdinals: settings.smallOrdinals, california: settings.californiaMode, misheard: settings.misheard)
                text += inserted
                coordinator.learnHandles(from: result.text, renderedText: inserted)
                Haptics.success()
                coordinator.acknowledgeActivity(resultWasUsed: true)
            }
        }
    }
}

/// Liquid Glass on iOS 26 for the one floating control; the field color with a rule before.
/// The only view that reads the 20 Hz level stream, so a recording redraws the wave and not
/// the whole composer around it.
struct LiveWave: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Group {
            // Settings > Appearance > Voice graphic. Mirrored is a keyboard layout; here it is the wave.
            if settings.meterStyle.isDrawn || settings.meterStyle == .scope {
                VoiceArt(style: settings.meterStyle, level: coordinator.showsPaused ? 0 : (coordinator.recentLevels.last ?? 0),
                         live: !coordinator.showsPaused, ink: UIColor(Zone.ink(scheme)), accent: UIColor(Zone.accentGraphic(scheme)))
            } else if settings.meterStyle == .bars {
                SignalLevelMeter(levels: coordinator.showsPaused ? [] : coordinator.recentLevels,
                                 color: UIColor(Zone.accentGraphic(scheme)), shape: .swell)
            } else {
                FlowingWave(levels: coordinator.showsPaused ? [] : coordinator.recentLevels,
                            color: UIColor(Zone.accentGraphic(scheme)), ink: UIColor(Zone.accentText(scheme)))
            }
        }
        .opacity(coordinator.showsPaused ? 0.4 : 1)
        .accessibilityHidden(true)
    }
}

private struct ComposerSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    /// Concentric with the 44 pt round button inside it: 22 pt radius plus the 8 pt inset.
    private let radius: CGFloat = 30

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: radius, style: .continuous))
        } else {
            content
                .background(Zone.field(scheme), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Zone.rule(scheme), lineWidth: 1))
        }
    }
}

extension View {
    func composerSurface() -> some View { modifier(ComposerSurface()) }
}

extension DictationCoordinator.Activity {
    var isBusy: Bool {
        switch self {
        case .recording, .transcribing: return true
        default: return false
        }
    }

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}

extension Int64 {
    var byteCountLabel: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

/// "Recovered from Nov 1, 3:04 PM": a retried recording's original time, grayed, under the
/// time it was transcribed (which is the item's main time and its place in the list).
struct RecoveredFromLabel: View {
    @Environment(\.colorScheme) private var scheme
    let date: Date

    var body: some View {
        (Text("Recovered from ") + Text(date.formatted(date: .abbreviated, time: .shortened))
            .foregroundStyle(Zone.muted(scheme).opacity(0.6)))
            .font(.caption).foregroundStyle(Zone.muted(scheme))
            .accessibilityLabel("Recovered from a recording made \(date.formatted(date: .abbreviated, time: .shortened))")
    }
}
