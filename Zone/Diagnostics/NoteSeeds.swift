// by zayd/cold @ zayd.wtf

#if DEBUG
import Foundation
import AVFoundation
import ZoneCore

/// Development builds only: `-zoneNotesSeed 50` adds up to 50 made-up notes that read like real
/// ones (a few words to a few hundred, said over the last year), so the Notes list, its search
/// and the read page can be looked at and tested with something to skim. The ids are fixed, so
/// running it again adds nothing. `NotesReadingUITests` and the design screenshots use it.
/// `-zoneNotesAdd "One|Two"` adds those as new notes, the first the newest, every launch: notes a
/// test may edit and delete without changing the seeded ones.
enum NoteSeeds {
    @MainActor
    static func runIfRequested(notes: NotesStore) {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-zoneLongReaderSeed"), arguments.indices.contains(index + 1) {
            // Multiline launch arguments can be split by the simulator runner.
            let heading = arguments[index + 1]
            let body = Array(repeating: "we saw the sun", count: 749).joined(separator: " ")
            notes.add(heading + "\n" + body + "\nBlue lantern")
        }
        if let index = arguments.firstIndex(of: "-zoneNotesAdd"), index + 1 < arguments.count {
            for text in arguments[index + 1].split(separator: "|").reversed() { notes.add(String(text)) }
        }
        guard let index = arguments.firstIndex(of: "-zoneNotesSeed"), index + 1 < arguments.count,
              let count = Int(arguments[index + 1]), count > 0 else { return }
        let added = (try? notes.importBackup(samples(count, now: Date()))) ?? 0
        print("zoneNotesSeed: added \(added) notes")
    }

    #if targetEnvironment(simulator)
    static func recoveryPair(in store: AudioRecoveryStore) async throws {
        guard let url = Bundle.main.url(forResource: "test-clip", withExtension: "wav") else {
            throw AudioRecoveryError.missingAudio
        }
        for (index, silent) in [true, false].enumerated() {
            let id = UUID(uuidString: "5EED0000-0000-4000-8005-00000000000" + String(index))!
            try store.discard(id)
            let writer = try store.begin(id: id, engine: "fixture", source: .app, attempting: silent)
            if silent {
                writer.append(Array(repeating: 0, count: 16_000))
            } else {
                let file = try AVAudioFile(forReading: url)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else {
                    throw AudioRecoveryError.missingAudio
                }
                while file.framePosition < file.length {
                    try file.read(into: buffer)
                    guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { break }
                    writer.append(Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
                }
            }
            try await writer.finish()
            if silent {
                for attempt in 1...2 {
                    if attempt == 2 { _ = try store.beginRetry(id) }
                    do { try store.complete(id, text: "") } catch AudioRecoveryError.emptyTranscript {}
                }
            } else {
                try store.markFailed(id, text: "", message: "Audio saved before transcription.", outcome: .interrupted)
            }
        }
    }
    #endif

    static func samples(_ count: Int, now: Date) -> [LibraryNote] {
        // Hours ago for each note: several today and yesterday, then thinning out over a year.
        texts.prefix(count).enumerated().map { index, text in
            let hours: Double
            switch index {
            case 0..<5: hours = 0.4 + Double(index) * 1.3
            case 5..<9: hours = 24 + Double(index - 5) * 2.5
            case 9..<16: hours = 48 + Double(index - 9) * 17
            case 16..<28: hours = 8 * 24 + Double(index - 16) * 41
            case 28..<40: hours = 32 * 24 + Double(index - 28) * 9.3 * 24
            default: hours = 150 * 24 + Double(index - 40) * 23.7 * 24
            }
            return LibraryNote(id: UUID(uuidString: String(format: "5EED0000-0000-4000-8003-%012d", index))!, text: text,
                               createdAt: now.addingTimeInterval(-hours * 3_600),
                               editedAt: index % 11 == 3 ? now.addingTimeInterval(-hours * 3_600 + 1_500) : nil)
        }
    }

    static let texts: [String] = [
        "Trip planning for March. Okay so I want to book the cabin early because last year it filled up by January, and we should ask Priya whether her brother can lend us the roof box again. I think four nights is right, Thursday to Monday, so nobody has to take more than two days off. Also remind me to renew my passport, it runs out in the spring and I do not want to find that out at the airport. The dentist said to come back before then for the second filling, so that has to fit in before we leave. For food, last time we brought way too much, so one big shop on the way up and that is it. Snow chains. Do not forget the snow chains this time, we got lucky last year. And check whether the cabin has a kettle, because the one two years ago did not, and mornings without tea were grim.",
        "Pick up oat milk and the good coffee on the way home",
        "Idea for the onboarding. What if the first screen just asks you to say something, anything, and it types it back, before any of the permissions talk. People get it in three seconds that way. Then the keyboard step makes sense because they already saw it work. Worth trying on Dana next week.",
        "Call the landlord about the leak in the kitchen ceiling, he said Thursday works but I need to confirm the time, and ask whether the plumber is coming before or after noon because I have the dentist at three and cannot move it again",
        "Parking level three, row G, near the stairs",
        "Thoughts after the call with Kowalski. He is not against the pricing, he is against being surprised by it, which is a different problem. He kept coming back to the invoice from September where the overage showed up with no warning. So the fix is not a discount, it is a heads up at eighty percent and a number he can forward to finance without a meeting. He also asked twice about export, so that is clearly a worry on their side, probably someone above him wants to know they can leave. I said we would send the export format this week. I should actually do that tomorrow morning before it slides. Also he mentioned in passing that their team in Lisbon uses it the most, which I did not know, and that they want Portuguese. Park that, but write it down. Overall I think the renewal is fine if the next invoice has no surprises in it.",
        "Did the plumber call back? If not, try the other number on the fridge.",
        "Book for Sam's birthday, the one about the lighthouse keepers, the bookshop on the corner had it in the window",
        "Gym. Squats felt better with the wider stance. Keep the weight the same next week and add one set.",
        "Remember to move the car before eight tomorrow, street cleaning on the north side",
        "Deploy checklist. Run the migration on staging first, then check the two dashboards, then Vercel, and only then tell support. Last time we told support first and the migration took forty minutes.",
        "Gift ideas for mom. The blue scarf she pointed at in the market, or a class at the pottery place, she has been talking about it since the summer. Ask Leila which one, she will know.",
        "Recipe from Aunt Rosa, the lentil soup. Onion, two carrots, celery, all chopped small and cooked slow in olive oil for longer than you think, at least fifteen minutes. Then cumin, a little smoked paprika, garlic at the end so it does not burn. Red lentils, a cup and a half, rinsed. Water, not stock, she was firm about that, and a bay leaf. Twenty five minutes. Lemon at the very end, more than seems reasonable, and salt after the lemon not before. She says the mistake everyone makes is rushing the onions. Serve with the flatbread from the place on Alder Street if they have it.",
        "Wifi at the cabin is cedar underscore guest, password is on the fridge",
        "Tell Marcus the Thursday review moves to two thirty",
        "Podcast idea, short episodes, under ten minutes, each one is one thing I got wrong this year and what I do now instead",
        "Dentist follow up is on the nineteenth at three. Ask about the night guard and whether insurance covers it this year.",
        "Things the mechanic said. Front brake pads have maybe three months left. The noise when turning is the left wheel bearing, not urgent but it will get louder. Tires are fine until next winter. He would do the bearing and the pads together to save on labor, about four hundred all in. Book it for after the trip, not before.",
        "Water the plants at Nora's on Wednesday and Saturday, the fern gets the most, the cactus gets nothing",
        "Standup notes. Search is done on the phone side and waiting on review. The read page needs one more pass at the largest text size. Nothing blocked. Ask about the simulator pool, it was full again this morning.",
        "Return the drill to Theo",
        "Flight is the seven forty out of terminal two, seat twenty three A, leave the house by five fifteen",
        "Sentence for the talk. The best interface for a thought is the one that is already open when you have it.",
        "Ask the vet about the limp, it is the back left leg and it is worse in the morning, started about a week ago after the long hike",
        "Budget for the kitchen. Counters are the big one, the quote was six thousand two hundred for the quartz, and the cheaper laminate was under two. Cabinets we are painting, not replacing, call it four hundred for paint and hardware. The sink and tap about five fifty. Electrician for the two new outlets and the under cabinet lights, he said around nine hundred. So with quartz we are right at eight thousand and with laminate under four. I keep going back and forth. The counters are the thing you touch every single day, so I lean quartz, but that is the difference between doing the floor this year or not.",
        "Passport photos, the pharmacy on Fifth does them while you wait",
        "Lock code for the storage unit is the year we moved plus two",
        "Feedback for Jordan. The work is good and it is late, and those are separate conversations. Start with the work.",
        "Movie Priya recommended, the slow one about the bakery in Kyoto, on the service we do not have, check if the library has it",
        "Renew the car registration before the end of the month, the letter is in the blue folder",
        "Notes from the school meeting. Reading is going well, she is ahead, and the teacher wants her to pick harder books, not more books. Math is fine. The thing to work on is speaking up in group work, she knows the answer and waits. They are doing a science fair in February, projects are due the week after the break, and parents are asked not to build it for them, which got a laugh. Field trip to the aquarium needs the form back by Friday. Bring the form.",
        "Try the ramen place Devon mentioned, closed Mondays",
        "Why the tests were slow. It was not the tests, it was every run booting its own simulator. One pool, leased, fixed it.",
        "Shoe size for the kids, Maya is a two, Eli is a twelve and a half, check again in the spring",
        "Mom's flight lands Saturday at four ten, terminal one, she will have the big green suitcase",
        "Half formed thought about notes. The reason I never look at old ones is that finding one costs more than writing it again. If search just worked on the words I half remember, misspelled, I would trust the pile more and write more into it.",
        "Paint color for the hallway was called quiet harbor, the eggshell finish, two cans",
        "Ask Leila for the name of the accountant she used for the house sale",
        "Running log. Five miles along the river, slow, knee was fine until the last half mile. Shoes have about four hundred miles on them, time to replace.",
        "Password hint for the old email is the street we grew up on",
        "Agenda for Monday. Hiring first, because it keeps getting cut. Then the roadmap, only the next six weeks. Then whatever is on fire. Stop at forty five minutes even if we are not done.",
        "Library books are due on the twelfth, the three on the stairs",
        "What the electrician found. The outlet in the garage is on the same circuit as the freezer, which is why it trips when the compressor runs. He can split it for about two hundred. Do it.",
        "Anniversary dinner, the place with the garden, book the corner table, they open reservations thirty days out",
        "Line for the card. You make ordinary Tuesdays feel like the good part.",
        "Tax things to gather. The two forms from the bank, the donation receipts in the drawer, the mileage from the spreadsheet, and the home office measurements. The accountant wants everything by the first week of March.",
        "Vaccines for the trip, check the clinic's list at least six weeks before",
        "Bike needs a new chain and the rear brake is soft",
        "Lesson from the launch. We tested every feature and never the first five minutes of a new person. Next time one of us installs it fresh on a borrowed phone the day before.",
        "The song from the cafe was by a band called something like Paper Lanterns, acoustic, a woman singing, ask the barista next time",
    ]
}
#endif
