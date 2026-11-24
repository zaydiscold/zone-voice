// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// The recording log (`RecordingJournal`) as a timeline per recording: when it started, every
/// time a call or alarm paused it and how long until it resumed, who stopped it, how long the
/// words took and where they were saved. No words are in it. Share exports the raw lines.
struct RecordingLogView: View {
    @Environment(\.colorScheme) private var scheme
    @State private var groups: [Group] = []
    @State private var loose: [JournalEvent] = []
    @State private var exportURL: URL?
    @State private var expanded: Set<String> = []

    struct Group: Identifiable {
        let id: String
        let events: [JournalEvent]
        var start: Date { events.first?.date ?? .distantPast }
    }

    var body: some View {
        List {
            if groups.isEmpty && loose.isEmpty {
                Text("No recordings logged yet. Timings and mic events appear here without saving any spoken words.")
                    .foregroundStyle(.secondary)
                    .listRowBackground(Zone.card(scheme))
            }
            ForEach(groups) { group in
                Section {
                    Button {
                        if !expanded.insert(group.id).inserted { expanded.remove(group.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.start.formatted(date: .abbreviated, time: .standard)).font(.headline)
                            Text(Self.summary(group.events)).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if expanded.contains(group.id) {
                        ForEach(Array(group.events.enumerated()), id: \.offset) { _, event in
                            EventRow(event: event)
                        }
                    }
                } header: {
                    Text(group.id)
                }
                .listRowBackground(Zone.card(scheme))
            }
            if !loose.isEmpty {
                Section("App and microphone") {
                    ForEach(Array(loose.suffix(60).reversed().enumerated()), id: \.offset) { _, event in
                        EventRow(event: event)
                    }
                }
                .listRowBackground(Zone.card(scheme))
            }
        }
        .scrollContentBackground(.hidden)
        .zoneScreen()
        .navigationTitle("Recording log")
        .zoneBackButton()
        .toolbar {
            if let exportURL {
                ShareLink(item: exportURL) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Share the recording log")
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        let (events, url) = await Task.detached(priority: .utility) { () -> ([JournalEvent], URL?) in
            guard let journal = Journal.app else { return ([], nil) }
            let events = journal.events()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("zone-recording-log.jsonl")
            return (events, (try? journal.exportFile(to: url)) == nil ? nil : url)
        }.value
        var byRecording: [String: [JournalEvent]] = [:]
        var other: [JournalEvent] = []
        for event in events {
            if let id = event.r { byRecording[id, default: []].append(event) } else { other.append(event) }
        }
        groups = byRecording.map { Group(id: $0.key, events: $0.value) }.sorted { $0.start > $1.start }
        loose = other
        exportURL = url
    }

    /// One line: how it started, how many holds, how it ended.
    static func summary(_ events: [JournalEvent]) -> String {
        var parts: [String] = []
        if let start = events.first(where: { $0.name == "recordingStarted" }) {
            parts.append("from \(start.f["origin"] ?? "?")")
        }
        let holds = events.filter { $0.name == "recordingHeld" }.count
        if holds > 0 {
            let resumes = events.filter { $0.name == "recordingResumed" }.count
            parts.append("paused \(holds)× by a call or alarm, resumed \(resumes)×")
        }
        if let stop = events.last(where: { $0.name == "recordingStopping" }) {
            parts.append("stopped: \(stop.f["reason"] ?? "?")")
        } else if let retired = events.last(where: { $0.name == "recordingRetired" }) {
            parts.append("ended by a new dictation")
            if retired.f["complete"] == "false" { parts.append("audio kept to transcribe again") }
        } else if events.contains(where: { $0.name == "recordingCancelled" }) {
            parts.append("cancelled")
        } else if events.contains(where: { $0.name == "recordingAbandoned" }) {
            parts.append("Zone closed during it")
        }
        if let done = events.last(where: { $0.name == "recordingTranscribed" }) {
            parts.append("\(done.f["audio"] ?? "?") s, \(done.f["words"] ?? "?") words")
        }
        if events.contains(where: { $0.name == "recordingFailed" }) { parts.append("failed") }
        return parts.isEmpty ? "\(events.count) lines" : parts.joined(separator: " · ")
    }
}

private struct EventRow: View {
    let event: JournalEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(event.date.formatted(date: .omitted, time: .standard)).font(.caption.monospacedDigit())
                Text(Self.title(event.name)).font(.subheadline)
                Spacer(minLength: 0)
                Text(event.p).font(.caption2).foregroundStyle(.secondary)
            }
            if !event.f.isEmpty {
                Text(event.f.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func title(_ name: String) -> String {
        switch name {
        case "recordingStarted": "Started"
        case "recordingProgress": "Still recording"
        case "recordingHeld": "Paused by a call or alarm"
        case "recordingHoldSaved": "Words so far saved"
        case "recordingResumed": "Resumed"
        case "recordingResumeFailed": "Could not resume"
        case "recordingStopping": "Stopped"
        case "recordingTranscribed": "Recognized"
        case "recordingSaved": "Saved"
        case "recordingFailed": "Failed"
        case "recordingCancelled": "Cancelled"
        case "recordingRetired": "Ended by a new dictation"
        case "recordingAbandoned": "Zone was closed during it"
        case "interruptionBegan": "iOS took the microphone"
        case "interruptionEnded": "iOS gave the microphone back"
        case "interruptionDecision": "Decision"
        case "inputStalled": "No audio coming in"
        case "inputRecovered": "Audio back"
        case "standbyInterrupted": "Standby paused"
        case "standbyResumed": "Standby back"
        case "standbyEndedByClearedCard": "Zone turned off: its card was cleared"
        case "clearedCardNotice": "Said Zone is off"
        case "pressArmRetried": "Press tried the microphone again"
        case "appLaunch": "Zone started"
        case "appForeground": "Zone opened"
        case "appBackground": "Zone in the background"
        case "keyboardRequest": "Keyboard asked to record"
        case "keyboardSawStatus": "Keyboard saw"
        case "keyboardResult": "Keyboard got the words"
        case "keyboardDroppedWrite": "Keyboard ignored a key"
        case "keyboardVisit": "Keyboard shown"
        case "keyboardOpenSkipped": "Keyboard did not open Zone twice"
        default: name
        }
    }
}
