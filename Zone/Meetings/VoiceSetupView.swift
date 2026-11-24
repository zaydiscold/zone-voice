// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// Voice setup: a few guided minutes that teach Zone your voice for meetings (`VoiceSetup`).
/// Read aloud, talk about your day, whisper, then speak from across the room. Each part fills a
/// bar as Zone hears speech and chimes when it has enough.
struct VoiceSetupView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: VoiceSetupSession
    @State private var confirmLeave = false
    @State private var idleTimerBefore = false

    init(dictation: DictationCoordinator, meetings: MeetingCoordinator) {
        _session = State(initialValue: VoiceSetupSession(dictation: dictation, meetings: meetings))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch session.stage {
                case .intro: intro
                case .step(let part): StepScreen(session: session, part: part)
                case .review: review
                case .finished: finished
                }
            }
            .animation(Zone.motion, value: session.stage)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The last screen ends with its own Done.
                if session.stage != .finished {
                    ZoneBarItem(.cancellationAction) {
                        Button {
                            if session.stage == .intro { close() } else { confirmLeave = true }
                        } label: {
                            Text("Cancel")
                        }
                        // The bar offers a full-screen cover's item too little width otherwise.
                        .fixedSize()
                    }
                }
            }
            .confirmationDialog("Stop voice setup?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Stop without saving", role: .destructive) { close() }
                Button("Keep going", role: .cancel) {}
            } message: {
                Text("Nothing you've recorded here is kept.")
            }
            .zoneScreen()
        }
        .interactiveDismissDisabled(session.stage != .intro && session.stage != .finished)
        .onChange(of: scenePhase) { _, phase in
            // Never record in the background: the part pauses and continues on return.
            if phase != .active { session.stopEverything() }
        }
        // The far step leaves the phone across the room for half a minute: it must not lock.
        .onAppear {
            idleTimerBefore = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            session.stopEverything()
            UIApplication.shared.isIdleTimerDisabled = idleTimerBefore
        }
    }

    private var title: String {
        switch session.stage {
        case .intro, .review, .finished: return "Your voice"
        case .step(let part):
            let index = (VoiceSetup.Part.allCases.firstIndex(of: part) ?? 0) + 1
            return "Step \(index) of \(VoiceSetup.Part.allCases.count)"
        }
    }

    private func close() {
        session.stopEverything()
        dismiss()
    }

    // MARK: Intro

    private var intro: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("So meetings know which voice is yours")
                        .font(.zoneTitle).foregroundStyle(Zone.ink(scheme))
                    Text("About three minutes. Zone listens to you read, talk, whisper and speak from across the room, then names you in meetings without asking.")
                        .font(.body).foregroundStyle(Zone.muted(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(VoiceSetup.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("\(index + 1)").font(.footnote.weight(.semibold).monospacedDigit())
                                .foregroundStyle(Zone.ink(scheme)).frame(width: 18, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.title).font(.body.weight(.medium)).foregroundStyle(Zone.ink(scheme))
                                Text(Self.summary(step.part)).font(.footnote).foregroundStyle(Zone.muted(scheme))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .zoneCard()
                MeetingFact("Privacy", "Zone keeps a voice print, 256 numbers made from your voice, not the recording. It stays on this iPhone, and Delete my voice removes it.")
                MeetingFact("Best place", "Somewhere quiet. A room with other people talking makes a print of them too.")
                if let message = session.message {
                    Text(message).font(.footnote).foregroundStyle(Zone.live)
                }
                Button("Start") { session.begin() }
                    .buttonStyle(ZonePrimaryButtonStyle())
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 32)
        }
    }

    static func summary(_ part: VoiceSetup.Part) -> String {
        switch part {
        case .read: return "A short passage at your normal pace. About 45 seconds."
        case .talk: return "Anything at all. Questions appear if you run out. About 30 seconds."
        case .whisper: return "Two sentences, whispered. Under 10 seconds."
        case .far: return "Put the phone down across the room and keep talking. About 20 seconds."
        }
    }

    // MARK: Review

    private var review: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(session.canSave ? "That's everything Zone needs" : "Zone needs a bit more")
                    .font(.zoneTitle).foregroundStyle(Zone.ink(scheme))
                VStack(spacing: 0) {
                    ForEach(VoiceSetup.Part.allCases, id: \.self) { part in
                        PartRow(session: session, part: part)
                        if part != VoiceSetup.Part.allCases.last { Divider().overlay(Zone.rule(scheme)) }
                    }
                }
                .zoneCard(padding: 0)
                if !session.canSave {
                    Text("Read aloud or talk about your day for at least \(Int(VoiceSetup.minimumVoiced)) seconds between them. Tap Record again on either.")
                        .font(.footnote).foregroundStyle(Zone.muted(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let message = session.message {
                    Text(message).font(.footnote).foregroundStyle(Zone.live)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    Task { await session.save() }
                } label: {
                    if session.saving || !session.printsSettled {
                        HStack(spacing: 8) { ProgressView(); Text("Making your voice print") }
                    } else {
                        Text("Save my voice")
                    }
                }
                .buttonStyle(ZonePrimaryButtonStyle())
                .disabled(!session.canSave || session.saving)
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 32)
        }
    }

    // MARK: Finished

    private var finished: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44)).foregroundStyle(Zone.accentTone(scheme))
                    .accessibilityHidden(true)
                Text("Zone knows your voice")
                    .font(.zoneTitle).foregroundStyle(Zone.ink(scheme))
                Text("In your next meeting, the voice that sounds like you is labeled Me, with a dot until you tap it and save.")
                    .font(.body).foregroundStyle(Zone.muted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                if !session.earlierMeetings.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        let count = session.earlierMeetings.count
                        Text("Zone also hears you in \(count) earlier \(count == 1 ? "meeting" : "meetings") where nobody is marked as you.")
                            .font(.body).foregroundStyle(Zone.ink(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                        if session.markedEarlier {
                            Label("Marked. Tap your name in each to confirm.", systemImage: "checkmark")
                                .font(.footnote.weight(.medium)).labelStyle(ZoneCueLabelStyle(scheme: scheme))
                        } else {
                            Button(count == 1 ? "Mark me in it" : "Mark me in them") { session.markEarlier() }
                                .buttonStyle(ZoneQuietButtonStyle(fullWidth: true))
                        }
                    }
                    .zoneCard()
                }
                Button("Done") { dismiss() }.buttonStyle(ZonePrimaryButtonStyle())
            }
            .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 32)
        }
    }
}

/// One part on the review list: how much was heard, its print, and Record again.
private struct PartRow: View {
    @Environment(\.colorScheme) private var scheme
    let session: VoiceSetupSession
    let part: VoiceSetup.Part

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(VoiceSetup.step(part).title).font(.body.weight(.medium)).foregroundStyle(Zone.ink(scheme))
                Text(detail).font(.footnote).foregroundStyle(failed ? Zone.live : Zone.muted(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if case .failed = session.printStates[part] {
                Button("Retry") { session.retryPrint(part) }.buttonStyle(ZonePillButtonStyle())
            }
            Button(session.finished.contains(part) ? "Redo" : "Record") { session.redo(part) }
                .buttonStyle(ZonePillButtonStyle())
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var failed: Bool {
        if case .failed = session.printStates[part] { return true }
        return session.soundsLikeSomeoneElse.contains(part)
    }

    private var detail: String {
        if session.skipped.contains(part) || !session.finished.contains(part) { return "Skipped" }
        let seconds = "\(Int(session.speech[part, default: 0].rounded())) s of speech"
        switch session.printStates[part] {
        case .ready:
            if session.soundsLikeSomeoneElse.contains(part) {
                return session.soundsLikeSomeoneElse.count > 1
                    ? "These parts sound like different people. Redo them, just you talking."
                    : "This sounds like someone else, or a loud room, so Zone leaves it out. Redo it?"
            }
            return seconds
        case .failed(let reason): return reason
        default: return seconds + ", making its print"
        }
    }
}

/// One part being recorded.
private struct StepScreen: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    let session: VoiceSetupSession
    let part: VoiceSetup.Part

    private var step: VoiceSetup.Step { VoiceSetup.step(part) }
    private var heard: Double { session.speech[part, default: 0] }
    private var isRecording: Bool { session.recorder == .recording }
    private var isFinished: Bool { session.finished.contains(part) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(step.title).font(.zoneTitle).foregroundStyle(Zone.ink(scheme))
                        Text(step.instruction).font(.body).foregroundStyle(Zone.muted(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Label(step.placement, systemImage: placementIcon)
                        .font(.footnote.weight(.medium)).labelStyle(ZoneCueLabelStyle(scheme: scheme))
                        .fixedSize(horizontal: false, vertical: true)
                    if part == .talk {
                        talkPrompt
                    } else if part == .far {
                        Text(VoiceSetup.farPrompt)
                            .font(.title.weight(.semibold))
                            .foregroundStyle(Zone.ink(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .zoneCard()
                    } else {
                        Text(step.script)
                            .font(part == .whisper ? .title3.italic() : .title3)
                            .lineSpacing(6)
                            .foregroundStyle(Zone.ink(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.disabled)
                            .zoneCard()
                    }
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
            }
            controls
        }
    }

    private var placementIcon: String {
        switch part {
        case .far: return "arrow.left.and.right"
        case .whisper: return "mouth"
        default: return "iphone"
        }
    }

    private var talkPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isRecording || heard > 0 ? "Try this" : "If you need a start")
                .font(.zoneEyebrow).foregroundStyle(Zone.muted(scheme))
            Text(VoiceSetup.prompt(after: heard))
                .font(.title2.weight(.medium)).foregroundStyle(Zone.ink(scheme))
                .fixedSize(horizontal: false, vertical: true)
                .id(VoiceSetup.prompt(after: heard))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .animation(.easeOut(duration: 0.35), value: VoiceSetup.prompt(after: heard))
        }
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .zoneCard()
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 14) {
            if let message = session.message {
                Text(message).font(.footnote).foregroundStyle(Zone.live)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            meter
            switch session.recorder {
            case .countdown(let left):
                VStack(spacing: 6) {
                    Text("\(left)").font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Zone.ink(scheme)).contentTransition(.numericText())
                    Text("Put the phone down and step away").font(.footnote).foregroundStyle(Zone.muted(scheme))
                }
                Button("Cancel") { session.cancelCountdown() }.buttonStyle(ZoneQuietButtonStyle(fullWidth: true))
            case .recording:
                Button(heard >= step.minimum ? "Done" : "Listening…") { session.done(part) }
                    .buttonStyle(ZonePrimaryButtonStyle())
                    .accessibilityHint("Ends this part when Zone has heard enough")
            case .idle, .interrupted:
                if isFinished, part == .far {
                    Text("Got it. Pick up your phone.").font(.body.weight(.medium)).foregroundStyle(Zone.ink(scheme))
                    Button("Next") { session.advance(from: part) }.buttonStyle(ZonePrimaryButtonStyle())
                } else {
                    Button(heard > 0 ? "Continue" : (part == .far ? "Start the countdown" : "Start recording")) {
                        session.start(part)
                    }
                    .buttonStyle(ZonePrimaryButtonStyle())
                    if heard >= step.minimum {
                        Button("Use what I recorded") { session.done(part) }.buttonStyle(ZoneLinkButtonStyle())
                    }
                }
            }
            if !isRecording, !isFinished || part != .far {
                HStack(spacing: 24) {
                    if part == .read, heard == 0, session.recorder == .idle {
                        Button("I'd rather just talk") { session.talkInstead() }.buttonStyle(ZoneLinkButtonStyle())
                    }
                    Button(skipLabel) { session.skip(part) }.buttonStyle(ZoneLinkButtonStyle())
                }
            }
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 16)
        .background(Zone.paper(scheme))
    }

    private var skipLabel: String {
        switch part {
        case .read, .talk: return "Skip this part"
        case .whisper: return "Skip whispering"
        case .far: return "Skip, I can't put the phone down"
        }
    }

    private var meter: some View {
        VStack(spacing: 8) {
            SignalLevelMeter(levels: session.recentLevels,
                             color: UIColor(session.hearing ? Zone.accentTone(scheme) : Zone.muted(scheme)), barPitch: 7)
                .frame(height: 40)
                .opacity(isRecording ? 1 : 0.35)
                .accessibilityHidden(true)
            ProgressView(value: session.progress(part))
                .tint(Zone.accentTone(scheme))
                .animation(.easeOut(duration: 0.25), value: session.progress(part))
                .accessibilityLabel("Speech heard")
                .accessibilityValue("\(Int(heard)) of \(Int(step.target)) seconds")
            HStack {
                Text(status).font(.footnote).foregroundStyle(Zone.muted(scheme))
                Spacer()
                Text("\(Int(heard)) of \(Int(step.target)) s").font(.footnote.monospacedDigit()).foregroundStyle(Zone.muted(scheme))
            }
        }
    }

    private var status: String {
        switch session.recorder {
        case .recording:
            if session.hearing { return part == .whisper ? "Hearing your whisper" : "Hearing you" }
            return part == .whisper ? "Whisper a little closer" : "Waiting for you to speak"
        case .interrupted: return "Paused"
        case .countdown: return "Starting"
        case .idle: return isFinished ? "Done" : (heard > 0 ? "Paused" : "Ready")
        }
    }
}
