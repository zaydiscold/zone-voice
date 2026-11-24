// by zayd/cold @ zayd.wtf

import SwiftUI
import ZoneCore

/// Settings > Your data > Delete data: clear what Zone has kept, by age, by dates, or all of it, and start the
/// totals over. Every delete asks once, and says so when a paired computer holds copies too.
struct YourDataView: View {
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
        var deletesLibraryItems: Bool {
            if case .stats = self { return false }
            return true
        }
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
    @State private var isDeleting = false

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
                Button("Reset speaking stats", role: .destructive) { pending = .stats }
                Button("Delete everything", role: .destructive) { pending = .everything }
            } footer: {
                SettingsNote("Delete everything", "My words and settings stay.", detail: "Delete everything clears dictation history, speaking stats, notes, meetings, text saved by earlier versions, clipboard copies, saved audio, recent Messages text and waiting computer sends. Paired Watches clear their notes when they reconnect. Reset speaking stats only clears word count, speaking speed, longest dictation and share totals.")
            }
            .listRowBackground(Zone.card(scheme))

            if let done {
                Text(done).font(.footnote).foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .tint(Zone.inlineInk(scheme))
        .navigationTitle("Delete data")
        .zoneBackButton()
        .zoneScreen()
        .alert(title, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
               presenting: pending) { action in
            Button(confirmLabel(action), role: .destructive) { Task { await perform(action) } }
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
        if action.deletesLibraryItems, meetings.blocksLibraryDeletion { return "Finish the meeting before deleting library items." }
        // These are deletes the person asked for, so a paired computer is told to delete too,
        // unless it keeps what is deleted here.
        let computers = LinkCopy.deleteNote(link?.computers.map(\.name) ?? [], keeping: link?.computers.keepingNames ?? [])
        switch action {
        case .olderThan, .range:
            return ["Deletes dictation history, notes, and meetings from that period. Speaking stats are kept.", computers].compactMap { $0 }.joined(separator: " ")
        case .everything:
            let clips = link?.clips ?? []
            let sendNote = LinkClipCopy.deleteEverythingNote(waiting: clips.filter { !$0.isSent }.count,
                                                            delivered: clips.filter { !$0.sentTo.isEmpty }.count)
            return ["Deletes dictation history, speaking stats, notes, meetings, kept copies and saved audio. Zone asks the Watch to clear its notes and the keyboard to clear its recording when it next opens. Voice setup, the recording log, settings and saved diagnostic clips stay.", computers, sendNote].compactMap { $0 }.joined(separator: " ")
        case .stats: return "Resets word count, WPM, longest dictation, and share totals to zero."
        }
    }

    private func perform(_ action: Pending) async {
        guard !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }
        if action.deletesLibraryItems, meetings.blocksLibraryDeletion {
            pending = nil
            done = "Finish the meeting before deleting library items. Nothing was deleted."
            return
        }
        // A recording still being made or recognized keeps its audio out of the wipe, and saving
        // it afterwards would put it back after "Deleted everything."
        if action.deletesLibraryItems, coordinator.activity.isBusy || coordinator.retryingAudioID != nil {
            pending = nil
            done = "Finish the recording before deleting library items. Nothing was deleted."
            return
        }
        if action.deletesLibraryItems,
           let refusal = coordinator.keyboardRecordingRefusal("Finish the keyboard recording before deleting library items.", from: "deleteLibrary") {
            pending = nil
            done = refusal
            return
        }
        var succeeded = true
        switch action {
        case .olderThan(let age):
            succeeded = delete(in: Date.distantPast...Date(timeIntervalSinceNow: -age.rawValue * 86_400))
            done = "Deleted everything older than \(age.label)."
        case .range(let range):
            succeeded = delete(in: range)
            done = "Deleted \(range.lowerBound.formatted(date: .abbreviated, time: .omitted)) to \(range.upperBound.formatted(date: .abbreviated, time: .omitted))."
        case .everything:
            // Also removes the history recovery files a backup would still export.
            let cutoff = Date()
            pending = nil
            let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ZoneContract.appGroup)
            let keyboardRequested = group.map { (try? KeyboardCapture.requestAudioErase(in: $0)) != nil } ?? false
            let historyDeleted = TranscriptHistory.shared?.deleteAllWithRecovery(clearingStats: true) == true
            if historyDeleted { coordinator.didResetStats() }
            let notesDeleted = coordinator.notes.delete(createdIn: Date.distantPast...Date.distantFuture)
            if notesDeleted { coordinator.failedNoteEdits.removeAll() }
            for meeting in meetings.store.all() { meetings.delete(meeting.id) }
            let recordingsDeleted = coordinator.eraseAudioRecovery()
            // Older versions kept saved rewrites in a separate folder.
            let legacyTextDeleted = (try? RetiredCleanup.archive.delete(createdIn: Date.distantPast...Date.distantFuture)) != nil
            // Kept copies are the person's text too.
            let copiesDeleted = ClipboardHistory.shared?.deleteAll() == true
            // Text queued for a paired computer is the person's too: withdrawn so it is never
            // sent. What a computer already received stays there (nothing is sent to take it back).
            let clips = link?.deleteAllClips()
            let messagesCleared = CompanionShareCache.url.map { (try? PhoneNoteBridge.shared.clearMessagesCache(at: $0)) != nil } ?? false
            let localMessages = [messagesCleared ? nil : "Recent words in Messages could not be cleared.",
                            keyboardRequested ? nil : "The keyboard recording could not be cleared. Try again.",
                            recordingsDeleted ? nil : "Some recovery recordings could not be deleted. Try again.",
                            historyDeleted ? nil : "Some dictation history could not be deleted. Try again.",
                            copiesDeleted ? nil : "Saved clipboard copies could not be cleared. Try again.",
                            legacyTextDeleted ? nil : "Some text from an earlier version could not be deleted. Try again.",
                            notesDeleted ? nil : "Some notes could not be deleted. Try again.",
                            (try? meetings.store.backupMeetings().isEmpty) == true ? nil : "Some meetings could not be deleted. Try again.",
                            clips == nil ? "Computer sends could not be checked. Try again." : clips.flatMap(LinkClipCopy.deletedEverything)]
                .compactMap { $0 }
            let watchResult = PhoneNoteBridge.shared.eraseWatchNotes(through: cutoff)
            var messages = localMessages
            if !watchResult.inboxCleared { messages.append("The iPhone could not clear its Watch inbox. Try again.") }
            if notesDeleted {
                do { try coordinator.notes.clearWatchReceipts() }
                catch { messages.append("Watch delivery records could not be cleared. Try again.") }
            }
            succeeded = messages.isEmpty
            if succeeded { messages.append("Cleared the phone library. The keyboard clears its retry recording the next time it opens.") }
            if let status = watchResult.watchStatus { messages.append(status) }
            done = messages.joined(separator: " ")
        case .stats:
            succeeded = await DictationCoordinator.commitHistory { $0.resetStats() }
            if succeeded { coordinator.didResetStats() }
            done = succeeded ? "Stats start again from zero." : "Could not reset stats. Try again."
        }
        if !succeeded, case .range = action { done = "Some items in that range could not be deleted. Try again." }
        if !succeeded, case .olderThan = action { done = "Some older items could not be deleted. Try again." }
        pending = nil
        if succeeded { Haptics.success() }
    }

    private func delete(in range: ClosedRange<Date>) -> Bool {
        let notesDeleted = coordinator.notes.delete(createdIn: range)
        if notesDeleted {
            let remaining = Set(coordinator.notes.notes.map(\.id))
            coordinator.failedNoteEdits = coordinator.failedNoteEdits.filter { remaining.contains($0.key) }
        }
        let historyDeleted = TranscriptHistory.shared?.delete(createdIn: range) == true
        var meetingsDeleted = true
        do {
            for meeting in try meetings.store.backupMeetings() where range.contains(meeting.createdAt) {
                if !meetings.delete(meeting.id) { meetingsDeleted = false }
            }
        } catch { meetingsDeleted = false }
        let legacyTextDeleted = (try? RetiredCleanup.archive.delete(createdIn: range)) != nil
        return notesDeleted && historyDeleted && meetingsDeleted && legacyTextDeleted
    }
}
