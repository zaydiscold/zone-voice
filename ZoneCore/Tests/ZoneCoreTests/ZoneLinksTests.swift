// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class ZoneLinksTests: XCTestCase {
    func testInviteSharesOnlyTheAppStoreLink() throws {
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for paired in [false, true] {
            let invite = ZoneLinks.invite(sendsToComputer: paired)
            let links = detector.matches(in: invite, range: NSRange(invite.startIndex..., in: invite))
            XCTAssertEqual(links.compactMap(\.url), [ZoneLinks.appStore])
            XCTAssertFalse(invite.contains("TestFlight"))
            XCTAssertTrue(invite.hasPrefix(ZoneLinks.pitch))
        }
    }

    func testLinksAreTheRealListings() {
        XCTAssertEqual(ZoneLinks.appStore.host, "apps.apple.com")
        XCTAssertTrue(ZoneLinks.appStore.path.hasSuffix("/id6830955448"))
        // No storefront in the path: each friend lands on their own country's store.
        XCTAssertFalse(ZoneLinks.appStore.path.hasPrefix("/us/"))
    }

    func testInviteHasNoLeadingIndentation() {
        XCTAssertFalse(ZoneLinks.invite.components(separatedBy: "\n").contains { $0.hasPrefix(" ") })
    }
}
