// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

struct MeetingTranscriptEditor: View {
    @Environment(MeetingCoordinator.self) private var meetings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    let meeting: Meeting
    @State private var texts: [String]
    @State private var error: String?

    init(meeting: Meeting) {
        self.meeting = meeting
        _texts = State(initialValue: meeting.segments.map(\.text))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(texts.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 8) {
                            let segment = meeting.segments[index]
                            Text([meeting.speakerName(segment.speaker), MeetingExport.timestamp(segment.start)].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(Zone.muted(scheme))
                            TextField("Transcript", text: $texts[index], axis: .vertical)
                                .font(.body).foregroundStyle(Zone.ink(scheme))
                                .lineLimit(2...)
                                .accessibilityLabel("Transcript at \(MeetingExport.timestamp(segment.start))")
                            Hairline()
                        }
                    }
                }.padding(20)
            }
            .navigationTitle("Edit transcript")
            .zoneBackButton()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ZoneBarItem(.cancellationAction) { Button("Cancel") { dismiss() } }
                ZoneBarItem(.confirmationAction, prominent: true) {
                    Button("Save") {
                        do {
                            try meetings.editTranscript(meeting.id, original: meeting.segments, texts: texts)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
            .zoneScreen()
            .alert("Transcript was not saved", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }
}
