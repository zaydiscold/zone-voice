// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// What the app says about where words go: unchanged with no computer paired, honest with one.
final class LinkCopyTests: XCTestCase {
    func testNothingChangesUntilAComputerIsPaired() {
        XCTAssertNil(LinkCopy.who([]))
        XCTAssertNil(LinkCopy.deleteNote([]))
        XCTAssertNil(LinkCopy.agedOutNote([]))
        XCTAssertNil(LinkCopy.privacyParagraph([]))
        XCTAssertNil(LinkCopy.privacyHistoryNote([]))
        XCTAssertNil(LinkCopy.privacyControlsNote([]))
        XCTAssertEqual(LinkCopy.historyFooter([]),
                       "Text only, never audio, kept on this iPhone and out of backups. Text takes almost no space, so it stays until you delete it. Pick 7 or 30 days to clear old ones automatically, or Off to stop keeping them. A dictation that gets cut off is always saved. Notes are never touched.")
        XCTAssertEqual(LinkCopy.yourDataFooter([]), "Stored on this iPhone. Back up to Files, or pair a computer in Setup.")
        XCTAssertEqual(LinkCopy.inviteClaim(sendsToComputer: false), "Nothing you say leaves your phone.")
        XCTAssertEqual(ZoneLinks.invite, ZoneLinks.invite(sendsToComputer: false))
        XCTAssertTrue(ZoneLinks.invite.contains("Nothing you say leaves your phone."))
    }

    func testWithAComputerPairedNothingClaimsTheWordsStayOnThePhone() {
        let names = ["frostbyte"]
        XCTAssertEqual(LinkCopy.deleteNote(names), "Frostbyte deletes its copies the next time Zone syncs.")
        XCTAssertEqual(LinkCopy.deleteNote(names, what: "copy of the transcript"),
                       "Frostbyte deletes its copy of the transcript the next time Zone syncs.")
        XCTAssertEqual(LinkCopy.agedOutNote(names), "Copies already on frostbyte stay there.")
        XCTAssertTrue(LinkCopy.historyFooter(names).contains("sent to frostbyte, which keeps dictations after they are cleared here"))
        XCTAssertNotEqual(LinkCopy.historyFooter(names), LinkCopy.historyFooter([]))
        XCTAssertEqual(LinkCopy.yourDataFooter(names),
                       "Stored on this iPhone and sent to frostbyte. Back up to Files, or manage computers in Setup.")

        let privacy = try? XCTUnwrap(LinkCopy.privacyParagraph(names))
        XCTAssertEqual(privacy?.hasPrefix("You paired frostbyte. Zone sends it the text"), true)
        XCTAssertEqual(privacy?.contains("Audio is never sent."), true)
        XCTAssertEqual(privacy?.contains("leaves what the computer already has"), true)

        let invite = ZoneLinks.invite(sendsToComputer: true)
        XCTAssertFalse(invite.contains("leaves your phone"))
        XCTAssertTrue(invite.hasPrefix(ZoneLinks.pitch))
        XCTAssertTrue(invite.contains(ZoneLinks.appStore.absoluteString))
        XCTAssertEqual(invite.components(separatedBy: "\n").count, ZoneLinks.invite.components(separatedBy: "\n").count)
    }

    func testSeveralComputersReadAsSeveral() {
        XCTAssertEqual(LinkCopy.who(["a", "b"]), "a and b")
        XCTAssertEqual(LinkCopy.who(["a", "b", "c"]), "your paired computers")
        XCTAssertEqual(LinkCopy.deleteNote(["a", "b"]), "A and b delete their copies the next time Zone syncs.")
        XCTAssertEqual(LinkCopy.deleteNote(["a", "b", "c"]), "Your paired computers delete their copies the next time Zone syncs.")
        XCTAssertEqual(LinkCopy.privacyHistoryNote(["a", "b"]), "While a and b are paired, this text is sent there too (see Computers).")
        XCTAssertTrue(LinkCopy.yourDataFooter(["a", "b", "c"]).hasPrefix("Stored on this iPhone and sent to your paired computers."))
    }

    func testNoEmDashesInAnyOfIt() {
        for names in [[], ["frostbyte"], ["a", "b"], ["a", "b", "c"]] {
            let all = [LinkCopy.deleteNote(names), LinkCopy.agedOutNote(names), LinkCopy.historyFooter(names), LinkCopy.yourDataFooter(names),
                       LinkCopy.privacyParagraph(names), LinkCopy.privacyHistoryNote(names), LinkCopy.privacyControlsNote(names)]
            XCTAssertFalse(all.compactMap { $0 }.joined().contains("\u{2014}"))
        }
    }
}
