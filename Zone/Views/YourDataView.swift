// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// Settings > Your data: clear what Zone has kept, by age, by dates, or all of it, and start the
/// totals over. Every delete asks once, and says so when a paired computer holds copies too.
struct YourDataView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DictationCoordinator.self) private var coordinator
    @Environment(MeetingCoordinator.self) private var meetings
    @Environment(LinkCoordinator.self) private var link: LinkCoordinator?
    @Environment(\.colorScheme) private var scheme

    enum Age: Double, CaseIterable, Identifiable {
        case week = 7, month = 30, quarter = 90, year = 365
        var id: Double { rawValue }
        var label: String {
            switch self {
            case .week: return "1 week"
            case .month: return "1 month"
            case .quarter: return "3 months"
            case .year: return "1 year"
            }
        }
    }

    private enum Pending: Identifiable {
        case olderThan(Age), range(ClosedRange<Date>), everything, stats
        var id: String {
            switch self {
            case .olderThan(let age): return "age\(age.rawValue)"
            case .range: return "range"
            case .everything: return "everything"
            case .stats: return "stats"
            }
        }
    }

    @State private var age: Age = .month
    @State private var from = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var to = Date()
    @State private var pending: Pending?
    @State private var done: String?

    var body: some View {
        Form {
            Section {
                Picker("Older than", selection: $age) {
                    ForEach(Age.allCases) { Text($0.label).tag($0) }
                }
                Button("Delete older than \(age.label)", role: .destructive) { pending = .olderThan(age) }
            } header: {
                Text("By age")
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                DatePicker("From", selection: $from, in: ...to, displayedComponents: .date)
                DatePicker("To", selection: $to, in: from..., displayedComponents: .date)
                Button("Delete this range", role: .destructive) { pending = .range(dayRange) }
            } header: {
                Text("By dates")
            }
            .listRowBackground(Zone.card(scheme))

            Section {
                Button("Reset words and stats", role: .destructive) { pending = .stats }
                Button("Delete everything", role: .destructive) { pending = .everything }
            } footer: {
                Text("Clears dictation history, notes, meetings, cleanups, and saved audio. My words and settings are kept.")
            }
            .listRowBackground(Zone.card(scheme))

            if let done {
                Text(done).font(.footnote).foregroundStyle(Zone.muted(scheme))
                    .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .tint(Zone.accentGraphic)
        .navigationTitle("Delete data")
        .zoneBackButton()
        .zoneScreen()
        .alert(title, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
               presenting: pending) { action in
            Button(confirmLabel(action), role: .destructive) { perform(action) }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { action in
            Text(message(action))
        }
    }

    /// Whole days: from the start of the first to the end of the last.
    private var dayRange: ClosedRange<Date> {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: from)
        let end = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: calendar.startOfDay(for: to)) ?? to
        return start...max(start, end)
    }

    private var title: String { "This can't be undone" }

    private func confirmLabel(_ action: Pending) -> String {
        switch action {
        case .olderThan(let age): return "Delete older than \(age.label)"
        case .range: return "Delete this range"
        case .everything: return "Delete everything"
        case .stats: return "Reset stats"
        }
    }

    private func message(_ action: Pending) -> String {
        // These are deletes the person asked for, so a paired computer is told to delete too,
        // unless it keeps what is deleted here.
        let computers = LinkCopy.deleteNote(link?.computers.map(\.name) ?? [], keeping: link?.computers.keepingNames ?? [])
        switch action {
        case .olderThan, .range:
            return ["Deletes dictation history, notes, meetings, and cleanups from that period.", computers].compactMap { $0 }.joined(separator: " ")
        case .everything:
            return ["Deletes all dictation history, notes, meetings, cleanups, and saved audio.", computers].compactMap { $0 }.joined(separator: " ")
        case .stats: return "Resets word count, WPM, and share totals to zero."
        }
    }

    private func perform(_ action: Pending) {
        switch action {
        case .olderThan(let age):
            delete(in: Date.distantPast...Date(timeIntervalSinceNow: -age.rawValue * 86_400))
            done = "Deleted everything older than \(age.label)."
        case .range(let range):
            delete(in: range)
            done = "Deleted \(range.lowerBound.formatted(date: .abbreviated, time: .omitted)) to \(range.upperBound.formatted(date: .abbreviated, time: .omitted))."
        case .everything:
            TranscriptHistory.shared?.deleteAll()
            coordinator.notes.delete(createdIn: Date.distantPast...Date.distantFuture)
            for meeting in meetings.store.all() { meetings.delete(meeting.id) }
            for record in coordinator.audioRecoveryRecords { coordinator.deleteAudioRecovery(record.id) }
            // Cleanup keeps each original and its cleaned text in its own folder; "everything" means those too.
            _ = try? CleanupEngine.archive.delete(createdIn: Date.distantPast...Date.distantFuture)
            done = "Deleted everything."
        case .stats:
            settings.resetStats()
            done = "Stats start again from zero."
        }
        pending = nil
        Haptics.success()
    }

    private func delete(in range: ClosedRange<Date>) {
        TranscriptHistory.shared?.delete(createdIn: range)
        coordinator.notes.delete(createdIn: range)
        for meeting in meetings.store.all() where range.contains(meeting.createdAt) { meetings.delete(meeting.id) }
        _ = try? CleanupEngine.archive.delete(createdIn: range)
    }
}
