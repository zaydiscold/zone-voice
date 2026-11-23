// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class ZoneLinksTests: XCTestCase {
    func testInviteCarriesBothLinksOnTheirOwnLines() {
        let lines = ZoneLinks.invite.components(separatedBy: "\n")
        XCTAssertTrue(lines.contains { $0.hasSuffix(ZoneLinks.appStore.absoluteString) })
        XCTAssertTrue(lines.contains { $0.hasSuffix(ZoneLinks.testFlight.absoluteString) })
        XCTAssertTrue(ZoneLinks.invite.hasPrefix(ZoneLinks.pitch))
    }

    func testLinksAreTheRealListings() {
        XCTAssertEqual(ZoneLinks.appStore.host, "apps.apple.com")
        XCTAssertTrue(ZoneLinks.appStore.path.hasSuffix("/id6830955448"))
        // No storefront in the path: each friend lands on their own country's store.
        XCTAssertFalse(ZoneLinks.appStore.path.hasPrefix("/us/"))
        XCTAssertEqual(ZoneLinks.testFlight.absoluteString, "https://testflight.apple.com/join/cStumGN1")
    }

    func testInviteHasNoLeadingIndentation() {
        XCTAssertFalse(ZoneLinks.invite.components(separatedBy: "\n").contains { $0.hasPrefix(" ") })
    }
}
