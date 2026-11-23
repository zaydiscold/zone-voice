// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

// Pieces shared by the Meeting space, the recorder and a meeting's page.

/// Meeting mode is early, so it is labeled Alpha. `onInk` for the tag on a selected ink pill.
struct AlphaTag: View {
    @Environment(\.colorScheme) private var scheme
    var onInk = false

    var body: some View {
        let color = onInk ? Zone.onInk(scheme).opacity(0.8) : Zone.accentText(scheme)
        Text("Alpha")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(color.opacity(0.55), lineWidth: 1))
            .fixedSize()
            .accessibilityLabel("Alpha")
    }
}

/// "Nov 2, 10:04 AM · 48 min".
func meetingMetaLine(_ meeting: Meeting, seconds: Double? = nil) -> String {
    "\(meeting.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(MeetingExport.durationLabel(seconds ?? meeting.duration))"
}

/// Where the speaker model is: downloading with a bar, ready, or failed with Try again.
struct SpeakerModelStatus: View {
    @Environment(MeetingCoordinator.self) private var meetings
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch meetings.speakerModel {
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: fraction).tint(Zone.accentGraphic)
                Text("Downloading, \(Int(fraction * 100))% of \(MeetingDiarizer.downloadBytes.byteCountLabel)")
                    .font(.caption.monospacedDigit()).foregroundStyle(Zone.muted(scheme))
            }
            .accessibilityElement(children: .combine)
        case .ready:
            Label("Downloaded", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(Zone.muted(scheme))
        case .failed(let message):
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(message).font(.caption).foregroundStyle(Zone.live)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { meetings.prefetchSpeakerModel() }
                    .buttonStyle(ZonePillButtonStyle())
            }
        case .absent:
            EmptyView()
        }
    }
}

/// A thin accent bar with what the transcriber is doing and about how long is left.
struct MeetingProgressLine: View {
    @Environment(MeetingCoordinator.self) private var meetings
    @Environment(\.colorScheme) private var scheme
    let meeting: Meeting

    var body: some View {
        let live = meetings.transcribingID == meeting.id
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: live ? (waitsForDownload ? (meetings.speakerModelDownload ?? 0) : meetings.progress) : meeting.progress)
                .tint(Zone.accentGraphic)
                .animation(Zone.motion, value: meetings.progress)
            Text(label(live: live)).font(.caption.monospacedDigit()).foregroundStyle(Zone.muted(scheme))
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    private var waitsForDownload: Bool { meetings.transcriptionWaitsForSpeakerModel }

    private func label(live: Bool) -> String {
        guard live else { return "Waiting to transcribe" }
        if waitsForDownload {
            let download = meetings.speakerModelDownload ?? 0
            return "Downloading speaker model · \(Int(download * 100))% of \(MeetingDiarizer.downloadBytes.byteCountLabel)"
        }
        // Only steps with a real fraction show one; waiting steps say what they wait for.
        guard ["Transcribing", "Finding speakers"].contains(meetings.phase) else { return meetings.phase }
        var text = "\(meetings.phase), \(Int(meetings.progress * 100))%"
        if let left = meetings.remainingLabel(meeting) { text += " · \(left)" }
        return text
    }
}

/// A sheet's paper, title and close button, shared by the info sheets.
struct MeetingSheet<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) { content }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(title)
            .zoneBackButton()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ZoneBarItem(.confirmationAction, prominent: true) { Button("Done") { dismiss() } }
            }
            .zoneScreen()
        }
    }
}

/// One fact in an info sheet: a small label over a sentence.
struct MeetingFact: View {
    @Environment(\.colorScheme) private var scheme
    let label: String
    let text: String

    init(_ label: String, _ text: String) {
        self.label = label
        self.text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow(label)
            Text(text).font(.body).foregroundStyle(Zone.ink(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
