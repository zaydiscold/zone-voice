// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class VoiceBarsTests: XCTestCase {
    func testSilenceLeavesEveryBarFlat() {
        XCTAssertEqual(VoiceBars.heights(levels: [Float](repeating: 0, count: 32), count: 37),
                       [Float](repeating: 0, count: 37))
        XCTAssertEqual(VoiceBars.heights(levels: [], count: 5), [0, 0, 0, 0, 0])
    }

    func testASteadyVoiceSwellsInTheMiddleAndTapersEvenly() {
        let heights = VoiceBars.heights(levels: [Float](repeating: 0.5, count: 32), count: 37)
        let center = heights[18]
        XCTAssertEqual(center, heights.max())
        XCTAssertEqual(center, pow(0.5, 0.62), accuracy: 0.0001)
        for index in 0..<18 {
            XCTAssertEqual(heights[index], heights[36 - index], accuracy: 0.0001, "bar \(index) and its mirror")
            XCTAssertLessThan(heights[index], heights[index + 1], "rises toward the middle at \(index)")
        }
        XCTAssertEqual(heights[0], center * VoiceBars.edgeReach, accuracy: 0.0001)
    }

    func testTheNewestSoundIsAtTheRightEnd() {
        var levels = [Float](repeating: 0, count: 32)
        levels[31] = 1
        let heights = VoiceBars.heights(levels: levels, count: 33)
        XCTAssertEqual(heights[32], VoiceBars.edgeReach, accuracy: 0.0001)
        XCTAssertEqual(heights[0], 0)
        XCTAssertEqual(heights[16], 0)
    }

    func testASoundMovesLeftAsItAges() {
        func peak(at sample: Int) -> Int {
            var levels = [Float](repeating: 0, count: 32)
            levels[sample] = 1
            // Divide the taper back out: where the sound is, not where the row is tallest.
            let heights = VoiceBars.heights(levels: levels, count: 63)
            let flat = heights.enumerated().map { $0.element / VoiceBars.reach(at: $0.offset, of: 63) }
            return flat.firstIndex(of: flat.max()!)!
        }
        XCTAssertGreaterThan(peak(at: 24), peak(at: 16))
        XCTAssertGreaterThan(peak(at: 16), peak(at: 8))
    }

    func testTheHistoryFillsTheRowAtAnyWidth() {
        let levels = [Float](repeating: 0.8, count: 32)
        for count in [1, 2, 13, 32, 64, 121] {
            let heights = VoiceBars.heights(levels: levels, count: count)
            XCTAssertEqual(heights.count, count)
            XCTAssertTrue(heights.allSatisfy { $0 > 0 }, "no empty bars at \(count)")
        }
        XCTAssertEqual(VoiceBars.heights(levels: [0.8], count: 3).count, 3)
        XCTAssertEqual(VoiceBars.heights(levels: levels, count: 0), [])
        XCTAssertEqual(VoiceBars.heights(levels: levels, count: -4), [])
    }

    func testBrokenSamplesAreDrawnAsSilenceOrFullScale() {
        let heights = VoiceBars.heights(levels: [.nan, .infinity, -3, 7], count: 4)
        XCTAssertTrue(heights.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
        XCTAssertEqual(heights[0], 0)
        XCTAssertEqual(heights[3], VoiceBars.edgeReach, accuracy: 0.0001)
    }

    func testBarCountFitsTheWidthWithOneBarOnTheCenterLine() {
        XCTAssertEqual(VoiceBars.count(fitting: 136), 37)
        XCTAssertEqual(VoiceBars.count(fitting: 137), 37)
        XCTAssertEqual(VoiceBars.count(fitting: 3.6), 1)
        XCTAssertEqual(VoiceBars.count(fitting: 2), 0)
        XCTAssertEqual(VoiceBars.count(fitting: 0), 0)
        XCTAssertEqual(VoiceBars.count(fitting: -20), 0)
        XCTAssertEqual(VoiceBars.count(fitting: .nan), 0)
        XCTAssertEqual(VoiceBars.count(fitting: 5000), 121)
        XCTAssertEqual(VoiceBars.count(fitting: 100, pitch: 0), 0)
        for width in stride(from: 4.0, through: 440, by: 3) {
            XCTAssertEqual(VoiceBars.count(fitting: width) % 2, 1, "odd at \(width)")
        }
    }
}
