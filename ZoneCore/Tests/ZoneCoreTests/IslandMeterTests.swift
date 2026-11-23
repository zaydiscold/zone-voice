// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class IslandMeterTests: XCTestCase {
    func testStartsSilentAtCapacity() {
        let meter = IslandMeter(samplesPerBar: 3, capacity: 13)
        XCTAssertEqual(meter.bars, Array(repeating: 0, count: 13))
        XCTAssertEqual(meter.snapshot.count, 13)
    }

    func testEachBarIsTheBinPeakNotTheAverage() {
        var meter = IslandMeter(samplesPerBar: 3, capacity: 4)
        // One loud sample between two quiet ones: a syllable must survive as a peak.
        [0, 1, 0].forEach { meter.append($0) }
        XCTAssertEqual(meter.bars.last, IslandMeter.scale)
        XCTAssertEqual(meter.bars.dropLast(), [0, 0, 0])
    }

    func testOldestBarsScrollOff() {
        var meter = IslandMeter(samplesPerBar: 1, capacity: 3)
        [1, 0, 0, 0].forEach { meter.append($0) }
        XCTAssertEqual(meter.bars, [0, 0, 0])
    }

    func testSnapshotIncludesTheFillingBin() {
        var meter = IslandMeter(samplesPerBar: 3, capacity: 3)
        meter.append(1)
        XCTAssertEqual(meter.bars, [0, 0, 0], "a bin is not committed until it fills")
        XCTAssertEqual(meter.snapshot, [0, 0, IslandMeter.scale], "but the island shows it now")
        XCTAssertEqual(meter.snapshot.count, 3)
    }

    func testQuietSpeechClearsTheFloor() {
        // About -35 dBFS on Zone's meter curve is ~0.15: it must not read as silence on a 22 pt bar.
        XCTAssertGreaterThanOrEqual(IslandMeter.quantize(0.15), 5)
        XCTAssertEqual(IslandMeter.quantize(0), 0)
        XCTAssertEqual(IslandMeter.quantize(1), IslandMeter.scale)
    }

    func testBadInputIsClamped() {
        var meter = IslandMeter(samplesPerBar: 1, capacity: 2)
        meter.append(.nan)
        meter.append(7)
        XCTAssertEqual(meter.bars, [0, IslandMeter.scale])
        XCTAssertEqual(IslandMeter.quantize(-1), 0)
    }

    func testResetClearsHistoryAndPartialBin() {
        var meter = IslandMeter(samplesPerBar: 3, capacity: 2)
        [1, 1, 1, 1].forEach { meter.append($0) }
        meter.reset()
        XCTAssertEqual(meter.snapshot, [0, 0])
    }
}
