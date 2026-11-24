// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// What the Speakers sheet opens on: everyone, or one person (a tap on their name) who is
/// heard at once.
struct SpeakersTarget: Identifiable {
    let id = UUID()
    var person: String?
}

/// Everyone in a meeting on one screen: hear a voice, see a line they said, name them, mark
/// yourself, say two speakers are the same person, or separate a voice that was joined to the
/// wrong one. Rows a hairline apart, one open at a time; every change can be undone.
struct MeetingSpeakersSheet: View {
    @Environment(MeetingCoordinator.self) private var meetings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    let meetingID: UUID
    let focus: String?
    /// The person whose row is open.
    @State private var open: String?
    @State private var name = ""
    /// Someone already has the name being saved: ask before making two of them.
    @State private var clash: MeetingSpeaker?
    @State private var player = SpeakerSamplePlayer()
    /// The row (a person or one voice) the player is playing for.
    @State private var playingFor: String?
    @FocusState private var naming: Bool

    private var meeting: Meeting? { meetings.meeting(meetingID) }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let meeting {
                    VStack(alignment: .leading, spacing: 0) {
                        if meetings.isMatchingVoices(meetingID) {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Matching voices across the recordings")
                                    .font(.footnote).foregroundStyle(Zone.muted(scheme))
                            }
                            .padding(.bottom, 12)
                            .accessibilityIdentifier("meeting.speakers.matching")
                        }
                        ForEach(meeting.people) { person in
                            row(person, in: meeting)
                            Hairline()
                        }
                        Text("Two people under one name? More > Transcribe again lets you say how many spoke.")
                            .font(.footnote).foregroundStyle(Zone.muted(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 16)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Speakers")
            .zoneBackButton()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ZoneBarItem(.confirmationAction, prominent: true) { Button("Done") { commitName(); if clash == nil { dismiss() } } } }
            .zoneScreen()
            .safeAreaInset(edge: .bottom) { SpeakerUndoBar(meetingID: meetingID) }
        }
        .onAppear {
            guard let meeting, let focus, let person = meeting.person(focus) else { return }
            toggle(person, in: meeting)
            // Hear them first, as a tap on a name always has. Never out loud into a recording.
            play(person, voices: Set(meeting.voices(of: person).map(\.id)), count: 3, in: meeting)
        }
        .onDisappear { player.stop() }
        .onChange(of: player.playing) { _, playing in if playing == nil { playingFor = nil } }
    }

    // MARK: Rows

    @ViewBuilder private func row(_ person: MeetingSpeaker, in meeting: Meeting) -> some View {
        let voices = meeting.voices(of: person.id)
        let isOpen = open == person.id
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                playButton(key: person.id, label: meeting.speakerName(person.id) ?? "speaker") {
                    play(person.id, voices: Set(voices.map(\.id)), count: 1, in: meeting)
                }
                Button { toggle(person.id, in: meeting) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(meeting.speakerName(person.id) ?? person.id)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(person.isMe ? Zone.controlInk(scheme) : Zone.ink(scheme))
                            .padding(.horizontal, person.isMe ? 6 : 0)
                            .background(person.isMe ? Zone.controlFill(scheme) : .clear, in: Capsule())
                            if person.recognized == true {
                                Circle().fill(Zone.accentTone(scheme)).frame(width: 6, height: 6)
                            }
                            Spacer(minLength: 8)
                            Text(MeetingExport.durationLabel(meeting.speechSeconds(of: person.id)))
                                .font(.footnote.monospacedDigit()).foregroundStyle(Zone.muted(scheme))
                        }
                        if let line = meeting.mainVoice(of: person.id).flatMap({ meeting.sampleLine(ofVoice: $0) }) {
                            Text("\u{201C}\(line.text.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}")
                                .font(.subheadline).foregroundStyle(Zone.muted(scheme))
                                .lineLimit(2).multilineTextAlignment(.leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("meeting.speakers.row.\(person.id)")
                .accessibilityValue(person.recognized == true ? "Recognized by voice, not confirmed" : "")
                .accessibilityHint(isOpen ? "Closes" : "Name, mark as you, or combine")
            }
            if !isOpen, let match = suggestion(for: person, in: meeting) {
                HStack(spacing: 12) {
                    Text("Sounds like \(meeting.speakerName(match) ?? "someone here")")
                        .font(.footnote).foregroundStyle(Zone.muted(scheme))
                    Spacer(minLength: 8)
                    Button("Same person") { meetings.joinSpeakers(meetingID, speaker: person.id, into: match) }
                        .buttonStyle(ZonePillButtonStyle())
                        .accessibilityIdentifier("meeting.speakers.suggest.\(person.id)")
                }
                .padding(.leading, 56)
            }
            if isOpen { editor(person, voices: voices, in: meeting) }
        }
        .padding(.vertical, 14)
    }

    @ViewBuilder private func editor(_ person: MeetingSpeaker, voices: [MeetingSpeaker], in meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if person.recognized == true {
                Text("Zone recognized this voice. Save the name to confirm, or change it.")
                    .font(.footnote).foregroundStyle(Zone.muted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Name", text: $name)
                .font(.body)
                .padding(.horizontal, 16)
                .frame(minHeight: 48)
                .background(Zone.field(scheme), in: Zone.fieldShape)
                .overlay(Zone.fieldShape.strokeBorder(Zone.rule(scheme), lineWidth: 1))
                .focused($naming)
                // Names are not dictionary words; autocorrect turned "Zayd" into "Says".
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
                .textContentType(.name)
                .submitLabel(.done)
                .onSubmit { commitName() }
                .onChange(of: name) { _, _ in clash = nil }
                .accessibilityIdentifier("meeting.speakers.name")
            let known = (person.name ?? "").isEmpty ? meetings.speakerNames(notIn: meetingID) : []
            if !known.isEmpty, clash == nil {
                // Names from earlier meetings: one tap, no typing.
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(known, id: \.self) { known in
                            Button(known) {
                                name = known
                                meetings.renameSpeaker(meetingID, speaker: person.id, to: known)
                            }
                            .buttonStyle(ZonePillButtonStyle())
                            .accessibilityIdentifier("meeting.speakers.known.\(known)")
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
            if let clash {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(meeting.speakerName(clash.id) ?? "That name") is already a speaker here.")
                        .font(.footnote).foregroundStyle(Zone.ink(scheme))
                    HStack(spacing: 8) {
                        Button("Same person") {
                            meetings.joinSpeakers(meetingID, speaker: person.id, into: clash.id)
                            self.clash = nil
                            open = nil
                        }
                        .buttonStyle(ZoneInkPillButtonStyle())
                        .accessibilityIdentifier("meeting.speakers.clash.same")
                        Button("Two people") {
                            meetings.renameSpeaker(meetingID, speaker: person.id, to: name, sharesName: true)
                            self.clash = nil
                        }
                        .buttonStyle(ZonePillButtonStyle())
                    }
                }
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if person.isMe {
                        Button("This is not me") { meetings.setMe(meetingID, speaker: nil) }
                            .buttonStyle(ZonePillButtonStyle())
                    } else if let me = meeting.me(except: person.id) {
                        // Someone already is. The same person twice, or the earlier pick was wrong:
                        // both answers are here, and neither takes anything away unasked.
                        Button("This is also me") {
                            meetings.setMe(meetingID, speaker: person.id)
                            open = meeting.person(me.id)
                        }
                        .buttonStyle(ZoneInkPillButtonStyle())
                        .accessibilityIdentifier("meeting.speakers.alsoMe")
                        Button("Only this is me") { meetings.moveMe(meetingID, to: person.id) }
                            .buttonStyle(ZonePillButtonStyle())
                            .accessibilityIdentifier("meeting.speakers.onlyMe")
                    } else {
                        Button("This is me") { meetings.setMe(meetingID, speaker: person.id) }
                            .buttonStyle(ZoneInkPillButtonStyle())
                            .accessibilityIdentifier("meeting.speakers.me")
                    }
                    let others = candidates(for: person, in: meeting)
                    if !others.isEmpty {
                        Menu {
                            ForEach(others, id: \.self) { other in
                                Button(meeting.speakerName(other) ?? other) {
                                    commitName()
                                    meetings.joinSpeakers(meetingID, speaker: person.id, into: other)
                                    open = other
                                    name = meetings.meeting(meetingID)?.people.first { $0.id == other }?.name ?? ""
                                }
                            }
                        } label: {
                            Text("Same person as")
                        }
                        .buttonStyle(ZonePillButtonStyle())
                        .accessibilityIdentifier("meeting.speakers.sameAs")
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            let joined = voices.filter { $0.id != person.id }
            if !joined.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(joined.count == 1 ? "One more voice is counted as this person" : "\(joined.count) more voices are counted as this person")
                        .font(.footnote).foregroundStyle(Zone.muted(scheme))
                    ForEach(joined) { voice in
                        HStack(alignment: .center, spacing: 12) {
                            playButton(key: voice.id, label: "this voice") {
                                play(voice.id, voices: [voice.id], count: 1, in: meeting)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                if let line = meeting.sampleLine(ofVoice: voice.id) {
                                    Text("From \(MeetingExport.timestamp(line.start))")
                                        .font(.footnote.monospacedDigit()).foregroundStyle(Zone.ink(scheme))
                                    Text("\u{201C}\(line.text.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}")
                                        .font(.footnote).foregroundStyle(Zone.muted(scheme)).lineLimit(1)
                                } else {
                                    Text("No lines").font(.footnote).foregroundStyle(Zone.muted(scheme))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Separate") { meetings.separateSpeaker(meetingID, speaker: voice.id) }
                                .buttonStyle(ZonePillButtonStyle())
                                .accessibilityIdentifier("meeting.speakers.separate.\(voice.id)")
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.leading, 56)
    }

    private func playButton(key: String, label: String, action: @escaping () -> Void) -> some View {
        let playing = playingFor == key && player.playing != nil
        return Button {
            if playing { player.stop(); playingFor = nil } else { action() }
        } label: {
            Image(systemName: playing ? "stop.fill" : "play.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(playing ? Zone.accentTone(scheme) : Zone.ink(scheme))
                .frame(width: 44, height: 44)
                .background(Zone.card(scheme), in: Zone.keyShape)
                .overlay(Zone.keyShape.strokeBorder(playing ? Zone.accentStroke(scheme) : Zone.rule(scheme), lineWidth: playing ? 1.5 : 1))
                .contentShape(Zone.keyShape)
        }
        .buttonStyle(ScaleButtonStyle())
        .disabled(meetings.isRecording)
        .accessibilityLabel(playing ? "Stop" : "Hear \(label)")
        .accessibilityIdentifier("meeting.speakers.play.\(key)")
    }

    // MARK: Actions

    private func toggle(_ person: String, in meeting: Meeting) {
        commitName()
        guard clash == nil else { return }
        if open == person {
            open = nil
        } else {
            open = person
            name = meeting.people.first { $0.id == person }?.name ?? ""
        }
    }

    /// Saves the open row's name when it changed. A name someone else here already has asks
    /// first; nothing is saved until answered.
    private func commitName() {
        guard let open, let meeting, let person = meeting.people.first(where: { $0.id == open }) else { return }
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed != (person.name ?? "") || (person.recognized == true && !typed.isEmpty) else { return }
        if let other = meeting.personNamed(typed, except: open) {
            clash = other
            return
        }
        meetings.renameSpeaker(meetingID, speaker: open, to: typed)
    }

    private func play(_ key: String, voices: Set<String>, count: Int, in meeting: Meeting) {
        guard !meetings.isRecording else { return }
        let clips = MeetingSpeakerSamples.clips(for: voices, in: meeting.segments, count: count)
        guard !clips.isEmpty else { return }
        playingFor = key
        player.play(clips: clips, from: 0, meeting: meetingID, store: meetings.store)
    }

    /// Who "Same person as" offers: everyone else, the closest voices first when prints exist.
    private func candidates(for person: MeetingSpeaker, in meeting: Meeting) -> [String] {
        let near = MeetingVoiceMatch.closest(to: person.id, in: meeting).map(\.person)
        return near + meeting.people.map(\.id).filter { $0 != person.id && !near.contains($0) }
    }

    /// An unnamed speaker who sounds like someone listed before them, offered on the row itself.
    private func suggestion(for person: MeetingSpeaker, in meeting: Meeting) -> String? {
        guard !person.isMe, (person.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let index = meeting.people.firstIndex(where: { $0.id == person.id }) else { return nil }
        let earlier = Set(meeting.people.prefix(index).map(\.id))
        return MeetingVoiceMatch.closest(to: person.id, in: meeting).first { earlier.contains($0.person) }?.person
    }
}

/// "Combined Speaker 3 with Me" and Undo, for the last change to who is who in this meeting.
struct SpeakerUndoBar: View {
    @Environment(MeetingCoordinator.self) private var meetings
    @Environment(\.colorScheme) private var scheme
    let meetingID: UUID

    var body: some View {
        if let undo = meetings.speakerUndo, undo.meeting == meetingID {
            HStack(spacing: 12) {
                Text(undo.what)
                    .font(.footnote).foregroundStyle(Zone.ink(scheme))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Undo") { meetings.undoSpeakerChange() }
                    .buttonStyle(ZoneInkPillButtonStyle())
                    .accessibilityIdentifier("meeting.speakers.undo")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Zone.card(scheme), in: Zone.keyShape)
            .overlay(Zone.keyShape.strokeBorder(Zone.rule(scheme), lineWidth: 1))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// A merge keeps the two recordings' voice IDs until the listener confirms the pairs.
struct MeetingVoiceReview: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(MeetingCoordinator.self) private var meetings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    let meeting: Meeting
    private let pairs: [MeetingVoiceMatch.ReviewPair]
    private let suggested: Set<MeetingVoiceMatch.ReviewPair>
    @State private var selected: Set<MeetingVoiceMatch.ReviewPair>
    @State private var player = SpeakerSamplePlayer()
    @State private var playing: String?
    @State private var error: String?

    init(meeting: Meeting) {
        self.meeting = meeting
        pairs = MeetingVoiceMatch.reviewPairs(in: meeting)
        suggested = MeetingVoiceMatch.suggestedPairs(in: meeting)
        _selected = State(initialValue: suggested)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Listen to both voices. Select the pairs to combine.")
                    .font(.subheadline).foregroundStyle(Zone.muted(scheme))
                if suggested.isEmpty {
                    rows(pairs)
                } else {
                    rows(pairs.filter(suggested.contains))
                    let others = pairs.filter { !suggested.contains($0) }
                    if !others.isEmpty {
                        DisclosureGroup("Less likely pairs") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Zone found these voices less alike.")
                                    .font(.footnote).foregroundStyle(Zone.muted(scheme))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                rows(others)
                            }
                            .padding(.top, 6)
                        }
                    }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(Zone.live) }
            }
            .padding(20)
        }
        .navigationTitle(typeSize.isAccessibilitySize ? "Voices" : "Same person?")
        .zoneBackButton()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ZoneBarItem(.cancellationAction) { Button("Later") { dismiss() } }
            ZoneBarItem(.confirmationAction, prominent: true) {
                Button(selected.isEmpty ? "Keep separate" : "Confirm pairs") {
                    do {
                        try meetings.finishVoiceReview(meeting.id, selected: selected)
                        dismiss()
                    } catch { self.error = "Zone couldn't combine these voices. Try again." }
                }
            }
        }
        .zoneScreen()
        .onDisappear { player.stop() }
    }

    /// One pair per row: the choice first, the two names as one sentence, a play button for each
    /// voice underneath. Two bare play buttons side by side did not read as a pair.
    private func rows(_ pairs: [MeetingVoiceMatch.ReviewPair]) -> some View {
        ForEach(pairs, id: \.self) { pair in
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    error = nil
                    if selected.remove(pair) == nil {
                        var proposed = selected.filter { $0.from != pair.from && $0.to != pair.to }
                        proposed.insert(pair)
                        if MeetingVoiceMatch.reviewedSpeakers(for: proposed, in: meeting) != nil {
                            selected = proposed
                        } else {
                            error = "These choices would combine two people with different names. Deselect a pair first."
                        }
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: selected.contains(pair) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                        Text("\(name(pair.from)) and \(name(pair.to))")
                            .font(.body).foregroundStyle(Zone.ink(scheme))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Combine \(name(pair.from)) and \(name(pair.to))")
                .accessibilityValue(selected.contains(pair) ? "Yes" : "No")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) {
                        sample(pair.from)
                        sample(pair.to)
                    }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 0) {
                        sample(pair.from)
                        sample(pair.to)
                    }
                }
            }
        }
    }

    private func name(_ id: String) -> String { meeting.speakerName(id) ?? id }

    private func sample(_ id: String) -> some View {
        let voices = Set(meeting.voices(of: id).map(\.id))
        let clips = MeetingSpeakerSamples.clips(for: voices, in: meeting.segments, count: 1)
        let active = playing == id && player.playing != nil
        return Button {
            if active { player.stop(); return }
            playing = id
            player.play(clips: clips, from: 0, meeting: meeting.id, store: meetings.store)
        } label: {
            Label(name(id), systemImage: active ? "stop.fill" : "play.fill")
                .font(.footnote).frame(minHeight: 44)
        }
        .accessibilityLabel("\(active ? "Stop" : "Play") \(name(id))")
        .disabled(meetings.isRecording || clips.isEmpty)
    }
}
