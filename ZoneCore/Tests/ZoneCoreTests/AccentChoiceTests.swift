// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class AccentChoiceTests: XCTestCase {
    func testLastChoiceSurvivesEmptyReadsAndTracksChanges() throws {
        let suite = "last-accent-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = LastAccentChoice(defaults: defaults)
        XCTAssertEqual(cache.resolve(stored: nil), .defaultChoice)
        defaults.set("unknown", forKey: LastAccentChoice.key)
        XCTAssertEqual(cache.resolve(stored: nil), .defaultChoice)
        for choice in AccentChoice.allCases {
            XCTAssertEqual(cache.resolve(stored: choice), choice)
            XCTAssertEqual(LastAccentChoice(defaults: defaults).resolve(stored: nil), choice)
        }
    }

    func testContrastOnReviewedSurfaces() {
        for choice in AccentChoice.allCases {
            for dark in [false, true] {
                XCTAssertGreaterThanOrEqual(contrast(choice.controlFillHex(isDark: dark), choice.controlInkHex(isDark: dark)), 4.5, choice.label)
            }
            for surface: UInt32 in [0xD1D3D9, 0xE2E4E8, 0xF1E9D2, 0xF7F2E4] {
                XCTAssertGreaterThanOrEqual(contrast(choice.lightHex, surface), 3, choice.label)
            }
            XCTAssertGreaterThanOrEqual(contrast(choice.lightHex, 0xFFFFFF), 4.5, choice.label)
            for surface: UInt32 in [0x2A2A2A, 0x333333, 0x171717, choice.foregroundHex] {
                XCTAssertGreaterThanOrEqual(contrast(choice.darkHex, surface), 4.5, choice.label)
            }
            XCTAssertGreaterThanOrEqual(contrast(choice.darkHex, 0x2E2E2F), 3, choice.label)
            XCTAssertGreaterThanOrEqual(contrast(choice.lightHex, choice.darkHex), 2.2, choice.label)
        }
    }

    func testReviewedPairsAndFillInk() {
        XCTAssertEqual(AccentChoice.allCases.map(\.lightHex), [0x7149E8, 0x007D9D, 0xD14200, 0x0E8657, 0xC44068])
        XCTAssertEqual(AccentChoice.allCases.map(\.darkHex), [0xC48AFF, 0xA5D6E4, 0xFFA341, 0x8CE6BE, 0xF6ACBE])
        XCTAssertEqual(Set(AccentChoice.allCases.map(\.foregroundHex)), [0x262626])
    }

    func testExistingSavedAccentsKeepTheirIdentityAlongsidePastels() {
        XCTAssertEqual(AccentChoice(rawValue: "violet"), .violet)
        XCTAssertEqual(AccentChoice(rawValue: "ice"), .ice)
        XCTAssertEqual(AccentChoice(rawValue: "ember"), .ember)
        XCTAssertEqual(AccentChoice(rawValue: "mint"), .mint)
        XCTAssertEqual(AccentChoice(rawValue: "rose"), .rose)
        XCTAssertEqual(Set(AccentChoice.allCases.map(\.darkHex)).count, AccentChoice.allCases.count)
    }

    private func contrast(_ first: UInt32, _ second: UInt32) -> Double {
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func luminance(_ hex: UInt32) -> Double {
        func channel(_ value: UInt32) -> Double {
            let c = Double(value) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((hex >> 16) & 255)
            + 0.7152 * channel((hex >> 8) & 255)
            + 0.0722 * channel(hex & 255)
    }
}
