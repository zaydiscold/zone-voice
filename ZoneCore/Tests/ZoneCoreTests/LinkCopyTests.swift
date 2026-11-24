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
                       "Text only, never audio, kept on this iPhone. iPhone backups leave it out; Backup and export keeps it. Text takes almost no space, so it stays until you delete it. Pick 7 or 30 days to clear old ones automatically, or Off to stop keeping them. A dictation that gets cut off is always saved. Notes are never touched.")
        XCTAssertEqual(LinkCopy.yourDataFooter([]), "Stored on this iPhone. Back up to Files, or pair a computer in Settings > Computers.")
        XCTAssertEqual(LinkCopy.inviteClaim(sendsToComputer: false), "I can dictate offline with the on-device model.")
        XCTAssertEqual(ZoneLinks.invite, ZoneLinks.invite(sendsToComputer: false))
        XCTAssertTrue(ZoneLinks.invite.contains("dictate offline with the on-device model"))
    }

    func testWithAComputerPairedNothingClaimsTheWordsStayOnThePhone() {
        let names = ["frostbyte"]
        XCTAssertEqual(LinkCopy.deleteNote(names), "Frostbyte deletes its copies the next time Zone syncs.")
        XCTAssertEqual(LinkCopy.deleteNote(names, what: "copy of the transcript"),
                       "Frostbyte deletes its copy of the transcript the next time Zone syncs.")
        XCTAssertEqual(LinkCopy.agedOutNote(names), "Copies already on frostbyte stay there.")
        XCTAssertTrue(LinkCopy.historyFooter(names).contains("sent to frostbyte, which keeps dictations after they are cleared here"))
        XCTAssertNotEqual(LinkCopy.historyFooter(names), LinkCopy.historyFooter([]))
        // Backup and export includes History; the footer must not say it is out of every backup.
        for footer in [LinkCopy.historyFooter([]), LinkCopy.historyFooter(names)] {
            XCTAssertFalse(footer.contains("out of backups"))
            XCTAssertTrue(footer.contains("Backup and export keeps it"))
        }
        XCTAssertEqual(LinkCopy.yourDataFooter(names),
                       "Dictations, notes and meeting transcripts go to frostbyte. Back up your library and dictionary to Files. Manage computers in Settings > Computers.")

        let privacy = try? XCTUnwrap(LinkCopy.privacyParagraph(names))
        XCTAssertEqual(privacy?.hasPrefix("You paired frostbyte."), true)
        XCTAssertEqual(LinkCopy.privacyComputers.contains("Audio stays out of the transfer."), true)
        XCTAssertEqual(LinkCopy.privacyComputers.contains("leaves the copies already there"), true)

        let invite = ZoneLinks.invite(sendsToComputer: true)
        XCTAssertTrue(invite.contains("send my words straight to my paired computer"))
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
        XCTAssertTrue(LinkCopy.yourDataFooter(["a", "b", "c"]).hasPrefix("Dictations, notes and meeting transcripts go to your paired computers."))
    }

    func testNoEmDashesInAnyOfIt() {
        for names in [[], ["frostbyte"], ["a", "b"], ["a", "b", "c"]] {
            let all = [LinkCopy.deleteNote(names), LinkCopy.agedOutNote(names), LinkCopy.historyFooter(names), LinkCopy.yourDataFooter(names),
                       LinkCopy.privacyParagraph(names), LinkCopy.privacyHistoryNote(names), LinkCopy.privacyControlsNote(names)]
            XCTAssertFalse(all.compactMap { $0 }.joined().contains("\u{2014}"))
        }
    }
}
