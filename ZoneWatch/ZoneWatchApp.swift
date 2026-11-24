// by zayd/cold @ zayd.wtf

import SwiftUI

@main
struct ZoneWatchApp: App {
    @StateObject private var notes = WatchNotesModel()
    var body: some Scene {
        WindowGroup {
            WatchNotesView()
                .environmentObject(notes)
                .tint(Color(hex: notes.accent.darkHex))
        }
    }
}

struct WatchNotesView: View {
    @EnvironmentObject private var model: WatchNotesModel
    @State private var showsComposer = false
    var body: some View {
        NavigationStack {
            List {
                Button { showsComposer = true } label: {
                    Label("New note", systemImage: "mic.fill")
                }
                .disabled(!model.canSave)
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.orange) }
                if model.notes.isEmpty {
                    Text("Dictate or type a note. Saved locally on Watch first, then synced to your iPhone.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(model.notes) { saved in
                    NavigationLink {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(saved.note.text).frame(maxWidth: .infinity, alignment: .leading)
                                Text(model.status(saved)).font(.footnote).foregroundStyle(.secondary)
                                if saved.delivery != .receivedOnPhone {
                                    Button("Retry iPhone transfer") { model.retry(saved.id) }
                                }
                            }
                        }.navigationTitle("Note")
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(saved.note.text).lineLimit(3)
                            Text(model.status(saved)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Zone")
            .sheet(isPresented: $showsComposer) { WatchNoteComposer() }
        }
    }
}

private struct WatchNoteComposer: View {
    @EnvironmentObject private var model: WatchNotesModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    var body: some View {
        NavigationStack {
            Form {
                TextField("Dictate or type", text: $draft)
                    .accessibilityIdentifier("watchNoteText")
                Button("Save note") {
                    if model.save(draft) { dismiss() }
                }
                .accessibilityIdentifier("saveWatchNote")
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.orange) }
                Text("Uses the Watch's system text input. Your saved notes remain here when your iPhone is away.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.navigationTitle("New note")
        }
    }
}
