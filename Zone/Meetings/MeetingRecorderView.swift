// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// The recorder: the screen's edges are the level meter, the length of the recording is the
/// one big thing in the middle, and three controls sit under the thumb: Cancel, Stop, Pause.
/// Calm on purpose; it may sit on a table for six hours.
struct MeetingRecorderView: View {
    @Environment(MeetingCoordinator.self) private var meetings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmingCancel = false
    @State private var renaming = false
    @State private var draftTitle = ""
    @State private var showsInfo = false

    var body: some View {
        ZStack {
            Zone.paper(scheme).ignoresSafeArea()
            RecorderEdge().ignoresSafeArea()
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

    private var recordingStatus: some View {
        VStack(spacing: 12) {
            TimelineLabel()
                .foregroundStyle(Zone.ink(scheme).opacity(meetings.isPaused ? 0.45 : 1))
                .accessibilityLabel("Recorded \(MeetingExport.durationLabel(meetings.recordedSeconds))")
            HStack(spacing: 0) {
                StatusDot(color: stateColor, pulses: !meetings.isPaused && !meetings.isInterrupted, size: 8)
                Text(stateLabel).font(.subheadline.weight(.medium)).foregroundStyle(Zone.ink(scheme))
            }
            .padding(.leading, -8)
            if let warning = meetings.recordingWarning {
                Text(warning).font(.footnote).foregroundStyle(Zone.live)
            }
            if meetings.isInterrupted {
                Button("Resume") { Task { await meetings.resumeAfterInterruption() } }.buttonStyle(ZoneInkPillButtonStyle())
            } else if meetings.isPaused {
                Text("Recording paused.")
                    .font(.footnote).foregroundStyle(Zone.muted(scheme))
            } else if MeetingRecordingSafety.maximumSeconds - meetings.recordedSeconds <= MeetingRecordingSafety.countdownSeconds {
                Text("Auto-saves in \(MeetingExport.durationLabel(max(0, MeetingRecordingSafety.maximumSeconds - meetings.recordedSeconds)))")
                    .font(.footnote.monospacedDigit()).foregroundStyle(Zone.muted(scheme))
            } else if meetings.labelsSpeakers, meetings.recordedSeconds > MeetingRecordingSafety.maximumSpeakerSeconds {
                // Said while it can still change the plan, not after the transcript arrives.
                Text("Past \(MeetingRecordingSafety.speakerLabel), so speaker labels will be skipped.")
                    .font(.footnote).foregroundStyle(Zone.muted(scheme))
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button { meetings.showsRecorder = false } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Hide. Recording continues")
            Spacer(minLength: 0)
            Button {
                draftTitle = meetings.recording?.title ?? ""
                renaming = true
            } label: {
                Text(meetings.recording?.title ?? "Meeting")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .frame(minHeight: 44)
            }
            .accessibilityHint("Rename this meeting")
            Spacer(minLength: 0)
            Button { showsInfo = true } label: {
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
            RecorderControl(symbol: "xmark", label: "Cancel", diameter: 60) { confirmingCancel = true }
                .accessibilityLabel("Cancel and delete the recording")
            Spacer(minLength: 12)
            RecorderControl(symbol: "stop.fill", label: "Stop", diameter: 84, prominent: true) {
                Task { await meetings.stopRecording() }
            }
            .accessibilityLabel("Stop and transcribe")
            Spacer(minLength: 12)
            RecorderControl(symbol: meetings.isPaused ? "play.fill" : "pause.fill",
                            label: meetings.isPaused ? "Resume" : "Pause", diameter: 60) {
                meetings.togglePause()
            }
            .disabled(meetings.isInterrupted)
            .accessibilityLabel(meetings.isPaused ? "Resume recording" : "Pause recording")
        }
        .padding(.horizontal, 8)
    }

    private var stateColor: Color {
        meetings.isPaused || meetings.isInterrupted ? Zone.muted(scheme) : Zone.accentGraphic(scheme)
    }

    private var stateLabel: String {
        if meetings.isInterrupted { return "Interrupted" }
        return meetings.isPaused ? "Paused" : "Recording"
    }


}

/// The big clock, read in its own view so the twenty-a-second level updates never touch it.
private struct TimelineLabel: View {
    @Environment(MeetingCoordinator.self) private var meetings
    var body: some View {
        MeetingTimerText(seconds: meetings.recordedSeconds)
    }
}

/// The edge meter, the only view that reads the levels.
private struct RecorderEdge: View {
    @AppStorage("meetingWaveformStyle") private var style = EdgeEqualizer.Style.flow.rawValue
    @Environment(MeetingCoordinator.self) private var meetings
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let live = !meetings.isPaused && !meetings.isInterrupted
        EdgeEqualizer(levels: meetings.levels, color: UIColor(live ? Zone.accentGraphic(scheme) : Zone.muted(scheme)), active: live,
                      style: EdgeEqualizer.Style(rawValue: style) ?? .flow)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
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
                    .foregroundStyle(prominent ? Zone.onAccent : Zone.ink(scheme))
                    .frame(width: diameter, height: diameter)
                    .background(prominent ? Zone.accent : Zone.card(scheme), in: Circle())
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
