// by zayd/cold @ zayd.wtf

import XCTest

/// The Speakers screen on a meeting merged from two recordings of the same two people
/// (`-zoneMeetingSeedMerged`, Debug builds): combining the voices, naming, "me", separating and
/// Undo, and how many taps the whole relabeling takes.
final class MeetingSpeakersUITests: XCTestCase {
    private func settled(mode: String = "meeting") -> [String] {
        let version = Bundle(for: Self.self).infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.6"
        return ["-zone.settings.onboardingDone", "YES", "-zone.tour.seen", "YES", "-zoneWhatsNewAfter", version,
                "-zone.home.mode", mode, "-zone.settings.autoArm", "NO"]
    }

    /// Taps made on the way to a fully relabeled meeting, counted where they are made.
    private var taps = 0
    private let sampleSuffix = String(UUID().uuidString.prefix(6))
    private var secondSample: String { "Second half " + sampleSuffix }

    override func setUp() {
        continueAfterFailure = false
        taps = 0
    }

    private func openMeeting(_ mode: String, arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        let title = "Catch-up " + sampleSuffix
        app.launchArguments = settled() + ["-zoneMeetingSeedMerged", mode, "-zoneDebugMeetingTitle", title,
                                           "-zoneDebugSecondMeetingTitle", secondSample] + arguments
        app.launch()
        let search = app.textFields["meetings.search"]
        for _ in 0..<4 where !search.isHittable { app.swipeUp() }
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText(title + "\n")
        let row = app.buttons["meeting.row." + title].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the seeded meeting is in the list")
        row.tap()
        XCTAssertTrue(app.textViews["Meeting title"].waitForExistence(timeout: 10) || app.textFields["Meeting title"].waitForExistence(timeout: 2))
        return app
    }

    private func tap(_ element: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 8), "\(what) is on screen", file: file, line: line)
        element.tap()
        taps += 1
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["ZONE_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }

    private func speakerRows(_ app: XCUIApplication) -> Int {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'meeting.speakers.row.'")).count
    }

    private func openReview(appearance: String) -> XCUIApplication {
        let app = openMeeting("review", arguments: ["-zone.settings.appearance", appearance, "-zone.settings.accent", "ice"])
        let more = app.buttons["More"]
        // Core Animation can report 43.99999999999999 for the 44-point frame.
        XCTAssertGreaterThanOrEqual(more.frame.width, 44 - 0.001)
        XCTAssertGreaterThanOrEqual(more.frame.height, 44 - 0.001)
        more.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let merge = app.buttons["Merge with another recording"]
        XCTAssertTrue(merge.waitForExistence(timeout: 5))
        merge.tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", secondSample)).firstMatch.tap()
        app.buttons["Merge"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Confirm pairs"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.buttons["Play Speaker 3"].firstMatch.exists)
        shot(app, "same-person-" + appearance)
        return app
    }

    func testReviewAppearsAtMergeAndConfirmsBothPairs() {
        let app = openReview(appearance: "dark")
        let confirm = app.buttons["Confirm pairs"]
        confirm.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["meeting.speaker.S2"].exists)
        XCTAssertFalse(app.buttons["meeting.speaker.S3"].exists)
    }

    func testPlayBothVoicesAndKeepOnePairSeparate() {
        let app = openReview(appearance: "light")
        for voice in ["Speaker 3", "Speaker 2"] {
            app.buttons["Play " + voice].firstMatch.tap()
            XCTAssertTrue(app.buttons["Stop " + voice].firstMatch.waitForExistence(timeout: 3))
        }
        let pair = app.buttons["Combine Speaker 3 and Speaker 2"]
        pair.tap()
        XCTAssertEqual(pair.value as? String, "No")
        let confirm = app.buttons["Confirm pairs"]
        confirm.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["meeting.speaker.S3"].exists)
        XCTAssertFalse(app.buttons["meeting.speaker.S4"].exists)
    }

    func testHoldMeetingAndConfirmDeletion() {
        let app = XCUIApplication()
        let title = "Delete sample " + UUID().uuidString.prefix(6)
        app.launchArguments = settled() + ["-zoneMeetingSeedMerged", "open", "-zoneDebugMeetingTitle", title]
        app.launch()
        let row = app.buttons["meeting.row." + title]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.press(forDuration: 1.1)
        for title in ["Rename", "Merge with another recording", "Transcribe again", "Delete"] {
            XCTAssertTrue(app.buttons[title].exists, title)
        }
        shot(app, "meeting-hold")
        app.buttons["Delete"].tap()
        let confirm = app.buttons["Delete audio and transcript"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        shot(app, "meeting-delete-confirmation")
        confirm.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 8))
    }

    func testCompareAndSelectSavedRecordings() {
        let app = XCUIApplication()
        app.launchArguments = settled(mode: "transcribe") + ["-zoneRecoveryPair", "-zoneFakeSpeech", "Sample"]
        app.launch()
        let group = app.buttons.matching(NSPredicate(format: "label CONTAINS 'recordings to recover'")).firstMatch
        for _ in 0..<5 where !group.isHittable { app.swipeUp() }
        XCTAssertTrue(group.waitForExistence(timeout: 20))
        group.tap()
        let all = app.buttons["recovery.seeAll"]
        if all.exists {
            shot(app, "inline-recovery-preview")
            for _ in 0..<5 where !all.isHittable { app.swipeUp() }
            all.tap()
            XCTAssertTrue(app.navigationBars["Saved recordings"].waitForExistence(timeout: 8))
        }
        let spoken = app.buttons["recovery.row.5EED0000-0000-4000-8005-000000000001"]
        let silent = app.buttons["recovery.row.5EED0000-0000-4000-8005-000000000000"]
        XCTAssertTrue(silent.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(spoken.exists)
        shot(app, "saved-sound-comparison")
        silent.press(forDuration: 1.1)
        XCTAssertTrue(app.buttons["Details"].waitForExistence(timeout: 5))
        shot(app, "saved-recording-hold")
        app.buttons["Details"].tap()
        XCTAssertTrue(app.navigationBars["Recording details"].waitForExistence(timeout: 5))
        let peak = app.staticTexts["Peak level"]
        for _ in 0..<6 where !peak.exists { app.swipeUp() }
        XCTAssertTrue(peak.exists)
        shot(app, "saved-recording-levels")
        app.buttons["Done"].tap()
        let select = app.buttons["Select recordings"]
        for _ in 0..<4 where !select.isHittable { app.swipeDown() }
        select.tap()
        // The Debug seeder owns precisely these two IDs, even on a shared simulator.
        let silentID = "5EED0000-0000-4000-8005-000000000000"
        let spokenID = "5EED0000-0000-4000-8005-000000000001"
        app.buttons["recovery.select." + spokenID].tap()
        app.buttons["recovery.select." + silentID].tap()
        app.buttons["Delete selected"].tap()
        let confirm = app.alerts["Delete 2 recordings?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(confirm.staticTexts.containing(NSPredicate(format: "label CONTAINS 'permanently deletes'")).firstMatch.exists)
        confirm.buttons["Cancel"].tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["recovery.row." + spokenID].exists)
        XCTAssertTrue(app.buttons["recovery.row." + silentID].exists)
        app.buttons["Delete selected"].tap()
        confirm.buttons["Delete recordings"].tap()
        XCTAssertTrue(app.buttons["recovery.row." + spokenID].waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons["recovery.row." + silentID].waitForNonExistence(timeout: 10))
    }

    func testRelabelingAMergedMeetingTakesSevenTaps() {
        let app = openMeeting("open")
        // Before: four numbered speakers for two people, and the meeting says so.
        XCTAssertTrue(app.buttons["meeting.speaker.S4"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Review voices"].exists)
        shot(app, "01-merged-four-speakers")

        tap(app.buttons["meeting.speaker.S1"], "Speaker 1's pill")
        XCTAssertTrue(app.buttons["meeting.speakers.row.S4"].waitForExistence(timeout: 8))
        XCTAssertEqual(speakerRows(app), 4)
        shot(app, "02-speakers-suggestions")

        tap(app.buttons["meeting.speakers.suggest.S3"], "Same person, for the third voice")
        tap(app.buttons["meeting.speakers.suggest.S4"], "Same person, for the fourth voice")
        XCTAssertTrue(app.buttons["meeting.speakers.row.S4"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(speakerRows(app), 2)

        tap(app.buttons["meeting.speakers.me"], "This is me")
        tap(app.buttons["meeting.speakers.row.S2"], "the other person's row")
        tap(app.buttons["meeting.speakers.known.Riju"], "the name used in an earlier meeting")
        shot(app, "03-speakers-relabeled")
        tap(app.buttons["Done"], "Done")

        XCTAssertEqual(taps, 7, "pill, two Same person, This is me, row, name, Done")
        XCTAssertTrue(app.buttons["meeting.speaker.S2"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["meeting.speaker.S1"].label, "Me")
        XCTAssertEqual(app.buttons["meeting.speaker.S2"].label, "Riju")
        XCTAssertFalse(app.buttons["meeting.speaker.S3"].exists)
        XCTAssertFalse(app.buttons["meeting.speaker.S4"].exists)
        let labels = app.buttons.matching(identifier: "meeting.paragraph.speaker").allElementsBoundByIndex.map(\.label)
        XCTAssertEqual(Set(labels), ["Me", "Riju"])
        XCTAssertFalse(app.buttons["Review voices"].exists)
        shot(app, "04-transcript-two-people")

        // The last change can still be taken back from the meeting itself.
        XCTAssertTrue(app.buttons["meeting.speakers.undo"].waitForExistence(timeout: 5))
        app.buttons["meeting.speakers.undo"].tap()
        XCTAssertTrue(app.buttons["meeting.speaker.S2"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["meeting.speaker.S2"].label, "Speaker 2")
    }

    func testASecondMeIsOfferedBothWaysAndNeverTakenSilently() {
        let app = openMeeting("open")
        tap(app.buttons["meeting.speaker.S1"], "Speaker 1's pill")
        tap(app.buttons["meeting.speakers.me"], "This is me")
        tap(app.buttons["meeting.speakers.row.S3"], "the third voice's row")
        // Someone already is me: both answers are on screen, and neither is the old silent move.
        XCTAssertTrue(app.buttons["meeting.speakers.alsoMe"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["meeting.speakers.onlyMe"].exists)
        XCTAssertFalse(app.buttons["meeting.speakers.me"].exists)
        shot(app, "05-also-me-or-only-me")

        app.buttons["meeting.speakers.alsoMe"].tap()
        XCTAssertTrue(app.buttons["meeting.speakers.row.S3"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(speakerRows(app), 3)
        XCTAssertTrue(app.buttons["meeting.speakers.separate.S3"].waitForExistence(timeout: 5), "the joined voice is listed under Me")
        XCTAssertTrue(app.staticTexts["Combined Speaker 3 with Me"].exists)
        shot(app, "06-combined-with-undo")

        app.buttons["meeting.speakers.undo"].tap()
        XCTAssertTrue(app.buttons["meeting.speakers.row.S3"].waitForExistence(timeout: 5))
        XCTAssertEqual(speakerRows(app), 4)
        XCTAssertEqual(app.buttons["meeting.speakers.row.S1"].label.hasPrefix("Me"), true, "Speaker 1 is still me")
    }

    func testVoicesMatchedAtTheMergeShowAsTwoPeopleAndCanBeSeparated() {
        let app = openMeeting("separate")
        tap(app.buttons["More"], "More")
        tap(app.buttons["Merge with another recording"], "Merge with another recording")
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", secondSample)).firstMatch, "second recording")
        tap(app.buttons["Merge"].firstMatch, "confirm merge")
        XCTAssertEqual(taps, 4)
        // Nothing to do after the merge: two people, no notice.
        XCTAssertTrue(app.buttons["meeting.speaker.S2"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["meeting.speaker.S3"].exists)
        XCTAssertFalse(app.buttons["Review voices"].exists)
        shot(app, "07-matched-at-merge")

        app.buttons["meeting.speaker.S1"].tap()
        XCTAssertTrue(app.buttons["meeting.speakers.separate.S4"].waitForExistence(timeout: 8))
        shot(app, "08-joined-voice-listed")
        app.buttons["meeting.speakers.separate.S4"].tap()
        XCTAssertTrue(app.buttons["meeting.speakers.row.S4"].waitForExistence(timeout: 5))
        XCTAssertEqual(speakerRows(app), 3)
        app.buttons["meeting.speakers.undo"].tap()
        XCTAssertTrue(app.buttons["meeting.speakers.row.S4"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(speakerRows(app), 2)
    }

    func testSearchAndCopyFindWordsSpokenAfterTheMerge() {
        let app = XCUIApplication()
        app.launchArguments = settled() + ["-zoneMeetingSeedMerged", "matched"]
        app.launch()
        let search = app.textFields["meetings.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 20))
        search.tap()
        search.typeText("call dropped\n")
        let row = app.buttons["meeting.row.Catch-up with Riju"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["meeting.row.Planning with Riju"].exists)
        let copy = app.buttons["library.copy"].firstMatch
        tap(copy, "Copy on the matching row")
        XCTAssertEqual(copy.label, "Copied")
        shot(app, "10-search-and-copy")
    }

    func testANameSomeoneAlreadyHasAsksBeforeMakingTwoOfThem() {
        let app = openMeeting("open")
        app.buttons["meeting.speaker.S2"].tap()
        XCTAssertTrue(app.buttons["meeting.speakers.known.Riju"].waitForExistence(timeout: 8))
        app.buttons["meeting.speakers.known.Riju"].tap()
        app.buttons["meeting.speakers.row.S3"].tap()
        let field = app.textFields["meeting.speakers.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("riju\n")
        XCTAssertTrue(app.buttons["meeting.speakers.clash.same"].waitForExistence(timeout: 5), "asked, not saved")
        shot(app, "09-name-already-here")
        app.buttons["meeting.speakers.clash.same"].tap()
        XCTAssertTrue(app.buttons["meeting.speakers.row.S3"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(speakerRows(app), 3)
    }
}
