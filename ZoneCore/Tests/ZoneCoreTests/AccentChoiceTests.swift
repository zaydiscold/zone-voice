// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class AccentChoiceTests: XCTestCase {
    func testEveryAccentHasReadableTextOnPaperAndFilledControls() {
        for choice in AccentChoice.allCases {
            XCTAssertGreaterThanOrEqual(contrast(choice.textHexOnLight, 0xF1E9D2), 4.5, choice.label + " on light paper")
            XCTAssertGreaterThanOrEqual(contrast(choice.hex, 0x2A2A2A), 4.5, choice.label + " on dark paper")
            XCTAssertGreaterThanOrEqual(contrast(choice.foregroundHex, choice.hex), 4.5, choice.label + " filled control")
        }
    }

    /// The wave, the bars and the swipe trail are shapes, so they need 3:1, not text's 4.5:1,
    /// against the light keyboard backdrop and Zone's cream paper and card.
    func testEveryAccentHoldsItsShapeOnLightSurfaces() {
        for choice in AccentChoice.allCases {
            for (surface, hex) in [("light keyboard", UInt32(0xD1D3D9)), ("cream paper", 0xF1E9D2), ("cream card", 0xF7F2E4)] {
                XCTAssertGreaterThanOrEqual(contrast(choice.graphicHexOnLight, hex), 3, "\(choice.label) wave on \(surface)")
            }
            // Brighter than the text tone: a filled shape in the text tone goes dull.
            XCTAssertGreaterThan(luminance(choice.graphicHexOnLight), luminance(choice.textHexOnLight), choice.label)
        }
    }

    func testExistingSavedAccentsKeepTheirIdentityAlongsidePastels() {
        XCTAssertEqual(AccentChoice(rawValue: "violet"), .violet)
        XCTAssertEqual(AccentChoice(rawValue: "ice"), .ice)
        XCTAssertEqual(AccentChoice(rawValue: "ember"), .ember)
        XCTAssertEqual(AccentChoice(rawValue: "mint"), .mint)
        XCTAssertEqual(AccentChoice(rawValue: "rose"), .rose)
        XCTAssertEqual(Set(AccentChoice.allCases.map(\.hex)).count, AccentChoice.allCases.count)
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
