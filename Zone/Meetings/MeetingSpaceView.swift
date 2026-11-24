// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// Home's Meeting tab: a voice recorder for meetings. The headline, two quiet lines of what to
/// expect, the meetings, and at the bottom, under the thumb, an optional name and Start
/// meeting. Everything else (speaker labels, privacy, how long transcripts take) is behind the
/// info button.
struct MeetingSpaceView: View {
    let isActive: Bool
    @Environment(MeetingCoordinator.self) private var meetings
    @Environment(\.colorScheme) private var scheme
    @State private var query = ""
    @State private var hits: [LibrarySearch.Hit] = []
    @State private var searchIndex = LibrarySearch(documents: [])
    @State private var documents: [UUID: String] = [:]
    @State private var name = ""
    @State private var showsInfo = false
    @State private var mergeTarget: Meeting?
    private enum Field { case name, search }
    @FocusState private var focusedField: Field?
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SectionBreak.spacing) {
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
                            .labelStyle(ZoneCueLabelStyle(scheme: scheme))
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
                        TextField("Search meetings", text: $query)
                            .focused($focusedField, equals: .search)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("meetings.search")
                            .padding(.vertical, 8)
                        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            ForEach(meetings.meetings) { meeting in
                                if meeting.id != meetings.meetings.first?.id { RowRule() }
                                row(meeting)
                            }
                        } else if hits.isEmpty {
                            Text("No matching meetings").font(.subheadline).foregroundStyle(Zone.muted(scheme))
                        } else {
                            ForEach(hits, id: \.id) { hit in
                                if let meeting = meetings.meeting(hit.id), let text = documents[hit.id] {
                                    if hit.id != hits.first?.id { RowRule() }
                                    let excerpt = LibrarySearch.excerpt(text, marks: hit.ranges)
                                    row(meeting, excerpt: LibraryRow.marked(excerpt.text, excerpt.marks, scheme: scheme))
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .task(id: !isActive || query.isEmpty ? [] : meetings.meetings.map { SearchRevision(id: $0.id, updated: $0.updatedAt) }) {
            guard isActive && !query.isEmpty else { return }
            let snapshot = meetings.meetings
            let (index, texts) = await Task.detached(priority: .utility) {
                let entries = snapshot.map { LibrarySearch.Document(id: $0.id, text: MeetingExport.text($0), date: $0.createdAt) }
                return (LibrarySearch(documents: entries), Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.text) }))
            }.value
            guard !Task.isCancelled else { return }
            searchIndex = index
            documents = texts
            hits = index.search(query).hits
        }
        .onChange(of: query) { _, value in hits = searchIndex.search(value).hits }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: isActive) { _, active in
            if !active { focusedField = nil }
        }
        .safeAreaInset(edge: .bottom) { startBar }
        .sheet(item: $mergeTarget) { target in
            MergePicker(target: target.id) { _ in }.presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showsInfo) {
            MeetingInfoSheet().presentationDetents([.large])
        }
        .task(id: isActive) {
            guard isActive else { return }
            await meetings.reload()
            guard !Task.isCancelled else { return }
            meetings.refreshSpaceLeft()
            // Labels are on by default: fetch the speaker model now, not after the first meeting.
            meetings.prefetchSpeakerModel()
        }
    }

    private struct SearchRevision: Equatable {
        let id: UUID
        let updated: Date
    }

    @ViewBuilder private func row(_ meeting: Meeting, excerpt: AttributedString? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            NavigationLink { MeetingDetailView(id: meeting.id) } label: {
                MeetingRow(meeting: meeting, excerpt: excerpt)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("meeting.row." + meeting.title)
            if !meeting.segments.isEmpty {
                MeetingRowCopy(meeting: meeting)
            }
        }
        .modifier(MeetingRowMenu(meeting: meeting, merge: { mergeTarget = meeting }))
    }

    /// The name field and Start meeting; while a meeting records, the way back to it.
    private var startBar: some View {
        let layout = verticalSizeClass == .compact
            ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 12))
        return layout {
            if let recording = meetings.recording {
                Button { meetings.showsRecorder = true } label: {
                    HStack(spacing: 8) {
                        Circle().fill(Zone.controlInk(scheme)).frame(width: 8, height: 8)
                        Text("\(meetings.isPaused ? "Paused" : "Recording") · \(MeetingExport.timestamp(meetings.recordedSeconds))")
                            .monospacedDigit()
                    }
                }
                .buttonStyle(ZonePrimaryButtonStyle())
                .accessibilityLabel("Back to \(recording.title)")
            } else {
                TextField("Name (optional)", text: $name)
                    .font(.body)
                    .focused($focusedField, equals: .name)
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
        focusedField = nil
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

private struct MeetingRowCopy: View {
    let meeting: Meeting
    @State private var copied = false

    var body: some View {
        LibraryCopyButton(noun: "meeting transcript", copied: copied) {
            Clipboard.copy(MeetingExport.text(meeting))
            Haptics.tap()
            copied = true
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

private struct MeetingRow: View {
    @Environment(MeetingCoordinator.self) private var meetings
    @Environment(\.colorScheme) private var scheme
    let meeting: Meeting
    let excerpt: AttributedString?

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
            if let excerpt {
                Text(excerpt).font(.subheadline).foregroundStyle(Zone.muted(scheme)).lineLimit(3)
            } else {
                status.padding(.top, 4)
            }
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
                Circle().fill(Zone.accentTone(scheme)).frame(width: 7, height: 7)
                Text(meetings.isPaused ? "Paused" : "Recording").font(.footnote.weight(.medium)).zoneAccentBadge(scheme)
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
    @Environment(DictationCoordinator.self) private var dictation
    @Environment(\.colorScheme) private var scheme
    @State private var showsVoiceSetup = false
    @State private var confirmDelete = false
    @State private var profile = VoiceProfileStore.default.load(model: MeetingDiarizer.modelName)

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
                .tint(Zone.accentTone(scheme))
                SpeakerModelStatus()
                Toggle(isOn: $meetings.recognizesVoices) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recognize voices").font(.body.weight(.medium)).foregroundStyle(Zone.ink(scheme))
                        Text("Names people you named before, and you, when their voice comes back. Tap a recognized name to confirm it.")
                            .font(.footnote).foregroundStyle(Zone.muted(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(Zone.accentTone(scheme))
                .disabled(!meetings.labelsSpeakers)
                voiceSetupRow
            }
            MeetingFact("Voice data", LinkCopy.voicePrivacy)
            DisclosureGroup("Calls and long meetings") {
                VStack(alignment: .leading, spacing: 16) {
                    MeetingFact("Interruptions", "Phone calls or Siri pause recording. Audio so far is saved, and Zone resumes when the call ends. Turn on Do Not Disturb to avoid gaps.")
                    MeetingFact("Over \(MeetingRecordingSafety.speakerLabel)", "Recordings longer than \(MeetingRecordingSafety.speakerLabel) transcribe without speaker labels. Start a new recording after \(MeetingRecordingSafety.maximumLabel).")
                }
                .padding(.top, 8)
            }
            .tint(Zone.inlineInk(scheme))
        }
        .fullScreenCover(isPresented: $showsVoiceSetup) {
            VoiceSetupView(dictation: dictation, meetings: meetings)
        }
        .onReceive(NotificationCenter.default.publisher(for: VoiceProfileStore.didChange).receive(on: RunLoop.main)) { _ in
            profile = VoiceProfileStore.default.load(model: MeetingDiarizer.modelName)
        }
        .confirmationDialog("Delete your voice?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete my voice", role: .destructive) { try? VoiceProfileStore.default.delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Meetings stop recognizing you from voice setup. A meeting where you tapped This is me still teaches Zone your voice.")
        }
    }

    /// Voice setup: teach Zone your voice on purpose, or redo or delete it.
    @ViewBuilder private var voiceSetupRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your voice").font(.body.weight(.medium)).foregroundStyle(Zone.ink(scheme))
                Text(profile.map { "Set up \($0.createdAt.formatted(date: .abbreviated, time: .omitted)). Meetings name you when they hear it." }
                     ?? "Three minutes of reading and talking, so meetings name you from the start.")
                    .font(.footnote).foregroundStyle(Zone.muted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button(profile == nil ? "Teach Zone your voice" : "Set up again") { showsVoiceSetup = true }
                    .buttonStyle(ZoneInkPillButtonStyle())
                    .disabled(dictation.voiceSetupRefusal != nil)
                if profile != nil {
                    Button("Delete my voice") { confirmDelete = true }.buttonStyle(ZonePillButtonStyle())
                }
            }
            if let refusal = dictation.voiceSetupRefusal {
                Text(refusal).font(.footnote).foregroundStyle(Zone.muted(scheme))
            }
        }
        .disabled(!meetings.labelsSpeakers || !meetings.recognizesVoices)
        .opacity(meetings.labelsSpeakers && meetings.recognizesVoices ? 1 : 0.5)
    }
}

struct MeetingRowMenu: ViewModifier {
    @Environment(MeetingCoordinator.self) private var meetings
    @Environment(LinkCoordinator.self) private var link: LinkCoordinator?
    let meeting: Meeting
    @State private var deleting = false
    @State private var renaming = false
    @State private var title = ""
    let merge: () -> Void
    @State private var transcribing = false
    @State private var editing = false

    private var actions: [LibraryRow.Action] {
        var items: [LibraryRow.Action] = [.init(title: "Rename", symbol: "pencil") {
            title = meeting.title
            renaming = true
        }]
        if meeting.status != .recording && meeting.status != .transcribing {
            if !meeting.segments.isEmpty {
                items.append(.init(title: "Edit transcript", symbol: "text.cursor") { editing = true })
            }
            items.append(.init(title: "Merge with another recording", symbol: "arrow.triangle.merge") { merge() })
            items.append(.init(title: "Transcribe again", symbol: "arrow.clockwise") { transcribing = true })
        }
        return items
    }

    func body(content: Content) -> some View {
        content
            .modifier(RowMenu(text: meeting.segments.isEmpty ? meeting.title : MeetingExport.text(meeting),
                              actions: actions, delete: meeting.status == .recording ? nil : { deleting = true }))
            .alert("Rename meeting", isPresented: $renaming) {
                TextField("Meeting title", text: $title)
                Button("Save") { meetings.rename(meeting.id, to: title) }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $editing) { MeetingTranscriptEditor(meeting: meeting) }
            .sheet(isPresented: $transcribing) { MeetingRetranscribeSheet(meeting: meeting) }
            .confirmationDialog("Delete this meeting?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete audio and transcript", role: .destructive) { meetings.delete(meeting.id) }
            } message: {
                Text(["Deletes the audio and transcript from your iPhone.",
                      LinkCopy.deleteNote(link?.computers.map(\.name) ?? [], keeping: link?.computers.keepingNames ?? [],
                                          what: "copy of the transcript")].compactMap { $0 }.joined(separator: " "))
            }
    }
}
