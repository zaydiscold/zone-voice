// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class IslandPetGrowthTests: XCTestCase {
    func testDailyEnergyExpiresAndKeepsakesSurviveTimeAwayAndRetries() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        var receipts = DictationReceipts()
        for offset in 0..<3 {
            let id = UUID(), start = now.addingTimeInterval(-86_400 * Double(offset) - 60)
            receipts.finish(id: id, start: start, words: 4, seconds: 48, recoveryDate: nil, awaitingNote: false)
            receipts.finish(id: id, start: start, words: 5, seconds: 48, recoveryDate: now, awaitingNote: false)
        }
        let garden = receipts.garden(on: now, calendar: calendar)
        XCTAssertEqual(garden.activeDays, 3)
        XCTAssertEqual(garden.sessions, 3)
        XCTAssertEqual(garden.todayCount, 1)
        XCTAssertEqual(garden.dailyEnergy(on: now, calendar: calendar), 2)
        XCTAssertEqual(garden.stage(words: 15).index, 1)
        XCTAssertEqual(garden.stage(words: 75_000).index, 4)
        let later = now.addingTimeInterval(86_400 * 30)
        XCTAssertEqual(garden.dailyEnergy(on: later, calendar: calendar), 0)
        XCTAssertEqual(receipts.garden(on: later, calendar: calendar).accessory, 2)
    }

    func testGalleryCountAndEnergyResetAtLocalMidnightOnAShortDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let late = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 23, minute: 59)))
        let midnight = late.addingTimeInterval(60)
        var receipts = DictationReceipts()
        receipts.finish(id: UUID(), start: late, words: 4, seconds: 48, recoveryDate: nil, awaitingNote: false)
        let garden = receipts.garden(on: late, calendar: calendar)
        XCTAssertEqual(garden.sessionsToday(on: late, calendar: calendar), 1)
        XCTAssertEqual(garden.sessionsToday(on: midnight, calendar: calendar), 0)
        XCTAssertEqual(garden.dailyEnergy(on: midnight, calendar: calendar), 0)
        XCTAssertEqual(garden.sessions, 1)
    }

    func testAnEggHatchesWithinTheFirstFewDictations() {
        XCTAssertEqual(IslandPetGrowth.stage(forWords: 0).name, "Egg")
        XCTAssertEqual(IslandPetGrowth.stage(forWords: 99).index, 0)
        XCTAssertEqual(IslandPetGrowth.stage(forWords: 100).name, "Hatchling")
    }

    func testStagesOnlyEverGoUpWithWords() {
        var last = -1
        for words in stride(from: 0, through: 300_000, by: 250) {
            let index = IslandPetGrowth.stage(forWords: words).index
            XCTAssertGreaterThanOrEqual(index, last, "the pet shrank at \(words) words")
            last = index
        }
        XCTAssertEqual(last, IslandPetGrowth.stages.count - 1)
    }

    func testEveryStageBoundaryIsItsOwnStage() {
        for stage in IslandPetGrowth.stages {
            XCTAssertEqual(IslandPetGrowth.stage(forWords: stage.words), stage)
            if stage.words > 0 {
                XCTAssertEqual(IslandPetGrowth.stage(forWords: stage.words - 1).index, stage.index - 1)
            }
        }
    }

    func testProgressRunsFromZeroToOneWithinAStage() {
        XCTAssertEqual(IslandPetGrowth.progress(forWords: 100), 0, accuracy: 0.0001)
        XCTAssertEqual(IslandPetGrowth.progress(forWords: 1_050), 0.5, accuracy: 0.0001)
        XCTAssertEqual(IslandPetGrowth.progress(forWords: 9_999_999), 1)
    }

    func testTheLineNamesWhatComesNextAndEndsWhenGrown() {
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(IslandPetGrowth.line(forWords: 412, locale: us), "412 of 2,000 words to Listener")
        XCTAssertEqual(IslandPetGrowth.line(forWords: 0, locale: us), "0 of 100 words to Hatchling")
        XCTAssertNil(IslandPetGrowth.line(forWords: 250_000, locale: us))
    }

    func testAnExistingFullyGrownPetKeepsItsCrown() {
        XCTAssertEqual(IslandPetGrowth.stage(forWords: 75_000).name, "Sovereign")
        XCTAssertEqual(IslandPetGrowth.stage(forWords: 250_000).name, "Starlit")
    }

    func testFirstBoxUnlocksAtOneThousandAndStaysOpen() {
        XCTAssertFalse(IslandPetGrowth.hasWordBox(999))
        XCTAssertTrue(IslandPetGrowth.hasWordBox(1_000))
        XCTAssertTrue(IslandPetGrowth.hasWordBox(.max))
    }

    func testNegativeAndAbsurdCountsAreSafe() {
        XCTAssertEqual(IslandPetGrowth.stage(forWords: -5).index, 0)
        XCTAssertEqual(IslandPetGrowth.progress(forWords: -5), 0)
        XCTAssertEqual(IslandPetGrowth.stage(forWords: .max).index, IslandPetGrowth.stages.count - 1)
    }
}
