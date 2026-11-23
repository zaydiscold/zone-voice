// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class SunShadowTests: XCTestCase {
    private let pacific = TimeZone(identifier: "America/Los_Angeles")!

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    /// real-shadows 1.2.0, `shadowVector(date, 37.5, -120, { minLength: 1.5, maxLength: 4, minAlpha: 0.5 })`
    /// with `sunPosition`, `moonPosition` and `moonIllumination` for the same moments. The package
    /// rounds the vector to two places. -120 is the Pacific zone's standard meridian, which is
    /// what `at` uses when it is given no longitude.
    private let reference: [(iso: String, dx: Double, dy: Double, alpha: Double, source: SunShadow.Source,
                             sunAlt: Double, sunAz: Double, moonAlt: Double, moonAz: Double, lit: Double)] = [
        ("2026-11-16T17:00:00Z", 2.13, 1.97, 0.68, .sun, 21.598, 137.895, -40.514, 80.686, 0.4258),   // 9:00, morning
        ("2026-11-16T20:00:00Z", -0.21, 2.03, 0.78, .sun, 33.500, 184.299, -6.121, 106.639, 0.4377),  // noon
        ("2026-11-16T23:00:00Z", -2.49, 1.93, 0.65, .sun, 17.287, 228.180, 23.835, 136.820, 0.4496),  // 15:00
        ("2026-11-17T00:50:00Z", -3.64, 1.6, 0.5, .moon, -1.121, 246.789, 34.839, 163.862, 0.4570),   // 16:50, afterglow
        ("2026-11-17T01:10:00Z", -0.08, 1.97, 0.5, .moon, -4.807, 249.755, 35.800, 169.531, 0.4583),  // 17:10, handoff
        ("2026-11-17T02:00:00Z", -0.19, 2.03, 0.5, .moon, -14.306, 256.896, 36.507, 184.155, 0.4617), // 18:00, half moon
        ("2026-11-17T06:20:00Z", -3.31, 1.78, 0.5, .moon, -63.813, 309.107, 8.072, 244.147, 0.4791),  // 22:20, moon setting
        ("2026-11-17T07:30:00Z", 1.5, 1.5, 0.5, .none, -71.219, 348.972, -4.402, 254.950, 0.4838),    // 23:30, nothing up
        ("2026-06-21T20:10:00Z", -0.22, 1.64, 0.98, .sun, 75.829, 187.588, 0.901, 93.964, 0.4934),    // solstice noon
        ("2026-11-25T06:00:00Z", 2.03, 1.87, 0.61, .moon, -61.437, 298.393, 58.029, 99.190, 0.9925),  // full moon, high
    ]

    func testTheSkyMatchesRealShadows() {
        for row in reference {
            let when = date(row.iso)
            let sun = SkyEphemeris.sun(when, latitude: 37.5, longitude: -120)
            let moon = SkyEphemeris.moon(when, latitude: 37.5, longitude: -120)
            XCTAssertEqual(sun.altitude, row.sunAlt, accuracy: 0.001, row.iso)
            XCTAssertEqual(sun.azimuth, row.sunAz, accuracy: 0.001, row.iso)
            XCTAssertEqual(moon.altitude, row.moonAlt, accuracy: 0.001, row.iso)
            XCTAssertEqual(moon.azimuth, row.moonAz, accuracy: 0.001, row.iso)
            XCTAssertEqual(SkyEphemeris.moonLitFraction(when), row.lit, accuracy: 0.0001, row.iso)
        }
    }

    func testTheShadowMatchesRealShadows() {
        for row in reference {
            let shadow = SunShadow.at(date(row.iso), timeZone: pacific)
            XCTAssertEqual(shadow.dx, row.dx, accuracy: 0.006, row.iso)
            XCTAssertEqual(shadow.dy, row.dy, accuracy: 0.006, row.iso)
            XCTAssertEqual(shadow.alpha, row.alpha, accuracy: 0.006, row.iso)
            XCTAssertEqual(shadow.source, row.source, row.iso)
            XCTAssertEqual(shadow.sunAltitude, row.sunAlt, accuracy: 0.001, row.iso)
        }
    }

    /// Facing south, the morning sun is on the left and the afternoon sun on the right, and a
    /// shadow falls away from its light. The first port had this backwards.
    func testMorningLeansRightAfternoonLeansLeft() {
        let morning = SunShadow.at(date("2026-11-01T16:30:00Z"), timeZone: pacific)
        let afternoon = SunShadow.at(date("2026-11-01T23:00:00Z"), timeZone: pacific)
        XCTAssertGreaterThan(morning.dx, 0)
        XCTAssertLessThan(afternoon.dx, 0)
        XCTAssertGreaterThan(morning.dy, 0)
        XCTAssertGreaterThan(afternoon.dy, 0)
    }

    func testSouthOfTheEquatorTheLeanFlips() {
        // Sydney, 10:00: the sun is in the north-east, on the right of someone facing north.
        let sydney = SunShadow.at(date("2026-11-16T23:00:00Z"), latitude: -33.9, longitude: 150)
        XCTAssertEqual(sydney.dx, -2.21, accuracy: 0.006)
        XCTAssertEqual(sydney.dy, 1.95, accuracy: 0.006)
    }

    func testDaylightSavingDoesNotMoveTheMeridian() {
        // The same instant read in summer time and in a fixed UTC-8 zone is the same sky.
        let july = date("2026-07-04T19:00:00Z")
        XCTAssertEqual(SunShadow.at(july, timeZone: pacific), SunShadow.at(july, timeZone: TimeZone(secondsFromGMT: -8 * 3600)!))
    }

    func testNoonIsShortAndDark() {
        let shadow = SunShadow.at(date("2026-06-21T20:10:00Z"), timeZone: pacific)
        XCTAssertLessThan(hypot(shadow.dx, shadow.dy), 1.7)
        XCTAssertGreaterThan(shadow.alpha, 0.9)
    }

    func testTheShadowNeverJumps() {
        // A whole lunar month in one-minute steps: sunrise, sunset, moonrise and moonset at
        // every phase. The shadow may never move more than a fraction of a point in a minute.
        // The hard handoff used to snap it from one side of a card to the other at sunset.
        let start = date("2026-11-01T08:00:00Z")
        var previous = SunShadow.at(start, timeZone: pacific)
        var worst = 0.0
        for minute in 1...(30 * 24 * 60) {
            let now = SunShadow.at(start.addingTimeInterval(Double(minute) * 60), timeZone: pacific)
            worst = max(worst, hypot(now.dx - previous.dx, now.dy - previous.dy))
            XCTAssertLessThan(abs(now.alpha - previous.alpha), 0.05)
            previous = now
        }
        XCTAssertLessThan(worst, 0.4)
    }

    func testAShadowIsAlwaysVisibleAndFallsDown() {
        let start = date("2026-01-01T00:00:00Z")
        for hour in 0..<(365 * 24) {
            let shadow = SunShadow.at(start.addingTimeInterval(Double(hour) * 3600), timeZone: pacific)
            XCTAssertGreaterThanOrEqual(shadow.alpha, 0.5 - 1e-9)
            XCTAssertLessThanOrEqual(shadow.alpha, 1)
            XCTAssertGreaterThan(shadow.dy, 0.5)
            // Each offset is bounded by the longest shadow. The lean and the fall are separate
            // curves in the package, so a horizon light gives (4, 1.6): 4.3 corner to corner.
            XCTAssertLessThanOrEqual(abs(shadow.dx), 4.0001)
            XCTAssertLessThanOrEqual(shadow.dy, 4.0001)
        }
    }

    func testNothingUpSettlesToAShortNeutralShadow() {
        let shadow = SunShadow.at(date("2026-11-17T07:30:00Z"), timeZone: pacific)
        XCTAssertEqual(shadow.source, .none)
        XCTAssertEqual(shadow.dx, 1.5, accuracy: 1e-9)
        XCTAssertEqual(shadow.dy, 1.5, accuracy: 1e-9)
    }
}
