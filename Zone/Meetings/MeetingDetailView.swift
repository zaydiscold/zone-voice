// by zayd/cold @ zayd.wtf

import AVFoundation
import SwiftUI
import ZoneCore

/// One meeting: its title, when and how long, the speakers, and the transcript. Share sits in
/// the toolbar; the models, parts and storage are behind the info button.
struct MeetingDetailView: View {
    @Environment(LinkCoordinator.self) private var link: LinkCoordinator?
    @Environment(MeetingCoordinator.self) private var meetings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State var id: UUID
    @State private var title = ""
    @State private var speakersTarget: SpeakersTarget?
    @State private var choosingMerge = false
    @State private var reviewingVoices = false
    @State private var confirmingDelete = false
    @State private var confirmingRetranscribe = false
    @State private var showsInfo = false
    @State private var editingTranscript = false
    @State private var playback = MeetingPlayback()
    @FocusState private var titleFocused: Bool

    private var meeting: Meeting? { meetings.meeting(id) }

    var body: some View {
        Group {
            if let meeting {
                content(meeting)
            } else {
                Text("Meeting not found.")
                    .font(.subheadline).foregroundStyle(Zone.muted(scheme))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        // The title is the editable name field, so there is no navigationTitle to follow; the
        // Back key still replaces the system's glass Back, from Meetings and from a search alike.
        .zoneBackButton()
        .toolbar(.visible, for: .navigationBar)
        .toolbar { toolbar }
        .zoneScreen()
        .sheet(item: $speakersTarget) { target in
            MeetingSpeakersSheet(meetingID: id, focus: target.person)
                .presentationDetents([.large])
        }
        .safeAreaInset(edge: .bottom) { if speakersTarget == nil { SpeakerUndoBar(meetingID: id) } }
        .animation(.snappy(duration: 0.2), value: meetings.speakerUndo)
        .sheet(isPresented: $choosingMerge) {
            MergePicker(target: id) { merged in id = merged }
                .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        }
        .sheet(isPresented: $reviewingVoices) {
            if let meeting {
                NavigationStack { MeetingVoiceReview(meeting: meeting) }
                    .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
            }
        }
        .sheet(isPresented: $showsInfo) {
            if let meeting { MeetingDetailInfo(meeting: meeting).presentationDetents([.medium, .large]) }
        }
        .sheet(isPresented: $editingTranscript) {
            if let meeting { MeetingTranscriptEditor(meeting: meeting) }
        }
        .onDisappear { playback.stop(); meetings.forgetSpeakerUndo() }
        .confirmationDialog("Delete this meeting?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete audio and transcript", role: .destructive) {
                meetings.delete(id)
                dismiss()
            }
        } message: {
            Text(["Deletes the audio and transcript from your iPhone.",
                  LinkCopy.deleteNote(link?.computers.map(\.name) ?? [], keeping: link?.computers.keepingNames ?? [],
                                      what: "copy of the transcript")].compactMap { $0 }.joined(separator: " "))
        }
        .sheet(isPresented: $confirmingRetranscribe) {
            if let meeting {
                MeetingRetranscribeSheet(meeting: meeting)
                    .presentationDetents([.medium, .large])
            }
        }
        .onAppear { title = meeting?.title ?? "" }
        .onChange(of: meeting?.title) { _, new in if !titleFocused, let new { title = new } }
    }

    private func content(_ meeting: Meeting) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Title", text: $title, axis: .vertical)
                        .font(.zoneTitle)
                        .foregroundStyle(Zone.ink(scheme))
                        .focused($titleFocused)
                        .submitLabel(.done)
                        .onSubmit { commitTitle() }
                        .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
                        .accessibilityLabel("Meeting title")
                    Text(meetingMetaLine(meeting)).font(.footnote.monospacedDigit()).foregroundStyle(Zone.muted(scheme))
                }

                statusBlock(meeting)
                if let notice = meeting.recordingNotice {
                    Text(notice).font(.footnote).foregroundStyle(Zone.live)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if meeting.status != .recording {
                    HStack(spacing: 12) {
                        Button {
                            if playback.isPlaying { playback.stop() }
                            else if !meetings.isRecording { playback.play(meeting: meeting, store: meetings.store) }
                        } label: {
                            Label(playback.isPlaying ? "Stop playback" : "Play recording", systemImage: playback.isPlaying ? "stop.fill" : "play.fill")
                        }
                        .buttonStyle(ZonePillButtonStyle())
                        .disabled(meetings.isRecording)
                        if playback.isPlaying {
                            Text(MeetingExport.timestamp(playback.position)).font(.footnote.monospacedDigit()).foregroundStyle(Zone.muted(scheme))
                        }
                    }
                    if let error = playback.error { Text(error).font(.footnote).foregroundStyle(Zone.live) }
                }

                if !meeting.speakers.isEmpty {
                    speakers(meeting)
                }

                let paragraphs = MeetingExport.paragraphs(meeting)
                if !paragraphs.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Hairline()
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(paragraphs) { paragraph in
                                ParagraphView(meeting: meeting, paragraph: paragraph) {
                                    if let person = paragraph.speaker, meeting.speakers.contains(where: { $0.id == person }) {
                                        speakersTarget = SpeakersTarget(person: person)
                                    }
                                }
                            }
                        }
                        .textSelection(.enabled)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let meeting {
            ZoneBarItem(.topBarTrailing) {
                Button { showsInfo = true } label: { Image(systemName: "info") }
                    .accessibilityLabel("Details")
                ShareLink(item: MeetingExport.text(meeting), subject: Text(meeting.title),
                          preview: SharePreview(meeting.title, image: Image(systemName: "person.2.wave.2"))) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share transcript")
                .disabled(meeting.segments.isEmpty)
                Menu {
                    Button { editingTranscript = true } label: { Label("Edit transcript", systemImage: "pencil") }
                        .disabled(meeting.segments.isEmpty || meeting.status == .recording || meeting.status == .transcribing)
                    Button { Clipboard.copy(MeetingExport.text(meeting)) } label: { Label("Copy transcript", systemImage: "doc.on.doc") }
                        .disabled(meeting.segments.isEmpty)
                    Button { speakersTarget = SpeakersTarget(person: nil) } label: { Label("Speakers", systemImage: "person.2") }
                        .disabled(meeting.speakers.isEmpty)
                    Button { choosingMerge = true } label: { Label("Merge with another recording", systemImage: "arrow.triangle.merge") }
                        .disabled(meeting.status == .recording || meeting.status == .transcribing)
                    Button { confirmingRetranscribe = true } label: { Label("Transcribe again", systemImage: "arrow.clockwise") }
                        .disabled(meeting.status == .recording || meetings.transcribingID == id)
                    Divider()
                    Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete meeting", systemImage: "trash") }
                        .disabled(meeting.status == .recording)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .accessibilityLabel("More")
            }
        }
    }

    @ViewBuilder private func statusBlock(_ meeting: Meeting) -> some View {
        switch meeting.status {
        case .recording:
            HStack(spacing: 12) {
                Text(meetings.isPaused ? "Paused" : "Recording").font(.body.weight(.medium)).zoneAccentBadge(scheme)
                Spacer()
                Button("Open") { meetings.showsRecorder = true }.buttonStyle(ZoneInkPillButtonStyle())
            }
        case .transcribing:
            HStack(alignment: .center, spacing: 12) {
                MeetingProgressLine(meeting: meeting)
                Button("Pause") { meetings.cancelTranscription(meeting.id) }.buttonStyle(ZonePillButtonStyle())
            }
        case .recorded, .failed:
            HStack(alignment: .center, spacing: 12) {
                Text(meetings.queued.contains(meeting.id) ? "Waiting to transcribe" : (meeting.message ?? "Not transcribed yet"))
                    .font(.footnote).foregroundStyle(meeting.status == .failed ? Zone.live : Zone.muted(scheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if !meetings.queued.contains(meeting.id) {
                    Button(meeting.transcribedThrough > 0 ? "Continue" : "Transcribe") { meetings.enqueue(meeting.id) }
                        .buttonStyle(ZoneInkPillButtonStyle())
                }
            }
        case .done:
            if meetings.isMatchingVoices(meeting.id) {
                // The transcript is done and readable; only who is who can still change.
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Matching voices across the recordings")
                        .font(.footnote).foregroundStyle(Zone.muted(scheme))
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("meeting.matchingVoices")
            } else if meeting.voiceReviewCandidates != nil, meeting.visibleMessage != nil {
                Button("Review voices") { reviewingVoices = true }.buttonStyle(ZonePillButtonStyle())
            } else if let message = meeting.visibleMessage {
                Text(message).font(.footnote).foregroundStyle(Zone.muted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func speakers(_ meeting: Meeting) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                // One pill per person: a voice joined to someone is not listed again.
                ForEach(meeting.people) { speaker in
                    Button { speakersTarget = SpeakersTarget(person: speaker.id) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: speaker.isMe ? "person.fill" : "waveform")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(speaker.isMe ? Zone.accentTone(scheme) : Zone.muted(scheme))
                            Text(meeting.speakerName(speaker.id) ?? speaker.id)
                            if speaker.recognized == true {
                                // Zone's guess from the voice, until someone saves the name.
                                Circle().fill(Zone.accentTone(scheme)).frame(width: 6, height: 6)
                            }
                        }
                    }
                    .buttonStyle(ZonePillButtonStyle())
                    .accessibilityValue(speaker.recognized == true ? "Recognized by voice, not confirmed" : "")
                    .accessibilityIdentifier("meeting.paragraph.speaker")
                    .accessibilityHint("Hear this speaker and name them")
                    .accessibilityIdentifier("meeting.speaker.\(speaker.id)")
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private func commitTitle() {
        guard let meeting, title != meeting.title else { return }
        meetings.rename(id, to: title)
    }
}

private struct ParagraphView: View {
    @Environment(\.colorScheme) private var scheme
    let meeting: Meeting
    let paragraph: MeetingParagraph
    let onSpeaker: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let name = meeting.speakerName(paragraph.speaker) {
                    let isMe = meeting.speakers.first(where: { $0.id == paragraph.speaker })?.isMe == true
                    Button(action: onSpeaker) {
                        Text(name).font(.subheadline.weight(.semibold))
                            .foregroundStyle(isMe ? Zone.controlInk(scheme) : Zone.ink(scheme))
                            .padding(.horizontal, isMe ? 6 : 0)
                            .background(isMe ? Zone.controlFill(scheme) : .clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("meeting.paragraph.speaker")
                    .accessibilityHint("Hear this speaker and name them")
                }
                Text(MeetingExport.timestamp(paragraph.start))
                    .font(.caption.monospacedDigit()).foregroundStyle(Zone.muted(scheme))
            }
            Text(paragraph.text)
                .font(paragraph.isGap ? .callout : .body)
                .foregroundStyle(paragraph.isGap ? Zone.muted(scheme) : Zone.ink(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Hearing a speaker

/// Plays a speaker's clips one after another from the meeting's PCM parts.
@Observable @MainActor
final class SpeakerSamplePlayer {
    private(set) static weak var current: SpeakerSamplePlayer?
    /// The clip playing now, if any.
    private(set) var playing: Int?
    private var task: Task<Void, Never>?
    private var player: AVAudioPlayer?

    func play(clips: [ClosedRange<Double>], from start: Int, meeting: UUID, store: MeetingStore) {
        MeetingPlayback.current?.stop()
        Self.current = self
        // Switching clips keeps the session: releasing it here would race the next activation.
        halt()
        let alreadyOwned = ownsSession
        task = Task { [weak self] in
            let activated = alreadyOwned ? false : await Self.prepareSession()
            if activated { self?.ownsSession = true }
            for index in start..<clips.count {
                guard let self, !Task.isCancelled else { return }
                let clip = clips[index]
                let data = await Task.detached(priority: .userInitiated) { () -> Data? in
                    guard let audio = try? store.audio(meeting) else { return nil }
                    let offset = Int(clip.lowerBound * 16_000)
                    let count = min(Int((clip.upperBound - clip.lowerBound) * 16_000), audio.sampleCount - offset)
                    guard count > 0, let samples = try? audio.read(offset: offset, count: count) else { return nil }
                    return PCMWave.data(samples: samples)
                }.value
                guard !Task.isCancelled, let data, let player = try? AVAudioPlayer(data: data) else { continue }
                self.player = player
                self.playing = index
                guard player.play() else { continue }
                while player.isPlaying, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(80)) }
                try? await Task.sleep(for: .milliseconds(350))
            }
            // A newer play() cancelled this one and carries the session on.
            guard !Task.isCancelled else { return }
            self?.playing = nil
            self?.releaseSession()
        }
    }

    func stop() {
        halt()
        releaseSession()
        if Self.current === self { Self.current = nil }
    }

    private func halt() {
        task?.cancel()
        task = nil
        player?.stop()
        player = nil
        playing = nil
    }

    /// True while the samples hold a playback session they started themselves.
    @ObservationIgnored private var ownsSession = false

    /// Hands the audio back so music or a podcast the samples paused resumes.
    private func releaseSession() {
        guard ownsSession else { return }
        ownsSession = false
        let session = AVAudioSession.sharedInstance()
        // If a meeting/dictation has acquired the session since playback started, it owns it.
        guard session.category == .playback else { return }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Dictation's armed session (play and record, speaker) already plays out loud. Otherwise
    /// ask for playback, so the ring switch does not silence the samples. Off the main actor:
    /// activating a session blocks. Returns whether this call activated one.
    private static func prepareSession() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        guard session.category != .playAndRecord else { return false }
        // Keep music/audiobooks playing, including when samples finish. Main-actor ordering
        // avoids a detached activation racing the start of a new meeting recording.
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        return (try? session.setActive(true)) != nil
    }
}

// MARK: Details and merge

private struct MeetingDetailInfo: View {
    @Environment(MeetingCoordinator.self) private var meetings
    let meeting: Meeting

    var body: some View {
        MeetingSheet(title: "Details") {
            MeetingFact("Recorded", "\(meeting.createdAt.formatted(date: .complete, time: .shortened)), \(MeetingExport.durationLabel(meeting.duration))\(meeting.parts.count > 1 ? " in \(meeting.parts.count) parts" : "").")
            if let notice = meeting.recordingNotice { MeetingFact("Notice", notice) }
            MeetingFact("Model", meeting.engine.map { EngineKind(rawValue: $0)?.displayName ?? $0 }
                        ?? "Pending (\(meetings.transcriberName)).")
            MeetingFact("Speakers", meeting.diarizer ?? (meeting.status == .done ? "Not labeled." : "Pending."))
            MeetingFact("Audio size", "\(Int64(meeting.parts.reduce(0) { $0 + $1.bytes }).byteCountLabel) stored locally, excluded from iCloud backups.")
        }
    }
}

/// Pick the other half of a split recording. Earlier audio always plays first.
struct MergePicker: View {
    @Environment(MeetingCoordinator.self) private var meetings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    let target: UUID
    let onMerged: (UUID) -> Void
    @State private var candidate: Meeting?
    @State private var joinedID: UUID?

    @ViewBuilder private func result(_ id: UUID) -> some View {
        if let meeting = meetings.meeting(id), meeting.voiceReviewCandidates?.isEmpty == false, !meetings.isMatchingVoices(id) {
            MeetingVoiceReview(meeting: meeting)
        } else if let meeting = meetings.meeting(id), meeting.speakerGroupsToMatch != nil, meeting.status == .done {
            ProgressView("Checking voices")
                .toolbar { ZoneBarItem(.cancellationAction) { Button("Close") { dismiss() } } }
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }

    private var choices: [Meeting] {
        meetings.meetings.filter { $0.id != target && $0.status != .recording && $0.status != .transcribing }
    }

    var body: some View {
        NavigationStack {
            if let joinedID {
                result(joinedID)
            } else {
                picker
            }
        }
    }

    private var picker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose another recording to combine with this one. Earlier audio plays first.")
                    .font(.subheadline).foregroundStyle(Zone.muted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                if choices.isEmpty {
                    Text("No other recordings available to merge.").font(.subheadline).foregroundStyle(Zone.muted(scheme))
                }
                ForEach(choices) { meeting in
                    Button { candidate = meeting } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(meeting.title).font(.body.weight(.semibold)).foregroundStyle(Zone.ink(scheme))
                            Text(meetingMetaLine(meeting)).font(.caption.monospacedDigit()).foregroundStyle(Zone.muted(scheme))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .zoneCard(padding: 16)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .navigationTitle("Merge")
        .zoneBackButton()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ZoneBarItem(.cancellationAction) { Button("Cancel") { dismiss() } } }
        .zoneScreen()
        .confirmationDialog("Merge these recordings?", isPresented: Binding(get: { candidate != nil }, set: { if !$0 { candidate = nil } }),
                            titleVisibility: .visible, presenting: candidate) { other in
            Button("Merge") {
                if let merged = meetings.merge(target, with: other.id) {
                    joinedID = merged
                    onMerged(merged)
                }
            }
        } message: { other in
            Text("\u{201C}\(other.title)\u{201D} joins this meeting as one recording. This cannot be undone.")
        }
    }
}

/// An explicit count can separate voices that automatic detection grouped together.
/// The choice belongs to this recording, never to every future meeting.
struct MeetingRetranscribeSheet: View {
    let meeting: Meeting
    @Environment(MeetingCoordinator.self) private var meetings
    @Environment(\.dismiss) private var dismiss
    @State private var count = 0

    /// A speaker named before voice prints were kept cannot be found again by voice.
    private var namesWithoutVoices: Bool {
        meeting.speakers.contains { speaker in
            speaker.voice == nil
                && (speaker.isMe || !(speaker.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Speakers", selection: $count) {
                        Text("Automatic").tag(0)
                        ForEach(1...8, id: \.self) { number in
                            Text(number == 1 ? "1 speaker" : "\(number) speakers").tag(number)
                        }
                    }
                    .disabled(!meetings.labelsSpeakers || meetings.speakerModel != .ready || meeting.duration > MeetingRecordingSafety.maximumSpeakerSeconds)
                } footer: {
                    if meeting.duration > MeetingRecordingSafety.maximumSpeakerSeconds {
                        Text(MeetingRecordingSafety.speakerLimitMessage)
                    } else if !meetings.labelsSpeakers {
                        Text("Enable Label speakers in Meetings → How meetings work first.")
                    } else if meetings.speakerModel != .ready {
                        Text("Download the speaker model in Meetings → How meetings work first.")
                    } else {
                        Text("Pick how many people spoke if two voices got merged. Short or overlapping speech can still mislabel.")
                    }
                }
                Section {
                    Text(namesWithoutVoices
                         ? "Rebuilds the transcript from saved audio. Manual edits and speaker names will reset."
                         : "Rebuilds the transcript from saved audio. Manual edits will reset; named speakers keep their names when Zone recognizes their voices.")
                    Button("Transcribe again") {
                        let hint = meetings.labelsSpeakers && meetings.speakerModel == .ready
                            && meeting.duration <= MeetingRecordingSafety.maximumSpeakerSeconds && count > 0 ? count : nil
                        meetings.retranscribe(meeting.id, expectedSpeakerCount: hint)
                        dismiss()
                    }
                    .disabled(meetings.transcribingID == meeting.id || meeting.status == .recording || meeting.status == .transcribing)
                }
            }
            .navigationTitle("Transcribe again")
            .zoneBackButton()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ZoneBarItem(.cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear { count = meeting.speakerCountHint ?? 0 }
        }
    }
}
