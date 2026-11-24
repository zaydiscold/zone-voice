// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// The note card: a note's whole life at the top of Zone, in place of a screen that took over
/// the app. About twice the height of the recording strip (RecordingStrip), with the same
/// vocabulary as the old note screen: the light, the clock, the level bars, X and the check.
/// It sits in a window of its own (NoteCardWindow), so it is on top of whatever Zone shows.
struct NoteCard: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var scheme
    @Environment(AppSettings.self) private var settings
    let phase: NoteCardPhase
    @State private var confirmingDiscard = false

    private static let titleFont = Font.system(.title3, design: .serif, weight: .semibold)

    var body: some View {
        let shape = Zone.cardShape
        VStack(alignment: .leading, spacing: 10) {
            header
            controls
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { shape.fill(Zone.card(scheme)).sunShadow(scale: 0.8) }
        .overlay(shape.strokeBorder(border, lineWidth: 1))
        .contentShape(shape)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("noteCard")
        .confirmsDiscard($confirmingDiscard) { coordinator.cancelDictation() }
        .onChange(of: confirmingDiscard) { _, up in
            if !up { NoteCardOverlay.shared.returnKeyToApp() }
        }
        // VoiceOver hears the card change, wherever its focus is in Zone's own window.
        .onChange(of: phase.kind, initial: true) { _, _ in
            guard UIAccessibility.isVoiceOverRunning, let spoken = phase.announcement(noWordsDetail: noWordsDetail) else { return }
            UIAccessibility.post(notification: .announcement, argument: spoken)
        }
    }

    private var noWordsDetail: String {
        if let id = coordinator.lastResult?.requestID,
           coordinator.audioRecoveryRecords.contains(where: { $0.id == id && $0.audioBytes > 0 }) {
            return "Zone kept the audio. Look on Home to try again."
        }
        return "Zone did not save a transcript."
    }

    private var border: Color {
        switch phase {
        case .failed: Zone.live.opacity(0.55)
        case .noWords: Zone.rule(scheme)
        default: Zone.accentTone(scheme).opacity(0.45)
        }
    }

    // MARK: Header: what is happening, and for how long

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            switch phase {
            case .starting:
                ProgressView().controlSize(.small).tint(Zone.accentTone(scheme)).frame(width: 30, height: 30)
                title("New note")
            case .recording(let startedAt):
                StatusDot(color: Zone.accentTone(scheme), pulses: !coordinator.showsPaused,
                          hollow: coordinator.showsPaused)
                    .frame(width: 30, height: 30)
                title(coordinator.showsPaused ? "Paused" : "New note")
                Spacer(minLength: 8)
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    let elapsed = coordinator.noteRecordingDuration(startedAt: startedAt, now: context.date).countdownLabel
                    Text(elapsed)
                        .font(.system(.title3, design: .serif, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Zone.ink(scheme))
                        .contentTransition(.numericText())
                        .accessibilityLabel("Recording for \(elapsed)")
                }
            case .saving:
                ProgressView().controlSize(.small).tint(Zone.accentTone(scheme)).frame(width: 30, height: 30)
                title("Transcribing")
            case .noWords:
                Image(systemName: "waveform.slash")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(Zone.muted(scheme))
                    .frame(width: 30, height: 30)
                title("Nothing heard")
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(Zone.live)
                    .frame(width: 30, height: 30)
                title("Note failed")
            }
            if !phase.isRecording { Spacer(minLength: 0) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(Self.titleFont)
            .foregroundStyle(Zone.ink(scheme))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .contentTransition(.opacity)
    }

    // MARK: Controls: the row under the thumb's reach of the header

    @ViewBuilder
    private var controls: some View {
        switch phase {
        case .starting(let detail):
            HStack(spacing: 12) {
                Text(detail)
                    .font(.subheadline).foregroundStyle(Zone.muted(scheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                RoundAction(symbol: "xmark", label: "Cancel note", diameter: 40) { coordinator.cancelNoteStart() }
            }
            .frame(minHeight: 44)
        case .recording, .saving:
            if phase.isRecording, coordinator.audioRecoveryWarning != nil {
                Text("Audio recovery is unavailable. Keep Zone open.").font(.footnote)
            } else if phase.isRecording, !coordinator.modelIsReady {
                Text("Loading speech model…").font(.footnote)
            }
            if phase.isRecording, coordinator.isHeld, let hold = coordinator.holdNotice {
                HStack(spacing: 12) {
                    Text(hold)
                        .font(.footnote).foregroundStyle(Zone.live)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Resume") { Task { await coordinator.resumeHeldRecording(trigger: "noteCard") } }
                        .buttonStyle(ZoneInkPillButtonStyle())
                    stopButton
                }
                .frame(minHeight: 44)
            } else {
                HStack(spacing: 12) {
                    if phase.isRecording {
                        RoundAction(symbol: "xmark", label: "Discard note", diameter: 44) { confirmingDiscard = true }
                    }
                    if phase.isRecording || settings.meterStyle == .wave {
                        LiveWave(live: phase.isRecording)
                            .frame(height: 40)
                            .frame(maxWidth: .infinity)
                    } else {
                        SignalLevelMeter(levels: [], color: UIColor(Zone.muted(scheme)), barPitch: 7)
                            .accessibilityHidden(true).frame(height: 40)
                    }
                    if phase.isRecording {
                        RoundAction(symbol: coordinator.isPaused ? "play.fill" : "pause.fill",
                                    label: coordinator.isPaused ? "Resume note" : "Pause note", diameter: 44) {
                            coordinator.togglePause()
                        }
                        .accessibilityIdentifier("noteCard.pause")
                        stopButton
                    } else {
                        Text(coordinator.modelIsReady ? "Saving to Notes" : "Loading speech model…")
                            .font(.subheadline).foregroundStyle(Zone.muted(scheme)).fixedSize()
                    }
                }
                .frame(minHeight: 44)
            }
        case .noWords:
            HStack(spacing: 12) {
                Text(noWordsDetail)
                    .font(.subheadline).foregroundStyle(Zone.muted(scheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                RoundAction(symbol: "xmark", label: "Dismiss", diameter: 40) { coordinator.dismissNoteOutcome() }
            }
            .frame(minHeight: 44)
        case .failed(let message):
            HStack(alignment: .center, spacing: 12) {
                Text(message)
                    .font(.subheadline).foregroundStyle(Zone.ink(scheme))
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Try again") { coordinator.beginNoteDictation() }
                    .buttonStyle(ZoneInkPillButtonStyle())
                    .disabled(coordinator.activity.isBusy)
                RoundAction(symbol: "xmark", label: "Dismiss", diameter: 40) { coordinator.dismissNoteOutcome() }
            }
            .frame(minHeight: 44)
        }
    }

    private var stopButton: some View {
        RoundAction(symbol: "checkmark", label: "Save note", prominent: true, diameter: 44) {
            Task { await coordinator.stopDictation(reason: "noteCard") }
        }
        .accessibilityIdentifier("noteCard.save")
    }
}

/// The recording's dot while nothing is heard: it walks back and forth, the way someone waits.
/// Still, and hollow, with Reduce Motion.
private struct PacingDot: View {
    let color: Color
    var size: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var atFarSide = false

    var body: some View {
        if reduceMotion {
            Circle().strokeBorder(color, lineWidth: 1.5).frame(width: size, height: size)
        } else {
            Circle().fill(color)
                .frame(width: size, height: size)
                .offset(x: atFarSide ? 8 : -8)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: atFarSide)
                .onAppear { atFarSide = true }
        }
    }
}

private extension NoteCardPhase {
    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}

extension NoteCardPhase {
    func announcement(noWordsDetail: @autoclosure () -> String) -> String? {
        switch self {
        case .starting: nil
        case .recording: "Recording a note"
        case .saving: "Transcribing"
        case .noWords: "No words heard. \(noWordsDetail())"
        case .failed(let message): "Note failed. \(message)"
        }
    }
}
