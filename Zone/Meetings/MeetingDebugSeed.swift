// by zayd/cold @ zayd.wtf

#if DEBUG
import Foundation
import ZoneCore

/// `-zoneMeetingSeedMerged <open|matched|unlisted>` (Debug builds): a meeting made by merging two
/// recordings of the same two people, for the Speakers screen and its UI tests. The audio is two
/// tones, one per person, so the play buttons have something to play; the voice prints are made
/// up. `open`: the later recording's voices are close to the earlier ones but not close enough to
/// join, so the screen offers "Sounds like"; `matched`: they joined at the merge; `unlisted`: no
/// prints at all, as recordings labeled before 1.0.5 have, so the app listens to them itself when
/// the speaker model is on the simulator. An earlier meeting names someone Riju, which the
/// Speakers screen offers as a name. Seeded meetings from an earlier launch are replaced.
enum MeetingDebugSeed {
    static let mergedTitle = "Catch-up with Riju"
    static let earlierTitle = "Planning with Riju"

    static func runIfAsked(_ store: MeetingStore) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-zoneMeetingSeedMerged"), index + 1 < arguments.count else { return }
        let mode = arguments[index + 1]
        let defaults = UserDefaults.standard
        let key = "zone.debug.meetingFixtureIDs"
        for id in defaults.stringArray(forKey: key) ?? [] {
            if let id = UUID(uuidString: id) { try? store.delete(id) }
        }
        do {
            let day = Date().addingTimeInterval(-86_400)
            let similar: Float = ["matched", "separate"].contains(mode) ? 0.3 : 1.333
            func print(_ axis: Int, lean: Float = 0) -> [Float]? {
                guard mode != "unlisted" else { return nil }
                var voice = [Float](repeating: 0, count: 256)
                voice[axis] = 1
                voice[200 + axis] = lean
                return voice
            }
            let earlier = try record(store, title: earlierTitle, at: day.addingTimeInterval(-7 * 86_400), first: 0, lines: [
                "Thanks for making time. I wanted to plan the next two weeks before the build goes out.",
                "Sure. I have the list from last time, so let's go through it in order.",
            ], voices: [print(0), print(1)])
            try store.renameSpeaker(earlier.id, speaker: "S2", to: "Riju")
            let title = defaults.string(forKey: "zoneDebugMeetingTitle") ?? mergedTitle
            let first = try record(store, title: title, at: day, first: 0, lines: [
                "So the plan is to ship the keyboard update on Friday if the batch passes.",
                "That works. I can have the review notes ready by Thursday night.",
                "Good. What about the speaker labels, are they holding up in long meetings?",
                "Mostly. Two recordings merged into one still number the same people twice.",
            ], voices: [print(0), print(1)])
            // The second recording's speaker model heard Riju first, so its numbers are swapped.
            let secondTitle = defaults.string(forKey: "zoneDebugSecondMeetingTitle") ?? "Second half (sample)"
            let second = try record(store, title: secondTitle, at: day.addingTimeInterval(1_500), first: 1, lines: [
                "Sorry about that, the call dropped on my side. Where were we?",
                "Speaker labels after a merge. I want the same person to stay one speaker.",
                "Agreed. Matching the voices should not need the whole transcript again.",
                "Right. And if it guesses wrong I want to fix it in a couple of taps.",
            ], voices: [print(1, lean: similar), print(0, lean: similar)])
            defaults.set([earlier, first, second].map { $0.id.uuidString }, forKey: key)
            if mode != "separate", mode != "review" { _ = try store.merge(first.id, second.id) }
        } catch {
            ZoneLog.coordinator.error("meeting seed failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One finished recording: `lines` alternate between two people, six seconds each, starting
    /// with person `first` (0 or 1). S1 is whoever speaks first.
    private static func record(_ store: MeetingStore, title: String, at date: Date, first: Int, lines: [String],
                               voices: [[Float]?]) throws -> Meeting {
        let (meeting, writer) = try store.beginRecording(title: title, now: date)
        let lineSeconds = 6.0
        for (index, _) in lines.enumerated() {
            let person = (first + index) % 2
            let pitch = person == 0 ? 150.0 : 235.0
            for second in 0..<Int(lineSeconds) {
                let samples = (0..<16_000).map { sample -> Float in
                    let time = Double(second * 16_000 + sample) / 16_000
                    // A buzz with a slow swell, quiet at the edges of the line so cuts do not click.
                    let swell = sin(.pi * time / lineSeconds)
                    return Float(0.12 * swell * (sin(2 * .pi * pitch * time) + 0.4 * sin(2 * .pi * pitch * 2 * time)))
                }
                writer.append(samples)
            }
        }
        let done = DispatchSemaphore(value: 0)
        Task.detached { try? await writer.finish(); done.signal() }
        done.wait()
        try store.finishRecording(meeting.id, now: date)
        return try store.update(meeting.id, now: date) { meeting in
            meeting.speakers = [MeetingSpeaker(id: "S1", voice: voices[0]), MeetingSpeaker(id: "S2", voice: voices[1])]
            meeting.segments = lines.enumerated().map { index, text in
                MeetingSegment(start: Double(index) * lineSeconds + 0.3, end: Double(index + 1) * lineSeconds - 0.3,
                               speaker: "S\(index % 2 + 1)", text: text)
            }
            meeting.transcribedThrough = meeting.duration
            meeting.progress = 1
            meeting.status = .done
            meeting.engine = "sample"
            meeting.diarizer = "sample"
        }
    }
}
#endif
