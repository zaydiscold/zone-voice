// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class WordMilestonesTests: XCTestCase {
    func testNothingIsOwedBeforeTheFirstMark() {
        XCTAssertNil(WordMilestones.pending(words: 0, acknowledged: 0))
        XCTAssertNil(WordMilestones.pending(words: 499, acknowledged: 0))
        XCTAssertNil(WordMilestones.pending(words: -5, acknowledged: 0))
    }

    func testPassingAMarkOwesItsNote() {
        XCTAssertEqual(WordMilestones.pending(words: 500, acknowledged: 0)?.mark, 500)
        XCTAssertEqual(WordMilestones.pending(words: 999, acknowledged: 0)?.mark, 500)
        XCTAssertEqual(WordMilestones.pending(words: 1_000, acknowledged: 500)?.mark, 1_000)
        XCTAssertEqual(WordMilestones.pending(words: 1_000, acknowledged: 0)?.mark, 1_000)
        XCTAssertEqual(WordMilestones.pending(words: 4_999, acknowledged: 0)?.mark, 1_000)
        XCTAssertEqual(WordMilestones.pending(words: 10_432, acknowledged: 5_000)?.mark, 10_000)
    }

    func testOnlyTheHighestMarkIsOwed() {
        // An update at 30,000 words shows one note, not four.
        XCTAssertEqual(WordMilestones.pending(words: 30_000, acknowledged: 0)?.mark, 25_000)
        XCTAssertNil(WordMilestones.pending(words: 30_000, acknowledged: 25_000))
    }

    func testAClosedNoteStaysClosedWhenTheCountStartsOver() {
        // Delete data resets the count; the acknowledged mark is kept apart from it.
        XCTAssertNil(WordMilestones.pending(words: 1_200, acknowledged: 10_000))
        XCTAssertNil(WordMilestones.pending(words: 10_000, acknowledged: 10_000))
        XCTAssertEqual(WordMilestones.pending(words: 25_000, acknowledged: 10_000)?.mark, 25_000)
    }

    func testPastTheLastMarkNothingMoreIsOwed() {
        XCTAssertEqual(WordMilestones.pending(words: 5_000_000, acknowledged: 500_000)?.mark, 1_000_000)
        XCTAssertNil(WordMilestones.pending(words: 5_000_000, acknowledged: 1_000_000))
        XCTAssertNil(WordMilestones.pending(words: .max, acknowledged: .max))
    }

    func testMarksRiseAndEachHasItsOwnNote() {
        XCTAssertEqual(WordMilestones.marks, WordMilestones.marks.sorted())
        XCTAssertEqual(Set(WordMilestones.marks).count, WordMilestones.marks.count)
        let notes = WordMilestones.marks.map(WordMilestones.note(for:))
        XCTAssertEqual(Set(notes.map(\.line)).count, notes.count)
        XCTAssertEqual(notes.first?.title, "500 words.")
        XCTAssertEqual(notes[1].title, "1,000 words.")
        XCTAssertEqual(notes.last?.title, "1,000,000 words.")
    }

    /// The notes are Zone's own writing: no dashes, and never a request for a rating or review,
    /// which only Apple's prompt may make (App Review Guideline 5.6.1).
    func testNotesFollowTheWritingRulesAndNeverAskForAReview() {
        for mark in WordMilestones.marks {
            let note = WordMilestones.note(for: mark)
            let text = (note.title + " " + note.line).lowercased()
            XCTAssertFalse(text.contains("\u{2014}") || text.contains("\u{2013}"), "\(mark)")
            for banned in ["review", "rating", "rate ", "stars", "app store"] {
                XCTAssertFalse(text.contains(banned), "\(mark) mentions \(banned)")
            }
            XCTAssertLessThanOrEqual(note.line.count, 120, "\(mark) runs past three lines on a small iPhone")
        }
    }
}

/// When the note may come up: the What's New moment rules, a mark passed before the visit,
/// a short settle, and never in the same visit as What's New.
final class MilestoneMomentTests: XCTestCase {
    /// An idle Home, a visit the person began, 3 seconds in.
    private var idle: WhatsNewMoment {
        var moment = WhatsNewMoment()
        moment.setupFinished = true
        moment.sceneActive = true
        moment.homeInFront = true
        moment.sinceOpened = 3
        return moment
    }

    func testAnIdleHomeAtTheStartOfAVisitMayShowIt() {
        XCTAssertTrue(WordMilestones.mayShow(mark: 1_000, moment: idle, wordsAtVisitStart: 1_204, whatsNewThisVisit: false))
    }

    func testAMarkCrossedDuringThisVisitWaitsForTheNext() {
        // 980 words when Zone opened; a dictation then took it past 1,000.
        XCTAssertFalse(WordMilestones.mayShow(mark: 1_000, moment: idle, wordsAtVisitStart: 980, whatsNewThisVisit: false))
        XCTAssertTrue(WordMilestones.mayShow(mark: 500, moment: idle, wordsAtVisitStart: 980, whatsNewThisVisit: false))
    }

    func testNeverInTheSameVisitAsWhatsNew() {
        XCTAssertFalse(WordMilestones.mayShow(mark: 1_000, moment: idle, wordsAtVisitStart: 2_000, whatsNewThisVisit: true))
    }

    func testItWaitsForHomeToSettleAndOnlyOpensAVisit() {
        var moment = idle
        moment.sinceOpened = 1.2
        XCTAssertFalse(WordMilestones.mayShow(mark: 1_000, moment: moment, wordsAtVisitStart: 2_000, whatsNewThisVisit: false), "too soon")
        moment.sinceOpened = WordMilestones.settle
        XCTAssertTrue(WordMilestones.mayShow(mark: 1_000, moment: moment, wordsAtVisitStart: 2_000, whatsNewThisVisit: false))
        moment.sinceOpened = WhatsNewPolicy.window + 1
        XCTAssertFalse(WordMilestones.mayShow(mark: 1_000, moment: moment, wordsAtVisitStart: 2_000, whatsNewThisVisit: false),
                       "past the opening seconds the person is busy; the note waits for the next visit")
    }

    func testTheMomentRulesHold() {
        let busy: [(String, (inout WhatsNewMoment) -> Void)] = [
            ("setup unfinished", { $0.setupFinished = false }),
            ("in the background", { $0.sceneActive = false }),
            ("another screen on top", { $0.homeInFront = false }),
            ("a sheet is up", { $0.somethingPresented = true }),
            ("recording", { $0.recording = true }),
            ("an error is showing", { $0.showsError = true }),
            ("typing", { $0.typing = true }),
            ("opened by a Shortcut", { $0.automationBeforeOpen = 0.5 }),
        ]
        for (why, change) in busy {
            var moment = idle
            change(&moment)
            XCTAssertFalse(WordMilestones.mayShow(mark: 1_000, moment: moment, wordsAtVisitStart: 2_000, whatsNewThisVisit: false), why)
        }
    }
}

final class FeedbackEmailTests: XCTestCase {
    private let details = FeedbackEmail.Details(appVersion: "1.0.5", build: "2026111801", system: "iOS 26.1",
                                                device: "iPhone17,1", speechModel: "Fluid Speech Mini")

    func testDetailsLine() {
        XCTAssertEqual(details.line, "Zone 1.0.5 (2026111801), iOS 26.1, iPhone17,1, Fluid Speech Mini")
        let sparse = FeedbackEmail.Details(appVersion: "1.0.5", build: "", system: " ", device: "iPhone17,1", speechModel: "")
        XCTAssertEqual(sparse.line, "Zone 1.0.5, iPhone17,1")
    }

    func testBodyKeepsTheMessageFirstAndDetailsOnlyWhenIncluded() {
        XCTAssertEqual(FeedbackEmail.body(message: "  The mic key lags.\n", details: nil), "The mic key lags.")
        XCTAssertEqual(FeedbackEmail.body(message: "The mic key lags.", details: details),
                       "The mic key lags.\n\nZone 1.0.5 (2026111801), iOS 26.1, iPhone17,1, Fluid Speech Mini")
        XCTAssertEqual(FeedbackEmail.body(message: "", details: details), details.line)
    }

    func testSubject() {
        XCTAssertEqual(FeedbackEmail.subject(appVersion: "1.0.5"), "Zone feedback (1.0.5)")
        XCTAssertEqual(FeedbackEmail.subject(appVersion: " "), "Zone feedback")
    }

    /// A message with the characters that end a query or a field must arrive whole.
    func testMailtoSurvivesAwkwardText() throws {
        let message = "Q&A: 100% of \"swipes\" fail? a+b=c #1\nSecond line, caf\u{E9} \u{1F3A4}"
        let url = try XCTUnwrap(FeedbackEmail.mailto(message: message, details: details, appVersion: "1.0.5"))
        XCTAssertEqual(url.scheme, "mailto")
        let text = url.absoluteString
        XCTAssertTrue(text.hasPrefix("mailto:zayd@zayd.wtf?subject=Zone%20feedback%20%281.0.5%29&body="))
        // Exactly one "?" and one "&": the message's own are encoded.
        XCTAssertEqual(text.filter { $0 == "?" }.count, 1)
        XCTAssertEqual(text.filter { $0 == "&" }.count, 1)
        XCTAssertFalse(text.contains("+") || text.contains("#") || text.contains("\n"))
        // Accents and emoji are encoded too, so the link never depends on URL(string:) fixing it.
        XCTAssertTrue(text.unicodeScalars.allSatisfy(\.isASCII), text)
        let body = try XCTUnwrap(text.components(separatedBy: "&body=").last?.removingPercentEncoding)
        XCTAssertEqual(body, FeedbackEmail.body(message: message, details: details))
    }

    func testMailtoWithNothingWrittenStillOpens() {
        XCTAssertNotNil(FeedbackEmail.mailto(message: "", details: nil, appVersion: ""))
    }
}
