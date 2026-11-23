// by zayd/cold @ zayd.wtf

#if DEBUG
import Foundation
import UIKit
import ZoneCore

/// Development builds only: drive Zone Link without a camera or a real library.
///
/// - `-zoneLinkSeed 200` fills the library with 200 synthetic dictations, 20 notes and one
///   meeting. The ids are fixed, so running it again adds only what a larger number adds.
/// - `-zoneLinkPair "zone://pair?..."` offers that link exactly as a scanned code would be
///   offered, so the same question appears.
/// - `-zoneLinkAutoConfirm` answers that question with Send, for unattended runs.
/// - `-zoneLinkFlash` opens Send by Flash for the first paired computer. When none is paired
///   yet it waits up to a minute for one, so it follows a pairing question answered by hand.
/// - `-zoneLinkFlashStart` skips the Flash guide and shows the codes as soon as they are ready.
/// - `-zoneLinkFlashEverything` opens Flash on Everything instead of Not sent yet.
/// - `-zoneLinkFlashChunk N` and `-zoneLinkFlashRate N` make the frames N bytes, or show N
///   pictures a second, for measuring other sizes (read in `LinkCoordinator.flashPlan`).
/// - `-zoneLinkFlashPieces N` lets one flash carry at most N pieces, so a small library is sent
///   as several flashes, the way a library too large for `LinkFlashFormat.planChunks` is.
/// - `-zoneLinkFlashScene dusk` (or `aurora`, `ember`) keeps the color Flash in that scene, and
///   `-zoneLinkFlashDoneAfter N` taps Done N seconds after the codes start: for recordings.
/// - `-zoneLinkFlashChangeAfter N` transcribes a dictation the flash carries again N seconds
///   after the codes start, as a retried dictation or a Watch recording landing would change
///   the library while the codes show (`transcribeAgain`).
/// - `-zoneLinkClip "text"` sends that text as a clip once a computer is paired, exactly as the
///   Send button does. `-zoneLinkClipSheet` opens Send text on the Computers screen.
///   `-zoneLinkClipShortcut "text"` performs the Send to Computer intent with that text, as a
///   shortcut does (the simulator has no Shortcuts app), and prints what it would have said.
/// - `-zoneLinkRestoreNotes N` adds N notes with new ids, dated before everything in the
///   library, through the import a backup restore uses (which keeps their times): what restoring
///   an old backup part-way through an Everything round adds (`restoreOlderNotes`).
/// - `-zoneLinkComputers` shows Settings > Computers on its own, once a computer is paired.
/// - `-zoneLinkForgetAll` forgets every paired computer first, so a run starts from nothing.
enum LinkDebug {
    @MainActor
    static func runIfRequested(link: LinkCoordinator, notes: NotesStore, meetings: MeetingCoordinator) async {
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        if arguments.contains("-zoneLinkForgetAll") {
            for computer in link.computers { link.forget(computer.endpointID) }
        }
        if let count = value("-zoneLinkSeed").flatMap({ Int($0) }), count > 0 {
            await seed(count, notes: notes, meetings: meetings)
        }
        if let count = value("-zoneLinkRestoreNotes").flatMap({ Int($0) }), count > 0 {
            await restoreOlderNotes(count, notes: notes)
        }
        if let text = value("-zoneLinkPair") {
            link.offerPairing(text)
            if arguments.contains("-zoneLinkAutoConfirm") { link.confirmPairing() }
        }
        if let text = value("-zoneLinkClip") {
            // After the pairing question is answered; the clip then goes in a sync of its own.
            for _ in 0..<240 where link.computers.isEmpty || link.pendingPairing != nil {
                try? await Task.sleep(for: .milliseconds(250))
            }
            do {
                let clip = try link.sendClip(text, source: .typed)
                let settled = await link.clipSettled(clip.id, within: 60)
                print("zoneLinkClip: \(settled.map { LinkClipCopy.outcome($0, names: link.computerNames) } ?? "removed")")
            } catch {
                print("zoneLinkClip: \((error as? LinkClipFailure)?.plainMessage ?? "\(error)")")
            }
        }
        if let text = value("-zoneLinkClipShortcut") {
            for _ in 0..<240 where link.computers.isEmpty || link.pendingPairing != nil {
                try? await Task.sleep(for: .milliseconds(250))
            }
            do {
                print("zoneLinkClipShortcut: \(try await SendToComputerIntent.send(text))")
            } catch {
                print("zoneLinkClipShortcut: \(error.localizedDescription)")
            }
        }
        if arguments.contains("-zoneLinkComputers") {
            // After pairing and its first sync, whose one-line notice would take the screen's place.
            for _ in 0..<240 where link.computers.isEmpty || link.pendingPairing != nil || !link.syncing.isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
            }
            link.notice = nil
            try? await Task.sleep(for: .milliseconds(400))
            // A sheet that asks while another is up never appears, so wait for the screen to be free.
            for _ in 0..<80 where UIApplication.shared.showsPresentation {
                try? await Task.sleep(for: .milliseconds(250))
            }
            link.debugShowsComputers = true
        }
        if arguments.contains("-zoneLinkFlash") {
            for _ in 0..<240 where link.computers.isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
            }
            if let computer = link.computers.first { link.flashTarget = computer }
        }
    }

    /// The first dictation in `items` gets new words, the way a retried dictation would.
    static func transcribeAgain(_ items: [LinkItem]) {
        guard let id = items.first(where: { $0.kind == .dictation && !$0.deleted }).flatMap({ UUID(uuidString: $0.id) }) else { return }
        Task.detached(priority: .userInitiated) {
            guard let history = TranscriptHistory.shared, let record = history.record(id: id) else { return }
            history.finish(id: id, text: record.text + " Transcribed again.", audioSeconds: record.audioSeconds,
                           status: record.status, engine: record.engine, source: record.source)
            print("zoneLinkFlashChangeAfter: transcribed \(id.uuidString) again")
        }
    }

    private static let sentences = [
        "Can you send me the draft before lunch",
        "Running ten minutes late, start without me",
        "Remind me to call the dentist on Thursday",
        "The build passed, shipping it this afternoon",
        "Let us move the review to next week",
        "Pick up oat milk and coffee on the way home",
        "That sounds good, see you at seven",
        "I think the second option is the better one",
    ]

    private static func id(_ kind: Int, _ number: Int) -> UUID {
        UUID(uuidString: String(format: "5EED0000-0000-4000-80%02d-%012d", kind, number))!
    }

    /// Notes no earlier run added (new ids each time), a day older than the oldest item in the
    /// library, put in through the same import a backup restore uses, which keeps their times.
    /// They sort before wherever an Everything round goes on from, as a restored backup's do.
    @MainActor
    private static func restoreOlderNotes(_ count: Int, notes: NotesStore) async {
        let oldest = await Task.detached(priority: .utility) {
            LinkLibrary.read().map { min($0.createdAt ?? $0.updatedAt, $0.updatedAt) }.min()
        }.value
        let before = Date(timeIntervalSince1970: (oldest ?? Date().timeIntervalSince1970) - 86_400)
        let restored = (0..<count).map { index in
            LibraryNote(id: UUID(), text: "Restored note \(index + 1). \(sentences[index % sentences.count]).",
                        createdAt: before.addingTimeInterval(-Double(index) * 60))
        }
        let added = (try? notes.importBackup(restored)) ?? 0
        print("zoneLinkRestoreNotes: added \(added) notes dated \(before) and earlier")
    }

    @MainActor
    private static func seed(_ count: Int, notes: NotesStore, meetings: MeetingCoordinator) async {
        let now = Date()
        // Spread over the last two weeks, inside the default 30 days of history.
        let spacing = min(600, 14 * 86_400 / Double(count))
        await Task.detached(priority: .utility) {
            guard let history = TranscriptHistory.shared else { return }
            let existing = Set(history.records().map(\.id))
            for index in (0..<count).reversed() where !existing.contains(id(1, index)) {
                let date = now.addingTimeInterval(-Double(index + 1) * spacing)
                history.finish(id: id(1, index), text: "\(sentences[index % sentences.count]). Sample \(index + 1).",
                               audioSeconds: 2 + Double(index % 7), status: index % 3 == 0 ? .finished : .inserted,
                               engine: "fluidMini", source: index % 4 == 0 ? .app : .keyboard, now: date)
            }
        }.value

        let samples = (0..<max(1, count / 10)).map { index in
            LibraryNote(id: id(2, index), text: "Sample note \(index + 1). \(sentences[(index + 3) % sentences.count]).",
                        createdAt: now.addingTimeInterval(-Double(index + 1) * 3_600))
        }
        _ = try? notes.importBackup(samples)

        let store = meetings.store
        let title = "Zone Link sample meeting"
        await Task.detached(priority: .utility) {
            guard !store.all().contains(where: { $0.title == title }) else { return }
            guard let (meeting, _) = try? store.beginRecording(title: title, now: now.addingTimeInterval(-7_200)) else { return }
            // One minute of silence, so the meeting has a length like a real one.
            if let part = store.audioURLs(meeting).first { try? Data(count: 16_000 * 2 * 60).write(to: part) }
            _ = try? store.finishRecording(meeting.id)
            _ = try? store.update(meeting.id) { meeting in
                meeting.speakers = [MeetingSpeaker(id: "S1", name: "Dana"), MeetingSpeaker(id: "S2", isMe: true)]
                meeting.segments = [
                    MeetingSegment(start: 0, end: 8, speaker: "S1", text: "Thanks for joining. Let us go through the launch plan."),
                    MeetingSegment(start: 8, end: 19, speaker: "S2", text: "The build is ready. I want one more day of testing."),
                    MeetingSegment(start: 19, end: 31, speaker: "S1", text: "That works. We ship on Friday then."),
                    MeetingSegment(start: 31, end: 40, speaker: "S2", text: "Agreed. I will write up the notes."),
                ]
                meeting.transcribedThrough = meeting.duration
                meeting.progress = 1
                meeting.engine = "fluidMini"
                meeting.status = .done
            }
        }.value
        await meetings.reload()
    }
}
#endif
