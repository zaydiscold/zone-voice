// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// When a color Flash shows data and when the art takes over: every data picture gets a whole
/// slot, the art stays within its share, and the time on the guide counts all of it.
final class LinkFlashScheduleTests: XCTestCase {
    private let key = FlashFixtures.bytes(hex: FlashFixtures.keyHex)

    func testTheColorScheduleIsAnOpeningThenDataWithAHalfSecondInterludeEveryTwoAndAHalf() {
        let schedule = LinkFlashSchedule.color
        let rate = Double(LinkFlashFormat.framesPerSecond)
        XCTAssertEqual(Double(schedule.openingPictures) / rate, 1.0, accuracy: 1e-9, "about a second of opening")
        XCTAssertEqual(Double(schedule.artPictures) / rate, 0.5, accuracy: 1e-9, "about half a second of art")
        let every = Double(schedule.period) / rate
        XCTAssertGreaterThanOrEqual(every, 2.0)
        XCTAssertLessThanOrEqual(every, 2.5)
        XCTAssertLessThanOrEqual(1 - schedule.dataShare, 0.25, "the art takes at most a quarter of the time")
        XCTAssertEqual(schedule.dataShare, 0.8, accuracy: 1e-9)
        // One dip and one return of the window's brightness per interlude: far under three a second.
        XCTAssertLessThan(2 / every, 3)
        XCTAssertGreaterThanOrEqual(LinkFlashSchedule.interludeTurn * Double(schedule.artPictures) / rate, 0.15,
                                    "each turn is eased over at least 150 ms")
    }

    func testEveryDataPictureGetsOneWholeSlotInOrder() {
        let schedule = LinkFlashSchedule.color
        var data: [Int] = []
        var art = 0, opening = 0
        for index in 0..<(schedule.openingPictures + 10 * schedule.period) {
            switch schedule.slot(index) {
            case .opening(let step):
                XCTAssertEqual(step, index)
                XCTAssertTrue(data.isEmpty, "the opening comes before any data")
                opening += 1
            case .data(let picture):
                XCTAssertEqual(schedule.slotIndex(ofData: picture), index, "and back again")
                data.append(picture)
            case .art(let interlude, let step):
                XCTAssertEqual(interlude, (data.count - 1) / schedule.dataPictures)
                XCTAssertTrue((0..<schedule.artPictures).contains(step))
                art += 1
            }
        }
        XCTAssertEqual(opening, 20)
        XCTAssertEqual(data, Array(0..<400), "no picture skipped, none shown twice")
        XCTAssertEqual(art, 100)
        XCTAssertEqual(schedule.slot(-5), .opening(step: 0))
        XCTAssertEqual(schedule.slot(20), .data(0))
        XCTAssertEqual(schedule.slot(59), .data(39))
        XCTAssertEqual(schedule.slot(60), .art(interlude: 0, step: 0))
        XCTAssertEqual(schedule.slot(69), .art(interlude: 0, step: 9))
        XCTAssertEqual(schedule.slot(70), .data(40))
    }

    func testDataOnlyIsNothingButData() {
        let schedule = LinkFlashSchedule.dataOnly
        for index in 0..<200 { XCTAssertEqual(schedule.slot(index), .data(index)) }
        XCTAssertEqual(schedule.dataShare, 1)
        XCTAssertEqual(schedule.act(ofData: 5_000), 0)
        XCTAssertFalse(schedule.changesScene(atInterlude: 3))
        XCTAssertEqual(schedule.slots(forPictures: 70), 70)
    }

    func testAnActIsFourInterludesAndTheLastOneChangesTheScene() {
        let schedule = LinkFlashSchedule.color
        XCTAssertEqual(schedule.interludesPerAct, 4)
        XCTAssertEqual(schedule.act(ofData: 0), 0)
        XCTAssertEqual(schedule.act(ofData: 159), 0, "four runs of 40 pictures")
        XCTAssertEqual(schedule.act(ofData: 160), 1)
        XCTAssertEqual(schedule.act(ofData: 320), 2)
        XCTAssertEqual((0..<8).map { schedule.changesScene(atInterlude: $0) },
                       [false, false, false, true, false, false, false, true])
        // The interlude that changes the scene sits between the last picture of one act and the first of the next.
        for interlude in 0..<12 {
            let before = (interlude + 1) * schedule.dataPictures - 1
            XCTAssertEqual(schedule.act(ofData: before) != schedule.act(ofData: before + 1),
                           schedule.changesScene(atInterlude: interlude), "interlude \(interlude)")
        }
    }

    func testAnInterludeDissolvesHoldsAndFormsWithoutAStep() {
        XCTAssertEqual(LinkFlashSchedule.codePresence(through: 0), 1)
        XCTAssertEqual(LinkFlashSchedule.codePresence(through: 0.5), 0, "the scene has the window to itself")
        XCTAssertEqual(LinkFlashSchedule.codePresence(through: 1), 1)
        XCTAssertEqual(LinkFlashSchedule.codePresence(through: 0.3), 0, accuracy: 1e-9)
        XCTAssertEqual(LinkFlashSchedule.codePresence(through: 0.7), 0, accuracy: 1e-9)
        // Gentle: no refresh at 60 a second changes the window by more than a fifth.
        var previous = 1.0
        var steps = 0
        for refresh in 0...30 {
            let now = LinkFlashSchedule.codePresence(through: Double(refresh) / 30)
            XCTAssertLessThan(abs(now - previous), 0.2, "refresh \(refresh)")
            if now != previous { steps += 1 }
            previous = now
        }
        XCTAssertGreaterThanOrEqual(steps, 16, "spread over many refreshes")
        XCTAssertFalse(LinkFlashSchedule.showsNextPicture(through: 0.49))
        XCTAssertTrue(LinkFlashSchedule.showsNextPicture(through: 0.5))
        XCTAssertEqual(LinkFlashSchedule.codePresence(through: 0.45), 0, "the picture is swapped while none of it shows")
        XCTAssertEqual(LinkFlashSchedule.codePresence(through: 0.55), 0)
    }

    func testTheOpeningHoldsTheWordmarkThenTurnsItIntoTheCode() {
        XCTAssertEqual(LinkFlashSchedule.openingReveal(through: 0), 0)
        XCTAssertEqual(LinkFlashSchedule.openingReveal(through: LinkFlashSchedule.openingHold), 0)
        XCTAssertEqual(LinkFlashSchedule.openingReveal(through: 1), 1)
        var previous = 0.0
        for step in 0...40 {
            let now = LinkFlashSchedule.openingReveal(through: Double(step) / 40)
            XCTAssertGreaterThanOrEqual(now, previous, "never backwards")
            previous = now
        }
        XCTAssertEqual(LinkFlashSchedule.ease(-1), 0)
        XCTAssertEqual(LinkFlashSchedule.ease(0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(LinkFlashSchedule.ease(2), 1)
        XCTAssertGreaterThan(LinkFlashSchedule.endingSeconds, 0.3)
        XCTAssertLessThan(LinkFlashSchedule.endingSeconds, 1.2)
    }

    func testTheTimeOnTheGuideCountsTheOpeningAndTheInterludes() throws {
        // A library that needs about 200 chunks (a real one of 1,764 items did), by its sealed size.
        let payload = Data((0..<(200 * 900 - 40)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let encoder = try LinkFlashEncoder(payload: payload, session: 0x8000_0001)
        XCTAssertEqual(encoder.chunkCount, 200)
        let plan = LinkFlashPlan(items: [], leftOut: 0, jsonBytes: 0, encoder: encoder, framesPerSecond: 20, codesPerPicture: 3)
        XCTAssertEqual(plan.seconds, 3.5, accuracy: 1e-9, "210 frames, three a picture, twenty pictures a second")
        XCTAssertEqual(LinkFlashSchedule.dataOnly.seconds(for: plan), 3.5, accuracy: 1e-9)
        // 70 pictures: a second of opening, 40 pictures, one interlude, 30 pictures.
        XCTAssertEqual(LinkFlashSchedule.color.slots(forPictures: 70), 20 + 70 + 10)
        XCTAssertEqual(LinkFlashSchedule.color.seconds(for: plan), 5.0, accuracy: 1e-9)
        // A flash that fits before the first interlude pays only the opening.
        XCTAssertEqual(LinkFlashSchedule.color.slots(forPictures: 40), 60)
        XCTAssertEqual(LinkFlashSchedule.color.slots(forPictures: 41), 71)
        XCTAssertEqual(LinkFlashSchedule.color.slots(forPictures: 0), 20)

        let small = try LinkFlash.plan(items: FlashFixtures.library(dictations: 120), phone: FlashFixtures.phone, key: key,
                                       codesPerPicture: 3)
        XCTAssertGreaterThan(LinkFlashSchedule.color.seconds(for: small), small.seconds + 0.99)
    }
}
