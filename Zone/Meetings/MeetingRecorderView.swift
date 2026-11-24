// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// The recorder: the screen's edges are the level meter, the length of the recording is the
/// one big thing in the middle, and three controls sit under the thumb: Cancel, Stop, Pause.
/// Calm on purpose; it may sit on a table for six hours.
struct MeetingRecorderView: View {
    @Environment(MeetingCoordinator.self) private var meetings
    @State private var confirmingCancel = false
    @State private var renaming = false
    @State private var draftTitle = ""
    @State private var showsInfo = false

    var body: some View {
        MeetingRecorderFace(edge: RecorderEdge(), seconds: { meetings.recordedSeconds },
            title: meetings.recording?.title ?? "Meeting", isPaused: meetings.isPaused,
            isInterrupted: meetings.isInterrupted, warning: meetings.recordingWarning, detail: { detail }) { action in
            switch action {
            case .hide: meetings.showsRecorder = false
            case .info: showsInfo = true
            case .rename:
                draftTitle = meetings.recording?.title ?? ""
                renaming = true
            case .cancel: confirmingCancel = true
            case .stop: Task { await meetings.stopRecording() }
            case .pause: meetings.togglePause()
            case .resume: Task { await meetings.resumeAfterInterruption() }
            }
        }
        .alert("Cancel this recording?", isPresented: $confirmingCancel) {
            Button("Delete recording", role: .destructive) { Task { await meetings.discardRecording() } }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text("Deletes the audio without transcribing.")
        }
        .alert("Name this meeting", isPresented: $renaming) {
            TextField("Name", text: $draftTitle)
                .autocorrectionDisabled()
            Button("Save") { meetings.renameRecording(to: draftTitle) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showsInfo) { MeetingInfoSheet().presentationDetents([.large]) }
    }

    private var detail: String? {
        let remaining = MeetingRecordingSafety.maximumSeconds - meetings.recordedSeconds
        if remaining <= MeetingRecordingSafety.countdownSeconds {
            return "Auto-saves in \(MeetingExport.durationLabel(max(0, remaining)))"
        }
        if meetings.labelsSpeakers, meetings.recordedSeconds > MeetingRecordingSafety.maximumSpeakerSeconds {
            return "Past \(MeetingRecordingSafety.speakerLabel), so speaker labels will be skipped."
        }
        return nil
    }
}

enum MeetingRecorderAction { case hide, info, rename, cancel, stop, pause, resume }

struct MeetingRecorderFace<Edge: View>: View {
    let edge: Edge
    let seconds: () -> Double
    let title: String
    let isPaused: Bool
    var isInterrupted = false
    var warning: String?
    var detail: () -> String? = { nil }
    var previewInsets = EdgeInsets()
    var perform: (MeetingRecorderAction) -> Void = { _ in }
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Zone.paper(scheme).ignoresSafeArea()
            edge.ignoresSafeArea()
            GeometryReader { geometry in
                let landscape = geometry.size.width > geometry.size.height
                ScrollView {
                    VStack(spacing: landscape ? 12 : 0) {
                        topBar
                        if landscape {
                            HStack(spacing: 32) {
                                recordingStatus.frame(maxWidth: .infinity)
                                controls.frame(maxWidth: 300)
                            }
                            .frame(maxHeight: .infinity)
                        } else {
                            Spacer(minLength: 16)
                            recordingStatus
                            Spacer(minLength: 16)
                            controls
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 16)
                    .frame(minHeight: geometry.size.height)
                }
                .scrollIndicators(.hidden)
            }
            .padding(previewInsets)
        }
    }

    private var recordingStatus: some View {
        RecorderStatus(seconds: seconds, isPaused: isPaused, isInterrupted: isInterrupted,
                       warning: warning, detail: detail) { perform(.resume) }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button { perform(.hide) } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Hide. Recording continues")
            Spacer(minLength: 0)
            Button { perform(.rename) } label: {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .frame(minHeight: 44)
            }
            .accessibilityHint("Rename this meeting")
            Spacer(minLength: 0)
            Button { perform(.info) } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 18, weight: .regular))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("How meetings work")
        }
        .foregroundStyle(Zone.ink(scheme))
        .padding(.horizontal, -12) // Glyphs, not hit areas, on the 20 pt page edge.
    }

    private var controls: some View {
        HStack(alignment: .bottom, spacing: 0) {
            RecorderControl(symbol: "xmark", label: "Cancel", diameter: 60) { perform(.cancel) }
                .accessibilityLabel("Cancel and delete the recording")
            Spacer(minLength: 12)
            RecorderControl(symbol: "stop.fill", label: "Stop", diameter: 84, prominent: true) {
                perform(.stop)
            }
            .accessibilityLabel("Stop and transcribe")
            Spacer(minLength: 12)
            RecorderControl(symbol: isPaused ? "play.fill" : "pause.fill",
                            label: isPaused ? "Resume" : "Pause", diameter: 60) {
                perform(.pause)
            }
            .disabled(isInterrupted)
            .accessibilityLabel(isPaused ? "Resume recording" : "Pause recording")
        }
        .padding(.horizontal, 8)
    }


}

/// Reading elapsed time here keeps the controls and the recorder layout out of clock updates.
private struct RecorderStatus: View {
    let seconds: () -> Double
    let isPaused: Bool
    let isInterrupted: Bool
    let warning: String?
    let detail: () -> String?
    let resume: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 12) {
            MeetingTimerText(seconds: seconds())
                .foregroundStyle(stateColor)
            HStack(spacing: 0) {
                StatusDot(color: stateColor, pulses: !isPaused && !isInterrupted, size: 8)
                Text(stateLabel).font(.subheadline.weight(.medium)).foregroundStyle(Zone.ink(scheme))
            }
            .padding(.leading, -8)
            if let warning {
                Text(warning).font(.footnote).foregroundStyle(Zone.live)
            }
            if isInterrupted {
                Button("Resume", action: resume).buttonStyle(ZoneInkPillButtonStyle())
            } else if isPaused {
                Text("Recording paused.")
                    .font(.footnote).foregroundStyle(Zone.muted(scheme))
            } else if let detail = detail() {
                Text(detail).font(.footnote).foregroundStyle(Zone.muted(scheme))
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var stateColor: Color {
        isPaused || isInterrupted ? Zone.muted(scheme) : Zone.accentTone(scheme)
    }

    private var stateLabel: String {
        if isInterrupted { return "Interrupted" }
        return isPaused ? "Paused" : "Recording"
    }
}

/// The edge meter, the only view that reads the levels.
private struct RecorderEdge: View {
    @Environment(MeetingCoordinator.self) private var meetings

    var body: some View {
        MeetingEdge(levels: meetings.levels, active: !meetings.isPaused && !meetings.isInterrupted)
    }
}

/// A round control with its word under it.
private struct RecorderControl: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    let symbol: String
    let label: String
    let diameter: CGFloat
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: diameter * 0.32, weight: .bold))
                    .foregroundStyle(prominent ? Zone.controlInk(scheme) : Zone.ink(scheme))
                    .frame(width: diameter, height: diameter)
                    .background(prominent ? Zone.controlFill(scheme) : Zone.card(scheme), in: Circle())
                    .overlay(Circle().strokeBorder(prominent ? .clear : Zone.rule(scheme), lineWidth: 1))
                Text(label).font(.footnote.weight(.medium)).foregroundStyle(Zone.muted(scheme))
                    .lineLimit(1)
                    .fixedSize()
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            }
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
        }
        .buttonStyle(ScaleButtonStyle())
    }
}
