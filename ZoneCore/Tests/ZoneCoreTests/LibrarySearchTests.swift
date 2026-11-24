// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class LibrarySearchTests: XCTestCase {
    private func library(_ texts: [String]) -> (search: LibrarySearch, ids: [UUID]) {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // The first text is the newest, as the notes list is.
        let documents = texts.enumerated().map { index, text in
            LibrarySearch.Document(id: UUID(), text: text, date: now.addingTimeInterval(-Double(index) * 3_600))
        }
        return (LibrarySearch(documents: documents), documents.map(\.id))
    }

    private let long = "Okay so for the trip in March I want to book the cabin early because last year it filled up, "
        + "and we should ask Priya whether her brother can lend us the roof box. Also remind me to renew my passport, "
        + "it runs out in the spring, and the dentist said to come back before then for the second filling. "
        + "Nothing else, just do not forget the snow chains this time."

    private func found(_ result: LibrarySearch.Result, in text: String) -> [String] {
        let units = Array(text.utf16)
        return result.hits.first.map { hit in hit.ranges.map { String(utf16CodeUnits: Array(units[$0]), count: $0.count) } } ?? []
    }

    // MARK: Every word, as typed or in another form

    func testFindsAWordInTheMiddleOfALongNoteAndSaysWhere() {
        let (search, ids) = library(["Pick up oat milk", long, "Call the landlord about the leak"])
        let result = search.search("passport")
        XCTAssertEqual(result.hits.map(\.id), [ids[1]])
        XCTAssertEqual(result.hits[0].match, .words)
        XCTAssertEqual(found(result, in: long), ["passport"])
        XCTAssertFalse(result.widened)
        XCTAssertTrue(result.respelled.isEmpty)
    }

    func testCaseAccentsAndApostrophesDoNotMatter() {
        let (search, ids) = library(["Dinner at the café with Zoë, don’t be late", "Nothing here"])
        for query in ["CAFE", "zoe", "dont", "don't"] {
            XCTAssertEqual(search.search(query).hits.map(\.id), [ids[0]], query)
        }
    }

    func testPluralsAndTensesMeet() {
        let (search, ids) = library(["Two meetings moved to Friday", "She called about the parties", "I am making the boxes smaller"])
        XCTAssertEqual(search.search("meeting").hits.map(\.id), [ids[0]])
        XCTAssertEqual(search.search("call").hits.map(\.id), [ids[1]])
        XCTAssertEqual(search.search("party").hits.map(\.id), [ids[1]])
        XCTAssertEqual(search.search("make").hits.map(\.id), [ids[2]])
        XCTAssertEqual(search.search("box").hits.map(\.id), [ids[2]])
        XCTAssertEqual(search.search("meeting").hits[0].match, .words)
    }

    func testAWordStillBeingTypedFindsTheWholeWord() {
        let (search, ids) = library(["Book the dentist for Thursday", "Denver flight lands at nine", "Nothing"])
        XCTAssertEqual(Set(search.search("den").hits.map(\.id)), [ids[0], ids[1]])
        XCTAssertEqual(search.search("dent").hits.map(\.id), [ids[0]])
        XCTAssertEqual(search.search("dent").hits[0].match, .partial)
        XCTAssertTrue(search.search("d").hits.isEmpty, "One letter is too little to mean anything")
    }

    func testAWordInsideAJoinedWordAndTwoWordsSaidAsOne() {
        let (search, ids) = library(["Get oatmilk and bread", "Add it to the to do list", "Check-in opens at three"])
        XCTAssertEqual(search.search("milk").hits.map(\.id), [ids[0]])
        XCTAssertEqual(search.search("oat milk").hits.map(\.id), [ids[0]])
        let todo = search.search("todo")
        XCTAssertEqual(todo.hits.map(\.id), [ids[1]])
        XCTAssertEqual(found(todo, in: "Add it to the to do list"), ["to do"])
        XCTAssertTrue(todo.respelled.isEmpty, "The words are there, only spaced: nothing was respelled")
        XCTAssertEqual(search.search("checkin").hits.map(\.id), [ids[2]])
    }

    func testNumbersWrittenEitherWay() {
        let (search, ids) = library(["Table for five at seven", "Bring 5 chairs"])
        XCTAssertEqual(Set(search.search("5").hits.map(\.id)), Set(ids))
        XCTAssertEqual(Set(search.search("five").hits.map(\.id)), Set(ids))
        XCTAssertEqual(search.search("7").hits.map(\.id), [ids[0]])
    }

    // MARK: Close spellings, only for a word the library does not have

    func testASlightlyWrongSpellingFindsTheWord() {
        let (search, ids) = library([long, "Pick up oat milk"])
        for query in ["pasport", "passprot", "pastport", "dentest", "dentsit", "cabbin"] {
            let result = search.search(query)
            XCTAssertEqual(result.hits.map(\.id), [ids[0]], query)
            XCTAssertEqual(result.hits.first?.match, .close, query)
            XCTAssertEqual(result.respelled.first?.typed, query)
        }
        XCTAssertEqual(search.search("dentest").respelled, [.init(typed: "dentest", found: ["dentist"])])
        XCTAssertEqual(found(search.search("dentest"), in: long), ["dentist"])
    }

    func testAWordSpelledBySoundFindsTheWord() {
        let (search, ids) = library(["Deploy it on Vercel before the call with Kowalski", "Phone Zayd about the invoice"])
        XCTAssertEqual(search.search("versel").hits.map(\.id), [ids[0]])
        XCTAssertEqual(search.search("kowalsky").hits.map(\.id), [ids[0]])
        XCTAssertEqual(search.search("fone").hits.map(\.id), [ids[1]])
        XCTAssertEqual(search.search("zade").hits.map(\.id), [ids[1]])
        XCTAssertEqual(search.search("zaid invoise").hits.map(\.id), [ids[1]])
    }

    func testAWordTheLibraryHasIsNeverRespelled() {
        // "meeting" is here, so it must not also bring "melting"; "cat" must not bring "car".
        let (search, ids) = library(["The meeting ran long", "The ice is melting", "Feed the cat", "Wash the car"])
        XCTAssertEqual(search.search("meeting").hits.map(\.id), [ids[0]])
        XCTAssertEqual(search.search("cat").hits.map(\.id), [ids[2]])
        XCTAssertTrue(search.search("meeting").respelled.isEmpty)
    }

    func testASlipWhileStillTypingFindsTheWord() {
        let (search, ids) = library(["Book the dentist for Thursday", "Nothing"])
        XCTAssertEqual(search.search("dentes").hits.map(\.id), [ids[0]])
        XCTAssertEqual(search.search("thrusd").hits.map(\.id), [ids[0]])
    }

    func testNonsenseFindsNothing() {
        let (search, _) = library([long, "Pick up oat milk"])
        for query in ["zzqx", "xylophone", "qwertyuiop", "   ", "", "!!!"] {
            XCTAssertTrue(search.search(query).hits.isEmpty, query)
        }
    }

    // MARK: Order

    func testBestMatchesFirstThenNewest() {
        let (search, ids) = library([
            "The landlords are meeting about the leaking roof", // partial for "leak" (leaking has its stem) and both words
            "Call about the leak, the landlord is away",         // both whole words, apart
            "Ask the landlord leak questions",                   // side by side
            "Landlord leak again",                               // side by side, older
        ])
        let result = search.search("landlord leak")
        XCTAssertEqual(result.hits.map(\.id), [ids[2], ids[3], ids[0], ids[1]])
        XCTAssertEqual(result.hits.map(\.match), [.phrase, .phrase, .words, .words])
    }

    func testCloseSpellingsComeAfterNothingAndSomeWordsOnlyWhenNothingHasAll() {
        let (search, ids) = library(["Renew the passport in spring", "Passport photos at the pharmacy", "Spring cleaning list"])
        let both = search.search("passport spring")
        XCTAssertEqual(both.hits.map(\.id), [ids[0]])
        XCTAssertFalse(both.widened)
        // No note has "passport" and "pharmacy" and "cleaning": the ones with most of them come first.
        let some = search.search("passport pharmacy cleaning")
        XCTAssertTrue(some.widened)
        XCTAssertEqual(some.hits.map(\.id), [ids[1], ids[0], ids[2]])
        XCTAssertEqual(Set(some.hits.map(\.match)), [.some])
    }

    func testLittleWordsAloneDoNotWidenTheSearch() {
        let (search, _) = library(["Renew the passport in spring", "Call the bank"])
        // "the" is in both; nothing has "xylophone". The little word alone is not a result.
        XCTAssertTrue(search.search("the xylophone").hits.isEmpty)
        XCTAssertEqual(search.search("the").hits.count, 2, "Asked for by itself, it is found")
    }

    // MARK: Words and stems

    func testTokensKeepTheirPlaceInTheText() {
        let text = "Zoë’s café 🙂 isn't far"
        let tokens = LibrarySearch.tokens(text)
        XCTAssertEqual(tokens.map(\.folded), ["zoes", "cafe", "isnt", "far"])
        XCTAssertEqual(tokens.map(\.shown), ["Zoë’s", "café", "isn't", "far"])
        let units = Array(text.utf16)
        XCTAssertEqual(tokens.map { String(utf16CodeUnits: Array(units[$0.range]), count: $0.range.count) }, ["Zoë’s", "café", "isn't", "far"])
    }

    func testStems() {
        for (word, stem) in [("meetings", "meet"), ("meeting", "meet"), ("called", "call"), ("stopped", "stop"), ("running", "run"),
                             ("making", "mak"), ("make", "mak"), ("parties", "party"), ("boxes", "box"), ("thing", "thing"),
                             ("string", "string"), ("glass", "glass"), ("bus", "bus"), ("five", "5"), ("twenty", "20"), ("is", "is")] {
            XCTAssertEqual(LibrarySearch.stem(word), stem, word)
        }
    }

    func testDistanceCountsASwapOnceAndStopsAtTheLimit() {
        func distance(_ a: String, _ b: String, _ limit: Int) -> Int? { LibrarySearch.distance(Array(a), Array(b), limit: limit) }
        XCTAssertEqual(distance("dentist", "dentist", 1), 0)
        XCTAssertEqual(distance("dentsit", "dentist", 1), 1)
        XCTAssertEqual(distance("dentest", "dentist", 1), 1)
        XCTAssertEqual(distance("pasport", "passport", 1), 1)
        XCTAssertNil(distance("melting", "meeting", 0))
        XCTAssertNil(distance("cat", "dogs", 2))
        XCTAssertEqual(distance("kitten", "sitting", 3), 3)
    }

    // MARK: Showing a match

    func testAnExcerptStartsAFewWordsBeforeTheMatch() {
        let result = library([long]).search.search("passport")
        let match = result.hits[0].ranges[0]
        let start = LibrarySearch.excerptStart(in: long, before: match)
        let units = Array(long.utf16)
        let excerpt = String(utf16CodeUnits: Array(units[start...]), count: units.count - start)
        XCTAssertTrue(excerpt.hasPrefix("Also remind me to renew my passport"), excerpt)
        XCTAssertEqual(LibrarySearch.excerptStart(in: long, before: 5..<9), 0, "A match near the start shows from the start")
        // Never inside a character: an emoji before the match stays whole.
        let emoji = String(repeating: "🙂", count: 30) + " passport"
        let cut = LibrarySearch.excerptStart(in: emoji, before: 61..<69)
        XCTAssertNotNil(String(utf16CodeUnits: Array(Array(emoji.utf16)[cut...]), count: emoji.utf16.count - cut).unicodeScalars.first)
        XCTAssertEqual(cut, 0)
    }

    // MARK: Speed

    func testSearchingTwoThousandLongNotesIsFast() {
        let words = long.split(separator: " ").map(String.init)
        var seed: UInt64 = 42
        func next() -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(seed >> 33)
        }
        let documents = (0..<2_000).map { index in
            LibrarySearch.Document(id: UUID(), text: (0..<150).map { _ in words[next() % words.count] }.joined(separator: " ") + " note\(index)",
                                   date: Date(timeIntervalSince1970: Double(index)))
        }
        let built = Date()
        let search = LibrarySearch(documents: documents)
        let buildSeconds = Date().timeIntervalSince(built)
        let started = Date()
        var hits = 0
        for query in ["passport", "dentest", "snow chains", "note1999", "pri", "roof box spring", "xylophone"] {
            hits += search.search(query).hits.count
        }
        let seconds = Date().timeIntervalSince(started) / 7
        print("LibrarySearch: index of 2,000 notes (300,000 words) in \(Int(buildSeconds * 1_000)) ms, a search in \(String(format: "%.1f", seconds * 1_000)) ms")
        XCTAssertGreaterThan(hits, 0)
        // Debug builds on a loaded Mac; a phone's release build is several times faster.
        XCTAssertLessThan(seconds, 0.25, "A search must keep up with typing")
        XCTAssertLessThan(buildSeconds, 3)
    }
}

final class NotePreviewTests: XCTestCase {
    func testAShortFirstSentenceIsTheLead() {
        let preview = NotePreview("Grocery list. Oat milk, eggs, bread and the good coffee.")
        XCTAssertEqual(preview.lead, "Grocery list")
        XCTAssertEqual(preview.rest, "Oat milk, eggs, bread and the good coffee.")
        XCTAssertEqual(preview.words, 10)
        XCTAssertEqual(preview.length, "10 words")
    }

    func testAQuestionKeepsItsMark() {
        let preview = NotePreview("Did the plumber call back? If not, try the other number.")
        XCTAssertEqual(preview.lead, "Did the plumber call back?")
        XCTAssertEqual(preview.rest, "If not, try the other number.")
    }

    func testALongRunOnSentenceLeadsWithTheWordsThatFit() {
        let text = "Call the landlord about the leak in the kitchen ceiling, he said Thursday works but I need to confirm the time"
        let preview = NotePreview(text)
        XCTAssertEqual(preview.lead, "Call the landlord about the")
        XCTAssertEqual(preview.rest, "leak in the kitchen ceiling, he said Thursday works but I need to confirm the time")
        XCTAssertLessThanOrEqual(preview.lead.count, 30)
        // The rest starts exactly where the lead stopped.
        let units = Array(text.utf16)
        XCTAssertEqual(String(utf16CodeUnits: Array(units[preview.restOffset...]), count: units.count - preview.restOffset), preview.rest)
    }

    func testAShortNoteIsAllLead() {
        let preview = NotePreview("  Pick up oat milk  ")
        XCTAssertEqual(preview.lead, "Pick up oat milk")
        XCTAssertEqual(preview.rest, "")
        XCTAssertEqual(preview.length, "4 words")
        XCTAssertEqual(NotePreview("Milk").length, "1 word")
        // A whole note of one short sentence is never split: nothing reads "…coffee on the / way home".
        let whole = NotePreview("Pick up oat milk and the good coffee on the way home")
        XCTAssertEqual(whole.lead, "Pick up oat milk and the good coffee on the way home")
        XCTAssertEqual(whole.rest, "")
    }

    func testTheFirstLineOfATypedNoteIsTheLead() {
        let preview = NotePreview("Packing\nboots, charger\nsnow chains")
        XCTAssertEqual(preview.lead, "Packing")
        XCTAssertEqual(preview.rest, "boots, charger snow chains")
    }

    func testAbbreviationsAndDecimalsDoNotEndTheLead() {
        // "3.5" has no space after its period, so it is not a sentence end.
        XCTAssertEqual(NotePreview("Rate is 3.5 percent now. Check again Friday.").lead, "Rate is 3.5 percent now")
        XCTAssertEqual(NotePreview("A comma ends nothing, and this keeps going for quite a while longer than a line").lead,
                       "A comma ends nothing, and this")
    }

    func testOneVeryLongWordIsCutNotLost() {
        let preview = NotePreview(String(repeating: "a", count: 80))
        XCTAssertEqual(preview.lead.count, 30)
        XCTAssertEqual(preview.rest.count, 50)
    }

    func testEmpty() {
        let preview = NotePreview("")
        XCTAssertEqual(preview.lead, "")
        XCTAssertEqual(preview.words, 0)
    }

    // MARK: A row for a search

    func testAMatchInTheMiddleIsShownWithTheWordsAroundIt() {
        let text = "Trip planning for March. Okay so I want to book the cabin early because last year it filled up, and we should ask "
            + "Priya whether her brother can lend us the roof box. Also remind me to renew my passport, it runs out in the spring."
        let search = LibrarySearch(documents: [.init(id: UUID(), text: text, date: Date())])
        let preview = NotePreview(text)
        XCTAssertEqual(preview.lead, "Trip planning for March")
        let found = preview.found(search.search("passport").hits[0].ranges)
        XCTAssertEqual(found.lead, "Trip planning for March")
        XCTAssertTrue(found.leadMarks.isEmpty)
        XCTAssertTrue(found.rest.hasPrefix("\u{2026} Also remind me to renew my passport"), found.rest)
        XCTAssertEqual(marked(found.rest, found.restMarks), ["passport"])
    }

    func testAMatchInTheLeadIsMarkedThereAndTheRestStartsAtItsStart() {
        let text = "  Trip planning for March. Book the cabin early, and ask about the roof box for the trip."
        let search = LibrarySearch(documents: [.init(id: UUID(), text: text, date: Date())])
        let preview = NotePreview(text)
        let found = preview.found(search.search("trip").hits[0].ranges)
        XCTAssertEqual(marked(found.lead, found.leadMarks), ["Trip"])
        XCTAssertEqual(marked(found.rest, found.restMarks), ["trip"])
        let near = NotePreview("Trip planning for March. Book the trip early.")
        let foundNear = near.found(LibrarySearch(documents: [.init(id: UUID(), text: "Trip planning for March. Book the trip early.", date: Date())]).search("trip").hits[0].ranges)
        XCTAssertEqual(foundNear.rest, "Book the trip early.", "A match near the start of the rest shows from its start")
    }

    func testLineBreaksKeepMarksInPlace() {
        let text = "Packing\n\nboots, charger\r\nsnow chains and the passport"
        let search = LibrarySearch(documents: [.init(id: UUID(), text: text, date: Date())])
        let found = NotePreview(text).found(search.search("chains passport").hits[0].ranges)
        XCTAssertEqual(marked(found.rest, found.restMarks), ["chains", "passport"])
    }

    private func marked(_ text: String, _ marks: [Range<Int>]) -> [String] {
        let units = Array(text.utf16)
        return marks.map { String(utf16CodeUnits: Array(units[$0]), count: $0.count) }
    }
}

final class NoteGroupsTests: XCTestCase {
    func testRecentByDayThenWeekMonthAndYear() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let locale = Locale(identifier: "en_US")
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 15))!
        func title(_ daysAgo: Int) -> String {
            NoteGroups.title(for: calendar.date(byAdding: .day, value: -daysAgo, to: now)!, now: now, calendar: calendar, locale: locale)
        }
        XCTAssertEqual(title(0), "Today")
        XCTAssertEqual(title(1), "Yesterday")
        XCTAssertEqual(title(2), "This week")
        XCTAssertEqual(title(6), "This week")
        XCTAssertEqual(title(7), "This month")
        XCTAssertEqual(title(29), "This month")
        XCTAssertEqual(title(30), "October")
        XCTAssertEqual(title(120), "July")
        XCTAssertEqual(title(330), "2025")
        XCTAssertEqual(title(800), "2024")
        // Last December, seen in January, is still a month and not a year.
        let january = calendar.date(from: DateComponents(year: 2027, month: 1, day: 20))!
        let december = calendar.date(from: DateComponents(year: 2026, month: 12, day: 5))!
        XCTAssertEqual(NoteGroups.title(for: december, now: january, calendar: calendar, locale: locale), "December")
    }
}
