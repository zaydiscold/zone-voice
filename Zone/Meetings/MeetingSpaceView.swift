// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// Home's Meeting tab: a voice recorder for meetings. The headline, two quiet lines of what to
/// expect, the meetings, and at the bottom, under the thumb, an optional name and Start
/// meeting. Everything else (speaker labels, privacy, how long transcripts take) is behind the
/// info button.
struct MeetingSpaceView: View {
    @Environment(MeetingCoordinator.self) private var meetings
    @Environment(\.colorScheme) private var scheme
    @State private var name = ""
    @State private var showsInfo = false
    @FocusState private var naming: Bool
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Meetings").font(.zoneHeadline).foregroundStyle(Zone.ink(scheme))
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 8)
                        Button { showsInfo = true } label: {
                            Image(systemName: "info.circle")
                                .font(.system(size: 20, weight: .regular))
                                .foregroundStyle(Zone.ink(scheme))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("How meetings work")
                        // Optical: the glyph's own edge, not its 44 pt hit area, meets the page edge.
                        .padding(.trailing, -12)
                    }
                    MeetingExpectations()
                    NavigationLink { MeetingAppearanceView() } label: {
                        Label("Meeting appearance", systemImage: "waveform")
                            .font(.subheadline)
                            .foregroundStyle(Zone.accentText(scheme))
                            .frame(minHeight: 44)
                    }
                }

                if let error = meetings.lastError {
                    Text(error).font(.footnote).foregroundStyle(Zone.live)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if meetings.meetings.isEmpty {
                    Text("No meetings yet. Set your phone on the table and start one.")
                        .font(.subheadline).foregroundStyle(Zone.muted(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // A list on the paper, a hairline apart, like History and Notes on Home.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Hairline()
                        ForEach(meetings.meetings) { meeting in
                            NavigationLink { MeetingDetailView(id: meeting.id) } label: {
                                MeetingRow(meeting: meeting)
                            }
                            .buttonStyle(.plain)
                            Hairline()
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { startBar }
        .sheet(isPresented: $showsInfo) {
            MeetingInfoSheet().presentationDetents([.large])
        }
        .task {
            await meetings.reload()
            meetings.refreshSpaceLeft()
            // Labels are on by default: fetch the speaker model now, not after the first meeting.
            meetings.prefetchSpeakerModel()
        }
    }

    /// The name field and Start meeting; while a meeting records, the way back to it.
    private var startBar: some View {
        let layout = verticalSizeClass == .compact
            ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 12))
        return layout {
            if let recording = meetings.recording {
                Button { meetings.showsRecorder = true } label: {
                    HStack(spacing: 8) {
                        Circle().fill(Zone.onAccent).frame(width: 8, height: 8)
                        Text("\(meetings.isPaused ? "Paused" : "Recording") · \(MeetingExport.timestamp(meetings.recordedSeconds))")
                            .monospacedDigit()
                    }
                }
                .buttonStyle(ZonePrimaryButtonStyle(fill: Zone.accent))
                .accessibilityLabel("Back to \(recording.title)")
            } else {
                TextField("Name (optional)", text: $name)
                    .font(.body)
                    .focused($naming)
                    .submitLabel(.go)
                    .onSubmit(start)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.sentences)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                    .background(Zone.field(scheme), in: Zone.fieldShape)
                    .overlay(Zone.fieldShape.strokeBorder(Zone.rule(scheme), lineWidth: 1))
                    .accessibilityLabel("Meeting name, optional")
                Button(action: start) {
                    Label(meetings.isFinishingRecording ? "Saving meeting…" : "Start meeting", systemImage: "record.circle")
                }
                .buttonStyle(ZonePrimaryButtonStyle())
                .disabled(meetings.isStartingRecording || meetings.isFinishingRecording)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Zone.paper(scheme).ignoresSafeArea(edges: .bottom))
        // Pinned under the thumb, so it stops growing before it covers the list.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .animation(Zone.motion, value: meetings.isRecording)
    }

    private func start() {
        let title = name
        naming = false
        Haptics.start()
        Task {
            await meetings.startRecording(title: title)
            if meetings.isRecording { name = "" }
        }
    }
}

/// The two lines that set expectations before a meeting starts: how long it can run, and when
/// and by what the transcript is written.
struct MeetingExpectations: View {
    @Environment(MeetingCoordinator.self) private var meetings
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(lengthLine + " Transcribes when you stop.")
        }
        .font(.footnote.monospacedDigit())
        .foregroundStyle(Zone.muted(scheme))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// The ceiling, or less when storage would end the recording first.
    private var lengthLine: String {
        guard let minutes = MeetingRecordingSafety.storageMinutes(hoursOfSpace: meetings.hoursOfSpaceLeft) else {
            return "Up to \(MeetingRecordingSafety.maximumLabel) per recording."
        }
        if minutes < 1 { return "Not enough free storage to record." }
        return "Free space fits ~\(MeetingExport.durationLabel(Double(minutes) * 60)) of audio."
    }
}

private struct MeetingRow: View {
    @Environment(MeetingCoordinator.self) private var meetings
    @Environment(\.colorScheme) private var scheme
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(meeting.title)
                    .font(.body.weight(.semibold)).foregroundStyle(Zone.ink(scheme))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Zone.muted(scheme))
                    .accessibilityHidden(true)
            }
            Text(meetingMetaLine(meeting, seconds: meetings.recording?.id == meeting.id ? meetings.recordedSeconds : nil))
                .font(.caption.monospacedDigit()).foregroundStyle(Zone.muted(scheme))
            status.padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var status: some View {
        switch meeting.status {
        case .recording:
            HStack(spacing: 6) {
                Circle().fill(Zone.accentGraphic).frame(width: 7, height: 7)
                Text(meetings.isPaused ? "Paused" : "Recording").font(.footnote.weight(.medium)).foregroundStyle(Zone.accentText(scheme))
            }
        case .transcribing:
            MeetingProgressLine(meeting: meeting)
        case .recorded:
            Text(meetings.queued.contains(meeting.id) ? "Waiting to transcribe" : (meeting.message ?? "Not transcribed yet"))
                .font(.footnote).foregroundStyle(Zone.muted(scheme)).lineLimit(2)
        case .failed:
            Text(meeting.message ?? "Transcription stopped").font(.footnote).foregroundStyle(Zone.live).lineLimit(3)
        case .done:
            if let first = MeetingExport.paragraphs(meeting).first {
                Text(first.text).font(.subheadline).foregroundStyle(Zone.muted(scheme)).lineLimit(2)
            } else {
                Text(meeting.message ?? "No speech").font(.footnote).foregroundStyle(Zone.muted(scheme))
            }
        }
    }
}

/// Behind the info button: what to expect, the speaker switch, and where the audio lives.
struct MeetingInfoSheet: View {
    @Environment(MeetingCoordinator.self) private var meetings
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        @Bindable var meetings = meetings
        MeetingSheet(title: "How meetings work") {
            MeetingFact("Recording", "Saves automatically and stops at \(MeetingRecordingSafety.maximumLabel). Pauses don't count toward the limit, and recording continues with the screen locked.")
            if let space = meetings.spaceShortLabel {
                MeetingFact("Free space", space + " available. Max \(MeetingRecordingSafety.maximumLabel) per recording.")
            }
            MeetingFact("Transcript", "Generated locally after you stop. Reopen Zone if background processing pauses.")
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $meetings.labelsSpeakers) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Label speakers").font(.body.weight(.medium)).foregroundStyle(Zone.ink(scheme))
                        Text(meetings.speakerModel == .ready
                             ? "Tap any speaker in the transcript to name them."
                             : "Downloads a \(MeetingDiarizer.downloadBytes.byteCountLabel) model once.")
                            .font(.footnote).foregroundStyle(Zone.muted(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(Zone.accentGraphic)
                SpeakerModelStatus()
            }
            MeetingFact("Storage", "Audio and transcripts stay in Zone. Export a backup in Settings to save a copy elsewhere.")
            DisclosureGroup("Calls and long meetings") {
                VStack(alignment: .leading, spacing: 16) {
                    MeetingFact("Interruptions", "Phone calls or Siri pause recording. Audio so far is saved, and Zone resumes when the call ends. Turn on Do Not Disturb to avoid gaps.")
                    MeetingFact("Over \(MeetingRecordingSafety.speakerLabel)", "Recordings longer than \(MeetingRecordingSafety.speakerLabel) transcribe without speaker labels. Start a new recording after \(MeetingRecordingSafety.maximumLabel).")
                }
                .padding(.top, 8)
            }
            .tint(Zone.accentText(scheme))
        }
    }
}
