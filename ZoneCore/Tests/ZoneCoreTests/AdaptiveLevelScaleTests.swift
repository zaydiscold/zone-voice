// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class AdaptiveLevelScaleTests: XCTestCase {
    func testHeldNoteHoldsSteady() {
        var scale = AdaptiveLevelScale()
        let first = scale.map(decibels: -18, elapsed: 0.05)
        var last = first
        for _ in 0..<200 { last = scale.map(decibels: -18, elapsed: 0.05) } // ten seconds
        XCTAssertEqual(first, last, accuracy: 0.0001, "the same loudness must draw the same height")
    }

    func testSpeechSpreadsAcrossTheMeter() {
        var scale = AdaptiveLevelScale()
        let quietRoom = scale.map(decibels: -50, elapsed: 0.05)
        let softSpeech = scale.map(decibels: -35, elapsed: 0.05)
        let normal = scale.map(decibels: -20, elapsed: 0.05)
        let loud = scale.map(decibels: -8, elapsed: 0.05)
        XCTAssertLessThan(quietRoom, 0.01, "steady room noise must not look like speech")
        XCTAssertTrue(softSpeech < normal && normal < loud)
        XCTAssertEqual(normal, 0.5, accuracy: 0.12, "normal speech sits near the middle, not pinned")
        XCTAssertLessThan(loud, 0.95)
    }

    func testDeadMicReadsZero() {
        var scale = AdaptiveLevelScale()
        XCTAssertEqual(scale.map(decibels: -120, elapsed: 0.05), 0)
    }
    func testLowSpeechMovesTheMeterAndDoesNotAutoFinishOverSyllables() {
        var meter = QuietVoiceMeter()
        var finish = SilenceFinish(wait: 5)
        var maxLevel: Float = 0
        for step in 0..<240 {
            let time = Double(step) * 0.05
            let db: Float = step < 20 ? -64 : [-54, -48, -53, -59, -61, -57][step % 6]
            let reading = meter.reading(rms: pow(10, db / 20), at: time)
            maxLevel = max(maxLevel, reading.display)
            XCTAssertNotEqual(finish.sample(level: reading.detection, at: time), .finish)
        }
        XCTAssertGreaterThan(maxLevel, 0.32)
        var didFinish = false
        for step in 240..<400 {
            let t = Double(step) * 0.05
            let room = meter.reading(rms: pow(10, -59.0 / 20), at: t)
            if step > 255 { XCTAssertLessThan(room.display, 0.05) }
            if finish.sample(level: room.detection, at: t) == .finish { didFinish = true }
        }
        XCTAssertTrue(didFinish)
    }

}
